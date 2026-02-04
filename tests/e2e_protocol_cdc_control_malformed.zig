const std = @import("std");
const testing = std.testing;
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=CDCControlProtocolMalformed; STATUS=TESTED; TEST=protocol_CDC_CONTROL_malformed_missing_action; OWNER=wire; UPDATED=2025-09-20

test "protocol: CDC control missing action treated as UNSUPPORTED" {
    var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa_allocator.deinit());
    const gpa = gpa_allocator.allocator();

    var proc = Child.init(&[_][]const u8{"./zig-out/bin/geode"}, gpa.*);
    proc.stdin_behavior = .Pipe;
    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Pipe;
    proc.env_map = try std.process.getEnvMap(gpa.*);
    defer proc.env_map.deinit();
    try proc.env_map.put("GEODE_CDC_ENABLE", "1");
    try proc.spawn();

    // Missing action field
    const input = "{\"type\":\"CDC_CONTROL\"}\n";
    if (proc.stdin) |stdin| {
        try stdin.writeAll(input);
        stdin.close();
    }

    const out = try proc.stdout.?.reader().readAllAlloc(gpa, 100_000);
    defer gpa.free(out);
    _ = try proc.wait();

    // Expect UNSUPPORTED status due to empty action mapping
    try testing.expect(std.mem.indexOf(u8, out, "\"status\":\"UNSUPPORTED\"") != null);
}
