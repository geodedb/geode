const std = @import("std");

pub const Code = enum(u16) {
    US001 = 1, // Pagination unordered
    GroupByIllegal = 2,
    IllegalOrderKey = 3,
};

pub fn codeName(c: Code) []const u8 {
    return switch (c) {
        .US001 => "US001",
        .GroupByIllegal => "GroupByIllegal",
        .IllegalOrderKey => "IllegalOrderKey",
    };
}

pub const Severity = enum { Info, Warning, Error };

pub const Diagnostic = struct {
    code: Code,
    severity: Severity = .Error,
    message: []const u8,
};

pub fn precedence(a: Code, b: Code) Code {
    // Simple precedence: lower numeric code wins
    return if (@intFromEnum(a) <= @intFromEnum(b)) a else b;
}

test "diagnostics: code name and precedence" {
    try std.testing.expectEqualStrings("US001", codeName(.US001));
    try std.testing.expect(precedence(.GroupByIllegal, .US001) == .US001);
}

pub fn mapPlannerError(e: anytype) ?Code {
    // Match by error name; works for error.Union members
    const name = @errorName(e);
    if (std.mem.eql(u8, name, "OffsetPushdownRequiresOrder")) return .US001;
    if (std.mem.eql(u8, name, "GroupByIllegal")) return .GroupByIllegal;
    return null;
}

test "diagnostics: map planner errors" {
    const name1 = @errorName(error.OffsetPushdownRequiresOrder);
    _ = name1; // sanity
    try std.testing.expect(mapPlannerError(error.OffsetPushdownRequiresOrder).? == .US001);
    try std.testing.expect(mapPlannerError(error.GroupByIllegal).? == .GroupByIllegal);
}
