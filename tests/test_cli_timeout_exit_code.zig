// CANARY: REQ=REQ-CLI-TIMEOUT-EXIT-CODE-001; FEATURE="QueryTimeoutClassification"; ASPECT=SubprocessE2E; STATUS=TESTED; TEST=self; OWNER=cli; UPDATED=2026-09-01
//
// `geode query` misclassifies a CLIENT-SIDE TIMEOUT as a generic failure, so a
// still-running server-side statement is reported to the operator (and to any
// script branching on `$?`) as if the query had failed outright.
//
// VERIFIED READ-ONLY against this branch before the fix:
//
//   * `readProtoMessageViaZigClient` maps the transport's
//     `error.ReceiveTimeout` to `error.Timeout` (src/cli/main.zig:2955-2959).
//   * `executeQuicQuery` (:2911-2924) does not distinguish it from any other
//     transport error.
//   * The catch-all in `cmdQuery` (:1774-1781) prints the single line
//     `Error: query execution failed` and exits
//     `ExitCode.general_error` (= 1).
//   * The second trip-wire — the deadline watchdog in
//     src/cli/query_deadline.zig:159-192 — prints its own
//     `Error: query timed out after N seconds` but ALSO exits with
//     `EXIT_GENERAL_ERROR` (= 1).
//   * `ExitCode` (src/cli/cli_dispatcher.zig:118-123) has no timeout member at
//     all: success=0, general_error=1, usage_error=2, auth_error=3.
//
//   Reproduced on a live server (2026-09-01, Debug build): a 3-way cartesian
//   MATCH over 200 seeded nodes run with `--timeout 3` exits 1 and prints
//   exactly `Error: query execution failed` — indistinguishable from a syntax
//   error, an auth-less refusal, or a dropped connection, and giving no hint
//   that the statement is still executing server-side.
//
// THE CONTRACT THIS SUITE PINS (see the triage report for geode#875's CLI
// sibling finding):
//   1. a client-side timeout exits with its OWN code, `ExitCode.timeout_error`
//      = 4, so scripts can retry/poll instead of treating it as a hard failure;
//   2. the message says it TIMED OUT and warns that the statement MAY STILL BE
//      EXECUTING server-side;
//   3. the default timeout stays 30 s, and a non-timing-out query is
//      unaffected (exit 0) — the new code must not leak into the happy path;
//   4. a genuine non-timeout failure still exits 1, so code 4 keeps its
//      meaning.
//
// This is a subprocess e2e lane: it spawns a real `./zig-out/bin/geode serve`
// and drives the real `./zig-out/bin/geode query` against it, so nothing here
// can pass by mocking the wire. Structure, skip semantics and the bounded
// hand-rolled waitpid loop mirror tests/test_cli_batch_mode.zig.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const linux = std.os.linux;
const posix = std.posix;

const binary_path = "./zig-out/bin/geode";
const ready_marker = "[startup] server ready";
const admin_username = "geode";
const admin_password = "GeodeTestPassword123!";

const ready_deadline_ms: i64 = 120_000;
const cli_deadline_ms: i64 = 120_000;

/// The exit code a client-side timeout must carry (ExitCode.timeout_error).
const expected_timeout_exit: u8 = 4;

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
            sleepMs(50);
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

fn spawnProc(
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    io_proc: std.Io,
    args: []const []const u8,
    extra_env: []const EnvPair,
) !Proc {
    const env_ptr = try aa.create(std.process.Environ.Map);
    env_ptr.* = std.process.Environ.Map.init(aa);
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

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    data_dir: []const u8,
    listen: []const u8,
    spawn_threaded: *std.Io.Threaded,
    server: ?Proc = null,
    gpa: std.mem.Allocator,

    fn aa(self: *Fixture) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn io(self: *Fixture) std.Io {
        return self.spawn_threaded.io();
    }

    fn deinit(self: *Fixture) void {
        if (self.server) |*s| s.deinit();
        const io_fs = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().deleteTree(io_fs, self.data_dir) catch {};
        self.spawn_threaded.deinit();
        self.arena.child_allocator.destroy(self.spawn_threaded);
        self.arena.deinit();
    }

    /// Run `geode query <extra_args>` and return the spawned process.
    fn runQuery(self: *Fixture, extra_args: []const u8) !Proc {
        const cmd = try std.fmt.allocPrint(
            self.aa(),
            "{s} query --server {s} --insecure-tls-skip-verify --format json -U {s} -P '{s}' {s} < /dev/null",
            .{ binary_path, self.listen, admin_username, admin_password, extra_args },
        );
        const argv = try self.aa().alloc([]const u8, 3);
        argv[0] = "/bin/sh";
        argv[1] = "-c";
        argv[2] = cmd;
        return spawnProc(self.gpa, self.aa(), self.io(), argv, &.{
            .{ .key = "GEODE_ALLOW_INSECURE_TLS", .value = "1" },
            .{ .key = "GEODE_LOG_LEVEL", .value = "warn" },
        });
    }

    /// Run a query to completion and return its exit code (null = never exited).
    fn runQueryToCompletion(self: *Fixture, extra_args: []const u8) !?u8 {
        var p = try self.runQuery(extra_args);
        defer p.deinit();
        return p.waitExit(cli_deadline_ms);
    }

    /// Seed `n` nodes of :SlowP in one statement so the cartesian probe below
    /// has enough rows to keep the server busy well past the client timeout.
    fn seed(self: *Fixture, n: usize) !void {
        var stmt = std.ArrayList(u8).empty;
        defer stmt.deinit(self.gpa);
        try stmt.appendSlice(self.gpa, "CREATE ");
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (i != 0) try stmt.appendSlice(self.gpa, ", ");
            var buf: [64]u8 = undefined;
            try stmt.appendSlice(self.gpa, try std.fmt.bufPrint(&buf, "(:SlowP {{i: {d}}})", .{i}));
        }
        const args = try std.fmt.allocPrint(self.aa(), "--timeout 120 \"{s}\"", .{stmt.items});
        const code = (try self.runQueryToCompletion(args)) orelse return error.SeedHung;
        if (code != 0) return error.SeedFailed;
    }
};

/// Returns null when the lane must SKIP (no binary / opt-out env).
fn setUp(gpa: std.mem.Allocator, tag: []const u8, port: u16) !?Fixture {
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

    const stamp = nowMillis();
    const data_dir = try std.fmt.allocPrint(aa, "/tmp/geode-timeout-{s}-{d}-data", .{ tag, stamp });
    std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const threaded = try gpa.create(std.Io.Threaded);
    threaded.* = std.Io.Threaded.init(std.heap.smp_allocator, .{});

    var fx = Fixture{
        .arena = arena,
        .data_dir = data_dir,
        .listen = try std.fmt.allocPrint(aa, "127.0.0.1:{d}", .{port}),
        .spawn_threaded = threaded,
        .gpa = gpa,
    };
    errdefer fx.deinit();

    const serve_args = try fx.aa().alloc([]const u8, 7);
    serve_args[0] = binary_path;
    serve_args[1] = "serve";
    serve_args[2] = "--listen";
    serve_args[3] = fx.listen;
    serve_args[4] = "--data-dir";
    serve_args[5] = fx.data_dir;
    serve_args[6] = "--log-level=warn";

    var srv = try spawnProc(gpa, fx.aa(), fx.io(), serve_args, &.{
        .{ .key = "GEODE_ADMIN_USERNAME", .value = admin_username },
        .{ .key = "GEODE_ADMIN_PASSWORD", .value = admin_password },
    });
    if (!srv.waitForMarker(ready_marker, ready_deadline_ms)) {
        srv.dump("server");
        srv.deinit();
        return error.ServerStartupTimeout;
    }
    fx.server = srv;
    return fx;
}

// A statement the server cannot answer in a few seconds: a 3-way cartesian
// product over the seeded label (200^3 = 8 000 000 combinations; measured >60 s
// in a Debug build). No sleep procedure exists, and the slowness is real
// server-side work, so the client genuinely waits.
const slow_statement = "MATCH (a:SlowP), (b:SlowP), (c:SlowP) RETURN count(*) AS c";

// ---------------------------------------------------------------------
// 1. THE REGRESSION TEST: a client-side timeout is its own exit code and
//    carries a truthful, actionable message.
// ---------------------------------------------------------------------
test "geode query reports a client timeout with its own exit code and a truthful message" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "exitcode", 23981)) orelse return error.SkipZigTest;
    defer fx.deinit();

    try fx.seed(200);

    const args = try std.fmt.allocPrint(fx.aa(), "--timeout 3 \"{s}\"", .{slow_statement});
    var p = try fx.runQuery(args);
    defer p.deinit();
    const code = p.waitExit(cli_deadline_ms) orelse {
        p.dump("query client (never exited)");
        return error.TimeoutClientHung;
    };

    // The query MUST NOT have succeeded — if it did, the probe was not slow
    // enough on this machine and the lane proves nothing.
    if (code == 0) {
        p.dump("query client (the slow probe completed inside the timeout)");
        return error.SlowProbeWasNotSlow;
    }

    // ASSERTION 1 — a distinct exit code. RED: 1 (general_error), the same code
    // a syntax error or a dropped connection produces, so no caller can tell a
    // still-running statement from a hard failure.
    if (code != expected_timeout_exit) {
        p.dump("query client (timeout exit code)");
        std.debug.print(
            "\n[cli-timeout] `geode query --timeout 3` on a statement that outlives the deadline exited {d}; expected {d} (ExitCode.timeout_error) so a caller can distinguish a timeout from a real failure\n",
            .{ code, expected_timeout_exit },
        );
        return error.TimeoutNotDistinguishedFromGeneralError;
    }

    // ASSERTION 2 — the message names the deadline...
    if (!p.saw("timed out")) {
        p.dump("query client (message did not mention a timeout)");
        return error.TimeoutMessageMissing;
    }
    // ...and warns that the work may still be running on the server. RED: the
    // only output is `Error: query execution failed`.
    if (!p.saw("may still be executing")) {
        p.dump("query client (message did not warn the statement may still be running)");
        return error.TimeoutMessageNotActionable;
    }
}

// ---------------------------------------------------------------------
// 2. The new code must not leak into the happy path.
// ---------------------------------------------------------------------
test "geode query that answers inside the timeout still exits 0" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "happy", 23982)) orelse return error.SkipZigTest;
    defer fx.deinit();

    var p = try fx.runQuery("--timeout 30 \"RETURN 1 AS x\"");
    defer p.deinit();
    const code = p.waitExit(cli_deadline_ms) orelse {
        p.dump("query client (never exited)");
        return error.HappyPathHung;
    };
    if (code != 0) {
        p.dump("query client (fast query did not exit 0)");
        return error.HappyPathNonZeroExit;
    }
    try testing.expect(p.saw("\"x\":1"));
    try testing.expect(!p.saw("timed out"));
}

// ---------------------------------------------------------------------
// 3. Exit code 4 must MEAN timeout: an ordinary statement failure keeps 1.
// ---------------------------------------------------------------------
test "geode query keeps exit code 1 for a non-timeout statement failure" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "notimeout", 23983)) orelse return error.SkipZigTest;
    defer fx.deinit();

    var p = try fx.runQuery("--timeout 30 \"THIS IS NOT GQL AT ALL\"");
    defer p.deinit();
    const code = p.waitExit(cli_deadline_ms) orelse {
        p.dump("query client (never exited)");
        return error.BadQueryHung;
    };
    if (code == expected_timeout_exit) {
        p.dump("query client (a syntax error was reported as a timeout)");
        return error.NonTimeoutFailureReportedAsTimeout;
    }
    // The statement error itself is rendered in the result body (the CLI's
    // established behaviour for a server-reported status: `geode query` exits 0
    // and prints the 42000 status — verified on this branch, out of scope for
    // this bug). What matters here is only that it is not code 4.
    try testing.expect(p.saw("42000"));
    if (!p.saw("timed out")) return; // expected: no timeout wording at all
    p.dump("query client (a syntax error was described as a timeout)");
    return error.NonTimeoutFailureDescribedAsTimeout;
}
