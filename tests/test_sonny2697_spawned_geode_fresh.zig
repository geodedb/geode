// SONNY-2697: a test step that spawns the geode server ran whatever
// `./zig-out/bin/geode` held: a binary left by an earlier build, a stub, or
// nothing at all. The path resolved against the runner's cwd, missed a
// `zig build -p <prefix>` install, and raced any other build writing
// zig-out. A step that spawns geode now gets the path of the executable this
// build emitted, through the `geode_test_bin` module, which only a step
// registered with build.zig's `spawnsBuiltGeode` can import.
//
// This test runs the binary every such step spawns and checks that it is this
// build's own executable: an absolute path outside the install prefix, which
// reports the version this build was configured with.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const geode_test_bin = @import("geode_test_bin");

test "SONNY-2697: the spawned geode is this build's executable, not the zig-out copy" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const exe = geode_test_bin.geode_exe;

    try std.testing.expect(std.fs.path.isAbsolute(exe));
    // The install copy is what a stale or concurrent build leaves behind.
    try std.testing.expect(std.mem.indexOf(u8, exe, "zig-out") == null);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const result = try std.process.run(allocator, threaded.io(), .{
        .argv = &.{ exe, "--version" },
        .stdout_limit = .limited(1 << 16),
        .stderr_limit = .limited(1 << 16),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    const reported = std.mem.trim(u8, result.stdout, " \r\n\t");
    const expected = "geode " ++ build_options.version;
    std.testing.expectEqualStrings(expected, reported) catch |err| {
        std.debug.print("spawned {s} reported '{s}', this build is '{s}'\n", .{ exe, reported, expected });
        return err;
    };
}
