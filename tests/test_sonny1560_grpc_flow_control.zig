//! SONNY-1560 regression: a pushed gRPC result must never pin the session.
//!
//! Ticket symptom (filed from the Go driver's Lane D Task 14c against
//! geodedb/geode:0.8.15): `TestIntegration_GRPCLargePushedResultFailsLoudly`
//! read 5632 of 20000 rows over gRPC and then the stream stalled until the
//! client's context expired ~30 s later, while the SAME 50 000 rows over QUIC
//! finished in ~1.5 s. Worse, the stalled stream also blocked the next Execute
//! on that session for the whole 30 s.
//!
//! Root cause, split across two halves:
//!
//!   * LIBRARY HALF (not fixable here, see .superpowers/sdd/sonny-1560-report.md):
//!     grpc-zig 0.1.8 DOES honour WINDOW_UPDATE — `Transport.reserveSendCredit`
//!     (grpc_zig/src/transport.zig:1017) gates every DATA write on the peer's
//!     window and `processWindowUpdate` (grpc_zig/src/transport.zig:935)
//!     credits it back. But its server runs the connection read loop on the
//!     SAME thread as the handler (grpc_zig/src/server.zig:319/361/471), and
//!     the only server-side WINDOW_UPDATE dispatch lives inside
//!     `readMessageCore` (grpc_zig/src/transport.zig:1547). So while a handler
//!     pushes pages nobody drains the socket, the peer's WINDOW_UPDATE is never
//!     processed, and once the advertised 1 MiB initial window
//!     (grpc_zig/src/transport.zig:88) is consumed the writer parks until
//!     `flow_credit_timeout_ns` (30 s, grpc_zig/src/transport.zig:457) expires.
//!     1 MiB / 5632 rows is ~186 B per row, and 30 s is exactly the stall the
//!     ticket measured.
//!
//!   * ENGINE HALF (fixed, and pinned by this suite):
//!     `handleExecuteStreaming` held the session mutex for the ENTIRE push loop
//!     (Issue #514's fix for a concurrent-Execute use-after-free), so the 30 s
//!     stall above became a 30 s lock-out of every other statement on that
//!     session. The push loop now holds `entry.mutex` ONLY while a page is
//!     materialised, re-validates a claimed result generation after each
//!     unlocked write, bounds the write by the peer's advertised window, and
//!     releases the cursor deterministically on every abandonment.
//!
//! WHAT THIS SUITE PROVES: the transport-handler contract — that
//! `pushResultPages` never holds the session mutex across a page write, that a
//! normal reader receives every row, that abandonment and supersession release
//! the session's cursor, and that an unsatisfiable peer window is classified
//! loudly instead of waited out.
//!
//! WHAT THIS SUITE DOES NOT PROVE: anything about real HTTP/2 framing. It
//! drives the handler through the `PageSink` seam with stub sinks, so it cannot
//! observe WINDOW_UPDATE on the wire, cannot prove the library's credit
//! accounting, and cannot prove that a >1 MiB pushed result now completes — it
//! does not, and cannot, until the library grows a per-connection reader
//! thread. That end-to-end behaviour is the library half of SONNY-1560.

const std = @import("std");
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const logging = @import("logging");
const grpc = @import("grpc_impl").impl;

const execution = geode.execution;
const server_state = geode.server_state;
const value_types = geode.value_types;
const Value = value_types.Value;

/// Pin the engine logger to `.fatal`. `pushResultPages` logs at `.err` on every
/// abandonment path and this suite drives all of them on purpose; without this
/// the Zig 0.16 build runner echoes the piped child stderr back under a red
/// `failed command:` banner even on a clean exit-0 run.
fn silenceEngineLogs() void {
    logging.init(.{ .level = .fatal });
    logging.setLevel(.fatal);
}

const io = std.Io.Threaded.global_single_threaded.io();

// Zig 0.16 removed `std.time.nanoTimestamp` and `std.Thread.sleep`; these are
// the repo's compat idioms (see src/execution/planned_read_runtime.zig:3500 and
// tests/canary_planner_enumerator.zig:31). MONOTONIC is used deliberately so a
// wall-clock step cannot corrupt an elapsed-time assertion.
fn nowNs() i128 {
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

fn sleepNs(ns: u64) void {
    var req: std.posix.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.nanosleep(@ptrCast(&req), @ptrCast(&rem));
    } else {
        _ = std.c.nanosleep(&req, &rem);
    }
}

/// `query_runner.default_page_size`; the push loop pages at this width.
const page_rows: usize = 128;

/// gRPC length-prefix width the library adds before reserving send credit
/// (grpc_zig/src/transport.zig:2194-2205).
const grpc_framing_overhead: i64 = 5;

// ── fixtures ────────────────────────────────────────────────────────────────

fn makeResult(gpa: std.mem.Allocator, row_count: usize) !execution.ExecutionResult {
    const columns = try gpa.alloc([]const u8, 1);
    errdefer gpa.free(columns);
    columns[0] = try gpa.dupe(u8, "n");

    const rows = try gpa.alloc([]Value, row_count);
    for (rows, 0..) |*row, i| {
        row.* = try gpa.alloc(Value, 1);
        row.*[0] = .{ .Int = @intCast(i) };
    }

    return .{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
        // The values are plain ints with no heap tails, so the result does not
        // own value memory; `deinit` frees the row/column spines only.
        .owns_value_memory = false,
    };
}

const Fixture = struct {
    gpa: std.mem.Allocator,
    state: *server_state.ServerState,
    entry: *grpc.SessionEntry,

    fn init(gpa: std.mem.Allocator, row_count: usize) !Fixture {
        const state = try gpa.create(server_state.ServerState);
        state.* = .{ .allocator = gpa };
        state.active_result_values = try makeResult(gpa, row_count);
        state.active_result = true;
        state.result_page_index = 0;

        const entry = try gpa.create(grpc.SessionEntry);
        entry.* = .{ .state = state, .result_epoch = 1 };
        return .{ .gpa = gpa, .state = state, .entry = entry };
    }

    fn deinit(self: *Fixture) void {
        self.state.resetResult();
        self.gpa.destroy(self.state);
        self.gpa.destroy(self.entry);
    }

    /// True when the session's cursor has been released.
    fn released(self: *const Fixture) bool {
        return self.state.active_result_values == null and self.state.result_page_index == 0;
    }
};

// ── stub sinks ──────────────────────────────────────────────────────────────

/// Records every page and, optionally, fails or stalls at a chosen page index.
const StubSink = struct {
    gpa: std.mem.Allocator,
    pages: std.ArrayList([]u8) = .empty,
    writes: usize = 0,

    /// Page index at which `write` returns `fail_error` (null = never).
    fail_at: ?usize = null,
    fail_error: anyerror = error.ConnectionResetByPeer,

    /// Page index at which `write` parks for `stall_ns` (null = never). The
    /// park is BOUNDED so a regression shows up as a failed timing assertion
    /// rather than as a hung test.
    stall_at: ?usize = null,
    stall_ns: u64 = 0,
    /// Set once the stalling write has actually entered its park.
    in_stall: std.atomic.Value(bool) = .init(false),

    /// Remaining peer window reported to the push loop (null = sink reports
    /// none, i.e. an unbounded peer). NOT constant: every accepted write
    /// decrements it by the framed message size (`bytes.len + 5`), exactly as
    /// `Transport.writeStreamMessage` reserves it
    /// (grpc_zig/src/transport.zig:2192-2205). A constant window could never
    /// exercise the ticket's actual shape -- sufficient at page 1, exhausted at
    /// page N -- which is what a real 1 MiB initial window produces.
    window: ?i64 = null,

    /// Captured `failFn` classification.
    fail_code: ?u8 = null,
    fail_message: ?[]const u8 = null,

    /// When set, the first write simulates a concurrent Execute landing on the
    /// session: it takes the mutex, resets the result and bumps the epoch —
    /// exactly what `handleExecute` does.
    supersede_entry: ?*grpc.SessionEntry = null,

    fn deinit(self: *StubSink) void {
        for (self.pages.items) |p| self.gpa.free(p);
        self.pages.deinit(self.gpa);
    }

    fn writeThunk(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *StubSink = @ptrCast(@alignCast(ctx));
        const idx = self.writes;
        self.writes += 1;

        if (self.supersede_entry) |entry| {
            self.supersede_entry = null;
            entry.mutex.lockUncancelable(io);
            defer entry.mutex.unlock(io);
            entry.state.resetResult();
            entry.result_epoch +%= 1;
        }

        if (self.stall_at) |at| {
            if (idx == at) {
                self.in_stall.store(true, .release);
                sleepNs(self.stall_ns);
            }
        }

        if (self.fail_at) |at| {
            if (idx == at) return self.fail_error;
        }

        // Spend the peer's credit for this message, framing included.
        if (self.window) |*remaining| {
            remaining.* -= @as(i64, @intCast(bytes.len)) + grpc_framing_overhead;
        }

        try self.pages.append(self.gpa, try self.gpa.dupe(u8, bytes));
    }

    fn windowThunk(ctx: *anyopaque) i64 {
        const self: *StubSink = @ptrCast(@alignCast(ctx));
        return self.window orelse std.math.maxInt(i32);
    }

    fn failThunk(ctx: *anyopaque, code: u8, message: []const u8) void {
        const self: *StubSink = @ptrCast(@alignCast(ctx));
        self.fail_code = code;
        self.fail_message = message;
    }

    fn sink(self: *StubSink) grpc.PageSink {
        return .{
            .ctx = @ptrCast(self),
            .writeFn = writeThunk,
            .windowFn = if (self.window != null) windowThunk else null,
            .failFn = failThunk,
        };
    }

    /// Total rows across every captured page, by decoding each response.
    fn totalRows(self: *const StubSink, gpa: std.mem.Allocator) !usize {
        var total: usize = 0;
        for (self.pages.items) |bytes| {
            var reader: std.Io.Reader = .fixed(bytes);
            var resp = try protobuf.decode(schema.ExecutionResponse, &reader, gpa);
            defer resp.deinit(gpa);
            const payload = resp.payload orelse return error.MissingPayload;
            switch (payload) {
                .page => |pg| total += pg.rows.items.len,
                else => return error.NotADataPage,
            }
        }
        return total;
    }

    /// True when the last captured page carries the final marker.
    fn lastPageFinal(self: *const StubSink, gpa: std.mem.Allocator) !bool {
        if (self.pages.items.len == 0) return false;
        const bytes = self.pages.items[self.pages.items.len - 1];
        var reader: std.Io.Reader = .fixed(bytes);
        var resp = try protobuf.decode(schema.ExecutionResponse, &reader, gpa);
        defer resp.deinit(gpa);
        const payload = resp.payload orelse return error.MissingPayload;
        return switch (payload) {
            .page => |pg| pg.final,
            else => error.NotADataPage,
        };
    }
};

// ── (b) a client that reads normally receives all rows ──────────────────────

test "SONNY-1560: a normally-draining peer receives every row and the session is released" {
    silenceEngineLogs();
    const gpa = std.testing.allocator;

    const total_rows: usize = page_rows * 5 + 7;
    var fx = try Fixture.init(gpa, total_rows);
    defer fx.deinit();

    var stub = StubSink{ .gpa = gpa };
    defer stub.deinit();

    const outcome = grpc.pushResultPages(fx.entry, fx.entry.result_epoch, stub.sink(), gpa);
    try std.testing.expectEqual(grpc.PushOutcome.complete, outcome);

    try std.testing.expectEqual(total_rows, try stub.totalRows(gpa));
    try std.testing.expect(try stub.lastPageFinal(gpa));
    // Draining to the final page resets the cursor inside the page builder.
    try std.testing.expect(fx.released());
}

// ── (a) a stalled stream must NOT block the next Execute on the session ─────

const StallRunner = struct {
    entry: *grpc.SessionEntry,
    sink: grpc.PageSink,
    gpa: std.mem.Allocator,
    epoch: u64,
    outcome: grpc.PushOutcome = .complete,

    fn run(self: *StallRunner) void {
        self.outcome = grpc.pushResultPages(self.entry, self.epoch, self.sink, self.gpa);
    }
};

test "SONNY-1560: a stalled pushed stream does not hold the session mutex across the write" {
    silenceEngineLogs();
    const gpa = std.testing.allocator;

    // The stall is bounded so the OLD whole-loop-lock behaviour fails the
    // timing assertion below instead of deadlocking the test runner.
    const stall_ns: u64 = 2 * std.time.ns_per_s;
    // A second-Execute lock acquisition must complete far inside the stall.
    const acquire_bound_ns: u64 = 500 * std.time.ns_per_ms;

    var fx = try Fixture.init(gpa, page_rows * 6);
    defer fx.deinit();

    var stub = StubSink{ .gpa = gpa, .stall_at = 0, .stall_ns = stall_ns };
    defer stub.deinit();

    var runner = StallRunner{
        .entry = fx.entry,
        .sink = stub.sink(),
        .gpa = gpa,
        .epoch = fx.entry.result_epoch,
    };
    const thread = try std.Thread.spawn(.{}, StallRunner.run, .{&runner});

    // Wait for the push loop to be genuinely parked inside the page WRITE.
    const spin_deadline = nowNs() + @as(i128, stall_ns);
    while (!stub.in_stall.load(.acquire) and nowNs() < spin_deadline) {
        sleepNs(std.time.ns_per_ms);
    }
    try std.testing.expect(stub.in_stall.load(.acquire));

    // This is exactly what the next Execute on this session does first.
    const started = nowNs();
    fx.entry.mutex.lockUncancelable(io);
    const elapsed: u64 = @intCast(nowNs() - started);
    fx.entry.mutex.unlock(io);

    // RED against the pre-fix code: `handleExecuteStreaming` held this mutex for
    // the entire push loop, so this acquisition would have taken the full stall.
    try std.testing.expect(elapsed < acquire_bound_ns);

    thread.join();
    try std.testing.expectEqual(grpc.PushOutcome.complete, runner.outcome);
}

// ── (c) abandonment mid-stream releases the session deterministically ───────

test "SONNY-1560: an abandoned stream releases the session cursor and frees the mutex" {
    silenceEngineLogs();
    const gpa = std.testing.allocator;

    var fx = try Fixture.init(gpa, page_rows * 6);
    defer fx.deinit();

    const claimed = fx.entry.result_epoch;
    var stub = StubSink{ .gpa = gpa, .fail_at = 2, .fail_error = error.ConnectionResetByPeer };
    defer stub.deinit();

    const outcome = grpc.pushResultPages(fx.entry, claimed, stub.sink(), gpa);
    try std.testing.expectEqual(grpc.PushOutcome.write_failed, outcome);

    // The cursor is gone and the generation moved on, so a late duplicate
    // release cannot touch a newer statement's result.
    try std.testing.expect(fx.released());
    try std.testing.expect(fx.entry.result_epoch != claimed);

    // The mutex is free: the next Execute proceeds immediately.
    const started = nowNs();
    fx.entry.mutex.lockUncancelable(io);
    const elapsed: u64 = @intCast(nowNs() - started);
    fx.entry.mutex.unlock(io);
    try std.testing.expect(elapsed < 500 * std.time.ns_per_ms);
}

// ── supersession: a newer Execute wins, the stale stream stands down ────────

test "SONNY-1560: a newer Execute supersedes an in-flight stream without it paging the new result" {
    silenceEngineLogs();
    const gpa = std.testing.allocator;

    var fx = try Fixture.init(gpa, page_rows * 6);
    defer fx.deinit();

    const claimed = fx.entry.result_epoch;
    var stub = StubSink{ .gpa = gpa, .supersede_entry = fx.entry };
    defer stub.deinit();

    const outcome = grpc.pushResultPages(fx.entry, claimed, stub.sink(), gpa);
    try std.testing.expectEqual(grpc.PushOutcome.superseded, outcome);

    // The stale stream stopped after its first (already in-flight) page and
    // never produced a page from the superseding statement's generation.
    try std.testing.expectEqual(@as(usize, 1), stub.writes);
    try std.testing.expect(fx.entry.result_epoch != claimed);
}

// ── window bound: an unsatisfiable peer window fails loudly, not silently ───

test "SONNY-1560: a peer window too small for the next page is classified RESOURCE_EXHAUSTED" {
    silenceEngineLogs();
    const gpa = std.testing.allocator;

    var fx = try Fixture.init(gpa, page_rows * 6);
    defer fx.deinit();

    const claimed = fx.entry.result_epoch;
    // Smaller than any real page, so the very first write is refused rather
    // than parked on for the library's 30 s flow-credit timeout.
    var stub = StubSink{ .gpa = gpa, .window = 8 };
    defer stub.deinit();

    const outcome = grpc.pushResultPages(fx.entry, claimed, stub.sink(), gpa);
    try std.testing.expectEqual(grpc.PushOutcome.window_exhausted, outcome);

    // Nothing was written, the peer got a classified terminal status, and the
    // session was released.
    try std.testing.expectEqual(@as(usize, 0), stub.writes);
    try std.testing.expectEqual(@as(?u8, 8), stub.fail_code); // RESOURCE_EXHAUSTED
    try std.testing.expect(stub.fail_message != null);
    // Static text only: no tenant id, no session id.
    try std.testing.expect(std.mem.indexOfScalar(u8, stub.fail_message.?, '=') == null);
    try std.testing.expect(fx.released());
}

test "SONNY-1560: a peer window that fits the page lets the drain complete" {
    silenceEngineLogs();
    const gpa = std.testing.allocator;

    const total_rows: usize = page_rows * 3;
    var fx = try Fixture.init(gpa, total_rows);
    defer fx.deinit();

    var stub = StubSink{ .gpa = gpa, .window = 1024 * 1024 };
    defer stub.deinit();

    const outcome = grpc.pushResultPages(fx.entry, fx.entry.result_epoch, stub.sink(), gpa);
    try std.testing.expectEqual(grpc.PushOutcome.complete, outcome);
    try std.testing.expectEqual(total_rows, try stub.totalRows(gpa));
}

// ── the ticket's shape: enough window for page 1, none for page 2 ───────────

test "SONNY-1560: a draining window sufficient at page 1 is classified when it runs out at page N" {
    silenceEngineLogs();
    const gpa = std.testing.allocator;

    // Measure one encoded page against an unbounded peer so the budget below is
    // derived from the real wire size rather than a guessed constant.
    const framed_first_page: i64 = blk: {
        var probe_fx = try Fixture.init(gpa, page_rows * 6);
        defer probe_fx.deinit();
        var probe = StubSink{ .gpa = gpa };
        defer probe.deinit();
        _ = grpc.pushResultPages(probe_fx.entry, probe_fx.entry.result_epoch, probe.sink(), gpa);
        try std.testing.expect(probe.pages.items.len > 1);
        break :blk @as(i64, @intCast(probe.pages.items[0].len)) + grpc_framing_overhead;
    };

    var fx = try Fixture.init(gpa, page_rows * 6);
    defer fx.deinit();

    const claimed = fx.entry.result_epoch;
    // Exactly one page of credit: page 1 fits, and the decrement leaves nothing
    // for page 2 — the 1 MiB-initial-window shape the ticket measured.
    var stub = StubSink{ .gpa = gpa, .window = framed_first_page };
    defer stub.deinit();

    const outcome = grpc.pushResultPages(fx.entry, claimed, stub.sink(), gpa);
    try std.testing.expectEqual(grpc.PushOutcome.window_exhausted, outcome);

    // One page went out, then the probe refused rather than parking.
    try std.testing.expectEqual(@as(usize, 1), stub.writes);
    try std.testing.expectEqual(@as(i64, 0), stub.window.?);
    // This path sends no RST, so the handler owes the peer the trailer.
    try std.testing.expectEqual(@as(?u8, 8), stub.fail_code);
    try std.testing.expect(fx.released());
    try std.testing.expect(fx.entry.result_epoch != claimed);
}

// ── the library's RST is the terminal signal: no conflicting trailer ────────

test "SONNY-1560: a write-time FlowControlTimeout writes no trailer because the library's RST already ended the stream" {
    silenceEngineLogs();
    const gpa = std.testing.allocator;

    var fx = try Fixture.init(gpa, page_rows * 6);
    defer fx.deinit();

    const claimed = fx.entry.result_epoch;
    // Simulate the library surfacing `error.FlowControlTimeout` from
    // `writeStreamMessage` (grpc_zig/src/transport.zig:2205 -> :1100). By the
    // time that error reaches us `reserveSendCreditOrRst` has ALREADY emitted
    // RST_STREAM(FLOW_CONTROL_ERROR) and the stream is closed at the peer.
    var stub = StubSink{ .gpa = gpa, .fail_at = 1, .fail_error = error.FlowControlTimeout };
    defer stub.deinit();

    const outcome = grpc.pushResultPages(fx.entry, claimed, stub.sink(), gpa);

    // Still classified as exhaustion, not as a broken connection.
    try std.testing.expectEqual(grpc.PushOutcome.window_exhausted, outcome);
    // ...but NOTHING more was written to the closed stream. A trailer HEADERS
    // frame here would be RFC 7540 §5.1 STREAM_CLOSED at the peer and would
    // race a second, conflicting gRPC status against the RST.
    try std.testing.expectEqual(@as(?u8, null), stub.fail_code);
    try std.testing.expect(stub.fail_message == null);
    // The session is still released deterministically.
    try std.testing.expect(fx.released());
    try std.testing.expect(fx.entry.result_epoch != claimed);
}
