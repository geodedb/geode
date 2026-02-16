# canaryscan

Small Go 1.23+ CLI to scan **CANARY** tokens across the repo, emit `status.json` / `status.csv`,
and **verify** GAP claims.

## Build

```bash
go build -o ./bin/canaryscan ./tools/canaryscan
```

## Usage

```bash
./bin/canaryscan --root . --out status.json --csv status.csv
./bin/canaryscan --root . --verify GAP_ANALYSIS.md --strict
```

- **Exit 0**: OK
- **Exit 2**: Verification/staleness failed
- **Exit 3**: Parse or IO error

**Token format**

```text
CANARY: REQ=<id>; FEATURE=<name>; ASPECT=<aspect>; STATUS=<status>; TEST=<path>; BENCH=<path>; OWNER=<team>; UPDATED=<date>
```

## Status Auto-Promotion

The scanner auto-promotes statuses based on evidence references:

| From        | Evidence Condition    | To      |
| ----------- | --------------------- | ------- |
| IMPL        | ≥1 test (TEST=)       | TESTED  |
| IMPL/TESTED | ≥1 benchmark (BENCH=) | BENCHED |

Notes:

- Promotion is applied in-memory; original source comments remain unchanged.
- BENCHED dominates TESTED in summary counts.
- `--strict` still validates staleness on TESTED/BENCHED after promotion.
- A future `--no-promote` flag may allow raw status reporting.

Example: if a feature is marked `STATUS=IMPL` and has a `TEST=TestCANARY_REQ_GQL_030_TxnCommit`, the report will show it as `TESTED`.

## Testing

```bash
cd tools/canaryscan
go test -v
```
