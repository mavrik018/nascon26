"""FR-3.2 recording: finished MediaMTX segments -> MinIO (SigV4 PUT) + vod_recordings index -> athlete VOD list."""
import datetime as dt
import os
import time
import urllib.error
import urllib.request

import pytest

pytestmark = pytest.mark.in_process  # writes segment files where the API process reads them

MINIO = os.environ.get("TEST_MINIO_URL", "http://localhost:9000")
CREDS = ("nascon", "nascon-local-only")  # Laptop 2's local-only MinIO (CONTEXT.md); skipped when unreachable


def minio_up() -> bool:
    try:
        return urllib.request.urlopen(f"{MINIO}/minio/health/live", timeout=2).status == 200
    except (urllib.error.URLError, OSError):
        return False


@pytest.fixture
def rec(tmp_path, monkeypatch):
    from app.modules import recording
    monkeypatch.setattr(recording, "RECORDINGS_DIR", tmp_path)
    monkeypatch.delenv("MINIO_URL", raising=False)
    return recording


def segment(root, key, name="2026-10-18_12-40-01-123456.mp4", age=10, data=b"\x00\x00\x00\x18ftypmp42"):
    p = root / "live" / key / name
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)
    t = time.time() - age
    os.utime(p, (t, t))
    return p


def stream_key(api):
    r = api.post("/audit/v1/stream/key", json={"player_id": "player-alpha-1", "action": "generate"})
    assert r.status_code == 201, r.text
    return r.json()["stream_key"]


def test_sync_indexes_finished_segments_once_and_profile_lists_them(api, rec, tmp_path):
    api.reset()
    key = stream_key(api)
    segment(tmp_path, key)
    segment(tmp_path, key, name="2026-10-18_12-40-11-5.mp4", age=0)  # still being written: skipped
    r = api.post("/internal/media/recordings/sync")
    assert r.status_code == 200, r.text
    (row,) = r.json()
    assert row["stream_key"] == key and row["player_id"] == "player-alpha-1" and row["object_url"] is None
    assert row["started_at"].startswith("2026-10-18T12:40:01.123456")
    assert api.post("/internal/media/recordings/sync").json() == []  # indexed once, not again
    assert len(api.get(f"/api/v1/vod/{key}").json()) == 1
    vod = api.get("/api/v1/athletes/player-alpha-1").json()["vod"]
    assert [v["stream_key"] for v in vod] == [key]


def test_bad_segment_requests_are_rejected(rec, tmp_path):
    from app.errors import ApiError
    good = segment(tmp_path, "k1")
    for body in ([], {"path": "live/k1", "segment": "/etc/passwd"}, {"path": "vod/x", "segment": str(good)},
                 {"path": "live/k1", "segment": str(tmp_path / "live" / "k1" / "notes.txt")}):
        with pytest.raises(ApiError):
            rec.store_segment(body)


def test_sync_without_recordings_dir_is_empty(rec, tmp_path, monkeypatch):
    monkeypatch.setattr(rec, "RECORDINGS_DIR", tmp_path / "missing")
    assert rec.sync_recordings() == []
    rec.sync_in_background()  # no directory: does nothing, never raises


def test_upload_error_is_kept_on_the_row(api, rec, tmp_path, monkeypatch):
    api.reset()
    key = stream_key(api)
    seg = segment(tmp_path, key)
    monkeypatch.setenv("MINIO_URL", "http://127.0.0.1:9")  # nothing listens: upload fails, row still indexed
    row = rec.store_segment({"path": f"live/{key}", "segment": str(seg)})
    assert row["object_url"] is None and row["upload_error"]


def test_sigv4_signature_matches_aws_reference_shape():
    from app.modules.recording import s3_put
    seen = {}

    class Res:
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    def opener(req, timeout):
        seen["req"] = req
        return Res()

    url = s3_put("http://minio:9000", "vod", "k/a b.mp4", b"x", "AK", "SK",
                 now=dt.datetime(2026, 10, 18, 12, 0, tzinfo=dt.timezone.utc), opener=opener)
    assert url == "http://minio:9000/vod/k/a%20b.mp4"
    auth = seen["req"].get_header("Authorization")
    assert auth.startswith("AWS4-HMAC-SHA256 Credential=AK/20261018/us-east-1/s3/aws4_request, "
                           "SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=")
    assert len(auth.rsplit("=", 1)[1]) == 64


@pytest.mark.skipif(not minio_up(), reason=f"no MinIO at {MINIO}")
def test_real_minio_upload(api, rec, tmp_path, monkeypatch):
    api.reset()
    key = stream_key(api)
    data = os.urandom(2048)
    seg = segment(tmp_path, key, data=data)
    monkeypatch.setenv("MINIO_URL", MINIO)
    monkeypatch.setenv("MINIO_ACCESS_KEY", CREDS[0])
    monkeypatch.setenv("MINIO_SECRET_KEY", CREDS[1])
    (row,) = rec.sync_recordings()
    assert row["object_url"] == f"{MINIO}/vod/{key}/{seg.name}" and row["upload_error"] is None
    assert rec.sync_recordings() == []  # uploaded segments are not uploaded again
