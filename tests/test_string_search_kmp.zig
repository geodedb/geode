const std = @import("std");
const geode = @import("../src/lib.zig");
const Kmp = geode.graph.string_search.kmp.Kmp;

// CANARY test referenced by KMP CANARY line
test "TestCANARY_REQ_GQL_070_KMP_basic_overlapping" {
    const allocator = std.testing.allocator;
    const pat = "aba";
    const text = "abacaba";
    const fail = try Kmp.buildFailure(allocator, pat);
    defer allocator.free(fail);
    const idx = Kmp.findFirst(text, pat, fail).?;
    try std.testing.expect(idx == 0);
    const all = try Kmp.findAll(allocator, text, pat, fail);
    defer allocator.free(all);
    try std.testing.expect(all.len == 2 and all[0] == 0 and all[1] == 4);
}

test "TestCANARY_REQ_GQL_070_KMP_no_match" {
    const allocator = std.testing.allocator;
    const pat = "xyz";
    const text = "aaaaab";
    const fail = try Kmp.buildFailure(allocator, pat);
    defer allocator.free(fail);
    try std.testing.expect(Kmp.findFirst(text, pat, fail) == null);
    const all = try Kmp.findAll(allocator, text, pat, fail);
    defer allocator.free(all);
    try std.testing.expect(all.len == 0);
}

test "TestCANARY_REQ_GQL_070_KMP_edge_cases" {
    const allocator = std.testing.allocator;
    const empty: []const u8 = "";
    const fail_empty = try Kmp.buildFailure(allocator, empty);
    defer allocator.free(fail_empty);
    try std.testing.expect(Kmp.findFirst("abc", empty, fail_empty) == 0);
    const pat = "a";
    const fail_a = try Kmp.buildFailure(allocator, pat);
    defer allocator.free(fail_a);
    const all = try Kmp.findAll(allocator, "aaaa", pat, fail_a);
    defer allocator.free(all);
    try std.testing.expect(all.len == 4 and all[0] == 0 and all[3] == 3);
}
