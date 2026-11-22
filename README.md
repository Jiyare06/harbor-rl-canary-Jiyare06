# Harbor RL Submission — Jiya (@Jiyare06)

## 1. Loom Walkthrough Video
- **Video URL:** [Watch 5-Minute Walkthrough](https://www.loom.com/share/YOUR_VIDEO_ID)
  *(Link sharing set to "Anyone with the link can view")*

## 2. Task & Calibration Summary
- **Bug 1 (Easy):** The CLI argument check requires `len(argv) >= 3`, so running the script with its one documented argument prints the usage message and exits 1 before doing any work.
- **Bug 2 (Medium):** The status filter treats everything that isn't `FAILED` as valid, so `PENDING` transactions are counted in `valid_count` and added to `total_valid_amount`.
- **Bug 3 (Hard, two scored parts):** (a) Deduplication "normalises" timestamps with `.replace(tzinfo=timezone.utc)`, which relabels local wall-clock time as UTC instead of converting it, and uses `>` so exact-instant ties keep the earlier row instead of the later one; (b) the row validator is lenient (`float()` + `fromisoformat()`), so malformed rows the spec says to ignore — amounts like `1e3`/`12.345`, timestamps with no offset or no seconds, extra fields, wrong-case statuses, empty IDs — are counted and can even replace a valid record.
- **Calibration History:** v1 (offset sliced off with `raw[:19]`) was too easy: `gemini-3.8-flash` passed 2/2 completed trials and `groq/openai/gpt-oss-120b` 1/1. v2 (UTC relabel + tie-break) still scored 3/3 on `gpt-oss-120b`; its trajectories showed why — the agent read `reconcile.py`, rewrote the whole file from the spec, tested only the `instruction.md` example, and stopped, so subtle planted bugs never mattered. `groq/openai/gpt-oss-20b` could not run the agent at all (all 3 trials crashed on Groq's 8K tokens/min free limit and invalid tool-call output after 1 step). v3 (this version) adds strict row-validity rules to the spec that a from-scratch rewrite easily gets wrong and the example never exercises; replaying gpt-oss-120b's own v2 code against the v3 verifier scores 0.75 (fails only the malformed-row check). Run 1 and Run 2 use `groq/openai/gpt-oss-120b`. `TODO: baseline result`
- **Calibration Scores:** `nop` = `0.00` | `oracle` (`solve.sh`) = `1.00` | Partial `oracle` (timezone part of Bug 3 broken, shown in video) = `0.75` | `hack.sh` = `0.00`

## 3. Ablation & RL Advantage Table (`terminus-2`, `k=3` Trials)

Generated with `python3 scripts/advantage_table.py`, which reads each trial's `verifier/checks.json`. The verifier logs all three checks in both modes, so trials graded in binary mode can be re-scored under the dense rules exactly, with no manual guessing.

| Run | Change Tested | Trial 1 (Binary / Dense) | Trial 2 (Binary / Dense) | Trial 3 (Binary / Dense) | Mean Binary | Mean Dense ($\bar{R}$) | Binary Advantage ($R_1-\bar{R}, R_2-\bar{R}, R_3-\bar{R}$) | Dense Advantage ($R_1-\bar{R}, R_2-\bar{R}, R_3-\bar{R}$) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Run 1: Baseline** | Original 3-bug task | `TODO` | `TODO` | `TODO` | `TODO` | `TODO` | `TODO` | `TODO` |
| **Run 2: Ablation** | `TODO: the one change` | `TODO` | `TODO` | `TODO` | `TODO` | `TODO` | `TODO` | `TODO` |

## 4. Trajectory Forensics (`trajectory.json`)
- **Where the Agent Failed in Run 1:** `TODO — name the trial, the step number, and the exact command (e.g. "after fixing the argv check and the status filter, the agent ran the instruction.md example, saw 110.1, and declared the task complete without testing duplicates across timezones").`
- **Ablation Hypothesis & Result:** `TODO — what you changed, why that failure suggested it, and how the agent's commands differed in Run 2.`

## 5. Dense Reward & Anti-Cheat Design
- **My Dense Reward Weights (`tests/test.sh`):** CLI check 0.20, status check 0.30, timezone/tie dedup check 0.25, malformed-row check 0.25. Each check runs 4 freshly generated CSVs and passes only if all 4 are correct, and each check's data isolates one bug (status cases have no duplicates; dedup cases have no `PENDING` or malformed rows; malformed cases use a single offset with no ties). Bug 3 carries half the reward so a policy can't plateau by fixing only the easy bugs, and splitting it in two gives a learning signal between "fixed the dedup" and "fixed everything".
- **How `solution/hack.sh` Cheated & How I Blocked It:** `hack.sh` replaces `reconcile.py` with a stub that never parses the CSV: it echoes any expected-output JSON it can find next to the input or under `/tests/`, otherwise it prints the worked example's answer from `instruction.md`. The hardened verifier generates every CSV at verification time from a fresh `secrets` seed (random IDs, amounts, statuses, offsets, and a random file name), computes expected answers only in memory, never writes them to disk, and requires every case in a check to pass — so the stub scores 0.00. It also uses rejection sampling so every dedup case defeats the planted bug, "last row wins" and "first row wins ties", and every malformed-row case defeats each lenient shortcut on its own (float-parsed amounts, loose timestamps, extra fields, case-insensitive status, empty IDs), runs the candidate in a clean env with a timeout, overwrites any pre-written `reward.txt`, and runs itself with `python3 -I -S` so planted `sitecustomize`/`PYTHON*` hooks don't load.
- **Remaining Reward-Hacking Risk:** The agent runs as root in the same container the verifier later uses, so it could tamper with the Python standard library (e.g. edit `datetime.py` or `decimal.py`) or replace the `python3` binary so that the verifier's own reference computation agrees with a wrong answer. Fixing this properly means running the verifier from a separate, read-only Python/toolchain (or a clean sidecar container) and hash-checking interpreter files before grading.

## 6. AI Tool Workflow
- **AI Tool & Model Used:** Claude (Claude Opus 5.5) in the claude.ai chat interface
- **How I Avoided Prompt Leakage:** `instruction.md` only specifies observable behaviour — the CLI contract, input/output formats, and the business rules (including the timezone-aware dedup rule) — and never mentions functions, line numbers, or what is broken. Its worked example exercises the `PENDING` rule but deliberately contains no cross-timezone duplicate, and the tests (hidden in `tests/`, generated at verification time) are never visible to the agent.
