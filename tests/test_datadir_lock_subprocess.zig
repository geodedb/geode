// CANARY: REQ=REQ-ENG-3921-DATA-DIR-LOCK-003; FEATURE="DataDirLock"; ASPECT=SubprocessExclusion; STATUS=IMPL; TEST=self; OWNER=storage; UPDATED=2026-08-29
// ENG-3921 end-to-end reproduction: NOTHING stops two `geode serve`
// processes from opening the same --data-dir.
//
// Live-verified at HEAD (2026-08-29, this worktree, binary
// ./zig-out/bin/geode):
//   * server A: serve --listen 127.0.0.1:23901 --data-dir D  -> "[startup] server ready"
//   * server B: serve --listen 127.0.0.1:23902 --data-dir D  -> "[startup] server ready"
//     (both live on ONE on-disk store: split-brain, last snapshot wins =
//     silent data loss)
//   * `geode auth reseal --data-dir D` while A is live ->
//     "HMAC chain resealed successfully (2 records)." exit 0
//     (an offline CLI writer rewrote a running server's __geode_security
//     graph out from under it)
//
// This is the e2e lane.  The lock primitive itself is unit-tested in
// tests/test_data_dir_lock.zig.
//
// What the fix must make true (asserted below):
//   1. A second `geode serve` on a data dir already held by a live server
//      exits NON-ZERO with "data directory is locked by pid <N>" and never
//      prints "[startup] server ready".
//   2. A SIGKILLed server leaves NO stale lock: a fresh serve on the same
//      dir starts normally (flock is released by the kernel on process
//      death; there is no TTL/manual-cleanup step for an operator to get
//      wrong).
//   3. `geode auth reseal --data-dir <live dir>` is refused the same way
//      (the offline CLI writers go through the same gate).
//
// Env contract used here:
//   GEODE_DATA_DIR_LOCK_TIMEOUT_MS  bounded handoff-retry budget in ms.
//   0 = refuse immediately.  The test pins 0 so the refusal path is
//   deterministic and fast (a restart handoff wants a non-zero default,
//   which is NOT what these cases exercise).
//
// Skip semantics mirror tests/test_cluster_3node_subprocess.zig: skip when
// the binary is missing or $GEODE_SKIP_SUBPROC_CLUSTER is set.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const linux = std.os.linux;
const posix = std.posix;

const binary_path = "./zig-out/bin/geode";
const ready_marker = "[startup] server ready";
const locked_marker = "data directory is locked by pid";
const admin_password = "GeodeTestPassword123!";
/// 64 hex chars: a VALID GEODE_AUTH_HMAC_KEY, so `auth reseal` would
/// otherwise succeed.  Without this the CLI case could pass for the wrong
/// reason (non-zero exit from an unresolvable HMAC key).
const hmac_key_hex = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90";

const ready_deadline_ms: i64 = 120_000;
/// A refusal is a startup-path decision: it must land long before a real
/// server would finish booting.  60s is pure CI headroom.
const refusal_deadline_ms: i64 = 60_000;

fn getenvOwned(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

fn nowMillis() i64 {
    var ts: posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    var req = linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    var rem: linux.timespec = undefined;
    _ = linux.nanosleep(&req, &rem);
}

fn setNonBlocking(file: std.Io.File) void {
    const fd = file.handle;
    const flags = linux.fcntl(fd, posix.F.GETFL, 0);
    if (@as(isize, @bitCast(flags)) < 0) return;
    const new_flags = flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
    _ = linux.fcntl(fd, posix.F.SETFL, new_flags);
}

/// Spawned child with piped stdio and an owned transcript.  We drive
/// waitpid ourselves (instead of Child.wait) so every wait is bounded by a
/// deadline — a pre-fix second server never exits on its own.
const Proc = struct {
    child: std.process.Child,
    transcript: std.ArrayList(u8) = .empty,
    reaped: bool = false,
    gpa: std.mem.Allocator,

    fn drain(self: *Proc) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        var buf: [8192]u8 = undefined;
        inline for (.{ self.child.stderr, self.child.stdout }) |maybe_f| {
            if (maybe_f) |f| {
                while (true) {
                    const n = f.readStreaming(io, &.{&buf}) catch break;
                    if (n == 0) break;
                    self.transcript.appendSlice(self.gpa, buf[0..n]) catch break;
                }
            }
        }
    }

    fn saw(self: *Proc, marker: []const u8) bool {
        return std.mem.indexOf(u8, self.transcript.items, marker) != null;
    }

    /// Poll until `marker` shows up in the transcript or the deadline lapses.
    fn waitForMarker(self: *Proc, marker: []const u8, deadline_ms: i64) bool {
        const t0 = nowMillis();
        while (nowMillis() - t0 < deadline_ms) {
            self.drain();
            if (self.saw(marker)) return true;
            sleepMs(100);
        }
        self.drain();
        return self.saw(marker);
    }

    /// Poll waitpid(WNOHANG) until the child exits or the deadline lapses,
    /// scraping output the whole time so a chatty child never wedges on a
    /// full pipe.  Returns the exit code, or null if it is still running.
    fn waitExit(self: *Proc, deadline_ms: i64) ?u8 {
        const pid = self.child.id orelse return null;
        const t0 = nowMillis();
        while (nowMillis() - t0 < deadline_ms) {
            self.drain();
            var status: u32 = 0;
            const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
            const rc_signed: isize = @bitCast(rc);
            if (rc_signed == pid) {
                self.reaped = true;
                self.drain();
                return if (linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else 255;
            }
            if (rc_signed < 0) {
                self.reaped = true;
                return 255;
            }
            sleepMs(100);
        }
        self.drain();
        return null;
    }

    fn killWith(self: *Proc, sig: posix.SIG) void {
        if (self.reaped) return;
        const pid = self.child.id orelse return;
        posix.kill(pid, sig) catch {};
        var status: u32 = 0;
        _ = linux.waitpid(pid, &status, 0);
        self.reaped = true;
    }

    fn deinit(self: *Proc) void {
        self.killWith(.KILL);
        self.transcript.deinit(self.gpa);
    }

    fn dump(self: *Proc, label: []const u8) void {
        const max_dump: usize = 8 * 1024;
        const items = self.transcript.items;
        const slice = if (items.len > max_dump) items[items.len - max_dump ..] else items;
        std.debug.print("\n--- {s} transcript (tail) ---\n{s}\n--- end ---\n", .{ label, slice });
    }
};

const EnvPair = struct { key: []const u8, value: []const u8 };

fn spawnGeode(
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    io_proc: std.Io,
    args: []const []const u8,
    extra_env: []const EnvPair,
) !Proc {
    const env_ptr = try aa.create(std.process.Environ.Map);
    env_ptr.* = std.process.Environ.Map.init(aa);
    // PATH/HOME/LD_LIBRARY_PATH so cert_gen can find openssl at startup.
    if (getenvOwned("PATH")) |p| try env_ptr.put("PATH", p);
    if (getenvOwned("HOME")) |p| try env_ptr.put("HOME", p);
    if (getenvOwned("LD_LIBRARY_PATH")) |p| try env_ptr.put("LD_LIBRARY_PATH", p);
    for (extra_env) |kv| try env_ptr.put(kv.key, kv.value);

    const child = try std.process.spawn(io_proc, .{
        .argv = args,
        .environ_map = env_ptr,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    const p = Proc{ .child = child, .gpa = gpa };
    if (p.child.stderr) |f| setNonBlocking(f);
    if (p.child.stdout) |f| setNonBlocking(f);
    return p;
}

fn serveArgs(aa: std.mem.Allocator, listen: []const u8, data_dir: []const u8) ![]const []const u8 {
    const args = try aa.alloc([]const u8, 7);
    args[0] = binary_path;
    args[1] = "serve";
    args[2] = "--listen";
    args[3] = listen;
    args[4] = "--data-dir";
    args[5] = data_dir;
    args[6] = "--log-level=info";
    return args;
}

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    data_dir: []const u8,
    spawn_threaded: *std.Io.Threaded,

    fn aa(self: *Fixture) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn io(self: *Fixture) std.Io {
        return self.spawn_threaded.io();
    }

    fn deinit(self: *Fixture) void {
        const io_fs = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().deleteTree(io_fs, self.data_dir) catch {};
        self.spawn_threaded.deinit();
        self.arena.child_allocator.destroy(self.spawn_threaded);
        self.arena.deinit();
    }
};

/// Returns null when the lane must SKIP (no binary / opt-out env).
fn setUp(gpa: std.mem.Allocator, tag: []const u8) !?Fixture {
    if (comptime builtin.os.tag != .linux) return null;
    if (getenvOwned("GEODE_SKIP_SUBPROC_CLUSTER") != null) return null;

    const io_fs = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io_fs, binary_path, .{}) catch {
        std.debug.print(
            "geode binary missing at {s}; run `zig build` first to populate zig-out/bin\n",
            .{binary_path},
        );
        return null;
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const data_dir = try std.fmt.allocPrint(aa, "/tmp/geode-eng3921-{s}-{d}", .{ tag, nowMillis() });
    std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // std.process.spawn needs an Io backed by a real allocator (the
    // process-global single-threaded Io ships with .allocator = .failing).
    const threaded = try gpa.create(std.Io.Threaded);
    threaded.* = std.Io.Threaded.init(std.heap.smp_allocator, .{});

    return Fixture{ .arena = arena, .data_dir = data_dir, .spawn_threaded = threaded };
}

// ---------------------------------------------------------------------
// 1. THE REGRESSION TEST: two `geode serve` on one data dir.
// ---------------------------------------------------------------------
test "second geode serve on a live data dir is refused (ENG-3921 regression)" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "two-serve")) orelse return error.SkipZigTest;
    defer fx.deinit();

    // Server A: the incumbent.  Distinct listen port from server B so the
    // ONLY thing the two contend over is the data directory (a shared port
    // would make the test pass for the wrong reason).
    var a = try spawnGeode(gpa, fx.aa(), fx.io(), try serveArgs(fx.aa(), "127.0.0.1:23911", fx.data_dir), &.{
        .{ .key = "GEODE_ADMIN_PASSWORD", .value = admin_password },
    });
    defer a.deinit();

    if (!a.waitForMarker(ready_marker, ready_deadline_ms)) {
        a.dump("server A");
        return error.IncumbentStartupTimeout;
    }

    // Server B: same data dir, different port, retry budget 0.
    var b = try spawnGeode(gpa, fx.aa(), fx.io(), try serveArgs(fx.aa(), "127.0.0.1:23912", fx.data_dir), &.{
        .{ .key = "GEODE_ADMIN_PASSWORD", .value = admin_password },
        .{ .key = "GEODE_DATA_DIR_LOCK_TIMEOUT_MS", .value = "0" },
    });
    defer b.deinit();

    const exit_code = b.waitExit(refusal_deadline_ms) orelse {
        b.dump("server B (still running -- data dir NOT locked)");
        return error.SecondServerNeverExited;
    };

    if (exit_code == 0) {
        b.dump("server B (exited 0 -- data dir NOT locked)");
        return error.SecondServerAcceptedLiveDataDir;
    }
    if (b.saw(ready_marker)) {
        b.dump("server B (reached 'server ready' on a locked data dir)");
        return error.SecondServerBecameReady;
    }
    if (!b.saw(locked_marker)) {
        b.dump("server B (no lock-refusal diagnostic)");
        return error.MissingLockedDiagnostic;
    }

    // Incumbent must be untouched by the refusal.
    a.drain();
    try testing.expect(a.waitExit(0) == null);
}

// ---------------------------------------------------------------------
// 2. Stale-lock guard: a SIGKILLed holder must not wedge the data dir.
// ---------------------------------------------------------------------
test "SIGKILLed server leaves no stale data dir lock (ENG-3921)" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "stale-lock")) orelse return error.SkipZigTest;
    defer fx.deinit();

    var a = try spawnGeode(gpa, fx.aa(), fx.io(), try serveArgs(fx.aa(), "127.0.0.1:23913", fx.data_dir), &.{
        .{ .key = "GEODE_ADMIN_PASSWORD", .value = admin_password },
    });
    defer a.deinit();

    if (!a.waitForMarker(ready_marker, ready_deadline_ms)) {
        a.dump("server A");
        return error.IncumbentStartupTimeout;
    }

    // No graceful shutdown: the holder dies without running any cleanup.
    a.killWith(.KILL);

    var b = try spawnGeode(gpa, fx.aa(), fx.io(), try serveArgs(fx.aa(), "127.0.0.1:23914", fx.data_dir), &.{
        .{ .key = "GEODE_ADMIN_PASSWORD", .value = admin_password },
        .{ .key = "GEODE_DATA_DIR_LOCK_TIMEOUT_MS", .value = "0" },
    });
    defer b.deinit();

    if (!b.waitForMarker(ready_marker, ready_deadline_ms)) {
        b.dump("server B (blocked by a stale lock after SIGKILL)");
        return error.StaleLockBlockedRestart;
    }
    try testing.expect(!b.saw(locked_marker));
}

// ---------------------------------------------------------------------
// 3. Offline CLI writer against a live data dir.
// ---------------------------------------------------------------------
test "geode auth reseal against a live data dir is refused (ENG-3921)" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "cli-reseal")) orelse return error.SkipZigTest;
    defer fx.deinit();

    var a = try spawnGeode(gpa, fx.aa(), fx.io(), try serveArgs(fx.aa(), "127.0.0.1:23915", fx.data_dir), &.{
        .{ .key = "GEODE_ADMIN_PASSWORD", .value = admin_password },
    });
    defer a.deinit();

    if (!a.waitForMarker(ready_marker, ready_deadline_ms)) {
        a.dump("server A");
        return error.IncumbentStartupTimeout;
    }

    const aa = fx.aa();
    // `geode auth reseal --data-dir <path>` (two-token form: the CLI
    // parser expects a separate value token).
    const cli_argv = try aa.alloc([]const u8, 5);
    cli_argv[0] = binary_path;
    cli_argv[1] = "auth";
    cli_argv[2] = "reseal";
    cli_argv[3] = "--data-dir";
    cli_argv[4] = fx.data_dir;

    var cli = try spawnGeode(gpa, aa, fx.io(), cli_argv, &.{
        .{ .key = "GEODE_AUTH_HMAC_KEY", .value = hmac_key_hex },
        .{ .key = "GEODE_DATA_DIR_LOCK_TIMEOUT_MS", .value = "0" },
    });
    defer cli.deinit();

    const exit_code = cli.waitExit(refusal_deadline_ms) orelse {
        cli.dump("auth reseal (never exited)");
        return error.CliNeverExited;
    };

    if (exit_code == 0) {
        cli.dump("auth reseal (exited 0 against a LIVE data dir)");
        return error.CliMutatedLiveDataDir;
    }
    if (cli.saw("HMAC chain resealed successfully")) {
        cli.dump("auth reseal (resealed a LIVE server's __geode_security graph)");
        return error.CliResealedLiveChain;
    }
    if (!cli.saw(locked_marker)) {
        cli.dump("auth reseal (no lock-refusal diagnostic)");
        return error.MissingLockedDiagnostic;
    }
}
