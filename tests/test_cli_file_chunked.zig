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
// 2d — swallowed allocation failures.
// ---------------------------------------------------------------------
// src/cli/main.zig:1357, 1359, 1399, 1400, 2478, 2481, 2483, 2489, 2490 all
// discarded an allocation error with `catch {}`, so an OOM mid-assembly
// silently TRUNCATED a statement or a chunk and then executed the corrupted
// remainder.  That path cannot be driven from a subprocess: it needs a
// failing allocator, which needed the statement-assembly loop lifted out of
// `cmdQuery`.  The seam now exists (src/cli/query_file.zig), and the
// failing-allocator cases specified for it live at the bottom of this file —
// they need no server.
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

// ---------------------------------------------------------------------
// #830 ROLLBACK-guard fixture: an oversized BEGIN … ROLLBACK/COMMIT block.
// ---------------------------------------------------------------------
// The pre-scan in executeChunkedQueries (src/cli/main.zig:2347-2423) measures
// every BEGIN…COMMIT/ROLLBACK block; a block whose byte total exceeds the 32KB
// chunk limit (:2338, :2376) cannot ride a single QUIC connection, so the
// wrappers are stripped and the inner writes auto-commit.  For a COMMIT
// terminator that strip IS the intended behaviour (:2347-2352); for a ROLLBACK
// terminator it is silent data corruption, so the code is SUPPOSED to refuse
// with error.TransactionTooLargeForChunkedRollback (:2389-2397).
//
// The inline `ends_with_rollback` re-check (:2384-2388) trims WHITESPACE ONLY
// then compares `eqlIgnoreCase(last, "ROLLBACK")`.  A file-assembled statement
// keeps its trailing `;` (src/cli/query_file.zig:61), so `"ROLLBACK;"` never
// equals `"ROLLBACK"`, the guard misses, and the block falls through to the
// COMMIT-strip branch that AUTO-COMMITS the writes the user asked to roll back.

/// CREATEs inside the BEGIN…terminator block.  Sized so the block itself clears
/// the 32KB chunk limit (each padded CREATE is ~65 bytes; 800×65 ≈ 52KB), which
/// is the precondition for the pre-scan's `txn_bytes > max_chunk_size` branch.
const txn_stmt_count: usize = 800;

/// Build `BEGIN;` + `txn_stmt_count` CREATEs on `label` + `terminator`, one
/// statement per line.  `terminator` is written verbatim (e.g. "ROLLBACK;",
/// "COMMIT;", or a bare "ROLLBACK" with no semicolon) so a test can exercise
/// each terminator spelling the assembler will produce.  Caller owns the slice.
fn buildTxnGql(
    aa: std.mem.Allocator,
    label: []const u8,
    terminator: []const u8,
) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(aa);
    var line: [256]u8 = undefined;
    try buf.appendSlice(aa, "BEGIN;\n");
    for (0..txn_stmt_count) |i| {
        const rendered = try std.fmt.bufPrint(
            &line,
            "CREATE (n:{s} {{i: {d}, pad: 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'}});\n",
            .{ label, i },
        );
        try buf.appendSlice(aa, rendered);
    }
    try buf.appendSlice(aa, terminator);
    try buf.append(aa, '\n');
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

// =====================================================================
// #830 — the ROLLBACK-guard bypass: an oversized BEGIN…ROLLBACK block must
// be REFUSED, never silently auto-committed.
// =====================================================================
// PRIMARY (the reported corruption).  RED at HEAD: the inline
// `ends_with_rollback` re-check (src/cli/main.zig:2384-2388) trims whitespace
// only, so `"ROLLBACK;"` != `"ROLLBACK"`, the guard misses, the COMMIT-strip
// branch (:2402-2408) runs, all 800 CREATEs auto-commit, and the CLI exits 0.
// Observed at HEAD: exit 0, MATCH (n:RbTest) count = 800 (expected 0).
//
// Contract (green after fix): the block is refused BEFORE any chunk is shipped
// — the guard returns error.TransactionTooLargeForChunkedRollback from the
// pre-scan (:2389-2397).  cmdQuery catches that error at the executeChunkedQueries
// call site and maps it to ExitCode.general_error = 1 (the same code the sibling
// "a chunk failed" path uses), after printing an actionable refusal message.  So
// the two hard clauses pinned here are:
//   1. the process exits with EXACTLY 1 (ExitCode.general_error), and
//   2. exactly ZERO :RbTest nodes persist (nothing was committed).
// Both are RED now (exit 0, count 800) and clean-GREEN once the guard fires.
test "geode query --file refuses an oversized BEGIN...ROLLBACK; block instead of silently committing it (#830)" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "rollback-guard", 4811, true)) orelse return error.SkipZigTest;
    defer fx.deinit();

    const content = try buildTxnGql(fx.aa(), "RbTest", "ROLLBACK;");
    // The block itself must exceed the 32KB chunk limit, else the pre-scan
    // keeps it intact and the guard never runs.
    try testing.expect(content.len > 32 * 1024);
    const path = try fx.writeGqlFile("rollback_big.gql", content);

    const arg = try std.fmt.allocPrint(fx.aa(), "--file {s}", .{path});
    const code = blk: {
        var p = try fx.runQuery(arg);
        defer p.deinit();
        const c = p.waitExit(cli_deadline_ms) orelse {
            p.dump("rollback file client (never exited)");
            return error.FileClientHung;
        };
        // Guard: the fixture really did take the chunked path.
        if (!p.saw("using chunked execution")) {
            p.dump("rollback file client (never entered chunked execution)");
            return error.FixtureDidNotChunk;
        }
        if (c == 0) {
            std.debug.print(
                "\n#830 VIOLATION: `--file` exited 0 on a >32KB BEGIN…ROLLBACK; block.\n" ++
                    "  The inline `ends_with_rollback` re-check (src/cli/main.zig:2384-2388)\n" ++
                    "  trims whitespace only, so the file-assembled \"ROLLBACK;\" (trailing `;`\n" ++
                    "  kept by src/cli/query_file.zig:61) never equals \"ROLLBACK\"; the guard\n" ++
                    "  misses and the COMMIT-strip branch (:2402-2408) auto-commits the writes\n" ++
                    "  the user asked to roll back.  Expected a nonzero exit\n" ++
                    "  (error.TransactionTooLargeForChunkedRollback).\n",
                .{},
            );
        }
        break :blk c;
    };

    // The read-back runs on a FRESH connection, so anything it sees was actually
    // committed rather than merely rendered.
    const persisted = (try readBackCount(&fx, "RbTest")) orelse
        return error.ReadBackReturnedNoRow;

    var violations: usize = 0;
    // Tightened from "nonzero" to the exact code the fixer settled on: the
    // pre-send refusal is caught in cmdQuery (src/cli/main.zig, the
    // executeChunkedQueries call site) and mapped to ExitCode.general_error = 1,
    // matching the sibling "a chunk failed" path.
    if (code != 1) {
        std.debug.print(
            "\n#830 VIOLATION: `--file` exited {d} on a >32KB BEGIN…ROLLBACK; block;\n" ++
                "  expected 1 (ExitCode.general_error) — the oversized-rollback refusal is\n" ++
                "  caught at the executeChunkedQueries call site and mapped to general_error.\n",
            .{code},
        );
        violations += 1;
    }
    if (persisted != 0) {
        std.debug.print(
            "\n#830 VIOLATION (silent data corruption): {d} :RbTest nodes persisted after a\n" ++
                "  BEGIN…ROLLBACK; block — the ROLLBACK was silently converted to a COMMIT.\n" ++
                "  Expected 0: the oversized-rollback block must be refused before any chunk\n" ++
                "  is shipped, so nothing is ever committed.\n",
            .{persisted},
        );
        violations += 1;
    }
    if (violations > 0) return error.OversizedRollbackSilentlyCommitted;
}

// ---------------------------------------------------------------------
// CONTROL (regression guard, PASSES at HEAD and must stay green): an
// oversized BEGIN…COMMIT block IS designed to strip its wrappers and
// auto-commit (src/cli/main.zig:2347-2352, :2398-2408).
// ---------------------------------------------------------------------
// This proves the fix does not over-refuse: only ROLLBACK is refused; a large
// COMMIT-terminated transaction still strips + auto-commits every inner write.
test "geode query --file auto-commits an oversized BEGIN...COMMIT; block (chunked strip is intended)" {
    const gpa = testing.allocator;
    var fx = (try setUp(gpa, "commit-strip", 4812, true)) orelse return error.SkipZigTest;
    defer fx.deinit();

    const content = try buildTxnGql(fx.aa(), "RbCommit", "COMMIT;");
    try testing.expect(content.len > 32 * 1024);
    const path = try fx.writeGqlFile("commit_big.gql", content);

    const arg = try std.fmt.allocPrint(fx.aa(), "--file {s}", .{path});
    {
        var p = try fx.runQuery(arg);
        defer p.deinit();
        const code = p.waitExit(cli_deadline_ms) orelse {
            p.dump("commit file client (never exited)");
            return error.FileClientHung;
        };
        if (!p.saw("using chunked execution")) {
            p.dump("commit file client (never entered chunked execution)");
            return error.FixtureDidNotChunk;
        }
        if (code != 0) {
            p.dump("commit file client (oversized COMMIT block was refused)");
            std.debug.print(
                "\nCONTROL VIOLATION: an oversized BEGIN…COMMIT; block exited {d}; the chunked\n" ++
                    "  path is DESIGNED to strip its wrappers and auto-commit these writes\n" ++
                    "  (src/cli/main.zig:2347-2352).  A fix for the ROLLBACK guard must not\n" ++
                    "  over-refuse the legitimate COMMIT case.\n",
                .{code},
            );
            return error.OversizedCommitOverRefused;
        }
    }

    const persisted = (try readBackCount(&fx, "RbCommit")) orelse
        return error.ReadBackReturnedNoRow;
    try testing.expectEqual(@as(i64, @intCast(txn_stmt_count)), persisted);
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
// 2d — swallowed allocation failures, now driven for real.
// =====================================================================
// The nine `catch {}` sites in the statement-assembly and chunk-building
// loops (src/cli/main.zig:1357, 1359, 1399, 1400, 2478, 2481, 2483, 2489,
// 2490) turned an allocation failure into a SILENTLY TRUNCATED statement that
// was then executed.  Driving that needs a failing allocator, which needed the
// loop lifted out of `cmdQuery`: it now lives in src/cli/query_file.zig, which
// imports nothing but std and is wired into this lane as the `cli_query_file`
// module (build.zig).  The chunk builder propagates `try`, and every remaining
// `--file` allocation site in `cmdQuery` exits with a message.
const cli = @import("cli_query_file");

test "assembleStatements is fatal on allocation failure (2d)" {
    const src =
        \\CREATE (n:A {p: 'one'});
        \\CREATE (n:B {p: 'two'});
        \\
    ;
    // Fail every allocation after the Nth so the failure lands MID
    // statement, which is exactly the truncation shape the old
    // `catch {}` hid.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 3 });
    try testing.expectError(
        error.OutOfMemory,
        cli.assembleStatements(failing.allocator(), src),
    );
}

test "assembleStatements never returns a truncated statement (2d)" {
    // Sweep the fail index across the whole allocation sequence: for
    // EVERY index the call must either return the complete statement
    // list or return error.OutOfMemory — never a short/partial one.
    const src = "CREATE (n:A {p: 'one'});\nCREATE (n:B {p: 'two'});\n";
    var idx: usize = 0;
    while (idx < 64) : (idx += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = idx });
        const res = cli.assembleStatements(failing.allocator(), src) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        defer cli.freeStatements(failing.allocator(), res);
        try testing.expectEqual(@as(usize, 2), res.len);
        try testing.expect(std.mem.endsWith(u8, res[0], ";"));
        try testing.expect(std.mem.endsWith(u8, res[1], ";"));
    }
}

test "assembleStatements joins continuation lines and drops comments (2d)" {
    const src =
        \\-- a comment
        \\# another comment
        \\CREATE (n:A {p: 'one'});
        \\
        \\CREATE (n:B
        \\  {p: 'two'});
        \\RETURN 3
        \\
    ;
    const stmts = try cli.assembleStatements(testing.allocator, src);
    defer cli.freeStatements(testing.allocator, stmts);
    // The unterminated trailing fragment is dropped, as it always was.
    try testing.expectEqual(@as(usize, 2), stmts.len);
    try testing.expectEqualStrings("CREATE (n:A {p: 'one'});", stmts[0]);
    try testing.expectEqualStrings("CREATE (n:B {p: 'two'});", stmts[1]);
}

// =====================================================================
// #830 — the guard predicate.  UNIT-testable seam.
// =====================================================================
// The fix must make the inline `ends_with_rollback` re-check
// (src/cli/main.zig:2384-2388) semicolon-tolerant the same way the sibling
// helpers isTransactionBegin/isTransactionEnd (:2782-2801) already are —
// `std.mem.trimEnd(u8, trimmed, "; \t")` then `eqlIgnoreCase`.  The natural,
// server-free place for that logic is a `pub fn isRollback` on the std-only
// src/cli/query_file.zig seam this lane already imports as `cli_query_file`
// (main.zig imports the same module at src/cli/main.zig:119), so the inline
// guard can call `query_file.isRollback(last)`.
//
// FIXER SEAM CONTRACT:
//   pub fn isRollback(stmt: []const u8) bool   // in src/cli/query_file.zig
//     - whitespace- AND semicolon-tolerant, case-insensitive
//     - true  for: "ROLLBACK", "ROLLBACK;", "ROLLBACK ;", "  ROLLBACK ;  ",
//                   "rollback;", "RollBack;"
//     - false for: "COMMIT;", "ROLLBACKS;", "ROLL BACK;", any CREATE
//
// Uses the `@hasDecl` guard-sentinel pattern (see
// tests/test_geode875_incremental_index.zig): a clean, named RED now (the seam
// does not exist), the real classification assertions once the fixer adds it.
test "#830 isRollback classifies every ROLLBACK spelling the assembler emits (guard predicate)" {
    if (comptime @hasDecl(cli, "isRollback")) {
        // Terminators the file assembler actually produces / an operator writes.
        const rollbacks = [_][]const u8{
            "ROLLBACK",
            "ROLLBACK;",
            "ROLLBACK ;",
            "  ROLLBACK ;  ",
            "rollback;",
            "RollBack;",
        };
        for (rollbacks) |s| {
            if (!cli.isRollback(s)) {
                std.debug.print(
                    "\n#830 VIOLATION: isRollback(\"{s}\") = false; every ROLLBACK spelling\n" ++
                        "  (with/without `;`, any case, surrounding whitespace) must classify as\n" ++
                        "  ROLLBACK so the oversized-transaction guard fires on the assembled form.\n",
                    .{s},
                );
                return error.RollbackSpellingMisclassified;
            }
        }
        // Must NOT match COMMIT, a near-miss keyword, a split keyword, or a write.
        const non_rollbacks = [_][]const u8{
            "COMMIT;",
            "ROLLBACKS;",
            "ROLL BACK;",
            "CREATE (n:RbTest {i: 0});",
        };
        for (non_rollbacks) |s| {
            if (cli.isRollback(s)) {
                std.debug.print(
                    "\n#830 VIOLATION: isRollback(\"{s}\") = true; only a bare ROLLBACK terminator\n" ++
                        "  may match — COMMIT, ROLLBACKS, ROLL BACK, and CREATEs must not, or the\n" ++
                        "  guard would over-refuse legitimate transactions.\n",
                    .{s},
                );
                return error.NonRollbackMisclassified;
            }
        }
    } else {
        // FIXER SEAM REQUIRED: extract the semicolon-tolerant ROLLBACK test into
        // `pub fn isRollback(stmt: []const u8) bool` on src/cli/query_file.zig and
        // call it from the inline guard at src/cli/main.zig:2384-2388 (replacing
        // the whitespace-only `std.mem.trim` + `eqlIgnoreCase(last, "ROLLBACK")`).
        return error.IsRollbackSeamMissing;
    }
}

// ---------------------------------------------------------------------
// #830 SECONDARY (documented known gap, asserts CURRENT behaviour): the
// assembler DROPS a bare no-`;` ROLLBACK terminator.
// ---------------------------------------------------------------------
// src/cli/query_file.zig:61 only completes a statement when its last line ends
// with `;`, so a file whose transaction is terminated by a bare `ROLLBACK`
// (no semicolon) loses the terminator entirely.  The pre-scan then finds no
// isTransactionEnd, treats the LAST inner CREATE as the block terminator, and
// (via the COMMIT-strip branch) strips it — leaving count = N-1 committed.
//
// The guard-normalization fix (isRollback) does NOT reach this input, because
// the terminator is dropped before the guard ever sees it.  So this is pinned
// as a KNOWN-GAP tripwire on the CURRENT assembler behaviour, NOT as a
// refuse-count-0 contract.  A follow-up that makes src/cli/query_file.zig:61
// preserve a no-`;` terminator would flip this test and should update it (and
// then the e2e refusal contract above would extend to cover the no-`;` form).
test "#830 SECONDARY: assembleStatements drops a bare no-semicolon ROLLBACK terminator (known gap)" {
    const src =
        \\BEGIN;
        \\CREATE (n:RbNoSemi {i: 0});
        \\CREATE (n:RbNoSemi {i: 1});
        \\ROLLBACK
        \\
    ;
    const stmts = try cli.assembleStatements(testing.allocator, src);
    defer cli.freeStatements(testing.allocator, stmts);

    // Current behaviour: BEGIN; + 2 CREATEs = 3 statements; the bare ROLLBACK is
    // dropped.  If this ever becomes 4 (terminator preserved), the assembler gap
    // was fixed — update this test AND extend the e2e refusal to the no-`;` form.
    try testing.expectEqual(@as(usize, 3), stmts.len);
    try testing.expectEqualStrings("BEGIN;", stmts[0]);
    // The last surviving statement is a CREATE, NOT the intended ROLLBACK
    // terminator — this is exactly the fragment the pre-scan mis-strips as the
    // block's "COMMIT", corrupting the rolled-back data.
    try testing.expect(!std.mem.startsWith(u8, stmts[stmts.len - 1], "ROLLBACK"));
    try testing.expectEqualStrings("CREATE (n:RbNoSemi {i: 1});", stmts[stmts.len - 1]);
}
