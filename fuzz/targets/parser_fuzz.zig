const std = @import("std");
const geode = @import("geode");
const Context = struct {};

fn mkInput(max: usize, data: []const u8) []const u8 {
    const cap = if (max == 0) data.len else @min(max, data.len);
    return data[0..cap];
}

// Zig 0.16: std.testing.fuzz hands the test a *Smith generator instead of a
// raw byte slice.  Draw a fuzzer-controlled byte slice from the Smith and
// feed it to the original byte-driven harness.
fn fuzz_parser(context: Context, smith: *std.testing.Smith) anyerror!void {
    var buf: [64 * 1024]u8 = undefined;
    const len = smith.slice(&buf);
    try fuzz_parser_bytes(context, buf[0..len]);
}

fn fuzz_parser_bytes(context: Context, data: []const u8) anyerror!void {
    _ = context;
    const slice = mkInput(64 * 1024, data);
    var fa = std.testing.FailingAllocator.init(std.heap.page_allocator, .{ .fail_index = if (slice.len == 0) 0 else @intCast(slice[0] % 16) });
    const ally = fa.allocator();
    const opts: geode.ParseOptions = .{ .ident_order_only = true, .forbid_orderby_calls = true };
    _ = geode.parseGqlOutcome(slice, ally, opts) catch |e| switch (e) {
        error.OutOfMemory => return,
        else => return,
    };
}

test "fuzz parser" {
    try std.testing.fuzz(Context{}, fuzz_parser, .{});
    std.debug.print("fuzzing: completed\n", .{});
}
