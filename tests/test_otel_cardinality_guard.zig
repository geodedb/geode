// CANARY: REQ=REQ-OTEL-PRIV-001; FEATURE="OTel Instrumentation"; ASPECT=CardinalityPrivacyGuard; STATUS=TESTED; TEST=tests/test_otel_cardinality_guard.zig; OWNER=monitoring; UPDATED=2026-04-28
const std = @import("std");
const otel = @import("otel");
const otel_metrics = @import("otel_metrics");

const FORBIDDEN_KEYS = [_][]const u8{
    "user.id",    "username",    "session.id", "request.id",
    "trace.id",   "span.id",     "tenant.id",  "geode.tenant.id",
    "index.name", "policy.name", "key.id",     "db.query.text",
};

test "no forbidden attribute keys appear in default metric stream" {
    const gpa = std.testing.allocator;
    try otel_metrics.initForTesting(gpa);
    defer otel_metrics.shutdown();

    // Drive every public recordX function with safe, low-cardinality inputs
    // that match exactly what the facade contract permits.

    // Lifecycle
    try otel_metrics.registerServerLifecycle(0);
    otel_metrics.recordServerHealth("storage", true);
    otel_metrics.recordConfigReload(.success, null);
    otel_metrics.recordShutdown(.graceful);

    // Transport
    otel_metrics.recordTransportConnectionOpened(.quic);
    otel_metrics.recordTransportConnectionClosed(.client_close);
    otel_metrics.recordTransportHandshake(0.012, .success, null);
    otel_metrics.recordTransportRequest("MATCH", 0.034, .success, null);
    otel_metrics.recordTransportBytes(.transmit, 1024);
    otel_metrics.recordTransportTimeout(.handshake);
    otel_metrics.incTransportInflight("MATCH");
    otel_metrics.decTransportInflight("MATCH");

    // Query
    otel_metrics.incQueryActive(.read);
    otel_metrics.recordQueryExecution("MATCH", "MATCH Person", .read, 0.012, .success, null);
    otel_metrics.recordQueryParse(0.0001, .success, null);
    otel_metrics.recordQueryParseError("SyntaxError");
    otel_metrics.recordQueryPlan("MATCH", 0.0005, .cbo);
    otel_metrics.recordQueryRowsReturned("MATCH", "MATCH Person", 42);
    otel_metrics.recordQueryTimeout("MATCH", .request);
    otel_metrics.decQueryActive(.read);

    // Transaction
    otel_metrics.incTransactionActive(.snapshot);
    otel_metrics.recordTransactionBegin(.snapshot);
    otel_metrics.recordTransactionCommit(.snapshot, 0.005, .success);
    otel_metrics.recordTransactionAbort(.conflict, "WriteWriteConflict");
    otel_metrics.recordTransactionTimeout(.snapshot);
    otel_metrics.recordSerializationConflict("rw_dependency");
    otel_metrics.recordDeadlock("oldest_first");
    otel_metrics.recordLockWait(.exclusive, 0.001, .success);
    otel_metrics.decTransactionActive(.snapshot);

    // Storage + WAL
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

    // Graph
    otel_metrics.recordNodeMutation(.create, "default", .success);
    otel_metrics.recordEdgeMutation(.create, "default", .success);

    // Index + vector
    otel_metrics.recordIndexLookup(.btree, 0.0001, .success);
    otel_metrics.recordIndexUpdate(.btree, .create, 0.0002);
    otel_metrics.recordHnswSearch(.cosine, 0.001);

    // Security
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

    // Distributed
    otel_metrics.recordShardQuery(0, .success);
    otel_metrics.recordDistributedQuery(.strong, 0.05, .success);
    otel_metrics.recordDistributedFanout(.strong, 4);
    otel_metrics.recordPartialFailure("ShardUnavailable");

    // CDC + analytics
    otel_metrics.recordCdcEvent(.node_change, .success);
    otel_metrics.recordCdcSinkError(.kafka, "ConnectionRefused");
    otel_metrics.recordCdcEventDropped(.queue_full);
    otel_metrics.recordAnalyticsEvent("aggregate", .success);
    otel_metrics.recordAnalyticsProcessing("aggregate", 0.005);

    // Backup + restore
    otel_metrics.recordBackup(.full, 1.5, .success, null);
    otel_metrics.recordBackupBytes(.full, 1048576);
    otel_metrics.recordRestore(2.0, .success, null);
    otel_metrics.recordRestoreBytes(1048576);

    // db.client.* (DbClientOp is a []const u8 type alias)
    otel_metrics.recordDbClientOperation("MATCH", "node-1:3141", 0.005, .success, null);
    otel_metrics.incDbClientConnection("node-1:3141", .used);
    otel_metrics.decDbClientConnection("node-1:3141", .used);

    // Render Prometheus output and assert no forbidden attribute key appears.
    var prom = otel.exporters.prometheus.Prometheus.init(gpa, otel_metrics.getProvider().?);
    const body = try prom.render();
    defer gpa.free(body);

    for (FORBIDDEN_KEYS) |key| {
        // Prometheus translates `.` -> `_`; a leaked key would appear as e.g. `user_id="..."`.
        const tk = try std.mem.replaceOwned(u8, gpa, key, ".", "_");
        defer gpa.free(tk);
        var search_buf: [80]u8 = undefined;
        const needle = try std.fmt.bufPrint(&search_buf, "{s}=\"", .{tk});
        const found = std.mem.indexOf(u8, body, needle);
        if (found != null) {
            std.debug.print("LEAK: attribute key {s} appeared in /metrics body\n", .{key});
        }
        try std.testing.expect(found == null);
    }
}
