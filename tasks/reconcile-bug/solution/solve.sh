#!/bin/bash
# Reference solution: fixes all bugs in /app/reconcile.py.
set -euo pipefail

cat > /app/reconcile.py <<'EOF'
#!/usr/bin/env python3
"""Reconcile a CSV of payment transactions into a JSON summary.

Usage: python3 reconcile.py <transactions.csv>
"""
import csv
import json
import re
import sys
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP

VALID_STATUS = "SUCCESS"
FAILED_STATUS = "FAILED"
KNOWN_STATUSES = (VALID_STATUS, FAILED_STATUS, "PENDING")
TS_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})")
AMOUNT_RE = re.compile(r"\d+(?:\.\d{1,2})?")


def parse_ts(raw):
    """Parse an ISO 8601 timestamp and normalise it to UTC."""
    # FIX (Bug 3a): CONVERT to UTC; replace(tzinfo=...) only relabels local time.
    return datetime.fromisoformat(raw).astimezone(timezone.utc)


def parse_row(fields):
    """Return a parsed record, or None if the row is malformed (Bug 3b: strict rules)."""
    if len(fields) != 4:
        return None
    tx_id, ts, amount, status = fields
    if not tx_id or status not in KNOWN_STATUSES:
        return None
    if not TS_RE.fullmatch(ts) or not AMOUNT_RE.fullmatch(amount):
        return None
    try:
        when = parse_ts(ts)
    except ValueError:  # e.g. 2024-02-30 or 25:00:00
        return None
    value = Decimal(amount)
    if value <= 0:
        return None
    return {"tx_id": tx_id, "ts": when, "amount": value, "status": status}


def load_rows(path):
    with open(path, newline="") as fh:
        reader = csv.reader(fh)
        next(reader, None)  # header
        return [r for r in (parse_row(f) for f in reader) if r is not None]


def latest_per_tx(rows):
    """Keep only the most recent record for each tx_id."""
    # FIX (Bug 3a): >= so that on an exact tie the later row in the file wins.
    latest = {}
    for row in rows:
        current = latest.get(row["tx_id"])
        if current is None or row["ts"] >= current["ts"]:
            latest[row["tx_id"]] = row
    return list(latest.values())


def summarize(rows):
    total = Decimal("0")
    valid = 0
    failed = 0
    for row in rows:
        # FIX (Bug 2): only SUCCESS is valid; PENDING is counted nowhere.
        if row["status"] == FAILED_STATUS:
            failed += 1
        elif row["status"] == VALID_STATUS:
            valid += 1
            total += row["amount"]
    return {
        "total_valid_amount": float(total.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)),
        "valid_count": valid,
        "failed_count": failed,
    }


def main(argv):
    # FIX (Bug 1): the script takes exactly one argument.
    if len(argv) != 2:
        print("usage: reconcile.py <transactions.csv>", file=sys.stderr)
        return 1
    rows = load_rows(argv[1])
    print(json.dumps(summarize(latest_per_tx(rows))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
EOF

echo "reconcile.py fixed"
