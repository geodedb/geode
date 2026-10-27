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
//
// ---------------------------------------------------------------------
// 2026-08-31: post-fix residuals (cases 4-6 below), RED at HEAD
// ---------------------------------------------------------------------
// The core lock landed, but triage of the shipped behaviour found three
// operator-facing holes.  Each case below fails at HEAD:
//
//   R2 (src/server/main.zig:1142-1148) — the DataDirLockUnavailable branch
//      only calls `log.err`, which the default log configuration does not
//      emit.  An unopenable `{data_dir}/.geode.lock` (mode 000, or owned by
//      another uid in the shared default /tmp) therefore kills startup with
//      nothing but a raw error trace, while the sibling DataDirLocked
//      branch at :1131-1134 prints a real operator message.
//
//   R3 (src/server/main.zig:1116-1120) — the lock is per-DIRECTORY, not
//      per-TREE.  `geode serve --data-dir <live_dir>/<subdir>` starts
//      cleanly INSIDE a running server's data directory and proceeds to
//      write into its tree.  Nothing detects the ancestor's lock.
//
//   R4 (src/server/data_dir_lock.zig:43,181-191) — the 15s default handoff
//      budget is spent in total silence, so a conflicting `geode serve`
//      looks hung for 15 seconds before it refuses.  The retry loop must
//      say what it is waiting for (or the refusal must land promptly).

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const linux = std.os.linux;
const posix = std.posix;

const binary_path = "./zig-out/bin/geode";
const ready_marker = "[startup] server ready";
const locked_marker = "data directory is locked by pid";
/// ENG-3921 R2 — operator-facing diagnostic for the
/// `error.DataDirLockUnavailable` branch (src/server/main.zig:1142-1148).
/// Today that branch only calls `log.err`, which the default log config does
/// not emit, so the operator gets a bare error trace.  Load-bearing string:
/// the fix must print this on stderr/stdout, alongside the offending path.
const unavailable_marker = "cannot acquire data directory lock";
/// ENG-3921 R3 — refusal wording shared with the sibling-directory case.
/// A nested `--data-dir` inside a LIVE server's tree must be refused naming
/// the incumbent, exactly as an identical `--data-dir` already is.
const locked_by_pid_marker = "locked by pid";
/// ENG-3921 R4 — the bounded handoff retry (data_dir_lock.zig:181-191) must
/// tell the operator it is waiting rather than sitting mute for the whole
/// 15s default budget.  Either this progress line or the final refusal has
/// to reach the operator early.
const waiting_marker = "waiting for data-dir lock";
const admin_password = "GeodeTestPassword123!";
/// 64 hex chars: a VALID GEODE_AUTH_HMAC_KEY, so `auth reseal` would
/// otherwise succeed.  Without this the CLI case could pass for the wrong
/// reason (non-zero exit from an unresolvable HMAC key).
const hmac_key_hex = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"; // gitleaks:allow — synthetic test HMAC key, not a real secret

const ready_deadline_ms: i64 = 120_000;
/// A refusal is a startup-path decision: it must land long before a real
/// server would finish booting.  60s is pure CI headroom.
const refusal_deadline_ms: i64 = 60_000;

fn getenvOwned(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;

/// root ignores file permission bits, so the "unopenable lockfile" fixture
/// cannot be built as uid 0.
fn runningAsRoot() bool {
    return std.c.geteuid() == 0;
}

fn nowMillis() i64 {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).toMilliseconds();
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

    /// Poll until ANY of `markers` shows up, returning the milliseconds
    /// elapsed since the call started (null if none arrived in time).  Used
    /// by the R4 latency case, which cares WHEN the operator first hears
    /// something, not just that they eventually do.
    fn waitForAnyMarkerMs(self: *Proc, markers: []const []const u8, deadline_ms: i64) ?i64 {
        const t0 = nowMillis();
        while (true) {
            self.drain();
            for (markers) |m| {
                if (self.saw(m)) return nowMillis() - t0;
            }
            if (nowMillis() - t0 >= deadline_ms) return null;
            sleepMs(50);
        }
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

// ---------------------------------------------------------------------
// 4. R2: an UNOPENABLE lockfile must refuse with an operator message.
// ---------------------------------------------------------------------
// src/server/main.zig:1142-1148 handles error.DataDirLockUnavailable with
// `log.err` only.  The default log configuration does not emit it, so the
// operator sees a bare Zig error trace and has no idea a lockfile is the
// problem.  Contrast :1131-1134 (DataDirLocked), which prints a real
// message via std.debug.print.
//
// Fixture: plant `{data_dir}/.geode.lock` mode 000.  That is precisely
// what a stray lockfile owned by another uid looks like in the shared
// default /tmp data dir (residual R1) -- and it is unfixable from inside
// geode, so the diagnostic is the whole remedy.
test "unopenable lockfile is refused with an operator-facing message (ENG-3921 R2)" {
    const gpa = testing.allocator;
    if (runningAsRoot()) return error.SkipZigTest;
    var fx = (try setUp(gpa, "lock-unavailable")) orelse return error.SkipZigTest;
    defer fx.deinit();

    const aa = fx.aa();
    const io_fs = std.Io.Threaded.global_single_threaded.io();

    const lock_path = try std.fmt.allocPrint(aa, "{s}/.geode.lock", .{fx.data_dir});
    const lock_path_z = try aa.dupeZ(u8, lock_path);
    {
        const f = try std.Io.Dir.cwd().createFile(io_fs, lock_path, .{});
        f.close(io_fs);
    }
    // mode 000: open(2) returns EACCES for a non-root uid.
    if (chmod(lock_path_z.ptr, 0o000) != 0) return error.ChmodFailed;

    var srv = try spawnGeode(gpa, aa, fx.io(), try serveArgs(aa, "127.0.0.1:23916", fx.data_dir), &.{
        .{ .key = "GEODE_ADMIN_PASSWORD", .value = admin_password },
        .{ .key = "GEODE_DATA_DIR_LOCK_TIMEOUT_MS", .value = "0" },
    });
    defer srv.deinit();

    const exit_code = srv.waitExit(refusal_deadline_ms) orelse {
        srv.dump("serve (never exited on an unopenable lockfile)");
        return error.ServerNeverExited;
    };

    if (srv.saw(ready_marker)) {
        srv.dump("serve (reached 'server ready' without holding the lock)");
        return error.ServerBecameReadyWithoutLock;
    }
    if (exit_code != 1) {
        srv.dump("serve (unexpected exit code on an unopenable lockfile)");
        std.debug.print(
            "\nENG-3921 R2: expected exit code 1, got {d}\n",
            .{exit_code},
        );
        return error.UnexpectedExitCode;
    }
    if (!srv.saw(unavailable_marker)) {
        srv.dump("serve (no operator-facing DataDirLockUnavailable diagnostic)");
        std.debug.print(
            "\nENG-3921 R2: stderr/stdout never contained \"{s}\".\n" ++
                "  src/server/main.zig:1142-1148 only calls log.err, which the default\n" ++
                "  log config does not emit -- the operator gets a raw error trace and\n" ++
                "  no hint that '{s}/.geode.lock' is unopenable.  The DataDirLocked\n" ++
                "  branch two lines up (:1131-1134) already prints an operator message;\n" ++
                "  this branch must too.\n",
            .{ unavailable_marker, fx.data_dir },
        );
        return error.MissingLockUnavailableDiagnostic;
    }
    // The message has to name the directory or it is not actionable.
    if (!srv.saw(fx.data_dir)) {
        srv.dump("serve (diagnostic does not name the data dir)");
        return error.LockUnavailableDiagnosticMissingPath;
    }
}

// ---------------------------------------------------------------------
// 5. R3: a NESTED data dir inside a live server's tree must be refused.
// ---------------------------------------------------------------------
// The lock covers one directory, not the tree beneath it
// (src/server/main.zig:1116-1120 locks exactly the resolved path), so a
// second server pointed at any subdirectory of a live data dir starts
// cleanly and writes inside the incumbent's tree -- the same split-brain
// ENG-3921 set out to eliminate, one path component down.  Real operator
// shape: `--data-dir /var/lib/geode` for A and `--data-dir
// /var/lib/geode/<graph-uuid>` (or .../data) for B.
//
// Scope: the CHILD-inside-live-tree direction only.  The inverse (serving
// a PARENT of a live data dir) is deliberately not asserted here -- an
// ancestor walk does not catch it, and no test should pin behaviour the
// planned fix will not deliver.
test "geode serve on a subdirectory of a live data dir is refused (ENG-3921 R3)" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "nested-dir")) orelse return error.SkipZigTest;
    defer fx.deinit();

    const aa = fx.aa();
    const io_fs = std.Io.Threaded.global_single_threaded.io();

    var a = try spawnGeode(gpa, aa, fx.io(), try serveArgs(aa, "127.0.0.1:23917", fx.data_dir), &.{
        .{ .key = "GEODE_ADMIN_PASSWORD", .value = admin_password },
    });
    defer a.deinit();

    if (!a.waitForMarker(ready_marker, ready_deadline_ms)) {
        a.dump("server A");
        return error.IncumbentStartupTimeout;
    }

    const nested = try std.fmt.allocPrint(aa, "{s}/nested", .{fx.data_dir});
    std.Io.Dir.cwd().createDirPath(io_fs, nested) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Distinct port again, so the ONLY contended resource is the tree.
    var b = try spawnGeode(gpa, aa, fx.io(), try serveArgs(aa, "127.0.0.1:23918", nested), &.{
        .{ .key = "GEODE_ADMIN_PASSWORD", .value = admin_password },
        .{ .key = "GEODE_DATA_DIR_LOCK_TIMEOUT_MS", .value = "0" },
    });
    defer b.deinit();

    const exit_code = b.waitExit(refusal_deadline_ms) orelse {
        b.dump("server B (still running INSIDE server A's live data dir tree)");
        std.debug.print(
            "\nENG-3921 R3: `serve --data-dir {s}` was accepted while a live server\n" ++
                "  holds the ancestor '{s}'.  The lock is per-directory, not per-tree.\n",
            .{ nested, fx.data_dir },
        );
        return error.NestedServerNeverExited;
    };

    if (exit_code == 0) {
        b.dump("server B (exited 0 -- nested data dir NOT refused)");
        return error.NestedServerAcceptedLiveTree;
    }
    if (b.saw(ready_marker)) {
        b.dump("server B (reached 'server ready' inside a locked tree)");
        std.debug.print(
            "\nENG-3921 R3: server B became ready on '{s}', nested inside live '{s}'.\n",
            .{ nested, fx.data_dir },
        );
        return error.NestedServerBecameReady;
    }
    if (!b.saw(locked_by_pid_marker)) {
        b.dump("server B (no ancestor-lock refusal diagnostic)");
        std.debug.print(
            "\nENG-3921 R3: refusal did not contain \"{s}\"; the operator must be told\n" ++
                "  which live process owns the enclosing data directory '{s}'.\n",
            .{ locked_by_pid_marker, fx.data_dir },
        );
        return error.MissingNestedLockDiagnostic;
    }

    // The incumbent must be untouched.
    a.drain();
    try testing.expect(a.waitExit(0) == null);
}

// ---------------------------------------------------------------------
// 6. R4: the handoff wait must not look like a hang.
// ---------------------------------------------------------------------
// data_dir_lock.zig:43 sets a 15s default budget and :181-191 burns it in
// a silent 250ms retry loop.  An operator who restarts into a still-live
// data dir sees a process that prints nothing for fifteen seconds and then
// dies -- indistinguishable from a hang, and long enough that supervisors
// and humans alike kill it first.
//
// This case does NOT pin the budget: it pins that the operator hears
// something EARLY.  Either a progress line ("waiting for data-dir lock
// ...") or the final refusal must reach stdio within 5s of spawn.
test "a conflicting geode serve reports progress within 5s (ENG-3921 R4)" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "silent-wait")) orelse return error.SkipZigTest;
    defer fx.deinit();

    const aa = fx.aa();

    var a = try spawnGeode(gpa, aa, fx.io(), try serveArgs(aa, "127.0.0.1:23919", fx.data_dir), &.{
        .{ .key = "GEODE_ADMIN_PASSWORD", .value = admin_password },
    });
    defer a.deinit();

    if (!a.waitForMarker(ready_marker, ready_deadline_ms)) {
        a.dump("server A");
        return error.IncumbentStartupTimeout;
    }

    // NOTE: GEODE_DATA_DIR_LOCK_TIMEOUT_MS is deliberately NOT set -- this
    // case is about the DEFAULT budget's user experience.
    var b = try spawnGeode(gpa, aa, fx.io(), try serveArgs(aa, "127.0.0.1:23920", fx.data_dir), &.{
        .{ .key = "GEODE_ADMIN_PASSWORD", .value = admin_password },
    });
    defer b.deinit();

    const markers = [_][]const u8{ waiting_marker, locked_marker };
    // 30s ceiling: generous enough for a loaded runner to still produce the
    // pre-fix 15s-late refusal, so the failure below reports the REAL
    // silence duration instead of a bare timeout.
    const elapsed_ms = b.waitForAnyMarkerMs(&markers, 30_000) orelse {
        b.dump("server B (silent for 30s on a contended data dir)");
        std.debug.print(
            "\nENG-3921 R4: server B said nothing about the data-dir lock for 30s.\n",
            .{},
        );
        return error.NoDataDirLockProgressOutput;
    };

    if (elapsed_ms > 5_000) {
        b.dump("server B (silent handoff wait)");
        std.debug.print(
            "\nENG-3921 R4: server B stayed silent for {d}ms before saying anything about\n" ++
                "  the data-dir lock (budget {d}ms, retry loop data_dir_lock.zig:181-191).\n" ++
                "  Operators read that as a hang.  The retry loop must emit \"{s}\"\n" ++
                "  (naming the holding pid) early, or refuse promptly.\n",
            .{ elapsed_ms, @as(u64, 15_000), waiting_marker },
        );
        return error.SilentDataDirLockWait;
    }
}
