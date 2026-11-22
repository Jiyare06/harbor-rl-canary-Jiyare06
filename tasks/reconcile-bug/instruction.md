# Fix the payment reconciliation script

`/app/reconcile.py` is a command-line tool that is supposed to summarise a CSV file of payment
transactions. It currently produces wrong results. Fix it so that it follows the specification
below. Edit `/app/reconcile.py` in place; do not rename or move it.

## How it is run

```
python3 /app/reconcile.py <path-to-transactions.csv>
```

It takes exactly one argument (the CSV path), prints a single JSON object to stdout, and exits with
status code 0.

## Input format

The first line is always the header `tx_id,timestamp,amount,status`. Every following line is one
transaction record. Fields never contain quotes, commas or surrounding whitespace.

A record is **valid** only if all of the following hold:

- It has exactly 4 fields.
- `tx_id` is non-empty. The same `tx_id` may appear on more than one row.
- `timestamp` has exactly the form `YYYY-MM-DDTHH:MM:SS` followed by either `Z` or a UTC offset
  `+HH:MM` / `-HH:MM` (e.g. `2024-03-01T10:15:00+05:30`, `2024-03-01T04:45:00Z`), and is a real
  calendar date and time. Different rows may use different offsets.
- `amount` is one or more digits, optionally followed by `.` and one or two digits
  (e.g. `125`, `125.5`, `125.50`), and is greater than zero.
- `status` is exactly one of `SUCCESS`, `FAILED`, `PENDING` (case-sensitive).

Any line that is not a valid record (including a blank line) is **malformed** and must be ignored
completely: it is not counted anywhere and it never replaces or hides another record.

## Business rules

1. **Deduplication.** If a `tx_id` appears in more than one valid record, only its most recent
   record counts. "Most recent" means the latest actual point in time: compare timestamps as
   absolute instants. If two records for the same `tx_id` have exactly the same instant, the one
   that appears later in the file wins. All older records for that `tx_id` are ignored completely.
2. **Classification** (applied to the surviving record of each `tx_id`):
   - `SUCCESS` → a valid transaction. Its amount counts toward the total.
   - `FAILED` → a failed transaction.
   - `PENDING` → neither valid nor failed. It is not counted anywhere.
3. **Total.** `total_valid_amount` is the sum of the amounts of all valid transactions, rounded to
   two decimal places.

## Output format

```json
{"total_valid_amount": 110.10, "valid_count": 2, "failed_count": 1}
```

- `total_valid_amount`: number
- `valid_count`: integer
- `failed_count`: integer

## Example

Input:

```
tx_id,timestamp,amount,status
T1,2024-03-01T09:00:00+00:00,100.00,SUCCESS
T2,2024-03-01T09:05:00+00:00,50.25,FAILED
T3,2024-03-01T09:10:00+00:00,20.00,PENDING
T1,2024-03-01T08:00:00+00:00,999.99,FAILED
T4,2024-03-01T10:00:00Z,10.10,SUCCESS
```

Output:

```json
{"total_valid_amount": 110.1, "valid_count": 2, "failed_count": 1}
```

(`T1`'s 08:00 record is older than its 09:00 record, so it is ignored. `T3` is pending.)

Your fix will be checked against other, unseen inputs that follow the same rules.
