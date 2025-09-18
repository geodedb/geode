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
    // Canonical numeric comparator aligning scales without string roundtrip.
    if (a == .Decimal and b == .Decimal) {
        const da = a.Decimal;
        const db = b.Decimal;
        if (da.scale == db.scale) {
            if (da.coeff < db.coeff) return .lt;
            if (da.coeff > db.coeff) return .gt;
            return .eq;
        }
        const maxs: u8 = @max(da.scale, db.scale);
        const ac = scaleAlign(da.coeff, da.scale, maxs) catch return .eq; // treat overflow as eq (diagnosed elsewhere)
        const bc = scaleAlign(db.coeff, db.scale, maxs) catch return .eq;
        if (ac < bc) return .lt;
        if (ac > bc) return .gt;
        return .eq;
    }
    if (a == .Decimal and b == .Int) {
        const da = a.Decimal;
        const bc = scaleAlign(@as(i128, b.Int), 0, da.scale) catch return .eq;
        if (da.coeff < bc) return .lt;
        if (da.coeff > bc) return .gt;
        return .eq;
    }
    if (a == .Int and b == .Decimal) {
        const db = b.Decimal;
        const ac = scaleAlign(@as(i128, a.Int), 0, db.scale) catch return .eq;
        if (ac < db.coeff) return .lt;
        if (ac > db.coeff) return .gt;
        return .eq;
    }
    // Fallback for Int/Int
    if (a == .Int and b == .Int) {
        if (a.Int < b.Int) return .lt;
        if (a.Int > b.Int) return .gt;
        return .eq;
    }
    return .eq;
}

fn scaleAlign(coeff: i128, from: u8, to: u8) !i128 {
    if (from == to) return coeff;
    if (from > to) {
        var i: u8 = 0;
        var v = coeff;
        while (i < from - to) : (i += 1) v = @divTrunc(v, 10);
        return v;
    }
    var v = coeff;
    var i: u8 = 0;
    while (i < to - from) : (i += 1) {
        if (v > @as(i128, std.math.maxInt(i128)) / 10 or v < @as(i128, std.math.minInt(i128)) / 10) return error.Overflow;
        v *= 10;
    }
    return v;
}

pub fn run(ally: std.mem.Allocator) !void {
    // Build a small set of decimals with varying scales and coefficients.
    var vals = std.ArrayList(geode.eval.Value){};
    defer vals.deinit();
    var i: usize = 0;
    while (i < 128) : (i += 1) {
        const coeff: i128 = PRNG.nextI128() % 1_000_000; // keep small for stringify
        const scale: u8 = @intCast(PRNG.next() % 6);
        try vals.append(.{ .Decimal = .{ .coeff = coeff, .scale = scale } });
    }
    // Antisymmetry
    const slice = vals.items[0..32];
    for (slice) |va| {
        for (slice) |vb| {
            const ab = cmpDec(va, vb);
            const ba = cmpDec(vb, va);
            switch (ab) {
                .lt => std.debug.assert(ba == .gt),
                .gt => std.debug.assert(ba == .lt),
                .eq => std.debug.assert(ba == .eq),
            }
            // Triples transitivity sampling: only when ai < bi to reduce cost
        }
    }
    // Transitivity: for random sampled triples among first 24
    const triple_slice = vals.items[0..24];
    var x: usize = 0;
    while (x < triple_slice.len) : (x += 1) {
        var y: usize = 0;
        while (y < triple_slice.len) : (y += 1) {
            var z: usize = 0;
            while (z < triple_slice.len) : (z += 1) {
                if (x == y or y == z or x == z) continue;
                const xy = cmpDec(triple_slice[x], triple_slice[y]);
                const yz = cmpDec(triple_slice[y], triple_slice[z]);
                const xz = cmpDec(triple_slice[x], triple_slice[z]);
                if (xy == .lt and yz == .lt) std.debug.assert(xz == .lt or xz == .eq);
                if (xy == .gt and yz == .gt) std.debug.assert(xz == .gt or xz == .eq);
            }
        }
    }
}

test "fuzz: decimal ordering skeleton" {
    try run(std.testing.allocator);
}
