const std = @import("std");
const cdc = @import("cdc_enhanced");
// TestCANARY_REQ_GQL_042_BackpressureAdaptive
// Simulates buffer growth & shrink cycles and validates adaptive watermark adjustments.

test "TestCANARY_REQ_GQL_042_BackpressureAdaptive" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var cfg: cdc.CDCConfig = .{};
    cfg.enabled = true;
    cfg.pending_backpressure_watermark = 10_000; // starting watermark
    cfg.adaptive_backpressure = true;
    cfg.backpressure_adjust_min_events = 50;
    cfg.backpressure_high_pct = 0.80;
    cfg.backpressure_low_pct = 0.20;
    cfg.backpressure_step_pct = 0.50; // 50% adjust for clearer test signal
    cfg.backpressure_min_watermark = 2_000;
    cfg.backpressure_max_watermark = 100_000;

    var engine = try cdc.CDCEngine.init(allocator, cfg);
    defer engine.deinit();

    // Helper to push fake events without full change capture complexity.
    const FakeEvent = cdc.ChangeEvent;
    var meta = std.StringHashMap([]const u8).init(allocator);
    defer meta.deinit();

    // Phase 1: drive peak above high threshold repeatedly to trigger shrink.
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        // append events to exceed 80% of 10k (~8k). We'll push 9000.
        // We reuse buffer by truncating afterwards to simulate streaming consumption.
        while (engine.event_buffer.items.len < 9000) {
            const e = FakeEvent{ .timestamp = 0, .transaction_id = 0, .sequence = engine.next_sequence, .change_type = .insert, .entity_type = .node, .entity_id = 0, .before = null, .after = null, .metadata = meta };
            engine.event_buffer.append(e) catch unreachable;
            engine.next_sequence += 1;
            engine.adaptiveTick();
        }
        // simulate consumer draining back to half
        engine.event_buffer.shrinkRetainingCapacity(engine.event_buffer.items.len / 2);
    }
    const shrunk_wm = engine.config.pending_backpressure_watermark;
    try std.testing.expect(shrunk_wm < 10_000);

    // Phase 2: hold buffer very low to trigger growth
    var j: usize = 0;
    while (j < 60) : (j += 1) {
        // keep only 500 events (<20% even if shrunk to maybe ~5000)
        if (engine.event_buffer.items.len > 500) engine.event_buffer.shrinkRetainingCapacity(500);
        // add a small number to tick stats
        var k: usize = 0;
        while (k < 100) : (k += 1) {
            const e2 = FakeEvent{ .timestamp = 0, .transaction_id = 0, .sequence = engine.next_sequence, .change_type = .insert, .entity_type = .node, .entity_id = 0, .before = null, .after = null, .metadata = meta };
            engine.event_buffer.append(e2) catch unreachable;
            engine.next_sequence += 1;
            engine.adaptiveTick();
        }
    }
    const grown_wm = engine.config.pending_backpressure_watermark;
    try std.testing.expect(grown_wm > shrunk_wm);
}
