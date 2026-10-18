"""Appium 2 deep-link suite (spec 6.3). Needs Appium on :4723 (uiautomator2) and one adb device with the
release APK installed (mobile/release/app-release.apk).

    pytest tests/appium/ --junitxml=tests/reports/appium-report.xml

Env: APPIUM_URL (default http://localhost:4723), ANDROID_SERIAL (optional), and for the cross-surface test
GRID_URL / WEB_BASE / API_URL as in tests/selenium/conftest.py.
"""
import os
import shutil
import subprocess
import time
import uuid

import pytest
import requests

APPIUM_URL = os.environ.get("APPIUM_URL", "http://localhost:4723")
PACKAGE = "pk.nascon.league.league_app"
GRID_URL = os.environ.get("GRID_URL", "http://localhost:4444")
WEB_BASE = os.environ.get("WEB_BASE", "http://localhost:8080").rstrip("/")
API_BASE = os.environ.get("API_URL", WEB_BASE).rstrip("/")
FOREGROUND = 4  # ApplicationState.RUNNING_IN_FOREGROUND


def _appium_ready() -> bool:
    try:
        return bool(requests.get(f"{APPIUM_URL}/status", timeout=5).json()["value"]["ready"])
    except (requests.RequestException, ValueError, KeyError):
        return False


def adb(*args: str) -> str:
    cmd = ["adb"]
    if os.environ.get("ANDROID_SERIAL"):
        cmd += ["-s", os.environ["ANDROID_SERIAL"]]
    return subprocess.run(cmd + list(args), capture_output=True, text=True, timeout=30).stdout


@pytest.fixture(scope="module")
def driver():
    if shutil.which("adb") is None or not _appium_ready():
        pytest.skip(f"needs adb and Appium ready at {APPIUM_URL}")
    from appium import webdriver
    from appium.options.android import UiAutomator2Options

    options = UiAutomator2Options()
    options.platform_name = "Android"
    options.automation_name = "UiAutomator2"
    options.app_package = PACKAGE
    options.app_activity = ".MainActivity"
    options.no_reset = True
    options.auto_launch = False
    drv = webdriver.Remote(APPIUM_URL, options=options)
    yield drv
    drv.quit()


def open_link(driver, uri: str) -> float:
    """Cold-open the app on `uri` exactly like the desk audit; returns seconds until it is in the foreground."""
    driver.terminate_app(PACKAGE)
    start = time.monotonic()
    out = adb("shell", "am", "start", "-W", "-a", "android.intent.action.VIEW", "-d", uri)
    while time.monotonic() - start < 5:
        if driver.query_app_state(PACKAGE) == FOREGROUND:
            # `am start -W` reports WaitTime (ms) = intent fired -> activity drawn, measured on the device;
            # prefer it over our own clock, which also counts adb process start-up and Appium round trips.
            for line in out.splitlines():
                if line.startswith("WaitTime:"):
                    return int(line.split(":")[1]) / 1000
            return time.monotonic() - start
        time.sleep(0.05)
    pytest.fail(f"{PACKAGE} not in the foreground 5 s after {uri}")


def wait_desc(driver, text: str, timeout: float):
    from appium.webdriver.common.appiumby import AppiumBy
    from selenium.webdriver.support import expected_conditions as EC
    from selenium.webdriver.support.ui import WebDriverWait

    locator = (AppiumBy.XPATH, f'//*[contains(@content-desc, "{text}") or contains(@text, "{text}")]')
    return WebDriverWait(driver, timeout, poll_frequency=0.1).until(EC.presence_of_element_located(locator))


@pytest.mark.parametrize("uri, screen", [
    ("nascon://entity/match-m1", "Match Live"),
    ("nascon://stream/cs-session-101", "Co-Stream"),
])
def test_deeplink_opens_screen_in_foreground(driver, uri, screen):
    took = open_link(driver, uri)
    assert took <= 2.0, f"foreground after {took:.2f}s"
    # The target screen itself (not the sign-in screen) is showing: guests get read-only access.
    wait_desc(driver, screen, 2.0)


def test_cross_surface_costream_chat(driver):
    """App joins cs-session-101 while a Grid browser opens /web/costream/cs-session-101: one chat message
    reaches both surfaces within 3 s."""
    try:
        grid_ok = requests.get(f"{GRID_URL}/status", timeout=5).json()["value"]["ready"]
    except (requests.RequestException, ValueError, KeyError):
        grid_ok = False
    if not grid_ok:
        pytest.skip(f"Selenium Grid not ready at {GRID_URL}")
    from selenium import webdriver as sel
    from selenium.webdriver.support.ui import WebDriverWait

    # Start the co-stream (spec 5.4 example: 4 participants, player-alpha-1 hosting), then the app joins it.
    r = requests.post(f"{API_BASE}/audit/v1/costream/session", timeout=10, json={
        "session_id": "cs-session-101", "host_player_id": "player-alpha-1",
        "participants": ["player-alpha-1", "player-alpha-2", "player-beta-1", "player-beta-2"],
        "layout": "grid_4", "simulate_host_drop": False,
    })
    assert r.status_code in (200, 201), r.text
    open_link(driver, "nascon://stream/cs-session-101")
    wait_desc(driver, "Co-Stream", 2.0)

    options = sel.ChromeOptions()
    options.add_argument("--headless=new")
    browser = sel.Remote(command_executor=GRID_URL, options=options)
    try:
        browser.get(f"{WEB_BASE}/web/costream/cs-session-101")
        text = f"cross surface {uuid.uuid4().hex[:8]}"
        r = requests.post(f"{API_BASE}/audit/v1/moderation/test", timeout=10, json={
            "chat_room_id": "chat-cs-session-101",
            "incoming_messages": [{"message_id": f"xs-{uuid.uuid4().hex[:8]}", "sender": "player-alpha-1", "text": text}],
            "check_dlq": False,
        })
        assert r.status_code in (200, 201), r.text
        start = time.monotonic()
        WebDriverWait(browser, 3, poll_frequency=0.1).until(
            lambda b: text in b.find_element("css selector", '[data-testid="chat-message-list"]').text)
        wait_desc(driver, text, max(0.1, 3.0 - (time.monotonic() - start)))
    finally:
        browser.quit()
