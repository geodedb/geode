const std = @import("std");
const testing = std.testing;
const cdc = @import("../src/streaming/cdc_enhanced.zig");
const posix = std.posix;
const protobuf = @import("protobuf");
const schema = @import("schema");

test "TestCANARY_REQ_GQL_042_CDC_MalformedSnapshotIntervalEnv" {
    // Set env overrides
    try posix.setenv("GEODE_CDC_MALFORMED_SNAPSHOT_INTERVAL", "2", 1);
    defer posix.unsetenv("GEODE_CDC_MALFORMED_SNAPSHOT_INTERVAL") catch {};
    var engine = try cdc.CDCEngine.init(testing.allocator, .{ .enabled = true, .sinks = &.{.memory} });
    defer engine.deinit();
    try testing.expectEqual(@as(u64, 2), engine.config.malformed_snapshot_interval);
    // Ingest malformed records (payload without braces)
    try engine.ingestChangeRecord(1, .node, 1, "bad"); // count 1 (recorded)
    try engine.ingestChangeRecord(1, .node, 2, "bad"); // count 2 (interval)
    try engine.ingestChangeRecord(1, .node, 3, "bad"); // count 3 (not interval)
    try engine.ingestChangeRecord(1, .node, 4, "bad"); // count 4 (interval)
    var diag = try engine.exportDiagnostics(testing.allocator);
    defer diag.deinit(testing.allocator);
    // Expect snapshots for counts 1,2,4 (at least)
    var has1 = false;
    var has2 = false;
    var has4 = false;
    for (diag.malformed_snapshots.items) |snap| {
        if (snap.count == 1) has1 = true;
        if (snap.count == 2) has2 = true;
        if (snap.count == 4) has4 = true;
    }
    try testing.expect(has1);
    try testing.expect(has2);
    try testing.expect(has4);
}

test "TestCANARY_REQ_GQL_042_CDC_MalformedPayloadHash" {
    var engine = try cdc.CDCEngine.init(testing.allocator, .{ .enabled = true, .sinks = &.{.memory}, .malformed_hash_retain = 3 });
    defer engine.deinit();
    // Ingest 5 malformed payloads
    try engine.ingestChangeRecord(1, .node, 1, "x");
    try engine.ingestChangeRecord(1, .node, 2, "y");
    try engine.ingestChangeRecord(1, .node, 3, "z");
    try engine.ingestChangeRecord(1, .node, 4, "q");
    try engine.ingestChangeRecord(1, .node, 5, "r");
    var diag = try engine.exportDiagnostics(testing.allocator);
    defer diag.deinit(testing.allocator);
    // Count hash entries; should be 3 (retention)
    try testing.expectEqual(@as(usize, 3), diag.malformed_hashes.items.len);
}

test "TestCANARY_REQ_GQL_042_CDC_MalformedGuardrailEnv" {
    // Set thresholds via env; warn=0.10 abort=0.20
    try posix.setenv("GEODE_CDC_MALFORMED_WARN_PCT", "0.10", 1);
    try posix.setenv("GEODE_CDC_MALFORMED_ABORT_PCT", "0.20", 1);
    defer posix.unsetenv("GEODE_CDC_MALFORMED_WARN_PCT") catch {};
    defer posix.unsetenv("GEODE_CDC_MALFORMED_ABORT_PCT") catch {};
    var engine = try cdc.CDCEngine.init(testing.allocator, .{ .enabled = true, .sinks = &.{.memory} });
    defer engine.deinit();
    try testing.expectApproxEqAbs(@as(f64, 0.10), engine.config.malformed_warn_pct, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0.20), engine.config.malformed_abort_pct, 0.0001);
    // Produce 1 malformed + 4 valid (ratio 0.2 triggers both warn & abort)
    try engine.ingestChangeRecord(1, .node, 1, "b"); // malformed
    try engine.ingestChangeRecord(1, .node, 2, "{}");
    try engine.ingestChangeRecord(1, .node, 3, "{}");
    try engine.ingestChangeRecord(1, .node, 4, "{}");
    try engine.ingestChangeRecord(1, .node, 5, "{}");
    try testing.expect(engine.guardrail_warn_triggered);
    try testing.expect(engine.guardrail_abort_triggered);
    var diag = try engine.exportDiagnostics(testing.allocator);
    defer diag.deinit(testing.allocator);
    try testing.expect(diag.guardrail_warn_triggered);
    try testing.expect(diag.guardrail_abort_triggered);
}

test "TestCANARY_REQ_GQL_042_CDC_DiagnosticsProtocol" {
    // Encode/decode CDC diagnostics request as protobuf client packet
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const msg = schema.ClientPacket{ .quic = .{ .cdc_diag = .{} } };
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit(allocator);
    var writer = buf.writer(allocator);
    try protobuf.encode(&writer, allocator, msg);

    var reader = std.Io.fixedBufferStream(buf.items).reader();
    var decoded = try protobuf.decode(schema.ClientPacket, &reader, allocator);
    defer decoded.deinit(allocator);
    try testing.expect(decoded.quic != null);
    try testing.expect(decoded.quic.? == .cdc_diag);
}
