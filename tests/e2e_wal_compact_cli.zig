const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

// End-to-end test invoking `geode storage verify` on GraphStore.
test "graphstore storage verify CLI" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    try env.put("GEODE_DATA_DIR", tmp.dir_path);

    var child = Child.init(&.{ "./zig-out/bin/geode", "storage", "verify", "--check", "graph_store" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.env_map = &env;
    try child.spawn();

    const out = try child.stdout.?.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(out);
    const err = try child.stderr.?.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(err);
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };
    try std.testing.expectEqual(@as(i32, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"graph_store_ok\":true") != null);
}
