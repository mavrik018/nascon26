"""Two ways to run the same tests:

* In-process (default): the FastAPI app runs inside pytest via TestClient against
  a real PostgreSQL given by TEST_DATABASE_URL (run_tests.sh starts one).
  This is what produces line coverage for COVERAGE.json.
* Over HTTP: set API_URL (e.g. http://localhost:8080 or the host laptop's LAN IP)
  to test a running docker compose stack.

Every test that changes state calls api.reset() first, so tests are independent.
"""
import os
import time

import pytest
import requests

API_URL = os.environ.get("API_URL")
TEST_DATABASE_URL = os.environ.get("TEST_DATABASE_URL", "postgresql://league:dev@localhost:55432/league")
os.environ.setdefault("DAY1_SALT", "test-salt")

if not API_URL:
    # Must be set before app.db is imported (the pool reads it at import time).
    os.environ["DATABASE_URL"] = TEST_DATABASE_URL

# DAY1_SALT the code under test sees (in HTTP mode the server's own env decides).
SALT = os.environ["DAY1_SALT"]


class Api:
    """requests-style helper; works over HTTP or against an in-process TestClient."""

    def __init__(self, client, base_url: str = ""):
        self.client = client
        self.base_url = base_url

    def request(self, method: str, path: str, **kwargs):
        if self.base_url:
            kwargs.setdefault("timeout", 15)
        else:
            kwargs.pop("timeout", None)
            if "data" in kwargs:
                kwargs["content"] = kwargs.pop("data")
        return self.client.request(method, self.base_url + path, **kwargs)

    def get(self, path, **kw):
        return self.request("GET", path, **kw)

    def post(self, path, **kw):
        return self.request("POST", path, **kw)

    def put(self, path, **kw):
        return self.request("PUT", path, **kw)

    def patch(self, path, **kw):
        return self.request("PATCH", path, **kw)

    def delete(self, path, **kw):
        return self.request("DELETE", path, **kw)

    def reset(self, **body):
        r = self.post("/audit/v1/reset", json=body or None)
        assert r.status_code == 200, r.text
        return r.json()


def _wait_http(base_url: str, seconds: float = 120) -> None:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            if requests.get(base_url + "/health", timeout=5).status_code == 200:
                return
        except requests.RequestException:
            pass
        time.sleep(1)
    pytest.fail(f"API at {base_url} not healthy within {seconds}s")


def pytest_collection_modifyitems(config, items):
    """White-box tests call module functions directly; they only make sense in-process."""
    if API_URL:
        skip = pytest.mark.skip(reason="in-process only (calls Python functions directly)")
        for item in items:
            if "in_process" in item.keywords:
                item.add_marker(skip)


@pytest.fixture(scope="session")
def api():
    if API_URL:
        _wait_http(API_URL)
        yield Api(requests.Session(), API_URL)
    else:
        from fastapi.testclient import TestClient
        from app.main import app
        with TestClient(app) as client:
            yield Api(client)
