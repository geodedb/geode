const std = @import("std");
const testing = std.testing;

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


test "CDC diagnostics export contains core, adaptive & ratio fields" {
    var engine = try makeEngine();
    defer engine.deinit();

    try engine.start();
    defer engine.stop();

    // Simulate events + multiple malformed WAL records to produce ratio > 0
    try engine.captureChange(.insert, .node, 1, null, "{\"id\":1}");
    try engine.captureChange(.update, .node, 1, "{\"id\":1}", "{\"id\":1,\"v\":2}");
    try engine.ingestChangeRecord(2, .node, 5, "BAD_PAYLOAD");
    try engine.ingestChangeRecord(2, .node, 6, "BAD_PAYLOAD2");

    var diag = try engine.exportDiagnostics(dummyAllocator());
    defer diag.deinit(dummyAllocator());

    try testing.expect(diag.malformed_change_records > 0);
    try testing.expect(diag.total_change_attempts > 0);
    try testing.expect(diag.config != null);
    try testing.expect(diag.engine != null);
    try testing.expect(diag.version.len > 0);
    try testing.expect(diag.timestamp_ms > 0);
    try testing.expect(diag.malformed_snapshots.items.len > 0);
    try testing.expect(diag.malformed_ratio > 0);
    if (diag.engine) |engine_diag| {
        try testing.expect(engine_diag.dynamic_batch_size >= 0);
        try testing.expect(engine_diag.batch_adjustments >= 0);
    }
}
