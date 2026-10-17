"""Reset/seed orchestration and readiness (spec 5.4, 5.5)."""
from fastapi import APIRouter, Request

from ..db import pool
from ..errors import validation

router = APIRouter()

SCHEMA = """
CREATE TABLE IF NOT EXISTS app_state (
    key   TEXT PRIMARY KEY,
    value JSONB NOT NULL
);
"""

DEFAULT_STOCK = {"var-jersey-001-M": 1, "var-jersey-001-L": 5}


def reset(conn, seed: int, body: dict) -> None:
    conn.execute("DELETE FROM app_state")
    conn.execute("INSERT INTO app_state (key, value) VALUES ('seed', %s::jsonb)", (str(seed),))


def _all_modules():
    from . import MODULES
    return MODULES


def apply_schemas(conn) -> None:
    for module in _all_modules():
        if module.SCHEMA.strip():
            conn.execute(module.SCHEMA)


def run_reset(seed: int = 42, stock: dict | None = None) -> None:
    body = {"seed": seed, "stock": {**DEFAULT_STOCK, **(stock or {})}}
    with pool.connection() as conn:
        # One lock so concurrent resets/startup never interleave.
        conn.execute("SELECT pg_advisory_xact_lock(4242)")
        apply_schemas(conn)
        for module in _all_modules():
            module.reset(conn, seed, body)


def bootstrap() -> None:
    with pool.connection() as conn:
        conn.execute("SELECT pg_advisory_xact_lock(4242)")
        apply_schemas(conn)
        seeded = conn.execute("SELECT 1 FROM app_state WHERE key = 'seed'").fetchone()
    if not seeded:
        run_reset()


def current_seed() -> int:
    with pool.connection() as conn:
        row = conn.execute("SELECT value FROM app_state WHERE key = 'seed'").fetchone()
    return int(row["value"]) if row else 42


def is_ready() -> bool:
    try:
        with pool.connection(timeout=2) as conn:
            return conn.execute("SELECT 1 FROM app_state WHERE key = 'seed'").fetchone() is not None
    except Exception:
        return False


@router.post("/audit/v1/reset")
async def reset_endpoint(request: Request):
    raw = await request.body()
    body = {}
    if raw.strip():
        import json
        try:
            body = json.loads(raw)
        except ValueError:
            raise validation("body", "Malformed JSON")
        if not isinstance(body, dict):
            raise validation("body")
    seed = body.get("seed", 42)
    if seed is None:
        seed = 42
    if isinstance(seed, bool) or not isinstance(seed, int):
        raise validation("seed")
    stock = body.get("stock") or {}
    if not isinstance(stock, dict) or any(
        not isinstance(k, str) or isinstance(v, bool) or not isinstance(v, int) or v < 0 for k, v in stock.items()
    ):
        raise validation("stock")
    merged = {**DEFAULT_STOCK, **stock}
    run_reset(seed, merged)
    from . import sports
    return {"status": "reset_complete", "seed": seed, "sports": sports.BASELINE_SPORT_IDS,
            "tenants": ["tenant-alpha", "tenant-beta"], "stock": merged}
