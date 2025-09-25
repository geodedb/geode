const std = @import("std");
// CANARY: REQ=REQ-GQL-010; FEATURE="Diagnostics Precedence & Folding"; ASPECT=Engine; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_010_DiagnosticsFold; OWNER=engine; UPDATED=2025-09-20

pub const Code = enum(u16) {
    US001 = 1, // Pagination unordered
    GroupByIllegal = 2,
    IllegalOrderKey = 3,
    TypeMismatch = 4,
    TypeMismatchDivZero = 5, // Division by zero subclass
    TxnState = 6,
    StoragePageChecksum = 7,
    ExecutionGuardTrip = 8, // MATCH safety guard (max_results/max_frontier) triggered
};

pub fn codeName(c: Code) []const u8 {
    return switch (c) {
        .US001 => "US001",
        .GroupByIllegal => "GroupByIllegal",
        .IllegalOrderKey => "IllegalOrderKey",
        .TypeMismatch => "TypeMismatch",
        .TypeMismatchDivZero => "TypeMismatch.DivZero",
        .TxnState => "TxnState",
        .StoragePageChecksum => "StoragePageChecksum",
        .ExecutionGuardTrip => "ExecutionGuardTrip",
    };
}

pub fn anchorFor(c: Code) []const u8 {
    return switch (c) {
        .US001 => "16.18–16.19",
        .IllegalOrderKey, .GroupByIllegal => "14.10",
        .TypeMismatch, .TypeMismatchDivZero => "16.x",
        .TxnState => "8",
        .StoragePageChecksum => "4",
        .ExecutionGuardTrip => "14.x",
    };
}

pub fn defaultMessage(c: Code) []const u8 {
    return switch (c) {
        .US001 => "unordered pagination",
        .IllegalOrderKey => "ORDER BY key must be identifier",
        .GroupByIllegal => "group by illegal",
        .TypeMismatch => "type mismatch",
        .TypeMismatchDivZero => "division by zero",
        .TxnState => "transaction state error",
        .StoragePageChecksum => "page checksum mismatch detected during load",
        .ExecutionGuardTrip => "match execution safety guard tripped",
    };
}

pub const Severity = enum { Info, Warning, Error };

pub const Diagnostic = struct {
    code: Code,
    severity: Severity = .Error,
    message: []const u8,
};

pub fn precedence(a: Code, b: Code) Code {
    // Explicit precedence ordering table (lower index wins): US001, IllegalOrderKey, GroupByIllegal, TypeMismatch, TypeMismatchDivZero
    inline for (.{ Code.US001, Code.IllegalOrderKey, Code.GroupByIllegal, Code.TypeMismatch, Code.TypeMismatchDivZero, Code.TxnState, Code.ExecutionGuardTrip }) |ord| {
        // extend precedence sequence with StoragePageChecksum lowest priority (surface separately)
        if (a == ord and b == ord) return a;
    }
    // If different, pick the one that appears earlier in the sequence above.
    const idx = struct {
        fn rank(c: Code) u8 {
            return switch (c) {
                .US001 => 0,
                .IllegalOrderKey => 1,
                .GroupByIllegal => 2,
                .TypeMismatch => 3,
                .TypeMismatchDivZero => 4,
                .TxnState => 5,
                .ExecutionGuardTrip => 6,
                .StoragePageChecksum => 7,
            };
        }
    };
    return if (idx.rank(a) <= idx.rank(b)) a else b;
}

pub fn sortByPrecedence(codes: []Code) void {
    // Simple insertion sort using precedence() comparator (small N)
    var i: usize = 1;
    while (i < codes.len) : (i += 1) {
        const key = codes[i];
        var j: isize = @as(isize, @intCast(i)) - 1;
        while (j >= 0 and precedence(codes[@as(usize, @intCast(j))], key) == key) : (j -= 1) {
            codes[@as(usize, @intCast(j + 1))] = codes[@as(usize, @intCast(j))];
        }
        codes[@as(usize, @intCast(j + 1))] = key;
    }
}

// foldCodes applies precedence (UA002 policy) to a set of diagnostic codes:
//  - de-duplicates in-place (stable first occurrence)
//  - sorts by precedence (lowest rank first)
//  - returns slice length after dedup (leading portion of input slice)
pub fn foldCodes(codes: []Code) usize {
    if (codes.len == 0) return 0;
    // Deduplicate (small N; O(n^2) acceptable)
    var out_idx: usize = 0;
    var i: usize = 0;
    while (i < codes.len) : (i += 1) {
        var seen = false;
        var j: usize = 0;
        while (j < out_idx) : (j += 1) {
            if (codes[j] == codes[i]) {
                seen = true;
                break;
            }
        }
        if (!seen) {
            codes[out_idx] = codes[i];
            out_idx += 1;
        }
    }
    sortByPrecedence(codes[0..out_idx]);
    return out_idx;
}

test "diagnostics: code name and precedence" {
    try std.testing.expectEqualStrings("US001", codeName(.US001));
    try std.testing.expect(precedence(.GroupByIllegal, .US001) == .US001);
}

test "diagnostics: sortByPrecedence orders ascending" {
    var arr: [3]Code = .{ .IllegalOrderKey, .US001, .TypeMismatch };
    sortByPrecedence(arr[0..]);
    try std.testing.expect(arr[0] == .US001);
    try std.testing.expect(arr[1] == .IllegalOrderKey);
    try std.testing.expect(arr[2] == .TypeMismatch);
}

test "diagnostics: foldCodes dedup + precedence" {
    var arr: [5]Code = .{ .TypeMismatch, .US001, .IllegalOrderKey, .US001, .IllegalOrderKey };
    const n = foldCodes(arr[0..]);
    try std.testing.expect(n == 3);
    try std.testing.expect(arr[0] == .US001);
    try std.testing.expect(arr[1] == .IllegalOrderKey);
    try std.testing.expect(arr[2] == .TypeMismatch);
}

test "diagnostics: foldCodes already sorted idempotent" {
    var arr: [4]Code = .{ .US001, .IllegalOrderKey, .GroupByIllegal, .TypeMismatch };
    const n = foldCodes(arr[0..]);
    try std.testing.expect(n == 4);
    try std.testing.expect(arr[0] == .US001);
    try std.testing.expect(arr[1] == .IllegalOrderKey);
    try std.testing.expect(arr[2] == .GroupByIllegal);
    try std.testing.expect(arr[3] == .TypeMismatch);
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

pub fn mapParserMessage(msg: []const u8) ?Code {
    // Recognize parser policy messages related to ORDER BY key legality.
    if (std.mem.indexOf(u8, msg, "ORDER BY key must be identifier") != null) return .IllegalOrderKey;
    if (std.mem.indexOf(u8, msg, "ORDER BY key must be identifier or member") != null) return .IllegalOrderKey;
    if (std.mem.indexOf(u8, msg, "function calls in ORDER BY are disabled") != null) return .IllegalOrderKey;
    if (std.mem.indexOf(u8, msg, "ORDER BY cannot reference path alias") != null) return .IllegalOrderKey;
    if (std.mem.indexOf(u8, msg, "ORDER BY key must reference projected identifier") != null) return .IllegalOrderKey;
    return null;
}

test "diagnostics: map parser messages to IllegalOrderKey" {
    try std.testing.expect(mapParserMessage("ORDER BY key must be identifier").? == .IllegalOrderKey);
    try std.testing.expect(mapParserMessage("function calls in ORDER BY are disabled").? == .IllegalOrderKey);
}

pub fn mapEvalError(e: anytype) ?Code {
    const name = @errorName(e);
    if (std.mem.eql(u8, name, "TypeMismatch")) return .TypeMismatch;
    if (std.mem.eql(u8, name, "DivisionByZero")) return .TypeMismatchDivZero;
    return null;
}

pub fn mapStorageError(e: anytype) ?Code {
    const name = @errorName(e);
    if (std.mem.eql(u8, name, "PageChecksumMismatch")) return .StoragePageChecksum;
    return null;
}

test "diagnostics: map eval errors" {
    try std.testing.expect(mapEvalError(error.TypeMismatch).? == .TypeMismatch);
}

test "diagnostics: map storage errors" {
    try std.testing.expect(mapStorageError(error.PageChecksumMismatch).? == .StoragePageChecksum);
}
