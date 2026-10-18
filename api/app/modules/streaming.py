"""Part II: stream key lifecycle (spec 5.4) and the MediaMTX publish-auth hook.

stream_keys keeps every key ever issued; a player has at most one 'active' key
(partial unique index). generate/rotate revoke the prior active key and issue a
new one; revoke flips the active key to 'revoked'. A revoked key is never usable
again (409 KEY_REVOKED), including as a stream_key_override."""
import re
import secrets

from fastapi import APIRouter, Request, Response
from fastapi.responses import JSONResponse

from ..db import pool
from ..errors import ApiError, conflict, not_found, validation
from ..signing import sign_day2
from .day2 import require_player
from .util import read_json

router = APIRouter()

SCHEMA = """
CREATE TABLE IF NOT EXISTS stream_keys (
    stream_key TEXT PRIMARY KEY,
    player_id  TEXT NOT NULL,
    label      TEXT NOT NULL,
    status     TEXT NOT NULL CHECK (status IN ('active', 'revoked')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS stream_keys_one_active ON stream_keys (player_id) WHERE status = 'active';
"""

ACTIONS = ("generate", "rotate", "revoke")
KEY_RE = re.compile(r"^sk_live_[a-f0-9]{16}\Z")


def reset(conn, seed: int, body: dict) -> None:
    conn.execute("DELETE FROM stream_keys")


def key_revoked(stream_key: str) -> ApiError:
    return conflict("KEY_REVOKED", "Stream key has been revoked", stream_key=stream_key)


def active_key(conn, key) -> bool:
    return isinstance(key, str) and conn.execute(
        "SELECT 1 FROM stream_keys WHERE stream_key = %s AND status = 'active'", (key,)).fetchone() is not None


def key_view(player_id: str, label: str, stream_key: str, status: str) -> dict:
    live = status == "active"
    return {
        "player_id": player_id, "label": label, "stream_key": stream_key, "status": status,
        "ingest_endpoints": {"rtmp": f"rtmp://localhost:1935/live/{stream_key}",
                             "webrtc": f"http://localhost:8889/live/{stream_key}/whip"} if live else None,
        "playback_url": f"http://localhost:8888/live/{stream_key}/index.m3u8" if live else None,
    }


def _validate(body) -> dict:
    if not isinstance(body, dict):
        raise validation("body")
    bad = []
    if body.get("action") not in ACTIONS:
        bad.append("action")
    if not isinstance(body.get("player_id"), str) or not body["player_id"]:
        bad.append("player_id")
    label = body.get("label", "default")
    if not isinstance(label, str) or not 1 <= len(label) <= 64:
        bad.append("label")
    override = body.get("stream_key_override")
    if override is not None and not (isinstance(override, str) and KEY_RE.match(override)):
        bad.append("stream_key_override")
    if bad:
        raise validation(bad)
    return {"action": body["action"], "player_id": body["player_id"], "label": label, "override": override}


def kick_publishers(stream_key: str) -> int:
    """Disconnect every RTMP / WebRTC publisher on live/<stream_key> via the MediaMTX control API.
    No-op when MEDIA_API_URL is not set (tests, no media server). Returns how many sessions were kicked."""
    import json
    import os
    import urllib.request
    base = os.environ.get("MEDIA_API_URL")
    if not base:
        return 0
    kicked = 0
    for kind in ("rtmpconns", "webrtcsessions"):
        try:
            with urllib.request.urlopen(f"{base}/v3/{kind}/list", timeout=1) as r:
                items = json.load(r).get("items", [])
            for item in items:
                if item.get("path") == f"live/{stream_key}":
                    req = urllib.request.Request(f"{base}/v3/{kind}/kick/{item['id']}", method="POST")
                    urllib.request.urlopen(req, timeout=1).close()
                    kicked += 1
        except OSError:
            pass  # media server down: the auth hook still refuses any new publish with this key
    return kicked


@router.post("/audit/v1/stream/key")
async def stream_key(request: Request):
    req = _validate(await read_json(request))
    action, player_id = req["action"], req["player_id"]
    with pool.connection() as conn:
        require_player(conn, player_id)
        conn.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", ("stream:" + player_id,))
        current = conn.execute("SELECT stream_key, label FROM stream_keys WHERE player_id = %s AND status = 'active'",
                               (player_id,)).fetchone()
        if action == "revoke":
            if current is None:
                raise not_found("STREAM_NOT_FOUND", player_id=player_id)
            key, label, status = current["stream_key"], current["label"], "revoked"
            conn.execute("UPDATE stream_keys SET status = 'revoked', updated_at = now() WHERE stream_key = %s", (key,))
        else:
            key, label, status = req["override"] or "sk_live_" + secrets.token_hex(8), req["label"], "active"
            conn.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", ("stream-key:" + key,))
            row = conn.execute("SELECT status FROM stream_keys WHERE stream_key = %s", (key,)).fetchone()
            if row is not None and row["status"] == "revoked":
                raise key_revoked(key)
            conn.execute("UPDATE stream_keys SET status = 'revoked', updated_at = now() "
                         "WHERE player_id = %s AND status = 'active' AND stream_key <> %s", (player_id, key))
            # An override that is already active (e.g. a replayed rotate) is re-issued to this player.
            conn.execute("""INSERT INTO stream_keys (stream_key, player_id, label, status) VALUES (%s, %s, %s, 'active')
                            ON CONFLICT (stream_key) DO UPDATE SET player_id = EXCLUDED.player_id,
                            label = EXCLUDED.label, status = 'active', updated_at = now()""", (key, player_id, label))
        if action == "revoke":
            superseded = [key]
        else:
            superseded = [current["stream_key"]] if current is not None and current["stream_key"] != key else []
    # After commit: cut any live ingest still using a revoked key (FR-3.2: within 2 s).
    for old in superseded:
        kick_publishers(old)
    body = key_view(player_id, label, key, status)
    body["signature"] = sign_day2(key, {"action": action, "player_id": player_id, "status": status,
                                        "stream_key": key})
    return JSONResponse(status_code=201 if action == "generate" else 200, content=body)


@router.get("/audit/v1/stream/key/{key}")
def get_stream_key(key: str):
    with pool.connection() as conn:
        row = conn.execute("SELECT player_id, label, status FROM stream_keys WHERE stream_key = %s", (key,)).fetchone()
    if row is None:
        raise not_found("STREAM_NOT_FOUND", stream_key=key)
    if row["status"] == "revoked":
        raise key_revoked(key)
    return key_view(row["player_id"], row["label"], key, row["status"])


@router.post("/internal/media/auth")
async def media_auth(request: Request):
    """MediaMTX authHTTPAddress hook: any non-2xx denies. Only publishing needs an active key."""
    try:
        body = await read_json(request)
    except ApiError:
        body = None
    if not isinstance(body, dict):
        raise ApiError(401, "UNAUTHENTICATED", "Malformed media auth request")
    if body.get("action") != "publish":
        return Response(status_code=200)
    path = body.get("path")
    key = path[len("live/"):] if isinstance(path, str) and path.startswith("live/") else None
    with pool.connection() as conn:
        if key and active_key(conn, key):
            return Response(status_code=200)
        if key and conn.execute("SELECT 1 FROM stream_keys WHERE stream_key = %s", (key,)).fetchone():
            raise key_revoked(key)
    raise ApiError(401, "UNAUTHENTICATED", "Unknown stream key", {"path": path})
