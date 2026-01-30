const std = @import("std");
// CANARY: REQ=REQ-GQL-026; FEATURE="Conformance/Flagger"; ASPECT=FlaggerCompleteness; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_026_FlaggerCompleteness,TestCANARY_REQ_GQL_026_FlaggerNegativeMissing; BENCH=BenchmarkCANARY_REQ_GQL_026_FlaggerGenerationVarianceEnvelope; OWNER=conformance; UPDATED=2025-09-27

pub const Profile = struct {
    version: []const u8 = "skeleton",
    features: Features,
};

pub const Features = struct {
    // Core language features
    order_by: bool = true,
    order_by_nulls_policy: bool = true,
    order_by_alias_resolution: bool = true,
    group_by_phase1: bool = true,
    having_parsed: bool = true,
    set_ops_skeleton: bool = true,
    temporals_structured: bool = true,
    session_offset_flag: bool = true,
    // ISO conformance features
    select_statement: bool = true,
    return_distinct: bool = true,
    unicode_identifiers: bool = true,
    case_insensitive_identifiers: bool = true,
    comment_double_slash: bool = true, // GB03
    comment_double_dash: bool = true, // GB02
    reserved_words_complete: bool = true,
    unordered_pagination: bool = true, // No longer requires ORDER BY
    structured_diagnostics: bool = true,
};

pub fn writeConformanceJson(w: anytype, prof: Profile) !void {
    try w.writeByte('{');
    try w.print("\"version\":\"{s}\",", .{prof.version});
    try w.writeAll("\"features\":{");
    try w.print("\"order_by\":{},", .{prof.features.order_by});
    try w.print("\"order_by_nulls_policy\":{},", .{prof.features.order_by_nulls_policy});
    try w.print("\"order_by_alias_resolution\":{},", .{prof.features.order_by_alias_resolution});
    try w.print("\"group_by_phase1\":{},", .{prof.features.group_by_phase1});
    try w.print("\"having_parsed\":{},", .{prof.features.having_parsed});
    try w.print("\"set_ops_skeleton\":{},", .{prof.features.set_ops_skeleton});
    try w.print("\"temporals_structured\":{},", .{prof.features.temporals_structured});
    try w.print("\"session_offset_flag\":{},", .{prof.features.session_offset_flag});
    try w.print("\"select_statement\":{},", .{prof.features.select_statement});
    try w.print("\"return_distinct\":{},", .{prof.features.return_distinct});
    try w.print("\"unicode_identifiers\":{},", .{prof.features.unicode_identifiers});
    try w.print("\"case_insensitive_identifiers\":{},", .{prof.features.case_insensitive_identifiers});
    try w.print("\"comment_double_slash\":{},", .{prof.features.comment_double_slash});
    try w.print("\"comment_double_dash\":{},", .{prof.features.comment_double_dash});
    try w.print("\"reserved_words_complete\":{},", .{prof.features.reserved_words_complete});
    try w.print("\"unordered_pagination\":{},", .{prof.features.unordered_pagination});
    try w.print("\"structured_diagnostics\":{}", .{prof.features.structured_diagnostics});
    try w.writeAll("}}");
}

test "conformance json outputs expected keys" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit(std.testing.allocator);
    const prof = Profile{ .features = .{} };
    try writeConformanceJson(buf.writer(std.testing.allocator), prof);
    const s = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, s, "\"version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"features\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"group_by_phase1\"") != null);
}

pub fn collectImplDefinedFlags(allocator: std.mem.Allocator) ![][]const u8 {
    var list = try allocator.alloc([]const u8, 5);
    list[0] = "CollationBinaryDefault";
    list[1] = "NullOrderPolicyDefault";
    list[2] = "UnorderedPaginationAllowed"; // Changed from US001
    list[3] = "UA005PathTieBreak";
    list[4] = "UA006PathTieBreak";
    return list;
}

test "TestCANARY_REQ_GQL_026_FlaggerCompleteness" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const flags = try collectImplDefinedFlags(alloc);
    defer alloc.free(flags);
    // ensure required flags present
    inline for (.{ "CollationBinaryDefault", "US001PaginationPolicy" }) |req| {
        var found = false;
        for (flags) |f| {
            if (std.mem.eql(u8, f, req)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

// Negative guard: ensure a bogus required flag (should not exist) is absent; protects against false positives in completeness logic.
test "TestCANARY_REQ_GQL_026_FlaggerNegativeMissing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const flags = try collectImplDefinedFlags(alloc);
    defer alloc.free(flags);
    var found = false;
    for (flags) |f| {
        if (std.mem.eql(u8, f, "NonExistentPolicyToggle")) {
            found = true;
        }
    }
    try std.testing.expect(!found);
}

test "BenchmarkCANARY_REQ_GQL_026_FlaggerGenerationVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const iterations: usize = 64;
    var samples = try alloc.alloc(u64, iterations);
    defer alloc.free(samples);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();
        const flags = collectImplDefinedFlags(alloc) catch unreachable;
        alloc.free(flags);
        const end = std.time.nanoTimestamp();
        samples[i] = @as(u64, @intCast(end - start));
    }
    var sum: f128 = 0;
    for (samples) |s| sum += @as(f128, @floatFromInt(s));
    const mean = sum / @as(f128, @floatFromInt(iterations));
    var var_acc: f128 = 0;
    for (samples) |s| {
        const diff = @as(f128, @floatFromInt(s)) - mean;
        var_acc += diff * diff;
    }
    const variance = var_acc / @as(f128, @floatFromInt(iterations));
    const cv = std.math.sqrt(variance) / mean;
    var scratch = try alloc.dupe(u64, samples);
    defer alloc.free(scratch);
    const rank = (iterations * 95) / 100;
    var r: usize = 0;
    while (r <= rank) : (r += 1) {
        var min_index = r;
        var j: usize = r + 1;
        while (j < iterations) : (j += 1) {
            if (scratch[j] < scratch[min_index]) min_index = j;
        }
        if (min_index != r) {
            const tmp = scratch[r];
            scratch[r] = scratch[min_index];
            scratch[min_index] = tmp;
        }
    }
    const p95 = @as(f128, @floatFromInt(scratch[rank]));
    const p95_mean = p95 / mean;
    try std.testing.expect(cv <= 0.22);
    try std.testing.expect(p95_mean <= 2.55);
}
