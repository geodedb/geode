# Timeseries Requirements Inventory

**Generated:** 2026-04-01
**Scope:** `src/timeseries/`, `tests/ts_store_integration.zig`, `tests/e2e_timeseries.zig`, `src/benchmarks/bench_timeseries.zig`, `specs/signal-analysis/`, build system, GitLab issues
**Mode:** --skip-issues (no platform issues created)

---

## Platform

- **Platform:** GitLab
- **Project:** devnw/codepros/geode/geode
- **Auth status:** Token present but reported as invalid; issue queries succeeded via `glab issue list`

---

## 1. Source Inventory

### 1.1 Implementation Files

| File | Role | Lines |
|------|------|-------|
| `src/timeseries/timeseries.zig` | Thin re-export wrapper over external `timeseries_lib` (Point, PointF64, SeriesKey, Series, Store) | 116 |
| `src/timeseries/chunk_storage.zig` | Thin re-export wrapper over external `timeseries_lib.chunk_storage` (ChunkConfig, CompressionAlgorithm, ChunkMeta, GorillaEncoder, GorillaDecoder, ChunkStorage) | 92 |
| `src/timeseries/gql_functions.zig` | GQL function registry: 8 function types (last_value, value_at, sample_by, time_bucket, interpolate, moving_avg, rate, derivative) | 402 |
| `src/eval.zig:862-890` | `timeseries.value()` GQL function wired into eval engine | 29 |
| `src/value_types.zig:159` | `Env.timeseries_store` optional field (GAP-004 wiring) | 1 |
| `src/exec.zig:321,465` | `runGroupedQuery` accepts and passes `timeseries_store` | ~2 |
| `src/gql/main.zig:425-455` | CLI test path: creates Store, passes to executor (GAP-004) | ~30 |

### 1.2 External Library (timeseries v0.1.0)

**Source:** `gitlab.com/devnw/zig/timeseries` at commit `0103cf25b923...`
**Pinned in:** `build.zig.zon` lines 226-228

**Modules provided but NOT re-exported/used by Geode wrapper:**

| Module | Capability | Exposed via Geode |
|--------|-----------|-------------------|
| `store` | Point, Series, Store (insertMany, last, valueBefore, sampleBy, timeBucketAvg, valueAt, getSeries) | YES (via timeseries.zig) |
| `chunk_storage` | ChunkStorage, GorillaEncoder/Decoder, compression stats, retention | YES (via chunk_storage.zig) |
| `dtw` | Dynamic Time Warping (constrained, derivative, open-end, shape, soft) | NO (accessible via `lib.dtw`) |
| `distances` | Cross-correlation, SBD, LCSS, EDR, ERP, TWED | NO (accessible via `lib.distances`) |
| `matrix_profile` | STOMP matrix profile, MPDist | NO (accessible via `lib.matrix_profile`) |
| `features` | 22-element feature extraction, cosine similarity | NO (accessible via `lib.features`) |
| `pelt` | PELT change-point detection | NO (accessible via `lib.pelt`) |
| `preprocess` | z-normalization, baseline correction | NO (accessible via `lib.preprocess`) |
| `invariants` | Invariant sets | NO (accessible via `lib.invariants`) |
| `abi` | C ABI exports for FFI (Go, Python, etc.) | NO |

### 1.3 Test Files

| File | Tests | Purpose |
|------|-------|---------|
| `src/timeseries/timeseries.zig` (inline) | 4 | Wrapper validation: insert/order/last/asof, timeBucketAvg, sampleBy (avg/min/max/count), valueAt/lastValue |
| `src/timeseries/chunk_storage.zig` (inline) | 2 | Chunk compression + stats, retention pruning |
| `src/timeseries/gql_functions.zig` (inline) | 2 | GQL last_value, interpolate (linear) |
| `tests/ts_store_integration.zig` | 1 | Integration: last/valueBefore/timeBucketAvg via `geode.timeseries` import |
| `tests/e2e_timeseries.zig` | 5 | E2E: basic store ops, chunk compression, retention policy, GQL function integration, performance benchmark |

### 1.4 Benchmark Files

| File | Purpose |
|------|---------|
| `src/benchmarks/bench_timeseries.zig` | Ingestion + GQL `timeseries.value()` eval benchmark (100K/1M points) |
| `BENCHMARK_REPORT.md` | Documents GAP-006 benchmark results |

### 1.5 Spec Files

| File | Relevance |
|------|-----------|
| `specs/signal-analysis/integrating-signal-analysis.md` | Full design spec for signal-based anomaly detection integration with timeseries subsystem |

### 1.6 Build System

| File | Integration |
|------|-------------|
| `build.zig:348-349` | Fetches `timeseries` dependency, creates `timeseries_ext_mod` |
| `build.zig:459` | Adds `timeseries_lib` import to root module |
| `build.zig:519` | Adds `timeseries_lib` import to geode executable |
| `build.zig.zon:226-228` | Pins timeseries v0.1.0 with hash |

---

## 2. GitLab Issues (Timeseries-Related)

| Issue | Title | Labels | State |
|-------|-------|--------|-------|
| #74 | Time Series and Analytics Charting | enhancement, priority::medium, visualization, vscode-extension | closed |
| #91 | Create benchmark query suite for internet-scale testing | benchmarking, enhancement, load-testing, priority::low | open |
| #133 | GAP-0051: Anomaly Detector Metric Extraction Returns Constant Value | gap, implementation, priority::low | closed |

No dedicated timeseries feature/bug/gap issues exist in the tracker. The GAP-004/GAP-005/GAP-006 references in CHANGELOG.md are not tracked as GitLab issues.

---

## 3. Requirements Inventory

### 3.1 Core Store Requirements (from tests + code)

| ID | Requirement | Source | Evidence | Status |
|----|------------|--------|----------|--------|
| TS-STORE-001 | Insert points into a keyed series (device_id + metric) | `timeseries.zig` test, `e2e_timeseries.zig` | `Store.insertMany(key, points)` | IMPLEMENTED, TESTED |
| TS-STORE-002 | Points stored in sorted order by timestamp | `timeseries.zig` test "insert/order/last/asof" | Out-of-order insert (100, 90, 110) returns correct last | IMPLEMENTED, TESTED |
| TS-STORE-003 | Retrieve last (most recent) point for a series | `timeseries.zig` test, `e2e_timeseries.zig` | `Store.last(key)` | IMPLEMENTED, TESTED |
| TS-STORE-004 | Retrieve point at or before a given timestamp (as-of lookup) | `timeseries.zig` test | `Store.valueBefore(key, ts)` | IMPLEMENTED, TESTED |
| TS-STORE-005 | Get value at exact timestamp or closest match | `timeseries.zig` test "valueAt and lastValue" | `Series.valueAt(ts)` | IMPLEMENTED, TESTED |
| TS-STORE-006 | Multiple independent series per store (different device_id/metric) | `e2e_timeseries.zig` "basic store operations" | temp_key + humidity_key | IMPLEMENTED, TESTED |
| TS-STORE-007 | Series key is composite: device_id (i64) + metric (string) | `timeseries.zig`, `gql_functions.zig` | `SeriesKey{ .device_id, .metric }` | IMPLEMENTED, TESTED |

### 3.2 Aggregation Requirements (from tests + code)

| ID | Requirement | Source | Evidence | Status |
|----|------------|--------|----------|--------|
| TS-AGG-001 | Time-bucket average aggregation over range | `timeseries.zig` test "timeBucketAvg basic" | `Store.timeBucketAvg(key, bucket_size, start, end, alloc)` | IMPLEMENTED, TESTED |
| TS-AGG-002 | Sample-by AVG aggregation over interval | `timeseries.zig` test "sampleBy aggregations" | `Store.sampleBy(key, interval, start, end, .avg, alloc)` | IMPLEMENTED, TESTED |
| TS-AGG-003 | Sample-by MIN aggregation | `timeseries.zig` test | `sampleBy(..., .min, ...)` | IMPLEMENTED, TESTED |
| TS-AGG-004 | Sample-by MAX aggregation | `timeseries.zig` test | `sampleBy(..., .max, ...)` | IMPLEMENTED, TESTED |
| TS-AGG-005 | Sample-by COUNT aggregation | `timeseries.zig` test | `sampleBy(..., .count, ...)` | IMPLEMENTED, TESTED |
| TS-AGG-006 | Sample-by SUM aggregation | `gql_functions.zig` TSFunctionParams enum | `.sum` variant defined | DEFINED, NOT TESTED |
| TS-AGG-007 | Sample-by FIRST aggregation | `gql_functions.zig` TSFunctionParams enum | `.first` variant defined | DEFINED, NOT TESTED |
| TS-AGG-008 | Sample-by LAST aggregation | `gql_functions.zig` TSFunctionParams enum | `.last` variant defined | DEFINED, NOT TESTED |

### 3.3 GQL Function Requirements (from gql_functions.zig + eval.zig)

| ID | Requirement | Source | Evidence | Status |
|----|------------|--------|----------|--------|
| TS-GQL-001 | `timeseries.value(device_id, metric, timestamp)` function in GQL eval | `eval.zig:862`, `MIGRATION_GUIDE.md` | Wired into evalExpr, returns Int or Null | IMPLEMENTED, TESTED (bench) |
| TS-GQL-002 | last_value function via TSFunctionCall | `gql_functions.zig` test "ts_functions: last_value" | `executeFunction` with `.last_value` | IMPLEMENTED, TESTED |
| TS-GQL-003 | value_at function via TSFunctionCall | `gql_functions.zig:91-101` | Returns point at timestamp from series | IMPLEMENTED, NOT TESTED (no dedicated test) |
| TS-GQL-004 | sample_by function with aggregation dispatch | `gql_functions.zig:103-126`, `e2e_timeseries.zig` | Returns array of {ts, value} objects | IMPLEMENTED, TESTED |
| TS-GQL-005 | time_bucket function | `gql_functions.zig:128-149` | Delegates to `timeBucketAvg`, returns {ts, avg} | IMPLEMENTED, NOT TESTED (no dedicated test) |
| TS-GQL-006 | interpolate function (linear, step, nearest) | `gql_functions.zig` test "ts_functions: interpolate" | Linear interpolation tested; step/nearest implemented | IMPLEMENTED, PARTIALLY TESTED |
| TS-GQL-007 | moving_avg function (windowed) | `gql_functions.zig:223-261`, `e2e_timeseries.zig` | Window + step parameters, returns {ts, avg} array | IMPLEMENTED, TESTED |
| TS-GQL-008 | rate function (rate of change) | `gql_functions.zig:263-294`, `e2e_timeseries.zig` | Per-second rate, returns {ts, rate} | IMPLEMENTED, TESTED |
| TS-GQL-009 | derivative function (nth order) | `gql_functions.zig:296-328` | Only 1st order implemented; higher orders stub | IMPLEMENTED, PARTIALLY (1st order only) |

### 3.4 Chunk Storage Requirements (from chunk_storage.zig + e2e tests)

| ID | Requirement | Source | Evidence | Status |
|----|------------|--------|----------|--------|
| TS-CHUNK-001 | Gorilla compression for time-series chunks | `chunk_storage.zig`, `e2e_timeseries.zig` | GorillaEncoder/Decoder re-exported; `compression_algorithm: .gorilla` | IMPLEMENTED, TESTED |
| TS-CHUNK-002 | Configurable max points per chunk | `e2e_timeseries.zig` | `ChunkConfig{ .max_points_per_chunk = 1000 }` | IMPLEMENTED, TESTED |
| TS-CHUNK-003 | Compression ratio < 50% (2:1 or better) | `e2e_timeseries.zig` assertion | `stats.ratio < 0.5` | IMPLEMENTED, TESTED |
| TS-CHUNK-004 | Bytes per value < 12 with Gorilla | `e2e_timeseries.zig` assertion | `bytes_per_value < 12.0` | IMPLEMENTED, TESTED |
| TS-CHUNK-005 | Retention policy (configurable days) | `chunk_storage.zig` test, `e2e_timeseries.zig` | `retention_days` config, `runRetention(current_time)` prunes old chunks | IMPLEMENTED, TESTED |
| TS-CHUNK-006 | Compression statistics reporting | `chunk_storage.zig` test | `getCompressionStats()` returns total_chunks, ratio, etc. | IMPLEMENTED, TESTED |

### 3.5 Performance Requirements (from benchmarks + spec)

| ID | Requirement | Source | Evidence | Status |
|----|------------|--------|----------|--------|
| TS-PERF-001 | Write throughput > 500K points/sec | `e2e_timeseries.zig` "performance benchmark" | Assertion: `write_throughput > 500000` | IMPLEMENTED, TESTED |
| TS-PERF-002 | Query latency < 100ms (last, valueBefore, sampleBy) | `e2e_timeseries.zig` "performance benchmark" | Assertion: `query_time < 100` | IMPLEMENTED, TESTED |
| TS-PERF-003 | Memory usage < 20 bytes per point | `e2e_timeseries.zig` "performance benchmark" | Assertion: `bytes_per_point < 20` | IMPLEMENTED, TESTED |
| TS-PERF-004 | Ingestion benchmark at 100K and 1M points | `bench_timeseries.zig` | Two configs: Medium (100K) and Large (1M) | IMPLEMENTED |
| TS-PERF-005 | GQL eval query rate benchmark | `bench_timeseries.zig` | 100K `timeseries.value()` eval calls benchmarked | IMPLEMENTED |

### 3.6 Integration Requirements (from code wiring)

| ID | Requirement | Source | Evidence | Status |
|----|------------|--------|----------|--------|
| TS-INT-001 | timeseries_store field on Env for GQL evaluation | `value_types.zig:159` | `timeseries_store: ?*const Store = null` | IMPLEMENTED |
| TS-INT-002 | Store passed through exec.runGroupedQuery | `exec.zig:321,465` | Parameter threaded to Env | IMPLEMENTED |
| TS-INT-003 | Store initialized and wired in CLI test path | `gql/main.zig:425` | GAP-004 comment | IMPLEMENTED |
| TS-INT-004 | Store wired in QUIC server execution path | -- | **NO EVIDENCE** -- `src/server/` has no `timeseries_store` references | **NOT IMPLEMENTED** |
| TS-INT-005 | Store wired in gRPC server execution path | -- | **NO EVIDENCE** | **NOT IMPLEMENTED** |
| TS-INT-006 | Build system dependency wiring | `build.zig`, `build.zig.zon` | `timeseries_lib` import on root module + executable | IMPLEMENTED |

### 3.7 Signal Analysis / Anomaly Detection Requirements (from spec)

These are from `specs/signal-analysis/integrating-signal-analysis.md` -- a design spec describing future integration. None are currently tracked as GitLab issues and none have implementation evidence beyond the external library capabilities.

| ID | Requirement | Spec Section | Library Support | Implementation Status |
|----|------------|-------------|----------------|----------------------|
| TS-SIG-001 | FFT (Fourier transform) on series windows | Sec 3 "Native Zig/C++ Implementation" | NOT in library | NOT IMPLEMENTED |
| TS-SIG-002 | Short-Time FFT (STFT/spectrogram) | Sec 3 | NOT in library | NOT IMPLEMENTED |
| TS-SIG-003 | Wavelet transform (CWT/DWT) | Sec 3 | NOT in library | NOT IMPLEMENTED |
| TS-SIG-004 | Spectral Residual (SR) anomaly detection | Sec 3 | NOT in library | NOT IMPLEMENTED |
| TS-SIG-005 | SR-CNN model inference | Sec 3 | NOT in library | NOT IMPLEMENTED |
| TS-SIG-006 | CUSUM / EWMA change detection | Sec 3 | NOT in library (PELT is available) | NOT IMPLEMENTED |
| TS-SIG-007 | AnomalyEvent node type in graph schema | Sec 4 "Representing Anomalies" | N/A | NOT IMPLEMENTED |
| TS-SIG-008 | ANOMALY_DETECTED edge type (Series -> AnomalyEvent) | Sec 4 | N/A | NOT IMPLEMENTED |
| TS-SIG-009 | Continuous anomaly detection via CDC/streaming | Sec 2 "On Ingestion" | N/A | NOT IMPLEMENTED |
| TS-SIG-010 | On-demand anomaly detection query functions | Sec 2 "On-Demand Query" | N/A | NOT IMPLEMENTED |
| TS-SIG-011 | spectral_anomaly_score() GQL function | Sec 2 example query | N/A | NOT IMPLEMENTED |
| TS-SIG-012 | GPU acceleration for spectral transforms | Sec 3 "GPU Acceleration" | N/A | NOT IMPLEMENTED |
| TS-SIG-013 | WASM extension mechanism for custom detectors | Sec 3 "Scripting and WASM" | N/A | NOT IMPLEMENTED |
| TS-SIG-014 | 50K samples/sec throughput with sub-200ms detection | Sec 5 "Performance Considerations" | N/A | NOT IMPLEMENTED |
| TS-SIG-015 | False alarm rate <= 1 per hour per host | Sec 5 "Validation" | N/A | NOT IMPLEMENTED |

### 3.8 External Library Capabilities (available but not wired into GQL)

These modules exist in the `timeseries` v0.1.0 library and are accessible via `timeseries.lib.*` but have no GQL function wiring or server-side integration.

| ID | Capability | Library Module | Geode Integration |
|----|-----------|---------------|-------------------|
| TS-LIB-001 | Dynamic Time Warping (5 variants) | `lib.dtw` | NOT WIRED |
| TS-LIB-002 | Distance metrics (cross-correlation, SBD, LCSS, EDR, ERP, TWED) | `lib.distances` | NOT WIRED |
| TS-LIB-003 | Matrix Profile (STOMP) and MPDist | `lib.matrix_profile` | NOT WIRED |
| TS-LIB-004 | 22-element feature extraction + cosine similarity | `lib.features` | NOT WIRED |
| TS-LIB-005 | PELT change-point detection | `lib.pelt` | NOT WIRED |
| TS-LIB-006 | Z-normalization and baseline correction | `lib.preprocess` | NOT WIRED |
| TS-LIB-007 | Invariant sets | `lib.invariants` | NOT WIRED |
| TS-LIB-008 | C ABI for FFI (Go, Python) | `lib.abi` | NOT WIRED |
| TS-LIB-009 | PointF64 (floating-point series) | `lib.store.PointF64` | RE-EXPORTED but unused |

---

## 4. CANARY Token Status

**There are ZERO CANARY tokens in the timeseries subsystem.** No file in `src/timeseries/` contains any CANARY markers. This is a governance gap -- all other major subsystems have CANARY coverage.

---

## 5. Gaps and Conflicts

### 5.1 Critical Gaps

| Gap ID | Description | Evidence |
|--------|------------|----------|
| GAP-TS-001 | **Server execution path not wired**: `timeseries.value()` only works in the CLI test path (`src/gql/main.zig`). The QUIC server handler (`src/server/quic_connection_handler.zig`) and gRPC server handler do not initialize or pass a `timeseries_store` to the eval Env. Production queries via QUIC/gRPC will always get `null` store and return `Null`. | grep for `timeseries_store` in `src/server/` returns zero matches |
| GAP-TS-002 | **No CANARY governance tokens**: Zero CANARY markers in `src/timeseries/`, `tests/e2e_timeseries.zig`, or `tests/ts_store_integration.zig` | grep for CANARY in `src/timeseries/` returns zero matches |
| GAP-TS-003 | **GAP-004/005/006 not tracked as issues**: CHANGELOG.md references GAP-004 (timeseries.value wiring), GAP-005 (backup encryption), GAP-006 (benchmarks) but none are GitLab issues | glab issue search returns no matching issues |
| GAP-TS-004 | **gql_functions.zig uses temporary Value/Expression types**: File header says "Temporary Value type for testing (will be replaced by protocol.Value)" and "Temporary Expression type for testing (will be replaced by parser.Expression)". This module is not integrated with the actual GQL evaluation pipeline. | `gql_functions.zig:6-23` |
| GAP-TS-005 | **derivative() only implements 1st order**: Comment at line 304 says "For now, just calculate first order derivative" with no implementation for higher orders | `gql_functions.zig:304` |
| GAP-TS-006 | **SUM/FIRST/LAST aggregations untested**: These are defined in the TSFunctionParams enum but have no test coverage | `gql_functions.zig:52` enum definition only |

### 5.2 Documentation Conflicts

| Conflict | Doc Claim | Reality |
|----------|----------|---------|
| MIGRATION_GUIDE.md claims `timeseries.value()` is a production function | "Retrieves the value of a metric for a specific device at a given timestamp" | Only works in CLI test path; null store in server path means it always returns NULL in production queries |
| Signal analysis spec references "Geode's time-series extension" as production-ready | Sec 1: "Geode stores time-series as columnar chunks of points" | Chunk storage is in the external library and re-exported, but not wired to the server persistence layer |
| Signal analysis spec claims >=2M pts/sec ingestion | Sec 5: "tested >=2 million points/sec per node" | Only test evidence is e2e_timeseries.zig assertion of >500K pts/sec (1M points in-memory, no persistence) |
| CHANGELOG.md GAP-006 | "Added Time-Series benchmarks" | Benchmarks exist but are not part of CI (no `bench_timeseries` target in Makefile or .gitlab-ci.yml) |

### 5.3 Architecture Notes

The `src/timeseries/gql_functions.zig` module defines a parallel GQL function system (TSFunctionType, TSFunctionCall, executeFunction) that is **completely independent** from the actual GQL eval path in `src/eval.zig`. The eval.zig path only supports `timeseries.value()` directly. The 8 function types in gql_functions.zig (last_value, value_at, sample_by, time_bucket, interpolate, moving_avg, rate, derivative) are tested via direct Zig calls but are not callable from GQL queries.

---

## 6. Summary Statistics

| Category | Count |
|----------|-------|
| Total requirements identified | 52 |
| Implemented and tested | 24 |
| Implemented, not/partially tested | 8 |
| Defined but not implemented (signal analysis) | 15 |
| Available in library but not wired | 9 |
| GitLab issues (timeseries-related) | 3 |
| CANARY tokens | 0 |
| Critical gaps | 6 |
| Documentation conflicts | 4 |

---

## 7. File Index

All absolute paths referenced in this inventory:

**Implementation:**

- `/home/benji/src/devnw/codepros/geode/geode/src/timeseries/timeseries.zig`
- `/home/benji/src/devnw/codepros/geode/geode/src/timeseries/chunk_storage.zig`
- `/home/benji/src/devnw/codepros/geode/geode/src/timeseries/gql_functions.zig`
- `/home/benji/src/devnw/codepros/geode/geode/src/eval.zig` (lines 862-890)
- `/home/benji/src/devnw/codepros/geode/geode/src/value_types.zig` (line 159)
- `/home/benji/src/devnw/codepros/geode/geode/src/exec.zig` (lines 321, 465)
- `/home/benji/src/devnw/codepros/geode/geode/src/gql/main.zig` (lines 425-455)

**Tests:**

- `/home/benji/src/devnw/codepros/geode/geode/tests/ts_store_integration.zig`
- `/home/benji/src/devnw/codepros/geode/geode/tests/e2e_timeseries.zig`

**Benchmarks:**

- `/home/benji/src/devnw/codepros/geode/geode/src/benchmarks/bench_timeseries.zig`
- `/home/benji/src/devnw/codepros/geode/geode/BENCHMARK_REPORT.md`

**Specs:**

- `/home/benji/src/devnw/codepros/geode/geode/specs/signal-analysis/integrating-signal-analysis.md`

**Build:**

- `/home/benji/src/devnw/codepros/geode/geode/build.zig` (lines 348-349, 459, 519)
- `/home/benji/src/devnw/codepros/geode/geode/build.zig.zon` (lines 226-228)

**Docs:**

- `/home/benji/src/devnw/codepros/geode/geode/docs/CHANGELOG.md`
- `/home/benji/src/devnw/codepros/geode/geode/docs/MIGRATION_GUIDE.md`
- `/home/benji/src/devnw/codepros/geode/geode/docs/CURRENT_ARCHITECTURE.md`

**External Library (cached):**

- `/home/benji/.cache/zig/p/timeseries-0.1.0-iAEwOlA3AwB0QmX0WcYWUljO4_aG4Q2Q8ot-WW919ch7/src/root.zig`
