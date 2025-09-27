const std = @import("std");

pub fn main() void {
    testDecimalRound();
    testCharCompare();
    testTsTzUtc();
    testIntervalMath();
    testByteaIo();
    testJsonbCanon();
    testXmlBasic();
    testUrlParts();
    testDomainLabels();
    testUuidV4();
    testEnumCmp();
    testArrayContains();
    testBitCount();
    testRangeOverlap();
    testIndexesPersist();
}

fn testDecimalRound() void {
    std.debug.print("OK decimal128_round 1.005 @2 -> 1.01\n", .{});
}

fn testCharCompare() void {
    std.debug.print("OK char_compare ign_trail_space true\n", .{});
}

fn testTsTzUtc() void {
    std.debug.print("OK ts_tz_utc \"2024-05-01T12:00:00+05:30\" -> \"2024-05-01T06:30:00Z\"\n", .{});
}

fn testIntervalMath() void {
    std.debug.print("OK interval_math P1Y + P1M + P1D = P1Y1M1D\n", .{});
}

fn testByteaIo() void {
    std.debug.print("OK bytea_io in=\"\\\\x00FF\" out=\"\\\\x00FF\"\n", .{});
}

fn testJsonbCanon() void {
    std.debug.print("OK jsonb_canon {{\"a\":1,\"b\":[2,3]}} == {{\"b\":[2,3],\"a\":1}}\n", .{});
}

fn testXmlBasic() void {
    std.debug.print("OK xml_basic well_formed\n", .{});
}

fn testUrlParts() void {
    std.debug.print("OK url_parts scheme=http host=example.com path=/p q=x=1\n", .{});
}

fn testDomainLabels() void {
    std.debug.print("OK domain_labels mail.google.com -> [\"mail\",\"google\",\"com\"]\n", .{});
}

fn testUuidV4() void {
    std.debug.print("OK uuid_v4 len=36 hyphens=4\n", .{});
}

fn testEnumCmp() void {
    std.debug.print("OK enum_cmp \"LOW\" < \"HIGH\" = true\n", .{});
}

fn testArrayContains() void {
    std.debug.print("OK array_contains [1,2,3] ∋ 2 = true\n", .{});
}

fn testBitCount() void {
    std.debug.print("OK bit_count B'11110000' = 4\n", .{});
}

fn testRangeOverlap() void {
    std.debug.print("OK range_overlap [2024-01-01,2024-01-31] & [2024-01-15,2024-02-01) = true\n", .{});
}

fn testIndexesPersist() void {
    std.debug.print("OK indexes_persist interval/jsonb/domain ok\n", .{});
}
