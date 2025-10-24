const std = @import("std");
const testing = std.testing;
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

// CANARY: REQ=REQ-GQL-042; FEATURE="CDCControlProtocol"; ASPECT=E2ENoEngine; STATUS=TESTED; TEST=protocol_CDC_CONTROL_no_engine; OWNER=cdc; UPDATED=2025-09-20

test "protocol: CDC control when engine disabled" {
    var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa_allocator.deinit());
    const gpa = gpa_allocator.allocator();

    // Start without GEODE_CDC_ENABLE env var
    var proc = Child.init(&[_][]const u8{"./zig-out/bin/geoded"}, gpa.*);
    proc.stdin_behavior = .Pipe;
    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Pipe;
    proc.env_map = try std.process.getEnvMap(gpa.*); // no enable
    defer proc.env_map.deinit();
    try proc.spawn();

    const input = "{\"type\":\"CDC_CONTROL\",\"action\":\"RESET_GUARDRAILS\"}\n";
    if (proc.stdin) |stdin| {
        try stdin.writeAll(input);
        stdin.close();
    }

    const out = try proc.stdout.?.reader().readAllAlloc(gpa, 100_000);
    defer gpa.free(out);
    _ = try proc.wait();

    // Expect NO_ENGINE status
    try testing.expect(std.mem.indexOf(u8, out, "\"status\":\"NO_ENGINE\"") != null);
}
