"""Turn a coverage.py JSON report into the six per-area line-coverage figures of spec 9.3.

    python tools/coverage_report.py reports/coverage.json            # print
    python tools/coverage_report.py reports/coverage.json --write    # also write COVERAGE.json

Each area is the module(s) implementing it; the figure is covered lines / statements,
rounded DOWN to one decimal so the declared value never exceeds the measured one."""
import json
import math
import sys
from pathlib import Path

AREAS = {
    "fixtures": ["fixtures.py"],
    "scoring": ["scoring.py", "sports.py"],
    "standings": ["standings.py"],
    "store": ["store.py"],
    "roster": ["roster.py"],
    "rbac": ["rbac.py"],
}

# Part II 7.2: the five Phase II modules  (--day2 writes COVERAGE_DAY2.json).
AREAS_DAY2 = {
    "streaming": ["streaming.py", "recording.py"],
    "costream": ["costream.py", "hostctl.py"],
    "qr_guest": ["qr_guest.py"],
    "moderation_dlq": ["moderation_dlq.py", "notify.py"],
    "observability": ["observability.py"],
}


def area_coverage(report: dict, areas: dict = AREAS) -> dict:
    files = {Path(name).name: data["summary"] for name, data in report["files"].items()
             if "modules" in Path(name).parts}
    result = {}
    for area, names in areas.items():
        statements = sum(files[n]["num_statements"] for n in names if n in files)
        covered = sum(files[n]["covered_lines"] for n in names if n in files)
        result[area] = math.floor(1000 * covered / statements) / 10 if statements else 0.0
    return result


if __name__ == "__main__":
    report = json.loads(Path(sys.argv[1]).read_text())
    day2 = "--day2" in sys.argv
    figures = area_coverage(report, AREAS_DAY2 if day2 else AREAS)
    print(json.dumps(figures))
    if "--write" in sys.argv or day2:
        name = "COVERAGE_DAY2.json" if day2 else "COVERAGE.json"
        Path(__file__).resolve().parents[1].joinpath(name).write_text(json.dumps(figures, indent=2) + "\n")
