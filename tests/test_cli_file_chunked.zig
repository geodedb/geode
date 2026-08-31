// CANARY: REQ=REQ-CLI-FILE-CHUNKED-001; FEATURE="QueryFileChunkedExecution"; ASPECT=SubprocessE2E; STATUS=IMPL; TEST=self; OWNER=cli; UPDATED=2026-08-31
//
// `geode query --file` reproduction lane.  Three verified defects, all
// live-reproduced at HEAD (e46ece27, this worktree, ./zig-out/bin/geode,
// server on 127.0.0.1:4600):
//
// ---------------------------------------------------------------------
// 2c — CRITICAL, SILENT DATA LOSS: a chunk that the server rejects is
//      counted as a success.
// ---------------------------------------------------------------------
// A --file over the 16KB chunking threshold (src/cli/main.zig:1384) is cut
// into 32KB chunks (:2332) and each chunk is shipped as ONE program
// (:2516-2535).  The `catch |err|` at :2532-2535 only ever sees ZIG errors —
// a server-side statement error comes back as a normal response whose JSON
// carries the GQLSTATE, so the catch never fires.  `executed += chunk_count`
// then credits the whole failed chunk, `executeChunkedQueries` returns void,
// and `cmdQuery` exits 0.
//
// Observed at HEAD with a 28,320-byte file of 400 valid CREATEs plus ONE
// invalid statement at index 200:
//
//     stdout: {"status_class":"42000","error_code":"42000","error":"parse error",...}
//     stderr: Executing chunk 1-401 of 401 statements...
//             Chunked execution complete:
//               Statements executed: 401          <-- claims all 401 ran
//             (no "Errors:" line at all)
//     exit code: 0
//     MATCH (n:ChunkProbe) RETURN count(n)  ->  0
//
// FOUR HUNDRED valid writes were dropped on the floor and the process
// reported total success.  The identical shape under `--batch` exits
// non-zero (src/cli/main.zig:1660-1664, ExitCode.general_error = 1).
//
// The contract pinned below (strongest the fixer can reasonably meet — the
// all-valid control case in this file proves 400/400 IS achievable on this
// exact fixture):
//   1. exit code 1  (ExitCode.general_error, same as --batch)
//   2. "Errors: 1" appears in the summary
//   3. "Statements executed: 400" — the summary must not credit the
//      statement that failed
//   4. exactly 400 ChunkProbe nodes persist — a failed chunk falls back to
//      statement-by-statement execution so only the GENUINELY bad statement
//      is lost, never its 400 innocent neighbours
//
// ---------------------------------------------------------------------
// 2 — UX: the 16 MiB cap refuses with a message an operator cannot act on.
// ---------------------------------------------------------------------
// src/cli/main.zig:1325-1327 compares against a bare `1 << 24` and prints
// "Error: File too large".  No size, no limit, no remedy.  `geode query
// --help` (:259) and docs/USAGE.md:28 never mention a cap at all, so the
// number is undiscoverable.  Verified at HEAD on a 17,825,823-byte file:
//
//     stderr: Error: File too large
//     exit code: 2                      <-- ExitCode.usage_error, KEEP THIS
//
// The check fires before any connection is opened, so these cases need no
// server.
//
// ---------------------------------------------------------------------
// 2d — swallowed allocation failures (NO AUTOMATED CASE HERE).
// ---------------------------------------------------------------------
// src/cli/main.zig:1357, 1359, 1399, 1400, 2478, 2481, 2483, 2489, 2490 all
// discard an allocation error with `catch {}`, so an OOM mid-assembly
// silently TRUNCATES a statement or a chunk and then executes the corrupted
// remainder.  That path cannot be driven from a subprocess: it needs a
// failing allocator, which needs the statement-assembly loop lifted out of
// `cmdQuery` (it is inline today, and every failure branch calls
// std.process.exit).  The fixer-owned unit test is specified verbatim in the
// commented skeleton at the bottom of this file; it is a FIX DELIVERABLE, not
// something this lane can assert today.
//
// Subprocess e2e shape, skip semantics, and the Proc helper mirror
// tests/test_cli_batch_mode.zig / tests/test_datadir_lock_subprocess.zig:
// skip when the binary is missing or $GEODE_SKIP_SUBPROC_CLUSTER is set.

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
const cli_deadline_ms: i64 = 180_000;

/// Valid CREATEs written into the chunked fixture.  Padded so the file clears
/// the 16KB chunking threshold (src/cli/main.zig:1384) while staying inside a
/// single 32KB chunk — the tightest shape that still loses everything.
const valid_stmt_count: usize = 400;
/// Index (into the valid run) after which the one poisoned statement is
/// injected.  Mid-file on purpose: statements both before and after it are at
/// risk, so a partial-apply fix cannot pass by accident.
const bad_stmt_index: usize = 200;

/// 2c contract strings.  These are the spec: the fixer must make all four
/// true simultaneously.
const errors_one_marker = "Errors: 1";
const truthful_executed_marker = "Statements executed: 400";
const untruthful_executed_marker = "Statements executed: 401";

/// 2 contract strings for the 16 MiB cap message.
const cap_marker = "16 MiB";
/// A remediation hint: an operator told only "too large" has nowhere to go.
/// Splitting the file is the actual remedy (each piece then chunks normally),
/// so the message has to say so.
const remediation_marker = "split";

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

/// Spawned child with piped stdio and an owned transcript (stdout AND stderr
/// merged: the chunked summary goes to stderr while the result JSON goes to
/// stdout, and both carry load-bearing evidence).  waitpid is driven by hand
/// so every wait is bounded.
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

    fn writeGqlFile(self: *Fixture, name: []const u8, content: []const u8) ![]const u8 {
        const path = try std.fmt.allocPrint(self.aa(), "{s}/{s}", .{ self.work_dir, name });
        const io_fs = std.Io.Threaded.global_single_threaded.io();
        try std.Io.Dir.cwd().writeFile(io_fs, .{ .sub_path = path, .data = content });
        return path;
    }

    /// Run `geode query <extra_args>` against the fixture server.
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

    /// Run `geode query <extra_args>` with NO server involved (the file-size
    /// cap fires before any connection is opened).
    fn runQueryNoServer(self: *Fixture, extra_args: []const u8) !Proc {
        const cmd = try std.fmt.allocPrint(
            self.aa(),
            "{s} query --server {s} --insecure-tls-skip-verify {s} < /dev/null",
            .{ binary_path, self.listen, extra_args },
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
    const data_dir = try std.fmt.allocPrint(aa, "/tmp/geode-filechunk-{s}-{d}-data", .{ tag, stamp });
    const work_dir = try std.fmt.allocPrint(aa, "/tmp/geode-filechunk-{s}-{d}-work", .{ tag, stamp });
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
    });
    if (!srv.waitForMarker(ready_marker, ready_deadline_ms)) {
        srv.dump("server");
        srv.deinit();
        return error.ServerStartupTimeout;
    }
    fx.server = srv;
    return fx;
}

/// Build the chunked fixture: `valid_stmt_count` CREATEs on `label`, with one
/// unparseable statement spliced in after `bad_stmt_index` when `poison` is
/// set.  Padding keeps every statement wide enough that the file clears the
/// 16KB chunking threshold.  Caller owns the returned slice.
fn buildChunkedGql(
    aa: std.mem.Allocator,
    label: []const u8,
    poison: bool,
) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(aa);
    var line: [256]u8 = undefined;
    for (0..valid_stmt_count) |i| {
        if (poison and i == bad_stmt_index) {
            // Not GQL under any reading: the server answers GQLSTATE 42000.
            try buf.appendSlice(aa, "THIS IS NOT VALID GQL AT ALL;\n");
        }
        const rendered = try std.fmt.bufPrint(
            &line,
            "CREATE (n:{s} {{i: {d}, pad: 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'}});\n",
            .{ label, i },
        );
        try buf.appendSlice(aa, rendered);
    }
    return buf.toOwnedSlice(aa);
}

/// Read `count(n)` back out of a `--format json` result row.  Returns null
/// when the transcript carries no such row (which is itself a failure the
/// caller reports).
fn parseCount(transcript: []const u8) ?i64 {
    const key = "\"c\":";
    const at = std.mem.indexOf(u8, transcript, key) orelse return null;
    var i = at + key.len;
    while (i < transcript.len and transcript[i] == ' ') i += 1;
    const start = i;
    while (i < transcript.len and std.ascii.isDigit(transcript[i])) i += 1;
    if (i == start) return null;
    return std.fmt.parseInt(i64, transcript[start..i], 10) catch null;
}

/// Run the count read-back on a fresh connection, so anything it sees was
/// actually committed rather than merely rendered.
fn readBackCount(fx: *Fixture, label: []const u8) !?i64 {
    const q = try std.fmt.allocPrint(
        fx.aa(),
        "\"MATCH (n:{s}) RETURN count(n) AS c\"",
        .{label},
    );
    var p = try fx.runQuery(q);
    defer p.deinit();
    const code = p.waitExit(cli_deadline_ms) orelse {
        p.dump("read-back client (never exited)");
        return error.ReadBackClientHung;
    };
    if (code != 0) {
        p.dump("read-back client (non-zero exit)");
        return error.ReadBackFailed;
    }
    return parseCount(p.transcript.items);
}

// ---------------------------------------------------------------------
// 1. THE REGRESSION TEST (2c): a rejected chunk must be reported, not
//    silently credited as a success.
// ---------------------------------------------------------------------
// Every violation is collected before failing so one run gives the fixer the
// whole contract, not just the first broken clause.
test "geode query --file reports a failed chunk instead of exiting 0 (chunked silent data loss regression)" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "chunk-error", 4601, true)) orelse return error.SkipZigTest;
    defer fx.deinit();

    const content = try buildChunkedGql(fx.aa(), "ChunkProbe", true);
    try testing.expect(content.len > 16 * 1024); // must actually chunk
    const path = try fx.writeGqlFile("chunked_bad.gql", content);

    const arg = try std.fmt.allocPrint(fx.aa(), "--file {s}", .{path});
    var p = try fx.runQuery(arg);
    defer p.deinit();

    const code = p.waitExit(cli_deadline_ms) orelse {
        p.dump("file client (never exited)");
        return error.FileClientHung;
    };

    // Guard: the fixture really did take the chunked path.  Without this a
    // future threshold change could make this test pass for the wrong reason.
    if (!p.saw("using chunked execution")) {
        p.dump("file client (never entered chunked execution)");
        return error.FixtureDidNotChunk;
    }
    // Guard: the server really did reject the poisoned statement.
    if (!p.saw("42000")) {
        p.dump("file client (server never reported the invalid statement)");
        return error.PoisonStatementNotRejected;
    }

    var violations: usize = 0;

    // (1) exit code — --batch already uses ExitCode.general_error (1) for the
    //     identical "a statement failed" condition (src/cli/main.zig:1660-1664).
    if (code != 1) {
        std.debug.print(
            "\n2c VIOLATION: `--file` exited {d}; expected 1 (ExitCode.general_error).\n" ++
                "  A server-side statement error inside a chunk is not a Zig error, so the\n" ++
                "  `catch |err|` at src/cli/main.zig:2532-2535 never fires and\n" ++
                "  executeChunkedQueries returns void.\n",
            .{code},
        );
        violations += 1;
    }

    // (2) the summary must say a chunk failed.
    if (!p.saw(errors_one_marker)) {
        std.debug.print(
            "\n2c VIOLATION: summary never contained \"{s}\".\n" ++
                "  error_count is only incremented for Zig errors (src/cli/main.zig:2534),\n" ++
                "  so a rejected chunk prints no Errors line at all.\n",
            .{errors_one_marker},
        );
        violations += 1;
    }

    // (3) the summary must not credit the statement that failed.
    if (p.saw(untruthful_executed_marker)) {
        std.debug.print(
            "\n2c VIOLATION: summary claimed \"{s}\" — `executed += chunk_count`\n" ++
                "  (src/cli/main.zig:2537) credits every statement in a chunk the server\n" ++
                "  refused.  Expected \"{s}\".\n",
            .{ untruthful_executed_marker, truthful_executed_marker },
        );
        violations += 1;
    } else if (!p.saw(truthful_executed_marker)) {
        std.debug.print(
            "\n2c VIOLATION: summary never contained \"{s}\"; the executed count must be\n" ++
                "  truthful (exactly the statements that actually ran).\n",
            .{truthful_executed_marker},
        );
        violations += 1;
    }

    if (violations > 0) {
        p.dump("file client (chunk-failure not propagated)");
        return error.ChunkFailureNotPropagated;
    }
}

// ---------------------------------------------------------------------
// 2. THE DATA-LOSS ASSERTION (2c): one bad statement must cost exactly one
//    statement, not its whole 32KB chunk.
// ---------------------------------------------------------------------
// Separate test so the fixer sees this red independently of the exit-code
// red above.  The all-valid control (case 3) proves 400/400 is reachable on
// this exact fixture and server, so 400 is not an aspirational number.
test "geode query --file loses only the invalid statement, not its whole chunk (chunked data-loss regression)" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "chunk-loss", 4602, true)) orelse return error.SkipZigTest;
    defer fx.deinit();

    const content = try buildChunkedGql(fx.aa(), "ChunkProbe", true);
    const path = try fx.writeGqlFile("chunked_bad.gql", content);

    const arg = try std.fmt.allocPrint(fx.aa(), "--file {s}", .{path});
    {
        var p = try fx.runQuery(arg);
        defer p.deinit();
        _ = p.waitExit(cli_deadline_ms) orelse {
            p.dump("file client (never exited)");
            return error.FileClientHung;
        };
        if (!p.saw("using chunked execution")) {
            p.dump("file client (never entered chunked execution)");
            return error.FixtureDidNotChunk;
        }
    }

    const persisted = (try readBackCount(&fx, "ChunkProbe")) orelse
        return error.ReadBackReturnedNoRow;

    if (persisted != @as(i64, @intCast(valid_stmt_count))) {
        std.debug.print(
            "\n2c VIOLATION (silent data loss): {d} of {d} valid CREATEs persisted.\n" ++
                "  The whole chunk containing the single invalid statement was shipped as ONE\n" ++
                "  program (src/cli/main.zig:2516-2535); the server refused the program and\n" ++
                "  every innocent statement in it vanished — while the CLI exited 0.\n" ++
                "  Contract: a chunk the server rejects must be retried statement by\n" ++
                "  statement so exactly the bad statement is lost.  Expected {d}.\n",
            .{ persisted, valid_stmt_count, valid_stmt_count },
        );
        return error.ValidStatementsSilentlyDropped;
    }
}

// ---------------------------------------------------------------------
// 3. CONTROL (guard, PASSES at HEAD): an all-valid chunked file still
//    commits everything and exits 0.
// ---------------------------------------------------------------------
// This is what keeps the fix honest: it pins that 400/400 + exit 0 is the
// achievable baseline on this fixture, and that the fix does not turn the
// happy path into a failure.
test "geode query --file commits every statement of an all-valid chunked file" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "chunk-good", 4603, true)) orelse return error.SkipZigTest;
    defer fx.deinit();

    const content = try buildChunkedGql(fx.aa(), "GoodProbe", false);
    try testing.expect(content.len > 16 * 1024);
    const path = try fx.writeGqlFile("chunked_good.gql", content);

    const arg = try std.fmt.allocPrint(fx.aa(), "--file {s}", .{path});
    {
        var p = try fx.runQuery(arg);
        defer p.deinit();
        const code = p.waitExit(cli_deadline_ms) orelse {
            p.dump("file client (never exited)");
            return error.FileClientHung;
        };
        if (code != 0) {
            p.dump("file client (all-valid chunked file exited non-zero)");
            return error.ValidChunkedFileFailed;
        }
        if (p.saw("Errors:")) {
            p.dump("file client (reported errors on an all-valid file)");
            return error.SpuriousChunkError;
        }
    }

    const persisted = (try readBackCount(&fx, "GoodProbe")) orelse
        return error.ReadBackReturnedNoRow;
    try testing.expectEqual(@as(i64, @intCast(valid_stmt_count)), persisted);
}

// ---------------------------------------------------------------------
// 4. (2) The 16 MiB cap must refuse with an ACTIONABLE message.
// ---------------------------------------------------------------------
// No server: src/cli/main.zig:1325-1327 fires while reading the file, before
// any connection is opened (verified at HEAD — the refusal is identical with
// the server up and with nothing listening).
test "geode query --file over the 16 MiB cap names the size, the limit, and a remedy" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "oversize", 4604, false)) orelse return error.SkipZigTest;
    defer fx.deinit();

    // 17 MiB, comfortably over `1 << 24`.  Built as one buffer + one write so
    // generation costs milliseconds.
    const cap: usize = 1 << 24;
    const target: usize = cap + (1 << 20);
    const unit = "-- padding comment line to clear the 16 MiB file cap\n";
    var content = try std.ArrayList(u8).initCapacity(fx.aa(), target + unit.len + 32);
    while (content.items.len < target) try content.appendSlice(fx.aa(), unit);
    try content.appendSlice(fx.aa(), "RETURN 1 AS x;\n");
    const path = try fx.writeGqlFile("oversize.gql", content.items);
    const actual_len = content.items.len;

    const arg = try std.fmt.allocPrint(fx.aa(), "--file {s}", .{path});
    var p = try fx.runQueryNoServer(arg);
    defer p.deinit();

    const code = p.waitExit(cli_deadline_ms) orelse {
        p.dump("oversize client (never exited)");
        return error.OversizeClientHung;
    };

    var violations: usize = 0;

    // Exit code is already correct at HEAD (ExitCode.usage_error = 2); pinned
    // so the fix cannot drift it while rewording the message.
    if (code != 2) {
        std.debug.print(
            "\n2 VIOLATION: oversize --file exited {d}; expected 2 (ExitCode.usage_error).\n",
            .{code},
        );
        violations += 1;
    }

    const size_str = try std.fmt.allocPrint(fx.aa(), "{d}", .{actual_len});
    if (!p.saw(size_str)) {
        std.debug.print(
            "\n2 VIOLATION: refusal never named the file's actual size ({s} bytes).\n" ++
                "  src/cli/main.zig:1325-1327 prints a bare \"Error: File too large\"; an\n" ++
                "  operator cannot tell how far over the line they are.\n",
            .{size_str},
        );
        violations += 1;
    }
    if (!p.saw(cap_marker)) {
        std.debug.print(
            "\n2 VIOLATION: refusal never named the limit (\"{s}\").  The cap is the bare\n" ++
                "  literal `1 << 24` at src/cli/main.zig:1325 and appears in no message, no\n" ++
                "  --help text, and no doc — it is undiscoverable.\n",
            .{cap_marker},
        );
        violations += 1;
    }
    if (!p.saw(remediation_marker)) {
        std.debug.print(
            "\n2 VIOLATION: refusal offered no remedy (expected the word \"{s}\" — splitting\n" ++
                "  the file is the actual fix, since each piece then chunks normally).\n",
            .{remediation_marker},
        );
        violations += 1;
    }

    if (violations > 0) {
        p.dump("oversize client (unactionable refusal)");
        return error.UnactionableFileTooLargeMessage;
    }
}

// ---------------------------------------------------------------------
// 5. (2) `geode query --help` must document the cap.
// ---------------------------------------------------------------------
// The --file help line (src/cli/main.zig:259) says only "Execute GQL
// statements from a file (supports ~)".  A limit a user can hit but cannot
// look up is a documentation defect in its own right.
test "geode query --help documents the --file size cap" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "help-cap", 4605, false)) orelse return error.SkipZigTest;
    defer fx.deinit();

    var p = try fx.runQueryNoServer("--help");
    defer p.deinit();
    _ = p.waitExit(cli_deadline_ms) orelse {
        p.dump("help client (never exited)");
        return error.HelpClientHung;
    };

    if (!p.saw("--file")) {
        p.dump("help client (no --file line at all)");
        return error.HelpMissingFileFlag;
    }
    if (!p.saw(cap_marker)) {
        p.dump("help client");
        std.debug.print(
            "\n2 VIOLATION: `geode query --help` never mentions \"{s}\".  The --file line\n" ++
                "  (src/cli/main.zig:259) must state the maximum accepted file size.\n",
            .{cap_marker},
        );
        return error.HelpMissingFileSizeCap;
    }
}

// =====================================================================
// 2d — FIXER DELIVERABLE (no automated case here; see the header note).
// =====================================================================
// The nine `catch {}` sites in the statement-assembly and chunk-building
// loops (src/cli/main.zig:1357, 1359, 1399, 1400, 2478, 2481, 2483, 2489,
// 2490) turn an allocation failure into a SILENTLY TRUNCATED statement that
// is then executed.  Driving that needs a failing allocator, which needs the
// loop lifted out of `cmdQuery`.  Uncomment and wire this once the seam
// exists — the assertions are already the contract:
//
//     const cli = @import("geode").cli;  // or the extracted module
//
//     test "assembleStatements is fatal on allocation failure (2d)" {
//         const src =
//             \\CREATE (n:A {p: 'one'});
//             \\CREATE (n:B {p: 'two'});
//             \\
//         ;
//         // Fail every allocation after the Nth so the failure lands MID
//         // statement, which is exactly the truncation shape today's
//         // `catch {}` hides.
//         var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 3 });
//         try testing.expectError(
//             error.OutOfMemory,
//             cli.assembleStatements(failing.allocator(), src),
//         );
//     }
//
//     test "assembleStatements never returns a truncated statement (2d)" {
//         // Sweep the fail index across the whole allocation sequence: for
//         // EVERY index the call must either return the complete statement
//         // list or return error.OutOfMemory — never a short/partial one.
//         const src = "CREATE (n:A {p: 'one'});\nCREATE (n:B {p: 'two'});\n";
//         var idx: usize = 0;
//         while (idx < 64) : (idx += 1) {
//             var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = idx });
//             const res = cli.assembleStatements(failing.allocator(), src) catch |err| {
//                 try testing.expectEqual(error.OutOfMemory, err);
//                 continue;
//             };
//             defer cli.freeStatements(failing.allocator(), res);
//             try testing.expectEqual(@as(usize, 2), res.len);
//             try testing.expect(std.mem.endsWith(u8, res[0], ";"));
//             try testing.expect(std.mem.endsWith(u8, res[1], ";"));
//         }
//     }
//
// Suggested seam:
//     pub fn assembleStatements(gpa: std.mem.Allocator, contents: []const u8)
//         error{OutOfMemory}![][]const u8
//     pub fn freeStatements(gpa: std.mem.Allocator, stmts: [][]const u8) void
// with `cmdQuery` calling it and exiting on error, and the chunk builder
// (src/cli/main.zig:2478-2490) propagating `try` instead of `catch {}`.
