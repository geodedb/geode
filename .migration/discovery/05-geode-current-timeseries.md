# geode:current-timeseries

## summary

Geode HAS a dedicated time-series TSDB at src/timeseries/ (wraps external timeseries_lib + timeseries_storage_lib LSM + thread_pool). Ingest only via Store.insertMany (no GQL/QUIC ingest verb). GQL functions name-dispatched in eval.zig (no grammar). Per-graph isolation, not per-tenant. SeriesKey{device_id,metric}, Point{ts,value}, Gorilla compression + 30d retention.

## files

- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/timeseries/timeseries.zig — **role**: Core TSDB Store wrapper: in-mem cache + durable LSM engine; insertMany/last/valueBefore/queryRange/timeBucketAvg/sampleBy. CANARY REQ-TS-* TESTED, PERSIST IMPL.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/timeseries/chunk_storage.zig — **role**: Gorilla compression + chunked retention; retention_days=30.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/timeseries/gql_functions.zig — **role**: GQL bridge: 13 series-based + 8 array TS functions; ~23 CANARY REQ-TS-GQL-* TESTED.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/eval.zig — **role**: GQL TS dispatch + resolution (70-96, 889, 3825, 3842, 3811).
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/server/main.zig — **role**: Server boot TS store wiring 1604-1617 (WIRE-003 TESTED).
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/storage/graph_storage_adapter.zig — **role**: Per-graph TS store at {graph_dir}/timeseries/ (3827, 1258).
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/execution.zig — **role**: ExecutionContext.timeseries_store 497-500 (WIRE-002 TESTED).
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/src/benchmarks/bench_timeseries.zig — **role**: Dedicated TS benchmark; results docs/performance/2026-04-19-qps-closure/.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/tests/e2e_timeseries.zig — **role**: End-to-end TS test (+ ts_store_integration.zig, ts_udf_parse.zig).
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode/build.zig — **role**: Wires external TS libs; engine+on-disk format out-of-repo. Docs docs/TIMESERIES_AUDIT_REPORT.md.
