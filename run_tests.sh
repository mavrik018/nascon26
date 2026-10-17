#!/usr/bin/env bash
# Start the stack from scratch and run the full test suite against it.
#   ./run_tests.sh          (API_URL overrides the target, default http://localhost:8080)
set -euo pipefail
cd "$(dirname "$0")"

docker compose up -d --build --wait --wait-timeout 180
python -m pip install -q -r tests/requirements.txt
python -m pytest "$@"
