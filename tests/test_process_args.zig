//! Regression cover for the portable process-argv holder
//! (`src/server/process_args.zig`).
//!
//! Background: Zig 0.16 removed `std.process.argsAlloc` and `std.os.argv`, so
//! the server used to read `/proc/self/cmdline` to recover argv. That file is
//! LINUX-ONLY — on macOS `openFileAbsolute("/proc/self/cmdline")` returns
//! FileNotFound, `parseArgs` returned `error.StdioUnavailable`, `geode serve`
//! died at startup, and the macOS `test-cluster-3node-subprocess` job hung
//! until the 2h CI ceiling. The portable holder captures argv from the
//! `std.process.Args` delivered to `main` and replays it on every platform.
//!
//! These tests exercise the holder directly via its test seams so they run
//! identically on Linux, macOS, and the BSDs.
//
// CANARY: REQ=REQ-CLI-PORTABLE-ARGV-001; FEATURE="PortableProcessArgv"; ASPECT=CrossPlatform; STATUS=TESTED; TEST=tests/test_process_args.zig; OWNER=cli; UPDATED=2026-06-12

const std = @import("std");
const testing = std.testing;
const cli_args = @import("cli_args");
// Reach the holder through cli_args so the test and parseArgs share one
// module instance (and one global). cli_args re-exports it as `process_args`.
const process_args = cli_args.process_args;

test "getArgs returns StdioUnavailable before capture" {
    process_args.resetForTesting();
    defer process_args.resetForTesting();
    try testing.expectError(error.StdioUnavailable, process_args.getArgs(testing.allocator));
}

test "getArgs replays the captured argv vector verbatim" {
    process_args.resetForTesting();
    defer process_args.resetForTesting();

    // Synthetic argv, exactly the shape std.process.Args.vector has on POSIX.
    const vector = [_][*:0]const u8{
        "geode",
        "serve",
        "--listen",
        "127.0.0.1:3141",
        "--data-dir",
        "/var/lib/geode",
        "--no-auth",
    };
    process_args.setForTesting(&vector);

    const args = try process_args.getArgs(testing.allocator);
    defer testing.allocator.free(args);

    try testing.expectEqual(@as(usize, 7), args.len);
    try testing.expectEqualStrings("geode", args[0]);
    try testing.expectEqualStrings("serve", args[1]);
    try testing.expectEqualStrings("--listen", args[2]);
    try testing.expectEqualStrings("127.0.0.1:3141", args[3]);
    try testing.expectEqualStrings("--data-dir", args[4]);
    try testing.expectEqualStrings("/var/lib/geode", args[5]);
    try testing.expectEqualStrings("--no-auth", args[6]);
}

test "getArgs reports StdioUnavailable for an empty captured vector" {
    process_args.resetForTesting();
    defer process_args.resetForTesting();

    const empty = [_][*:0]const u8{};
    process_args.setForTesting(&empty);
    try testing.expectError(error.StdioUnavailable, process_args.getArgs(testing.allocator));
}

test "init is idempotent (first capture wins)" {
    process_args.resetForTesting();
    defer process_args.resetForTesting();

    const first = [_][*:0]const u8{ "geode", "serve" };
    const second = [_][*:0]const u8{ "geode", "shell", "--extra" };

    process_args.init(.{ .vector = &first });
    process_args.init(.{ .vector = &second }); // must be ignored

    const args = try process_args.getArgs(testing.allocator);
    defer testing.allocator.free(args);

    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("geode", args[0]);
    try testing.expectEqualStrings("serve", args[1]);
}

test "parseArgsFromSlice consumes getArgs output (end-to-end shape)" {
    // Proves the portable holder feeds the real parser with the same slice
    // type the prior /proc/self/cmdline path produced ([]const []const u8).
    process_args.resetForTesting();
    defer process_args.resetForTesting();

    const vector = [_][*:0]const u8{ "geode", "serve", "--listen", "0.0.0.0:3141" };
    process_args.setForTesting(&vector);

    const args = try process_args.getArgs(testing.allocator);
    defer testing.allocator.free(args);

    var config = (try cli_args.parseArgsFromSlice(testing.allocator, args)).?;
    defer config.deinit(testing.allocator);

    try testing.expect(config.listen_quic != null);
    try testing.expectEqualStrings("0.0.0.0:3141", config.listen_quic.?);
}

test "parseArgsFromSlice refuses --no-auth in every build mode (SONNY-6329)" {
    // SONNY-6329: authentication cannot be disabled on a server; the flag
    // used to set a field nothing read (Debug) or exit (other modes). It is
    // refused through the same argv holder the server reads.
    process_args.resetForTesting();
    defer process_args.resetForTesting();
    const vector = [_][*:0]const u8{ "geode", "serve", "--listen", "0.0.0.0:3141", "--no-auth" };
    process_args.setForTesting(&vector);

    const args = try process_args.getArgs(testing.allocator);
    defer testing.allocator.free(args);

    try testing.expectError(error.NoAuthUnsupported, cli_args.parseArgsFromSlice(testing.allocator, args));
}
