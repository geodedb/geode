const std = @import("std");

// E2E: ensure graceful shutdown flushes WAL (presence + non-zero size of wal segment file after BEGIN/COMMIT)

test "wal flush on shutdown" {
    const gpa = std.testing.allocator;
    const exe = "./zig-out/bin/geode";
    // temp directory for pages/WAL
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base_path = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(base_path);

    var env = try std.process.getEnvMap(gpa);
    defer env.deinit();
    // Provide path so server writes wal to this directory
    try env.put("GEODE_CHECKSUM_TEST_PATH", base_path);

    var child = std.process.Child.init(&[_][]const u8{exe}, gpa);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.env_map = &env;
    try child.spawn();
    if (child.stdin) |stdin| {
        try stdin.writeAll("{\"type\":\"HELLO\"}\n");
        try stdin.writeAll("{\"type\":\"BEGIN\"}\n");
        try stdin.writeAll("{\"type\":\"COMMIT\"}\n");
        // Close to trigger graceful shutdown flush.
        stdin.close();
        child.stdin = null;
    }
    _ = child.wait() catch {};

    // Look for wal_0.log (segment index initial) or similar naming; inspect directory entries.
    var it = tmp.dir.iterate();
    var found = false;
    while (try it.next()) |ent| {
        if (std.mem.startsWith(u8, ent.name, "wal_")) {
            const meta = try tmp.dir.statFile(ent.name);
            if (meta.size > 0) {
                found = true;
                break;
            }
        }
    }
    if (!found) return error.MissingWalFlush;
}
