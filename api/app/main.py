"""App wiring only. Each domain area lives in its own module under app/modules/
and exposes:  router (APIRouter), SCHEMA (idempotent DDL), reset(conn, seed, body).
POST /audit/v1/reset calls every module's reset() in MODULES order inside one
transaction, so a reset is all-or-nothing and repeatable."""
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, Response

from . import errors
from .db import pool
from .modules import MODULES, core

MAX_BODY_BYTES = 1024 * 1024  # spec 5.2: bodies over 1 MB -> 413


@asynccontextmanager
async def lifespan(app: FastAPI):
    pool.open(wait=True, timeout=60)
    core.bootstrap()  # create tables + seed baseline if empty
    yield
    pool.close()


app = FastAPI(title="Multi-Sport League & Club Operations Platform", lifespan=lifespan)
errors.install(app)


@app.middleware("http")
async def limit_body_size(request: Request, call_next):
    length = request.headers.get("content-length")
    if length is not None and length.isdigit() and int(length) > MAX_BODY_BYTES:
        return errors.envelope(413, "PAYLOAD_TOO_LARGE", "Request body exceeds 1 MB")
    if length is None and request.method in ("POST", "PUT", "PATCH"):
        body = await request.body()  # chunked upload: measure the real body
        if len(body) > MAX_BODY_BYTES:
            return errors.envelope(413, "PAYLOAD_TOO_LARGE", "Request body exceeds 1 MB")
    return await call_next(request)


for module in MODULES:
    app.include_router(module.router)


@app.get("/health")
def health(response: Response):
    """200 only when the database is reachable and the baseline is seeded (spec 5.4)."""
    if core.is_ready():
        return {"status": "ok"}
    response.status_code = 503
    return {"status": "unavailable"}
