import pathlib

import pytest

REPORT = pathlib.Path(__file__).resolve().parents[1] / "reports" / "appium-report.xml"


@pytest.hookimpl(tryfirst=True)
def pytest_configure(config):
    if not getattr(config.option, "xmlpath", None):
        REPORT.parent.mkdir(parents=True, exist_ok=True)
        config.option.xmlpath = str(REPORT)
