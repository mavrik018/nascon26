# Multi-Sport League & Club Operations Platform — NaSCon '26 Part I

Self-hosted backend (FastAPI + PostgreSQL 16, Docker Compose) and a Flutter Android app.

## Run

```bash
DAY1_SALT=<team-salt> docker compose up -d --build
```

API on `http://localhost:8080` (`GET /health` → `{"status":"ok"}` once the baseline is seeded).
`DAY1_SALT` is read only from the environment; see `.env.example` for all variables.

## Tests

```bash
./run_tests.sh
```

## Demo accounts (password for all: `Nascon@26`)

| Role | Email |
|---|---|
| Platform Super-Admin | admin@nascon.test |
| League Organizer (league-alpha-1) | organizer@nascon.test |
| Club Manager (club-alpha-1) | manager@nascon.test |
| Player (player-alpha-1) | player@nascon.test |
| General Viewer | viewer@nascon.test |

## Mobile

Source in `mobile/`, release build at `mobile/release/app-release.apk` (Android 10+).
The backend address is set in the app's Settings screen (emulator `http://10.0.2.2:8080`, phone: laptop LAN IP).
