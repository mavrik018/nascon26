"""Order matters: reset() runs in this order (later modules may reference earlier tables)."""
from . import core, sports, fixtures, scoring, standings, roster, store, rbac, sync, schedule, competitions

MODULES = [core, sports, fixtures, scoring, standings, roster, store, rbac, sync, schedule, competitions]
