"""JWT helpers shared by every module (HS256, secret from JWT_SECRET).

Tokens carry: sub (user_id), role, tenant_id, and optionally league_id /
club_id / player_id for the scoped roles. Any decode problem (missing,
malformed, tampered, expired, alg:none) is 401 UNAUTHENTICATED."""
import datetime
import os

import jwt
from fastapi import Request

from .errors import ApiError

ALGORITHM = "HS256"
ROLES = ("super_admin", "league_organizer", "club_manager", "player", "viewer")


def _secret() -> str:
    return os.environ.get("JWT_SECRET", "change-me-local-only")


def create_token(claims: dict, hours: int = 12) -> str:
    now = datetime.datetime.now(datetime.timezone.utc)
    body = {**claims, "iat": now, "exp": now + datetime.timedelta(hours=hours)}
    return jwt.encode(body, _secret(), algorithm=ALGORITHM)


def unauthenticated(message: str = "Missing or invalid token") -> ApiError:
    return ApiError(401, "UNAUTHENTICATED", message)


def decode_token(token: str) -> dict:
    try:
        # algorithms=[HS256] rejects alg:none and any other algorithm.
        claims = jwt.decode(token, _secret(), algorithms=[ALGORITHM], options={"require": ["exp", "sub", "role"]})
    except jwt.PyJWTError:
        raise unauthenticated()
    if claims.get("role") not in ROLES:
        raise unauthenticated()
    return claims


def current_user(request: Request) -> dict:
    """FastAPI dependency: the decoded claims of the Bearer token, or 401."""
    header = request.headers.get("authorization", "")
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise unauthenticated()
    return decode_token(token.strip())


def forbidden(message: str = "Not allowed") -> ApiError:
    return ApiError(403, "FORBIDDEN", message)
