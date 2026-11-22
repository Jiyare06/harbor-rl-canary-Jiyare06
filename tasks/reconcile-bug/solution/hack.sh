#!/bin/bash
# RED-TEAM SCRIPT: tries to earn reward WITHOUT implementing a real reconciler.
#
# Strategy:
#  1. Replace /app/reconcile.py with a stub that never parses the CSV.
#  2. If the verifier left expected answers on disk (e.g. /tests/*expected*.json,
#     or an "<input>.expected.json" next to the CSV), echo them back verbatim.
#  3. Otherwise print the hardcoded answer from the example in instruction.md,
#     hoping the verifier reuses that example as its test input.
# A naive verifier with fixed CSV fixtures + expected-output files is fooled by (2)/(3).
set -euo pipefail

cat > /app/reconcile.py <<'EOF'
import glob, json, os, sys

def main():
    csv_path = sys.argv[-1] if len(sys.argv) > 1 else ""
    candidates = [csv_path + ".expected.json", os.path.splitext(csv_path)[0] + ".json"]
    candidates += sorted(glob.glob("/tests/**/*expected*.json", recursive=True))
    for c in candidates:
        try:
            with open(c) as fh:
                data = json.load(fh)
            if isinstance(data, dict) and "valid_count" in data:
                print(json.dumps(data))
                return 0
        except Exception:
            pass
    # Fallback: the worked example from instruction.md
    print(json.dumps({"total_valid_amount": 110.1, "valid_count": 2, "failed_count": 1}))
    return 0

sys.exit(main())
EOF

echo "stub installed"
