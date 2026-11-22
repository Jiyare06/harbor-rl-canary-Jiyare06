#!/usr/bin/env python3
"""Build the README advantage table from Harbor job folders.

Every trial's verifier writes verifier/checks.json with BOTH the binary and the dense score,
so trials run in binary mode (Run 1, Run 2) can be re-scored under the dense rules exactly.

Usage:
  python3 scripts/advantage_table.py "Run 1: Baseline=jobs/<baseline-job>" "Run 2: Ablation=jobs/<ablation-job>"
"""
import json, re, sys
from pathlib import Path

def load_checks(trial_dir: Path):
    f = trial_dir / "verifier" / "checks.json"
    if f.exists():
        return json.loads(f.read_text())
    out = trial_dir / "verifier" / "test-stdout.txt"
    if out.exists():
        m = re.search(r"^CHECKS_JSON: (.*)$", out.read_text(), re.M)
        if m:
            return json.loads(m.group(1))
    return None

def fmt_adv(x):
    return f"{x:+.2f}" if abs(x) >= 0.005 else "0.00"

def main(args):
    if not args:
        sys.exit(__doc__)
    for spec in args:
        label, _, job = spec.partition("=")
        job = Path(job)
        trials = sorted(p.parent for p in job.glob("*/verifier"))
        rows = []
        for t in trials:
            c = load_checks(t)
            if c is None:
                print(f"WARNING: no checks.json in {t} (verifier didn't run?) -> counted as 0/0", file=sys.stderr)
                c = {"binary_reward": 0.0, "dense_reward": 0.0, "checks": {}}
            rows.append((t.name, c))
        if len(rows) != 3:
            print(f"WARNING: {label}: found {len(rows)} trials, expected 3", file=sys.stderr)
        b = [c["binary_reward"] for _, c in rows]
        d = [c["dense_reward"] for _, c in rows]
        mb, md = sum(b) / len(b), sum(d) / len(d)
        print(f"\n{label}  ({job})")
        for (name, c), bi, de in zip(rows, b, d):
            passed = [k for k, v in c.get("checks", {}).items() if v.get("passed")]
            print(f"  {name}: binary={bi:.2f} dense={de:.2f} checks_passed={passed}")
        cells = " | ".join(f"`{int(bi)} / {de:.2f}`" for bi, de in zip(b, d))
        print("\nREADME row:")
        print(f"| **{label}** | `<change>` | {cells} | `{mb:.2f}` | `{md:.2f}` | "
              f"`{', '.join(fmt_adv(x - mb) for x in b)}` | `{', '.join(fmt_adv(x - md) for x in d)}` |")

if __name__ == "__main__":
    main(sys.argv[1:])
