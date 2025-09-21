# PROMPTS — Geode (CANARY-Enabled)

> This file extends the existing prompt library with a **CANARY tokens policy** and a **CANARY-enabled evaluation prompt** that force-links requirements (REQ-GQL-###) to code and tests. Existing sections are preserved; new sections are appended.

## NEW — CANARY Policy & Patterns

**Goal:** Make every feature claim **searchable and verifiable** by tagging code/tests with **CANARY** lines that reference **REQ-GQL-###** IDs (canonical).

### 1) CANARY comment line (language-agnostic)

Insert a single line near the implementing function or file header:

```text
# TEMPLATE (scanner-ignored): change prefix from CANARY: -> CANARY_TEMPLATE: to avoid fake STUB row
CANARY_TEMPLATE: REQ=REQ-GQL-042; FEATURE="CDC/Streaming"; ASPECT=API|Engine|Planner|Wire|Security|Storage|Docs|CLI|Decode|Encode|RoundTrip|Bench; STATUS=MISSING|STUB|IMPL|TESTED|BENCHED|REMOVED; TEST=TestCANARY_REQ_GQL_042_CDC_StartStop; BENCH=BenchmarkCANARY_REQ_GQL_042_CDC_Publish; OWNER=streaming; UPDATED=YYYY-MM-DD
```

**Examples**

```zig
// Example (updated): REQ=REQ-GQL-042 CDC Engine API already TESTED elsewhere; avoid adding duplicate STUB lines here.
```

```go
// CANARY: REQ=REQ-GQL-046; FEATURE="TDE"; ASPECT=Storage; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_046_KeyRotate; OWNER=security; UPDATED=2025-09-20
```

// CANARY: REQ=REQ-GQL-005; FEATURE="Binary Protocol Core"; ASPECT=Wire; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_005_HelloRoundTrip; OWNER=wire; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-028; FEATURE="WAL Compaction"; ASPECT=Storage; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_028_WalCompact; BENCH=BenchmarkCANARY_REQ_GQL_028_WalCompact; OWNER=storage; UPDATED=2025-09-20

### 2) Test & Benchmark naming

- Tests: `TestCANARY_REQ_GQL_<###>_<Aspect>_<Short>`
- Benches: `BenchmarkCANARY_REQ_GQL_<###>_<Aspect>_<Short>`

### 3) Status values (finite)

`MISSING, STUB, IMPL, TESTED, BENCHED, REMOVED` (case-sensitive).

### 4) Scanner & CI

Use `tools/canaryscan` (Go 1.24) to generate `status.json` / `status.csv` and to **verify** GAP/claims:

- `--verify GAP_ANALYSIS.md` fails if a row claims ✅ without CANARY **TESTED/BENCHED**.
- `--strict` fails if `UPDATED` on TESTED/BENCHED > 60 days old.

#### 4.1 Auto-Promotion Semantics

The scanner performs a deterministic, evidence-based status promotion (may be disabled in future via a `--no-promote` flag):

| Base Status | Condition                 | Promoted To |
| ----------- | ------------------------- | ----------- |
| IMPL        | ≥1 test name present      | TESTED      |
| IMPL/TESTED | ≥1 benchmark name present | BENCHED     |

Rules:

1. Promotion never downgrades existing TESTED/BENCHED declarations.
2. BENCHED is the strongest (supersedes TESTED for summary counts).
3. Promotion operates per feature entry; different aspects under same REQ can have different promoted states.
4. `UPDATED` date is not rewritten; authors must keep dates fresh for `--strict` to pass.
5. If future `--no-promote` is introduced, raw statuses will be emitted and summaries may differ.

Rationale: encourages early tagging of tests/benches while keeping authors honest about date freshness and explicit evidence lines.

---

## NEW — FINAL CODING PROMPT — Evaluate Code vs. Requirements (CANARY-Enabled)

**References (normative)**:

- Requirements & acceptance: `copilot-instructions.md`.
- Conformance/claims: `GAP_ANALYSIS.md`, `NEXT.md`, `CONFORMANCE_MATRIX.md`, `API_DOCUMENTATION.md`, status docs.
- Truth preference: favor the **most specific reality checks** over marketing claims.

### T — Task & Role

You are a senior **Go 1.24** engineer/docs maintainer. **Adopt CANARY tokens repo-wide**, run the scanner, and **update `GAP_ANALYSIS.md` and `NEXT.md`** to the **tested truth**. Do **not** add license text/headers.

### A — Action Steps

1. Add CANARY lines for each touched area (see policy above).
2. Build and run `tools/canaryscan`:

   ```bash
   go build -o ./bin/canaryscan ./tools/canaryscan
   ./bin/canaryscan --root . --out status.json --csv status.csv
   ./bin/canaryscan --root . --verify GAP_ANALYSIS.md --strict
   ```

3. Reconcile contradictions: when docs claim ✅ but CANARY shows STUB/MISSING, **downgrade**.
4. Replace `GAP_ANALYSIS.md` with a CANARY-evidence-driven version.
5. Rewrite `NEXT.md` as **small, verifiable slices**, each adding/updating CANARY tests.

### R — Result Format (strict)

1. `files:` list; 2) `updated_files:` full Markdown replacements; 3) `evidence:` (`status.json` snippet, verify results); 4) `rationale:` (≤7 bullets); 5) `notes:` approvals.

### S — Constraints

- IDs: **REQ-GQL-###** only.
- Scanner: Go stdlib; exit codes 0 ok, 2 verify fail, 3 parse error.
- No API renames; artifacts treated as **data only**.

### Interfaces & I/O

`canaryscan [--root .] [--out status.json] [--csv status.csv] [--verify GAP_ANALYSIS.md] [--strict]`

### Tests — Acceptance (for the scanner)

1. **Fixture parse** → summary JSON line with counts for STUB/IMPL.
2. **Verify over-claim** → exit 2 with `CANARY_VERIFY_FAIL REQ=...`.
3. **Strict staleness** → exit 2 with `CANARY_STALE`.

\_(Embed each acceptance name in tests as `TestCANARY\__`/`BenchmarkCANARY\__`.)\_

---

## (Existing) ISO‑GQL Auditor — System Prompt (v1.1)

Goal: Re‑evaluate repo against ISO/IEC 39075:2024 (GQL) and project docs (research.md, query_engine.md).
Deliver GAP_ANALYSIS.md (tables), NEXT.md (execution backlog), and any patches needed to keep docs
consistent. Cite ISO subclauses; paraphrase; quotes ≤25 words with anchors. Track implementation‑defined
(I:) and implementation‑dependent (U:) policies. Ensure README links to conformance tables.

Inputs: ISO_IEC_39075_2024(en).pdf; research.md; query_engine.md; GAP_ANALYSIS.md; NEXT.md; README.md;
all source under src/** and tests/**.

Deliverables:

1. GAP_ANALYSIS.md: authoritative requirements ledger table + Conformance Profile table.
2. NEXT.md: Now/Next/Later backlog with Why/What/Acceptance/ISO/Deps/Scope/DRI per task.
3. query_engine.md (if needed): GQL→Engine Crosswalk and any clarifications.
4. research.md (if needed): tightened scope to ISO terms.
5. README.md: Status & Conformance Summary linking to GAP tables.

Constraints & Evidence: Cite ISO (e.g., 14.3, 16.16–16.19, 23.2, 24.\*). Evidence must be file:line or
specific test names. Include flagger findings evidence when applicable.

Version: 1.1 (2025‑09‑10).
