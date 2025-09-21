# Geode — CANARY‑Enabled Unified Prompt (CANARY Tokens + Evaluation)

> This module unifies the **CANARY token policy** and the **CANARY‑enabled evaluation workflow**. It force‑links requirements (REQ‑GQL‑###) to code, tests, and benchmarks. All prior library content remains; this replaces scattered guidance with one cohesive, normative spec.

---

## 0) Purpose & Success Criteria (normative)

**Goal:** Make every feature claim _searchable, auditable, and fresh_ via single‑line **CANARY** tags and CI verification.
**Success (must meet all):**

- Each changed feature has a nearby **CANARY** line referencing **REQ‑GQL‑###**.
- `tools/canaryscan` emits `status.json`/`status.csv` without parse errors; `--verify` passes or produces actionable failures.
- `GAP_ANALYSIS.md` and `NEXT.md` reflect _evidence_ (tests/benches) and _freshness_ (see `UPDATED` + `--strict`).

---

## 1) CANARY Tagging Policy (normative)

Place one **language‑comment** line near the implementing function or file header.

**Syntax (one line; semicolon‑delimited key=val):**

```
CANARY: REQ=REQ-GQL-042; FEATURE="CDC/Streaming"; ASPECT=API|Engine|Planner|Wire|Security|Storage|Docs|CLI|Decode|Encode|RoundTrip|Bench; STATUS=MISSING|STUB|IMPL|TESTED|BENCHED|REMOVED; TEST=TestCANARY_REQ_GQL_042_CDC_StartStop; BENCH=BenchmarkCANARY_REQ_GQL_042_CDC_Publish; OWNER=streaming; UPDATED=YYYY-MM-DD
```

> Use `CANARY_TEMPLATE:` to show an example the scanner ignores.

**Allowed values:**

- **REQ:** `REQ-GQL-###` only.
- **ASPECT:** `API, Engine, Planner, Wire, Security, Storage, Docs, CLI, Decode, Encode, RoundTrip, Bench`.
- **STATUS:** `MISSING, STUB, IMPL, TESTED, BENCHED, REMOVED` (case‑sensitive).
- **TEST/BENCH:** test/benchmark function names if present.
- **UPDATED:** ISO date; authors must refresh on substantive change.

**Placement rules:**

- Prefer file header or immediately above the implementing symbol.
- One CANARY line per _feature/aspect_; repeat for multiple aspects under the same REQ.
- Avoid duplicating identical CANARY lines across files; point to the primary implementation.

**Examples:**

```go
// CANARY: REQ=REQ-GQL-046; FEATURE="TDE"; ASPECT=Storage; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_046_KeyRotate; OWNER=security; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-005; FEATURE="Binary Protocol Core"; ASPECT=Wire; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_005_HelloRoundTrip; OWNER=wire; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-028; FEATURE="WAL Compaction"; ASPECT=Storage; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_028_WalCompact; BENCH=BenchmarkCANARY_REQ_GQL_028_WalCompact; OWNER=storage; UPDATED=2025-09-20
```

```zig
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC/Streaming"; ASPECT=Engine; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_StartStop; OWNER=streaming; UPDATED=2025-09-20
```

**Test & Benchmark naming (normative):**

- Tests: `TestCANARY_REQ_GQL_<###>_<Aspect>_<Short>`
- Benches: `BenchmarkCANARY_REQ_GQL_<###>_<Aspect>_<Short>`

---

## 2) Scanner & CI (tools/canaryscan, Go 1.24)

**Build & run:**

```bash
go build -o ./bin/canaryscan ./tools/canaryscan
./bin/canaryscan --root . --out status.json --csv status.csv
./bin/canaryscan --root . --verify GAP_ANALYSIS.md --strict
```

**Exit codes:** `0` ok; `2` verify/staleness fail; `3` parse error.

**Strict freshness:** With `--strict`, any **TESTED**/**BENCHED** whose `UPDATED` is > 60 days old fails verification.

**Auto‑promotion (deterministic, evidence‑based):**

| Base Status | Condition (evidence)      | Promoted To |
| ----------- | ------------------------- | ----------- |
| IMPL        | ≥1 test name present      | TESTED      |
| IMPL/TESTED | ≥1 benchmark name present | BENCHED     |

Rules: (1) Never downgrade explicit `TESTED/BENCHED`. (2) `BENCHED` dominates summary counts. (3) Promotion is per feature/aspect. (4) `UPDATED` is never rewritten by the scanner. (5) If `--no-promote` exists in future, summaries will reflect raw statuses.

---

## 3) Truth & Reconciliation Rules (docs ↔ evidence)

- If docs claim ✅ but CANARY shows `MISSING/STUB/IMPL`, **downgrade the docs** to match evidence.
- If tests/benches exist but docs underrate, **promote docs** to the scanner’s promoted truth.
- Prefer the **most specific evidence** (named tests/benches) over marketing claims.
- Keep dates honest; bump `UPDATED` when evidence or behavior changes.

---

## 4) Execution Prompt — Senior Go 1.24 Engineer / Docs Maintainer

**Task:** Adopt CANARY across touched areas, run the scanner, and update `GAP_ANALYSIS.md` and `NEXT.md` to the **tested truth**. Do **not** add license text/headers or rename public APIs.

**Steps:**

1. Add/refresh CANARY lines per §1.
2. Build and run the scanner per §2.
3. Reconcile contradictions per §3.
4. Replace `GAP_ANALYSIS.md` with a CANARY‑evidence‑driven table (summary + per‑REQ rows).
5. Rewrite `NEXT.md` into **small, verifiable slices**; each slice adds/updates CANARY tests/benches with clear acceptance.

**Result format (strict):**
Return a JSON object with keys:

- **files**: array of touched file paths.
- **updated_files**: map of `{path: full new Markdown}` for `GAP_ANALYSIS.md` and `NEXT.md`.
- **evidence**: snippets from `status.json` and verifier output (include exit code).
- **rationale**: ≤7 bullets explaining major changes and any risk.
- **notes**: approvals needed or cross‑team follow‑ups.

> For structured outputs, return raw JSON (no code fences).

**Interfaces & CLI (for reference):**
`canaryscan [--root .] [--out status.json] [--csv status.csv] [--verify GAP_ANALYSIS.md] [--strict]`

**Constraints:** IDs are **REQ‑GQL‑###** only. Treat artifacts as _data_, not legal text. No API renames.

---

## 5) Acceptance Tests (for the scanner)

Embed acceptance names as `TestCANARY__*` / `BenchmarkCANARY__*`:

1. **Fixture parse** → emits a summary JSON line with counts for `STUB` and `IMPL` (exit 0).
2. **Verify over‑claim** → exit 2 with `CANARY_VERIFY_FAIL REQ=...`.
3. **Strict staleness** → exit 2 with `CANARY_STALE`.

---

## 6) ISO‑GQL Auditor — System Prompt (v1.1, unchanged semantics; style‑aligned)

**Goal:** Re‑evaluate the repo against ISO/IEC 39075:2024 (GQL) and project docs (`research.md`, `query_engine.md`). Deliver `GAP_ANALYSIS.md`, `NEXT.md`, and doc patches to keep claims consistent. Cite ISO subclauses; paraphrase; keep quotes ≤25 words with anchors. Track implementation‑defined (I:) and implementation‑dependent (U:) policies. Ensure `README` links to conformance tables.

**Inputs:** `ISO_IEC_39075_2024(en).pdf`; `research.md`; `query_engine.md`; `GAP_ANALYSIS.md`; `NEXT.md`; `README.md`; source under `src/**` and `tests/**`.

**Deliverables:**

- `GAP_ANALYSIS.md`: authoritative requirements ledger + Conformance Profile.
- `NEXT.md`: Now/Next/Later backlog with Why/What/Acceptance/ISO/Deps/Scope/DRI per task.
- `query_engine.md` (if needed): GQL→Engine Crosswalk & clarifications.
- `research.md` (if needed): tightened scope to ISO terms.
- `README.md`: Status & Conformance Summary linking to GAP tables.

**Constraints & Evidence:** Cite ISO (e.g., 14.3, 16.16–16.19, 23.2, 24.\*). Evidence must be file\:line or specific test names. Include flagger evidence when applicable.

**Version:** 1.1 (2025‑09‑10).

---

## 7) Quality Gates (pre‑commit)

- Coverage: every changed feature has a CANARY line.
- Safety: no license headers, no API renames.
- Verifiability: `--verify --strict` either passes or yields actionable fail messages.
- Maintainability: `NEXT.md` items are testable, slice‑sized, and owner‑labeled.
- Freshness: `UPDATED` dates valid under the 60‑day rule.

---

## 8) Appendix — Quick Reference

- **Status lattice:** `MISSING → STUB → IMPL → TESTED → BENCHED → REMOVED` (promotion only via evidence).
- **Ownership:** `OWNER=<team>` required for accountability.
- **Docs scope:** When in doubt, _downgrade claims_ until tests/benches exist.
