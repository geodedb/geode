// CANARY: REQ=REQ-SONNY-6422-PHANTOM-ONCE-PER-COMMIT; FEATURE="MVCC Phantom Prevention"; ASPECT=RangeLookupOncePerCommit; STATUS=TESTED; TEST=tests/test_sonny6422_phantom_check_once_per_commit.zig; OWNER=txn; UPDATED=2026-11-12
//
// SONNY-6422 (7): `Manager.detectPhantoms` (src/transactions/manager.zig)
// called `RangeTracker.keyInRanges(txn.id, key)` for every write committed
// since the transaction started, and each call looked the transaction's
// range list up in the tracker's hash map again. A transaction that read no
// range paid one hash lookup per concurrent write at commit; one that read
// ranges paid the same lookup before every range comparison.
//
// The contract: the range list is looked up once per commit. A transaction
// with no range reads checks no writes against ranges, so its phantom check
// does not grow with the number of concurrent committed writes; detection
// itself is unchanged (a write inside a read range still fails the commit).
//
// The cost is measured through the shared perf_gate helpers (interleaved
// batches, medians). The complexity claim (no growth with the write history
// for a transaction with no range reads) is asserted directly: before the
// fix the check grew about linearly (a 64x larger history cost tens of
// times more), far outside the bound.
const std = @import("std");
const perf_gate = @import("perf_gate");
const txn = @import("txn");

const testing = std.testing;

/// A manager with `writes` committed writes newer than two open
/// transactions: `plain` (no range reads) and `ranged` (two range reads no
/// write falls in). `pin` begins first and stays open so pruneWrites keeps
/// the history.
const Fixture = struct {
    mgr: txn.Manager,
    pin: txn.Txn,
    plain: txn.Txn,
    ranged: txn.Txn,

    fn init(self: *Fixture, allocator: std.mem.Allocator, writes: usize) !void {
        self.mgr.init(allocator);
        self.mgr.enablePhantomPrevention();
        self.pin = self.mgr.begin();
        self.plain = self.mgr.begin();
        self.ranged = self.mgr.begin();
        try self.mgr.rangeRead(&self.ranged, "cust:100", "cust:300");
        try self.mgr.rangeRead(&self.ranged, "order:050", "order:999");
        var key_buf: [32]u8 = undefined;
        for (0..writes) |i| {
            var w = self.mgr.begin();
            const key = try std.fmt.bufPrint(&key_buf, "zz:{d}", .{i});
            self.mgr.recordWrite(key, &w);
            try self.mgr.commit(&w);
        }
    }

    fn deinit(self: *Fixture) void {
        self.mgr.deinit();
    }

    fn checkPlain(self: *Fixture) !u64 {
        try self.mgr.checkPhantoms(&self.plain);
        return self.plain.id;
    }

    fn checkRanged(self: *Fixture) !u64 {
        try self.mgr.checkPhantoms(&self.ranged);
        return self.ranged.id;
    }
};

const small_history: usize = 64;
const large_history: usize = 4096;
/// Allowed growth of the no-range check from the small to the 64x larger
/// history. One lookup per commit is flat (about 1x); one lookup per write
/// grows with the history.
const max_plain_growth: f64 = 8.0;

const Pair = struct {
    small: *Fixture,
    large: *Fixture,

    fn plainSmall(self: *Pair) !u64 {
        return self.small.checkPlain();
    }
    fn plainLarge(self: *Pair) !u64 {
        return self.large.checkPlain();
    }
    fn rangedSmall(self: *Pair) !u64 {
        return self.small.checkRanged();
    }
    fn rangedLarge(self: *Pair) !u64 {
        return self.large.checkRanged();
    }
};

test "SONNY-6422 (7) the phantom check of a transaction with no range reads does not grow with the concurrent write history" {
    const allocator = perf_gate.bench_allocator;
    var small: Fixture = undefined;
    try small.init(allocator, small_history);
    defer small.deinit();
    var large: Fixture = undefined;
    try large.init(allocator, large_history);
    defer large.deinit();
    var pair: Pair = .{ .small = &small, .large = &large };

    const samples = 31;
    const batch = 256;
    var plain_small: [samples]f64 = undefined;
    var plain_large: [samples]f64 = undefined;
    var ranged_small: [samples]f64 = undefined;
    var ranged_large: [samples]f64 = undefined;
    _ = try perf_gate.timeBatch(&pair, Pair.plainLarge, batch);
    try perf_gate.interleavedAB(&pair, Pair.plainSmall, Pair.plainLarge, batch, &plain_small, &plain_large);
    try perf_gate.interleavedAB(&pair, Pair.rangedSmall, Pair.rangedLarge, batch, &ranged_small, &ranged_large);
    const ps = perf_gate.robust(&plain_small);
    const pl = perf_gate.robust(&plain_large);
    const rs = perf_gate.robust(&ranged_small);
    const rl = perf_gate.robust(&ranged_large);
    const plain_growth = if (ps.median > 0) pl.median / ps.median else 0;
    std.debug.print(
        "SONNY6422_PHANTOM_CHECK history={d}/{d} no_range_median={d:.1}ns/{d:.1}ns growth={d:.2} ranged_median={d:.1}ns/{d:.1}ns ranged_per_write={d:.2}ns\n",
        .{ small_history, large_history, ps.median, pl.median, plain_growth, rs.median, rl.median, (rl.median - rs.median) / @as(f64, @floatFromInt(large_history - small_history)) },
    );
    if (plain_growth > max_plain_growth) {
        std.debug.print("SONNY-6422 (7): the no-range phantom check grew {d:.1}x from a {d}- to a {d}-write history (bound {d:.0}x): it still does per-write range lookups\n", .{ plain_growth, small_history, large_history, max_plain_growth });
    }
    try testing.expect(plain_growth <= max_plain_growth);
}

test "SONNY-6422 (7) a write inside a read range still fails the commit, and one outside does not" {
    var mgr: txn.Manager = undefined;
    mgr.init(testing.allocator);
    defer mgr.deinit();
    mgr.enablePhantomPrevention();

    var reader = mgr.begin();
    var outside_reader = mgr.begin();
    try mgr.rangeRead(&reader, "cust:100", "cust:200");
    try mgr.rangeRead(&outside_reader, "order:000", "order:100");
    var w = mgr.begin();
    mgr.recordWrite("cust:150", &w);
    try mgr.commit(&w);
    try testing.expectError(error.SerializationFailure, mgr.commit(&reader));
    mgr.rollback(&reader);
    try mgr.commit(&outside_reader);
}
