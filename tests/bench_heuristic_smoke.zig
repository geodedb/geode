const std = @import("std");

// Smoke run of bench executable to ensure it prints JSON line with expected keys.
// (Not asserting timing numbers to keep deterministic.)
test "bench: heuristic planning smoke" {
    var child = std.ChildProcess.init(&.{"./zig-out/bin/bench"}, std.testing.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    defer child.deinit();
    var stdout_stream = child.stdout.?.reader();
    var buf: [512]u8 = undefined;
    const n = try stdout_stream.read(&buf);
    const out = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, out, "heuristic_planning") != null);
    _ = try child.wait();
}
