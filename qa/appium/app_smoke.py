"""Appium 2 (UiAutomator2) smoke test of the real Android app against the running backend.

Installs mobile/release/app-release.apk on the emulator (or a USB phone), signs in with the Viewer demo account
and checks the five tabs appear. Talks to Appium's W3C REST API with `requests` (no extra client package).

Prereqs (three terminals):
    emulator -avd Medium_Phone_API_36.0          # or plug in a phone with USB debugging
    appium --port 4723
    docker compose up -d                          # backend on :8080 (the emulator reaches it as 10.0.2.2:8080)
Run:
    python qa/appium/app_smoke.py
"""
import base64
import os
import pathlib
import sys
import time

import requests

APPIUM = os.environ.get("APPIUM_URL", "http://localhost:4723")
ROOT = pathlib.Path(__file__).resolve().parents[2]
APK = os.environ.get("APK", str(ROOT / "mobile" / "release" / "app-release.apk"))
OUT = pathlib.Path(__file__).with_name("screenshots")


class Session:
    def __init__(self):
        caps = {
            "platformName": "Android",
            "appium:automationName": "UiAutomator2",
            "appium:app": APK,
            "appium:appPackage": "pk.nascon.league.league_app",
            "appium:autoGrantPermissions": True,
            "appium:newCommandTimeout": 180,
            "appium:uiautomator2ServerInstallTimeout": 120000,
            "appium:adbExecTimeout": 120000,
        }
        r = requests.post(f"{APPIUM}/session", json={"capabilities": {"alwaysMatch": caps}}, timeout=600)
        r.raise_for_status()
        self.id = r.json()["value"]["sessionId"]
        self.base = f"{APPIUM}/session/{self.id}"

    def find(self, uiselector: str, timeout: float = 30):
        """Wait for an element matched by an Android UiSelector, return its id."""
        end = time.time() + timeout
        while time.time() < end:
            r = requests.post(f"{self.base}/element",
                              json={"using": "-android uiautomator", "value": uiselector}, timeout=60)
            if r.status_code == 200:
                return next(iter(r.json()["value"].values()))
            time.sleep(1)
        raise AssertionError(f"not found within {timeout}s: {uiselector}")

    def tap(self, uiselector: str, timeout: float = 30):
        el = self.find(uiselector, timeout)
        requests.post(f"{self.base}/element/{el}/click", json={}, timeout=60).raise_for_status()

    def screenshot(self, name: str):
        OUT.mkdir(exist_ok=True)
        png = requests.get(f"{self.base}/screenshot", timeout=60).json()["value"]
        (OUT / name).write_bytes(base64.b64decode(png))

    def source(self) -> str:
        return requests.get(f"{self.base}/source", timeout=60).json()["value"]

    def quit(self):
        requests.delete(self.base, timeout=60)


def main() -> int:
    s = Session()
    try:
        # Sign-in screen: the Viewer demo chip fills email + password (Semantics label from the app).
        s.tap('new UiSelector().descriptionContains("Viewer")', timeout=60)
        s.tap('new UiSelector().descriptionMatches("(?i).*sign in.*").clickable(true)')
        # Home: the five tabs of spec 8.2 (navigation bar labels).
        for tab in ("Fixtures", "Standings", "Club", "Store", "Profile"):
            s.find(f'new UiSelector().descriptionContains("{tab}")', timeout=45)
        s.screenshot("home.png")
        print("PASS  Appium 2 / UiAutomator2: app installed, Viewer signed in, 5 tabs visible")
        return 0
    except AssertionError as e:
        (OUT / "page_source.xml").parent.mkdir(exist_ok=True)
        (OUT / "page_source.xml").write_text(s.source(), encoding="utf-8")
        print(f"FAIL  {e}  (UI dump saved to qa/appium/screenshots/page_source.xml)")
        return 1
    finally:
        s.quit()


if __name__ == "__main__":
    sys.exit(main())
