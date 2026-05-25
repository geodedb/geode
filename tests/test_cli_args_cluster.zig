// CANARY: REQ=REQ-DIST-CLI-001; FEATURE="DistributedClusterCLI"; ASPECT=ArgParsing; STATUS=TESTED; TEST=tests/test_cli_args_cluster.zig; OWNER=core; UPDATED=2026-05-25
// Unit tests for the --cluster-port and --peers CLI flags introduced by
// the distributed cluster testing plan (Task A1). These exercise the new
// `parseArgsFromSlice` entry point so the parser body can be tested
// without invoking `/proc/self/cmdline` / argv recovery.

const std = @import("std");
const cli_args = @import("cli_args");

test "--cluster-port parses to u16" {
    const a = std.testing.allocator;
    const argv = [_][]const u8{ "geode", "--cluster-port", "4242" };
    const maybe_cfg = try cli_args.parseArgsFromSlice(a, &argv);
    try std.testing.expect(maybe_cfg != null);
    var cfg = maybe_cfg.?;
    defer cfg.deinit(a);
    try std.testing.expectEqual(@as(?u16, 4242), cfg.cluster_port);
}

test "--peers splits on comma and owns each entry" {
    const a = std.testing.allocator;
    const argv = [_][]const u8{ "geode", "--peers", "127.0.0.1:4242,127.0.0.1:4243" };
    const maybe_cfg = try cli_args.parseArgsFromSlice(a, &argv);
    try std.testing.expect(maybe_cfg != null);
    var cfg = maybe_cfg.?;
    defer cfg.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), cfg.peers.len);
    try std.testing.expectEqualStrings("127.0.0.1:4242", cfg.peers[0]);
    try std.testing.expectEqualStrings("127.0.0.1:4243", cfg.peers[1]);
}

test "--peers with empty entries skips them" {
    const a = std.testing.allocator;
    const argv = [_][]const u8{ "geode", "--peers", "127.0.0.1:4242,,127.0.0.1:4243," };
    const maybe_cfg = try cli_args.parseArgsFromSlice(a, &argv);
    try std.testing.expect(maybe_cfg != null);
    var cfg = maybe_cfg.?;
    defer cfg.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), cfg.peers.len);
}

test "cluster_port defaults to null and peers defaults to empty slice" {
    const a = std.testing.allocator;
    const argv = [_][]const u8{"geode"};
    const maybe_cfg = try cli_args.parseArgsFromSlice(a, &argv);
    try std.testing.expect(maybe_cfg != null);
    var cfg = maybe_cfg.?;
    defer cfg.deinit(a);
    try std.testing.expectEqual(@as(?u16, null), cfg.cluster_port);
    try std.testing.expectEqual(@as(usize, 0), cfg.peers.len);
}

test "--cluster-port with malformed value yields null" {
    const a = std.testing.allocator;
    const argv = [_][]const u8{ "geode", "--cluster-port", "not-a-number" };
    const maybe_cfg = try cli_args.parseArgsFromSlice(a, &argv);
    try std.testing.expect(maybe_cfg != null);
    var cfg = maybe_cfg.?;
    defer cfg.deinit(a);
    try std.testing.expectEqual(@as(?u16, null), cfg.cluster_port);
}
