const std = @import("std");
const testing = std.testing;
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

// E2E test for CDC_CONTROL RESET_GUARDRAILS round trip.
// CANARY: REQ=REQ-GQL-042; FEATURE="CDCControlProtocol"; ASPECT=E2E; STATUS=TESTED; TEST=protocol_CDC_CONTROL_reset; OWNER=cdc; UPDATED=2025-09-20

fn runGeoded(gpa: *std.mem.Allocator, input: []const u8, env: [][]const u8) !struct { stdout: []u8, stderr: []u8, exit_code: u8 } {
    var proc = Child.init(&[_][]const u8{"./zig-out/bin/geode"}, gpa.*);
    proc.stdin_behavior = .Pipe;
    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Pipe;
    proc.env_map = try std.process.getEnvMap(gpa.*);
    defer proc.env_map.deinit();
    // apply env overrides
    for (env) |kv| {
        if (std.mem.indexOfScalar(u8, kv, '=')) |eq| {
            proc.env_map.put(kv[0..eq], kv[eq + 1 ..]) catch {};
        }
    }

    try proc.spawn();

    // Write input (multiple lines) then close stdin so server exits after processing
    if (proc.stdin) |stdin| {
        try stdin.writer().writeAll(input);
        stdin.close();
    }

    const stdout_bytes = try proc.stdout.?.reader().readAllAlloc(gpa.*, 1_000_000);
    defer gpa.free(stdout_bytes);
    const stderr_bytes = try proc.stderr.?.reader().readAllAlloc(gpa.*, 1_000_000);
    defer gpa.free(stderr_bytes);

    const term = try proc.wait();

    var code: u8 = 255;
    switch (term) {
        .Exited => |ec| {
            code = @intCast(ec);
        },
        .Signal => |_| {
            code = 254;
        },
        else => {
            code = 253;
        },
    }
    return .{ .stdout = try std.mem.dupe(gpa.*, u8, stdout_bytes), .stderr = try std.mem.dupe(gpa.*, u8, stderr_bytes), .exit_code = code };
}

fn findEpoch(line: []const u8) ?u64 {
    if (std.mem.indexOf(u8, line, "\"guardrail_epoch\":")) |idx| {
        const slice = line[idx + 19 ..];
        var it = std.mem.tokenizeAny(u8, slice, ",}\n ");
        if (it.next()) |tok| {
            return std.fmt.parseInt(u64, tok, 10) catch null;
        }
    }
    return null;
}

test "protocol: CDC control reset" {
    var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa_allocator.deinit());
    const gpa = gpa_allocator.allocator();

    const input =
        "{\"type\":\"CDC_DIAGNOSTICS\"}\n" ++
        "{\"type\":\"CDC_CONTROL\",\"action\":\"RESET_GUARDRAILS\"}\n" ++
        "{\"type\":\"CDC_DIAGNOSTICS\"}\n";

    const result = try runGeoded(&gpa, input, &[_][]const u8{"GEODE_CDC_ENABLE=1"});
    try testing.expectEqual(@as(u8, 0), result.exit_code);

    // Split stdout by lines and collect control + diagnostics
    var it = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    var first_diag: ?[]const u8 = null;
    var control_line: ?[]const u8 = null;
    var second_diag: ?[]const u8 = null;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, "\"type\":\"CDC_DIAGNOSTICS\"")) |_| {
            if (first_diag == null) first_diag = line else second_diag = line;
        } else if (std.mem.indexOf(u8, line, "\"type\":\"CDC_CONTROL\"")) |_| {
            control_line = line;
        }
    }

    try testing.expect(first_diag != null and second_diag != null and control_line != null);

    const epoch1 = findEpoch(first_diag.?) orelse return error.TestExpectedEpoch;
    const epoch2 = findEpoch(second_diag.?) orelse return error.TestExpectedEpoch;

    try testing.expect(epoch2 == epoch1 + 1);

    // Control line should show OK status
    try testing.expect(std.mem.indexOf(u8, control_line.?, "\"status\":\"OK\"") != null);
}
