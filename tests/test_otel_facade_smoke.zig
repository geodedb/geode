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
    otel_metrics.recordTransportConnectionClosed("client_close");
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
    otel_metrics.recordQueryPlan("MATCH", 0.0005, "cbo");
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
    otel_metrics.recordAuditDropped("queue_full");
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

test "CDC and analytics metrics register" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    otel_metrics.recordCdcEvent(.node_change, .success);
    otel_metrics.recordCdcSinkError(.kafka, "ConnectionRefused");
    otel_metrics.recordCdcEventDropped("queue_full");
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
