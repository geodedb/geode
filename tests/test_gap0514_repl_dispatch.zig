// GAP-0514 Phase 6 P1: real end-to-end regression coverage for the
// src/client/repl/repl_dispatch.zig CANARY hotspot.
//
// Every test here drives the REAL public REPL client surface
// (ClientSession over the QUIC transport against a spawned
// ./zig-out/bin/geode server, or the module-level executeSourceFile /
// executeGql generic entry points with the same state shape repl_loop
// uses).  No mocks, no simulated server responses.
//
// Interrupt lanes are driven through the real signal flag
// (geode.repl.platform.sigint_received) that the SIGINT handler sets in
// production; checkForInterrupt() consumes exactly that flag.  Each
// interrupt-checking loop in repl_dispatch checks the flag BEFORE its
// first blocking read, so pre-arming the flag drives those lanes
// deterministically.
//
// CANARY: REQ=REQ-GAP-0514-REPL-DISPATCH; FEATURE="CanaryReconciliation"; ASPECT=ReplDispatchRegression; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const repl_util = @import("repl_test_util.zig");
const proto_util = @import("proto_test_util.zig");

const repl_dispatch = geode.repl.repl_dispatch;
const repl_loop = geode.repl.repl_loop;
const platform = geode.repl.platform;
const spinner_mod = geode.repl.spinner;

/// Minimal REPL state satisfying the duck-typed `state: anytype` contract of
/// executeGql / executeSourceFile / handleConnectionError.  Mirrors the field
/// subset of repl_loop.ReplState that those functions touch.
const TestReplState = struct {
    allocator: std.mem.Allocator,
    format: repl_loop.ReplLoop.Format = .json,
    verbose: bool = false,
    show_timing: bool = false,
    session: *repl_dispatch.ClientSession,
    current_graph: ?[]const u8 = null,
    suppress_output: bool = false,
    in_txn: bool = false,
    quit_requested: bool = false,
};

// Zig 0.16: std.Thread.sleep was removed — linux nanosleep compat shim.
fn compatSleep(ns: u64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

/// Redirect REPL display output to /dev/null for the duration of a test.
/// The zig build runner multiplexes its control protocol over this test
/// binary's stdout; the real REPL display path (executeSourceFile /
/// executeGql) writes raw bytes to stdout and would corrupt that protocol.
/// Returns the file to close in the paired `restoreReplStdout`.
fn silenceReplStdout() !std.Io.File {
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    const f = try std.Io.Dir.cwd().createFile(io_fs, "/dev/null", .{});
    platform.stdout_override = f;
    return f;
}

fn restoreReplStdout(f: std.Io.File) void {
    platform.stdout_override = null;
    f.close(std.Io.Threaded.global_single_threaded.io());
}

fn armSigint() void {
    platform.sigint_received.store(true, .seq_cst);
}

fn disarmSigint() void {
    platform.clearSigint();
}

/// Connect at the transport level WITHOUT performing any HELLO handshake.
/// Used by the hello()/helloWithAuth() lane tests.
fn connectTransportOnly(allocator: std.mem.Allocator, addr: []const u8) !repl_dispatch.ClientSession {
    geode.repl.quic_transport.setTlsConfig(.{ .insecure = true });
    var session = try repl_dispatch.ClientSession.init(
        allocator,
        addr,
        &geode.repl.quic_transport.transport,
    );
    errdefer session.deinit();

    var attempts: usize = 0;
    while (attempts < 40) : (attempts += 1) {
        if (attempts > 0) compatSleep(50 * std.time.ns_per_ms);
        session.connect() catch |err| {
            if (err == error.ConnectionRefused or err == error.WouldBlock) continue;
            return err;
        };
        return session;
    }
    return error.ConnectionFailed;
}

/// Run a row-returning query and collect its rows through the real
/// consumption path (runGql + pullAll, which merges the inline page and
/// issues PULLs as needed), then return rows[0][0] as an integer.
fn queryFirstRowInt(allocator: std.mem.Allocator, session: *repl_dispatch.ClientSession, gql: []const u8) !i64 {
    try session.runGql(gql);
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(allocator);
    try session.pullAll(&sink);
    return firstRowInt(allocator, sink.items);
}

/// Parse the integer in rows[0][0] of a client-side response JSON
/// (the shape produced by executionResponseToJson / pullAll).
fn firstRowInt(allocator: std.mem.Allocator, response: []const u8) !i64 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const rows = parsed.value.object.get("rows") orelse return error.NoRows;
    if (rows.array.items.len == 0) return error.EmptyRows;
    const first = rows.array.items[0];
    const cell = switch (first) {
        .array => |arr| if (arr.items.len > 0) arr.items[0] else return error.EmptyRow,
        // pullAll emits each row as an object keyed by column name
        // (rowToJsonArray); take the first column's value.
        .object => |obj| blk: {
            var it = obj.iterator();
            const entry = it.next() orelse return error.EmptyRow;
            break :blk entry.value_ptr.*;
        },
        else => first,
    };
    return switch (cell) {
        .integer => |v| v,
        .string => |s| try std.fmt.parseInt(i64, s, 10),
        .float => |f| @intFromFloat(f),
        else => error.UnexpectedCellType,
    };
}

fn writeTextFile(path: []const u8, contents: []const u8) !void {
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().createFile(io_fs, path, .{});
    defer file.close(io_fs);
    try file.writeStreamingAll(io_fs, contents);
}

fn deleteFileQuiet(path: []const u8) void {
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteFile(io_fs, path) catch {};
}

// ---------------------------------------------------------------------------
// REQ-SHELL-INTERRUPT-036 (SignalBasedInterrupt) +
// REQ-SHELL-PLAIN-009 (InterruptCheckTTY)
// ---------------------------------------------------------------------------
test "checkForInterrupt: signal flag is consumed; piped (non-TTY) stdin relies on the flag only" {
    disarmSigint();
    defer disarmSigint();
    const devnull = try silenceReplStdout();
    defer restoreReplStdout(devnull);

    // Plain/piped mode (test stdin is not a TTY): with no signal pending,
    // checkForInterrupt must return false WITHOUT consuming stdin.
    try testing.expect(!repl_dispatch.checkForInterrupt());

    // Signal-based lane: the SIGINT flag alone must trigger the interrupt
    // even with non-TTY stdin, and the check must clear the flag (swap).
    armSigint();
    try testing.expect(repl_dispatch.checkForInterrupt());
    try testing.expect(!platform.wasSigintReceived());
    try testing.expect(!repl_dispatch.checkForInterrupt());
}

// ---------------------------------------------------------------------------
// REQ-SHELL-AUTH-001 (HelloAuthCheck), REQ-SHELL-INTERRUPT-016 (HelloInterrupt),
// REQ-SHELL-INTERRUPT-017 (HelloAuthInterrupt)
// ---------------------------------------------------------------------------
test "hello: unauthenticated HELLO is rejected on an auth-required server; SIGINT aborts hello and helloWithAuth" {
    const allocator = testing.allocator;
    disarmSigint();
    defer disarmSigint();
    const devnull = try silenceReplStdout();
    defer restoreReplStdout(devnull);

    var server = try repl_util.startServer(allocator);
    defer server.deinit();
    try proto_util.waitForServerReady(allocator, server.addr, 30000);

    // Unauthenticated hello() against a server with auth enabled (the test
    // fixture always configures admin credentials) must fail with an
    // authentication error, never succeed.
    {
        var session = try connectTransportOnly(allocator, server.addr);
        defer session.deinit();
        const result = session.hello();
        try testing.expectError(error.AuthenticationRequired, result);
    }

    // Pre-armed SIGINT must abort hello() before its first blocking read.
    {
        var session = try connectTransportOnly(allocator, server.addr);
        defer session.deinit();
        armSigint();
        try testing.expectError(error.Interrupted, session.hello());
        disarmSigint();
    }

    // Same lane for the authenticated HELLO.  Unlike hello(), the
    // authenticated handshake reports the interrupt as a failed
    // AuthHelloResult with a user-facing message (the REPL prints it),
    // not as error.Interrupted.
    {
        var session = try connectTransportOnly(allocator, server.addr);
        defer session.deinit();
        armSigint();
        const result = try session.helloWithAuth(
            proto_util.defaultUsername(),
            proto_util.defaultPassword(),
        );
        disarmSigint();
        defer if (result.error_message) |m| allocator.free(m);
        defer if (result.session_token) |t| allocator.free(t);
        try testing.expect(!result.success);
        try testing.expect(result.error_message != null);
        try testing.expect(std.mem.indexOf(u8, result.error_message.?, "interrupted") != null);
    }
}

// ---------------------------------------------------------------------------
// REQ-SHELL-INTERRUPT-035 (DisconnectForRollback),
// REQ-INLINE-RESULTS-001 (SchemaResponseFlag),
// REQ-INLINE-RESULTS-003 (ConsumeInlinePage),
// REQ-INLINE-RESULTS-006 (ConsumeAfterSchema),
// REQ-SHELL-INTERRUPT-039 (ThreadedRead)
// ---------------------------------------------------------------------------
test "session: back-to-back queries do not desync the protocol (inline page consumed); disconnect clears session state" {
    const allocator = testing.allocator;
    disarmSigint();
    defer disarmSigint();
    const devnull = try silenceReplStdout();
    defer restoreReplStdout(devnull);

    var server = try repl_util.startServer(allocator);
    defer server.deinit();
    // The threaded-read path lazily creates a process-global background pool
    // with this test's allocator; tear it down before the leak check.
    defer repl_dispatch.deinitBackgroundPool();

    var session = try repl_util.connectSession(allocator, server.addr);
    defer session.deinit();

    // First row-returning query.  runGql goes through the threaded-read
    // path (worker thread blocking read + main-thread interrupt polling) and
    // must consume the inline page that follows the schema response.
    try session.runGql("RETURN 1 AS x");
    try testing.expect(!session.received_schema_response);
    try testing.expect(session.last_response != null);

    // Second query immediately after: if the inline page of query #1 had
    // been left unread this would observe a protocol mismatch / stale page.
    try session.runGql("RETURN 42 AS y");
    try testing.expect(!session.received_schema_response);
    // Collect query #2's rows through the real consumption path (pullAll
    // merges the consumed inline page).  A stale page from query #1 would
    // yield 1 here instead of 42.
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(allocator);
    try session.pullAll(&sink);
    try testing.expectEqual(@as(i64, 42), try firstRowInt(allocator, sink.items));

    // disconnect() must drop the connection and clear per-connection state
    // so the server can roll back any in-flight transaction.
    session.disconnect();
    try testing.expect(!session.connected);
    try testing.expect(session.connection == null);
    try testing.expect(session.session_id == null);
    try testing.expect(session.last_response == null);
    try testing.expect(session.inline_page_response == null);
}

// ---------------------------------------------------------------------------
// REQ-SHELL-INTERRUPT-013 (BeginInterrupt),
// REQ-SHELL-TXN-ERROR-001 (ErrorMessage),
// REQ-SHELL-TXN-ERROR-002 (CommitWithRetry),
// REQ-SHELL-TXN-ERROR-003 (RollbackWithRetry),
// REQ-SHELL-INTERRUPT-014 (RollbackDoubleInterrupt, first-press lane),
// REQ-SHELL-INTERRUPT-026 (RollbackScaledTimeout),
// REQ-SHELL-INTERRUPT-023 (DrainWithTimeout, stale-data discard lane)
// ---------------------------------------------------------------------------
test "transactions: happy commit/rollback, interrupt lanes set last_txn_error, scaled rollback timeout, stale drain" {
    const allocator = testing.allocator;
    disarmSigint();
    defer disarmSigint();
    const devnull = try silenceReplStdout();
    defer restoreReplStdout(devnull);

    var server = try repl_util.startServer(allocator);
    defer server.deinit();
    defer repl_dispatch.deinitBackgroundPool();

    var session = try repl_util.connectSession(allocator, server.addr);
    defer session.deinit();

    // Happy path: BEGIN -> CREATE -> COMMIT (drives the WouldBlock retry
    // loops in begin/commit to their success lanes).
    try session.begin();
    try session.runGql("CREATE (:Gap0514Txn {seq: 1})");
    try session.commit();
    try testing.expect(session.last_txn_error == null);

    // Interrupted COMMIT: must surface error.Interrupted and record the
    // user-facing detail message in last_txn_error.
    try session.begin();
    armSigint();
    try testing.expectError(error.Interrupted, session.commit());
    disarmSigint();
    try testing.expect(session.last_txn_error != null);
    try testing.expect(std.mem.indexOf(u8, session.last_txn_error.?, "cancelled") != null);
    // The COMMIT was sent before the interrupt; its response is now stale
    // data on the connection.  drain must discard it (DrainWithTimeout).
    // Limit 1: exactly one response is in flight, and a quiet-connection
    // iteration costs 20 polls x the 30 s transport idle timeout.
    const drained_commit = session.drainWithLimit(1, false);
    try testing.expectEqual(@as(usize, 1), drained_commit);

    // Interrupted BEGIN: the read loop checks the flag before its first read.
    armSigint();
    try testing.expectError(error.Interrupted, session.begin());
    disarmSigint();
    _ = session.drainWithLimit(1, false); // discard the stale BEGIN response

    // Rollback first-press safety: a single Ctrl+C during rollback must NOT
    // cancel it — it warns and keeps waiting, and the rollback completes.
    try session.begin();
    try session.runGql("CREATE (:Gap0514Txn {seq: 2})");
    armSigint();
    try session.rollback();
    disarmSigint();
    try testing.expect(session.last_txn_error == null);

    // Scaled rollback timeout: max_retries=0 exhausts the retry budget
    // immediately and must surface the stale-connection detail message.
    try testing.expectError(error.WouldBlock, session.rollbackWithTimeout(0));
    try testing.expect(session.last_txn_error != null);
    try testing.expect(std.mem.indexOf(u8, session.last_txn_error.?, "timed out") != null);
    _ = session.drainWithLimit(1, false); // discard the late ROLLBACK response
}

// ---------------------------------------------------------------------------
// REQ-SHELL-INTERRUPT-023 (DrainWithTimeout),
// REQ-SHELL-INTERRUPT-024 (DrainForRollback, interrupt-aware drainWithLimit),
// REQ-SHELL-INTERRUPT-025 (DrainAllForRollback),
// REQ-SHELL-INTERRUPT-033 (DrainWithSpinner)
// ---------------------------------------------------------------------------
test "drain: quiet-connection timeout lanes and interrupt lanes" {
    const allocator = testing.allocator;
    disarmSigint();
    defer disarmSigint();
    const devnull = try silenceReplStdout();
    defer restoreReplStdout(devnull);

    var server = try repl_util.startServer(allocator);
    defer server.deinit();
    defer repl_dispatch.deinitBackgroundPool();

    var session = try repl_util.connectSession(allocator, server.addr);
    defer session.deinit();

    // The quiet-connection lanes below each wait out the transport's rolling
    // idle timeout (20 polls per drained message).  Shorten it to test scale
    // AFTER the HELLO handshake so the timeout lanes finish in seconds, not
    // 20 x 30 s per message.  This tunes a real production timeout, it does
    // not stub the read path.
    const saved_idle_timeout = geode.repl.quic_transport.read_idle_timeout_ms;
    geode.repl.quic_transport.read_idle_timeout_ms = 100;
    defer geode.repl.quic_transport.read_idle_timeout_ms = saved_idle_timeout;

    // Quiet connection: drain must time out per message and report 0.
    try testing.expectEqual(@as(usize, 0), session.drainWithLimit(1, false));

    // Interrupt-aware drain: a pending SIGINT stops draining immediately.
    armSigint();
    try testing.expectEqual(@as(usize, 0), session.drainWithLimit(2, true));
    disarmSigint();

    // Aggressive pre-rollback drain: quiet connection ends after the
    // consecutive-empty threshold with 0 drained.
    const stderr = platform.getStderrHandle();
    const drained = try session.drainForRollback(4, stderr);
    try testing.expectEqual(@as(usize, 0), drained);

    // First Ctrl+C during the aggressive drain warns and CONTINUES (does not
    // error); the quiet connection then ends the drain normally.
    armSigint();
    const drained_after_press = try session.drainForRollback(4, stderr);
    disarmSigint();
    try testing.expectEqual(@as(usize, 0), drained_after_press);

    // Time-limited spinner drain: quiet connection stops after 3 empty reads.
    var spin = spinner_mod.Spinner.init(allocator, "gap0514 drain");
    const drained_spinner = try session.drainForRollbackWithSpinner(0, &spin);
    if (spin.isRunning()) spin.stop(null);
    try testing.expectEqual(@as(usize, 0), drained_spinner);
}

// ---------------------------------------------------------------------------
// REQ-SOURCE-CHUNKED-001/002/003/004/006 (REPL \source chunked execution),
// REQ-SHELL-INTERRUPT-015 (PullAllInterrupt),
// REQ-SHELL-INTERRUPT-018 (ParsingInterrupt),
// REQ-SOURCE-PERF-001/002 (FileHashCache + cleanup),
// REQ-SHELL-SOURCE-ERROR-001 (BatchErrorExtraction)
// ---------------------------------------------------------------------------
test "executeSourceFile: small batch path, re-source tracking, error extraction" {
    const allocator = testing.allocator;
    disarmSigint();
    defer disarmSigint();
    const devnull = try silenceReplStdout();
    defer restoreReplStdout(devnull);
    // Own the global sourced-file cache lifecycle for this test.
    repl_dispatch.deinitSourcedFileCache();
    defer repl_dispatch.deinitSourcedFileCache();

    var server = try repl_util.startServer(allocator);
    defer server.deinit();
    defer repl_dispatch.deinitBackgroundPool();

    var session = try repl_util.connectSession(allocator, server.addr);
    defer session.deinit();

    var state = TestReplState{ .allocator = allocator, .session = &session };

    const label = "Gap0514Small";
    const small_path = ".zig-cache/tmp/gap0514_small.gql";
    defer deleteFileQuiet(small_path);
    {
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(allocator);
        try content.appendSlice(allocator, "-- gap0514 small source file\n");
        try content.appendSlice(allocator, "# hash-style comment\n\n");
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            try content.appendSlice(allocator, "CREATE (:");
            try content.appendSlice(allocator, label);
            const stmt = try std.fmt.allocPrint(allocator, " {{i: {d}}});\n", .{i});
            defer allocator.free(stmt);
            try content.appendSlice(allocator, stmt);
        }
        try writeTextFile(small_path, content.items);
    }

    // Small file (< 32KB): single-batch path.
    try repl_dispatch.executeSourceFile(&state, small_path);
    try testing.expectEqual(@as(i64, 3), try queryFirstRowInt(allocator, &session, "MATCH (n:" ++ label ++ ") RETURN count(n) AS c"));

    // Re-source the identical file: drives the FileHashCache hit lane
    // (already-sourced warning) and the statements execute again.
    try repl_dispatch.executeSourceFile(&state, small_path);
    try testing.expectEqual(@as(i64, 6), try queryFirstRowInt(allocator, &session, "MATCH (n:" ++ label ++ ") RETURN count(n) AS c"));

    // Error file: the batch executes server-side and fails; the error status
    // must land in last_response and extractServerErrorMessage must be able
    // to pull a human-readable detail out of it (BatchErrorExtraction).
    const err_path = ".zig-cache/tmp/gap0514_error.gql";
    defer deleteFileQuiet(err_path);
    try writeTextFile(err_path, "THIS IS NOT VALID GQL AT ALL;\n");
    try repl_dispatch.executeSourceFile(&state, err_path);
    try testing.expect(session.last_response != null);
    const resp = session.last_response.?;
    const has_error_class = std.mem.indexOf(u8, resp, "\"status_class\":\"4") != null or
        std.mem.indexOf(u8, resp, "\"status_class\":\"5") != null;
    try testing.expect(has_error_class);
    const extracted = repl_dispatch.extractServerErrorMessage(allocator, resp);
    try testing.expect(extracted != null);
    allocator.free(extracted.?);

    // REQ-SHELL-INTERRUPT-018 (ParsingInterrupt): a pending SIGINT is honored
    // during the parse pass (checked every 10 lines) BEFORE anything is sent
    // to the server — none of the file's statements may execute.
    const parse_label = "Gap0514ParseInt";
    const parse_path = ".zig-cache/tmp/gap0514_parse_interrupt.gql";
    defer deleteFileQuiet(parse_path);
    {
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(allocator);
        var j: usize = 0;
        while (j < 25) : (j += 1) {
            try content.appendSlice(allocator, "CREATE (:" ++ parse_label ++ " {i: 1});\n");
        }
        try writeTextFile(parse_path, content.items);
    }
    armSigint();
    try repl_dispatch.executeSourceFile(&state, parse_path);
    disarmSigint();
    try testing.expectEqual(@as(i64, 0), try queryFirstRowInt(allocator, &session, "MATCH (n:" ++ parse_label ++ ") RETURN count(n) AS c"));

    // Explicit cache cleanup (FileHashCacheCleanup): frees all key strings.
    // testing.allocator leak detection verifies nothing is leaked, which
    // also proves the cache actually stored the sourced-file entries.
    repl_dispatch.deinitSourcedFileCache();
}

test "executeSourceFile: >32KB file takes the chunked execution path; pullAll interrupt during PULL" {
    const allocator = testing.allocator;
    disarmSigint();
    defer disarmSigint();
    const devnull = try silenceReplStdout();
    defer restoreReplStdout(devnull);
    repl_dispatch.deinitSourcedFileCache();
    defer repl_dispatch.deinitSourcedFileCache();

    var server = try repl_util.startServer(allocator);
    defer server.deinit();
    defer repl_dispatch.deinitBackgroundPool();

    var session = try repl_util.connectSession(allocator, server.addr);
    defer session.deinit();

    var state = TestReplState{ .allocator = allocator, .session = &session };

    // 1100 statements x ~90 bytes ≈ 99KB total batch — well above the 32KB
    // chunking threshold, and 1100 rows is above the server's default
    // inline-page cap (1000) so the later MATCH needs a real PULL.
    const label = "Gap0514Chunk";
    const total: usize = 1100;
    const big_path = ".zig-cache/tmp/gap0514_chunked.gql";
    defer deleteFileQuiet(big_path);
    {
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(allocator);
        var i: usize = 0;
        while (i < total) : (i += 1) {
            const stmt = try std.fmt.allocPrint(
                allocator,
                "CREATE (:{s} {{i: {d}, pad: 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'}});\n",
                .{ label, i },
            );
            defer allocator.free(stmt);
            try content.appendSlice(allocator, stmt);
        }
        try testing.expect(content.items.len > 32 * 1024);
        try writeTextFile(big_path, content.items);
    }

    try repl_dispatch.executeSourceFile(&state, big_path);
    // Output suppression must be scoped to the chunked run only.
    try testing.expect(!state.suppress_output);

    // Every statement from every chunk must have landed.
    try testing.expectEqual(@as(i64, @intCast(total)), try queryFirstRowInt(allocator, &session, "MATCH (n:" ++ label ++ ") RETURN count(n) AS c"));

    // PullAllInterrupt: 1100 rows exceed the inline page, so pullAll must
    // issue a PULL; a pending SIGINT aborts before that blocking read.
    try session.runGql("MATCH (n:" ++ label ++ ") RETURN n.i");
    try testing.expect(!session.inline_page_final);
    armSigint();
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(allocator);
    try testing.expectError(error.Interrupted, session.pullAll(&sink));
    disarmSigint();
    // The aborted PULL left exactly one response in flight; discard it so the
    // session (and its deinit-time teardown) sees a clean connection.
    _ = session.drainWithLimit(1, false);
}
