"""App wiring only. Each domain area lives in its own module under app/modules/
and exposes:  router (APIRouter), SCHEMA (idempotent DDL), reset(conn, seed, body).
POST /audit/v1/reset calls every module's reset() in MODULES order inside one
transaction, so a reset is all-or-nothing and repeatable."""
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, Response

from . import errors
from .db import pool
from .modules import MODULES, core

MAX_BODY_BYTES = 1_000_000  # spec 5.2: bodies over 1 MB -> 413 (decimal MB: the stricter reading)


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


WRITE_METHODS = ("POST", "PUT", "PATCH", "DELETE")


@app.middleware("http")
async def guest_write_block(request: Request, call_next):
    """Part II 5.7 / FR-4.3: a guest_* bearer token may never mutate anything, on any route (server-side, not UI)."""
    from .modules import day2
    token = day2.bearer(request)
    if request.method in WRITE_METHODS and day2.is_guest_token(token):
        e = day2.guest_forbidden(token)
        return errors.envelope(e.status, e.code, e.message, e.details)
    return await call_next(request)


@app.middleware("http")
async def rate_limit(request: Request, call_next):
    """Spec 5.13: every /api/v1/* path is limited per client IP; /audit/v1/* and /health are exempt."""
    from .modules import rbac
    if request.url.path.startswith("/api/v1/"):
        retry = rbac.check_rate_limit(rbac.client_ip(request))
        if retry is not None:
            return errors.envelope(429, "RATE_LIMITED", "Too many requests", {"retry_after": retry},
                                   {"Retry-After": str(retry)})
        request.scope[rbac.RATE_LIMIT_SCOPE_FLAG] = True
    return await call_next(request)


for module in MODULES:
    app.include_router(module.router)


@app.get("/health")
def health(response: Response):
    """200 only when the database is reachable and the baseline is seeded (spec 5.4)."""
    if core.is_ready():
        return {"status": "ok"}
    return errors.envelope(503, "SERVICE_UNAVAILABLE", "Database not reachable or baseline not seeded")
