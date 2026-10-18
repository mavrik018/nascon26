"""Order matters: reset() runs in this order (later modules may reference earlier tables)."""
from . import core, sports, fixtures, scoring, standings, roster, store, rbac, sync, schedule, competitions
from . import day2, streaming, costream, qr_guest, moderation_dlq, observability, realtime, web, social

MODULES = [core, sports, fixtures, scoring, standings, roster, store, rbac, sync, schedule, competitions,
           day2, streaming, costream, qr_guest, moderation_dlq, observability, realtime, web, social]
