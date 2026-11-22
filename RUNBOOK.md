# Runbook (delete this file before submitting if you like)



## 0. Sanity checks (no API key)
```bash
cd ~/harbor-rl-canary-Jiyare06
harbor run -p ./tasks/reconcile-bug -a nop      # expect 0.000
harbor run -p ./tasks/reconcile-bug -a oracle   # expect 1.000
```

## 1. Run 1 — Baseline (binary grading) — Windows PowerShell
`tests/test.sh` already ships in binary mode (`REWARD_MODE:-binary`). Run in every new window:
```powershell
$env:PATH = "C:\Users\BIT\.local\bin;$env:PATH"
$env:PYTHONUTF8="1"
$env:GROQ_API_KEY="your-groq-key"
harbor run -p ./tasks/reconcile-bug -a terminus-2 --model groq/openai/gpt-oss-120b -k 3 -n 1 --ak 'llm_kwargs={\"num_retries\": 10}'
```
The `--ak` part makes the model client wait and retry on Groq's 8,000 tokens/minute free limit instead of
crashing. Runs are slow (~1 agent step per minute); that's expected.
Need >= 1 failed trial. A trial that ends in an Exception (rate limit) is not a real result: delete that job
folder and re-run.

## 2. Forensics
Open `jobs/<baseline-job>/<trial>/agent/trajectory.json` for a failed trial. Also look at
`<trial>/verifier/checks.json` (which checks passed, first error) and `<trial>/verifier/final_reconcile.py`
(the agent's final code). Find the step where it ran its last test and declared done.

## 3. Run 2 — Ablation (still binary). Make exactly ONE change based on what you saw:
- Agent stopped after testing only the instruction example → add a sample file to the image, e.g.
  `environment/sample_transactions.csv` containing a cross-timezone duplicate (no expected output!),
  add `COPY sample_transactions.csv /app/sample_transactions.csv` to the Dockerfile, and one line to
  `instruction.md`: "A sample input is available at /app/sample_transactions.csv."
- Agent misread the dedup rule → add a second worked example in `instruction.md` with two records for the
  same tx_id in different offsets (and its output). This doesn't reveal which code is broken.
```bash
harbor run -p ./tasks/reconcile-bug -a terminus-2 --model gemini/gemini-2.5-flash -k 3 -n 1
```

## 4. Switch to dense & build the table
Set `REWARD_MODE` back to `dense` in `test.sh` (PowerShell, keeps Linux line endings):
```powershell
$f = (Resolve-Path tasks/reconcile-bug/tests/test.sh).Path; [IO.File]::WriteAllText($f, ([IO.File]::ReadAllText($f) -replace 'REWARD_MODE:-binary','REWARD_MODE:-dense'))
```
Then (use `python` or `py` on Windows, or `uv run --no-project python`):
```bash
python3 scripts/advantage_table.py "Run 1: Baseline=jobs/<baseline-job>" "Run 2: Ablation=jobs/<ablation-job>"
```
Paste the printed rows into README section 3 (fill in the change description).

## 5. Hack check (zero API calls)
```bash
cp tasks/reconcile-bug/solution/solve.sh /tmp/solve.sh.bak
cp tasks/reconcile-bug/solution/hack.sh tasks/reconcile-bug/solution/solve.sh
harbor run -p ./tasks/reconcile-bug -a oracle   # must score 0.000
mv /tmp/solve.sh.bak tasks/reconcile-bug/solution/solve.sh
```

## 6. Video Part 1 — partial-credit canary
In `solve.sh`, change `return datetime.fromisoformat(raw).astimezone(timezone.utc)` to
`return datetime.fromisoformat(raw).replace(tzinfo=timezone.utc)`.
Predict out loud: **0.75** (CLI 0.20 + status 0.30 + malformed 0.25; tz/tie dedup 0.25 lost). Run oracle → 0.750. Undo → 1.000.

## 7. Video Part 3 — talking points
- **Advantage walkthrough:** pick a trial that fixed Bugs 1+2 but not 3. Binary: 0 − 0 = 0, nothing learned.
  Dense: e.g. 0.50 − mean. Positive advantage reinforces the commands that found the argv check and the
  `PENDING` filter and re-ran the example; a trial that broke the file gets negative advantage for those edits.
- **Local optimum:** with 0.2/0.3/0.25/0.25, fixing Bugs 1+2 reliably gives 0.50, and a risky Bug-3 edit that breaks
  the file drops it to 0.00 (the CLI check gates everything). If training stalled at 0.50 or 0.75, I'd shift weight
  further to Bug 3 (e.g. 0.1/0.2/0.35/0.35), give partial credit *within* the dedup check (fraction of cases),
  or use a curriculum with Bug-3-only variants of the task — while watching that within-check partial credit
  doesn't reward heuristics like "last row wins".
- **Remaining cheat:** tampering with the interpreter/stdlib the verifier itself uses (see README §5).

## 8. Transcripts & submit
Export this Claude conversation into `ai_transcripts/` (use the chat's share link, or copy the conversation
into a `.md` file), then follow assignment §8.2 and §8.5.
