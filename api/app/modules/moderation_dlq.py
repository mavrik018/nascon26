"""Part II: chat moderation engine and notification dead-letter queue (5.8, FR-5.2, FR-5.3).

Moderation (deterministic, per message in order):
  1. rate limit  more than 3 messages from one sender in a 2 s window -> blocked (not broadcast), sender muted
                 (probe: messages in one request are the same instant; live chat: 429 RATE_LIMITED)
  2. flood       >= 4 identical non-space characters (case-insensitive) or >= 3 of ! / ? in a row
                 -> dropped completely, sender muted
  3. profanity   leetspeak-normalised token matches the dictionary -> token replaced by ***, kept with
                 flagged true / reason profanity_leetspeak, sender kicked
  4. clean       kept unchanged, flagged false / reason null
Room state (kicked/muted lists, stored messages) is serialised per room by an advisory lock,
so concurrent identical requests stay idempotent (edge case 3).

DLQ: deliver() retries a notification up to 3 times with exponential backoff, then parks it in
notification_dlq (observability reads its depth).
"""
import re
import time
import uuid

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from psycopg.types.json import Jsonb
from starlette.concurrency import run_in_threadpool

from ..auth import current_user
from ..db import pool
from ..errors import ApiError, validation
from ..signing import sign_day2
from . import day2
from .util import is_id, is_int, read_json

router = APIRouter()

SCHEMA = """
CREATE TABLE IF NOT EXISTS moderation_rooms (
    chat_room_id TEXT PRIMARY KEY,
    kicked_users JSONB NOT NULL DEFAULT '[]',
    muted_users  JSONB NOT NULL DEFAULT '[]'
);
CREATE TABLE IF NOT EXISTS chat_messages (
    chat_room_id TEXT NOT NULL,
    message_id   TEXT NOT NULL,
    seq          BIGINT NOT NULL,
    sender       TEXT NOT NULL,
    text         TEXT NOT NULL,
    flagged      BOOLEAN NOT NULL,
    reason       TEXT,
    dropped      BOOLEAN NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (chat_room_id, message_id)
);
CREATE INDEX IF NOT EXISTS chat_messages_room_seq ON chat_messages (chat_room_id, seq);
CREATE TABLE IF NOT EXISTS notification_dlq (
    id         BIGSERIAL PRIMARY KEY,
    event_type TEXT NOT NULL,
    payload    JSONB NOT NULL,
    attempts   INTEGER NOT NULL,
    last_error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
"""


def reset(conn, seed: int, body: dict) -> None:
    conn.execute("TRUNCATE chat_messages, moderation_rooms, notification_dlq RESTART IDENTITY")


# --------------------------------------------------------------------------- moderation rules

PROFANITY = {"badword", "porn", "scam", "fuck", "shit", "bitch", "asshole", "idiotspam"}
LEET = str.maketrans({"@": "a", "0": "o", "1": "i", "3": "e", "$": "s"})
ZERO_WIDTH = re.compile("[​‌‍⁠﻿]")
FLOOD = re.compile(r"(\S)\1{3,}|[!?]{3,}", re.IGNORECASE)
TOKEN_EDGES = re.compile(r"^([\"'(\[{]*)(.*?)([\"')\]}.,;:?!]*)$", re.DOTALL)
RATE_LIMIT, RATE_WINDOW_SECONDS = 3, 2
REASON_PROFANITY, REASON_FLOOD, REASON_RATE = "profanity_leetspeak", "flood_character_repeat", "rate_limit_exceeded"


def _is_profane(token: str) -> bool:
    s = ZERO_WIDTH.sub("", token).lower()
    # "!" is leet for i (sh!t) but also a plain separator (s!c@m): try both readings.
    for variant in (s.replace("!", "i"), s.replace("!", "")):
        word = re.sub(r"[\W_]", "", variant.translate(LEET))
        if word in PROFANITY or (word.endswith("s") and word[:-1] in PROFANITY):
            return True
    return False


def _mask(text: str) -> tuple[str, bool]:
    """Replace each offending whitespace-separated token with ***, keeping surrounding punctuation."""
    hit = False
    parts = re.split(r"(\s+)", text)
    for i, token in enumerate(parts):
        if not token or token.isspace():
            continue
        lead, core, trail = TOKEN_EDGES.match(token).groups()
        if core and _is_profane(core):
            parts[i], hit = lead + "***" + trail, True
        elif _is_profane(token):
            parts[i], hit = "***", True
    return "".join(parts), hit


def classify(text: str) -> tuple[str, str, bool, str | None]:
    """-> (action, text, flagged, reason); action is 'drop' or 'keep'. Pure: no rate limiting here."""
    if FLOOD.search(ZERO_WIDTH.sub("", text)):
        return "drop", text, True, REASON_FLOOD
    masked, hit = _mask(text)
    return ("keep", masked, True, REASON_PROFANITY) if hit else ("keep", text, False, None)


def _add(users: list, user: str) -> None:
    if user not in users:
        users.append(user)


def _lock_room(conn, room: str) -> dict:
    conn.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", ("room:" + room,))
    conn.execute("INSERT INTO moderation_rooms (chat_room_id) VALUES (%s) ON CONFLICT DO NOTHING", (room,))
    return conn.execute("SELECT kicked_users, muted_users FROM moderation_rooms WHERE chat_room_id = %s",
                        (room,)).fetchone()


def _save_room(conn, room: str, kicked: list, muted: list) -> None:
    conn.execute("UPDATE moderation_rooms SET kicked_users = %s, muted_users = %s WHERE chat_room_id = %s",
                 (Jsonb(kicked), Jsonb(muted), room))


def _store(conn, room: str, m: dict) -> int | None:
    """Insert a message with the next per-room seq; a replayed message_id is ignored (returns None)."""
    row = conn.execute(
        "INSERT INTO chat_messages (chat_room_id, message_id, seq, sender, text, flagged, reason, dropped)"
        " SELECT %s, %s, COALESCE(MAX(seq), 0) + 1, %s, %s, %s, %s, %s FROM chat_messages WHERE chat_room_id = %s"
        " ON CONFLICT DO NOTHING RETURNING seq",
        (room, m["message_id"], m["sender"], m["text"], m["flagged"], m["reason"], m["dropped"], room)).fetchone()
    return row["seq"] if row else None


# --------------------------------------------------------------------------- DLQ

BACKOFF_SECONDS = (0.1, 0.2, 0.4)
MAX_ATTEMPTS = 3


def deliver(conn, event_type: str, payload: dict, send, sleep=time.sleep) -> bool:
    """Try send(payload) up to 3 times with exponential backoff; on final failure park it in the DLQ.
    Returns True when delivered. Pass sleep=lambda _: None to skip the waits (probe / tests)."""
    last_error = None
    for attempt in range(MAX_ATTEMPTS):
        try:
            send(payload)
            return True
        except Exception as e:  # any downstream failure counts as a failed attempt
            last_error = f"{type(e).__name__}: {e}"
            if attempt < MAX_ATTEMPTS - 1:
                sleep(BACKOFF_SECONDS[attempt])
    conn.execute("INSERT INTO notification_dlq (event_type, payload, attempts, last_error) VALUES (%s, %s, %s, %s)",
                 (event_type, Jsonb(payload), MAX_ATTEMPTS, last_error))
    return False


def _simulated_failure(_payload):
    raise ConnectionError("simulated downstream webhook failure")


def dlq_status(conn) -> dict:
    rows = conn.execute("SELECT id, event_type, attempts, last_error FROM notification_dlq ORDER BY id").fetchall()
    return {"queue_depth": len(rows),
            "undelivered_events": [{"event_id": f"dlq-{r['id']}", "event_type": r["event_type"],
                                    "attempts": r["attempts"], "last_error": r["last_error"]} for r in rows]}


# --------------------------------------------------------------------------- probe

def _validate(body) -> tuple[str, list, int]:
    if not isinstance(body, dict):
        raise validation("body")
    bad = []
    room, msgs = body.get("chat_room_id"), body.get("incoming_messages")
    if not is_id(room):
        bad.append("chat_room_id")
    if not isinstance(msgs, list):
        bad.append("incoming_messages")
    else:
        for m in msgs:
            if not isinstance(m, dict):
                bad.append("incoming_messages")
                continue
            for key in ("message_id", "sender", "text"):
                if not isinstance(m.get(key), str) or (key != "text" and not m[key].strip()):
                    bad.append(f"incoming_messages.{key}")
    if not isinstance(body.get("check_dlq", False), bool):
        bad.append("check_dlq")
    simulate = body.get("simulate_failed_notifications", 0)
    if not is_int(simulate, 0, 1000):
        bad.append("simulate_failed_notifications")
    if bad:
        raise validation(sorted(set(bad)))
    return room, msgs, simulate


def moderate_probe(body) -> dict:
    room, msgs, simulate = _validate(body)
    with pool.connection() as conn:
        state = _lock_room(conn, room)
        kicked, muted = list(state["kicked_users"]), list(state["muted_users"])
        filtered, per_sender = [], {}
        for m in msgs:
            sender = m["sender"]
            per_sender[sender] = per_sender.get(sender, 0) + 1
            if per_sender[sender] > RATE_LIMIT:  # one request = one instant, so the window is the request
                action, text, flagged, reason = "drop", m["text"], True, REASON_RATE
            else:
                action, text, flagged, reason = classify(m["text"])
            if action == "drop":
                _add(muted, sender)
            elif flagged:
                _add(kicked, sender)
            out = {"message_id": m["message_id"], "sender": sender, "text": text, "flagged": flagged,
                   "reason": reason}
            _store(conn, room, {**out, "dropped": action == "drop"})
            if action == "keep":
                filtered.append(out)
        _save_room(conn, room, kicked, muted)
        for i in range(simulate):
            deliver(conn, "chat_notification", {"chat_room_id": room, "sequence": i + 1}, _simulated_failure,
                    sleep=lambda _: None)
        dlq = dlq_status(conn)
    flagged_count = sum(1 for f in filtered if f["flagged"])
    signature = sign_day2(room, {"chat_room_id": room, "flagged_count": flagged_count, "kicked_users": kicked,
                                 "queue_depth": dlq["queue_depth"]})
    return {"chat_room_id": room, "filtered_messages": filtered, "kicked_users": kicked, "muted_users": muted,
            "dlq_status": dlq, "signature": signature}


@router.post("/audit/v1/moderation/test")
async def moderation_test(request: Request):
    return await run_in_threadpool(moderate_probe, await read_json(request))


# --------------------------------------------------------------------------- live chat (guest web player)

CHAT_HISTORY_LIMIT = 200


@router.get("/api/v1/public/chat/{chat_room_id}")
def public_chat(chat_room_id: str):
    # shortcut: newest 200 messages only; add cursor paging if rooms get long histories
    with pool.connection() as conn:
        rows = conn.execute(
            "SELECT message_id, sender, text, flagged FROM (SELECT * FROM chat_messages"
            " WHERE chat_room_id = %s AND NOT dropped ORDER BY seq DESC LIMIT %s) t ORDER BY seq",
            (chat_room_id, CHAT_HISTORY_LIMIT)).fetchall()
    return [dict(r) for r in rows]


def post_chat(claims: dict, body) -> tuple[int, dict]:
    if not isinstance(body, dict):
        raise validation("body")
    room, text = body.get("chat_room_id"), body.get("text")
    bad = ([] if is_id(room) else ["chat_room_id"]) + \
          ([] if isinstance(text, str) and text.strip() and len(text) <= 2000 else ["text"])
    if bad:
        raise validation(bad)
    sender = str(claims["sub"])
    with pool.connection() as conn:
        state = _lock_room(conn, room)
        kicked, muted = list(state["kicked_users"]), list(state["muted_users"])
        recent = conn.execute(
            "SELECT count(*) AS n FROM chat_messages WHERE chat_room_id = %s AND sender = %s"
            " AND created_at > clock_timestamp() - make_interval(secs => %s)",
            (room, sender, RATE_WINDOW_SECONDS)).fetchone()["n"]
        msg = {"message_id": str(uuid.uuid4()), "sender": sender}
        if recent >= RATE_LIMIT:
            _add(muted, sender)
            _store(conn, room, {**msg, "text": text, "flagged": True, "reason": REASON_RATE, "dropped": True})
            _save_room(conn, room, kicked, muted)
            conn.commit()  # keep the mute; the 429 below would otherwise roll it back
            raise ApiError(429, "RATE_LIMITED", "Chat flood threshold exceeded",
                           {"retry_after": RATE_WINDOW_SECONDS}, {"Retry-After": str(RATE_WINDOW_SECONDS)})
        action, out_text, flagged, reason = classify(text)
        if action == "drop":
            _add(muted, sender)
        elif flagged:
            _add(kicked, sender)
        out = {**msg, "text": out_text, "flagged": flagged, "reason": reason}
        seq = _store(conn, room, {**out, "dropped": action == "drop"})
        _save_room(conn, room, kicked, muted)
    out = {"chat_room_id": room, "seq": seq, **out}
    return (200, {**out, "dropped": True}) if action == "drop" else (201, out)


@router.post("/api/v1/chat")
async def chat(request: Request):
    """FR-4.3: no token or a guest token -> 403 GUEST_WRITE_FORBIDDEN; members' messages are moderated."""
    token = day2.bearer(request)
    if token is None or day2.is_guest_token(token):
        raise day2.guest_forbidden(token)
    claims = current_user(request)
    status, out = await run_in_threadpool(post_chat, claims, await read_json(request))
    return JSONResponse(out, status_code=status)
