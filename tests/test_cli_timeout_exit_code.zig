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
const geode_test_bin = @import("geode_test_bin");
const builtin = @import("builtin");
const testing = std.testing;

const linux = std.os.linux;
const posix = std.posix;

const binary_path = geode_test_bin.geode_exe;
const ready_marker = "[startup] server ready";
const admin_username = "geode";
const admin_password = "Geode Test Password Passphrase 123";

const ready_deadline_ms: i64 = 120_000;
const cli_deadline_ms: i64 = 120_000;

/// The exit code a client-side timeout must carry (ExitCode.timeout_error).
const expected_timeout_exit: u8 = 4;

/// A generic/connection failure (cli_dispatcher.ExitCode.general_error).
/// Duplicated as a bare const — like `expected_timeout_exit` — so this lane
/// need not import the full CLI module graph.
const expected_general_error_exit: u8 = 1;

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
    /// Set only when the fixture was brought up with a gRPC listener.
    grpc_listen: ?[]const u8 = null,
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

    /// Run `geode query` over the gRPC transport (`--dsn grpc://...`) against
    /// `dsn_authority` (`host:port`), which is either the server's own gRPC
    /// listener or the stalling proxy in front of it.
    fn runGrpcQuery(self: *Fixture, dsn_authority: []const u8, extra_args: []const u8) !Proc {
        const cmd = try std.fmt.allocPrint(
            self.aa(),
            "{s} query --dsn 'grpc://{s}:{s}@{s}' --insecure-tls-skip-verify --format json {s} < /dev/null",
            .{ binary_path, admin_username, admin_password, dsn_authority, extra_args },
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

/// Bind a UDP socket to 127.0.0.1:0, read the ephemeral port the kernel handed
/// out, then close it — so the returned port was provably free at this instant.
/// QUIC is UDP, so a UDP-free port is exactly "nothing is listening" for the
/// `geode query --server` connect path; a fixed high port could in principle be
/// bound by another process, this cannot. Returns null if the socket dance
/// fails (the caller then SKIPs rather than asserting on a bogus port).
fn pickDeadUdpPort() ?u16 {
    const rc_socket = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    if (@as(isize, @bitCast(rc_socket)) < 0) return null;
    const fd: i32 = @intCast(@as(isize, @bitCast(rc_socket)));
    defer _ = linux.close(fd);

    var bind_addr = linux.sockaddr.in{
        .port = 0,
        .addr = 0x0100007f, // 127.0.0.1 in network byte order
    };
    const rc_bind = linux.bind(fd, @ptrCast(&bind_addr), @sizeOf(linux.sockaddr.in));
    if (@as(isize, @bitCast(rc_bind)) != 0) return null;

    var out_addr: linux.sockaddr.in = undefined;
    var out_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    const rc_gsn = linux.getsockname(fd, @ptrCast(&out_addr), &out_len);
    if (@as(isize, @bitCast(rc_gsn)) != 0) return null;
    // sockaddr.in.port is network byte order.
    return std.mem.bigToNative(u16, out_addr.port);
}

/// A server-less rig for the connect-phase lanes: no `geode serve` at all, just
/// enough scaffolding to spawn a real `geode query` against a dead port and read
/// its exit code + stderr. Mirrors `Fixture`'s allocator/io ownership so the
/// same `spawnProc`/`Proc` machinery drives the real binary (no mocks).
const DeadPortFixture = struct {
    arena: std.heap.ArenaAllocator,
    threaded: *std.Io.Threaded,
    gpa: std.mem.Allocator,

    fn aa(self: *DeadPortFixture) std.mem.Allocator {
        return self.arena.allocator();
    }
    fn io(self: *DeadPortFixture) std.Io {
        return self.threaded.io();
    }

    /// Returns null when the lane must SKIP (no binary / opt-out env).
    fn setUp(gpa: std.mem.Allocator) !?DeadPortFixture {
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
        const threaded = try gpa.create(std.Io.Threaded);
        threaded.* = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        return DeadPortFixture{ .arena = arena, .threaded = threaded, .gpa = gpa };
    }

    fn deinit(self: *DeadPortFixture) void {
        self.threaded.deinit();
        self.arena.child_allocator.destroy(self.threaded);
        self.arena.deinit();
    }

    /// Run `geode query --server 127.0.0.1:<port> --timeout <secs> "RETURN 1"`.
    fn runDeadPort(self: *DeadPortFixture, port: u16, timeout_secs: u32) !Proc {
        const cmd = try std.fmt.allocPrint(
            self.aa(),
            "{s} query --server 127.0.0.1:{d} --insecure --timeout {d} \"RETURN 1\" < /dev/null",
            .{ binary_path, port, timeout_secs },
        );
        const argv = try self.aa().alloc([]const u8, 3);
        argv[0] = "/bin/sh";
        argv[1] = "-c";
        argv[2] = cmd;
        return spawnProc(self.gpa, self.aa(), self.io(), argv, &.{
            .{ .key = "GEODE_LOG_LEVEL", .value = "warn" },
        });
    }
};

// ---------------------------------------------------------------------
// CONNECT-PHASE LANES — a client-side deadline that elapses BEFORE the query
// was ever handed to a server is a CONNECTION failure (exit 1), NOT a query
// execution timeout (exit 4). Mirrors the harness spec cases
// `../geode-test-harness/geodetestlab-cli/specs/geode_quic_transport.yml`
// `connection-timeout` (exit 1 + stderr "timed out") and `connection-refused`
// (exit 1). RED today: the phase-blind watchdog in
// src/cli/query_deadline.zig:166-201 unconditionally exits 4 with "the
// statement may still be executing on the server" even though nothing ever
// connected, so nothing is executing anywhere.
//
// CANARY: REQ=REQ-CLI-CONNECT-TIMEOUT-CLASSIFY-001; FEATURE="QueryTimeoutClassification"; ASPECT=ConnectPhaseVsExecPhase; STATUS=TESTED; TEST=tests/test_cli_timeout_exit_code.zig; OWNER=cli; UPDATED=2026-09-02

test "geode query against an unreachable server reports a connect timeout (exit 1), not an exec timeout (exit 4)" {
    const gpa = testing.allocator;
    var fx = (try DeadPortFixture.setUp(gpa)) orelse return error.SkipZigTest;
    defer fx.deinit();

    const dead_port = pickDeadUdpPort() orelse return error.SkipZigTest;

    var p = try fx.runDeadPort(dead_port, 1);
    defer p.deinit();
    const code = p.waitExit(cli_deadline_ms) orelse {
        p.dump("query client (never exited)");
        return error.ConnectTimeoutClientHung;
    };

    // ASSERTION 1 — connect failure is a GENERAL error (exit 1), the contract
    // the harness `connection-timeout` case pins. RED today: 4
    // (ExitCode.timeout_error), because the watchdog fires before the connect
    // path's own `error.ConnectionFailed`->exit-1 can win.
    if (code != expected_general_error_exit) {
        p.dump("query client (connect-timeout exit code)");
        std.debug.print(
            "\n[cli-connect-timeout] `geode query --server 127.0.0.1:{d} --timeout 1` on a dead port exited {d}; expected {d} (ExitCode.general_error) — a never-connected server is a CONNECTION failure, not a query-execution timeout\n",
            .{ dead_port, code, expected_general_error_exit },
        );
        return error.ConnectTimeoutMisclassifiedAsExecTimeout;
    }

    // ASSERTION 2 — the message still names the deadline (harness
    // `stderr_contains: ['timed out']`).
    if (!p.saw("timed out")) {
        p.dump("query client (connect-timeout message did not mention a timeout)");
        return error.ConnectTimeoutMessageMissing;
    }

    // ASSERTION 3 — but it must NOT claim server-side work is in flight: nothing
    // ever connected. RED today: the watchdog prints "the statement may still
    // be executing on the server", which is false for an unreachable server.
    if (p.saw("may still be executing")) {
        p.dump("query client (connect-timeout falsely claimed server-side execution)");
        std.debug.print(
            "\n[cli-connect-timeout] the client never connected to 127.0.0.1:{d}, yet reported the statement 'may still be executing on the server'\n",
            .{dead_port},
        );
        return error.ConnectTimeoutFalselyClaimedServerExecution;
    }
}

test "geode query against a refused/dead connection port exits 1, not exec-timeout 4" {
    const gpa = testing.allocator;
    var fx = (try DeadPortFixture.setUp(gpa)) orelse return error.SkipZigTest;
    defer fx.deinit();

    const dead_port = pickDeadUdpPort() orelse return error.SkipZigTest;

    var p = try fx.runDeadPort(dead_port, 1);
    defer p.deinit();
    const code = p.waitExit(cli_deadline_ms) orelse {
        p.dump("query client (never exited)");
        return error.ConnectRefusedClientHung;
    };

    // The harness `connection-refused` case pins only `exit_code: 1`. RED today:
    // 4 (ExitCode.timeout_error) from the phase-blind watchdog.
    if (code != expected_general_error_exit) {
        p.dump("query client (connect-refused exit code)");
        std.debug.print(
            "\n[cli-connect-refused] `geode query --server 127.0.0.1:{d} --timeout 1` on a dead port exited {d}; expected {d} (ExitCode.general_error)\n",
            .{ dead_port, code, expected_general_error_exit },
        );
        return error.ConnectRefusedMisclassifiedAsExecTimeout;
    }

    // And, as above, it must not pretend the statement is running server-side.
    if (p.saw("may still be executing")) {
        p.dump("query client (connect-refused falsely claimed server-side execution)");
        return error.ConnectRefusedFalselyClaimedServerExecution;
    }
}

/// Returns null when the lane must SKIP (no binary / opt-out env).
fn setUp(gpa: std.mem.Allocator, tag: []const u8, port: u16) !?Fixture {
    return setUpWithGrpc(gpa, tag, port, null);
}

/// Same fixture, additionally bringing up the gRPC listener on `grpc_port`.
/// Geode's gRPC listener requires TLS unless
/// `GEODE_GRPC_ALLOW_PLAINTEXT_FALLBACK` is set AND the build is Debug
/// (src/transport/grpc_server.zig:151-157), which is exactly the `zig build`
/// posture this lane runs in; the CLI's gRPC client speaks plaintext HTTP/2
/// only, so that fallback is what makes the transport reachable from `geode
/// query --dsn grpc://...` at all.
fn setUpWithGrpc(gpa: std.mem.Allocator, tag: []const u8, port: u16, grpc_port: ?u16) !?Fixture {
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
    if (grpc_port) |gp| {
        fx.grpc_listen = try std.fmt.allocPrint(aa, "127.0.0.1:{d}", .{gp});
    }

    const serve_args = try fx.aa().alloc([]const u8, if (grpc_port == null) 7 else 9);
    serve_args[0] = binary_path;
    serve_args[1] = "serve";
    serve_args[2] = "--listen";
    serve_args[3] = fx.listen;
    serve_args[4] = "--data-dir";
    serve_args[5] = fx.data_dir;
    serve_args[6] = "--log-level=warn";
    if (fx.grpc_listen) |gl| {
        serve_args[7] = "--listen-grpc";
        serve_args[8] = gl;
    }

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

// =====================================================================
// gRPC TRANSPORT LANE — timeout MISCLASSIFICATION + SILENT RE-SUBMISSION
// =====================================================================
//
// VERIFIED READ-ONLY against this branch before the fix:
//
//   `executeGrpcQuery` (src/cli/main.zig:2010-2036) wraps the whole
//   connect+execute in a retry loop with `max_attempts = @max(retry_count+1, 3)`
//   and catches EVERY error from `executeQueryOnGrpc` — including
//   `error.ReadTimeout`, which `grpc_query_transport.readExact`
//   (src/client/grpc_query_transport.zig:148-159) raises when the SO_RCVTIMEO
//   set at :52-61 from `--timeout` expires. A client-side deadline is therefore
//   treated as a RETRYABLE transport fault:
//
//     * the statement is RE-SUBMITTED, on a fresh connection, up to 3 times —
//       for a mutating statement that is a silent duplicate write, and the CLI
//       never says a word about it;
//     * after the last attempt the process exits `ExitCode.general_error` (=1)
//       at :2080 while printing the "Geode's gRPC listener REQUIRES TLS ..."
//       diagnostic, which is FALSE here (the handshake succeeded; the server
//       is simply still working);
//     * the run takes ~3 x `--timeout` instead of ~1 x.
//
//   The QUIC path is already correct (exit 4 + "may still be executing"), and
//   `query_deadline.zig`'s process watchdog also exits 4 — which is precisely
//   what makes this defect nondeterministic against a bare server: the two
//   trip-wires race, and the watchdog usually wins.
//
//   MEASURED against a live server on this branch (2026-09-01, Debug build,
//   `--timeout 3`, gRPC DSN straight at `--listen-grpc`):
//     batch A: 16 runs -> 13 x (exit 4, ~3.69 s)  3 x (exit 1, ~11.3 s, false TLS text)
//     batch B: 20 runs -> 19 x (exit 4, ~3.69 s)  1 x (exit 1, ~11.4 s, false TLS text)
//     => the broken transport path wins only ~11% of runs (4/36). A repeat-N
//        assertion would be flaky, and WHICH wire-wire wins is decided by
//        (handshake_duration mod the watchdog's 100 ms tick), i.e. by the host,
//        so on another machine the rate can be 0.
//
// HOW THIS LANE MAKES IT DETERMINISTIC — `StallProxy`, a transport-level fault
// injector, NOT a mock:
//
//   The CLI, the wire protocol and the geode server are all REAL. The proxy is
//   a byte pump between them that does exactly one thing: after it has
//   forwarded the client's `Execute` request to the real server, it writes 4
//   bytes to the client and then stops forwarding the response.
//
//   Those 4 bytes are what removes the race. `readExact` calls
//   `notifyProgress` after EVERY short read, so the watchdog's progress clock
//   is reset microseconds before the client blocks for the remaining 5 bytes of
//   the frame header — the transport's SO_RCVTIMEO therefore expires first,
//   every time, instead of ~11% of the time.
//
//   The request itself really reaches the real server and really executes, so
//   a re-submission is observable BOTH as a proxy-side count and as duplicate
//   rows in the database.
//
// CANARY: REQ=REQ-CLI-TIMEOUT-EXIT-CODE-002; FEATURE="QueryTimeoutClassification"; ASPECT=GrpcTransportTimeout; STATUS=TESTED; TEST=tests/test_cli_timeout_exit_code.zig; OWNER=cli; UPDATED=2026-09-01
// CANARY: REQ=REQ-CLI-TIMEOUT-NO-RESUBMIT-001; FEATURE="QueryTimeoutClassification"; ASPECT=NoSilentResubmission; STATUS=TESTED; TEST=tests/test_cli_timeout_exit_code.zig; OWNER=cli; UPDATED=2026-09-01

const H2_DATA: u8 = 0x0;
const H2_HEADERS: u8 = 0x1;
/// `grpc_query_transport.execute_stream_id` — the Execute RPC always rides
/// HTTP/2 stream 3 (the Handshake rides stream 1).
const execute_stream_id: u32 = 3;
const h2_preface_len: usize = 24;

fn netIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn readSome(fd: std.Io.File.Handle, buf: []u8) ?usize {
    const n = std.posix.read(fd, buf) catch return null;
    if (n == 0) return null;
    return n;
}

fn readExactFd(fd: std.Io.File.Handle, dest: []u8) bool {
    var total: usize = 0;
    while (total < dest.len) {
        const n = std.posix.read(fd, dest[total..]) catch return false;
        if (n == 0) return false;
        total += n;
    }
    return true;
}

fn writeAllFd(fd: std.Io.File.Handle, bytes: []const u8) bool {
    var total: usize = 0;
    while (total < bytes.len) {
        const rc = linux.write(fd, bytes[total..].ptr, bytes.len - total);
        const signed: isize = @bitCast(rc);
        if (signed == -4) continue; // EINTR
        if (signed <= 0) return false;
        total += @intCast(signed);
    }
    return true;
}

/// A transparent TCP relay in front of the real gRPC listener that withholds
/// the RESPONSE to every `Execute` request (after nudging the client with a
/// partial frame header, see the lane header for why).
///
/// Counts, across the whole test:
///   * `sessions`  — accepted client connections (one per CLI connect attempt)
///   * `executes`  — `Execute` RPCs actually forwarded to the server
const StallProxy = struct {
    server: std.Io.net.Server,
    port: u16,
    upstream_port: u16,
    sessions: std.atomic.Value(u32) = .init(0),
    executes: std.atomic.Value(u32) = .init(0),
    stop_flag: std.atomic.Value(bool) = .init(false),
    accept_thread: ?std.Thread = null,
    gpa: std.mem.Allocator,

    fn start(gpa: std.mem.Allocator, upstream_port: u16, first_port: u16) !*StallProxy {
        const self = try gpa.create(StallProxy);
        errdefer gpa.destroy(self);

        var bound: u16 = 0;
        var server: std.Io.net.Server = undefined;
        var p: u16 = first_port;
        while (p < first_port + 200) : (p += 1) {
            const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", p) catch unreachable;
            server = std.Io.net.IpAddress.listen(&addr, netIo(), .{ .reuse_address = true }) catch continue;
            bound = p;
            break;
        }
        if (bound == 0) return error.NoFreeProxyPort;

        self.* = .{
            .server = server,
            .port = bound,
            .upstream_port = upstream_port,
            .gpa = gpa,
        };
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    fn stop(self: *StallProxy) void {
        self.stop_flag.store(true, .release);
        // Unblock the parked accept() with a throwaway connection.
        var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port) catch unreachable;
        if (std.Io.net.IpAddress.connect(&addr, netIo(), .{ .mode = .stream })) |s| {
            s.close(netIo());
        } else |_| {}
        if (self.accept_thread) |t| t.join();
        self.server.deinit(netIo());
        self.gpa.destroy(self);
    }

    fn acceptLoop(self: *StallProxy) void {
        var sessions: [16]?std.Thread = @splat(null);
        var live: usize = 0;
        while (!self.stop_flag.load(.acquire) and live < sessions.len) {
            const client = self.server.accept(netIo()) catch return;
            if (self.stop_flag.load(.acquire)) {
                client.close(netIo());
                break;
            }
            _ = self.sessions.fetchAdd(1, .monotonic);
            const holder = self.gpa.create(std.Io.net.Stream) catch {
                client.close(netIo());
                continue;
            };
            holder.* = client;
            sessions[live] = std.Thread.spawn(.{}, session, .{ self, holder }) catch {
                client.close(netIo());
                self.gpa.destroy(holder);
                continue;
            };
            live += 1;
        }
        for (sessions[0..live]) |maybe_t| {
            if (maybe_t) |t| t.join();
        }
    }

    const Pump = struct {
        from: std.Io.File.Handle,
        to: std.Io.File.Handle,
        stall: *std.atomic.Value(bool),

        /// Server -> client. Everything is forwarded verbatim until the
        /// session flips `stall`; from then on the response is swallowed, so
        /// the client sits in `readExact` until SO_RCVTIMEO fires.
        fn run(self: *Pump) void {
            var buf: [16 * 1024]u8 = undefined;
            while (true) {
                const n = readSome(self.from, &buf) orelse return;
                if (self.stall.load(.acquire)) continue;
                if (!writeAllFd(self.to, buf[0..n])) return;
            }
        }
    };

    fn session(self: *StallProxy, client_holder: *std.Io.net.Stream) void {
        const client = client_holder.*;
        defer {
            client.close(netIo());
            self.gpa.destroy(client_holder);
        }

        var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.upstream_port) catch unreachable;
        const upstream = std.Io.net.IpAddress.connect(&addr, netIo(), .{ .mode = .stream }) catch return;
        defer upstream.close(netIo());

        const cfd = client.socket.handle;
        const ufd = upstream.socket.handle;

        var stall = std.atomic.Value(bool).init(false);
        var pump = Pump{ .from = ufd, .to = cfd, .stall = &stall };
        const s2c = std.Thread.spawn(.{}, Pump.run, .{&pump}) catch return;
        defer s2c.join();

        // 1. HTTP/2 connection preface, verbatim.
        var preface: [h2_preface_len]u8 = undefined;
        if (!readExactFd(cfd, &preface)) return;
        if (!writeAllFd(ufd, &preface)) return;

        // 2. Frame-by-frame relay of the client's stream, so we can see the
        //    exact moment the Execute request has been handed to the server.
        var payload: [64 * 1024]u8 = undefined;
        var saw_execute = false;
        while (true) {
            var header: [9]u8 = undefined;
            if (!readExactFd(cfd, &header)) break;
            const length: usize = (@as(usize, header[0]) << 16) |
                (@as(usize, header[1]) << 8) | @as(usize, header[2]);
            const frame_type = header[3];
            const stream_id: u32 = (@as(u32, header[5] & 0x7F) << 24) |
                (@as(u32, header[6]) << 16) | (@as(u32, header[7]) << 8) | @as(u32, header[8]);
            if (length > payload.len) break;
            if (length > 0 and !readExactFd(cfd, payload[0..length])) break;
            // The CLI's gRPC client now fragments oversized requests into
            // legal-size DATA frames itself (grpc_query_transport.sendRequest),
            // so this relay forwards every frame VERBATIM — no reframing crutch.
            if (!writeAllFd(ufd, &header)) break;
            if (length > 0 and !writeAllFd(ufd, payload[0..length])) break;

            if (frame_type == H2_HEADERS and stream_id == execute_stream_id) {
                _ = self.executes.fetchAdd(1, .monotonic);
                saw_execute = true;
            }
            if (saw_execute and frame_type == H2_DATA and stream_id == execute_stream_id) {
                // The request is now with the real server, which will execute
                // it for real. Nudge the client with a PARTIAL frame header so
                // its deadline watchdog's progress clock is reset immediately
                // before it blocks, then withhold the response.
                stall.store(true, .release);
                _ = writeAllFd(cfd, &[_]u8{ 0x00, 0x00, 0x00, 0x00 });
                // Keep the connection open until the client gives up.
                var sink: [4096]u8 = undefined;
                while (readSome(cfd, &sink) != null) {}
                break;
            }
        }

        // The client is gone. Tear the upstream socket down so the
        // server->client pump's blocking read returns and the `s2c` join in
        // the deferred teardown cannot park forever (the geode server has no
        // reason to close its side first).
        _ = linux.shutdown(ufd, 2); // SHUT_RDWR
    }
};

/// A MUTATING statement that the server executes and commits promptly. The
/// timeout comes from the proxy withholding the RESPONSE, not from server-side
/// slowness — so every submission that reaches the server leaves exactly one
/// durable row behind, which is what makes a silent re-submission countable.
///
/// It is padded past 16 KiB and delivered with `--file` ON PURPOSE. That is the
/// SECOND half of making this lane deterministic:
///
///   `cmdQuery` arms the deadline watchdog with the raw `--timeout` for a
///   single query (src/cli/main.zig:1736), i.e. with the SAME number the
///   transport's SO_RCVTIMEO uses — so the two trip-wires expire within a
///   watchdog tick of each other and the process usually dies inside the
///   retry's 50 ms backoff, hiding the re-submission. A `--file` larger than
///   `max_single_query_size` (16 KiB, :1379) takes the chunked branch, which
///   arms the watchdog with `min(600, (timeout+3) * estimated_chunks)`
///   (:1590-1601) = 18 s here, while the per-chunk socket timeout stays 3 s.
///   The transport deadline therefore expires ~15 s before the watchdog can
///   interfere, and whatever `executeGrpcQuery` does with `error.ReadTimeout`
///   is observed directly instead of through a race.
///
///   Same `executeGrpcQuery` retry loop either way (`executeChunkedQueries`
///   calls it per chunk, :2553) — the chunked route is only the vehicle that
///   silences the watchdog.
fn buildPaddedMutation(aa: std.mem.Allocator) ![]const u8 {
    const pad_len: usize = 17_000; // > max_single_query_size (16 KiB)
    var buf = std.ArrayList(u8).empty;
    try buf.appendSlice(aa, "CREATE (:GrpcTmo {n: 1, pad: '");
    try buf.appendNTimes(aa, 'x', pad_len);
    try buf.appendSlice(aa, "'});\n");
    return buf.toOwnedSlice(aa);
}

/// Pull the integer out of the CLI's `{"c":N}` JSON row.
fn countFromJson(transcript: []const u8) ?u64 {
    const needle = "\"c\":";
    const at = std.mem.indexOf(u8, transcript, needle) orelse return null;
    var i = at + needle.len;
    var value: u64 = 0;
    var digits: usize = 0;
    while (i < transcript.len and transcript[i] >= '0' and transcript[i] <= '9') : (i += 1) {
        value = value * 10 + (transcript[i] - '0');
        digits += 1;
    }
    return if (digits == 0) null else value;
}

// ---------------------------------------------------------------------
// 4. THE gRPC REGRESSION TEST: a client-side timeout on the gRPC transport
//    must be classified as a timeout (exit 4, truthful message) and must NOT
//    silently re-submit the statement.
// ---------------------------------------------------------------------
test "geode query over gRPC reports a client timeout without re-submitting the statement" {
    const gpa = testing.allocator;
    var fx = (try setUpWithGrpc(gpa, "grpctmo", 23984, 23985)) orelse return error.SkipZigTest;
    defer fx.deinit();

    const proxy = try StallProxy.start(gpa, 23985, 24501);
    defer proxy.stop();

    const io_fs = std.Io.Threaded.global_single_threaded.io();
    const script_path = try std.fmt.allocPrint(fx.aa(), "{s}.gql", .{fx.data_dir});
    try std.Io.Dir.cwd().writeFile(io_fs, .{
        .sub_path = script_path,
        .data = try buildPaddedMutation(fx.aa()),
    });
    defer std.Io.Dir.cwd().deleteFile(io_fs, script_path) catch {};

    const authority = try std.fmt.allocPrint(fx.aa(), "127.0.0.1:{d}", .{proxy.port});
    const args = try std.fmt.allocPrint(fx.aa(), "--timeout 3 --file {s}", .{script_path});

    const started_ms = nowMillis();
    var p = try fx.runGrpcQuery(authority, args);
    defer p.deinit();
    const code = p.waitExit(cli_deadline_ms) orelse {
        p.dump("grpc query client (never exited)");
        return error.GrpcTimeoutClientHung;
    };
    const elapsed_ms = nowMillis() - started_ms;

    // ---- gather every piece of evidence FIRST, then assert on all of it ----

    // How many :GrpcTmo rows the ONE `geode query` invocation actually left
    // behind. Read over QUIC, which is unaffected by any of this.
    var verify = try fx.runQuery("--timeout 60 \"MATCH (n:GrpcTmo) RETURN count(*) AS c\"");
    defer verify.deinit();
    const verify_code = verify.waitExit(cli_deadline_ms) orelse return error.VerifyQueryHung;
    if (verify_code != 0) {
        verify.dump("verify query");
        return error.VerifyQueryFailed;
    }
    const rows_created = countFromJson(verify.transcript.items) orelse {
        verify.dump("verify query (no count in output)");
        return error.VerifyQueryUnparsable;
    };
    const executes = proxy.executes.load(.acquire);
    const sessions = proxy.sessions.load(.acquire);

    // Sanity: the request really reached the real server at least once. If it
    // did not, the proxy or the plaintext-fallback listener is broken and the
    // lane proves nothing.
    if (executes == 0) {
        p.dump("grpc query client (no Execute reached the server)");
        return error.GrpcRequestNeverReachedServer;
    }

    // ASSERTION 1 — the statement is submitted EXACTLY ONCE. RED: 3.
    // This is the data-integrity half of the bug: `error.ReadTimeout` is
    // retryable in the loop at src/cli/main.zig:2010-2036, so a mutating
    // statement that merely outlived its CLIENT deadline is written again, on
    // a fresh connection, without a word to the operator.
    if (executes != 1) {
        p.dump("grpc query client (statement re-submitted after a timeout)");
        std.debug.print(
            "\n[cli-timeout/grpc] ONE `geode query` invocation timed out and the CLI submitted the statement {d} times over {d} connections (exit {d} after {d} ms), leaving {d} :GrpcTmo row(s) in the graph\n",
            .{ executes, sessions, code, elapsed_ms, rows_created },
        );
        return error.TimeoutSilentlyResubmittedStatement;
    }

    // ASSERTION 2 — and the database agrees: a single invocation can never
    // leave MORE THAN ONE row behind.
    //
    // Deliberately an upper bound, not `== 1`. Whether a submission commits at
    // all is a genuine server-side race: when the client walks away the server
    // cancels the in-flight statement ("ReadQueryCancelled: the client
    // disconnected"), so 0 rows is a legitimate outcome for a timed-out write
    // and asserting `== 1` would flake in BOTH directions. Two or more rows,
    // though, can only come from the CLI submitting the statement more than
    // once. Measured pre-fix over 5 runs: 3, 0, 1, 2, 1 rows — every run
    // submitted 3 times, and 2 of the 5 committed duplicates.
    if (rows_created > 1) {
        std.debug.print(
            "\n[cli-timeout/grpc] ONE timed-out `CREATE (:GrpcTmo ...)` left {d} nodes in the graph — the timeout retry duplicated the write\n",
            .{rows_created},
        );
        return error.TimeoutResubmissionDuplicatedWrite;
    }

    // ASSERTION 3 — the distinct exit code. RED: 1 (general_error).
    if (code != expected_timeout_exit) {
        p.dump("grpc query client (timeout exit code)");
        std.debug.print(
            "\n[cli-timeout/grpc] `geode query --dsn grpc://... --timeout 3` exited {d} after {d} ms; expected {d} (ExitCode.timeout_error)\n",
            .{ code, elapsed_ms, expected_timeout_exit },
        );
        return error.GrpcTimeoutNotDistinguishedFromGeneralError;
    }

    // ASSERTION 4 — the message is truthful and actionable, the same contract
    // the QUIC path already honours.
    if (!p.saw("timed out")) {
        p.dump("grpc query client (message did not mention a timeout)");
        return error.GrpcTimeoutMessageMissing;
    }
    if (!p.saw("may still be executing")) {
        p.dump("grpc query client (message did not warn the statement may still be running)");
        return error.GrpcTimeoutMessageNotActionable;
    }

    // ASSERTION 5 — the timeout must not be dressed up as a TLS problem. RED:
    // the retry loop exhausts its attempts and prints the "Geode's gRPC
    // listener REQUIRES TLS" diagnostic even though the handshake plainly
    // succeeded (this very connection carried a Handshake RPC).
    if (p.saw("REQUIRES TLS")) {
        p.dump("grpc query client (timeout misdiagnosed as a TLS mismatch)");
        return error.TimeoutMisdiagnosedAsTlsFailure;
    }

    // ASSERTION 6 — one deadline, not three. A retry loop spends ~3 x the
    // timeout before giving up; a correct classification returns after one.
    if (elapsed_ms >= 2 * 3 * 1000) {
        p.dump("grpc query client (took multiple deadlines to give up)");
        std.debug.print(
            "\n[cli-timeout/grpc] the client took {d} ms to report a 3 s timeout — more than one deadline, i.e. it reconnected and waited again\n",
            .{elapsed_ms},
        );
        return error.GrpcTimeoutBurnedMultipleDeadlines;
    }
}

// ---------------------------------------------------------------------
// 5. Guardrails: the new classification must not leak into the gRPC happy
//    path, and a genuine statement error must not become a timeout.
// ---------------------------------------------------------------------
test "geode query over gRPC still exits 0 for a fast query and never claims a timeout" {
    const gpa = testing.allocator;
    var fx = (try setUpWithGrpc(gpa, "grpcok", 23986, 23987)) orelse return error.SkipZigTest;
    defer fx.deinit();

    const authority = fx.grpc_listen.?;

    var p = try fx.runGrpcQuery(authority, "--timeout 30 \"RETURN 1 AS x\"");
    defer p.deinit();
    const code = p.waitExit(cli_deadline_ms) orelse {
        p.dump("grpc query client (never exited)");
        return error.GrpcHappyPathHung;
    };
    if (code != 0) {
        p.dump("grpc query client (fast query did not exit 0)");
        return error.GrpcHappyPathNonZeroExit;
    }
    try testing.expect(p.saw("\"x\":1"));
    try testing.expect(!p.saw("timed out"));
    try testing.expect(!p.saw("REQUIRES TLS"));

    var bad = try fx.runGrpcQuery(authority, "--timeout 30 \"THIS IS NOT GQL AT ALL\"");
    defer bad.deinit();
    const bad_code = bad.waitExit(cli_deadline_ms) orelse {
        bad.dump("grpc query client (never exited)");
        return error.GrpcBadQueryHung;
    };
    if (bad_code == expected_timeout_exit) {
        bad.dump("grpc query client (a syntax error was reported as a timeout)");
        return error.GrpcNonTimeoutFailureReportedAsTimeout;
    }
    try testing.expect(bad.saw("42000"));
    try testing.expect(!bad.saw("timed out"));
    try testing.expect(!bad.saw("REQUIRES TLS"));
}
