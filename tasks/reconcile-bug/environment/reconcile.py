#!/usr/bin/env python3
"""Reconcile a CSV of payment transactions into a JSON summary.

Usage: python3 reconcile.py <transactions.csv>
"""
import csv
import json
import sys
from datetime import datetime, timezone

VALID_STATUS = "SUCCESS"
FAILED_STATUS = "FAILED"
KNOWN_STATUSES = (VALID_STATUS, FAILED_STATUS, "PENDING")


def parse_ts(raw):
    """Parse an ISO 8601 timestamp and normalise it to UTC."""
    ts = datetime.fromisoformat(raw.strip())
    return ts.replace(tzinfo=timezone.utc)


def is_valid(row):
    """Basic sanity checks; malformed rows are skipped."""
    try:
        float(row["amount"])
        parse_ts(row["timestamp"])
    except (TypeError, ValueError, AttributeError):
        return False
    return row["status"].strip() in KNOWN_STATUSES


def load_rows(path):
    with open(path, newline="") as fh:
        rows = []
        for row in csv.DictReader(fh):
            if not is_valid(row):
                continue
            rows.append(
                {
                    "tx_id": row["tx_id"].strip(),
                    "ts": parse_ts(row["timestamp"]),
                    "amount": float(row["amount"]),
                    "status": row["status"].strip(),
                }
            )
    return rows


def latest_per_tx(rows):
    """Keep only the most recent record for each tx_id."""
    latest = {}
    for row in rows:
        current = latest.get(row["tx_id"])
        if current is None or row["ts"] > current["ts"]:
            latest[row["tx_id"]] = row
    return list(latest.values())


def summarize(rows):
    total = 0.0
    valid = 0
    failed = 0
    for row in rows:
        if row["status"] == FAILED_STATUS:
            failed += 1
        else:
            valid += 1
            total += row["amount"]
    return {
        "total_valid_amount": round(total, 2),
        "valid_count": valid,
        "failed_count": failed,
    }


def main(argv):
    if len(argv) < 3:
        print("usage: reconcile.py <transactions.csv>", file=sys.stderr)
        return 1
    rows = load_rows(argv[1])
    print(json.dumps(summarize(latest_per_tx(rows))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
