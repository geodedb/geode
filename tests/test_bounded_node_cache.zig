// TDD: BoundedNodeCache unit tests (RED first).
//
// The cache is a bounded, evict-freely wrapper over ShardedStore(u64, V) with:
//   * a resident-entry cap (evict cold entries past the cap),
//   * hydrate-on-miss via a caller-supplied callback (the "engine"),
//   * unlink-now / free-at-grace eviction (retire list + reclaimRetired()),
//   * a caller-supplied per-value free function (Node freeing is custom).
//
// These tests use a fake value type and a fake in-memory "engine" so the cache
// logic is exercised in isolation from graph_store's locking.

const std = @import("std");
const node_cache = @import("node_cache");

const testing = std.testing;

// ---- Fake value + fake engine -------------------------------------------

// A value that owns a heap string, so we can detect use-after-free / leaks
// via the testing allocator.
const FakeVal = struct {
    id: u64,
    name: []u8, // owned

    fn free(self: *FakeVal, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

// Fake durable engine: the source of truth the cache hydrates from.
const FakeEngine = struct {
    allocator: std.mem.Allocator,
    rows: std.AutoHashMap(u64, []const u8),
    hydrate_calls: usize = 0,

    fn init(allocator: std.mem.Allocator) FakeEngine {
        return .{ .allocator = allocator, .rows = std.AutoHashMap(u64, []const u8).init(allocator) };
    }
    fn deinit(self: *FakeEngine) void {
        var it = self.rows.iterator();
        while (it.next()) |e| self.allocator.free(e.value_ptr.*);
        self.rows.deinit();
    }
    fn put(self: *FakeEngine, id: u64, name: []const u8) !void {
        const owned = try self.allocator.dupe(u8, name);
        if (try self.rows.fetchPut(id, owned)) |old| self.allocator.free(old.value);
    }

    // Hydrate callback: rebuild a FakeVal from the durable engine, or null if
    // the id does not exist. The returned value's heap is owned by the cache.
    fn hydrate(ctx: *anyopaque, allocator: std.mem.Allocator, id: u64) anyerror!?FakeVal {
        const self: *FakeEngine = @ptrCast(@alignCast(ctx));
        self.hydrate_calls += 1;
        const name = self.rows.get(id) orelse return null;
        return FakeVal{ .id = id, .name = try allocator.dupe(u8, name) };
    }
};

const Cache = node_cache.BoundedNodeCache(u64, FakeVal);

/// The cache evicts PER SHARD (each shard capped at ceil(cap/SHARD_COUNT)), so
/// the worst-case total resident is the per-shard cap times the shard count —
/// i.e. the requested cap rounded UP to a multiple of SHARD_COUNT. Eviction
/// being shard-local is what makes it safe under geode's per-shard locks.
fn shardRoundedBound(cap: usize) usize {
    const sc = node_cache.SHARD_COUNT;
    return ((cap + sc - 1) / sc) * sc;
}

fn freeFakeVal(allocator: std.mem.Allocator, v: *FakeVal) void {
    v.free(allocator);
}

fn makeVal(allocator: std.mem.Allocator, id: u64, name: []const u8) !FakeVal {
    return FakeVal{ .id = id, .name = try allocator.dupe(u8, name) };
}

// ---- Tests ---------------------------------------------------------------

test "BoundedNodeCache: put/get round-trips like a plain map under the cap" {
    const a = testing.allocator;
    var eng = FakeEngine.init(a);
    defer eng.deinit();

    var cache = try Cache.init(a, .{
        .cap = 100,
        .free_fn = freeFakeVal,
        .hydrate_fn = FakeEngine.hydrate,
        .hydrate_ctx = &eng,
    });
    defer cache.deinit();

    var i: u64 = 0;
    while (i < 10) : (i += 1) try cache.put(i, try makeVal(a, i, "x"));

    try testing.expectEqual(@as(usize, 10), cache.residentCount());
    const got = cache.get(7).?;
    try testing.expectEqualStrings("x", got.name);
}

test "BoundedNodeCache: resident count never exceeds the cap (self-bounding insert)" {
    const a = testing.allocator;
    var eng = FakeEngine.init(a);
    defer eng.deinit();

    var cache = try Cache.init(a, .{
        .cap = 64,
        .free_fn = freeFakeVal,
        .hydrate_fn = FakeEngine.hydrate,
        .hydrate_ctx = &eng,
    });
    defer cache.deinit();

    // Insert WAY more than the cap. Resident count must plateau at <= cap.
    var i: u64 = 0;
    while (i < 5000) : (i += 1) {
        try cache.put(i, try makeVal(a, i, "v"));
        // also drain retired periodically (simulates a grace point) so the
        // testing allocator doesn't accumulate retired entries forever.
        if (i % 200 == 0) cache.reclaimRetired();
        try testing.expect(cache.residentCount() <= shardRoundedBound(64));
    }
    cache.reclaimRetired();
    try testing.expect(cache.residentCount() <= shardRoundedBound(64));
}

test "BoundedNodeCache: hydrate-on-miss rebuilds an evicted entry from the engine" {
    const a = testing.allocator;
    var eng = FakeEngine.init(a);
    defer eng.deinit();
    // Durable engine has rows 0..999.
    var k: u64 = 0;
    while (k < 1000) : (k += 1) {
        var nbuf: [32]u8 = undefined;
        try eng.put(k, try std.fmt.bufPrint(&nbuf, "name-{d}", .{k}));
    }

    var cache = try Cache.init(a, .{
        .cap = 50,
        .free_fn = freeFakeVal,
        .hydrate_fn = FakeEngine.hydrate,
        .hydrate_ctx = &eng,
    });
    defer cache.deinit();

    // Fill cache so early ids are evicted.
    k = 0;
    while (k < 1000) : (k += 1) {
        try cache.put(k, try makeVal(a, k, "stale-mirror-copy"));
        if (k % 50 == 0) cache.reclaimRetired();
    }
    cache.reclaimRetired();
    try testing.expect(cache.residentCount() <= shardRoundedBound(50));

    // id 3 was certainly evicted. A plain cache get() misses it.
    // getOrHydrate() must rebuild it from the engine with the CORRECT value.
    const hydrated = (try cache.getOrHydrate(3)).?;
    var ebuf: [32]u8 = undefined;
    const expected = try std.fmt.bufPrint(&ebuf, "name-{d}", .{3});
    try testing.expectEqualStrings(expected, hydrated.name);
    try testing.expect(eng.hydrate_calls >= 1);

    // A second getOrHydrate is now a cache hit (no extra hydrate).
    const before = eng.hydrate_calls;
    _ = (try cache.getOrHydrate(3)).?;
    try testing.expectEqual(before, eng.hydrate_calls);
}

test "BoundedNodeCache: bounded ingest then every id hydrates correctly (scaled)" {
    const a = testing.allocator;
    var eng = FakeEngine.init(a);
    defer eng.deinit();

    const N: u64 = 20_000;
    const cap: usize = 1_024;

    // Durable engine is the source of truth for all N ids.
    var k: u64 = 0;
    while (k < N) : (k += 1) {
        var nbuf: [40]u8 = undefined;
        try eng.put(k, try std.fmt.bufPrint(&nbuf, "row-{d}-payload", .{k}));
    }

    var cache = try Cache.init(a, .{
        .cap = cap,
        .free_fn = freeFakeVal,
        .hydrate_fn = FakeEngine.hydrate,
        .hydrate_ctx = &eng,
    });
    defer cache.deinit();

    // Bulk-insert all N (simulates ingest). Resident set must stay bounded —
    // this is the unit-level analogue of the bounded-RSS north-star.
    k = 0;
    while (k < N) : (k += 1) {
        try cache.put(k, try makeVal(a, k, "ingest"));
        if (k % 256 == 0) cache.reclaimRetired(); // periodic grace point
        try testing.expect(cache.residentCount() <= shardRoundedBound(cap));
    }
    cache.reclaimRetired();
    try testing.expect(cache.residentCount() <= shardRoundedBound(cap));

    // Every id — including the many that were evicted — reads back correctly
    // via hydrate-on-miss, with the engine's value (NOT the stale "ingest").
    k = 0;
    while (k < N) : (k += 1) {
        const v = (try cache.getOrHydrate(k)) orelse {
            std.debug.print("missing id {d}\n", .{k});
            return error.MissingId;
        };
        var ebuf: [40]u8 = undefined;
        const expected = try std.fmt.bufPrint(&ebuf, "row-{d}-payload", .{k});
        try testing.expectEqualStrings(expected, v.name);
        // Keep the resident set bounded even as reads hydrate.
        if (k % 256 == 0) cache.reclaimRetired();
        try testing.expect(cache.residentCount() <= shardRoundedBound(cap));
    }
    cache.reclaimRetired();
}

test "BoundedNodeCache: getOrHydrate returns null for an id absent from the engine" {
    const a = testing.allocator;
    var eng = FakeEngine.init(a);
    defer eng.deinit();
    try eng.put(1, "one");

    var cache = try Cache.init(a, .{
        .cap = 10,
        .free_fn = freeFakeVal,
        .hydrate_fn = FakeEngine.hydrate,
        .hydrate_ctx = &eng,
    });
    defer cache.deinit();

    try testing.expect((try cache.getOrHydrate(999)) == null);
    try testing.expect((try cache.getOrHydrate(1)).?.id == 1);
}

test "BoundedNodeCache: remove invalidates the entry and frees it at grace" {
    const a = testing.allocator;
    var eng = FakeEngine.init(a);
    defer eng.deinit();

    var cache = try Cache.init(a, .{
        .cap = 10,
        .free_fn = freeFakeVal,
        .hydrate_fn = FakeEngine.hydrate,
        .hydrate_ctx = &eng,
    });
    defer cache.deinit();

    try cache.put(5, try makeVal(a, 5, "five"));
    try testing.expect(cache.get(5) != null);
    cache.remove(5);
    try testing.expect(cache.get(5) == null);
    // engine has no row 5, so getOrHydrate also returns null after removal.
    try testing.expect((try cache.getOrHydrate(5)) == null);
    cache.reclaimRetired();
}

test "BoundedNodeCache: cap=0 disables bounding (unbounded legacy mode)" {
    const a = testing.allocator;
    var eng = FakeEngine.init(a);
    defer eng.deinit();

    var cache = try Cache.init(a, .{
        .cap = 0, // unbounded
        .free_fn = freeFakeVal,
        .hydrate_fn = FakeEngine.hydrate,
        .hydrate_ctx = &eng,
    });
    defer cache.deinit();

    var i: u64 = 0;
    while (i < 500) : (i += 1) try cache.put(i, try makeVal(a, i, "v"));
    try testing.expectEqual(@as(usize, 500), cache.residentCount());
    cache.reclaimRetired();
    try testing.expectEqual(@as(usize, 500), cache.residentCount());
}

test "BoundedNodeCache: getPtr returns a usable pointer; iterator visits resident entries" {
    const a = testing.allocator;
    var eng = FakeEngine.init(a);
    defer eng.deinit();

    var cache = try Cache.init(a, .{
        .cap = 100,
        .free_fn = freeFakeVal,
        .hydrate_fn = FakeEngine.hydrate,
        .hydrate_ctx = &eng,
    });
    defer cache.deinit();

    try cache.put(42, try makeVal(a, 42, "answer"));
    const p = cache.getPtr(42).?;
    try testing.expectEqualStrings("answer", p.name);

    var count: usize = 0;
    var it = cache.iterator();
    while (it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 1), count);
}

// SONNY-6567 (2): a key removed and inserted again leaves a stale FIFO entry
// ahead of its new one. Eviction popped it and removed the LIVE key; during
// the key's own hydrate-insert that made `getOrHydratePtr` return null, so a
// body that exists in the engine read as absent.
test "BoundedNodeCache: a hydrate-insert never evicts the key it inserts (stale FIFO entry)" {
    const a = testing.allocator;
    var eng = FakeEngine.init(a);
    defer eng.deinit();
    const x: u64 = 1;
    var y: u64 = 2;
    while (node_cache.shardOf(y) != node_cache.shardOf(x)) y += 1;
    try eng.put(x, "x");
    try eng.put(y, "y");

    // One entry per shard.
    var cache = try Cache.init(a, .{
        .cap = node_cache.SHARD_COUNT,
        .free_fn = freeFakeVal,
        .hydrate_fn = FakeEngine.hydrate,
        .hydrate_ctx = &eng,
    });
    defer cache.deinit();

    try cache.put(x, try makeVal(a, x, "x"));
    cache.remove(x); // its FIFO entry stays behind
    try cache.put(y, try makeVal(a, y, "y"));
    const got = (try cache.getOrHydratePtr(x)) orelse return error.ExistingBodyReadAsAbsent;
    try testing.expectEqualStrings("x", got.name);
    cache.reclaimRetired();
}
