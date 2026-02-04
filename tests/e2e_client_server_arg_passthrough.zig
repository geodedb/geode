const std = @import("std");
const util = @import("proto_test_util.zig");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

// Simple evidence test: start server with explicit --data_dir and ensure query runs.
// CANARY: REQ=REQ-GQL-091; FEATURE="ServerDataDirFlag"; ASPECT=CliErgonomics; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_091_ServerDataDirFlag; OWNER=client; UPDATED=2025-09-24
test "client: explicit server data_dir allows dataset query" {
    const allocator = std.testing.allocator;
    const exe = "./zig-out/bin/geode";
    const addr = "127.0.0.1:17697";
    const data_dir = "./data/varlen_determinism";

    var server = try util.spawnServer(
        allocator,
        &.{ exe, "serve", "--listen", addr, "--data_dir", data_dir },
        &.{},
    );
    defer server.deinit();

    var child = Child.init(&.{
        exe,
        "query",
        "MATCH (a:Person) RETURN a.name AS name ORDER BY name LIMIT 1",
        "--server",
        addr,
        "--insecure",
        "--user",
        util.defaultUsername(),
        "--password",
        util.defaultPassword(),
        "--format",
        "json",
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(allocator, 4 << 20);
    defer allocator.free(out);
    const err = try child.stderr.?.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(err);
    const term = try child.wait();
    try std.testing.expect(term == .Exited and term.Exited == 0);
    // Expect rows/columns payload with ordering metadata.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"columns\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"rows\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"status_class\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"order_keys\":[\"name\"]") != null);
}
