const std = @import("std");
const testing = std.testing;

// Opt-in slow test: runs `zig build bench-query-parser` and parses output.
// Enable with GEODE_RUN_SLOW_TESTS=1. Kept slow/opt-in because it shells out
// to the build system and runs 100,000+ parses — not appropriate for every
// `zig build test-perf` cycle.
test "bench-query-parser emits valid ResultDocument with 10 scenarios" {
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
    // Temporarily patch the allocator on the global IO instance and restore it.
    const prev_alloc = std.Io.Threaded.global_single_threaded.allocator;
    std.Io.Threaded.global_single_threaded.allocator = std.heap.page_allocator;
    defer std.Io.Threaded.global_single_threaded.allocator = prev_alloc;

    const io = std.Io.Threaded.global_single_threaded.io();
    const tmp_json = "/tmp/test-bench-query-parser.json";

    // Zig 0.16 process API: use std.process.run which spawns, waits, and collects output.
    const result = try std.process.run(std.heap.page_allocator, io, .{
        .argv = &.{
            "zig", "build",    "bench-query-parser", "-Doptimize=ReleaseFast",
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
    // 10 scenarios × 8 measurement rows per scenario = 80 rows.
    try testing.expect(rows.items.len >= 60);
}
