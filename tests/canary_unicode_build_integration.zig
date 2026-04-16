const std = @import("std");
const geode = @import("geode");

// The build integration requirement ensures generated unicode tables are compiled in and reachable.
// We validate by calling a representative unicode function (nfcNormalize) on a known decomposed sequence
// and asserting it returns a normalized form using the shipped tables.
// CANARY: REQ=REQ-GQL-UNICODE-006; FEATURE="UnicodeBuildIntegration"; ASPECT=BuildStep; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_UNICODE_006_BuildIncludesTables; OWNER=unicode; UPDATED=2025-09-27

test "TestCANARY_REQ_GQL_UNICODE_006_BuildIncludesTables" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const input = "e\xCC\x81"; // e + COMBINING ACUTE
    const maybe_norm = geode.unicode.nfcNormalize(gpa.allocator(), input) catch |e| {
        std.debug.print("unexpected error {s}\n", .{@errorName(e)});
        return error.Unexpected; // surface failure so test fails
    };
    defer if (maybe_norm) |n| gpa.allocator().free(n);
    try std.testing.expect(maybe_norm != null);
    const norm = maybe_norm.?;
    // Should be single composed \xC3\xA9
    try std.testing.expect(std.mem.eql(u8, norm, "\xC3\xA9"));
}
