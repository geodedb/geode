// CANARY: REQ=REQ-ENG-3921-DATA-DIR-LOCK-004; FEATURE="DataDirLock"; ASPECT=DefaultDataDirScoping; STATUS=IMPL; TEST=self; OWNER=storage; UPDATED=2026-08-31
// ENG-3921 residual R1: the DEFAULT data directory is the bare, shared,
// world-writable `/tmp`.
//
// src/graph_store.zig:794-802 (`getPersistenceFilePath`) resolves, in
// order: the in-process override, then $GEODE_DATA_DIR, then the string
// literal "/tmp" at :800.  That literal is now load-bearing for the
// ENG-3921 lock: src/server/main.zig:1116-1120 resolves the SAME chain to
// decide which directory to `flock`, so a default-configured `geode serve`
// takes an exclusive lock on `/tmp/.geode.lock` — a path every local user
// (and every unrelated program) can create, chmod, or hold.
//
// Two live consequences:
//
//   1. Cross-user denial of service.  If `/tmp/.geode.lock` already exists
//      owned by another uid with a restrictive mode (or is a directory, or
//      a dangling symlink), `DataDirLock.acquire` cannot open it and every
//      default-configured `geode serve` on the box fails closed with
//      error.DataDirLockUnavailable.  Nothing in geode created that file
//      and nothing in geode can clean it up.
//   2. Cross-user data sharing.  Two different users running
//      `geode serve` with no --data-dir silently target ONE store, and now
//      also contend for ONE lock: the second user's server is refused with
//      "data directory is locked by pid N" naming a pid they cannot see.
//
// RED-first status (verified at HEAD, this worktree): every assertion in
// the first three tests below fails because the resolved default is
// exactly "/tmp".
//
// What the fix must make true (asserted below):
//   * the resolved default is NOT a shared temp ROOT ("/tmp", "/var/tmp",
//     $TMPDIR itself);
//   * the resolved default is USER-SCOPED — it is either under $HOME /
//     $XDG_STATE_HOME, or it carries the current uid in its path (e.g.
//     "/tmp/geode-1000"), so two users never collide;
//   * the resolved default names geode, so the directory is unambiguously
//     geode-owned rather than a shared user directory.
//
// The two guard tests at the bottom pass at HEAD and must STAY passing:
// $GEODE_DATA_DIR and the in-process override must keep winning over the
// new default, and resolution must stay deterministic.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const geode = @import("geode");
const graph_store = geode.graph_store;

const env_var: [:0]const u8 = "GEODE_DATA_DIR";

// Zig 0.16 std.posix has no setenv/unsetenv; go straight to libc (same
// approach as tests/edge_rss_plateau_probe.zig).
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Shared temp ROOTS that must never be the default data dir: any process
/// or user on the box can plant `.geode.lock` in them.
const shared_temp_roots = [_][]const u8{
    "/tmp",
    "/tmp/",
    "/var/tmp",
    "/var/tmp/",
    "/dev/shm",
};

fn getenvOwned(allocator: std.mem.Allocator, name: [*:0]const u8) !?[]u8 {
    const raw = std.c.getenv(name) orelse return null;
    return try allocator.dupe(u8, std.mem.span(raw));
}

/// Resolve the default with no override and no $GEODE_DATA_DIR in the
/// environment, restoring the caller's environment afterwards.
fn restoreEnv(allocator: std.mem.Allocator, saved: ?[]const u8) void {
    if (saved) |s| {
        const z = allocator.dupeZ(u8, s) catch return;
        defer allocator.free(z);
        _ = setenv(env_var.ptr, z.ptr, 1);
    } else {
        _ = unsetenv(env_var.ptr);
    }
}

fn resolveDefault(allocator: std.mem.Allocator) ![]u8 {
    const saved = try getenvOwned(allocator, env_var);
    defer if (saved) |s| allocator.free(s);
    _ = unsetenv(env_var.ptr);
    defer restoreEnv(allocator, saved);

    return graph_store.getPersistenceFilePath(allocator);
}

fn uidText(buf: []u8) []const u8 {
    const uid: u64 = @intCast(std.c.getuid());
    return std.fmt.bufPrint(buf, "{d}", .{uid}) catch "";
}

// ---------------------------------------------------------------------
// R1 regression: the default must not be a shared temp root.
// ---------------------------------------------------------------------
test "default data dir is not a shared temp root (ENG-3921 R1 regression)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const resolved = try resolveDefault(testing.allocator);
    defer testing.allocator.free(resolved);

    for (shared_temp_roots) |root| {
        if (std.mem.eql(u8, resolved, root)) {
            std.debug.print(
                "\nENG-3921 R1: default data dir resolved to the SHARED temp root '{s}'.\n" ++
                    "  Every local user's default `geode serve` then locks '{s}/.geode.lock',\n" ++
                    "  which any of them can pre-create unopenable (-> DataDirLockUnavailable)\n" ++
                    "  or hold (-> 'data directory is locked by pid N').\n" ++
                    "  The default must be user-scoped.\n",
                .{ resolved, resolved },
            );
            return error.DefaultDataDirIsSharedTempRoot;
        }
    }
}

// ---------------------------------------------------------------------
// R1: the default must be per-user.
// ---------------------------------------------------------------------
test "default data dir is user-scoped (ENG-3921 R1)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const resolved = try resolveDefault(testing.allocator);
    defer testing.allocator.free(resolved);

    var uid_buf: [24]u8 = undefined;
    const uid = uidText(&uid_buf);

    // Accepted shapes (any one is enough):
    //   * under $XDG_STATE_HOME  (e.g. ~/.local/state/geode)
    //   * under $HOME            (e.g. ~/.geode)
    //   * carries the uid        (e.g. /tmp/geode-1000)
    var user_scoped = false;

    if (try getenvOwned(testing.allocator, "XDG_STATE_HOME")) |xdg| {
        defer testing.allocator.free(xdg);
        if (xdg.len > 0 and std.mem.startsWith(u8, resolved, xdg)) user_scoped = true;
    }
    if (try getenvOwned(testing.allocator, "HOME")) |home| {
        defer testing.allocator.free(home);
        if (home.len > 1 and std.mem.startsWith(u8, resolved, home)) user_scoped = true;
    }
    if (uid.len > 0 and std.mem.indexOf(u8, resolved, uid) != null) user_scoped = true;

    if (!user_scoped) {
        std.debug.print(
            "\nENG-3921 R1: default data dir '{s}' is not user-scoped.\n" ++
                "  Expected it under $XDG_STATE_HOME or $HOME, or carrying uid '{s}'\n" ++
                "  (e.g. $XDG_STATE_HOME/geode, or /tmp/geode-{s}).\n",
            .{ resolved, uid, uid },
        );
        return error.DefaultDataDirNotUserScoped;
    }
}

// ---------------------------------------------------------------------
// R1: the default must be a geode-owned directory, not a shared parent.
// ---------------------------------------------------------------------
test "default data dir names geode (ENG-3921 R1)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const resolved = try resolveDefault(testing.allocator);
    defer testing.allocator.free(resolved);

    if (std.mem.indexOf(u8, resolved, "geode") == null) {
        std.debug.print(
            "\nENG-3921 R1: default data dir '{s}' does not name geode.\n" ++
                "  The default must be a directory geode owns outright (it holds\n" ++
                "  '.geode.lock', the store, and the WAL), not a shared parent.\n",
            .{resolved},
        );
        return error.DefaultDataDirNotGeodeOwned;
    }
}

// ---------------------------------------------------------------------
// Guards: green at HEAD, must STAY green after the fix.
// ---------------------------------------------------------------------
test "GEODE_DATA_DIR still overrides the default (ENG-3921 R1 guard)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const saved = try getenvOwned(testing.allocator, env_var);
    defer if (saved) |s| testing.allocator.free(s);
    defer restoreEnv(testing.allocator, saved);

    _ = setenv(env_var.ptr, "/tmp/geode-eng3921-env-override", 1);
    const resolved = try graph_store.getPersistenceFilePath(testing.allocator);
    defer testing.allocator.free(resolved);
    try testing.expectEqualStrings("/tmp/geode-eng3921-env-override", resolved);
}

test "default data dir resolution is deterministic (ENG-3921 R1 guard)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const first = try resolveDefault(testing.allocator);
    defer testing.allocator.free(first);
    const second = try resolveDefault(testing.allocator);
    defer testing.allocator.free(second);

    try testing.expectEqualStrings(first, second);
}
