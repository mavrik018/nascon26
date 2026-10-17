"""Spec 5.7: POST /audit/v1/fixtures -- schedule and bracket generation.

Pure computation: nothing is stored. Four formats, each a pure function that
takes (teams, params) and returns the response dict, so they can be unit
tested without HTTP:

* generate_round_robin  -- circle method, 1 or 2 legs, byes, withdrawals
* generate_swiss        -- one round per call, exact minimum-cost pairing
                           (Edmonds' blossom maximum-weight matching)
* generate_single_elim  -- seeded bracket with byes, results, third place
* generate_double_elim  -- winners/losers/grand final with bracket reset

All algorithms are written here by hand (no third-party fixture libraries).
"""
import math

from fastapi import APIRouter, Request

from ..errors import ApiError, validation
from .util import is_id, is_int, read_json

router = APIRouter()

SCHEMA = ""  # pure computation: no tables


def reset(conn, seed: int, body: dict) -> None:
    """Nothing to reset: this module stores no state."""


FORMATS = ("round_robin", "swiss", "single_elim", "double_elim")
TEAM_LIMITS = {"round_robin": (2, 40), "swiss": (2, 64), "single_elim": (2, 128), "double_elim": (3, 128)}


@router.post("/audit/v1/fixtures")
async def fixtures(request: Request):
    body = await read_json(request)
    return generate(body)


def generate(body) -> dict:
    """Validate the envelope {format, teams, params} and dispatch to the format."""
    if not isinstance(body, dict):
        raise validation("body")
    fmt, teams, params = body.get("format"), body.get("teams"), body.get("params")
    bad = []
    if fmt not in FORMATS:
        bad.append("format")
    if (not isinstance(teams, list) or not all(is_id(t) for t in teams)
            or len(set(teams)) != len(teams)
            or (fmt in FORMATS and not TEAM_LIMITS[fmt][0] <= len(teams) <= TEAM_LIMITS[fmt][1])):
        bad.append("teams")
    if params is None:
        params = {}
    elif not isinstance(params, dict):
        bad.append("params")
    if bad:
        raise validation(bad)
    # An explicit null for an optional parameter means "use the default".
    params = {k: v for k, v in params.items() if v is not None}
    return GENERATORS[fmt](list(teams), params)


# --------------------------------------------------------------------------- #
# A) Round robin                                                              #
# --------------------------------------------------------------------------- #

def circle_rounds(teams: list) -> list[list[tuple]]:
    """One leg of the circle method. Returns rounds of (home, away) pairs where
    None stands for the bye. One slot stays fixed, the others rotate by one.

    Home/away: the pair on the fixed slot alternates by round; every other pair
    puts the top-row team at home. A rotating team visits each top-row and
    bottom-row position once, so its home/away counts differ by at most one.
    For odd n the dummy (bye) is the fixed slot, so every real team's game
    "against the fixed slot" is exactly its one bye and its counts are equal.
    """
    slots = ([None] + teams) if len(teams) % 2 else list(teams)
    m = len(slots)
    rounds = []
    for r in range(m - 1):
        pairs = []
        for i in range(m // 2):
            home, away = slots[i], slots[m - 1 - i]
            if i == 0 and r % 2 == 1:
                home, away = away, home
            pairs.append((home, away))
        rounds.append(pairs)
        slots = [slots[0], slots[-1]] + slots[1:-1]  # rotate all but the fixed slot
    return rounds


def generate_round_robin(teams: list, params: dict) -> dict:
    legs = params.get("legs", 1)
    withdrawals = params.get("withdrawals", [])
    policy = params.get("withdrawal_policy", "forfeit_remaining")
    n = len(teams)
    per_leg = n - 1 if n % 2 == 0 else n
    bad = []
    if not is_int(legs) or legs not in (1, 2):
        bad.append("params.legs")
    if policy not in ("forfeit_remaining", "void_all"):
        bad.append("params.withdrawal_policy")
    round_count = per_leg * (legs if legs in (1, 2) and is_int(legs) else 1)
    withdrawn = {}  # team_id -> after_round
    if not isinstance(withdrawals, list):
        bad.append("params.withdrawals")
    else:
        for w in withdrawals:
            if (not isinstance(w, dict) or w.get("team_id") not in teams or w["team_id"] in withdrawn
                    or not is_int(w.get("after_round"), 0, round_count)):
                bad.append("params.withdrawals")
                break
            withdrawn[w["team_id"]] = w["after_round"]
    if bad:
        raise validation(bad)

    leg_rounds = circle_rounds(teams)
    rounds, summary = [], {"total": 0, "scheduled": 0, "forfeit": 0, "voided": 0}
    for leg in range(1, legs + 1):
        for r, pairs in enumerate(leg_rounds, start=1 + (leg - 1) * per_leg):
            matches, byes = [], []
            for home, away in pairs:
                if leg == 2:
                    home, away = away, home
                if home is None or away is None:
                    byes.append(home or away)
                    continue
                status, awarded = _withdrawal_status(home, away, r, withdrawn, policy)
                matches.append({"match_id": f"RR-L{leg}-R{r}-M{len(matches) + 1}", "leg": leg,
                                "home": home, "away": away, "status": status, "awarded_to": awarded})
                summary["total"] += 1
                summary[status] += 1
            rounds.append({"round": r, "matches": matches, "byes": byes})
    return {"format": "round_robin", "legs": legs, "team_count": n, "round_count": round_count,
            "rounds": rounds, "summary": summary}


def _withdrawal_status(home, away, rnd, withdrawn, policy):
    """forfeit_remaining: a team is out for rounds > after_round; one side out ->
    forfeit to the other, both out -> voided. void_all: any fixture of a
    withdrawn team is voided."""
    if policy == "void_all":
        out_home, out_away = home in withdrawn, away in withdrawn
    else:
        out_home = home in withdrawn and rnd > withdrawn[home]
        out_away = away in withdrawn and rnd > withdrawn[away]
    if out_home and out_away or (policy == "void_all" and (out_home or out_away)):
        return "voided", None
    if out_home:
        return "forfeit", away
    if out_away:
        return "forfeit", home
    return "scheduled", None


# --------------------------------------------------------------------------- #
# B) Swiss                                                                    #
# --------------------------------------------------------------------------- #

RESULT_POINTS = {"home": (2, 0), "away": (0, 2), "draw": (1, 1)}  # in half points


def generate_swiss(teams: list, params: dict) -> dict:
    n = len(teams)
    total_rounds = params.get("total_rounds", math.ceil(math.log2(n)))
    rnd = params.get("round", 1)
    history = params.get("history", [])
    bad = []
    if not is_int(total_rounds, 1, n - 1):
        bad.append("params.total_rounds")
    elif not is_int(rnd, 1, total_rounds):
        bad.append("params.round")
    if not bad and not _valid_history(history, teams, rnd):
        bad.append("params.history")
    if bad:
        raise validation(bad)

    seed = {t: i for i, t in enumerate(teams)}
    score = {t: 0 for t in teams}  # half points, so all arithmetic is exact
    opponents = {t: [] for t in teams}
    had_bye = set()
    for h in history:
        for m in h["matches"]:
            ph, pa = RESULT_POINTS[m["result"]]
            score[m["home"]] += ph
            score[m["away"]] += pa
            opponents[m["home"]].append(m["away"])
            opponents[m["away"]].append(m["home"])
        if h.get("bye") is not None:
            score[h["bye"]] += 2
            had_bye.add(h["bye"])
    buchholz = {t: sum(score[o] for o in opponents[t]) for t in teams}
    ranked = sorted(teams, key=lambda t: (-score[t], -buchholz[t], seed[t]))
    standings = [{"rank": i + 1, "team_id": t, "score": score[t] / 2, "buchholz": buchholz[t] / 2}
                 for i, t in enumerate(ranked)]

    if rnd == 1:
        pairs, bye = _swiss_round_one(teams)
    else:
        played = {(a, b) for a in teams for b in opponents[a]}
        pairs, bye = _swiss_pair(ranked, seed, score, played, had_bye)
        if pairs is None:
            raise ApiError(409, "NO_VALID_PAIRING", f"No rematch-free pairing exists for round {rnd}",
                           {"round": rnd})
    pairings = [{"match_id": f"SW-R{rnd}-M{i}", "home": h, "away": a} for i, (h, a) in enumerate(pairs, 1)]
    return {"format": "swiss", "round": rnd, "total_rounds": total_rounds,
            "pairings": pairings, "bye": bye, "standings": standings}


def _valid_history(history, teams, rnd) -> bool:
    """history must hold exactly rounds 1..rnd-1; each team at most once per round."""
    if not isinstance(history, list) or not all(isinstance(h, dict) for h in history):
        return False
    if sorted(h.get("round") if is_int(h.get("round")) else -1 for h in history) != list(range(1, rnd)):
        return False
    known = set(teams)
    for h in history:
        matches, bye = h.get("matches"), h.get("bye")
        if not isinstance(matches, list) or (bye is not None and not _member(bye, known)):
            return False
        seen = [bye] if bye is not None else []
        for m in matches:
            if (not isinstance(m, dict) or not _member(m.get("home"), known)
                    or not _member(m.get("away"), known) or not _member(m.get("result"), RESULT_POINTS)):
                return False
            seen += [m["home"], m["away"]]
        if len(seen) != len(set(seen)):
            return False
    return True


def _member(value, collection) -> bool:
    """Membership test that is safe for unhashable JSON values (lists, objects)."""
    return isinstance(value, str) and value in collection


def _swiss_round_one(teams):
    """Exact: m = n // 2, seed i meets seed i + m (lower seed at home); odd n -> last seed bye."""
    m = len(teams) // 2
    pairs = [(teams[i], teams[i + m]) for i in range(m)]
    return pairs, (teams[-1] if len(teams) % 2 else None)


def _swiss_pair(ranked, seed, score, played, had_bye):
    """Rounds >= 2. Odd n: try bye candidates (lowest score first, ties -> largest
    seed index) until the rest has a rematch-free pairing. Returns (pairs, bye)
    or (None, None) if no candidate works."""
    if len(ranked) % 2 == 0:
        candidates = [None]
    else:
        pool = [t for t in ranked if t not in had_bye] or list(ranked)
        candidates = sorted(pool, key=lambda t: (score[t], -seed[t]))
    for bye in candidates:
        rest = [t for t in ranked if t != bye]
        pairs = min_cost_pairing(rest, score, played)
        if pairs is not None:
            rank = {t: i for i, t in enumerate(ranked)}
            pairs = sorted(((a, b) if rank[a] < rank[b] else (b, a) for a, b in pairs), key=lambda p: rank[p[0]])
            return pairs, bye
    return None, None


def min_cost_pairing(order: list, score: dict, played: set):
    """Exact minimum of sum |score difference| over all rematch-free perfect
    pairings of `order`. Returns a list of pairs, or None if none exists.

    Reduction to maximum-weight matching: every allowed (not yet played) pair
    gets weight W - |score difference| with W larger than any difference.
    Among maximum-cardinality matchings, maximum weight = (n/2)*W - cost, so
    the result minimises the cost. If the maximum cardinality is below n/2
    there is no complete rematch-free pairing. Greedy pairing is not enough
    (it can get stuck); Edmonds' blossom algorithm is exact and O(n^3).
    """
    n = len(order)
    s = [score[t] for t in order]
    big = max(s) - min(s) + 1
    edges = [(i, j, big - abs(s[i] - s[j])) for i in range(n) for j in range(i + 1, n)
             if (order[i], order[j]) not in played]
    mate = max_weight_matching(edges, n)
    pairs = [(order[i], order[mate[i]]) for i in range(n) if mate[i] > i]
    return pairs if 2 * len(pairs) == n else None


def max_weight_matching(edges, nvertex):
    """Edmonds' blossom algorithm, maximum-weight matching, O(n^3), primal-dual.

    edges: list of (i, j, w) with integer w and vertices 0..nvertex-1.
    Returns, among the matchings of maximum size (maximum cardinality), one of
    maximum weight. Returns mate[v] (-1 if unmatched).

    Vocabulary: blossoms are odd cycles shrunk into one node; S/T labels
    (1/2) mark outer/inner nodes of the alternating trees; dualvar holds the
    LP dual of each vertex/blossom; an edge is "tight" when its slack is 0.
    Edge k has endpoints 2k (= edges[k][0]) and 2k+1 (= edges[k][1]).
    """
    if not edges:
        return [-1] * nvertex
    edges = [(i, j, 2 * w) for i, j, w in edges]  # doubled: keeps every dual update integral
    nedge = len(edges)
    maxweight = max(0, max(w for _, _, w in edges))
    endpoint = [edges[p // 2][p % 2] for p in range(2 * nedge)]
    neighbend = [[] for _ in range(nvertex)]
    for k, (i, j, _) in enumerate(edges):
        neighbend[i].append(2 * k + 1)
        neighbend[j].append(2 * k)
    mate = [-1] * nvertex                     # remote endpoint of matched edge
    label = [0] * (2 * nvertex)               # 0 free, 1 S (outer), 2 T (inner)
    labelend = [-1] * (2 * nvertex)
    inblossom = list(range(nvertex))          # top-level blossom of each vertex
    blossomparent = [-1] * (2 * nvertex)
    blossomchilds = [None] * (2 * nvertex)
    blossombase = list(range(nvertex)) + [-1] * nvertex
    blossomendps = [None] * (2 * nvertex)
    bestedge = [-1] * (2 * nvertex)
    blossombestedges = [None] * (2 * nvertex)
    unusedblossoms = list(range(nvertex, 2 * nvertex))
    dualvar = [maxweight] * nvertex + [0] * nvertex
    allowedge = [False] * nedge
    queue = []

    def slack(k):
        i, j, w = edges[k]
        return dualvar[i] + dualvar[j] - 2 * w

    def leaves(b):
        if b < nvertex:
            yield b
        else:
            for t in blossomchilds[b]:
                yield from leaves(t)

    def assign_label(w, t, p):
        b = inblossom[w]
        label[w] = label[b] = t
        labelend[w] = labelend[b] = p
        bestedge[w] = bestedge[b] = -1
        if t == 1:
            queue.extend(leaves(b))
        else:
            base = blossombase[b]
            assign_label(endpoint[mate[base]], 1, mate[base] ^ 1)

    def scan_blossom(v, w):
        """Trace back from v and w; return the common base (new blossom) or -1 (augmenting path)."""
        path, base = [], -1
        while v != -1 or w != -1:
            b = inblossom[v]
            if label[b] & 4:
                base = blossombase[b]
                break
            path.append(b)
            label[b] = 5
            if labelend[b] == -1:
                v = -1
            else:
                v = endpoint[labelend[b]]
                b = inblossom[v]
                v = endpoint[labelend[b]]
            if w != -1:
                v, w = w, v
        for b in path:
            label[b] = 1
        return base

    def add_blossom(base, k):
        v, w, _ = edges[k]
        bb, bv, bw = inblossom[base], inblossom[v], inblossom[w]
        b = unusedblossoms.pop()
        blossombase[b] = base
        blossomparent[b] = -1
        blossomparent[bb] = b
        blossomchilds[b] = path = []
        blossomendps[b] = endps = []
        while bv != bb:
            blossomparent[bv] = b
            path.append(bv)
            endps.append(labelend[bv])
            v = endpoint[labelend[bv]]
            bv = inblossom[v]
        path.append(bb)
        path.reverse()
        endps.reverse()
        endps.append(2 * k)
        while bw != bb:
            blossomparent[bw] = b
            path.append(bw)
            endps.append(labelend[bw] ^ 1)
            w = endpoint[labelend[bw]]
            bw = inblossom[w]
        label[b] = 1
        labelend[b] = labelend[bb]
        dualvar[b] = 0
        for v in leaves(b):
            if label[inblossom[v]] == 2:
                queue.append(v)
            inblossom[v] = b
        bestedgeto = [-1] * (2 * nvertex)
        for bv in path:
            if blossombestedges[bv] is None:
                nblists = [[p // 2 for p in neighbend[v]] for v in leaves(bv)]
            else:
                nblists = [blossombestedges[bv]]
            for nblist in nblists:
                for k in nblist:
                    i, j, _ = edges[k]
                    if inblossom[j] == b:
                        i, j = j, i
                    bj = inblossom[j]
                    if bj != b and label[bj] == 1 and (bestedgeto[bj] == -1 or slack(k) < slack(bestedgeto[bj])):
                        bestedgeto[bj] = k
            blossombestedges[bv] = None
            bestedge[bv] = -1
        blossombestedges[b] = [k for k in bestedgeto if k != -1]
        bestedge[b] = -1
        for k in blossombestedges[b]:
            if bestedge[b] == -1 or slack(k) < slack(bestedge[b]):
                bestedge[b] = k

    def expand_blossom(b, endstage):
        for s in blossomchilds[b]:
            blossomparent[s] = -1
            if s < nvertex:
                inblossom[s] = s
            elif endstage and dualvar[s] == 0:
                expand_blossom(s, endstage)
            else:
                for v in leaves(s):
                    inblossom[v] = s
        if not endstage and label[b] == 2:
            entrychild = inblossom[endpoint[labelend[b] ^ 1]]
            j = blossomchilds[b].index(entrychild)
            if j & 1:
                j -= len(blossomchilds[b])
                jstep, endptrick = 1, 0
            else:
                jstep, endptrick = -1, 1
            p = labelend[b]
            while j != 0:
                label[endpoint[p ^ 1]] = 0
                label[endpoint[blossomendps[b][j - endptrick] ^ endptrick ^ 1]] = 0
                assign_label(endpoint[p ^ 1], 2, p)
                allowedge[blossomendps[b][j - endptrick] // 2] = True
                j += jstep
                p = blossomendps[b][j - endptrick] ^ endptrick
                allowedge[p // 2] = True
                j += jstep
            bv = blossomchilds[b][j]
            label[endpoint[p ^ 1]] = label[bv] = 2
            labelend[endpoint[p ^ 1]] = labelend[bv] = p
            bestedge[bv] = -1
            j += jstep
            while blossomchilds[b][j] != entrychild:
                bv = blossomchilds[b][j]
                if label[bv] == 1:
                    j += jstep
                    continue
                for v in leaves(bv):
                    if label[v] != 0:
                        break
                if label[v] != 0:
                    label[v] = 0
                    label[endpoint[mate[blossombase[bv]]]] = 0
                    assign_label(v, 2, labelend[v])
                j += jstep
        label[b] = labelend[b] = -1
        blossomchilds[b] = blossomendps[b] = None
        blossombase[b] = -1
        blossombestedges[b] = None
        bestedge[b] = -1
        unusedblossoms.append(b)

    def augment_blossom(b, v):
        t = v
        while blossomparent[t] != b:
            t = blossomparent[t]
        if t >= nvertex:
            augment_blossom(t, v)
        i = j = blossomchilds[b].index(t)
        if i & 1:
            j -= len(blossomchilds[b])
            jstep, endptrick = 1, 0
        else:
            jstep, endptrick = -1, 1
        while j != 0:
            j += jstep
            t = blossomchilds[b][j]
            p = blossomendps[b][j - endptrick] ^ endptrick
            if t >= nvertex:
                augment_blossom(t, endpoint[p])
            j += jstep
            t = blossomchilds[b][j]
            if t >= nvertex:
                augment_blossom(t, endpoint[p ^ 1])
            mate[endpoint[p]] = p ^ 1
            mate[endpoint[p ^ 1]] = p
        blossomchilds[b] = blossomchilds[b][i:] + blossomchilds[b][:i]
        blossomendps[b] = blossomendps[b][i:] + blossomendps[b][:i]
        blossombase[b] = blossombase[blossomchilds[b][0]]

    def augment_matching(k):
        v, w, _ = edges[k]
        for s, p in ((v, 2 * k + 1), (w, 2 * k)):
            while True:
                bs = inblossom[s]
                if bs >= nvertex:
                    augment_blossom(bs, s)
                mate[s] = p
                if labelend[bs] == -1:
                    break
                t = endpoint[labelend[bs]]
                bt = inblossom[t]
                s = endpoint[labelend[bt]]
                j = endpoint[labelend[bt] ^ 1]
                if bt >= nvertex:
                    augment_blossom(bt, j)
                mate[j] = labelend[bt]
                p = labelend[bt] ^ 1

    for _ in range(nvertex):  # each stage augments the matching by one edge (or stops)
        label[:] = [0] * (2 * nvertex)
        bestedge[:] = [-1] * (2 * nvertex)
        blossombestedges[nvertex:] = [None] * nvertex
        allowedge[:] = [False] * nedge
        queue[:] = []
        for v in range(nvertex):
            if mate[v] == -1 and label[inblossom[v]] == 0:
                assign_label(v, 1, -1)
        augmented = False
        while True:
            while queue and not augmented:
                v = queue.pop()
                for p in neighbend[v]:
                    k = p // 2
                    w = endpoint[p]
                    if inblossom[v] == inblossom[w]:
                        continue
                    if not allowedge[k]:
                        kslack = slack(k)
                        if kslack <= 0:
                            allowedge[k] = True
                    if allowedge[k]:
                        if label[inblossom[w]] == 0:
                            assign_label(w, 2, p ^ 1)
                        elif label[inblossom[w]] == 1:
                            base = scan_blossom(v, w)
                            if base >= 0:
                                add_blossom(base, k)
                            else:
                                augment_matching(k)
                                augmented = True
                                break
                        elif label[w] == 0:
                            label[w] = 2
                            labelend[w] = p ^ 1
                    elif label[inblossom[w]] == 1:
                        b = inblossom[v]
                        if bestedge[b] == -1 or kslack < slack(bestedge[b]):
                            bestedge[b] = k
                    elif label[w] == 0:
                        if bestedge[w] == -1 or kslack < slack(bestedge[w]):
                            bestedge[w] = k
            if augmented:
                break
            # No tight edge left to grow with: change the duals by the largest safe delta.
            deltatype, delta, deltaedge, deltablossom = -1, None, None, None
            for v in range(nvertex):
                if label[inblossom[v]] == 0 and bestedge[v] != -1:
                    d = slack(bestedge[v])
                    if deltatype == -1 or d < delta:
                        deltatype, delta, deltaedge = 2, d, bestedge[v]
            for b in range(2 * nvertex):
                if blossomparent[b] == -1 and label[b] == 1 and bestedge[b] != -1:
                    d = slack(bestedge[b]) // 2
                    if deltatype == -1 or d < delta:
                        deltatype, delta, deltaedge = 3, d, bestedge[b]
            for b in range(nvertex, 2 * nvertex):
                if (blossombase[b] >= 0 and blossomparent[b] == -1 and label[b] == 2
                        and (deltatype == -1 or dualvar[b] < delta)):
                    deltatype, delta, deltablossom = 4, dualvar[b], b
            if deltatype == -1:
                deltatype, delta = 1, max(0, min(dualvar[:nvertex]))
            for v in range(nvertex):
                if label[inblossom[v]] == 1:
                    dualvar[v] -= delta
                elif label[inblossom[v]] == 2:
                    dualvar[v] += delta
            for b in range(nvertex, 2 * nvertex):
                if blossombase[b] >= 0 and blossomparent[b] == -1:
                    if label[b] == 1:
                        dualvar[b] += delta
                    elif label[b] == 2:
                        dualvar[b] -= delta
            if deltatype == 1:
                break
            if deltatype == 2:
                allowedge[deltaedge] = True
                i, j, _ = edges[deltaedge]
                if label[inblossom[i]] == 0:
                    i, j = j, i
                queue.append(i)
            elif deltatype == 3:
                allowedge[deltaedge] = True
                i, j, _ = edges[deltaedge]
                queue.append(i)
            else:
                expand_blossom(deltablossom, False)
        if not augmented:
            break
        for b in range(nvertex, 2 * nvertex):
            if blossomparent[b] == -1 and blossombase[b] >= 0 and label[b] == 1 and dualvar[b] == 0:
                expand_blossom(b, True)
    return [endpoint[m] if m >= 0 else -1 for m in mate]


# --------------------------------------------------------------------------- #
# C/D) Elimination brackets                                                   #
# --------------------------------------------------------------------------- #

def seed_order(size: int) -> list[int]:
    """order(2) = [1, 2]; order(2k) = for s in order(k): [s, 2k + 1 - s]."""
    order = [1, 2]
    while len(order) < size:
        k2 = len(order) * 2
        order = [x for s in order for x in (s, k2 + 1 - s)]
    return order


def bracket_size(n: int) -> int:
    size = 2
    while size < n:
        size *= 2
    return size


class Bracket:
    """Matches plus the routing graph. Teams flow along winner_to / loser_to.

    A slot is "dead" when it can never receive a team (fed by a bye's loser, or
    by a match that is itself dead). A losers-bracket match with one live team
    and one dead slot is a bye: its team advances at once.
    """

    def __init__(self, teams: list):
        self.teams = teams
        self.seed = {t: i + 1 for i, t in enumerate(teams)}
        self.matches = {}  # match_id -> MATCH dict (insertion order = output order)
        self.feeds = {}    # (match_id, slot) -> (source match_id, "winner" | "loser")

    def add(self, match_id, bracket, rnd, index):
        self.matches[match_id] = {
            "match_id": match_id, "bracket": bracket, "round": rnd, "index": index,
            "home": None, "away": None, "home_seed": None, "away_seed": None, "bye": False,
            "winner": None, "loser": None, "winner_to": None, "loser_to": None}
        return self.matches[match_id]

    def route(self, src, kind, dst, slot):
        """kind 'winner' or 'loser' of match src goes into dst's slot."""
        self.matches[src][f"{kind}_to"] = {"match_id": dst, "slot": slot}
        self.feeds[(dst, slot)] = (src, kind)

    def place(self, match_id, slot, team):
        m = self.matches[match_id]
        m[slot] = team
        m[f"{slot}_seed"] = self.seed.get(team) if team is not None else None

    def seed_first_round(self, prefix):
        """Exact seeding: round-1 match i takes entries 2i-1 and 2i of order(B);
        a seed > n is missing, which makes the match a bye for the present team."""
        size = bracket_size(len(self.teams))
        order = seed_order(size)
        for i in range(size // 2):
            match_id = f"{prefix}1M{i + 1}"
            for slot, s in (("home", order[2 * i]), ("away", order[2 * i + 1])):
                if s <= len(self.teams):
                    self.place(match_id, slot, self.teams[s - 1])
            if self.matches[match_id]["away"] is None:
                self.matches[match_id]["bye"] = True
                self.decide(match_id, self.matches[match_id]["home"])

    def decide(self, match_id, winner):
        m = self.matches[match_id]
        loser = m["away"] if winner == m["home"] else m["home"]
        m["winner"], m["loser"] = winner, loser
        for kind, team in (("winner", winner), ("loser", loser)):
            target = m[f"{kind}_to"]
            if target is not None and team is not None:
                self.place(target["match_id"], target["slot"], team)

    def slot_dead(self, match_id, slot) -> bool:
        if self.matches[match_id][slot] is not None:
            return False
        src = self.feeds.get((match_id, slot))
        if src is None:
            return True
        src_id, kind = src
        return self.match_dead(src_id) or (kind == "loser" and self.matches[src_id]["bye"])

    def match_dead(self, match_id) -> bool:
        return self.slot_dead(match_id, "home") and self.slot_dead(match_id, "away")

    def auto_byes(self, bracket):
        """Advance a lone team when the opposite slot can never be filled."""
        changed = True
        while changed:
            changed = False
            for mid, m in self.matches.items():
                if m["bracket"] != bracket or m["winner"] is not None:
                    continue
                for slot, other in (("home", "away"), ("away", "home")):
                    if m[slot] is not None and self.slot_dead(mid, other):
                        m["bye"] = True
                        self.decide(mid, m[slot])
                        changed = True
                        break

    def apply_result(self, result):
        """One params.results item: winner must be a participant of a playable match."""
        if not isinstance(result, dict) or not _member(result.get("match_id"), self.matches):
            raise validation("params.results", "Unknown match_id in results")
        m = self.matches[result["match_id"]]
        winner = result.get("winner")
        playable = (m["home"] is not None and m["away"] is not None) or m["bye"]
        if not playable or not isinstance(winner, str) or winner not in (m["home"], m["away"]):
            raise validation("params.results", "Winner is not a participant of that match")
        self.decide(result["match_id"], winner)


def _bool_param(params, key, bad):
    value = params.get(key, False)
    if not isinstance(value, bool):
        bad.append(f"params.{key}")
    return value


def _results_param(params, bad):
    results = params.get("results", [])
    if not isinstance(results, list):
        bad.append("params.results")
    return results


def generate_single_elim(teams: list, params: dict) -> dict:
    bad = []
    third_place = _bool_param(params, "third_place_match", bad)
    results = _results_param(params, bad)
    if bad:
        raise validation(bad)

    size = bracket_size(len(teams))
    k = size.bit_length() - 1  # number of rounds = log2(B)
    br = Bracket(teams)
    for r in range(1, k + 1):
        for i in range(1, size // 2 ** r + 1):
            br.add(f"R{r}M{i}", "main", r, i)
    for r in range(1, k):
        for i in range(1, size // 2 ** r + 1):
            br.route(f"R{r}M{i}", "winner", f"R{r + 1}M{(i + 1) // 2}", "home" if i % 2 else "away")
    if third_place and k >= 2:
        br.add("TP", "third_place", k, 1)
        br.route(f"R{k - 1}M1", "loser", "TP", "home")
        br.route(f"R{k - 1}M2", "loser", "TP", "away")
    br.seed_first_round("R")
    for result in results:
        br.apply_result(result)

    rounds = [{"round": r, "matches": [m for m in br.matches.values() if m["round"] == r]}
              for r in range(1, k + 1)]
    return {"format": "single_elim", "bracket_size": size, "rounds": rounds}


def generate_double_elim(teams: list, params: dict) -> dict:
    bad = []
    reset_on = _bool_param(params, "bracket_reset", bad)
    results = _results_param(params, bad)
    if bad:
        raise validation(bad)

    size = bracket_size(len(teams))
    k = size.bit_length() - 1
    br = Bracket(teams)
    # Winners bracket: round r has B / 2^r matches.
    for r in range(1, k + 1):
        for i in range(1, size // 2 ** r + 1):
            br.add(f"WR{r}M{i}", "winners", r, i)
    # Losers bracket: rounds 2j-1 and 2j have B / 2^(j+1) matches (total B - 2).
    lr_count = {}
    for j in range(1, k):
        for r in (2 * j - 1, 2 * j):
            lr_count[r] = size // 2 ** (j + 1)
            for i in range(1, lr_count[r] + 1):
                br.add(f"LR{r}M{i}", "losers", r, i)
    br.add("GF1", "grand_final", 1, 1).update(conditional=False, required=True)
    if reset_on:
        br.add("GF2", "grand_final", 2, 1).update(conditional=True, required=None)

    # Winners bracket advancement; WR final winner -> GF1.home.
    for r in range(1, k):
        for i in range(1, size // 2 ** r + 1):
            br.route(f"WR{r}M{i}", "winner", f"WR{r + 1}M{(i + 1) // 2}", "home" if i % 2 else "away")
    br.route(f"WR{k}M1", "winner", "GF1", "home")
    # Drop-downs: WR1 losers meet each other in LR1; WRr (r >= 2) losers enter LR(2r-2) as away.
    for i in range(1, size // 2 + 1):
        br.route(f"WR1M{i}", "loser", f"LR1M{(i + 1) // 2}", "home" if i % 2 else "away")
    for r in range(2, k + 1):
        for i in range(1, size // 2 ** r + 1):
            br.route(f"WR{r}M{i}", "loser", f"LR{2 * r - 2}M{i}", "away")
    # Losers bracket advancement: odd round -> same index next round (home);
    # even round -> halving into the next odd round; LB final winner -> GF1.away.
    last = 2 * (k - 1)
    for r in range(1, last):
        for i in range(1, lr_count[r] + 1):
            if r % 2:
                br.route(f"LR{r}M{i}", "winner", f"LR{r + 1}M{i}", "home")
            else:
                br.route(f"LR{r}M{i}", "winner", f"LR{r + 1}M{(i + 1) // 2}", "home" if i % 2 else "away")
    br.route(f"LR{last}M1", "winner", "GF1", "away")

    br.seed_first_round("WR")
    br.auto_byes("losers")
    _sync_grand_final(br, reset_on)
    for result in results:
        br.apply_result(result)
        br.auto_byes("losers")
        _sync_grand_final(br, reset_on)

    def rounds_of(bracket):
        nums = sorted({m["round"] for m in br.matches.values() if m["bracket"] == bracket})
        return [{"round": r, "matches": [m for m in br.matches.values()
                                         if m["bracket"] == bracket and m["round"] == r]} for r in nums]

    return {"format": "double_elim", "bracket_size": size, "bracket_reset": reset_on,
            "winners": rounds_of("winners"), "losers": rounds_of("losers"),
            "grand_final": [m for m in br.matches.values() if m["bracket"] == "grand_final"]}


def _sync_grand_final(br: Bracket, reset_on: bool):
    """GF2 is the bracket-reset rematch: same two teams, same sides as GF1.
    GF1's winner and loser both route into GF2 (each keeps its side), and
    GF2.required is null until GF1 is decided, then true iff the losers-bracket
    champion (GF1.away) won GF1."""
    if not reset_on:
        return
    gf1, gf2 = br.matches["GF1"], br.matches["GF2"]
    for slot in ("home", "away"):
        br.place("GF2", slot, gf1[slot])
    winner_slot = "away" if gf1["winner"] is not None and gf1["winner"] == gf1["away"] else "home"
    loser_slot = "home" if winner_slot == "away" else "away"
    br.route("GF1", "winner", "GF2", winner_slot)
    br.route("GF1", "loser", "GF2", loser_slot)
    gf2["required"] = None if gf1["winner"] is None else winner_slot == "away"


GENERATORS = {"round_robin": generate_round_robin, "swiss": generate_swiss,
              "single_elim": generate_single_elim, "double_elim": generate_double_elim}
