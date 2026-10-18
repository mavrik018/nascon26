"""Minimal Redis client (RESP over a socket, no extra dependency) for state shared by all API worker
processes: the /api/v1 rate limiter (exact 100 requests / 10 s per IP across workers) and live counters.
Enabled when REDIS_HOST is set (docker compose); otherwise callers keep their in-process fallback."""
import os
import socket
import threading

_local = threading.local()

# Atomic sliding window: drop old hits, refuse when full (return the oldest score), else record this hit.
RATE_SCRIPT = """
local key, now, win, limit = KEYS[1], tonumber(ARGV[1]), tonumber(ARGV[2]), tonumber(ARGV[3])
redis.call('ZREMRANGEBYSCORE', key, '-inf', now - win)
if redis.call('ZCARD', key) >= limit then
  return redis.call('ZRANGE', key, 0, 0, 'WITHSCORES')[2]
end
redis.call('ZADD', key, now, ARGV[4])
redis.call('PEXPIRE', key, math.ceil(win * 1000) + 1000)
return ''
"""


def enabled() -> bool:
    return bool(os.environ.get("REDIS_HOST"))


def _sock() -> socket.socket:
    s = getattr(_local, "sock", None)
    if s is None:
        s = socket.create_connection((os.environ["REDIS_HOST"], int(os.environ.get("REDIS_PORT", "6379"))), timeout=2)
        _local.sock, _local.file = s, s.makefile("rb")
    return s


def _read(f):
    line = f.readline()
    kind, rest = line[:1], line[1:-2]
    if kind in (b"+", b":"):
        return int(rest) if kind == b":" else rest.decode()
    if kind == b"-":
        raise RuntimeError(rest.decode())
    if kind == b"$":
        n = int(rest)
        if n < 0:
            return None
        data = f.read(n + 2)[:-2]
        return data.decode()
    if kind == b"*":
        n = int(rest)
        return None if n < 0 else [_read(f) for _ in range(n)]
    raise RuntimeError(f"bad redis reply {line!r}")


def command(*args):
    payload = b"*%d\r\n" % len(args) + b"".join(
        b"$%d\r\n%s\r\n" % (len(a), a) for a in (str(x).encode() for x in args))
    for attempt in (1, 2):
        try:
            _sock().sendall(payload)
            return _read(_local.file)
        except OSError:
            _local.sock = None  # stale connection: reconnect once
            if attempt == 2:
                raise
