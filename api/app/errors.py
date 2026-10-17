"""Spec 5.2 error envelope for every non-2xx response:
{"error": {"code": "UPPER_SNAKE", "message": "...", "details": {...}}}
Schema-invalid / malformed requests are 400 VALIDATION_ERROR with
details.fields = offending field names (not FastAPI's default 422)."""
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str = "", details: dict | None = None,
                 headers: dict | None = None):
        super().__init__(message or code)
        self.status, self.code, self.message = status, code, message or code
        self.details = details or {}
        self.headers = headers


def envelope(status: int, code: str, message: str = "", details: dict | None = None,
             headers: dict | None = None) -> JSONResponse:
    return JSONResponse(status_code=status, headers=headers,
                        content={"error": {"code": code, "message": message or code, "details": details or {}}})


def validation(fields: list[str] | str, message: str = "Request is invalid") -> ApiError:
    if isinstance(fields, str):
        fields = [fields]
    return ApiError(400, "VALIDATION_ERROR", message, {"fields": fields})


def not_found(code: str, **details) -> ApiError:
    return ApiError(404, code, f"{code}: {details}", details)


def conflict(code: str, message: str = "", **details) -> ApiError:
    return ApiError(409, code, message or code, details)


HTTP_CODES = {400: "VALIDATION_ERROR", 401: "UNAUTHENTICATED", 403: "FORBIDDEN", 404: "NOT_FOUND",
              405: "METHOD_NOT_ALLOWED", 409: "CONFLICT", 413: "PAYLOAD_TOO_LARGE", 429: "RATE_LIMITED"}


def _field_name(loc: tuple) -> str:
    parts = [str(p) for p in loc[1:] if not isinstance(p, int)] if loc and loc[0] in ("body", "query", "path") \
        else [str(p) for p in loc]
    return ".".join(parts) or "body"


def install(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    async def _api_error(_: Request, e: ApiError):
        return envelope(e.status, e.code, e.message, e.details, e.headers)

    @app.exception_handler(RequestValidationError)
    async def _validation(_: Request, e: RequestValidationError):
        fields = sorted({_field_name(tuple(err.get("loc", ()))) for err in e.errors()})
        return envelope(400, "VALIDATION_ERROR", "Request is malformed or invalid", {"fields": fields})

    @app.exception_handler(StarletteHTTPException)
    async def _http(_: Request, e: StarletteHTTPException):
        return envelope(e.status_code, HTTP_CODES.get(e.status_code, "ERROR"), str(e.detail))

    @app.exception_handler(Exception)
    async def _unhandled(_: Request, e: Exception):
        return envelope(500, "INTERNAL_ERROR", "Unexpected server error")
