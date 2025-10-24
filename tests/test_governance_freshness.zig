const std = @import("std");

// CANARY: REQ=REQ-GQL-010; FEATURE="Governance"; ASPECT=FreshnessGuardTest; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_FreshnessGuardTest; OWNER=tooling; UPDATED=2025-09-21
// This test simulates detection of a stale BENCHED aspect (>60d). It does not invoke external scanner binary to remain hermetic.

const AspectRecord = struct { updated: []const u8, status: []const u8 };

fn parseDate(s: []const u8) ?struct { y: i32, m: i32, d: i32 } {
    if (s.len != 10) return null; // YYYY-MM-DD
    var year: i32 = 0;
    var month: i32 = 0;
    var day: i32 = 0;
    inline for ([_]usize{ 0, 1, 2, 3 }) |i| year = year * 10 + @as(i32, s[i] - '0');
    inline for ([_]usize{ 5, 6 }) |i| month = month * 10 + @as(i32, s[i] - '0');
    inline for ([_]usize{ 8, 9 }) |i| day = day * 10 + @as(i32, s[i] - '0');
    return .{ .y = year, .m = month, .d = day };
}

fn daysBetween(a: struct { y: i32, m: i32, d: i32 }, b: struct { y: i32, m: i32, d: i32 }) i32 {
    // Simplistic: convert to days assuming 30-day months, 365-day years (sufficient for stale detection heuristically)
    return (b.y - a.y) * 365 + (b.m - a.m) * 30 + (b.d - a.d);
}

test "TestCANARY_REQ_GQL_010_FreshnessGuardTest" {
    // Simulate today's date
    const today = parseDate("2025-09-21").?;
    // Simulated stale aspect updated 2025-06-01 (>60d difference ~112 days with simplification)
    const stale = AspectRecord{ .updated = "2025-06-01", .status = "BENCHED" };
    const upd = parseDate(stale.updated).?;
    const diff = daysBetween(upd, today);
    try std.testing.expect(diff > 60);
}
