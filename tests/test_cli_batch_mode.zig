// CANARY: REQ=REQ-CLI-BATCH-MODE-001; FEATURE="QueryBatchMode"; ASPECT=SubprocessE2E; STATUS=TESTED; TEST=self; OWNER=cli; UPDATED=2026-08-29
//
// ENG-3914 fallout: `geode query --batch` (PERF-P1-002, recorded closed in
// docs/GAP_ANALYSIS_RESOLVED.md) has NEVER worked end to end. Two defects,
// both reproduced by the cases below:
//
//   1. UNREACHABLE BRANCH. `cmdQuery` refused with "query text required"
//      whenever no positional query was supplied, without considering
//      `--batch`; and the stdin-as-query block consumed the `-` positional
//      before the batch branch could see it. So `--batch` (with or without
//      `-`) never reached `executeBatchQueries`.
//
//   2. ONE STREAM PER CONNECTION. `executeBatchQueries` called
//      `executeQueryOnConnection` per line, which does `closeStream()` plus a
//      fresh HELLO for every statement. The server serves exactly ONE stream
//      per connection handler call (see the note at
//      src/cli/backup_cli.zig:1049-1054), so statement #1 succeeded and every
//      later statement blocked until the HELLO receive deadline elapsed.
//
// The fix: make the batch branch reachable from both spellings, HELLO ONCE on
// a single stream, and send each line as its own ExecuteRequest on that
// stream (the REPL transport's shape).
//
// These are subprocess e2e lanes: they spawn a real `./zig-out/bin/geode
// serve` and drive a real `./zig-out/bin/geode query --batch` against it, so
// nothing here can pass by mocking the wire. Skip semantics mirror
// tests/test_datadir_lock_subprocess.zig (skip when the binary is missing or
// $GEODE_SKIP_SUBPROC_CLUSTER is set).

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
const cli_deadline_ms: i64 = 90_000;

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

/// Spawned child with piped stdio and an owned transcript. waitpid is driven
/// by hand so every wait is bounded — a pre-fix batch client blocks on a HELLO
/// that never comes and would otherwise wedge the build.
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

    fn countOf(self: *Proc, marker: []const u8) usize {
        var n: usize = 0;
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, self.transcript.items, idx, marker)) |hit| {
            n += 1;
            idx = hit + marker.len;
        }
        return n;
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

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    data_dir: []const u8,
    work_dir: []const u8,
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
        std.Io.Dir.cwd().deleteTree(io_fs, self.work_dir) catch {};
        self.spawn_threaded.deinit();
        self.arena.child_allocator.destroy(self.spawn_threaded);
        self.arena.deinit();
    }

    /// Write `content` into the fixture work dir and return the path.
    fn writeBatchFile(self: *Fixture, name: []const u8, content: []const u8) ![]const u8 {
        const path = try std.fmt.allocPrint(self.aa(), "{s}/{s}", .{ self.work_dir, name });
        const io_fs = std.Io.Threaded.global_single_threaded.io();
        try std.Io.Dir.cwd().writeFile(io_fs, .{ .sub_path = path, .data = content });
        return path;
    }

    /// Run `geode query ...` with stdin redirected from `stdin_path` (null =
    /// /dev/null). Returns the reaped process so the caller can assert on the
    /// exit code and the transcript.
    fn runQuery(self: *Fixture, extra_args: []const u8, stdin_path: ?[]const u8) !Proc {
        const redirect = if (stdin_path) |p| p else "/dev/null";
        const cmd = try std.fmt.allocPrint(
            self.aa(),
            "{s} query --server {s} --insecure-tls-skip-verify --format json -U {s} -P '{s}' {s} < '{s}'",
            .{ binary_path, self.listen, admin_username, admin_password, extra_args, redirect },
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
};

/// Returns null when the lane must SKIP (no binary / opt-out env).
fn setUp(gpa: std.mem.Allocator, tag: []const u8, port: u16, start_server: bool) !?Fixture {
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
    const data_dir = try std.fmt.allocPrint(aa, "/tmp/geode-batch-{s}-{d}-data", .{ tag, stamp });
    const work_dir = try std.fmt.allocPrint(aa, "/tmp/geode-batch-{s}-{d}-work", .{ tag, stamp });
    for ([_][]const u8{ data_dir, work_dir }) |d| {
        std.Io.Dir.cwd().deleteTree(io_fs, d) catch {};
        std.Io.Dir.cwd().createDirPath(io_fs, d) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const threaded = try gpa.create(std.Io.Threaded);
    threaded.* = std.Io.Threaded.init(std.heap.smp_allocator, .{});

    var fx = Fixture{
        .arena = arena,
        .data_dir = data_dir,
        .work_dir = work_dir,
        .listen = try std.fmt.allocPrint(aa, "127.0.0.1:{d}", .{port}),
        .spawn_threaded = threaded,
        .gpa = gpa,
    };
    errdefer fx.deinit();

    if (!start_server) return fx;

    const serve_args = try fx.aa().alloc([]const u8, 7);
    serve_args[0] = binary_path;
    serve_args[1] = "serve";
    serve_args[2] = "--listen";
    serve_args[3] = fx.listen;
    serve_args[4] = "--data-dir";
    serve_args[5] = fx.data_dir;
    serve_args[6] = "--log-level=info";

    var srv = try spawnProc(gpa, fx.aa(), fx.io(), serve_args, &.{
        .{ .key = "GEODE_ADMIN_USERNAME", .value = admin_username },
        .{ .key = "GEODE_ADMIN_PASSWORD", .value = admin_password },
        // ENG-3914: the batch writers in the harness spec ride the bulk MERGE
        // fast path; keep the same server posture here.
        .{ .key = "GEODE_BULK_INGEST", .value = "1" },
    });
    if (!srv.waitForMarker(ready_marker, ready_deadline_ms)) {
        srv.dump("server");
        srv.deinit();
        return error.ServerStartupTimeout;
    }
    fx.server = srv;
    return fx;
}

// ---------------------------------------------------------------------
// 1. THE REGRESSION TEST: every statement in the batch executes.
// ---------------------------------------------------------------------
test "geode query --batch executes every statement on one connection" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "exec-all", 23961, true)) orelse return error.SkipZigTest;
    defer fx.deinit();

    // 5 statements: four writes plus a read-back. Each write carries a
    // distinct marker so a partial batch is visible in the row count, and the
    // trailing RETURN proves the connection was still usable at statement #5
    // (pre-fix it timed out on a second HELLO).
    const batch =
        \\CREATE (n:BatchProbe {k: 'alpha'})
        \\CREATE (n:BatchProbe {k: 'beta'})
        \\CREATE (n:BatchProbe {k: 'gamma'})
        \\CREATE (n:BatchProbe {k: 'delta'})
        \\MATCH (n:BatchProbe) RETURN count(n) AS c
        \\
    ;
    const path = try fx.writeBatchFile("five.gql", batch);

    var p = try fx.runQuery("--batch", path);
    defer p.deinit();
    const code = p.waitExit(cli_deadline_ms) orelse {
        p.dump("batch client (never exited)");
        return error.BatchClientHung;
    };
    if (code != 0) {
        p.dump("batch client (non-zero exit)");
        return error.BatchExitedNonZero;
    }
    if (!p.saw("\"c\":4")) {
        p.dump("batch client (read-back did not see 4 rows)");
        return error.BatchWritesMissing;
    }

    // A FOLLOW-UP connection must see all four writes: the batch results were
    // not merely rendered, they were committed.
    var verify = try fx.runQuery("\"MATCH (n:BatchProbe) RETURN count(n) AS c\"", null);
    defer verify.deinit();
    const vcode = verify.waitExit(cli_deadline_ms) orelse {
        verify.dump("verify client (never exited)");
        return error.VerifyClientHung;
    };
    try testing.expectEqual(@as(u8, 0), vcode);
    if (!verify.saw("\"c\":4")) {
        verify.dump("verify client");
        return error.BatchWritesNotDurable;
    }
}

// ---------------------------------------------------------------------
// 2. One RESULT per statement, and both stdin spellings reach the branch.
// ---------------------------------------------------------------------
test "geode query --batch emits one result per statement for both stdin spellings" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "one-per-line", 23962, true)) orelse return error.SkipZigTest;
    defer fx.deinit();

    const batch =
        \\RETURN 'batch_r1' AS m
        \\RETURN 'batch_r2' AS m
        \\RETURN 'batch_r3' AS m
        \\RETURN 'batch_r4' AS m
        \\RETURN 'batch_r5' AS m
        \\
    ;
    const path = try fx.writeBatchFile("markers.gql", batch);

    // Spelling A: `--batch` with no positional.
    {
        var p = try fx.runQuery("--batch", path);
        defer p.deinit();
        const code = p.waitExit(cli_deadline_ms) orelse {
            p.dump("batch client (never exited)");
            return error.BatchClientHung;
        };
        if (code != 0) {
            p.dump("batch client (non-zero exit)");
            return error.BatchExitedNonZero;
        }
        inline for (.{ "batch_r1", "batch_r2", "batch_r3", "batch_r4", "batch_r5" }) |marker| {
            if (!p.saw(marker)) {
                p.dump("batch client (missing result " ++ marker ++ ")");
                return error.MissingPerStatementResult;
            }
        }
    }

    // Spelling B: the explicit `-` stdin positional. Pre-fix this was eaten by
    // the stdin-as-query block and sent as ONE five-line program.
    {
        var p = try fx.runQuery("--batch -", path);
        defer p.deinit();
        const code = p.waitExit(cli_deadline_ms) orelse {
            p.dump("batch - client (never exited)");
            return error.BatchDashClientHung;
        };
        if (code != 0) {
            p.dump("batch - client (non-zero exit)");
            return error.BatchDashExitedNonZero;
        }
        inline for (.{ "batch_r1", "batch_r5" }) |marker| {
            if (!p.saw(marker)) {
                p.dump("batch - client (missing result " ++ marker ++ ")");
                return error.MissingPerStatementResultDash;
            }
        }
    }
}

// ---------------------------------------------------------------------
// 3. Statement-error semantics + blank-line handling.
// ---------------------------------------------------------------------
test "geode query --batch continues past a statement error and reports failure at the end" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "stmt-error", 23963, true)) orelse return error.SkipZigTest;
    defer fx.deinit();

    // Statement #2 is not GQL. The documented contract: render the error,
    // keep going, and exit non-zero at the end so a failed statement is never
    // silently swallowed by a zero exit code.
    const batch =
        \\RETURN 'err_before' AS m
        \\THIS IS NOT GQL AT ALL
        \\RETURN 'err_after' AS m
        \\
    ;
    const path = try fx.writeBatchFile("with_error.gql", batch);

    var p = try fx.runQuery("--batch", path);
    defer p.deinit();
    const code = p.waitExit(cli_deadline_ms) orelse {
        p.dump("batch client (never exited)");
        return error.BatchClientHung;
    };
    if (!p.saw("err_before")) {
        p.dump("batch client (statement before the error did not run)");
        return error.StatementBeforeErrorMissing;
    }
    if (!p.saw("err_after")) {
        p.dump("batch client (statement after the error did not run)");
        return error.StatementAfterErrorMissing;
    }
    if (code == 0) {
        p.dump("batch client (exited 0 despite a failed statement)");
        return error.FailedStatementNotReported;
    }
}

test "geode query --batch skips blank lines" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "blank-lines", 23964, true)) orelse return error.SkipZigTest;
    defer fx.deinit();

    const batch = "\n   \nRETURN 'blank_one' AS m\n\n\t\nRETURN 'blank_two' AS m\n\n";
    const path = try fx.writeBatchFile("blanks.gql", batch);

    var p = try fx.runQuery("--batch", path);
    defer p.deinit();
    const code = p.waitExit(cli_deadline_ms) orelse {
        p.dump("batch client (never exited)");
        return error.BatchClientHung;
    };
    if (code != 0) {
        p.dump("batch client (non-zero exit on blank-line input)");
        return error.BatchExitedNonZero;
    }
    try testing.expect(p.saw("blank_one"));
    try testing.expect(p.saw("blank_two"));
    // Exactly the two non-blank lines ran — the blanks did not become empty
    // statements (which the server would answer with a syntax error).
    if (!p.saw("2 queries executed")) {
        p.dump("batch client (unexpected executed-statement count)");
        return error.BlankLinesNotSkipped;
    }
}

// ---------------------------------------------------------------------
// 4. Truthful diagnostics: --batch plus a positional query is refused.
//    Arg validation only — no server needed.
// ---------------------------------------------------------------------
test "geode query --batch with a positional query is refused with a truthful message" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "positional", 23965, false)) orelse return error.SkipZigTest;
    defer fx.deinit();

    var p = try fx.runQuery("--batch \"RETURN 1 AS x\"", null);
    defer p.deinit();
    const code = p.waitExit(cli_deadline_ms) orelse {
        p.dump("batch client (never exited)");
        return error.BatchClientHung;
    };
    if (code == 0) {
        p.dump("batch client (accepted a positional query)");
        return error.PositionalQueryAccepted;
    }
    if (!p.saw("--batch reads statements from stdin")) {
        p.dump("batch client (no truthful diagnostic)");
        return error.MissingBatchPositionalDiagnostic;
    }
}
