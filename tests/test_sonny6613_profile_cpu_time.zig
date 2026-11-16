//! SONNY-6613 item 6: a version-2 PROFILE reports no CPU time it did not
//! measure.
//!
//! The planned read runtime times each operator by the wall clock only;
//! `buildProfilePayloadFromTrace` (src/server/profile_payload.zig) copied
//! that wall time into `cpu_time_ns`, so every operator claimed to have spent
//! all its wall time on the CPU. Per-thread CPU time is not measured per
//! operator, so the field is 0 (not measured), as in the version-1 payload
//! (SONNY-6596). Checked against a real `geode serve` over QUIC.
//!
//! CANARY: REQ=REQ-SONNY-6613-PROFILE-CPU-TIME; FEATURE="PROFILE"; ASPECT=NoCopiedCpuTime; STATUS=TESTED; TEST=tests/test_sonny6613_profile_cpu_time.zig; OWNER=engine; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const profile_util = @import("profile_test_util.zig");

test "SONNY-6613: a version-2 PROFILE does not copy wall time into cpu_time_ns" {
    const a = testing.allocator;
    const json = try profile_util.runProfile(a, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1", null);
    defer a.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 2), parsed.value.object.get("profile_version").?.integer);
    const ops = parsed.value.object.get("ops").?.array.items;
    try testing.expect(ops.len > 0);
    var timed: usize = 0;
    for (ops) |op| {
        const t = op.object.get("time_ns").?.integer;
        if (t > 0) timed += 1;
        const cpu = op.object.get("cpu_time_ns").?.integer;
        if (cpu != 0) {
            std.debug.print("{s}: cpu_time_ns {d} (time_ns {d}) was not measured\n", .{ op.object.get("op").?.string, cpu, t });
            return error.UnmeasuredCpuTime;
        }
    }
    try testing.expect(timed > 0);
}
