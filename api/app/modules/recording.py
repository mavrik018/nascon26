"""Part II FR-3.2: stream recording to object storage + VOD index.

MediaMTX records every published path as fMP4 segments into the shared `recordings` volume
(infra/mediamtx.yml: record / recordPath). The MediaMTX image has no shell for a runOnRecordSegmentComplete hook,
so the API indexes finished segments itself: when a stream key is revoked (the broadcast is over) and on
POST /internal/media/recordings/sync. For every finished, not-yet-indexed segment it:
  1. uploads the segment to S3-compatible storage (MinIO) with a plain SigV4 PUT (stdlib only), and
  2. appends a vod_recordings row (stream_key, player_id, object_url, started_at, ended_at), which the athlete
     profile (social.py) lists as the VOD archive.
With MINIO_URL unset (tests, CI without MinIO) the row is still written with object_url NULL and no upload.
"""
import datetime as dt
import hashlib
import hmac
import os
import pathlib
import re
import threading
import time
import urllib.parse
import urllib.request

from fastapi import APIRouter
from starlette.concurrency import run_in_threadpool

from ..db import pool
from ..errors import validation

router = APIRouter()

SCHEMA = """
CREATE TABLE IF NOT EXISTS vod_recordings (
    id          BIGSERIAL PRIMARY KEY,
    stream_key  TEXT NOT NULL,
    player_id   TEXT,
    segment     TEXT NOT NULL UNIQUE,
    object_url  TEXT,
    started_at  TIMESTAMPTZ NOT NULL,
    ended_at    TIMESTAMPTZ NOT NULL,
    upload_error TEXT
);
CREATE INDEX IF NOT EXISTS vod_recordings_player ON vod_recordings (player_id, started_at);
"""

RECORDINGS_DIR = pathlib.Path(os.environ.get("RECORDINGS_DIR", "/recordings"))
# recordPath: /recordings/%path/%Y-%m-%d_%H-%M-%S-%f  ->  <dir>/live/<key>/2026-10-18_12-40-01-123456.mp4
NAME = re.compile(r"(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})-(\d{1,6})\.mp4$")


def reset(conn, seed: int, body: dict) -> None:
    conn.execute("TRUNCATE vod_recordings RESTART IDENTITY")


def _sign(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def s3_put(endpoint: str, bucket: str, key: str, data: bytes, access: str, secret: str,
           region: str = "us-east-1", content_type: str = "video/mp4", now: dt.datetime | None = None,
           opener=urllib.request.urlopen) -> str:
    """PUT one object with AWS Signature V4 (path-style, as MinIO expects). Returns the object URL."""
    now = now or dt.datetime.now(dt.timezone.utc)
    amz_date, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    host = urllib.parse.urlsplit(endpoint).netloc
    path = "/" + bucket + "/" + urllib.parse.quote(key, safe="/-_.~")
    payload_hash = hashlib.sha256(data).hexdigest()
    headers = {"host": host, "x-amz-content-sha256": payload_hash, "x-amz-date": amz_date}
    signed = ";".join(sorted(headers))
    canonical = "\n".join(["PUT", path, "", *(f"{h}:{headers[h]}" for h in sorted(headers)), "", signed,
                           payload_hash])
    scope = f"{day}/{region}/s3/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    k = _sign(_sign(_sign(_sign(("AWS4" + secret).encode(), day), region), "s3"), "aws4_request")
    signature = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
    req = urllib.request.Request(endpoint.rstrip("/") + path, data=data, method="PUT", headers={
        "x-amz-content-sha256": payload_hash, "x-amz-date": amz_date, "Content-Type": content_type,
        "Authorization": f"AWS4-HMAC-SHA256 Credential={access}/{scope}, SignedHeaders={signed}, "
                         f"Signature={signature}"})
    with opener(req, timeout=30) as res:
        if res.status not in (200, 201):
            raise OSError(f"S3 PUT {res.status}")
    return endpoint.rstrip("/") + path


def _parse(body) -> tuple[str, pathlib.Path, dt.datetime]:
    if not isinstance(body, dict):
        raise validation("body")
    mtx_path, segment = body.get("path"), body.get("segment")
    bad = []
    if not isinstance(mtx_path, str) or not re.fullmatch(r"live/[A-Za-z0-9_\-]{1,128}", mtx_path or ""):
        bad.append("path")
    seg = None
    if isinstance(segment, str):
        seg = pathlib.Path(segment).resolve()
        if RECORDINGS_DIR.resolve() not in seg.parents or not NAME.search(seg.name):
            seg = None
    if seg is None:
        bad.append("segment")
    if bad:
        raise validation(bad)
    y, mo, d, h, mi, s, frac = NAME.search(seg.name).groups()
    started = dt.datetime(int(y), int(mo), int(d), int(h), int(mi), int(s), int(frac.ljust(6, "0")),
                          tzinfo=dt.timezone.utc)
    return mtx_path.split("/", 1)[1], seg, started


def store_segment(body) -> dict:
    stream_key, seg, started = _parse(body)
    object_url, error = None, None
    endpoint = os.environ.get("MINIO_URL", "")
    if endpoint and seg.is_file():
        try:
            object_url = s3_put(endpoint, os.environ.get("MINIO_BUCKET", "vod"), f"{stream_key}/{seg.name}",
                                seg.read_bytes(), os.environ.get("MINIO_ACCESS_KEY", ""),
                                os.environ.get("MINIO_SECRET_KEY", ""))
        except Exception as e:  # storage down: keep the index row, remember why (retry is a re-post)
            error = f"{type(e).__name__}: {e}"
    elif endpoint:
        error = "segment file not found"
    with pool.connection() as conn:
        owner = conn.execute("SELECT player_id FROM stream_keys WHERE stream_key = %s", (stream_key,)).fetchone()
        row = conn.execute(
            """INSERT INTO vod_recordings (stream_key, player_id, segment, object_url, started_at, ended_at, upload_error)
               VALUES (%s, %s, %s, %s, %s, now(), %s)
               ON CONFLICT (segment) DO UPDATE SET object_url = COALESCE(EXCLUDED.object_url, vod_recordings.object_url),
                 upload_error = EXCLUDED.upload_error, ended_at = EXCLUDED.ended_at
               RETURNING id, stream_key, player_id, object_url, started_at, ended_at, upload_error""",
            (stream_key, owner["player_id"] if owner else None, str(seg), object_url, started, error)).fetchone()
    return {**row, "started_at": row["started_at"].isoformat(), "ended_at": row["ended_at"].isoformat()}


SETTLE_SECONDS = 3  # a segment untouched this long is finished (MediaMTX rotates segments every few seconds)


def sync_recordings(now: float | None = None) -> list[dict]:
    """Index (and upload) every finished segment under RECORDINGS_DIR/live/<key>/ that is not indexed yet."""
    root = RECORDINGS_DIR / "live"
    if not root.is_dir():
        return []
    now = now if now is not None else dt.datetime.now().timestamp()
    with pool.connection() as conn:
        done = {r["segment"] for r in conn.execute(
            "SELECT segment FROM vod_recordings WHERE object_url IS NOT NULL OR %s = ''",
            (os.environ.get("MINIO_URL", ""),)).fetchall()}
    stored = []
    for seg in sorted(root.glob("*/*.mp4")):
        if str(seg.resolve()) in done or now - seg.stat().st_mtime < SETTLE_SECONDS:
            continue
        stored.append(store_segment({"path": f"live/{seg.parent.name}", "segment": str(seg)}))
    return stored


def sync_in_background() -> None:
    """After a broadcast ends: wait for the last segment to settle, then index it. Never raises."""
    def run():
        time.sleep(SETTLE_SECONDS + 1)
        try:
            sync_recordings()
        except Exception:
            pass  # storage or DB hiccup: POST /internal/media/recordings/sync retries later

    if RECORDINGS_DIR.is_dir():
        threading.Thread(target=run, daemon=True).start()


@router.post("/internal/media/recordings/sync")
async def media_recordings_sync():
    return await run_in_threadpool(sync_recordings)


@router.get("/api/v1/vod/{stream_key}")
def vod_index(stream_key: str):
    with pool.connection() as conn:
        rows = conn.execute("SELECT stream_key, player_id, object_url, started_at, ended_at FROM vod_recordings "
                            "WHERE stream_key = %s ORDER BY started_at", (stream_key,)).fetchall()
    return [{**r, "started_at": r["started_at"].isoformat(), "ended_at": r["ended_at"].isoformat()} for r in rows]
