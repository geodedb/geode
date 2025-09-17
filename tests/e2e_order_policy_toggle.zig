const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn run(args: []const []const u8, gql: []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const ally = std.testing.allocator;
    var child = Child.init(args, ally);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    // HELLO
    try child.stdin.?.writeAll("{\"type\":\"HELLO\",\"client_name\":\"test\",\"client_ver\":\"0.1\",\"wanted_conformance\":\"min\"}\n");
    _ = try child.stdout.?.readToEndAlloc(ally, 1 << 20);

    // RUN_GQL
    try child.stdin.?.writeAll("{\"type\":\"RUN_GQL\",\"text\":\"");
    try child.stdin.?.writeAll(gql);
    try child.stdin.?.writeAll("\"}\n");

    // Read first response (SCHEMA or ERROR)
    const resp = try child.stdout.?.readToEndAlloc(ally, 1 << 20);
    defer ally.free(resp);

    child.stdin.?.close();
    child.stdout.?.close();
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };
    return .{ .code = code, .out = resp, .err = try ally.dupe(u8, "") };
}

test "ORDER policy: expr forbidden by default" {
    const exe = "./zig-out/bin/geoded";
    const r = try run(&.{exe}, "RETURN a ORDER BY f(a)");
    defer std.testing.allocator.free(r.out);
    defer std.testing.allocator.free(r.err);
    // Parse JSON and assert ERROR with code IllegalOrderKey
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, r.out, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const obj = parsed.value.object;
    const result_v = obj.get("result") orelse return error.Unexpected;
    try std.testing.expect(result_v == .object);
    const typ = result_v.object.get("type") orelse return error.Unexpected;
    try std.testing.expect(typ == .string and std.mem.eql(u8, typ.string, "ERROR"));
    const codev = result_v.object.get("code") orelse return error.Unexpected;
    try std.testing.expect(codev == .string and std.mem.eql(u8, codev.string, "IllegalOrderKey"));
}

test "ORDER policy: expr allowed with --order-keys expr" {
    const exe = "./zig-out/bin/geoded";
    const r = try run(&.{ exe, "--order-keys", "expr" }, "RETURN a ORDER BY f(a)");
    defer std.testing.allocator.free(r.out);
    defer std.testing.allocator.free(r.err);
    // Parse JSON and assert SCHEMA
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, r.out, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const obj = parsed.value.object;
    const result_v = obj.get("result") orelse return error.Unexpected;
    try std.testing.expect(result_v == .object);
    const typ = result_v.object.get("type") orelse return error.Unexpected;
    try std.testing.expect(typ == .string and std.mem.eql(u8, typ.string, "SCHEMA"));
}
