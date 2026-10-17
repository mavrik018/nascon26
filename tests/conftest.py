"""Tests run against the real running stack (docker compose up -d --wait).
API_URL lets teammates point at the host laptop over the hotspot."""
import os
import time

import pytest
import requests

BASE_URL = os.environ.get("API_URL", "http://localhost:8080")


class Api:
    def __init__(self, base_url: str):
        self.base_url = base_url
        self.session = requests.Session()

    def request(self, method: str, path: str, **kwargs) -> requests.Response:
        kwargs.setdefault("timeout", 10)
        return self.session.request(method, self.base_url + path, **kwargs)

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


def wait_until_healthy(api: Api, seconds: float = 90) -> None:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            if api.get("/health", timeout=5).status_code == 200:
                return
        except requests.RequestException:
            pass
        time.sleep(1)
    pytest.fail(f"API at {BASE_URL} not healthy within {seconds}s")


@pytest.fixture(scope="session")
def api() -> Api:
    client = Api(BASE_URL)
    wait_until_healthy(client)
    return client
