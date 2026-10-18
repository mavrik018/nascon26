"""Guest Web Player over Selenium Grid 4 (spec 6.2.3). Run: pytest -n 3 tests/selenium/"""
import time

from selenium.webdriver.common.by import By
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait


def tid(name: str):
    return By.CSS_SELECTOR, f'[data-testid="{name}"]'


def visible(driver, name: str, timeout: float):
    return WebDriverWait(driver, timeout, poll_frequency=0.05).until(EC.visibility_of_element_located(tid(name)))


def test_qr_resolution_zero_friction_load(driver, web):
    """Test 1: /q/m1-live redirects to the live player; video + score render within 3 s; no login modal."""
    driver.get(f"{web}/q/m1-live")
    start = time.monotonic()
    assert driver.current_url.split("?")[0].endswith("/web/matches/match-m1/live"), driver.current_url

    visible(driver, "guest-video-player", 3)
    banner = visible(driver, "live-score-banner", 3)
    WebDriverWait(driver, 3, poll_frequency=0.05).until(lambda d: " - " in banner.text)
    assert time.monotonic() - start <= 3.0

    assert driver.find_element(*tid("guest-video-player")).tag_name == "video"
    assert not driver.find_element(*tid("progressive-auth-modal")).is_displayed()


def test_guest_write_block_opens_progressive_modal(driver, web, uid):
    """Test 2: a guest's chat send is rejected (403): message not appended, auth modal shown."""
    driver.get(f"{web}/web/matches/match-m1/live")
    visible(driver, "chat-input-field", 5)
    assert not driver.find_element(*tid("progressive-auth-modal")).is_displayed()

    text = f"guest says hi {uid}"
    driver.find_element(*tid("chat-input-field")).send_keys(text)
    driver.find_element(*tid("chat-send-btn")).click()

    visible(driver, "progressive-auth-modal", 3)
    time.sleep(1.2)  # one chat poll later the message must still be absent (the server refused it)
    assert text not in driver.find_element(*tid("chat-message-list")).text


def test_guest_cart_staging_and_realtime_score(driver, web, api, uid):
    """Test 3: add to guest cart -> count "1"; score event via /audit/v1/events -> banner updates <= 500 ms."""
    driver.get(f"{web}/web/matches/match-m1/live")
    visible(driver, "pinned-merch-card", 5)
    count = driver.find_element(*tid("guest-cart-count"))
    assert count.text == "0"
    driver.find_element(*tid("add-to-guest-cart-btn")).click()
    WebDriverWait(driver, 2, poll_frequency=0.05).until(lambda d: count.text == "1")

    match = api.get(f"{api.base}/api/v1/public/matches/match-m1", timeout=10).json()
    banner = driver.find_element(*tid("live-score-banner"))
    WebDriverWait(driver, 3, poll_frequency=0.05).until(lambda d: " - " in banner.text)
    before = banner.text
    time.sleep(0.5)  # let the SSE stream connect before the event is posted

    r = api.post(f"{api.base}/audit/v1/events", timeout=10, json={
        "event_id": f"sel-goal-{uid}", "match_id": "match-m1", "type": "score",
        "payload": {"team_id": match["home"]["team_id"], "event_type": "goal"},
    })
    assert r.status_code in (200, 201), r.text
    WebDriverWait(driver, 0.5, poll_frequency=0.02).until(lambda d: banner.text != before)
