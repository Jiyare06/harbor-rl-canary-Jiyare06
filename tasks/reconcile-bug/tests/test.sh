#!/bin/bash
# Hardened dense-reward verifier for reconcile-bug.
#
# REWARD_MODE=binary -> reward.txt is 1 only if all checks pass, else 0  (used for Run 1 & Run 2)
# REWARD_MODE=dense  -> reward.txt = 0.20*cli + 0.30*status + 0.25*tz_dedup + 0.25*malformed (final verifier)
# Either way, the per-check breakdown is saved to /logs/verifier/checks.json so every trial
# can be scored under BOTH rules afterwards (see scripts/advantage_table.py).
REWARD_MODE="${REWARD_MODE:-binary}"

mkdir -p /logs/verifier
# Anything the agent may have pre-written is discarded; default to 0 if anything below crashes.
rm -rf /logs/verifier/reward.txt /logs/verifier/reward.json
echo 0 > /logs/verifier/reward.txt
# Snapshot the agent's final code for trajectory forensics.
cp /app/reconcile.py /logs/verifier/final_reconcile.py 2>/dev/null || true

VERIFIER=$(mktemp /tmp/verify_XXXXXX.py)
cat > "$VERIFIER" <<'PYEOF'
import json, os, random, re, secrets, shutil, subprocess, sys, tempfile
from datetime import datetime, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP

MODE = sys.argv[1]
WEIGHTS = {"cli": 0.20, "status": 0.30, "tz_dedup": 0.25, "malformed": 0.25}
CASES_PER_CHECK = 4
TARGET = "/app/reconcile.py"
rng = random.Random(secrets.randbits(64))  # fresh, unpredictable inputs on every verification

OFFSETS = ["+00:00", "Z", "+05:30", "-05:00", "+09:00", "-08:00", "+01:00", "-03:30", "+13:00", "-10:00"]
KNOWN = ("SUCCESS", "FAILED", "PENDING")
TS_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})")
AMOUNT_RE = re.compile(r"\d+(?:\.\d{1,2})?")

def off_delta(o):
    if o == "Z":
        return timedelta(0)
    sign = 1 if o[0] == "+" else -1
    h, m = o[1:].split(":")
    return sign * timedelta(hours=int(h), minutes=int(m))

def local(instant, off):
    return (instant + off_delta(off)).replace(tzinfo=None)

def fmt(instant, off):  # instant: aware UTC datetime
    return local(instant, off).strftime("%Y-%m-%dT%H:%M:%S") + ("Z" if off == "Z" else off)

def new_id(used):
    while True:
        t = "TX" + "".join(rng.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(rng.randint(5, 9)))
        if t not in used:
            used.add(t)
            return t

def amount():
    return Decimal(rng.randint(100, 999999)) / 100

def base_instant():
    return datetime(2024, 1, 1, tzinfo=timezone.utc) + timedelta(minutes=rng.randint(0, 500000))

def row(tx, instant, off, amt, status):
    s = fmt(instant, off)
    return {"tx_id": tx, "instant": instant, "amount": amt, "status": status,
            "naive": local(instant, off), "line": f"{tx},{s},{amt:.2f},{status}"}

# ---------- reference logic (in memory only; never written to disk) ----------
def summarize(recs, dedup="true", pending_valid=False):
    latest = {}
    for idx, r in enumerate(recs):
        cur = latest.get(r["tx_id"])
        if dedup == "tiefirst":  # correct instants, but first row wins exact ties
            if cur is None or r["instant"] > cur[0][0]:
                latest[r["tx_id"]] = ((r["instant"], idx), r)
            continue
        key = {"true": (r["instant"], idx), "naive": (r["naive"], idx), "lastrow": (idx,)}[dedup]
        if cur is None or key >= cur[0]:
            latest[r["tx_id"]] = (key, r)
    total, valid, failed = Decimal(0), 0, 0
    for _, r in latest.values():
        if r["status"] == "FAILED":
            failed += 1
        elif r["status"] == "SUCCESS" or (pending_valid and r["status"] == "PENDING"):
            valid += 1
            total += r["amount"]
    return {"total_valid_amount": total.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP),
            "valid_count": valid, "failed_count": failed}

def records(rows):
    return [r for r in rows if isinstance(r, dict)]

def interpret(line, lenient=frozenset()):
    """Parse one data line. With no flags this is the spec; each flag models one common shortcut."""
    if line == "":
        return None
    f = line.split(",")
    if len(f) < 4 or (len(f) > 4 and "fields" not in lenient):
        return None
    tx, ts, amt, st = f[:4]
    if tx == "" and "txid" not in lenient:
        return None
    if st not in KNOWN:
        if "status" in lenient and st.upper() in KNOWN:
            st = st.upper()
        else:
            return None
    if AMOUNT_RE.fullmatch(amt):
        val = Decimal(amt)
    elif "amount" in lenient:
        try:
            val = Decimal(str(float(amt)))
        except ValueError:
            return None
        if not val.is_finite():
            return None
    else:
        return None
    if val <= 0:
        return None
    try:
        when = datetime.fromisoformat(ts)
    except ValueError:
        return None
    if not TS_RE.fullmatch(ts):
        if "ts" not in lenient:
            return None
        if when.tzinfo is None:
            when = when.replace(tzinfo=timezone.utc)
    when = when.astimezone(timezone.utc)
    return {"tx_id": tx, "instant": when, "naive": when.replace(tzinfo=None), "amount": val, "status": st}

def parse_all(lines, lenient=frozenset()):
    return [r for r in (interpret(l, lenient) for l in lines) if r is not None]

def lines_of(rows):
    return [r["line"] if isinstance(r, dict) else r for r in rows]

# ---------- case generators ----------
def gen_cli():
    used, off, rows = set(), rng.choice(OFFSETS), []
    for _ in range(rng.randint(4, 12)):
        rows.append(row(new_id(used), base_instant(), off, amount(), rng.choice(["SUCCESS", "FAILED"])))
    return rows

def gen_status():
    while True:
        used, off, rows = set(), rng.choice(OFFSETS), []
        statuses = ["PENDING", "PENDING", "SUCCESS", "FAILED"] + [rng.choice(KNOWN) for _ in range(rng.randint(4, 10))]
        rng.shuffle(statuses)
        for st in statuses:
            rows.append(row(new_id(used), base_instant(), off, amount(), st))
        if summarize(rows) != summarize(rows, pending_valid=True):
            return rows

def gen_tz_dedup():
    while True:
        used, rows = set(), []
        for _ in range(rng.randint(3, 7)):  # plain unique rows
            rows.append(row(new_id(used), base_instant(), rng.choice(OFFSETS), amount(), rng.choice(["SUCCESS", "FAILED"])))
        for _ in range(rng.randint(2, 3)):  # traps: true-latest row is EARLIER in file and has a "smaller" local time
            tx, t_old = new_id(used), base_instant()
            t_new = t_old + timedelta(minutes=rng.randint(5, 240))
            st_new = rng.choice(["SUCCESS", "FAILED"])
            st_old = "FAILED" if st_new == "SUCCESS" else "SUCCESS"
            rows += [row(tx, t_new, rng.choice(["-05:00", "-08:00", "-10:00", "-03:30"]), amount(), st_new),
                     row(tx, t_old, rng.choice(["+05:30", "+09:00", "+13:00"]), amount(), st_old)]
        tx, t = new_id(used), base_instant()  # same-offset duplicate (easy)
        off = rng.choice(OFFSETS)
        rows += [row(tx, t + timedelta(hours=1), off, amount(), "SUCCESS"), row(tx, t, off, amount(), "FAILED")]
        tx, t = new_id(used), base_instant()  # exact-instant tie across offsets -> later row wins
        a, b = rng.sample(OFFSETS, 2)
        rows += [row(tx, t, a, amount(), "FAILED"), row(tx, t, b, amount(), "SUCCESS")]
        groups, cur = [], []
        for r in rows:  # shuffle whole tx groups, keep order inside a group
            if cur and cur[-1]["tx_id"] != r["tx_id"]:
                groups.append(cur); cur = []
            cur.append(r)
        groups.append(cur)
        rng.shuffle(groups)
        rows = [r for g in groups for r in g]
        truth = summarize(rows)
        if all(truth != summarize(rows, dedup=alt) for alt in ("naive", "lastrow", "tiefirst")):
            return rows

FAMILIES = ("amount", "ts", "fields", "status", "txid")

def trap_line(family, tx, instant, off, status):
    good_ts, good_amt = fmt(instant, off), f"{amount():.2f}"
    if family == "amount":
        bad = rng.choice(["1e3", "2.5e1", "12.345", "+5.00", ".50", "7.", "4.999"])
        return f"{tx},{good_ts},{bad},{status}"
    if family == "ts":
        l = local(instant, "+00:00")
        bad = rng.choice([
            l.strftime("%Y-%m-%dT%H:%M:%S"),               # no offset
            l.strftime("%Y-%m-%d %H:%M:%S") + "+00:00",    # space instead of T
            l.strftime("%Y-%m-%dT%H:%M") + "+00:00",       # no seconds
            l.strftime("%Y-%m-%dT%H:%M:%S") + ".500+00:00",  # fractional seconds
            l.strftime("%Y-%m-%dT%H:%M:%S") + "+0000",     # offset without colon
        ])
        return f"{tx},{bad},{good_amt},{status}"
    if family == "fields":
        return f"{tx},{good_ts},{good_amt},{status},{rng.choice(['EXTRA', 'note', '1'])}"
    if family == "status":
        return f"{tx},{good_ts},{good_amt},{rng.choice([status.lower(), status.capitalize()])}"
    return f",{good_ts},{good_amt},{status}"  # txid: empty id

NOISE = ["", "{tx},{ts},abc,SUCCESS", "{tx},{ts},-5.00,SUCCESS", "{tx},{ts},0.00,SUCCESS", "{tx},{ts},NaN,SUCCESS",
         "{tx},2024-02-30T10:00:00+00:00,12.00,SUCCESS", "{tx},{ts},12.00,REFUNDED", "{tx},{ts},12.00"]

def gen_malformed():
    while True:
        used, off, rows = set(), rng.choice(OFFSETS), []
        for _ in range(rng.randint(5, 9)):
            rows.append(row(new_id(used), base_instant(), off, amount(), rng.choice(["SUCCESS", "FAILED"])))
        tx, t = new_id(used), base_instant()  # a normal valid duplicate still has to work
        rows += [row(tx, t, off, amount(), "FAILED"), row(tx, t + timedelta(hours=2), off, amount(), "SUCCESS")]
        valid = list(records(rows))
        for fam in FAMILIES:
            for _ in range(rng.randint(1, 2)):
                if rng.random() < 0.5:  # malformed row that would "supersede" a valid record if accepted
                    target = rng.choice(valid)
                    st = "FAILED" if target["status"] == "SUCCESS" else "SUCCESS"
                    rows.append(trap_line(fam, target["tx_id"], target["instant"] + timedelta(minutes=rng.randint(10, 600)), off, st))
                else:                   # malformed row with a brand-new id
                    rows.append(trap_line(fam, new_id(used), base_instant(), off, rng.choice(["SUCCESS", "FAILED"])))
        for _ in range(rng.randint(1, 3)):
            rows.append(rng.choice(NOISE).format(tx=new_id(used), ts=fmt(base_instant(), off)))
        rng.shuffle(rows)
        truth = summarize(records(rows))
        lines = lines_of(rows)
        assert summarize(parse_all(lines)) == truth, "generator/spec mismatch"
        if all(truth != summarize(parse_all(lines, frozenset([fam]))) for fam in FAMILIES):
            return rows

# ---------- run the candidate ----------
def run_case(rows):
    expected = summarize(records(rows))
    work = tempfile.mkdtemp(prefix="rv_")
    cwd = tempfile.mkdtemp(prefix="rc_")
    path = os.path.join(work, secrets.token_hex(6) + ".csv")
    try:
        with open(path, "w") as fh:
            fh.write("tx_id,timestamp,amount,status\n")
            for l in lines_of(rows):
                fh.write(l + "\n")
        if not os.path.isfile(TARGET):
            return False, "reconcile.py missing"
        env = {"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": cwd, "LANG": "C.UTF-8"}
        try:
            p = subprocess.run(["python3", TARGET, path], cwd=cwd, env=env,
                               capture_output=True, text=True, timeout=10)
        except subprocess.TimeoutExpired:
            return False, "timeout"
        if p.returncode != 0:
            return False, f"exit {p.returncode}: {p.stderr.strip()[-200:]}"
        try:
            out = json.loads(p.stdout.strip())
        except Exception:
            return False, f"stdout is not JSON: {p.stdout.strip()[:200]!r}"
        if not isinstance(out, dict):
            return False, "output is not a JSON object"
        for k in ("valid_count", "failed_count"):
            v = out.get(k)
            if type(v) is not int or v != expected[k]:
                return False, f"{k}: got {v!r}, expected {expected[k]}"
        tv = out.get("total_valid_amount")
        try:
            ok = type(tv) in (int, float) and abs(Decimal(str(tv)) - expected["total_valid_amount"]) <= Decimal("0.005")
        except Exception:
            ok = False
        if not ok:
            return False, f"total_valid_amount: got {tv!r}, expected {expected['total_valid_amount']}"
        return True, "ok"
    finally:
        shutil.rmtree(work, ignore_errors=True)
        shutil.rmtree(cwd, ignore_errors=True)

GENERATORS = {"cli": gen_cli, "status": gen_status, "tz_dedup": gen_tz_dedup, "malformed": gen_malformed}
results = {}
for name, gen in GENERATORS.items():
    outcomes = [run_case(gen()) for _ in range(CASES_PER_CHECK)]
    results[name] = {"passed": all(ok for ok, _ in outcomes),
                     "cases_passed": sum(ok for ok, _ in outcomes),
                     "first_error": next((msg for ok, msg in outcomes if not ok), None)}

dense = round(sum(WEIGHTS[n] for n, r in results.items() if r["passed"]), 2)
binary = 1.0 if all(r["passed"] for r in results.values()) else 0.0
reward = dense if MODE == "dense" else binary
summary = {"mode": MODE, "weights": WEIGHTS, "checks": results,
           "binary_reward": binary, "dense_reward": dense, "reward": reward}

with open("/logs/verifier/checks.json", "w") as fh:
    json.dump(summary, fh, indent=2)
for n, r in results.items():
    print(f"[{'PASS' if r['passed'] else 'FAIL'}] {n:<9} weight={WEIGHTS[n]:.2f} "
          f"cases={r['cases_passed']}/{CASES_PER_CHECK}" + (f"  first_error={r['first_error']}" if r['first_error'] else ""))
print(f"binary={binary:.2f} dense={dense:.2f} -> reward ({MODE}) = {reward:.2f}")
print("CHECKS_JSON:", json.dumps(summary))
with open("/logs/verifier/reward.txt", "w") as fh:
    fh.write(f"{reward:.2f}\n")
PYEOF

# -I: ignore PYTHON* env vars & user site-packages; -S: don't run site/sitecustomize hooks the agent could plant.
python3 -I -S "$VERIFIER" "$REWARD_MODE"
rm -f "$VERIFIER"
echo "reward.txt: $(cat /logs/verifier/reward.txt)"
