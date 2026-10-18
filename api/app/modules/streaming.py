"""Part II: stream key lifecycle (spec 5.4)."""
from fastapi import APIRouter

router = APIRouter()

SCHEMA = ""


def reset(conn, seed: int, body: dict) -> None:
    pass
