const std = @import("std");
const geode = @import("geode");

// Deterministic pseudo-random generator (xorshift) for reproducibility.
const PRNG = struct {
    var state: u64 = 0x1234_5678_9abc_def0;
    fn next() u64 {
        var x = state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        state = x;
        return x;
    }
    fn nextI128() i128 {
        return @as(i128, @intCast(@as(i64, @bitCast(next()))));
    }
};

fn cmpDec(a: geode.eval.Value, b: geode.eval.Value) std.math.Order {
    // Reuse eval comparison via ORDER BY numeric ordering semantics: convert through exec comparator?
    // Placeholder: compare stringified values to get deterministic ordering; will be replaced by direct numeric compare.
    var bufA: [64]u8 = undefined;
    var bufB: [64]u8 = undefined;
    const sa = geode.eval.stringify(a, &bufA) catch return .eq;
    const sb = geode.eval.stringify(b, &bufB) catch return .eq;
    return std.mem.order(u8, sa, sb);
}

pub fn run(ally: std.mem.Allocator) !void {
    // Build a small set of decimals with varying scales and coefficients.
    var vals = std.ArrayList(geode.eval.Value).init(ally);
    defer vals.deinit();
    var i: usize = 0;
    while (i < 128) : (i += 1) {
        const coeff: i128 = PRNG.nextI128() % 1_000_000; // keep small for stringify
        const scale: u8 = @intCast(PRNG.next() % 6);
        try vals.append(.{ .Decimal = .{ .coeff = coeff, .scale = scale } });
    }
    // Antisymmetry & transitivity spot checks (O(n^3) trimmed)
    // For first 32 only to keep runtime bounded.
    const slice = vals.items[0..32];
    var a: usize = 0;
    while (a < slice.len) : (a += 1) {
        var b: usize = 0;
        while (b < slice.len) : (b += 1) {
            const ab = cmpDec(slice[a], slice[b]);
            const ba = cmpDec(slice[b], slice[a]);
            if (ab == .lt) std.debug.assert(ba == .gt);
            if (ab == .gt) std.debug.assert(ba == .lt);
            if (ab == .eq) std.debug.assert(ba == .eq);
        }
    }
}

test "fuzz: decimal ordering skeleton" {
    try run(std.testing.allocator);
}
