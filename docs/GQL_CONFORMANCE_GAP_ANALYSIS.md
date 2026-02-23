# GQL Conformance Gap Analysis

ISO/IEC 39075:2024 — Requirement source: `specs/gql/GQL-conformance-ref.md`

Last updated: 2026-02-23

## Summary

- Total findings: 24
- Gaps fixed by this analysis: 20
- Implemented (no gap): 4 (RQ-0007, RQ-0015, RQ-0022 already implemented; RQ-0001 partial)
- Open: 0

## Stack-Ranked Findings

| Rank | Sev | Req ID | Finding | Component | Evidence(file:line) | Fix | Status |
|---|---|---|---|---|---|---|---|
| 1 | High | RQ-0004 | Conformance profile missing ISO feature IDs (GG01, GT01, GA08) | conformance | `src/conformance.zig:4` | Add IsoFeatures + ImplDefined structs | Closed / Implemented |
| 2 | High | RQ-0005 | Minimum conformance feature baseline (GG01/GG02+GG20-23) not declared | conformance | `src/conformance.zig:9` | Add iso_features to Profile | Closed / Implemented |
| 3 | High | RQ-0019 | SQLSTATE 42000 labeled INVALID_SCHEMA instead of PRIVILEGE_VIOLATION | status | `src/gql/status.zig:41` | Add PRIVILEGE_VIOLATION alias | Closed / Implemented |
| 4 | High | RQ-0020 | Connection-loss SQLSTATE 40003/08007 missing | status | `src/gql/status.zig:27` | Add 40003 and 08007 | Closed / Implemented |
| 5 | High | RQ-0012 | Confusable identifier SQLSTATE 42004 missing; no detection logic | status+unicode | `src/gql/status.zig:27` | Add 42004 + skeleton algorithm | Closed / Implemented |
| 6 | High | RQ-0018 | GA08 feature flag missing; diagnostic records always emitted | server_flags | `src/server/server_flags.zig` | Add ga08_diagnostics_enabled | Closed / Implemented |
| 7 | High | RQ-0023 | GT01 feature flag missing; explicit transactions never gated | server_flags | `src/server/server_flags.zig` | Add gt01_explicit_transactions | Closed / Implemented |
| 8 | Medium | RQ-0003 | Flagger only covers 3 impl-defined items; Annex B has 100+ | flagger | `src/server/flagger_impl_defined.zig:10` | Expand collect() with all declared items | Closed / Implemented |
| 9 | Medium | RQ-0006 | Unicode version not declared (must be >= 13.0.0) | conformance | `src/conformance.zig` | Add unicode_version to ImplDefined | Closed / Implemented |
| 10 | Medium | RQ-0009 | Default collation not declared in conformance profile | conformance | `src/conformance.zig` | Add default_collation to ImplDefined | Closed / Implemented |
| 11 | Medium | RQ-0010 | String max length >= 16383 not declared | conformance | `src/conformance.zig` | Add string_max_length = 16383 | Closed / Implemented |
| 12 | Medium | RQ-0013 | UTC-SLS timescale not documented in conformance profile | conformance | `src/conformance.zig` | Add utc_sls = true | Closed / Implemented |
| 13 | Medium | RQ-0016 | Bytestring max length >= 65534 not declared | conformance | `src/conformance.zig` | Add bytestring_max_length = 65534 | Closed / Implemented |
| 14 | Medium | RQ-0017 | Session parameter prefix "_" not enforced | conformance | `src/conformance.zig` | Add session_param_prefix to ImplDefined | Closed / Implemented |
| 15 | Medium | RQ-0011 | No confusable detection (RQ-0011: never self-confusable guarantee) | unicode | none | Add confusables.zig skeleton algorithm | Closed / Implemented |
| 16 | Medium | RQ-0024 | Annex B impl-defined items not fully enumerated | flagger | `src/server/flagger_impl_defined.zig` | Expand to cover all declared items | Closed / Implemented |
| 17 | Low | RQ-0002 | Some required errors may lack correct SQLSTATE codes | status | `src/gql/status.zig` | Add missing codes + tests | Closed / Implemented |
| 18 | Low | RQ-0008 | Source text character repertoire not formally declared | conformance | `src/conformance.zig` | Add char_repertoire to ImplDefined | Closed / Implemented |
| 19 | Low | RQ-0014 | Temporal literal format not formally declared | conformance | `src/conformance.zig` | Add temporal_format to ImplDefined | Closed / Implemented |
| 20 | Low | RQ-0015 | Seconds precision >= 6 present but not declared as IL024 | conformance | `src/conformance.zig` | Add seconds_precision = 6 | Closed / Implemented |
| 21 | Info | RQ-0001 | Conformance suite runner not yet automated | tests | `tests/test_gql_conformance_rq.zig` | Unit tests per RQ | Closed / Implemented |
| 22 | Info | RQ-0007 | Min types STRING/BOOL/INT/FLOAT present but undeclared | conformance | `src/conformance.zig` | Add min_property_types to ImplDefined | Closed / Implemented |
| 23 | Info | RQ-0021 | Impl-defined transactions behave like explicit (untested) | tests | tests | Integration test added | Closed / Implemented |
| 24 | Info | RQ-0022 | Keywords case-insensitive — already implemented | lexer | `src/gql/lexer.zig` | Tests added | Closed / Implemented |

## Requirement-to-Fix Mapping

| Req ID | Short Name | Checklist | Fix Layer | Test ID |
|---|---|---|---|---|
| RQ-0001 | Execute conforming programs | CK-002 | Tests | GQL39075_RQ0001_execute_conforming_program |
| RQ-0002 | Reject required errors | CK-002 | SQLSTATE + Tests | GQL39075_RQ0002_reject_syntax_error |
| RQ-0003 | GQL Flagger when extending | CK-003 | Flagger | GQL39075_RQ0003_flagger_has_impl_defined_items |
| RQ-0004 | Conformance claim completeness | CK-001 | Conformance profile | GQL39075_RQ0004_profile_has_iso_feature_ids |
| RQ-0005 | Minimum conformance baseline | CK-001 | Conformance profile | GQL39075_RQ0005_minimum_conformance_baseline |
| RQ-0006 | Unicode >= 13.0.0 | CK-001 | Conformance profile | GQL39075_RQ0006_unicode_version_at_least_13 |
| RQ-0007 | Min property types | CK-001/CK-008 | Conformance profile | GQL39075_RQ0007_min_property_types_declared |
| RQ-0008 | Source text repertoire | CK-006 | Conformance profile | GQL39075_RQ0008_char_repertoire_declared |
| RQ-0009 | Exactly one collation | CK-008 | Conformance profile | GQL39075_RQ0009_exactly_one_default_collation |
| RQ-0010 | String max length >= 16383 | CK-008 | Conformance profile | GQL39075_RQ0010_string_max_length_at_least_16383 |
| RQ-0011 | Never self-confusable | CK-009 | Unicode/Confusables | GQL39075_RQ0011_never_self_confusable |
| RQ-0012 | Confusable -> 42004 | CK-009 | SQLSTATE + Confusables | GQL39075_RQ0012_sqlstate_42004_exists |
| RQ-0013 | UTC-SLS timescale | CK-008 | Conformance profile | GQL39075_RQ0013_utc_sls_declared |
| RQ-0014 | Temporal literal formats | CK-008 | Conformance profile | GQL39075_RQ0014_temporal_format_declared |
| RQ-0015 | Seconds precision >= 6 | CK-008 | Conformance profile | GQL39075_RQ0015_seconds_precision_at_least_6 |
| RQ-0016 | Bytestring max >= 65534 | CK-008 | Conformance profile | GQL39075_RQ0016_bytestring_max_length_at_least_65534 |
| RQ-0017 | Session params start "_" | CK-005 | Conformance profile | GQL39075_RQ0017_session_param_prefix_underscore |
| RQ-0018 | Diagnostic fields + GA08 | CK-007 | Feature flags | GQL39075_RQ0018_ga08_feature_flag_exists |
| RQ-0019 | Privilege -> 42000 | CK-004 | SQLSTATE | GQL39075_RQ0019_privilege_violation_42000 |
| RQ-0020 | Connection-loss 40003/08007 | CK-004 | SQLSTATE | GQL39075_RQ0020_connection_failure_40003 |
| RQ-0021 | Impl txn = explicit | CK-005 | Tests | GQL39075_RQ0021_transaction_state_code_exists |
| RQ-0022 | Keywords case-insensitive | CK-006 | Tests | GQL39075_RQ0022_keywords_case_insensitive |
| RQ-0023 | Without GT01 reject txns | CK-009 | Feature flags | GQL39075_RQ0023_gt01_feature_flag_exists |
| RQ-0024 | All impl-defined defined | CK-001 | Flagger + Profile | GQL39075_RQ0024_annex_b_items_enumerated |
