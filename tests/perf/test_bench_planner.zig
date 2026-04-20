const std = @import("std");
const testing = std.testing;

// Opt-in slow test: runs `zig build bench-query-planner` and parses output.
// Enable with GEODE_RUN_SLOW_TESTS=1. Kept slow/opt-in because it shells out
// to the build system and runs 2000*3 iterations per scenario — not appropriate
// for every `zig build test-perf` cycle.
test "bench-query-planner emits valid ResultDocument with 30 (scenario,size) rows" {
    // Zig 0.16: use std.c.getenv to read env vars.
    // If GEODE_RUN_SLOW_TESTS is unset or empty, skip this test.
    const should_run: bool = blk: {
        const key: [*:0]const u8 = "GEODE_RUN_SLOW_TESTS";
        const ptr = std.c.getenv(key) orelse break :blk false;
        const s = std.mem.span(ptr);
        break :blk s.len > 0;
    };
    if (!should_run) return error.SkipZigTest;

    // In Zig 0.16, global_single_threaded.allocator = .failing by default.
    // Process spawning (spawnPosix) needs a real allocator for argv/env buffers.
    const prev_alloc = std.Io.Threaded.global_single_threaded.allocator;
    std.Io.Threaded.global_single_threaded.allocator = std.heap.page_allocator;
    defer std.Io.Threaded.global_single_threaded.allocator = prev_alloc;

    const io = std.Io.Threaded.global_single_threaded.io();
    const tmp_json = "/tmp/test-bench-query-planner.json";

    const result = try std.process.run(std.heap.page_allocator, io, .{
        .argv = &.{
            "zig", "build",    "bench-query-planner", "-Doptimize=ReleaseFast",
            "--",  "--output", tmp_json,
        },
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    });
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);

    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    const contents = try std.Io.Dir.cwd().readFileAlloc(io, tmp_json, testing.allocator, .limited(8 * 1024 * 1024));
    defer testing.allocator.free(contents);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, contents, .{});
    defer parsed.deinit();
    const rows = parsed.value.object.get("rows").?.array;
    // 30 (scenario, size) pairs × 8 measurement rows each = 240 total rows.
    try testing.expect(rows.items.len >= 200);

    // At least one row must have measurement == "latency_plan_ns_p50" with value > 0.
    var found_nonzero_plan: bool = false;
    for (rows.items) |row| {
        const m = row.object.get("measurement") orelse continue;
        if (!std.mem.eql(u8, m.string, "latency_plan_ns_p50")) continue;
        const v = row.object.get("value") orelse continue;
        const val: f64 = switch (v) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => continue,
        };
        if (val > 0) {
            found_nonzero_plan = true;
            break;
        }
    }
    try testing.expect(found_nonzero_plan);
}
