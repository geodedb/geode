const std = @import("std");
const cdc_mod = @import("../src/streaming/cdc_enhanced.zig");

// TestCANARY_REQ_GQL_042_CDC_OrderingConcurrency
// Launch multiple threads capturing changes concurrently and verify monotonic global sequence ordering after flush.

const thread_count: usize = 4;
const events_per_thread: usize = 50;

const WorkerCtx = struct { engine: *cdc_mod.CDCEngine, start_id: u64 };

fn worker(ctx: WorkerCtx) !void {
    var i: usize = 0;
    while (i < events_per_thread) : (i += 1) {
        try ctx.engine.emitChange(.insert, .node, ctx.start_id + @as(u64, @intCast(i)), null, null);
    }
}

test "TestCANARY_REQ_GQL_042_CDC_OrderingConcurrency" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try cdc_mod.CDCEngine.init(allocator, .{ .enabled = true, .sinks = &[_]cdc_mod.CDCSink{.memory}, .batch_size = 1000, .flush_interval_ms = 100 });
    defer engine.deinit();

    try engine.start();

    var threads: [thread_count]std.Thread = undefined;
    var t: usize = 0;
    while (t < thread_count) : (t += 1) {
        threads[t] = try std.Thread.spawn(.{}, worker, .{WorkerCtx{ .engine = &engine, .start_id = @as(u64, @intCast(t)) * 1000 }});
    }
    t = 0;
    while (t < thread_count) : (t += 1) threads[t].join();

    // Force flush to memory sink
    try engine.flushNow();

    const seqs = try engine.memorySinkSequences(allocator);
    defer allocator.free(seqs);
    var i: usize = 1;
    while (i < seqs.len) : (i += 1) {
        if (!(seqs[i] > seqs[i - 1])) return error.NonMonotonicSequence;
    }
    try std.testing.expect(seqs.len == thread_count * events_per_thread);
}
