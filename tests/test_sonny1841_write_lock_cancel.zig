// SONNY-1841 — per-stream QUIC CANCEL must abort an abandoned WRITE-carrying
// mutation and RELEASE the per-graph write lock, so a concurrent writer waiting
// on that graph proceeds promptly instead of stalling to the ~120 s write-lock
// deadline.
//
// The shipped CANCEL plumbing (proto oneof tag 15 ->
// proto_reader_registry.requestCancelByStreamId -> the reader's cancel_requested
// atomic) was CORRECT, but the flag was polled ONLY on the READ path: the read
// budget/cancel scope is installed only for NON-write queries
// (query_execution.zig `!write_carrying`), and write_budget.check() carried NO
// cancel source. A write-carrying MATCH..SET therefore ignored the CANCEL and
// ran to completion under the exclusive per-graph write lock — the ticket's
// exact failure (a concurrent writer on another connection stays blocked).
//
// The existing test-sonny-quic-stream-semantics predicate only proved the flag
// gets SET; it never proved the lock is released. This test proves the release:
//
//   Thread A (the abandoned writer): takes the per-graph write lock (as the QUIC
//   handler does around executeProgramWithContext), installs the same cancel
//   source the transport installs (a pre-armed CANCEL), then runs a
//   write-carrying `MATCH (n:Taxon) SET ...`.
//     RED  (HEAD): write_budget.check() ignores the flag -> the SET runs to
//                  completion, THEN the lock releases. A returns success.
//     GREEN (fix): the write-side candidate loop's write_budget.check() observes
//                  the cancel at the first candidate -> aborts with
//                  error.WriteQueryCancelled -> unwinds -> releases the lock.
//
//   The contender: waits until A holds the lock, then acquires the SAME graph
//   write lock with a long (30 s) deadline and records how long it waited.
//
// GREEN assertions: A aborted with error.WriteQueryCancelled (the deterministic
// RED->GREEN discriminator — at HEAD A succeeds), the contender acquired the
// lock (proving A released it), and it did so well under the write-lock
// deadline. RED fails the first assertion (A returns a successful result).
//
// CANARY: REQ=SONNY-1841; FEATURE="WriteCancelReleasesLock"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny1841_write_lock_cancel.zig; OWNER=execution; UPDATED=2026-09-18

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const read_budget = geode.read_budget;

// Zig 0.16 compat — see tests/test_graph_write_lock_cancelable.zig:44-61.
fn monoNanos() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn sleepNs(ns: u64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    pub fn seed(self: *Harness, count: usize) !void {
        const aa = self.arena.allocator();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const q = try std.fmt.allocPrint(
                aa,
                "MERGE (n:Taxon {{source_id: 'row_{d}', source: 'col'}})",
                .{i},
            );
            var r = try self.runQuery(q);
            r.deinit(aa);
        }
    }
};

const WriterCtx = struct {
    h: *Harness,
    cancel_flag: *std.atomic.Value(bool),
    engaged: *std.atomic.Value(u32),
    done: *std.atomic.Value(u32),
    got_cancelled: *std.atomic.Value(u32),
    got_success: *std.atomic.Value(u32),
};

// The abandoned writer: hold the per-graph write lock across the mutation (as
// the QUIC handler does), with a pre-armed CANCEL installed on this thread's
// cancel source (exactly what the transport installs before dispatch).
fn abandonedWriter(ctx: *WriterCtx) void {
    const lock = graph_store.acquireGraphWriteLock("default");

    // The transport installs the stream's cancel_requested atomic here; the
    // QUIC CANCEL message has already set it (pre-armed) for this abandoned
    // stream. The WRITE scope installed inside executeStatement must capture it.
    read_budget.setWatchdogCancelSource(ctx.cancel_flag);
    defer read_budget.setWatchdogCancelSource(null);

    ctx.engaged.store(1, .release);

    if (ctx.h.runQuery("MATCH (n:Taxon) SET n.tag = 'abandoned'")) |*r| {
        var res = r.*;
        res.deinit(ctx.h.arena.allocator());
        ctx.got_success.store(1, .release); // RED: the SET ran to completion.
    } else |err| {
        if (err == error.WriteQueryCancelled) {
            ctx.got_cancelled.store(1, .release); // GREEN: aborted on the poll.
        } else {
            std.debug.print("SONNY-1841: writer got unexpected error {s}\n", .{@errorName(err)});
        }
    }

    graph_store.releaseGraphLock(lock);
    ctx.done.store(1, .release);
}

test "SONNY-1841: a canceled write-carrying mutation releases the per-graph write lock for a waiting writer" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Enough candidates that the write-side match loop iterates (so the poll has
    // somewhere to fire) — and, at HEAD, enough that the un-canceled SET holds
    // the exclusive write lock across all of them.
    try h.seed(600);

    // Pre-armed CANCEL: the client already sent per-stream CANCEL for this
    // (now abandoned) stream before the mutation began polling.
    var cancel_flag = std.atomic.Value(bool).init(true);
    var engaged = std.atomic.Value(u32).init(0);
    var done = std.atomic.Value(u32).init(0);
    var got_cancelled = std.atomic.Value(u32).init(0);
    var got_success = std.atomic.Value(u32).init(0);

    var wctx = WriterCtx{
        .h = &h,
        .cancel_flag = &cancel_flag,
        .engaged = &engaged,
        .done = &done,
        .got_cancelled = &got_cancelled,
        .got_success = &got_success,
    };

    const t_writer = try std.Thread.spawn(.{}, abandonedWriter, .{&wctx});

    // Wait until the abandoned writer holds the write lock (bounded so a hang
    // never wedges the suite).
    const engage_deadline = monoNanos() + 5 * std.time.ns_per_s;
    while (engaged.load(.acquire) == 0 and monoNanos() < engage_deadline) sleepNs(1 * std.time.ns_per_ms);
    if (engaged.load(.acquire) == 0) {
        t_writer.join();
        return error.WriterNeverEngaged;
    }

    // The concurrent writer on "another connection": wait on the SAME graph
    // write lock with a generous 30 s deadline (the production write-lock
    // deadline is ~120 s). Time how long until it proceeds.
    const t0 = monoNanos();
    const contender = graph_store.acquireGraphWriteLockCancelable("default", t0 + 30 * std.time.ns_per_s);
    const t1 = monoNanos();

    var contender_acquired = false;
    if (contender) |ch| {
        contender_acquired = true;
        graph_store.releaseGraphLock(ch);
    } else |err| {
        std.debug.print("SONNY-1841: contender failed to acquire: {s}\n", .{@errorName(err)});
    }

    t_writer.join();

    const waited_ms = @as(f64, @floatFromInt(t1 - t0)) / 1_000_000.0;

    // (1) PRIMARY, deterministic RED->GREEN gate: the abandoned mutation must
    // ABORT via the write-path cancel poll. At HEAD the SET ignores the flag and
    // completes (got_success=1) — this assertion fails, proving the bug shipped.
    if (got_cancelled.load(.acquire) != 1) {
        std.debug.print(
            "SONNY-1841 RED: write-carrying mutation did NOT observe the CANCEL " ++
                "(success={d}) — it ran to completion holding the write lock. " ++
                "write_budget.check() has no cancel source on the write path.\n",
            .{got_success.load(.acquire)},
        );
        return error.WriteMutationIgnoredCancel;
    }

    // (2) LOCK RELEASE: the contender acquired the lock the aborted writer held.
    // Composed with (1) — the mutation aborted (did NOT complete) yet the lock
    // became available — this proves the write lock is released ON CANCEL.
    try testing.expect(contender_acquired);

    // (3) PROMPTNESS: released well under the ~120 s write-lock deadline.
    try testing.expect(waited_ms < 10_000.0);
}
