"""One connection pool for the whole app. `with pool.connection() as conn:`
commits when the block ends and rolls back on an exception."""
import os

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://league:league-local-only@localhost:5432/league")

pool = ConnectionPool(
    DATABASE_URL,
    min_size=2,
    # Several uvicorn workers share Postgres' 100 connections: DB_POOL_MAX per worker (compose sets it).
    max_size=int(os.environ.get("DB_POOL_MAX", "30")),
    open=False,
    kwargs={"row_factory": dict_row},
    # Connections killed by a DB restart are detected before use (no 500s).
    check=ConnectionPool.check_connection,
)
