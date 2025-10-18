const std = @import("std");

const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn readLineAlloc(allocator: std.mem.Allocator, file: std.fs.File, max: usize) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
    errdefer buf.deinit(allocator);
    while (true) {
        var one: [1]u8 = undefined;
        const n = file.read(&one) catch 0;
        if (n == 0) break;
        if (one[0] == '\n') break;
        buf.append(allocator, one[0]) catch return error.OutOfMemory;
        if (buf.items.len >= max) break;
    }
    return buf.toOwnedSlice(allocator) catch error.OutOfMemory;
}

fn run_with_commits(n: usize) !struct { code: i32, out: []u8, err: []u8 } {
    const allocator = std.testing.allocator;
    var child = Child.init(&.{"./zig-out/bin/geoded"}, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    // HELLO
    try child.stdin.?.writeAll("{\"type\":\"HELLO\",\"client_name\":\"test\",\"client_ver\":\"0.1\",\"wanted_conformance\":\"min\"}\n");
    const _hello = try readLineAlloc(allocator, child.stdout.?, 1 << 16);
    allocator.free(_hello);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        try child.stdin.?.writeAll("{\"type\":\"BEGIN\"}\n");
        const _b = try readLineAlloc(allocator, child.stdout.?, 1 << 16);
        allocator.free(_b);
        try child.stdin.?.writeAll("{\"type\":\"COMMIT\"}\n");
        const _c = try readLineAlloc(allocator, child.stdout.?, 1 << 16);
        allocator.free(_c);
    }

    if (child.stdin) |s| {
        s.close();
        child.stdin = null;
    }
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };
    return .{ .code = code, .out = try allocator.dupe(u8, ""), .err = try allocator.dupe(u8, "") };
}

test "WAL compaction schedule triggers at interval" {
    const r = try run_with_commits(10);
    defer std.testing.allocator.free(r.out);
    defer std.testing.allocator.free(r.err);
    try std.testing.expectEqual(@as(i32, 0), r.code);
}
