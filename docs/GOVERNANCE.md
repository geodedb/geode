# Governance Automation Overview

This document describes the automated governance steps enforced by `scripts/governance_ci.zig` and related tooling. All steps produce a machine-readable JSON summary (type `governance_summary`). A failing step causes the process to exit with code 2 (policy violation) or >2 for internal errors.

## Steps

| Step Name              | Purpose                                                                                                         | Evidence Source(s)                                           | Failure Mode                                           | Notes                                             |
| ---------------------- | --------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------ | ------------------------------------------------- |
| `freshness`            | Ensures `docs/NEXT.md` regeneration date (Generated …) is not stale (>1 day)                                    | `docs/NEXT.md`                                               | Date drift                                             | Uses `scripts/next_freshness_check.zig`           |
| `canary`               | Runs CANARY scanner for evidence ledger                                                                         | `./bin/canaryscan`, CANARY lines                             | Missing / stale / inconsistent evidence                | Writes `status.json`, `status.csv`                |
| `doc_consistency`      | Verifies README + IMPLEMENTATION_REALITY counts match `status.json` summary                                     | `status.json`, `README.md`, `docs/IMPLEMENTATION_REALITY.md` | Count mismatch                                         | Total = TESTED + BENCHED; STUB/IMPL must be zero  |
| `gap_consistency`      | Confirms `docs/GAP_ANALYSIS.md` main table + summary lines align with counts                                    | `status.json`, `docs/GAP_ANALYSIS.md`                        | Table or summary drift                                 | Enforces no manual divergence                     |
| `next_slices`          | Validates each slice structure has mandatory sections                                                           | `docs/NEXT.md`                                               | Missing WHY/WHAT/ACCEPTANCE tokens or malformed header | Slice format contract                             |
| `slice_req_crosscheck` | Ensures every slice header's `REQ-GQL-###` appears in evidence (status.json) AND each slice has exactly one REQ | `docs/NEXT.md`, `status.json` (fallback grep)                | Missing REQ mapping or header without REQ              | Guards silent drift between planning and evidence |
| `evidence_delta`       | Detects removed `REQ-GQL-###` ids vs previous snapshot (`status_prev.json`)                                     | `status_prev.json`, `status.json`                            | REQ removed without explicit override                  | Prevents silent evidence regression               |
| `reality_freshness`    | Verifies `docs/IMPLEMENTATION_REALITY.md` date matches current `status.json` `generated_at` (± window)          | `status.json`, `docs/IMPLEMENTATION_REALITY.md`              | Stale date outside allowed window                      | Window via `REALITY_FRESHNESS_MAX_DAYS`           |

## Slice REQ Crosscheck Logic

1. Parse all slice headers matching `### Slice S-<NNN>:`.
2. Count slices and the subset with a `REQ-GQL-###` token.
3. Fail if any slice header omits a REQ.
4. Load `status.json`; each extracted REQ id must appear at least once.
5. If `status.json` missing (rare), fallback to a workspace grep for lines containing both the REQ token and (preferably) `CANARY:`.

Debug prints (temporary) include:

- `SLICE_REQ_CROSSCHECK_STATUS_JSON_FOUND <REQ>`
- `SLICE_REQ_CROSSCHECK_HEADER_MISSING slice_headers=<n> with_req=<m>`

These are now gated behind `GOV_DEBUG`.

## Exit Codes

- `0`: All governance steps passed.
- `2`: One or more policy validation failures (expected CI red condition).
- `>2`: Internal error (I/O, allocation, unexpected panic) — treat as infrastructure issue.

## Adding a New Governance Step

1. Implement a pure function `fn newStep(summary: *Summary) !bool` returning true on success.
2. Register via `runStep(&summary, "<name>", &newStep)` in `main` before final status emission.
3. Add a CANARY line referencing the governance REQ (currently REQ-GQL-010) with a unique ASPECT name.
4. Extend positive governance test to assert presence & ok=true.
5. (Optional) Add a negative test to simulate failure.

## Developer Workflow

```bash
# Run governance locally
zig run scripts/governance_ci.zig

# View summary only
zig run scripts/governance_ci.zig | jq

# Regenerate status (direct CANARY scan)
./bin/canaryscan --root . --out status.json --csv status.csv --verify docs/GAP_ANALYSIS.md --strict
```

## Common Failure Scenarios

| Symptom                               | Likely Cause                                                       | Fix                                                           |
| ------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------- |
| `doc_consistency` fail                | Forgot to update README after new aspects                          | Run scanner, update counts in README + IMPLEMENTATION_REALITY |
| `gap_consistency` fail                | Manual edit to GAP_ANALYSIS table mismatched scanner output        | Re-run scanner, restore generated lines                       |
| `next_slices` fail                    | Missing `WHY:` / `WHAT:` / `ACCEPTANCE:` or malformed slice header | Add required sections, correct format                         |
| `slice_req_crosscheck` fail (header)  | Slice missing REQ token                                            | Add `(REQ-GQL-###)` to header                                 |
| `slice_req_crosscheck` fail (mapping) | REQ has no CANARY evidence                                         | Add at least one CANARY line for that REQ                     |

## Future Enhancements

- Include per-step timing histogram over time.
- Rich diff output listing removed REQs with contextual file origins.
- Grace period mechanism for `reality_freshness` (multi-day window by default) with reporting mode before enforcement.

## CANARY Reference

Governance requirements use `REQ-GQL-010` with distinct ASPECTs:

- `GovernanceCombinedCheck` (positive path)
- `GovernanceSliceReqCrosscheckNegative` (negative path test)
- Future additions should append new ASPECT names referencing REQ-GQL-010.

---

Generated 2025-09-22
