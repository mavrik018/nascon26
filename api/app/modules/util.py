"""Shared request helpers."""
import json
import re

from fastapi import Request

from ..errors import validation

ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,64}\Z")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}\Z")


async def read_json(request: Request):
    """Parse the body ourselves so malformed JSON is a 400 in the spec envelope."""
    raw = await request.body()
    try:
        return json.loads(raw) if raw.strip() else None
    except ValueError:
        raise validation("body", "Malformed JSON")


def is_id(value) -> bool:
    return isinstance(value, str) and bool(ID_RE.match(value))


def is_int(value, minimum=None, maximum=None) -> bool:
    return (isinstance(value, int) and not isinstance(value, bool)
            and (minimum is None or value >= minimum) and (maximum is None or value <= maximum))


def parse_date(value):
    """YYYY-MM-DD -> datetime.date, or None if invalid."""
    import datetime
    if not isinstance(value, str) or not DATE_RE.match(value):
        return None
    try:
        return datetime.date.fromisoformat(value)
    except ValueError:
        return None


def utc_now_iso() -> str:
    import datetime
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
