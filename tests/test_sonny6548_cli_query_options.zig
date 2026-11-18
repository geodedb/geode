//! SONNY-6548 reproduction (intentionally red until fixed; KNOWN_TEST_ISSUES).
//!
//! `geode query` accepts options it does nothing with:
//!
//! 1. `--format <fmt>` takes any value (src/cli/main.zig, the `--format`
//!    branch stores it unchecked), and the renderer
//!    (src/cli/transport_response.zig renderTransportResponseWithStreams)
//!    handles only json, csv and table, then returns success: `--format txt`
//!    prints no result at all and exits 0. The help lists
//!    json|table|csv|dot|mermaid.
//! 2. An unknown option is skipped: the argument loop ends with a branch for
//!    non-option arguments and none for an unknown `-`-option, so a typo or
//!    an option of the deleted client (`--utf16-input`, `--dist-enable-raft`)
//!    exits 0. `geode serve` refuses one with exit 2 (SONNY-6442).
//! 3. `geode query --help` documents `--begin`, `--commit` and `--rollback`,
//!    and no parser branch reads them (the client that did, src/client/main.zig,
//!    was deleted in 78c9534e4): `--begin --rollback` commits the write.
//!
//! Spawns this build's geode (server and CLI).
const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");
const proto = @import("proto_test_util.zig");

const exe = geode_test_bin.geode_exe;

fn query(a: std.mem.Allocator, addr: []const u8, args: []const []const u8) !cli_test_util.CliResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.appendSlice(a, &.{ exe, "query" });
    try argv.appendSlice(a, args);
    return cli_test_util.runAgainstServer(a, addr, argv.items);
}

fn free(a: std.mem.Allocator, res: cli_test_util.CliResult) void {
    a.free(res.out);
    a.free(res.err);
}

test "SONNY-6548: geode query refuses an output format it does not render (usage error, exit 2)" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var server = try proto.spawnServerRandom(a, proto.TestEnv.standard());
    defer server.deinit();

    // Control: a documented format renders the row.
    const ok = try query(a, server.getAddr(), &.{ "RETURN 1 AS x", "--format", "json" });
    defer free(a, ok);
    try std.testing.expectEqual(@as(i32, 0), ok.code);
    try std.testing.expect(std.mem.indexOf(u8, ok.out, "\"rows\":[{\"x\":1}]") != null);

    for ([_][]const u8{ "txt", "text", "no-such-format" }) |fmt| {
        const res = try query(a, server.getAddr(), &.{ "RETURN 1 AS x", "--format", fmt });
        defer free(a, res);
        if (res.code != 2) std.debug.print("--format {s}: exit {d}, stdout {d} bytes: '{s}'\n", .{ fmt, res.code, res.out.len, res.out });
        try std.testing.expectEqual(@as(i32, 2), res.code);
    }
}

test "SONNY-6548: geode query refuses an unknown option (usage error, exit 2)" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var server = try proto.spawnServerRandom(a, proto.TestEnv.standard());
    defer server.deinit();

    for ([_][]const u8{ "--no-such-option", "--utf16-input", "--dist-enable-raft" }) |opt| {
        const res = try query(a, server.getAddr(), &.{ "RETURN 1 AS x", opt });
        defer free(a, res);
        if (res.code != 2) std.debug.print("{s}: exit {d}\n", .{ opt, res.code });
        try std.testing.expectEqual(@as(i32, 2), res.code);
    }
}

test "SONNY-6548: geode query --begin --rollback does not commit the write it documents rolling back" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var server = try proto.spawnServerRandom(a, proto.TestEnv.standard());
    defer server.deinit();

    // --help documents the transaction options.
    const help = try query(a, server.getAddr(), &.{"--help"});
    defer free(a, help);
    const help_text = if (help.out.len > 0) help.out else help.err;
    const documented = std.mem.indexOf(u8, help_text, "--rollback") != null;

    // Either the options work (the write is rolled back) or they are refused
    // (exit 2, nothing written); a write that commits is the bug.
    const write = try query(a, server.getAddr(), &.{ "CREATE (:Sonny6548Rollback {k: 1})", "--begin", "--rollback" });
    defer free(a, write);
    const count = try query(a, server.getAddr(), &.{"MATCH (n:Sonny6548Rollback) RETURN count(n) AS c"});
    defer free(a, count);
    try std.testing.expectEqual(@as(i32, 0), count.code);
    const committed = std.mem.indexOf(u8, count.out, "{\"c\":0}") == null;
    if (committed) std.debug.print("--begin --rollback exited {d} (help documents --rollback: {}); the node was committed: {s}\n", .{ write.code, documented, count.out });
    try std.testing.expect(!committed);
    try std.testing.expect(write.code == 0 or write.code == 2);
}
