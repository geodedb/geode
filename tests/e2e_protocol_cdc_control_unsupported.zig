const std = @import("std");
const testing = std.testing;
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

// CANARY: REQ=REQ-GQL-042; FEATURE="CDCControlProtocol"; ASPECT=E2EUnsupported; STATUS=TESTED; TEST=protocol_CDC_CONTROL_unsupported; OWNER=cdc; UPDATED=2025-09-20

test "protocol: CDC control unsupported action" {
    var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa_allocator.deinit());
    const gpa = gpa_allocator.allocator();

    var proc = Child.init(&[_][]const u8{"./zig-out/bin/geoded"}, gpa.*);
    proc.stdin_behavior = .Pipe;
    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Pipe;
    proc.env_map = try std.process.getEnvMap(gpa.*);
    defer proc.env_map.deinit();
    try proc.env_map.put("GEODE_CDC_ENABLE", "1");
    try proc.spawn();

    const input = "{\"type\":\"CDC_CONTROL\",\"action\":\"UNKNOWN_ACTION\"}\n";
    if (proc.stdin) |stdin| {
        try stdin.writeAll(input);
        stdin.close();
    }

    const out = try proc.stdout.?.reader().readAllAlloc(gpa, 100_000);
    defer gpa.free(out);
    _ = try proc.wait();

    // Expect UNSUPPORTED status
    try testing.expect(std.mem.indexOf(u8, out, "\"status\":\"UNSUPPORTED\"") != null);
}
