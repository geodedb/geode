// CANARY: REQ=REQ-GAP-0925-DECIMAL-PRECISION-CEILING; FEATURE="Decimal"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0925_decimal_precision.zig:1; OWNER=types; UPDATED=2026-07-10
//
// Regression tests for GAP-0925: "`decimal_add` has no precision ceiling
// (unlike `decimal_mul`)".
//
// decimal_add silently produced a 39-digit result past the 38-digit SQL
// DECIMAL ceiling, while decimal_mul rejected a comparable overflow with
// DecimalOverflow — inconsistent enforcement. A single 38-digit precision
// ceiling (|coeff| < 10^38) now applies to add/sub/mul alike.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const Decimal128 = geode.types.decimal128.Decimal128;

test "GAP-0925: add enforces the 38-digit precision ceiling" {
    // 38 nines: the largest 38-digit value — still valid.
    const big = try Decimal128.fromStr("99999999999999999999999999999999999999");
    const one = try Decimal128.fromStr("1");

    // 38-nines + 1 = 10^38, a 39-digit value → must overflow (was silently
    // accepted before the fix).
    try testing.expectError(Decimal128.Error.Overflow, big.add(one));

    // A small add well under the ceiling still works.
    const a = try Decimal128.fromStr("123.45");
    const b = try Decimal128.fromStr("0.55");
    const sum = try a.add(b);
    try testing.expectEqual(@as(i128, 12400), sum.coeff);
    try testing.expectEqual(@as(i16, 2), sum.scale);
}

test "GAP-0925: sub enforces the ceiling too" {
    const neg_big = try Decimal128.fromStr("-99999999999999999999999999999999999999");
    const one = try Decimal128.fromStr("1");
    // -(38 nines) - 1 = -10^38 → 39-digit magnitude → overflow.
    try testing.expectError(Decimal128.Error.Overflow, neg_big.sub(one));
}

test "GAP-0925: mul rejects overflow (unchanged), now consistent with add" {
    // 10^19 * 10^19 = 10^38 → 39 digits → overflow (as before).
    const big = try Decimal128.fromStr("10000000000000000000");
    try testing.expectError(Decimal128.Error.Overflow, big.mul(big));

    // A modest mul under the ceiling still works.
    const a = try Decimal128.fromStr("12.5");
    const b = try Decimal128.fromStr("2");
    const p = try a.mul(b);
    try testing.expectEqual(@as(i128, 250), p.coeff);
}
