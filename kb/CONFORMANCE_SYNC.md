# Conformance Sync Scanner

Utility script to keep `REQ-GQL-###` requirement IDs consistent across `docs/` and `src/`.

## Features

- Scans all `.md` and `.zig` files under `docs/` and `src/`.
- Detects duplicates (lists every extra occurrence beyond the first).
- Detects numeric gaps in the trailing 3‑digit sequence (000–999 window).
- Deterministic ordering of IDs for stable diffs.
- Multiple output formats (JSON / Markdown / plain text).
- Non‑zero exit (2) on issues with `--fail-on-issues`.

## Usage

```bash
zig run scripts/conformance_sync.zig -- [--json|--markdown] [--fail-on-issues]
```

If no format flag is provided, a plain text summary is printed.

### Flags

| Flag               | Description                                                  |
| ------------------ | ------------------------------------------------------------ |
| `--json`           | Emit machine‑readable JSON summary.                          |
| `--markdown`       | Emit Markdown report (table of duplicate frequencies, gaps). |
| `--fail-on-issues` | Exit code 2 if any duplicates or gaps are found.             |

### JSON Schema (current)

```json
{
  "total_ids": <number>,
  "ids": ["REQ-GQL-001", ...],
  "duplicates": ["REQ-GQL-026", ...],
  "gaps": [<number>, ...],
  "issues": true|false
}
```

- `duplicates` includes each extra occurrence (so the same ID can appear many times).
- For a frequency map, use:

```bash
jq '."duplicates" | group_by(.) | map({id:.[0], extra: length})'
```

### Markdown Output

Sections included:

1. Header + total unique IDs.
2. Duplicate frequency table (extra occurrences beyond first) or a “No duplicates” line.
3. Gaps section listing missing numeric suffixes (if any) or “No gaps …”.

### Exit Codes

| Code | Meaning                                          |
| ---- | ------------------------------------------------ |
| 0    | Success, no issues (or issues ignored).          |
| 2    | Issues present and `--fail-on-issues` specified. |

## Workflow Integration

Add a CI step that fails if new gaps / duplicates introduced:

```bash
zig run scripts/conformance_sync.zig -- --json --fail-on-issues > /dev/null
```

Or produce an artifact report:

### (Deprecated) Regeneration Tooling

Prior experimental scripts `scripts/scan_requirements.zig` and `scripts/regen_conformance.zig` plus the `make regen-conformance` target were removed (fragile on Zig 0.15.x, added maintenance cost). The ledger/backlog sections are now manually curated.

Recommended current practice:

1. Run a scan locally in JSON:  
   `zig run scripts/conformance_sync.zig -- --json > /tmp/req_scan.json`
2. Inspect duplicates/gaps (fail CI with `--fail-on-issues`).
3. Manually edit `GAP_ANALYSIS.md` / `NEXT.md` as needed; no in-place rewrite occurs.

If future lightweight regeneration is desired, prefer an external (non-repo) helper that consumes the stable JSON output instead of embedding additional Zig tooling.

## Notes / Limits

- Scans only first 1 MiB of each file (current hard cap in script).
- Numeric space limited to 000–999; raise the presence array size if expanding.
- JSON writer is manual for Zig 0.15.x compatibility.
- Duplicate frequency key copies are freed; memory should be leak‑free (debug allocator).

## Future Enhancements

- Optional CSV output (`--csv`).
- Direct regeneration of cross‑reference tables.
- Configurable ID prefix.
