"""Spec 5.3 / Appendix A: the one place signatures are computed.
DAY1_SALT is read from the environment at call time and never logged."""
import hashlib
import hmac
import json
import os


def canonical(obj) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def sign(id_: str, payload_obj, salt: str | None = None) -> str:
    key = (os.environ.get("DAY1_SALT", "") if salt is None else salt).encode("utf-8")
    msg = (id_ + "|" + canonical(payload_obj)).encode("utf-8")
    return hmac.new(key, msg, hashlib.sha256).hexdigest()


def sign_day2(entity_id: str, sig_payload, salt: str | None = None) -> str:
    """Part II 5.3 / Appendix A: HMAC-SHA256(DAY2_SALT, entity_id + "|" + canonical(sig_payload)), lowercase hex.
    DAY2_SALT comes only from the environment (never trimmed, never hex-decoded)."""
    key = (os.environ.get("DAY2_SALT", "") if salt is None else salt).encode("utf-8")
    msg = (entity_id + "|" + canonical(sig_payload)).encode("utf-8")
    return hmac.new(key, msg, hashlib.sha256).hexdigest()


def lots_key(seed: int, league_id: str, team_id: str) -> str:
    return hashlib.sha256(f"{seed}|{league_id}|{team_id}".encode("utf-8")).hexdigest()
