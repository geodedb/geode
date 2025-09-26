const std = @import("std");
const adv = @import("geode").fts_advanced_stub;

test "Advanced FTS disabled returns FeatureDisabled" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    try std.testing.expectError(error.FeatureDisabled, adv.phraseQuery(gpa.allocator(), "body", "sample phrase", 10));
}

test "Advanced FTS enabled phrase query returns hit" {
    adv.enableForTests();
    defer adv.disableForTests();
    const alloc = std.testing.allocator;
    const hits = try adv.phraseQuery(alloc, "body", "sample phrase", 10);
    defer alloc.free(hits);
    try std.testing.expect(hits.len == 1);
}

test "Advanced FTS enabled proximity query detects window" {
    adv.enableForTests();
    defer adv.disableForTests();
    const alloc = std.testing.allocator;
    var terms = [_][]const u8{ "geode", "queries" };
    const hits = try adv.proximityQuery(alloc, "body", terms[0..], 6);
    defer alloc.free(hits);
    try std.testing.expect(hits.len == 1);
}

test "Advanced FTS highlight returns fragment" {
    adv.enableForTests();
    defer adv.disableForTests();
    const alloc = std.testing.allocator;
    var terms = [_][]const u8{"fts"};
    const frags = try adv.highlight(alloc, "Example content for Geode FTS highlighting", terms[0..], 25);
    defer {
        for (frags) |f| _ = f; // slices owned by original content (no free)
        alloc.free(frags);
    }
    try std.testing.expect(frags.len >= 1);
}
// Skipping enabled highlight path due to environment mutation portability.
