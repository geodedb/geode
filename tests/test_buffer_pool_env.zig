// Buffer-pool size operator-configurability regression (read-path enablement).
//
// Operators running large graphs need to size the engine page cache to their
// available RAM. Without a runtime knob the pool is fixed at 1024 pages (8 MB
// at the default 8 KB page size), which is inadequate for graphs with millions
// of nodes and edges that benefit from keeping working sets in cache.
//
// This suite verifies that GEODE_BUFFER_POOL_PAGES controls the engine's
// buffer_pool_pages at adapter-init time:
//
//   (1) DEFAULT — env var unset → adapter.config.buffer_pool_pages == 1024
//   (2) EXPLICIT — GEODE_BUFFER_POOL_PAGES=3000 → buffer_pool_pages == 3000
//   (3) INVALID — GEODE_BUFFER_POOL_PAGES=not_a_number → falls back to 1024

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;

// libc setenv/unsetenv shims: std.posix.setenv was removed in Zig 0.16 and
// std.c does not surface these on all targets.  graph_store reads env vars via
// std.c.getenv, so we install them through the same libc layer.  The test
// module links libc (see build.zig).
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Build an absolute path string for a testing.TmpDir sub-path so that
/// initGlobalAdapter (which needs a real filesystem path) can use it.
fn tmpDirPath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const raw = @as(isize, @bitCast(rc));
    if (raw < 0) return error.GetCwdFailed;
    const cwd_len = @as(usize, @intCast(raw));
    var actual = cwd_len;
    while (actual > 0 and cwd_buf[actual - 1] == 0) : (actual -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual], &tmp.sub_path });
}

/// Tear down any live global adapter so each test starts from a clean slate.
fn resetAdapter() void {
    graph_store.deinitGlobalAdapter();
}

// ── (1) DEFAULT ──────────────────────────────────────────────────────────────

test "GEODE_BUFFER_POOL_PAGES unset: adapter uses default 1024 pages" {
    _ = unsetenv("GEODE_BUFFER_POOL_PAGES");
    resetAdapter();

    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDirPath(allocator, &tmp);
    defer allocator.free(path);

    const adapter = try graph_store.initGlobalAdapter(allocator, path);
    defer resetAdapter();

    try testing.expectEqual(@as(u32, 1024), adapter.config.buffer_pool_pages);
}

// ── (2) EXPLICIT ─────────────────────────────────────────────────────────────

test "GEODE_BUFFER_POOL_PAGES=3000: adapter uses 3000 pages" {
    if (setenv("GEODE_BUFFER_POOL_PAGES", "3000", 1) != 0) return error.SetEnvFailed;
    defer _ = unsetenv("GEODE_BUFFER_POOL_PAGES");
    resetAdapter();

    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDirPath(allocator, &tmp);
    defer allocator.free(path);

    const adapter = try graph_store.initGlobalAdapter(allocator, path);
    defer resetAdapter();

    try testing.expectEqual(@as(u32, 3000), adapter.config.buffer_pool_pages);
}

// ── (3) INVALID ──────────────────────────────────────────────────────────────

test "GEODE_BUFFER_POOL_PAGES=bad_value: adapter falls back to default 1024 pages" {
    if (setenv("GEODE_BUFFER_POOL_PAGES", "not_a_number", 1) != 0) return error.SetEnvFailed;
    defer _ = unsetenv("GEODE_BUFFER_POOL_PAGES");
    resetAdapter();

    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDirPath(allocator, &tmp);
    defer allocator.free(path);

    const adapter = try graph_store.initGlobalAdapter(allocator, path);
    defer resetAdapter();

    try testing.expectEqual(@as(u32, 1024), adapter.config.buffer_pool_pages);
}
