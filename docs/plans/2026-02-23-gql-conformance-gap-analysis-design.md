# GQL Conformance Gap Analysis, Tests, and Fixes — Design

**Date:** 2026-02-23
**Author:** Claude Code
**Scope:** ISO/IEC 39075:2024 GQL conformance evaluation against `specs/gql/GQL-conformance-ref.md`

---

## Summary

This document describes the design for a full conformance evaluation of Geode against the 24
requirements in `specs/gql/GQL-conformance-ref.md`, producing:

1. `docs/GQL_CONFORMANCE_GAP_ANALYSIS.md` — gap analysis document
2. `src/tests/test_gql_conformance_rq.zig` — unit tests for all 24 requirements (test-first)
3. `../geode-test-harness/geodetestlab-cli/specs/gql_conformance_39075.yml` — integration specs
4. Fixes for all identified gaps (layer-by-layer implementation)

---

## Gap Assessment

| RQ | Requirement | Current Status | Gap Description |
|---|---|---|---|
| RQ-0001 | Execute conforming programs | PARTIAL | No published conformance suite runner verifying all 24 RQs |
| RQ-0002 | Reject required errors | PARTIAL | Some required errors lack correct SQLSTATE codes |
| RQ-0003 | GQL Flagger when extending | PARTIAL | Flagger only covers zero-length paths (1 of ~116 impl-defined items) |
| RQ-0004 | Conformance claim completeness | **GAP** | Profile struct missing ISO feature IDs (GG01, GT01, GA08, etc.) |
| RQ-0005 | Minimum conformance (GG01/GG02+GG20-23) | **GAP** | ISO feature codes not declared anywhere |
| RQ-0006 | Unicode ≥ 13.0.0 | **GAP** | Unicode version not documented or declared in conformance profile |
| RQ-0007 | Min types (STRING, BOOL, INT, FLOAT) | IMPL | Types present but not explicitly declared in conformance profile |
| RQ-0008 | Source text character repertoire | PARTIAL | Character acceptance not formally declared |
| RQ-0009 | Exactly one default collation | **GAP** | No collation declaration in conformance profile |
| RQ-0010 | String max length ≥ 16383 chars | **GAP** | Not declared or enforced |
| RQ-0011 | Confusable never self-confusable | **GAP** | No confusable detection implemented |
| RQ-0012 | Confusable identifiers → 42004 | **GAP** | SQLSTATE 42004 missing; no detection logic |
| RQ-0013 | UTC-SLS timescale | **GAP** | Not documented in conformance profile |
| RQ-0014 | Temporal literals ISO 8601 or SQL | PARTIAL | Parser handles it; not formally declared |
| RQ-0015 | Seconds precision ≥ 6 (IL024) | IMPL | Microseconds used; not declared as IL024 = 6 |
| RQ-0016 | Bytestring max length ≥ 65534 bytes | **GAP** | Not declared |
| RQ-0017 | Session params start "_" | **GAP** | Not enforced |
| RQ-0018 | Diagnostic fields "_" + GA08 gating | PARTIAL | No GA08 feature flag; diagnostic codes exist |
| RQ-0019 | Privilege → 42000 | PARTIAL | 42000 exists but labeled INVALID_SCHEMA (wrong semantics) |
| RQ-0020 | Connection-loss → 40003/08007 | **GAP** | Neither SQLSTATE code exists in status.zig |
| RQ-0021 | Impl transactions = explicit | PARTIAL | Transactions exist; equivalence not formally verified |
| RQ-0022 | Keywords case-insensitive | IMPL | Lexer handles this correctly |
| RQ-0023 | Without GT01: reject transactions | **GAP** | GT01 feature flag not tracked; no enforcement |
| RQ-0024 | All impl-defined items defined | **GAP** | Only zero-length paths declared; Annex B items not enumerated |

**Summary:** 9 full gaps, 6 partial gaps, 4 implemented-but-undeclared, 5 require conformance profile additions.

---

## Architecture: Layer-by-Layer Implementation

### Layer 1 — Conformance Profile (`src/conformance.zig`)

**What it does:** Extend the existing `Profile` struct to declare all ISO feature IDs and
implementation-defined choices required by the standard.

**Changes:**

- Add `IsoFeatures` struct: `GG01`, `GG02`, `GG20`–`GG23`, `GT01`, `GA08` boolean flags
- Add `ImplDefined` struct for Annex B items: unicode_version, default_collation,
  char_repertoire, string_max_length (16383), bytestring_max_length (65534),
  seconds_precision (6), temporal_format, utc_sls, session_param_prefix
- `writeConformanceJson` emits all new fields

**Fixes:** RQ-0004, 0005, 0006, 0007, 0008, 0009, 0010, 0013, 0014, 0015, 0016, 0017, 0024

---

### Layer 2 — SQLSTATE Codes (`src/gql/status.zig`)

**What it does:** Add missing standard SQLSTATE codes and fix mislabeled ones.

**Changes:**

- `CONFUSABLE_IDENTIFIER = "42004"` — new
- `PRIVILEGE_VIOLATION = "42000"` — rename from `INVALID_SCHEMA` (correct semantics)
- `TRANSACTION_ROLLBACK = "40003"` — connection failure during statement
- `CONNECTION_FAILURE_COMMIT = "08007"` — connection failure during commit
- Helper functions: `confusableIdentifier()`, `privilegeViolation()`, `connectionFailure()`,
  `connectionFailureCommit()`

**Fixes:** RQ-0012 (SQLSTATE), RQ-0019 (label), RQ-0020

---

### Layer 3 — Feature Gating

**GA08 Diagnostic Gating** (`src/server/server_flags.zig`, `src/gql/status.zig`):

- Add `ga08_diagnostics_enabled: bool` to server flags
- Diagnostic record payloads suppressed when GA08 = false

**GT01 Transaction Commands** (`src/gql/parser.zig` or `src/server/`):

- When `gt01_explicit_transactions = false`, parsing/executing START TRANSACTION / END TRANSACTION
  raises a conformance error

**Flagger expansion** (`src/flagger_impl_defined.zig`):

- Expand to enumerate all impl-defined decisions from the conformance profile

**Fixes:** RQ-0003, RQ-0018, RQ-0023

---

### Layer 4 — Temporal Conformance (`src/temporal.zig`, conformance profile)

**What it does:** Document UTC-SLS timescale and verify ISO 8601 literal parsing.

**Changes:**

- Add `utc_sls` declaration in conformance profile
- Add assertions in `temporal.zig` that sub-second precision = 6 (microseconds)
- Add test that verifies ISO 8601 temporal literal parse round-trips

**Fixes:** RQ-0013, RQ-0014

---

### Layer 5 — Confusable Identifier Detection

**What it does:** Implement Unicode confusable skeleton algorithm to detect visually
confusable identifier pairs in the same GQL program.

**Components:**

- `src/unicode/confusables.zig` — skeleton algorithm + embedded confusable mapping
  (compact subset from UCD `confusables.txt`, ~2500 most-used entries)
- Integration point: parser's identifier registration phase
- Raises SQLSTATE 42004 for confusable pairs
- Guarantees: `confusable(s, s)` always returns false (RQ-0011)

**Algorithm:** Unicode TR#39 skeleton algorithm:

1. Apply NFD normalization to identifier
2. Map each character via confusables map to its skeleton
3. Apply NFD to skeleton
4. Two identifiers are confusable if their skeletons are identical (case-insensitively)

**Fixes:** RQ-0011, RQ-0012

---

### Layer 6 — Unit Tests (`src/tests/test_gql_conformance_rq.zig`)

One test per requirement, naming pattern: `TestCANARY_GQL39075_RQ_####_<ShortName>`.

Tests for unimplemented gaps will initially fail. After fixes, all pass.

**Also:** Add `@import("test_gql_conformance_rq.zig")` to `tests/all_tests.zig`.

---

### Layer 7 — Geodetestlab Specs (`../geode-test-harness/geodetestlab-cli/specs/gql_conformance_39075.yml`)

Black-box integration tests for all 24 requirements, grouped by CK-001 through CK-009.
Format: same as existing specs in that directory.

---

### Layer 8 — Gap Analysis Document (`docs/GQL_CONFORMANCE_GAP_ANALYSIS.md`)

Same table format as `docs/GAP_ANALYSIS.md`:

- 24 findings
- Status: Open / Closed / Won't Do
- Each with evidence (file:line), requirement ID, fix description

---

## Files Created/Modified

| File | Action | Description |
|---|---|---|
| `docs/GQL_CONFORMANCE_GAP_ANALYSIS.md` | CREATE | Gap analysis document |
| `src/conformance.zig` | MODIFY | Add ISO feature IDs, impl-defined declarations |
| `src/gql/status.zig` | MODIFY | Add 42004, fix 42000, add 40003, 08007 |
| `src/server/server_flags.zig` | MODIFY | Add GA08 and GT01 feature flags |
| `src/unicode/confusables.zig` | CREATE | Skeleton algorithm + compact confusable data |
| `src/flagger_impl_defined.zig` | MODIFY | Expand to cover all impl-defined items |
| `src/tests/test_gql_conformance_rq.zig` | CREATE | 24 unit tests (one per RQ) |
| `tests/all_tests.zig` | MODIFY | Import new test file |
| `../geode-test-harness/geodetestlab-cli/specs/gql_conformance_39075.yml` | CREATE | Integration specs |

---

## Test Strategy

**Unit tests (Zig):** Pure functions — test conformance profile serialization, SQLSTATE codes,
confusable skeleton algorithm, feature flag enforcement. No server required.

**Integration specs (geodetestlab):** Black-box tests against a running server — keyword
case-insensitivity, temporal literal parsing, privilege rejection (42000), transaction command
rejection without GT01, diagnostic record suppression without GA08.

**Test-first:** Tests for gaps are written before fixes. After layer 1-5 implementation, all
24 unit tests must pass. Integration specs verify runtime behavior.
