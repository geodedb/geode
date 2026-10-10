// SONNY-3029 regression: no group-commit batch has an engine transaction
// open on a graph while another thread holds the graph's write lock.
//
// Group commit (on by default) applies a shard's batch inside one statement
// transaction, and each op of the batch holds the graph's lock SHARED only
// while it runs. Between two ops the graph's write lock could be taken: the
// writer's engine transactions overlapped the batch's (review probe
// R9R11-P7: over 1600 inserts, a thread holding g1's exclusive lock saw open
// engine transactions in 15,314 of 864,308 samples, up to 6 at once), the
// SONNY-2978 overlap that can lose committed writes on crash recovery, and
// SONNY-2823's premise that the write lock keeps every other writer off the
// graph did not hold.
//
// Now a batch opens its transaction only while no thread holds or waits for
// the graph's write lock, and a writer takes the lock only once every open
// batch has committed (`StorageAdapter.enterBatchTxn` / `claimWriteLock`).
//
// CANARY: REQ=REQ-SONNY-3029-GROUP-COMMIT-TXN-GATE; FEATURE="High-Concurrency Mutations"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3029_group_commit_txn_gate.zig; OWNER=storage; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;
const group_commit = geode.group_commit;

// ---------------------------------------------------------------------------
// Deterministic: a batch held with its transaction open keeps the writer out.
// ---------------------------------------------------------------------------

var hold_batch: std.atomic.Value(bool) = .init(false);
var batch_held: std.atomic.Value(bool) = .init(false);

fn holdBatchHook(_: []const u8) void {
    if (!hold_batch.load(.acquire)) return;
    batch_held.store(true, .release);
    while (hold_batch.load(.acquire)) fx.sleepMs(1);
}

const Submit = struct {
    coord: *group_commit.ShardedCoordinator,
    failed: bool = false,

    fn run(self: *Submit) void {
        const labels = [_][]const u8{"G"};
        var op = group_commit.ApplyOp{ .bulk_insert_node = .{
            .labels = &labels,
            .props = &.{},
            .result = .{},
        } };
        _ = self.coord.submit(&op) catch {
            self.failed = true;
        };
    }
};

const Writer = struct {
    acquired: std.atomic.Value(bool) = .init(false),
    open_at_acquire: usize = std.math.maxInt(usize),

    fn run(self: *Writer) void {
        const lock = graph_store.acquireGraphWriteLock("g1");
        self.open_at_acquire = fx.engineActive("g1");
        self.acquired.store(true, .release);
        graph_store.releaseGraphLock(lock);
    }
};

test "SONNY-3029: a group-commit batch with its transaction open keeps another thread from taking the graph's write lock until it commits" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    defer group_commit.shutdownAllCoordinators();
    if (!group_commit.isEnabled()) return error.SkipZigTest;
    const ad = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const coord = try group_commit.getOrStartCoordinator(graph_store.global_allocator(), ad, "g1");

    group_commit.batch_txn_opened_hook = &holdBatchHook;
    defer group_commit.batch_txn_opened_hook = null;
    hold_batch.store(true, .release);
    batch_held.store(false, .release);
    defer hold_batch.store(false, .release);

    var submit: Submit = .{ .coord = coord };
    const st = try std.Thread.spawn(.{}, Submit.run, .{&submit});
    var waited_ms: usize = 0;
    while (!batch_held.load(.acquire)) : (waited_ms += 1) {
        if (waited_ms > 10_000) return error.BatchNeverOpened;
        fx.sleepMs(1);
    }
    // The batch is held with its engine transaction open.
    try testing.expect(fx.engineActive("g1") >= 1);

    var writer: Writer = .{};
    const wt = try std.Thread.spawn(.{}, Writer.run, .{&writer});
    fx.sleepMs(300);
    // Deterministic: the batch is held open, so the writer is still waiting.
    const acquired_while_open = writer.acquired.load(.acquire);

    hold_batch.store(false, .release);
    st.join();
    wt.join();
    try testing.expect(!acquired_while_open);
    try testing.expect(writer.acquired.load(.acquire));
    try testing.expectEqual(@as(usize, 0), writer.open_at_acquire);
    try testing.expect(!submit.failed);
    try testing.expectEqual(@as(usize, 1), fx.countLabel(f.st, "g1", "G"));
}

// ---------------------------------------------------------------------------
// The review's probe: many batches against a thread that keeps taking the
// graph's write lock.
// ---------------------------------------------------------------------------

const Sampler = struct {
    stop: std.atomic.Value(bool) = .init(false),
    samples: usize = 0,
    hits: usize = 0,
    max_open: usize = 0,

    fn run(self: *Sampler) void {
        while (!self.stop.load(.acquire)) {
            const lock = graph_store.acquireGraphWriteLock("g1");
            const n = fx.engineActive("g1");
            graph_store.releaseGraphLock(lock);
            self.samples += 1;
            if (n > 0) {
                self.hits += 1;
                if (n > self.max_open) self.max_open = n;
            }
        }
    }
};

const Submitter = struct {
    coord: *group_commit.ShardedCoordinator,
    n: usize,
    failed: usize = 0,

    fn run(self: *Submitter) void {
        const labels = [_][]const u8{"P7"};
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            var op = group_commit.ApplyOp{ .bulk_insert_node = .{
                .labels = &labels,
                .props = &.{},
                .result = .{},
            } };
            _ = self.coord.submit(&op) catch {
                self.failed += 1;
            };
        }
    }
};

test "SONNY-3029: 8 threads' group-commit inserts never leave an engine transaction open in g1 while another thread holds g1's write lock (R9R11-P7)" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    defer group_commit.shutdownAllCoordinators();
    if (!group_commit.isEnabled()) return error.SkipZigTest;
    const ad = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const coord = try group_commit.getOrStartCoordinator(graph_store.global_allocator(), ad, "g1");

    var sampler: Sampler = .{};
    const st = try std.Thread.spawn(.{}, Sampler.run, .{&sampler});
    var subs: [8]Submitter = undefined;
    var threads: [8]std.Thread = undefined;
    for (&subs, 0..) |*s, i| {
        s.* = .{ .coord = coord, .n = 200 };
        threads[i] = try std.Thread.spawn(.{}, Submitter.run, .{s});
    }
    for (threads) |t| t.join();
    sampler.stop.store(true, .release);
    st.join();
    var failed: usize = 0;
    for (subs) |s| failed += s.failed;
    std.debug.print("P7: submitted=1600 failed={d} P7={d} samples={d} hits={d} max_open={d}\n", .{
        failed, fx.countLabel(f.st, "g1", "P7"), sampler.samples, sampler.hits, sampler.max_open,
    });
    try testing.expectEqual(@as(usize, 0), failed);
    try testing.expectEqual(@as(usize, 1600), fx.countLabel(f.st, "g1", "P7"));
    try testing.expectEqual(@as(usize, 0), sampler.hits);
}
