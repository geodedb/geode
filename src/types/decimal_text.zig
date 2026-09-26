//! The exact text of a decimal, coeff * 10^-scale, for every i128
//! coefficient and every scale up to u16 (a query decimal's is u8, a heap
//! decimal's up to 32767) (SONNY-2769).
//!
//! The formatters this replaces each computed 10^scale in i128, one
//! `*= 10` per digit. Past scale 38 that overflows, which aborts a Debug or
//! ReleaseSafe server: `CAST(<a scale-40 decimal> AS STRING)`, `'a' || <it>`,
//! a map property holding it, the server's ORDER BY keys. Several also
//! negated the coefficient (minInt(i128) overflows), wrote the fraction into
//! a 32-byte buffer (a scale-36 value overran it, or came out NULL), or
//! dropped the sign of a value between -1 and 0 (-0.5 became "0.5"). This
//! works on the digits of |coeff| instead and never computes a power of ten.

// CANARY: REQ=REQ-SONNY-2769-DECIMAL-TEXT; FEATURE="DecimalText"; ASPECT=ExactAtAnyScale; STATUS=TESTED; TEST=tests/test_sonny2769_integer_overflow.zig; OWNER=types; UPDATED=2026-09-26

const std = @import("std");

/// |coeff| has at most 39 digits: 2^127 = 170141183460469231731687303715884105728.
const max_digits = 39;

/// The decimal digits of |coeff|, most significant first.
fn magnitude(buf: *[max_digits]u8, coeff: i128) []const u8 {
    var m: u128 = @abs(coeff);
    var i: usize = buf.len;
    while (true) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(m % 10));
        m /= 10;
        if (m == 0) return buf[i..];
    }
}

/// The length of the text: a '-' when negative, the integer digits (at
/// least one), and for a nonzero scale a '.' and exactly `scale` digits.
pub fn len(coeff: i128, scale: u16) usize {
    var buf: [max_digits]u8 = undefined;
    const digits = magnitude(&buf, coeff);
    const sign: usize = @intFromBool(coeff < 0);
    if (scale == 0) return sign + digits.len;
    const int_digits: usize = if (digits.len > scale) digits.len - scale else 1;
    return sign + int_digits + 1 + scale;
}

/// Writes the text of coeff * 10^-scale to `w` (anything with `writeAll`):
/// 150 at scale 2 is "1.50", -5 at scale 1 "-0.5", 1 at scale 40
/// "0.0000000000000000000000000000000000000001".
pub fn write(w: anytype, coeff: i128, scale: u16) !void {
    var buf: [max_digits]u8 = undefined;
    const digits = magnitude(&buf, coeff);
    if (coeff < 0) try w.writeAll("-");
    if (scale == 0) return w.writeAll(digits);
    if (digits.len > scale) {
        const int_len = digits.len - scale;
        try w.writeAll(digits[0..int_len]);
        try w.writeAll(".");
        return w.writeAll(digits[int_len..]);
    }
    try w.writeAll("0.");
    const zeros = "0" ** 64;
    var pad: usize = scale - digits.len;
    while (pad > 0) {
        const n = @min(pad, zeros.len);
        try w.writeAll(zeros[0..n]);
        pad -= n;
    }
    try w.writeAll(digits);
}

/// The text in `buf`, or NoSpaceLeft when it is longer.
pub fn bufPrint(buf: []u8, coeff: i128, scale: u16) error{NoSpaceLeft}![]u8 {
    var w: std.Io.Writer = .fixed(buf);
    write(&w, coeff, scale) catch return error.NoSpaceLeft;
    return w.buffered();
}

/// The text in a new allocation.
pub fn alloc(allocator: std.mem.Allocator, coeff: i128, scale: u16) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    // The allocating writer fails only when it cannot grow.
    write(&aw.writer, coeff, scale) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

test "decimal text at every scale and sign" {
    const cases = [_]struct { coeff: i128, scale: u16, text: []const u8 }{
        .{ .coeff = 0, .scale = 0, .text = "0" },
        .{ .coeff = 0, .scale = 2, .text = "0.00" },
        .{ .coeff = 150, .scale = 2, .text = "1.50" },
        .{ .coeff = -5, .scale = 1, .text = "-0.5" },
        .{ .coeff = -15, .scale = 1, .text = "-1.5" },
        .{ .coeff = 5, .scale = 3, .text = "0.005" },
        .{ .coeff = 1, .scale = 40, .text = "0.0000000000000000000000000000000000000001" },
        .{ .coeff = std.math.maxInt(i128), .scale = 0, .text = "170141183460469231731687303715884105727" },
        .{ .coeff = std.math.minInt(i128), .scale = 0, .text = "-170141183460469231731687303715884105728" },
        .{ .coeff = std.math.minInt(i128), .scale = 38, .text = "-1.70141183460469231731687303715884105728" },
        .{ .coeff = std.math.minInt(i128), .scale = 39, .text = "-0.170141183460469231731687303715884105728" },
    };
    for (cases) |c| {
        const got = try alloc(std.testing.allocator, c.coeff, c.scale);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(c.text, got);
        try std.testing.expectEqual(c.text.len, len(c.coeff, c.scale));
    }
    const long = try alloc(std.testing.allocator, -1, 255);
    defer std.testing.allocator.free(long);
    try std.testing.expectEqual(@as(usize, 258), long.len);
    try std.testing.expect(std.mem.startsWith(u8, long, "-0.000"));
    try std.testing.expect(std.mem.endsWith(u8, long, "01"));
    var small: [8]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, bufPrint(&small, 1, 40));
    try std.testing.expectEqualStrings("-12.345", try bufPrint(&small, -12345, 3));
}
