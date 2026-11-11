// SONNY-2771 / SONNY-2474: `zig build gen-fuzz` (tools/gen_fuzz.zig), the
// scaffolder fuzz/README.md documents, stopped compiling on Zig 0.16
// (std.process.argsAlloc, std.fs.File and Dir.makePath were removed). These
// tests drive the tool's real argument parsing and file generation.
const std = @import("std");
const gen_fuzz = @import("gen_fuzz");

const io = std.testing.io;

test "parseArgs accepts --canary and an optional --module" {
    const opts = gen_fuzz.parseArgs(&.{ "--canary", "REQ-GQL-068" }).?;
    try std.testing.expectEqualStrings("REQ-GQL-068", opts.canary);
    try std.testing.expect(opts.module == null);

    const with_module = gen_fuzz.parseArgs(&.{ "--module", "src/x.zig", "--canary", "REQ-GQL-030" }).?;
    try std.testing.expectEqualStrings("REQ-GQL-030", with_module.canary);
    try std.testing.expectEqualStrings("src/x.zig", with_module.module.?);
}

test "parseArgs rejects a missing --canary, a flag without a value, and unknown arguments" {
    try std.testing.expect(gen_fuzz.parseArgs(&.{}) == null);
    try std.testing.expect(gen_fuzz.parseArgs(&.{ "--module", "src/x.zig" }) == null);
    try std.testing.expect(gen_fuzz.parseArgs(&.{"--canary"}) == null);
    try std.testing.expect(gen_fuzz.parseArgs(&.{ "--canary", "REQ-GQL-068", "--bogus" }) == null);
}

test "mapCanary maps the known requirements and falls back to the parser target" {
    try std.testing.expectEqualStrings("lfu_cache", gen_fuzz.mapCanary("REQ-GQL-068", null));
    try std.testing.expectEqualStrings("txn_sequence", gen_fuzz.mapCanary("REQ-GQL-030", null));
    try std.testing.expectEqualStrings("protocol_hello", gen_fuzz.mapCanary("REQ-GQL-005", null));
    try std.testing.expectEqualStrings("parser", gen_fuzz.mapCanary("REQ-UNKNOWN", null));
}

test "generate writes the scaffold and corpus dir once and never overwrites a target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectEqual(gen_fuzz.Outcome.created, try gen_fuzz.generate(std.testing.allocator, io, tmp.dir, "lfu_cache"));

    const written = try tmp.dir.readFileAlloc(io, "fuzz/targets/lfu_cache_fuzz.zig", std.testing.allocator, .limited(1 << 16));
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings(gen_fuzz.scaffold("lfu_cache"), written);
    try std.testing.expect((try tmp.dir.statFile(io, "fuzz/corpora/lfu_cache", .{})).kind == .directory);

    // A hand-edited target survives a second run.
    try tmp.dir.writeFile(io, .{ .sub_path = "fuzz/targets/lfu_cache_fuzz.zig", .data = "edited" });
    try std.testing.expectEqual(gen_fuzz.Outcome.exists, try gen_fuzz.generate(std.testing.allocator, io, tmp.dir, "lfu_cache"));
    const kept = try tmp.dir.readFileAlloc(io, "fuzz/targets/lfu_cache_fuzz.zig", std.testing.allocator, .limited(1 << 16));
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqualStrings("edited", kept);
}
