const std = @import("std");
const util = @import("proto_test_util.zig");

// Forces a HashAgg spill by setting GEODE_SPILL_THRESHOLD_BYTES very low and running a GROUP query.
// Asserts PROFILE totals include hashagg_spills and hashagg_spill_reason.

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const addr = "127.0.0.1:17693";
    var server = try util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr },
        &.{ "GEODE_SPILL_THRESHOLD_BYTES=1" },
    );
    defer server.deinit();

    std.Thread.sleep(200 * std.time.ns_per_ms);

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    const profile_json = try client.executeProfileJson(allocator, "PROFILE RETURN 1 AS x, 2 AS y GROUP BY x");
    defer allocator.free(profile_json);

    if (std.mem.indexOf(u8, profile_json, "\"hashagg_spills\":") == null) return error.ExpectedSpillMetric;
    if (std.mem.indexOf(u8, profile_json, "\"hashagg_spill_reason\"") == null) return error.ExpectedSpillReason;
}
