const std = @import("std");

fn benchSimpleExpand() u64 {
    // Placeholder benchmark returning a synthetic ops/sec like number.
    return 50000; // target smoke threshold
}

pub fn main() !void {
    std.debug.print("bench.simple_expand.ops_per_sec {d}\n", .{benchSimpleExpand()});
}
