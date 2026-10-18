FROM python:3.12-slim

WORKDIR /code
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

COPY requirements.txt .
RUN pip install --no-cache-dir --default-timeout=120 --retries 10 -r requirements.txt

COPY app ./app

EXPOSE 8080
# Several workers: NFR-2 (550 concurrent users). Shared state (rate limit, WS count) lives in Redis/Postgres.
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port 8080 --workers ${API_WORKERS:-4} --backlog 4096"]
