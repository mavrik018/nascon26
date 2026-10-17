#!/usr/bin/env bash
# Runs the whole test suite in-process (FastAPI TestClient) against a throwaway
# PostgreSQL 16 container, measures line coverage per backend area and prints it
# in the COVERAGE.json format (tools/coverage_report.py).
#
#   ./run_tests.sh                      # all tests + coverage
#   ./run_tests.sh tests/test_store.py  # extra args go to pytest
#   API_URL=http://localhost:8080 python -m pytest   # same tests against a running compose stack
set -euo pipefail
cd "$(dirname "$0")"

PY="$(command -v python3 || command -v python)"
PG=league-test-db
PORT="${TEST_PG_PORT:-55433}"

docker rm -f "$PG" >/dev/null 2>&1 || true
docker run -d --rm --name "$PG" -p "$PORT:5432" \
  -e POSTGRES_USER=league -e POSTGRES_PASSWORD=test -e POSTGRES_DB=league postgres:16-alpine >/dev/null
trap 'docker rm -f "$PG" >/dev/null 2>&1 || true' EXIT
until docker exec "$PG" pg_isready -h 127.0.0.1 -U league >/dev/null 2>&1; do sleep 1; done

"$PY" -m pip install -q -r tests/requirements.txt
export TEST_DATABASE_URL="postgresql://league:test@localhost:$PORT/league"
export DAY1_SALT="${DAY1_SALT:-test-salt}"
mkdir -p reports
"$PY" -m pytest --cov=app --cov-report=term --cov-report=json:reports/coverage.json "$@"
"$PY" tools/coverage_report.py reports/coverage.json
