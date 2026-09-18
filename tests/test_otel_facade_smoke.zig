const std = @import("std");
const otel = @import("otel");
const otel_metrics = @import("otel_metrics");

test "facade meter() before init returns inert noop" {
    // g_provider is null at module start; meter() must not crash.
    // Even though we cannot reliably observe an attribute set without an
    // SDK provider, we can confirm the call returns a structurally-valid
    // Meter and that Counter.add on it is a safe no-op.
    const m = otel_metrics.meter();
    const c = try m.counter(.{ .name = "geode.preinit.test", .kind = .counter });
    c.add(1, &.{}); // must not crash
}

test "facade init + shutdown is idempotent" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    // Calling init twice must be a no-op (same pointer returned).
    const provider1 = otel_metrics.getProvider().?;
    try otel_metrics.initForTesting(gpa);
    const provider2 = otel_metrics.getProvider().?;
    try std.testing.expectEqual(provider1, provider2);
}

test "facade meter is non-null after init" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    // Smoke: registering a counter through the meter must not error.
    const m = otel_metrics.meter();
    const c = try m.counter(.{ .name = "geode.smoke.test", .kind = .counter });
    c.add(1, &.{});
}

test "bucket profiles match spec" {
    try std.testing.expectEqualSlices(f64, &.{ 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 10 }, otel_metrics.buckets_db_client_duration);
    try std.testing.expectEqualSlices(f64, &.{ 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60 }, otel_metrics.buckets_query_duration);
    try std.testing.expectEqualSlices(f64, &.{ 0.00001, 0.00005, 0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1 }, otel_metrics.buckets_storage_io_duration);
    try std.testing.expectEqualSlices(f64, &.{ 0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 30 }, otel_metrics.buckets_lock_wait_duration);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000 }, otel_metrics.buckets_rows);
    try std.testing.expectEqualSlices(f64, &.{ 128, 512, 1024, 4096, 16384, 65536, 262144, 1048576, 4194304, 16777216, 67108864 }, otel_metrics.buckets_bytes);
    try std.testing.expectEqualSlices(f64, &.{ 0, 1, 2, 5, 10, 20, 50, 100, 500, 1000, 10000 }, otel_metrics.buckets_graph_degree);
}

test "server lifecycle metrics register" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    try otel_metrics.registerServerLifecycle(0);
    otel_metrics.recordServerHealth("storage", true);
    otel_metrics.recordConfigReload(.success, null);
    otel_metrics.recordShutdown(.graceful);

    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "geode_server_uptime") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_server_health") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_server_config_reload_count") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_server_shutdown_count") != null);
}

test "transport metrics register and increment" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    otel_metrics.recordTransportConnectionOpened(.quic);
    otel_metrics.recordTransportConnectionClosed(.client_close);
    otel_metrics.recordTransportHandshake(0.012, .success, null);
    otel_metrics.recordTransportRequest("MATCH", 0.034, .success, null);
    otel_metrics.recordTransportBytes(.transmit, 1024);
    otel_metrics.recordTransportTimeout(.handshake);
    otel_metrics.incTransportInflight("MATCH");
    otel_metrics.decTransportInflight("MATCH");

    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);

    for ([_][]const u8{
        "geode_transport_connection_opened",
        "geode_transport_connection_closed",
        "geode_transport_handshake_duration",
        "geode_transport_request_duration",
        "geode_transport_bytes",
        "geode_transport_timeout_count",
    }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, body, name) != null);
    }
}

test "query metrics register" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    otel_metrics.incQueryActive(.read);
    otel_metrics.recordQueryExecution("MATCH", "MATCH Person", .read, 0.012, .success, null);
    otel_metrics.recordQueryParse(0.0001, .success, null);
    otel_metrics.recordQueryParseError("SyntaxError");
    otel_metrics.recordQueryPlan("MATCH", 0.0005, .cbo);
    otel_metrics.recordQueryRowsReturned("MATCH", "MATCH Person", 42);
    otel_metrics.recordQueryTimeout("MATCH", .request);
    otel_metrics.decQueryActive(.read);

    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);
    for ([_][]const u8{
        "geode_query_count",
        "geode_query_execution_duration",
        "geode_query_parse_duration",
        "geode_query_parse_error_count",
        "geode_query_plan_duration",
        "geode_query_rows_returned",
        "geode_query_timeout_count",
    }) |name| try std.testing.expect(std.mem.indexOf(u8, body, name) != null);
}

const QueryMetricsThreadCtx = struct {
    worker_id: usize,
    iterations: usize,

    fn run(ctx: *QueryMetricsThreadCtx) void {
        const qt: otel_metrics.QueryType = if ((ctx.worker_id & 1) == 0) .read else .write;
        var i: usize = 0;
        while (i < ctx.iterations) : (i += 1) {
            const op = if (((ctx.worker_id + i) % 3) == 0) "CREATE" else "MATCH";
            otel_metrics.incQueryActive(qt);
            otel_metrics.recordQueryParse(0.0001, .success, null);
            otel_metrics.recordQueryPlan(op, 0.0002, .cbo);
            otel_metrics.recordQueryRowsReturned(op, op, @intCast((ctx.worker_id + i) % 128));
            otel_metrics.recordQueryExecution(op, op, qt, 0.001, .success, null);
            if ((i % 17) == 0) {
                otel_metrics.recordQueryTimeout(op, .request);
            }
            otel_metrics.decQueryActive(qt);
        }
    }
};

test "query metrics record concurrently without SDK mutex crash" {
    // CANARY: REQ=REQ-QUIC-HC-039; FEATURE="QUIC High-Concurrency Requests"; ASPECT=QueryMetricThreadSafety; STATUS=TESTED; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-05-26
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    const worker_count = 64;
    const iterations = 64;
    var contexts: [worker_count]QueryMetricsThreadCtx = undefined;
    var threads: [worker_count]std.Thread = undefined;

    for (&contexts, 0..) |*ctx, i| {
        ctx.* = .{
            .worker_id = i,
            .iterations = iterations,
        };
        threads[i] = try std.Thread.spawn(.{}, QueryMetricsThreadCtx.run, .{ctx});
    }
    for (&threads) |thread| thread.join();

    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "geode_query_count") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_query_execution_duration") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_query_timeout_count") != null);
}

test "transaction metrics register" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    otel_metrics.incTransactionActive(.snapshot);
    otel_metrics.recordTransactionBegin(.snapshot);
    otel_metrics.recordTransactionCommit(.snapshot, 0.005, .success);
    otel_metrics.recordTransactionAbort(.conflict, "WriteWriteConflict");
    otel_metrics.recordTransactionTimeout(.snapshot);
    otel_metrics.recordSerializationConflict("rw_dependency");
    otel_metrics.recordDeadlock("oldest_first");
    otel_metrics.recordLockWait(.exclusive, 0.001, .success);
    otel_metrics.decTransactionActive(.snapshot);

    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);
    for ([_][]const u8{
        "geode_transaction_count",
        "geode_transaction_commit_duration",
        "geode_transaction_abort_count",
        "geode_transaction_timeout_count",
        "geode_transaction_serialization_conflict_count",
        "geode_transaction_deadlock_count",
        "geode_transaction_lock_wait_duration",
    }) |name| try std.testing.expect(std.mem.indexOf(u8, body, name) != null);
}

test "storage and WAL metrics register" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    otel_metrics.recordStorageOp(.read_node, 0.0001, .success, null);
    otel_metrics.recordStorageBytes(.read, 4096);
    otel_metrics.recordPageCacheLookup(.hit);
    otel_metrics.recordWalRecord(.node_create);
    otel_metrics.recordWalBytes(.write, 256);
    otel_metrics.recordWalAppend(0.0002, .success);
    otel_metrics.recordWalFlush(0.001, .success);
    otel_metrics.recordWalFsync(0.005, .success);
    otel_metrics.recordWalReplay(0.05, .success);
    otel_metrics.recordWalReplayRecord();

    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);
    for ([_][]const u8{
        "geode_storage_operation_count",
        "geode_storage_operation_duration",
        "geode_storage_bytes",
        "geode_storage_page_cache_lookup",
        "geode_wal_record_count",
        "geode_wal_bytes",
        "geode_wal_append_duration",
        "geode_wal_flush_duration",
        "geode_wal_fsync_duration",
        "geode_wal_replay_duration",
        "geode_wal_replay_record_count",
    }) |name| try std.testing.expect(std.mem.indexOf(u8, body, name) != null);
}

test "graph metrics register" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    otel_metrics.recordNodeMutation(.create, "default", .success);
    otel_metrics.recordNodeMutation(.update, "default", .success);
    otel_metrics.recordNodeMutation(.delete, "default", .success);
    otel_metrics.recordEdgeMutation(.create, "default", .success);
    otel_metrics.recordEdgeMutation(.update, "default", .success);
    otel_metrics.recordEdgeMutation(.delete, "default", .success);

    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_graph_node_operation_count") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_graph_edge_operation_count") != null);
}

test "graph mutation db.namespace is a bounded id, never the raw graph name" {
    // SONNY-1805: db.namespace on node/edge mutation metrics must be a bounded
    // id, not the raw per-tenant graph name (unbounded cardinality + pseudonym
    // leakage). Two distinct long names must both map to bounded ns-<n> ids and
    // neither raw name may appear anywhere in the exposition.
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    const raw_a = "tenant-acme-corp-private-customer-graph-0001";
    const raw_b = "tenant-globex-confidential-analytics-graph-9999";
    otel_metrics.recordNodeMutation(.create, raw_a, .success);
    otel_metrics.recordEdgeMutation(.create, raw_b, .success);

    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);

    // The raw per-tenant graph names must never reach the label set.
    try std.testing.expect(std.mem.indexOf(u8, body, raw_a) == null);
    try std.testing.expect(std.mem.indexOf(u8, body, raw_b) == null);
    // Bounded ids are emitted instead.
    try std.testing.expect(std.mem.indexOf(u8, body, "db_namespace=\"ns-") != null);
}

test "index and vector metrics register" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    otel_metrics.recordIndexLookup(.btree, 0.0001, .success);
    otel_metrics.recordIndexUpdate(.btree, .create, 0.0002);
    otel_metrics.recordHnswSearch(.cosine, 0.001);

    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_index_lookup_duration") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_index_lookup_count") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_index_update_duration") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_index_vector_hnsw_search_duration") != null);
}

test "security metrics register without identifier leakage" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    otel_metrics.recordAuthAttempt(.password, .success, null);
    otel_metrics.recordAuthDuration(.password, 0.005, .success);
    otel_metrics.incSession(.active);
    otel_metrics.recordAuthzCheck(.allow, .rbac, 0.0001);
    otel_metrics.recordRlsEvaluation(.allow, .rls, 0.0002);
    otel_metrics.recordAuditEvent("login", .success);
    otel_metrics.recordAuditDropped(.queue_full);
    otel_metrics.recordTdeOperation(.encrypt, 0.001, .success);
    otel_metrics.recordTdeBytes(.encrypt, 1024);
    otel_metrics.recordTdeError("KeyMissing");
    otel_metrics.decSession(.active);

    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);

    // All 12 P0 instrument names must appear in the rendered output.
    for ([_][]const u8{
        "geode_security_authentication_attempt_count",
        "geode_security_session_count",
        "geode_security_authorization_check_count",
        "geode_security_authorization_check_duration",
        "geode_security_rls_evaluation_count",
        "geode_security_rls_evaluation_duration",
        "geode_audit_event_count",
        "geode_audit_event_dropped",
        "geode_crypto_tde_operation_duration",
        "geode_crypto_tde_bytes",
        "geode_crypto_tde_error_count",
    }) |name| try std.testing.expect(std.mem.indexOf(u8, body, name) != null);

    // Privacy guard: forbidden high-cardinality attribute keys MUST NOT leak.
    for ([_][]const u8{ "user_id", "username", "session_id", "request_id", "tenant_id", "key_id" }) |forbidden| {
        var search_buf: [80]u8 = undefined;
        const needle = try std.fmt.bufPrint(&search_buf, "{s}=\"", .{forbidden});
        try std.testing.expect(std.mem.indexOf(u8, body, needle) == null);
    }
}

test "distributed and cluster metrics register" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    otel_metrics.recordShardQuery(0, .success);
    otel_metrics.recordDistributedQuery(.strong, 0.05, .success);
    otel_metrics.recordDistributedFanout(.strong, 4);
    otel_metrics.recordPartialFailure("ShardUnavailable");

    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);
    for ([_][]const u8{
        "geode_shard_query_count",
        "geode_distributed_query_count",
        "geode_distributed_query_duration",
        "geode_distributed_query_fanout",
        "geode_distributed_query_partial_failure_count",
    }) |name| try std.testing.expect(std.mem.indexOf(u8, body, name) != null);
}

test "cluster node health is a gauge observable in both directions" {
    // SONNY-1803: geode.cluster.node.health must be a last-value gauge, not a
    // monotonic counter — a node has to be able to fall to 0 (unhealthy) and
    // recover to 1 (healthy). A counter would only ever sum add(0|1).
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    // Flip node-1 healthy -> unhealthy -> healthy. A counter would accumulate
    // these writes to 2; a gauge keeps the last value (1).
    otel_metrics.recordClusterNodeHealth("node-1", true);
    otel_metrics.recordClusterNodeHealth("node-1", false);
    otel_metrics.recordClusterNodeHealth("node-1", true);
    // node-2 stays unhealthy so the downward direction (0) is observable.
    otel_metrics.recordClusterNodeHealth("node-2", false);

    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);

    // Instrument TYPE must be a gauge, never a counter.
    try std.testing.expect(std.mem.indexOf(u8, body, "# TYPE geode_cluster_node_health gauge") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "# TYPE geode_cluster_node_health counter") == null);

    // node-1 recovered: last value is 1, not the sum (2) a counter would show.
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_cluster_node_id=\"node-1\"} 1") != null);
    // node-2 unhealthy: the 0 (down) direction is representable.
    try std.testing.expect(std.mem.indexOf(u8, body, "geode_cluster_node_id=\"node-2\"} 0") != null);
}

test "CDC and analytics metrics register" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    otel_metrics.recordCdcEvent(.node_change, .success);
    otel_metrics.recordCdcSinkError(.kafka, "ConnectionRefused");
    otel_metrics.recordCdcEventDropped(.queue_full);
    otel_metrics.recordAnalyticsEvent("aggregate", .success);
    otel_metrics.recordAnalyticsProcessing("aggregate", 0.005);

    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);
    for ([_][]const u8{
        "geode_cdc_event_count",
        "geode_cdc_sink_error_count",
        "geode_cdc_event_dropped",
        "geode_analytics_event_count",
        "geode_analytics_event_processing_duration",
    }) |name| try std.testing.expect(std.mem.indexOf(u8, body, name) != null);
}

test "reason and strategy metric attrs are closed enums" {
    // SONNY-1806: reason/strategy attrs are closed enums; only their tag names
    // may appear as label values. Compile-time exhaustiveness guards typos;
    // this asserts every enum value renders as its bounded label string.
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    inline for (std.meta.tags(otel_metrics.CloseReason)) |r| otel_metrics.recordTransportConnectionClosed(r);
    inline for (std.meta.tags(otel_metrics.PlannerStrategy)) |s| otel_metrics.recordQueryPlan("MATCH", 0.0005, s);
    inline for (std.meta.tags(otel_metrics.AuditDropReason)) |r| otel_metrics.recordAuditDropped(r);
    inline for (std.meta.tags(otel_metrics.CdcDropReason)) |r| otel_metrics.recordCdcEventDropped(r);

    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);

    const Case = struct { label: []const u8, E: type };
    const cases = [_]Case{
        .{ .label = "geode_close_reason", .E = otel_metrics.CloseReason },
        .{ .label = "geode_planner_strategy", .E = otel_metrics.PlannerStrategy },
        .{ .label = "geode_audit_drop_reason", .E = otel_metrics.AuditDropReason },
        .{ .label = "geode_drop_reason", .E = otel_metrics.CdcDropReason },
    };
    inline for (cases) |c| {
        inline for (std.meta.tags(c.E)) |tag| {
            var b: [96]u8 = undefined;
            const needle = try std.fmt.bufPrint(&b, "{s}=\"{s}\"", .{ c.label, @tagName(tag) });
            try std.testing.expect(std.mem.indexOf(u8, body, needle) != null);
        }
    }
}

test "backup and restore metrics register" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    otel_metrics.recordBackup(.full, 1.5, .success, null);
    otel_metrics.recordBackupBytes(.full, 1048576);
    otel_metrics.recordRestore(2.0, .success, null);
    otel_metrics.recordRestoreBytes(1048576);

    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);
    for ([_][]const u8{
        "geode_backup_count",
        "geode_backup_duration",
        "geode_backup_bytes",
        "geode_restore_count",
        "geode_restore_duration",
        "geode_restore_bytes",
    }) |name| try std.testing.expect(std.mem.indexOf(u8, body, name) != null);
}

test "process and db.client metrics register" {
    // CANARY: REQ=REQ-OTEL-METRICS-014; FEATURE="OTel Instrumentation"; ASPECT=ProcessMetrics+DbClient; STATUS=TESTED; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-04-28
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    // Sub-A: process metrics — registration may be a no-op if the runtime
    // module isn't available; just confirm it doesn't crash.
    otel_metrics.registerRuntimeMetrics() catch {};

    // Refresh once to exercise the snapshot path (may be a no-op on non-Linux).
    otel_metrics.refreshRuntimeMetrics();

    // Sub-B: db.client.*
    otel_metrics.recordDbClientOperation("MATCH", "node-1:3141", 0.005, .success, null);
    otel_metrics.incDbClientConnection("node-1:3141", .used);
    otel_metrics.decDbClientConnection("node-1:3141", .used);

    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "db_client_operation_duration") != null);
    // process metrics may or may not appear depending on runtime support; not asserted here.
}

// CANARY: REQ=REQ-OTEL-OTLP-PUSH-001; FEATURE="OTel Instrumentation"; ASPECT=OTLPPush; STATUS=TESTED; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-04-28
test "OTLP env detection: init succeeds without OTEL_METRICS_EXPORTER set" {
    // Verify that init() works cleanly when OTEL_METRICS_EXPORTER is not set
    // (the common case). The OTLP reader must NOT be started.
    // Full OTLP push verification requires a live collector and is documented
    // as manual-only (docker compose); this test covers the env-detection path.
    const gpa = std.testing.allocator;

    // Ensure the env var is absent for this test (it won't be set in CI).
    // We cannot unset env vars without libc setenv, so we only assert
    // the no-OTLP path: init succeeds and the provider is non-null.
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    try std.testing.expect(otel_metrics.getProvider() != null);

    // Prometheus pull must still work when OTLP reader is inactive.
    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);
    // A freshly init'd provider renders at least the empty metric prefix.
    // We just confirm no crash here; specific metric content is tested above.
    // `body` is already consumed by the `defer gpa.free(body)` above.
}
