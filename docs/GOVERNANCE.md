# Governance Automation & Evidence Integrity

This document consolidates all automation steps, guard scripts, and policies ensuring that Geode's documentation and implementation evidence (**CANARY** system) remain synchronized and drift-resistant.

## Overview

Governance automation validates:

1. Evidence ledger freshness & counts (`status.csv` / `status.json`).
2. Cross-document consistency (README, GAP_ANALYSIS, IMPLEMENTATION_REALITY, NEXT).
3. Slice structure + requirement mapping (each slice enumerates exactly one REQ ID; every REQ used is declared).
4. Variance envelope floor claims (README "Variance Guards Landed" qualifier) vs actual BENCHED variance envelopes.
5. No silent removal of REQ IDs (delta guard).

All critical checks are composed in `scripts/governance_ci.zig` and runnable via `make governance-check`.

## Key Artifacts

| File                                  | Purpose                                                                                                                         |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `status.csv` / `status.json`          | Machine-extracted evidence ledger (TESTED / BENCHED aspects). For count-based checks, `status.csv` is the authoritative source. |
| `docs/GAP_ANALYSIS.md`                | Human-readable structured gap & evidence summary regenerated from scanner.                                                      |
| `docs/IMPLEMENTATION_REALITY.md`      | Narrative alignment with current evidence snapshot (date-guarded).                                                              |
| `docs/NEXT.md`                        | Forward plan (Generated date freshness guarded).                                                                                |
| `docs/VARIANCE_ENVELOPES.md`          | Canonical registry of all variance envelopes with thresholds & exceptions.                                                      |
| `docs/GOVERNANCE.md`                  | (This file) Consolidated governance policy & guard reference.                                                                   |
| `scripts/generate_badges.zig`         | Produces SVG badge summarizing TOTAL / TESTED / BENCHED counts.                                                                 |
| `scripts/variance_envelope_guard.zig` | Enforces README variance guard floor vs actual count.                                                                           |
| `scripts/governance_ci.zig`           | Orchestrates multi-step governance checks (JSON summary output).                                                                |
| `scripts/governance_trend_append.zig` | Appends current evidence metrics to `badges/history.jsonl` (time-series).                                                       |
| `scripts/badge_staleness_guard.zig`   | Ensures `badges/evidence.svg` is fresh relative to `status.json` timestamp.                                                     |

## Governance Steps (Pipeline)

| Step Name                 | Description                                                                      | Source / Implementation               |
| ------------------------- | -------------------------------------------------------------------------------- | ------------------------------------- |
| `freshness`               | Verifies `docs/NEXT.md` Generated date is today's date.                          | `scripts/governance_ci.zig`           |
| `canary`                  | Runs CANARY scanner: emits / validates `status.json` & `status.csv`.             | `bin/canaryscan`                      |
| `variance_envelope_guard` | README claim for variance envelopes meets actual count & floor.                  | `scripts/variance_envelope_guard.zig` |
| `doc_consistency`         | README & IMPLEMENTATION_REALITY counts match scanner summary (derived from CSV). | `scripts/governance_ci.zig`           |
| `gap_consistency`         | Ensures GAP_ANALYSIS tables reflect current counts (derived from CSV).           | `scripts/governance_ci.zig`           |
| `next_slices`             | Structural validation of slice sections (WHY / WHAT / ACCEPTANCE).               | `scripts/governance_ci.zig`           |
| `slice_req_crosscheck`    | Slice REQ IDs each map to exactly one requirement; must exist in ledger.         | `scripts/governance_ci.zig`           |
| `evidence_delta`          | Detect removed requirement IDs vs previous snapshot (prevents silent deletions). | `scripts/governance_ci.zig`           |
| `reality_freshness`       | IMPLEMENTATION_REALITY date matches current evidence snapshot date.              | `scripts/governance_ci.zig`           |
| `badge_generation`        | Generates SVG evidence coverage badge (`badges/evidence.svg`).                   | `scripts/generate_badges.zig`         |
| `trend_append`            | Appends latest counts into historical log `badges/history.jsonl`.                | `scripts/governance_trend_append.zig` |
| `badge_staleness`         | Ensures evidence badge freshness vs `status.json` `generated_at`.                | `scripts/badge_staleness_guard.zig`   |

## Variance Envelope Guard

The README uses a qualitative floor expression (e.g., `Variance Guards Landed: 70+`). This guard prevents drift:

Command:

```bash
zig run scripts/variance_envelope_guard.zig -- \
  --status status.csv \
  --readme README.md \
  --min 70 \
  --require-phrase
```

Exit codes:

| Code | Meaning                                                        |
| ---- | -------------------------------------------------------------- |
| 0    | Policy satisfied                                               |
| 2    | Policy violation (count below floor OR phrase mismatch/absent) |
| 1    | Usage / internal error                                         |

JSON output example:

```json
{
  "type": "variance_envelope_guard",
  "count": 73,
  "min": 70,
  "ok": true,
  "readme_phrase_found": true,
  "readme_ok": true,
  "status": "success"
}
```

README phrase parsing rules:

1. Search for literal `Variance Guards Landed`.
2. Accept syntax: `Variance Guards Landed: <N>` or `Variance Guards Landed: <N>+` (colon may be followed by spaces or a dash).
3. `N+` form: actual count must be `>= N`.
4. Plain `N` form: actual count must equal `N`.

Counting algorithm: number of CSV rows whose `aspect` column contains `VarianceEnvelope`. Distinct line entries are counted (multiple aspects referencing the same base feature still count individually—intent is transparency of all enforced performance guards).

## Badge Generation

An SVG summarizing evidence coverage (TOTAL / TESTED / BENCHED) can be produced for embedding:

```bash
zig run scripts/generate_badges.zig -- --status status.csv --out badges/evidence.svg
```

Color thresholds (coverage = (TESTED+BENCHED)/TOTAL):

| Coverage | Color                 |
| -------- | --------------------- |
| >=99.9%  | `#4c1` (bright green) |
| >=95%    | `#97CA00`             |
| >=85%    | `#dfb317`             |
| >=70%    | `#fe7d37`             |
| <70%     | `#e05d44` (red)       |

Embed in README (once generated):

```markdown
![Evidence Coverage](badges/evidence.svg)
```

CI may choose to (a) commit the generated SVG or (b) regenerate on demand during docs build. For deterministic pipelines, committing is acceptable because the badge is a derivative of authoritative scanner output.

## Adding New Evidence

1. Implement feature / performance guard.
2. Add CANARY lines to source or tests with correct metadata (REQ ID, FEATURE, ASPECT, STATUS, TEST/BENCH names, UPDATED=today).
3. Run `make governance-check` to ensure no regressions.
4. If adding a variance envelope, also append it to logical grouping in `docs/VARIANCE_ENVELOPES.md` (alphabetical within group preferred) and re-run guards.

## Failure Triage

| Failure                                        | Common Causes                              | Remediation                                                        |
| ---------------------------------------------- | ------------------------------------------ | ------------------------------------------------------------------ |
| `variance_envelope_guard: ... readme_ok=false` | README number too low/high; phrase missing | Adjust README claim or update aspect lines / CANARY entries        |
| `evidence_delta`                               | Requirement ID removed or renamed          | Reintroduce ID or document intentional removal with migration note |
| `freshness`                                    | Generated date stale                       | Regenerate `docs/NEXT.md` or update date if content still valid    |
| `reality_freshness`                            | IMPLEMENTATION_REALITY date drift          | Re-run reality synthesis tool generating updated report            |
| `doc_consistency`                              | Counts mismatch                            | Run scanner, update README counts, avoid manual edits without scan |

## Make Targets

| Target                            | Action                                                                         |
| --------------------------------- | ------------------------------------------------------------------------------ |
| `make governance-check`           | Run combined governance pipeline (all integrated steps).                       |
| `make governance-badge`           | Generate evidence badge SVG only.                                              |
| `make governance-variance-guard`  | Run variance envelope guard with repo defaults.                                |
| `make governance-trend-append`    | Append a new trend line to `badges/history.jsonl` (idempotent for same stamp). |
| `make governance-badge-staleness` | Enforce freshness of `badges/evidence.svg` vs `status.json` (optional gate).   |

Notes:

- `trend_append` is already part of the combined pipeline; standalone target useful for ad‑hoc replays.
- `badge_staleness_guard` is currently an optional CI gate (not yet integrated into combined pipeline to allow staggered adoption).

## Policy Summary

| Policy                   | Statement                                                                             |
| ------------------------ | ------------------------------------------------------------------------------------- |
| Evidence Completeness    | Target is 0 STUB / 0 IMPL residuals; current counts are tracked from `status.csv`.    |
| Freshness                | All UPDATED dates < 60 days old under `--strict`.                                     |
| Variance Guard Floor     | README floor (N+) must be satisfied by live count.                                    |
| Single-Purpose Promotion | Each PR should promote at most one aspect per requirement to prevent hidden bundling. |
| Determinism Thresholds   | Default CV ≤ 0.22 & p95/mean ≤ 2.55 (exceptions documented in VARIANCE_ENVELOPES).    |

## Extensibility

Future extensions may add:

- `trend_regression_guard` — verifies rolling mean stays within historical confidence bands.
- `slice_delta_guard` — enforces net slice count change annotation in PR description.
- `badge_integrity_hash` — embeds a hash of `status.json` counts in the SVG (tamper detection) with a validator guard.

Recently added (now implemented):

- `badge_staleness_guard` — implemented as `scripts/badge_staleness_guard.zig` & `make governance-badge-staleness`.

## JSON Output (Governance Combined)

`governance_ci.zig` prints a summary line similar to:

```json
{
  "type": "governance_summary",
  "status": "success",
  "steps": [
    { "name": "freshness", "ok": true },
    { "name": "canary", "ok": true },
    { "name": "variance_envelope_guard", "ok": true },
    { "name": "doc_consistency", "ok": true },
    { "name": "gap_consistency", "ok": true },
    { "name": "next_slices", "ok": true },
    { "name": "slice_req_crosscheck", "ok": true },
    { "name": "evidence_delta", "ok": true },
    { "name": "reality_freshness", "ok": true },
    { "name": "badge_generation", "ok": true },
    { "name": "badge_staleness", "ok": true },
    { "name": "trend_append", "ok": true }
  ]
}
```

Consumers (CI, dashboards) SHOULD treat absence of a step as unknown (not failure) to allow incremental adoption.

## CI Example (GitHub Actions)

Below is a minimal CI job that runs the CANARY scanner in strict mode and executes the consolidated governance pipeline. It also captures artifacts for debugging.

```yaml
name: governance
on:
  push: {}
  pull_request: {}
jobs:
  canary-governance:
    runs-on: ubuntu-22.04
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Setup Zig 0.15.1
        uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.15.1
      - name: Setup Go
        uses: actions/setup-go@v5
        with:
          go-version: '1.22'
      - name: Build canary scanner
        run: go build -o ./bin/canaryscan ./tools/canaryscan
      - name: Strict verify GAP_ANALYSIS vs evidence
        run: ./bin/canaryscan --root . --out status.json --csv status.csv --verify docs/GAP_ANALYSIS.md --strict
      - name: Governance summary
        run: zig run scripts/governance_ci.zig | tee governance_summary.jsonl
      - name: Upload artifacts
        uses: actions/upload-artifact@v4
        if: always()
        with:
          name: governance-artifacts
          path: |
            status.json
            status.csv
            badges/evidence.svg
            governance_summary.jsonl
  telemetry-smoke:
    runs-on: ubuntu-22.04
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Setup Zig 0.15.1
        uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.15.1
      - name: Build binaries
        run: zig build -Doptimize=ReleaseSafe
      - name: Run telemetry smoke (soft)
        env:
          GEODE_CI_TELEMETRY_SMOKE: '1'
        run: |
          export GEODE_CI_TELEMETRY_STRICT="${GEODE_CI_TELEMETRY_STRICT:-0}"
          zig test test_telemetry_smoke.zig || true
```

Notes:

- This workflow mirrors `make governance-check` while surfacing individual steps. For full parity, simply run `make governance-check` after building the scanner.
- Pin Zig and Go versions to ensure deterministic outputs and reliable strict freshness checks.
- Telemetry job defaults to soft mode. To enforce presence of `PULL_PAGE` telemetry, set `GEODE_CI_TELEMETRY_STRICT=1` in the job environment or repository variables.

### Nightly Governance (Scheduled)

Use a scheduled workflow to refresh evidence, regenerate the badge, enforce badge freshness, append trend history, and emit a nightly governance summary. This does not run strict GAP verification by default (keeps nightly green unless there is a staleness issue):

```yaml
name: nightly-governance
on:
  schedule:
    - cron: '17 3 * * *'
  workflow_dispatch: {}
jobs:
  nightly-governance:
    runs-on: ubuntu-22.04
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Setup Zig 0.15.1
        uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.15.1
      - name: Setup Go
        uses: actions/setup-go@v5
        with:
          go-version: '1.22'
      - name: Build canary scanner
        run: go build -o ./bin/canaryscan ./tools/canaryscan
      - name: Run scanner (non-strict) and write evidence
        run: ./bin/canaryscan --root . --out status.json --csv status.csv
      - name: Governance badge
        run: zig run scripts/generate_badges.zig -- --status status.csv --out badges/evidence.svg
      - name: Badge staleness guard
        run: zig run scripts/badge_staleness_guard.zig -- --status status.json --badge badges/evidence.svg --max-days 2
      - name: Governance trend append
        run: zig run scripts/governance_trend_append.zig
      - name: Combined governance summary
        run: zig run scripts/governance_ci.zig | tee governance_summary_nightly.jsonl
      - name: Upload nightly artifacts
        uses: actions/upload-artifact@v4
        with:
          name: nightly-governance-artifacts
          path: |
            status.json
            status.csv
            badges/evidence.svg
            governance_summary_nightly.jsonl
            badges/history.jsonl
```

---

Maintainers: keep this file minimal, normative, and synchronized with any added guard script flags. All non-trivial guard behavior changes must update this reference to avoid implicit policy shifts.

## Governance Automation (Detailed Reference)

This section expands operational specifics of the governance steps enforced by `scripts/governance_ci.zig`. All steps output a JSON summary (`governance_summary`). A failing step returns exit code 2 (policy violation) or >2 for internal errors.

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
