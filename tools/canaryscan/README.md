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

* **Exit 0**: OK
* **Exit 2**: Verification/staleness failed
* **Exit 3**: Parse or IO error

**Token format**

```
CANARY: REQ=REQ-GQL-###; FEATURE="Name"; ASPECT=...; STATUS=MISSING|STUB|IMPL|TESTED|BENCHED|REMOVED; TEST=...; BENCH=...; OWNER=...; UPDATED=YYYY-MM-DD
```

## Testing

```bash
cd tools/canaryscan
go test -v
```