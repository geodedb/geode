const std = @import("std");
const testing = std.testing;
const protocol = @import("protocol");

// NOTE: This is a lightweight E2E-style test that invokes the CDCEngine directly
// and exercises exportDiagnostics as the server handler would.
// A full network round trip test can be added later once QUIC test harness is stabilized.

extern fn getenv(name: [*:0]const u8) ?[*:0]u8; // to show how one might gate, not used.

const cdc = @import("cdc_enhanced");

fn dummyAllocator() std.mem.Allocator {
    return std.testing.allocator;
}

fn makeEngine() !cdc.CDCEngine {
    const cfg = cdc.CDCConfig{
        .enabled = true,
        .sinks = &[_]cdc.CDCSink{.memory},
        .batch_size = 4,
        .flush_interval_ms = 50,
        .adaptive_flush = true, // enable experimental adaptive flush so dynamic fields appear
    };
    return try cdc.CDCEngine.init(dummyAllocator(), cfg);
}

// Helper to assert substring presence
fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("Expected substring '{s}' in diagnostics: {s}\n", .{ needle, haystack });
        return error.NotFound;
    }
}

test "CDC diagnostics export contains core, adaptive & ratio fields" {
    var engine = try makeEngine();
    defer engine.deinit();

    try engine.start();
    defer engine.stop();

    // Simulate events + multiple malformed WAL records to produce ratio > 0
    try engine.captureChange(.insert, .node, 1, null, "{\"id\":1}");
    try engine.captureChange(.update, .node, 1, "{\"id\":1}", "{\"id\":1,\"v\":2}");
    try engine.ingestFromWalRecord(2, .node, 5, "BAD_PAYLOAD");
    try engine.ingestFromWalRecord(2, .node, 6, "BAD_PAYLOAD2");

    const diag = try engine.exportDiagnostics(dummyAllocator());
    defer dummyAllocator().free(diag);

    // Core counters
    try expectContains(diag, "\"malformed_wal_records\"");
    try expectContains(diag, "\"total_wal_attempts\"");
    try expectContains(diag, "\"config\"");
    try expectContains(diag, "\"engine\"");
    try expectContains(diag, "\"version\"");
    try expectContains(diag, "\"timestamp_ms\"");
    try expectContains(diag, "\"malformed_snapshots\"");
    // Adaptive flush & ratio related fields
    try expectContains(diag, "\"malformed_ratio\"");
    try expectContains(diag, "\"adaptive_flush\"");
    try expectContains(diag, "\"dynamic_batch_size\"");
    try expectContains(diag, "\"batch_adjustments\"");
}
