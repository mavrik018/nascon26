"""Guest Web Player routes (/web/*). The HTML/JS/CSS live in app/web/ (owned by the frontend laptop);
these routes only pick the right file. If a page is not there yet, a minimal accessible placeholder is
served so the QR redirects (spec 5.6) always land on a working page."""
import pathlib

from fastapi import APIRouter
from fastapi.responses import FileResponse, HTMLResponse

router = APIRouter()

SCHEMA = ""
WEB_DIR = pathlib.Path(__file__).resolve().parent.parent / "web"
MATCH_VIEWS = ("live", "preview", "vod")


def reset(conn, seed: int, body: dict) -> None:
    pass


def _page(name: str, title: str):
    path = WEB_DIR / name
    if path.is_file():
        return FileResponse(path, media_type="text/html")
    return HTMLResponse(f"<!doctype html><html lang='en'><head><meta charset='utf-8'>"
                        f"<meta name='viewport' content='width=device-width, initial-scale=1'><title>{title}</title>"
                        f"</head><body><main><h1>{title}</h1></main></body></html>")


@router.get("/web/matches/{match_id}/notice")
def match_notice(match_id: str):
    return _page("notice.html", "Match notice")


@router.get("/web/matches/{match_id}/{view}")
def match_page(match_id: str, view: str):
    if view not in MATCH_VIEWS:
        return HTMLResponse("<!doctype html><title>Not found</title><h1>Page not found</h1>", status_code=404)
    return _page("match.html", "Live match")


@router.get("/web/costream/{session_id}")
def costream_page(session_id: str):
    return _page("costream.html", "Co-stream")


@router.get("/web/players/{player_id}")
def player_page(player_id: str):
    return _page("entity.html", "Player")


@router.get("/web/clubs/{club_id}")
def club_page(club_id: str):
    return _page("entity.html", "Club")


@router.get("/web/static/{name}")
def static_file(name: str):
    path = (WEB_DIR / name).resolve()
    if WEB_DIR.resolve() not in path.parents or not path.is_file():  # no path traversal
        return HTMLResponse("Not found", status_code=404)
    media = {".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png"}
    return FileResponse(path, media_type=media.get(path.suffix, "application/octet-stream"))
