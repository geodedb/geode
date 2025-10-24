const std = @import("std");
const testing = std.testing;
const cdc = @import("../src/streaming/cdc_enhanced.zig");
const protocol = @import("../src/protocol.zig");
const posix = std.posix;

// Helper to count occurrences of a substring in a haystack
fn countOccurrences(hay: []const u8, needle: []const u8) usize {
    var i: usize = 0;
    var count: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.mem.eql(u8, hay[i .. i + needle.len], needle)) count += 1;
    }
    return count;
}

test "TestCANARY_REQ_GQL_042_CDC_MalformedSnapshotIntervalEnv" {
    // Set env overrides
    try posix.setenv("GEODE_MALFORMED_WAL_SNAPSHOT_INTERVAL", "2", 1);
    defer posix.unsetenv("GEODE_MALFORMED_WAL_SNAPSHOT_INTERVAL") catch {};
    var engine = try cdc.CDCEngine.init(testing.allocator, .{ .enabled = true, .sinks = &.{.memory} });
    defer engine.deinit();
    try testing.expectEqual(@as(u64, 2), engine.config.malformed_snapshot_interval);
    // Ingest malformed records (payload without braces)
    try engine.ingestFromWalRecord(1, .node, 1, "bad"); // count 1 (recorded)
    try engine.ingestFromWalRecord(1, .node, 2, "bad"); // count 2 (interval)
    try engine.ingestFromWalRecord(1, .node, 3, "bad"); // count 3 (not interval)
    try engine.ingestFromWalRecord(1, .node, 4, "bad"); // count 4 (interval)
    const diag = try engine.exportDiagnostics(testing.allocator);
    defer testing.allocator.free(diag);
    // Expect snapshots for counts 1,2,4 (at least)
    try testing.expect(std.mem.indexOf(u8, diag, "\"count\":1") != null);
    try testing.expect(std.mem.indexOf(u8, diag, "\"count\":2") != null);
    try testing.expect(std.mem.indexOf(u8, diag, "\"count\":4") != null);
}

test "TestCANARY_REQ_GQL_042_CDC_MalformedPayloadHash" {
    var engine = try cdc.CDCEngine.init(testing.allocator, .{ .enabled = true, .sinks = &.{.memory}, .malformed_hash_retain = 3 });
    defer engine.deinit();
    // Ingest 5 malformed payloads
    try engine.ingestFromWalRecord(1, .node, 1, "x");
    try engine.ingestFromWalRecord(1, .node, 2, "y");
    try engine.ingestFromWalRecord(1, .node, 3, "z");
    try engine.ingestFromWalRecord(1, .node, 4, "q");
    try engine.ingestFromWalRecord(1, .node, 5, "r");
    const diag = try engine.exportDiagnostics(testing.allocator);
    defer testing.allocator.free(diag);
    // Count hash entries; should be 3 (retention)
    const hashes = countOccurrences(diag, "\"hash\":");
    try testing.expectEqual(@as(usize, 3), hashes);
}

test "TestCANARY_REQ_GQL_042_CDC_MalformedGuardrailEnv" {
    // Set thresholds via env; warn=0.10 abort=0.20
    try posix.setenv("GEODE_MALFORMED_WAL_WARN_PCT", "0.10", 1);
    try posix.setenv("GEODE_MALFORMED_WAL_ABORT_PCT", "0.20", 1);
    defer posix.unsetenv("GEODE_MALFORMED_WAL_WARN_PCT") catch {};
    defer posix.unsetenv("GEODE_MALFORMED_WAL_ABORT_PCT") catch {};
    var engine = try cdc.CDCEngine.init(testing.allocator, .{ .enabled = true, .sinks = &.{.memory} });
    defer engine.deinit();
    try testing.expectApproxEqAbs(@as(f64, 0.10), engine.config.malformed_warn_pct, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0.20), engine.config.malformed_abort_pct, 0.0001);
    // Produce 1 malformed + 4 valid (ratio 0.2 triggers both warn & abort)
    try engine.ingestFromWalRecord(1, .node, 1, "b"); // malformed
    try engine.ingestFromWalRecord(1, .node, 2, "{}");
    try engine.ingestFromWalRecord(1, .node, 3, "{}");
    try engine.ingestFromWalRecord(1, .node, 4, "{}");
    try engine.ingestFromWalRecord(1, .node, 5, "{}");
    try testing.expect(engine.guardrail_warn_triggered);
    try testing.expect(engine.guardrail_abort_triggered);
    const diag = try engine.exportDiagnostics(testing.allocator);
    defer testing.allocator.free(diag);
    try testing.expect(std.mem.indexOf(u8, diag, "\"guardrail_warn_triggered\":true") != null);
    try testing.expect(std.mem.indexOf(u8, diag, "\"guardrail_abort_triggered\":true") != null);
}

test "TestCANARY_REQ_GQL_042_CDC_DiagnosticsProtocol" {
    // Parse CDC_DIAGNOSTICS message
    const line = "{\"type\":\"CDC_DIAGNOSTICS\"}";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const msg = try protocol.parseClientMessage(arena.allocator(), line);
    try testing.expect(msg == .CDC_DIAGNOSTICS);
    // Build diagnostics frame
    const payload = "{\"cdc\":{\"malformed_wal_records\":0}}";
    const frame = try protocol.buildCdcDiagnosticsLine(testing.allocator, payload);
    defer testing.allocator.free(frame);
    try testing.expect(std.mem.indexOf(u8, frame, "\"type\":\"CDC_DIAGNOSTICS\"") != null);
}
