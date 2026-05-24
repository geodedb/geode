// Regression: server must raise its own RLIMIT_NOFILE soft limit at startup.
//
// Failure shape: geode-test-harness `make test` (geodetestlab-cli/specs/
// dsn_graph_binding.yml) fails 2/12 with ProcessFdQuotaExceeded on the
// "CREATE GRAPH allowed on bound session" case, cascading to "Verify
// other graph was created via DSN" and "Graph name with underscores is
// valid" with "Error: Failed to create graph".
//
// Root cause: systemd user@.service ships LimitNOFILESoft=1024. Shells
// that don't raise it (nushell, etc.) pass that cap to every child,
// including the spawned `geode serve`. Each CREATE GRAPH opens ~177 FDs
// (16 shards x ~11 files: nodes.store, adj_in.store, adj_out.store,
// props.store, var.store, free.store, labels.idx, props.idx, edges.idx,
// wal/, wal/graph.wal). Baseline ~184 FDs + 5 graphs * 177 = ~1069 -> EMFILE.
//
// Fix: standard server-software hygiene -- bump soft = hard at startup
// (matches nginx, postgres, redis). Implemented in src/server/fd_limit.zig
// and called from src/server/main.zig before any listener comes up.
//
// This test exercises the helper directly: lower soft to 256, call
// raiseSoftToHard(), assert it raised to >= 4096 (large enough for any
// realistic spec workload) and reported `raised = true`.
const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const geode = @import("geode");
const fd_limit = geode.fd_limit;

test "fd_limit: raiseSoftToHard bumps soft toward hard" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const posix = std.posix;
    const before = try posix.getrlimit(.NOFILE);
    // If the harness already runs us at soft == hard with a large hard,
    // there is nothing to raise; assert the no-op path and exit.
    if (before.cur == before.max) {
        const result = fd_limit.raiseSoftToHard();
        try testing.expect(!result.raised);
        try testing.expectEqual(before.cur, result.soft_after);
        return;
    }

    // Drop the soft limit to a value small enough to demonstrate the fix
    // matters (256 mirrors how the failure surfaces under ulimit -n 1024).
    // 256 is well above geode's baseline ~184 FDs but well below the
    // ~1069 FDs the suite spec exercises, so we cannot accidentally pass.
    const lowered = std.posix.rlimit{ .cur = 256, .max = before.max };
    try posix.setrlimit(.NOFILE, lowered);
    defer posix.setrlimit(.NOFILE, before) catch {};

    const result = fd_limit.raiseSoftToHard();
    try testing.expect(result.raised);
    try testing.expectEqual(@as(u64, 256), result.soft_before);
    try testing.expectEqual(result.hard, result.soft_after);
    try testing.expect(result.soft_after >= 4096);

    const after = try posix.getrlimit(.NOFILE);
    try testing.expectEqual(result.soft_after, after.cur);
}

test "fd_limit: raiseSoftToHard is a no-op when soft == hard" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const posix = std.posix;
    const before = try posix.getrlimit(.NOFILE);
    const equalized = std.posix.rlimit{ .cur = before.max, .max = before.max };
    try posix.setrlimit(.NOFILE, equalized);
    defer posix.setrlimit(.NOFILE, before) catch {};

    const result = fd_limit.raiseSoftToHard();
    try testing.expect(!result.raised);
    try testing.expectEqual(before.max, result.soft_before);
    try testing.expectEqual(before.max, result.soft_after);
}
