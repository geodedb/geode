// The CLI's gRPC client cannot carry a request OR a response larger than one
// HTTP/2 DATA frame. Both directions are broken, independently, and both are
// invisible over QUIC.
//
// VERIFIED READ-ONLY against this branch, then reproduced live (see the
// measured signatures below):
//
//   REQUEST SIDE — `src/cli/grpc_query_transport.zig:218` (`sendRequest`)
//   writes the whole gRPC message as ONE DATA frame, with no regard for the
//   peer's `SETTINGS_MAX_FRAME_SIZE`. The peer's SETTINGS payload is not even
//   read: `drainInitialSettings` (:84-102) reads the frame header and then
//   DISCARDS the payload, so the client never learns the limit and never
//   splits. HTTP/2's default `SETTINGS_MAX_FRAME_SIZE` is 16 384, so any
//   program over ~16 KiB produces an oversized frame. The server is
//   spec-correct here — it answers with a FRAME_SIZE_ERROR and closes — and the
//   client surfaces that as `ConnectionResetByPeer` under a diagnostic blaming
//   TLS, which is simply false (the connection had already carried the preface,
//   SETTINGS, and HEADERS).
//
//   RESPONSE SIDE — `src/cli/grpc_query_transport.zig:236-253` (`readResponse`)
//   assumes ONE DATA frame == ONE complete gRPC message. A server that
//   fragments its reply across frames (which it MUST, for a reply over its own
//   max frame size) is mis-decoded: the client reads the first fragment, treats
//   its prefix as the whole length-prefixed gRPC message, and fails to parse
//   it. Surfaces as `InvalidInput` behind the same false TLS diagnostic.
//
// QUIC is unaffected in both directions — it has no frame-size negotiation of
// this kind — which is why nothing in the suite caught this.
//
// MEASURED RED SIGNATURES (live, against a real `geode serve --listen-grpc`
// with `GEODE_GRPC_ALLOW_PLAINTEXT_FALLBACK=1`, this branch):
//
//   request  >16 KiB  ->  exit 1,
//                         "gRPC request to 127.0.0.1:PORT failed (ConnectionResetByPeer)."
//   response >16 KiB  ->  exit 1,
//                         "gRPC request to 127.0.0.1:PORT failed (InvalidInput)."
//   both, over QUIC   ->  exit 0, full payload (20 404 bytes of JSON for the
//                         20 KB row) — the controls below.
//
// NOTE ON THE OTHER gRPC LANE: `tests/test_cli_timeout_exit_code.zig` reaches
// the gRPC listener through a `StallProxy` whose `forwardFrame` (:581-602)
// re-splits oversized DATA frames. That is a deliberate CRUTCH for the timeout
// lane and it papers over exactly the request-side defect under test here.
// NOTHING in this file goes through a proxy: every case below talks to the REAL
// gRPC listener with the REAL client framing, so the crutch cannot mask the
// result. Once the client framing is fixed, that crutch should be deleted.
//
// CANARY: REQ=REQ-CLI-GRPC-FRAMING-001; FEATURE="GrpcQueryTransport"; ASPECT=RequestFrameSplitting; STATUS=TESTED; TEST=tests/test_grpc_large_payload.zig; OWNER=cli; UPDATED=2026-09-01
// CANARY: REQ=REQ-CLI-GRPC-FRAMING-002; FEATURE="GrpcQueryTransport"; ASPECT=ResponseReassembly; STATUS=TESTED; TEST=tests/test_grpc_large_payload.zig; OWNER=cli; UPDATED=2026-09-01

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const builtin = @import("builtin");
const testing = std.testing;
const posix = std.posix;
const linux = std.os.linux;

const binary_path = geode_test_bin.geode_exe;
const admin_username = "geode";
const admin_password = "Test Pass Admin Passphrase";
const ready_marker = "server ready";
const ready_deadline_ms: i64 = 60_000;
const cli_deadline_ms: i64 = 180_000;

/// Comfortably past HTTP/2's default SETTINGS_MAX_FRAME_SIZE (16 384) so the
/// single-frame write is unambiguously oversized, but small enough that the
/// statement itself is trivial for the server.
const big_request_pad: usize = 20_000;

/// The response payload. Well over one frame, and over the request threshold
/// too, so a fix that only splits requests still fails this.
const big_response_pad: usize = 60_000;

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
        const max_dump: usize = 4 * 1024;
        const items = self.transcript.items;
        const slice = if (items.len > max_dump) items[0..max_dump] else items;
        std.debug.print("\n--- {s} transcript (head) ---\n{s}\n--- end ---\n", .{ label, slice });
    }

    /// Longest run of `ch` anywhere in the transcript. The padded property is a
    /// single unbroken run, so this measures how much of the row actually
    /// arrived — a partial or mis-reassembled response cannot fake it.
    fn longestRun(self: *Proc, ch: u8) usize {
        var best: usize = 0;
        var cur: usize = 0;
        for (self.transcript.items) |c| {
            if (c == ch) {
                cur += 1;
                if (cur > best) best = cur;
            } else cur = 0;
        }
        return best;
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

/// A real `geode serve` with BOTH transports up: QUIC (the control) and the
/// gRPC listener (the system under test).
///
/// `GEODE_GRPC_ALLOW_PLAINTEXT_FALLBACK` is what makes the gRPC listener
/// reachable from this CLI at all: the listener requires TLS unless that is set
/// AND the build is Debug (src/transport/grpc_server.zig:151-157), which is
/// exactly the `zig build` posture, and the CLI's gRPC client speaks plaintext
/// HTTP/2 only. It changes only the TLS posture — the HTTP/2 framing under test
/// is identical either way.
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

    /// `geode query` over QUIC — the CONTROL transport.
    fn runQuic(self: *Fixture, extra_args: []const u8) !Proc {
        const cmd = try std.fmt.allocPrint(
            self.aa(),
            "{s} query --server {s} --insecure-tls-skip-verify --format json -U {s} -P '{s}' {s} < /dev/null",
            .{ binary_path, self.listen, admin_username, admin_password, extra_args },
        );
        return self.sh(cmd);
    }

    /// `geode query` over the REAL gRPC listener. No proxy, no reframing.
    fn runGrpc(self: *Fixture, extra_args: []const u8) !Proc {
        const cmd = try std.fmt.allocPrint(
            self.aa(),
            "{s} query --dsn 'grpc://{s}:{s}@{s}' --insecure-tls-skip-verify --format json {s} < /dev/null",
            .{ binary_path, admin_username, admin_password, self.grpc_listen, extra_args },
        );
        return self.sh(cmd);
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

    /// Write `contents` to a scratch `.gql` file and return its path.
    fn writeScript(self: *Fixture, tag: []const u8, contents: []const u8) ![]const u8 {
        const io_fs = std.Io.Threaded.global_single_threaded.io();
        const path = try std.fmt.allocPrint(self.aa(), "{s}-{s}.gql", .{ self.data_dir, tag });
        try std.Io.Dir.cwd().writeFile(io_fs, .{ .sub_path = path, .data = contents });
        return path;
    }

    /// Seed the oversized row over QUIC (the transport that demonstrably
    /// carries it), so the RESPONSE test measures only the gRPC read path.
    fn seedHugeRow(self: *Fixture) !void {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.gpa);
        try buf.appendSlice(self.gpa, "CREATE (:HugeResp {n: 1, pad: '");
        try buf.appendNTimes(self.gpa, 'x', big_response_pad);
        try buf.appendSlice(self.gpa, "'});\n");

        const path = try self.writeScript("seed", buf.items);
        const args = try std.fmt.allocPrint(self.aa(), "--timeout 120 --file {s}", .{path});
        var p = try self.runQuic(args);
        defer p.deinit();
        const code = p.waitExit(cli_deadline_ms) orelse return error.SeedHung;
        if (code != 0) {
            p.dump("quic seed");
            return error.SeedFailed;
        }
    }
};

/// Returns null when the lane must SKIP (no binary / opt-out env).
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
    const data_dir = try std.fmt.allocPrint(aa, "/tmp/geode-grpcbig-{s}-{d}-data", .{ tag, stamp });
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

/// A ~20 KB single-statement program: one CREATE with a padded string literal.
/// Trivial for the server; oversized for one HTTP/2 DATA frame.
fn buildBigProgram(aa: std.mem.Allocator, label: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.appendSlice(aa, "CREATE (:");
    try buf.appendSlice(aa, label);
    try buf.appendSlice(aa, " {n: 1, pad: '");
    try buf.appendNTimes(aa, 'x', big_request_pad);
    try buf.appendSlice(aa, "'});\n");
    return buf.toOwnedSlice(aa);
}

// ---------------------------------------------------------------------
// 0. CONTROL — a SMALL gRPC round trip works today and must keep working.
//    If this fails, the plaintext-fallback gRPC lane is unavailable in this
//    environment and every result below is meaningless.
// ---------------------------------------------------------------------
test "control: a small gRPC query round trips" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "small", 23991, 23992)) orelse return error.SkipZigTest;
    defer fx.deinit();

    var p = try fx.runGrpc("\"RETURN 1 AS x\"");
    defer p.deinit();
    const code = p.waitExit(cli_deadline_ms) orelse {
        p.dump("grpc small query (never exited)");
        return error.GrpcSmallQueryHung;
    };
    if (code != 0 or !p.saw("\"x\":1")) {
        p.dump("grpc small query");
        std.debug.print(
            "\n[grpc-small] a sub-frame gRPC query exited {d}; the gRPC lane is not usable here so the large-payload cases below prove nothing\n",
            .{code},
        );
        return error.GrpcLaneUnavailable;
    }
}

// ---------------------------------------------------------------------
// 1. THE REQUEST REGRESSION: a program larger than one HTTP/2 DATA frame.
//
//    RED TODAY: exit 1, "failed (ConnectionResetByPeer)" — the server's
//    spec-correct FRAME_SIZE_ERROR, reported under a false TLS diagnostic.
// ---------------------------------------------------------------------
test "geode query over gRPC carries a request larger than one HTTP/2 frame" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "bigreq", 23993, 23994)) orelse return error.SkipZigTest;
    defer fx.deinit();

    const path = try fx.writeScript("bigreq", try buildBigProgram(fx.aa(), "BigReqG"));
    const args = try std.fmt.allocPrint(fx.aa(), "--timeout 120 --file {s}", .{path});

    var p = try fx.runGrpc(args);
    defer p.deinit();
    const code = p.waitExit(cli_deadline_ms) orelse {
        p.dump("grpc big request (never exited)");
        return error.GrpcBigRequestHung;
    };

    if (code != 0) {
        p.dump("grpc big request");
        std.debug.print(
            "\n[grpc-bigreq] a {d}-byte program over gRPC exited {d}; the same program over QUIC exits 0. sendRequest (src/cli/grpc_query_transport.zig:218) writes it as ONE DATA frame and drainInitialSettings (:84-102) discards the peer's SETTINGS_MAX_FRAME_SIZE, so the server answers FRAME_SIZE_ERROR\n",
            .{ big_request_pad, code },
        );
        return error.GrpcOversizedRequestRejected;
    }

    // Exit 0 alone is not enough — the write must actually have landed.
    var v = try fx.runGrpc("\"MATCH (n:BigReqG) RETURN count(*) AS c\"");
    defer v.deinit();
    _ = v.waitExit(cli_deadline_ms) orelse return error.GrpcVerifyHung;
    if (!v.saw("\"c\":1")) {
        v.dump("grpc big request verify");
        return error.GrpcOversizedRequestNotApplied;
    }
}

// ---------------------------------------------------------------------
// 1b. CONTROL for the request side — the SAME program over QUIC.
//     GREEN TODAY (measured exit 0) and must stay green: it proves the program
//     is valid and the server accepts it, so case 1 is a client-framing defect
//     and not a bad statement.
// ---------------------------------------------------------------------
test "control: the same oversized request succeeds over QUIC" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "bigreqquic", 23995, 23996)) orelse return error.SkipZigTest;
    defer fx.deinit();

    const path = try fx.writeScript("bigreq", try buildBigProgram(fx.aa(), "BigReqQ"));
    const args = try std.fmt.allocPrint(fx.aa(), "--timeout 120 --file {s}", .{path});

    var p = try fx.runQuic(args);
    defer p.deinit();
    const code = p.waitExit(cli_deadline_ms) orelse {
        p.dump("quic big request (never exited)");
        return error.QuicBigRequestHung;
    };
    if (code != 0) {
        p.dump("quic big request");
        return error.QuicOversizedRequestRejected;
    }
}

// ---------------------------------------------------------------------
// 2. THE RESPONSE REGRESSION: a single row larger than one HTTP/2 DATA frame.
//
//    The row is seeded over QUIC, so this measures ONLY the gRPC read path.
//
//    RED TODAY: exit 1, "failed (InvalidInput)" — readResponse
//    (src/cli/grpc_query_transport.zig:236-253) treats the first DATA frame as
//    the whole gRPC message and cannot decode the fragmented reply.
// ---------------------------------------------------------------------
test "geode query over gRPC reassembles a response larger than one HTTP/2 frame" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "bigresp", 23997, 23998)) orelse return error.SkipZigTest;
    defer fx.deinit();

    try fx.seedHugeRow();

    var p = try fx.runGrpc("\"MATCH (n:HugeResp) RETURN n.pad AS p\"");
    defer p.deinit();
    const code = p.waitExit(cli_deadline_ms) orelse {
        p.dump("grpc big response (never exited)");
        return error.GrpcBigResponseHung;
    };

    if (code != 0) {
        p.dump("grpc big response");
        std.debug.print(
            "\n[grpc-bigresp] a {d}-byte row over gRPC exited {d}; readResponse (src/cli/grpc_query_transport.zig:236-253) assumes one DATA frame is one gRPC message and mis-decodes the server's fragmented reply\n",
            .{ big_response_pad, code },
        );
        return error.GrpcOversizedResponseRejected;
    }

    // The WHOLE payload must arrive, not a first-frame prefix.
    const run = p.longestRun('x');
    if (run != big_response_pad) {
        p.dump("grpc big response (truncated)");
        std.debug.print(
            "\n[grpc-bigresp] the gRPC client delivered a {d}-byte run of padding; the row holds {d}. A first-DATA-frame prefix is ~16 KiB\n",
            .{ run, big_response_pad },
        );
        return error.GrpcOversizedResponseTruncated;
    }
}

// ---------------------------------------------------------------------
// 2b. CONTROL for the response side — the SAME row over QUIC.
//     GREEN TODAY (measured exit 0, full 60 000-char run) and must stay green.
// ---------------------------------------------------------------------
test "control: the same oversized response arrives intact over QUIC" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "bigrespquic", 23999, 24000)) orelse return error.SkipZigTest;
    defer fx.deinit();

    try fx.seedHugeRow();

    var p = try fx.runQuic("\"MATCH (n:HugeResp) RETURN n.pad AS p\"");
    defer p.deinit();
    const code = p.waitExit(cli_deadline_ms) orelse {
        p.dump("quic big response (never exited)");
        return error.QuicBigResponseHung;
    };
    if (code != 0) {
        p.dump("quic big response");
        return error.QuicOversizedResponseRejected;
    }
    const run = p.longestRun('x');
    if (run != big_response_pad) {
        std.debug.print(
            "\n[quic-bigresp] QUIC delivered a {d}-byte run; expected {d}\n",
            .{ run, big_response_pad },
        );
        return error.QuicOversizedResponseTruncated;
    }
}
