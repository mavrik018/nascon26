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


WRITE_METHODS = ("POST", "PUT", "PATCH", "DELETE")


class Guards:
    """One plain ASGI middleware (NFR-2: the BaseHTTPMiddleware style cost ~10 ms CPU per request), in order:
    1. spec 5.13 rate limit on /api/v1/* per client IP (/audit/v1/* and /health exempt);
    2. Part II 5.7 / FR-4.3: a guest_* bearer may never mutate anything, on any route (server-side, not UI);
    3. spec 5.2: request bodies over 1 MB -> 413 (chunked uploads are measured)."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        from .modules import day2, rbac
        request = Request(scope)
        if scope["path"].startswith("/api/v1/"):
            retry = rbac.check_rate_limit(rbac.client_ip(request))
            if retry is not None:
                return await errors.envelope(429, "RATE_LIMITED", "Too many requests", {"retry_after": retry},
                                             {"Retry-After": str(retry)})(scope, receive, send)
            scope[rbac.RATE_LIMIT_SCOPE_FLAG] = True
        method = scope["method"]
        token = day2.bearer(request)
        if method in WRITE_METHODS and day2.is_guest_token(token):
            e = day2.guest_forbidden(token)
            return await errors.envelope(e.status, e.code, e.message, e.details)(scope, receive, send)
        length = request.headers.get("content-length")
        if length is not None and length.isdigit() and int(length) > MAX_BODY_BYTES:
            return await errors.envelope(413, "PAYLOAD_TOO_LARGE", "Request body exceeds 1 MB")(scope, receive, send)
        if length is None and method in ("POST", "PUT", "PATCH"):
            chunks, size, more = [], 0, True  # chunked upload: read it all, measure, then replay it
            while more:
                message = await receive()
                chunks.append(message)
                size += len(message.get("body", b""))
                more = message.get("more_body", False)
            if size > MAX_BODY_BYTES:
                return await errors.envelope(413, "PAYLOAD_TOO_LARGE", "Request body exceeds 1 MB")(scope, receive, send)
            pending = iter(chunks)

            async def replay():
                return next(pending, None) or await receive()

            return await self.app(scope, replay, send)
        return await self.app(scope, receive, send)


app.add_middleware(Guards)


for module in MODULES:
    app.include_router(module.router)


def _redis_ok() -> bool:
    """PING over a raw socket (no client library needed). Skipped when REDIS_HOST is not configured."""
    import os
    import socket
    host = os.environ.get("REDIS_HOST")
    if not host:
        return True
    try:
        with socket.create_connection((host, int(os.environ.get("REDIS_PORT", "6379"))), timeout=1) as s:
            s.sendall(b"PING\r\n")
            return s.recv(16).startswith(b"+PONG")
    except OSError:
        return False


def _media_ok() -> bool:
    """MediaMTX control API answers. Skipped when MEDIA_API_URL is not configured."""
    import os
    import urllib.request
    url = os.environ.get("MEDIA_API_URL")
    if not url:
        return True
    try:
        with urllib.request.urlopen(url + "/v3/paths/list", timeout=1) as r:
            return r.status == 200
    except OSError:
        return False


@app.get("/health")
def health(response: Response):
    """200 only when the database is reachable and seeded, and Redis + the media server answer (Part II 5.1)."""
    if core.is_ready() and _redis_ok() and _media_ok():
        return {"status": "ok"}
    return errors.envelope(503, "SERVICE_UNAVAILABLE", "Database, Redis or media server not ready")
