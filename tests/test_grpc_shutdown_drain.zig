// SIGTERM while a gRPC query is in flight = use-after-free panic. The shutdown
// path frees the global store while detached gRPC handler threads are still
// reading it, because gRPC connections are invisible to the connection drain.
//
// VERIFIED READ-ONLY against this branch, then reproduced live:
//
//   * `src/server/main.zig:2346` — `deinitGlobalStore()` runs in a `defer`
//     registered BEFORE the gRPC teardown at :2058, so LIFO ordering tears the
//     STORE down FIRST and the gRPC server SECOND.
//   * `src/transport/grpc_server.zig:625` — `GeodeGrpcServer` exposes no
//     `requestShutdown` / quiesce API of any kind. There is nothing for the
//     shutdown path to call and nothing for it to wait on.
//   * The vendored accept loop
//     (`zig-pkg/grpc_zig-0.1.8-.../src/server.zig:328`, `connectionThread`)
//     is a `while (true)` that DETACHES a thread per connection, so an
//     in-flight handler outlives every geode-side teardown by construction.
//   * The drain that DOES exist is QUIC-only. With a gRPC query mid-execution
//     the shutdown log still reads `draining 0 connections` — the handler is
//     not counted, not waited for, and not cancelled.
//
//   The QUIC path is correct here: it drains, and it does not panic. That
//   asymmetry is the whole bug, and test 3 below pins it as the reference.
//
// MEASURED RED SIGNATURE (live, this branch — real `geode serve` with
// `--listen-grpc`, 200 :SlowP nodes, a 3-way cartesian gRPC query, `kill -TERM`
// 6 s in):
//
//   [shutdown] signal received, flushing data and stopping...
//   [shutdown] draining 0 connections (timeout 30000ms, ...)   <-- not counted
//   [shutdown] connection drain complete (0ms)
//   [shutdown] data flush complete
//   thread 2071527 panic: incorrect alignment
//     std/hash_map.zig:784  header()
//     std/hash_map.zig:798  capacity()
//     ... graph_storage_adapter.zig  (self.engines.get on a freed adapter)
//     ... planned_read_runtime.zig   materializeNode
//     src/transport/grpc_server.zig:2567  handleExecute
//     src/transport/grpc_server.zig:953   handleExecuteStreaming
//     grpc_zig .../server.zig:471         handleConnection
//     grpc_zig .../server.zig:328         connectionThread
//
//   The CLIENT meanwhile exited 0 with `"rows":[]` — a FALSE SUCCESS. A query
//   that never ran reported as an empty result set. Test 2 pins that.
//
//   Baseline for comparison (measured): SIGTERM with NO in-flight work exits 0
//   with zero panics.
//
// The slow statement is a real 3-way cartesian product over a seeded label —
// genuine server-side work, no sleep procedure, no fault injection. The payload
// is deliberately SMALL (a `count(*)`), so this lane is independent of the
// >16 KiB gRPC framing defect covered by tests/test_grpc_large_payload.zig.
//
// CANARY: REQ=REQ-TRANSPORT-GRPC-SHUTDOWN-001; FEATURE="GrpcServerLifecycle"; ASPECT=InFlightHandlerDrain; STATUS=TESTED; TEST=tests/test_grpc_shutdown_drain.zig; OWNER=transport; UPDATED=2026-09-01
// CANARY: REQ=REQ-TRANSPORT-GRPC-SHUTDOWN-002; FEATURE="GrpcServerLifecycle"; ASPECT=NoFalseSuccessOnShutdown; STATUS=TESTED; TEST=tests/test_grpc_shutdown_drain.zig; OWNER=transport; UPDATED=2026-09-01

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const posix = std.posix;
const linux = std.os.linux;

const binary_path = "zig-out/bin/geode";
const admin_username = "geode";
const admin_password = "testpass123";
const ready_marker = "server ready";
const ready_deadline_ms: i64 = 60_000;
const cli_deadline_ms: i64 = 180_000;

/// The teardown watchdog forces exit at 30 s (`gap 0039`), so a clean shutdown
/// can legitimately take just over that. Allow generous headroom.
const shutdown_deadline_ms: i64 = 90_000;

/// Rows of :SlowP. 200^3 = 8 000 000 combinations; measured well over 60 s in a
/// Debug build, so the query is reliably still executing when the signal lands.
const slow_rows: usize = 200;

/// How long to let the query run before signalling. Long enough that execution
/// has certainly started, short enough that it cannot have finished.
const inflight_settle_ms: u64 = 6_000;

const slow_statement = "MATCH (a:SlowP), (b:SlowP), (c:SlowP) RETURN count(*) AS c";

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
    /// Set when the process was reaped after dying on a signal rather than
    /// exiting: `waitExit` cannot express that in a u8, so it is recorded here.
    died_on_signal: ?u32 = null,
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

    fn alive(self: *Proc) bool {
        if (self.reaped) return false;
        const pid = self.child.id orelse return false;
        var status: u32 = 0;
        const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
        const rc_signed: isize = @bitCast(rc);
        if (rc_signed == pid) {
            self.reaped = true;
            if (!linux.W.IFEXITED(status)) self.died_on_signal = @intFromEnum(linux.W.TERMSIG(status));
            return false;
        }
        return rc_signed == 0;
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
                if (linux.W.IFEXITED(status)) return linux.W.EXITSTATUS(status);
                self.died_on_signal = @intFromEnum(linux.W.TERMSIG(status));
                return 255;
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

    fn signal(self: *Proc, sig: posix.SIG) void {
        if (self.reaped) return;
        const pid = self.child.id orelse return;
        posix.kill(pid, sig) catch {};
    }

    fn deinit(self: *Proc) void {
        if (!self.reaped) {
            if (self.child.id) |pid| {
                posix.kill(pid, .KILL) catch {};
                var status: u32 = 0;
                _ = linux.waitpid(pid, &status, 0);
                self.reaped = true;
            }
        }
        self.transcript.deinit(self.gpa);
    }

    fn dump(self: *Proc, label: []const u8) void {
        const max_dump: usize = 6 * 1024;
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
    grpc_listen: []const u8,
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

    fn sh(self: *Fixture, cmd: []const u8) !Proc {
        const argv = try self.aa().alloc([]const u8, 3);
        argv[0] = "/bin/sh";
        argv[1] = "-c";
        argv[2] = cmd;
        return spawnProc(self.gpa, self.aa(), self.io(), argv, &.{
            .{ .key = "GEODE_ALLOW_INSECURE_TLS", .value = "1" },
            .{ .key = "GEODE_LOG_LEVEL", .value = "warn" },
        });
    }

    fn runQuic(self: *Fixture, extra_args: []const u8) !Proc {
        const cmd = try std.fmt.allocPrint(
            self.aa(),
            "{s} query --server {s} --insecure-tls-skip-verify --format json -U {s} -P '{s}' {s} < /dev/null",
            .{ binary_path, self.listen, admin_username, admin_password, extra_args },
        );
        return self.sh(cmd);
    }

    /// Talks to the REAL gRPC listener — no proxy, no fault injection.
    fn runGrpc(self: *Fixture, extra_args: []const u8) !Proc {
        const cmd = try std.fmt.allocPrint(
            self.aa(),
            "{s} query --dsn 'grpc://{s}:{s}@{s}' --insecure-tls-skip-verify --format json {s} < /dev/null",
            .{ binary_path, admin_username, admin_password, self.grpc_listen, extra_args },
        );
        return self.sh(cmd);
    }

    /// Seed `slow_rows` :SlowP nodes over QUIC in one chunked statement.
    fn seed(self: *Fixture) !void {
        var stmt = std.ArrayList(u8).empty;
        defer stmt.deinit(self.gpa);
        try stmt.appendSlice(self.gpa, "CREATE ");
        var i: usize = 0;
        while (i < slow_rows) : (i += 1) {
            if (i != 0) try stmt.appendSlice(self.gpa, ", ");
            var buf: [64]u8 = undefined;
            try stmt.appendSlice(self.gpa, try std.fmt.bufPrint(&buf, "(:SlowP {{i: {d}}})", .{i}));
        }
        try stmt.appendSlice(self.gpa, ";\n");

        const io_fs = std.Io.Threaded.global_single_threaded.io();
        const path = try std.fmt.allocPrint(self.aa(), "{s}-seed.gql", .{self.data_dir});
        try std.Io.Dir.cwd().writeFile(io_fs, .{ .sub_path = path, .data = stmt.items });

        const args = try std.fmt.allocPrint(self.aa(), "--timeout 120 --file {s}", .{path});
        var p = try self.runQuic(args);
        defer p.deinit();
        const code = p.waitExit(cli_deadline_ms) orelse return error.SeedHung;
        if (code != 0) {
            p.dump("seed");
            return error.SeedFailed;
        }
    }
};

fn setUp(gpa: std.mem.Allocator, tag: []const u8, port: u16, grpc_port: u16) !?Fixture {
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
    const data_dir = try std.fmt.allocPrint(aa, "/tmp/geode-grpcdrain-{s}-{d}-data", .{ tag, stamp });
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
        .grpc_listen = try std.fmt.allocPrint(aa, "127.0.0.1:{d}", .{grpc_port}),
        .spawn_threaded = threaded,
        .gpa = gpa,
    };
    errdefer fx.deinit();

    const serve_args = try fx.aa().alloc([]const u8, 9);
    serve_args[0] = binary_path;
    serve_args[1] = "serve";
    serve_args[2] = "--listen";
    serve_args[3] = fx.listen;
    serve_args[4] = "--data-dir";
    serve_args[5] = fx.data_dir;
    serve_args[6] = "--log-level=warn";
    serve_args[7] = "--listen-grpc";
    serve_args[8] = fx.grpc_listen;

    var srv = try spawnProc(gpa, fx.aa(), fx.io(), serve_args, &.{
        .{ .key = "GEODE_ADMIN_USERNAME", .value = admin_username },
        .{ .key = "GEODE_ADMIN_PASSWORD", .value = admin_password },
        .{ .key = "GEODE_GRPC_ALLOW_PLAINTEXT_FALLBACK", .value = "1" },
    });
    if (!srv.waitForMarker(ready_marker, ready_deadline_ms)) {
        srv.dump("server");
        srv.deinit();
        return error.ServerStartupTimeout;
    }
    fx.server = srv;
    return fx;
}

/// Assert the server transcript carries no crash evidence, with the exact
/// signature named so a regression is unambiguous.
fn expectNoCrash(srv: *Proc, lane: []const u8) !void {
    if (srv.saw("panic")) {
        srv.dump("server (panicked)");
        std.debug.print(
            "\n[grpc-drain/{s}] the server PANICKED during shutdown. The store is freed at src/server/main.zig:2346 while detached gRPC handler threads are still reading it; GeodeGrpcServer (src/transport/grpc_server.zig:625) has no requestShutdown for the shutdown path to call\n",
            .{lane},
        );
        return error.ServerPanickedOnShutdown;
    }
    if (srv.saw("incorrect alignment")) {
        srv.dump("server (use-after-free)");
        return error.ServerUseAfterFreeOnShutdown;
    }
    if (srv.saw("Segmentation fault") or srv.saw("SIGSEGV")) {
        srv.dump("server (segfault)");
        return error.ServerSegfaultedOnShutdown;
    }
}

// ---------------------------------------------------------------------
// 0. CONTROL — SIGTERM with NOTHING in flight.
//    Measured clean today (exit 0, zero panics). If this fails, the shutdown
//    path is broken generally and the in-flight cases below prove nothing
//    specific to gRPC.
// ---------------------------------------------------------------------
test "control: SIGTERM with no in-flight work shuts down cleanly" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "idle", 24011, 24012)) orelse return error.SkipZigTest;
    defer fx.deinit();

    var srv = &fx.server.?;
    srv.signal(.TERM);

    const code = srv.waitExit(shutdown_deadline_ms) orelse {
        srv.dump("server (idle SIGTERM never exited)");
        return error.IdleShutdownHung;
    };
    try expectNoCrash(srv, "idle");
    if (code != 0) {
        srv.dump("server (idle SIGTERM exit code)");
        std.debug.print("\n[grpc-drain/idle] idle SIGTERM exited {d}, expected 0\n", .{code});
        return error.IdleShutdownUnclean;
    }
}

// ---------------------------------------------------------------------
// 1. THE REGRESSION TEST: SIGTERM with a gRPC query mid-execution.
//
//    RED TODAY: `thread N panic: incorrect alignment`, stack running
//    graph_storage_adapter (`self.engines.get` on a freed adapter) <-
//    planned_read_runtime.materializeNode <- grpc_server.zig:2567 handleExecute
//    <- grpc_server.zig:953 handleExecuteStreaming <- the vendored detached
//    connectionThread.
// ---------------------------------------------------------------------
test "SIGTERM with an in-flight gRPC query does not use-after-free the store" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "grpc", 24013, 24014)) orelse return error.SkipZigTest;
    defer fx.deinit();

    try fx.seed();

    const args = try std.fmt.allocPrint(fx.aa(), "--timeout 120 \"{s}\"", .{slow_statement});
    var q = try fx.runGrpc(args);
    defer q.deinit();

    // Let the statement genuinely start executing server-side.
    sleepMs(inflight_settle_ms);
    if (!q.alive()) {
        q.dump("grpc slow query (finished before the signal)");
        std.debug.print(
            "\n[grpc-drain] the {d}-row cartesian probe completed inside {d} ms on this machine; nothing was in flight when SIGTERM landed and this lane proves nothing\n",
            .{ slow_rows, inflight_settle_ms },
        );
        return error.SlowProbeWasNotSlow;
    }

    var srv = &fx.server.?;
    srv.signal(.TERM);

    const code = srv.waitExit(shutdown_deadline_ms) orelse {
        srv.dump("server (in-flight SIGTERM never exited)");
        return error.GrpcShutdownHung;
    };

    // ASSERTION 1 — no crash. This is the defect.
    try expectNoCrash(srv, "grpc");

    // ASSERTION 2 — and the process ended on its own terms, not on a signal.
    if (srv.died_on_signal) |sig| {
        srv.dump("server (died on a signal)");
        std.debug.print(
            "\n[grpc-drain] the server died on signal {d} instead of exiting; a SIGABRT here is the panic aborting the process\n",
            .{sig},
        );
        return error.ServerDiedOnSignal;
    }
    if (code != 0) {
        srv.dump("server (in-flight SIGTERM exit code)");
        std.debug.print(
            "\n[grpc-drain] SIGTERM with an in-flight gRPC query exited {d}; the idle control exits 0\n",
            .{code},
        );
        return error.GrpcShutdownUnclean;
    }
}

// ---------------------------------------------------------------------
// 2. The CLIENT-side half of the same defect: a query the server never
//    finished must NOT be reported to the caller as a successful empty result.
//
//    RED TODAY: the client exits 0 printing `"rows":[]`, indistinguishable
//    from a legitimate no-match — so a caller silently records "no results"
//    for a statement that was abandoned mid-execution.
// ---------------------------------------------------------------------
test "an in-flight gRPC query interrupted by shutdown is not reported as an empty success" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "false", 24015, 24016)) orelse return error.SkipZigTest;
    defer fx.deinit();

    try fx.seed();

    const args = try std.fmt.allocPrint(fx.aa(), "--timeout 120 \"{s}\"", .{slow_statement});
    var q = try fx.runGrpc(args);
    defer q.deinit();

    sleepMs(inflight_settle_ms);
    if (!q.alive()) return error.SlowProbeWasNotSlow;

    fx.server.?.signal(.TERM);

    const code = q.waitExit(cli_deadline_ms) orelse {
        q.dump("grpc client (never exited)");
        return error.GrpcClientHung;
    };

    // Either the shutdown drains the statement to completion (exit 0 WITH the
    // real count) or the client is told the query did not complete (non-zero).
    // The one outcome that must never happen is exit 0 with an empty row set.
    const empty_success = code == 0 and q.saw("\"rows\":[]");
    if (empty_success) {
        q.dump("grpc client (false empty success)");
        std.debug.print(
            "\n[grpc-drain] the client exited 0 with an EMPTY row set for a statement the server abandoned mid-execution; a caller cannot distinguish this from a legitimate no-match\n",
            .{},
        );
        return error.FalseEmptySuccessOnShutdown;
    }
}

// ---------------------------------------------------------------------
// 3. GUARDRAIL / REFERENCE — the SAME scenario over QUIC.
//    GREEN TODAY and must stay green: the QUIC path counts the connection in
//    its drain and does not panic. It is the shape the gRPC fix should match.
// ---------------------------------------------------------------------
test "guardrail: SIGTERM with an in-flight QUIC query shuts down without a panic" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "quic", 24017, 24018)) orelse return error.SkipZigTest;
    defer fx.deinit();

    try fx.seed();

    const args = try std.fmt.allocPrint(fx.aa(), "--timeout 120 \"{s}\"", .{slow_statement});
    var q = try fx.runQuic(args);
    defer q.deinit();

    sleepMs(inflight_settle_ms);
    if (!q.alive()) return error.SlowProbeWasNotSlow;

    var srv = &fx.server.?;
    srv.signal(.TERM);

    const code = srv.waitExit(shutdown_deadline_ms) orelse {
        srv.dump("server (QUIC in-flight SIGTERM never exited)");
        return error.QuicShutdownHung;
    };
    try expectNoCrash(srv, "quic");
    if (srv.died_on_signal != null or code != 0) {
        srv.dump("server (QUIC in-flight SIGTERM exit)");
        return error.QuicShutdownUnclean;
    }
}
