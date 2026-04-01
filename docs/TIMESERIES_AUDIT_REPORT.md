# Time-Series Subsystem Audit Report

Last updated: 2026-04-01

## Overview

This document tracks the time-series subsystem gap analysis, closure status,
and legacy ID mapping. The time-series module was extracted to an external
library (`timeseries_lib`) and re-integrated via thin wrappers in
`src/timeseries/`.

## Gap Status

| GAP ID   | Title                                    | Status   | Evidence |
|----------|------------------------------------------|----------|----------|
| GAP-0279 | External library extraction              | Closed   | `src/timeseries/timeseries.zig` delegates to `timeseries_lib`; all unit tests pass |
| GAP-0280 | `timeseries.value()` server wiring       | Closed   | `src/execution.zig` routes `timeseries.value()` calls through to the store |
| GAP-0281 | CANARY governance tokens                 | Closed   | 24 CANARY markers added across `timeseries.zig`, `gql_functions.zig`, `chunk_storage.zig` |
| GAP-0284 | SUM/FIRST/LAST aggregation coverage      | Closed   | Tests in `timeseries.zig`: `sampleBy SUM`, `sampleBy FIRST`, `sampleBy LAST`, empty-bucket variants |
| GAP-0285 | `valueAt` and `timeBucketAvg` edge cases | Closed   | Tests in `timeseries.zig`: before-first null, after-last, exact match, empty series, empty range, single-point, boundary |
| GAP-0286 | Step and nearest interpolation            | Closed   | Tests in `gql_functions.zig`: step left, step close-to-right, nearest closer, nearest equidistant, only-left, only-right, exact-match-all-methods |
| GAP-0287 | Benchmarks in CI                         | Open     | `src/benchmarks/bench_timeseries.zig` exists; CI gate not yet wired |
| GAP-0288 | Legacy GAP ID mapping                    | Closed   | This document |
| GAP-0291 | Documentation accuracy                   | Closed   | MIGRATION_GUIDE.md, CHANGELOG.md, and this report updated |

## Legacy GAP ID Mapping

The original `CHANGELOG.md` used short GAP IDs from the Grey Cardinal
compliance audit. The table below maps those to the current GAP-0279+
numbering used in the time-series audit.

| Legacy ID | New ID   | Description                                      | Notes |
|-----------|----------|--------------------------------------------------|-------|
| GAP-004   | GAP-0280 | `timeseries.value()` server wiring               | Closed: execution engine now routes the call |
| GAP-006   | GAP-0287 | Time-series benchmarks in CI                     | Open: benchmark binary exists, CI gate pending |
| GAP-005   | N/A      | Backup encryption (AES-256-GCM)                  | Not timeseries-related; tracked separately in backup/TDE gap analysis |

## CANARY Token Summary

### `src/timeseries/timeseries.zig` (9 markers)

- REQ-TS-STORE-001 -- Store init
- REQ-TS-INSERT-001 -- insertMany
- REQ-TS-LAST-001 -- last
- REQ-TS-VALUEBEFORE-001 -- valueBefore
- REQ-TS-SAMPLEBY-001 -- sampleBy
- REQ-TS-TIMEBUCKET-001 -- timeBucketAvg
- REQ-TS-VALUEAT-001 -- valueAt
- REQ-TS-SERIESKEY-001 -- SeriesKey type
- REQ-TS-POINT-001 -- Point type

### `src/timeseries/gql_functions.zig` (10 markers)

- REQ-TS-GQL-EXEC-001 -- executeFunction dispatcher
- REQ-TS-GQL-LASTVAL-001 -- last_value function
- REQ-TS-GQL-VALUEAT-001 -- value_at function
- REQ-TS-GQL-SAMPLEBY-001 -- sample_by function
- REQ-TS-GQL-TIMEBUCKET-001 -- time_bucket function
- REQ-TS-GQL-INTERPOLATE-001 -- interpolate function
- REQ-TS-GQL-MOVINGAVG-001 -- moving_avg function
- REQ-TS-GQL-RATE-001 -- rate function
- REQ-TS-GQL-DERIVATIVE-001 -- derivative function
- REQ-TS-GQL-FUNCTYPE-001 -- TSFunctionType enum

### `src/timeseries/chunk_storage.zig` (5 markers)

- REQ-TS-CHUNK-001 -- ChunkStorage
- REQ-TS-GORILLA-ENC-001 -- GorillaEncoder
- REQ-TS-GORILLA-DEC-001 -- GorillaDecoder
- REQ-TS-RETENTION-001 -- Retention policy
- REQ-TS-COMPRESS-STATS-001 -- Compression statistics
