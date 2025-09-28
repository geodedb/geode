const std = @import("std");
const geode = @import("geode");
const Context = struct {};

fn mkInput(max: usize, data: []const u8) []const u8 {
    const cap = if (max == 0) data.len else @min(max, data.len);
    return data[0..cap];
}

fn fuzz_parser(context: Context, data: []const u8) anyerror!void {
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
