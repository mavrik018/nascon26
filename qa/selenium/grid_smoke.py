"""Selenium Grid 4 smoke test: drives Chrome through the Grid against the backend's web surfaces
(Swagger UI at /docs and the /health probe).

Start the Grid first (one terminal):
    java -jar C:\\tools\\selenium\\selenium-server-4.51.0.jar standalone --port 4444
Then:
    python qa/selenium/grid_smoke.py            # GRID_URL / API_URL env vars override the defaults
"""
import json
import os
import pathlib

from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait

GRID_URL = os.environ.get("GRID_URL", "http://localhost:4444")
API_URL = os.environ.get("API_URL", "http://localhost:8080")
OUT = pathlib.Path(__file__).with_name("screenshots")


def main() -> None:
    options = webdriver.ChromeOptions()
    options.add_argument("--headless=new")
    options.add_argument("--window-size=1280,900")
    driver = webdriver.Remote(command_executor=GRID_URL, options=options)
    try:
        # 1. Health probe (spec 5.4): the browser sees exactly {"status": "ok"}.
        driver.get(f"{API_URL}/health")
        body = json.loads(driver.find_element(By.TAG_NAME, "body").text)
        assert body == {"status": "ok"}, body

        # 2. Swagger UI lists the autograder routes.
        driver.get(f"{API_URL}/docs")
        WebDriverWait(driver, 20).until(EC.presence_of_element_located((By.CSS_SELECTOR, ".opblock")))
        page = driver.page_source
        for route in ("/audit/v1/reset", "/audit/v1/checkout", "/api/v1/auth/login"):
            assert route in page, f"{route} missing from /docs"

        OUT.mkdir(exist_ok=True)
        driver.save_screenshot(str(OUT / "docs.png"))
        print(f"PASS  Selenium Grid {driver.capabilities.get('browserName')} "
              f"{driver.capabilities.get('browserVersion')} via {GRID_URL}: /health ok, /docs lists audit routes")
    finally:
        driver.quit()


if __name__ == "__main__":
    main()
