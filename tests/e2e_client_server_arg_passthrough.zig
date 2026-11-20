const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");
const util = @import("proto_test_util.zig");
const test_scratch = @import("test_scratch.zig");

// Simple evidence test: start server with explicit --data_dir and ensure query runs.
// CANARY: REQ=REQ-GQL-091; FEATURE="ServerDataDirFlag"; ASPECT=CliErgonomics; STATUS=TESTED; TEST=tests/e2e_client_server_arg_passthrough.zig; OWNER=client; UPDATED=2026-11-14
test "client: explicit server data_dir allows dataset query" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    util.testStart("explicit server data_dir allows dataset query");
    errdefer util.testFail();

    const allocator = std.testing.allocator;
    const exe = geode_test_bin.geode_exe;
    // SONNY-6548: this used ./data/varlen_determinism in the checkout, which
    // persisted between runs (an earlier run's admin credentials made the
    // query exit 3) and assumed a dataset nothing seeds. Use a fresh dir under
    // the test process's scratch root and seed the row it reads.
    var dir_buf: [256]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "{s}/argpass6548", .{try test_scratch.processRoot()});

    // Get random port
    const port = util.getRandomPort() catch |err| {
        util.progress("Port allocation failed: {}", .{err});
        util.testSkip();
        return;
    };
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);

    util.progress("Starting server on port {d} with custom data_dir...", .{port});
    var server = util.spawnServer(
        allocator,
        &.{ exe, "serve", "--listen", addr, "--data_dir", data_dir },
        util.TestEnv.standard(),
    ) catch |err| {
        util.progress("Server spawn failed: {}", .{err});
        util.testSkip();
        return;
    };
    defer server.deinit();

    // Wait for server readiness
    util.waitForServerReady(allocator, addr, 10000) catch |err| {
        util.progress("Server readiness timeout: {}", .{err});
        util.testSkip();
        return;
    };

    // The server runs on the --data_dir given (it holds the dir's lock).
    var lock_buf: [300]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buf, "{s}/.geode.lock", .{data_dir});
    try std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), lock_path, .{});

    const seed = try cli_test_util.runAgainstServer(allocator, addr, &.{ exe, "query", "CREATE (:Person {name: 'Ada'})", "--format", "json" });
    allocator.free(seed.out);
    allocator.free(seed.err);
    try std.testing.expectEqual(@as(i32, 0), seed.code);

    util.progress("Running query via CLI...", .{});
    const res = try cli_test_util.runAgainstServer(allocator, addr, &.{
        exe,
        "query",
        "MATCH (a:Person) RETURN a.name AS name ORDER BY name LIMIT 1",
        "--format",
        "json",
    });
    defer allocator.free(res.out);
    defer allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);

    util.progress("Validating query output...", .{});
    // Expect rows/columns payload with ordering metadata.
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"columns\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"rows\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"status_class\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"order_keys\":[\"name\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"rows\":[{\"name\":\"Ada\"}]") != null);

    util.testPass();
}
