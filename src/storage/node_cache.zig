// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
//! BoundedNodeCache — a bounded, evict-freely cache over `ShardedStore(K, V)`.
//!
//! geode is DISK-BACKED: the storage engine is the durable store of record and
//! every write is dual-written (write-through) to BOTH the engine and the
//! in-memory `GraphStore.nodes` map. That map used to be an UNBOUNDED mirror —
//! a full `Node` resident for every node forever (~8 KB/node) — which made a
//! large bulk ingest OOM (14.27M nodes → ~114 GB resident).
//!
//! This type bounds the resident set: it keeps at most `cap` entries and,
//! because the engine can rebuild any node by id, evicts cold entries past the
//! cap. A lookup miss is served by HYDRATE-ON-MISS (rebuild from the engine via
//! a caller-supplied callback) so the read sites stay transparent.
//!
//! ## Pointer-lifetime safety (THE critical invariant)
//!
//! `getPtr` returns `*V` that callers store and use across an extended span,
//! all under an enclosing read lock held by the caller (geode's per-graph /
//! global SHARED store lock for the whole query). Eviction must therefore NOT
//! free an entry's heap while a caller could still hold a pointer into it.
//!
//! Eviction is split into two phases:
//!   1. UNLINK (cheap, frequent): remove the entry from the map. Future lookups
//!      miss → hydrate-on-miss. The value's heap is NOT freed; it is pushed onto
//!      the `retired` list.
//!   2. RECLAIM (`reclaimRetired`, called at a GRACE boundary): free every
//!      retired value via `free_fn`. The caller must only call this when no
//!      reader can hold a pointer to a retired value — geode calls it inside the
//!      per-graph EXCLUSIVE checkpoint window and at deinit, which drains all
//!      SHARED holders.
//!
//! Between grace points, evicted entries are only unlinked, never freed, so
//! outstanding `*V` pointers remain valid. RSS is bounded by
//! `cap + retire_backlog`; the backlog is bounded by the checkpoint cadence,
//! not the total node count, so RSS plateaus.
//!
//! This type is NOT internally synchronized — like `ShardedStore`, the consumer
//! provides the locking. geode mutates it (put/evict/remove/reclaim) under the
//! same locks that already serialize `GraphStore.nodes` writes, and reads under
//! the shared store lock.
//!
//! CANARY: REQ=REQ-NODE-CACHE-001; FEATURE="BoundedNodeMirror"; ASPECT=Eviction; STATUS=TESTED; TEST=tests/test_bounded_node_cache.zig; OWNER=storage; UPDATED=2026-06-22

const std = @import("std");
const sharded_store = @import("graph_storage").sharded_store;

pub const SHARD_COUNT = sharded_store.SHARD_COUNT;

/// Default resident cap when `GEODE_NODE_CACHE_ENTRIES` is unset.
pub const DEFAULT_CAP: usize = 1_000_000;

/// Bounded cache over `ShardedStore(K, V)`.
///
/// `K` must be an unsigned integer (enforced by `ShardedStore`). `V` is the
/// cached value type whose heap is freed by `free_fn`.
pub fn BoundedNodeCache(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        pub const Store = sharded_store.ShardedStore(K, V);
        pub const GetOrPutResult = Store.GetOrPutResult;
        pub const KV = Store.KV;
        pub const Iterator = Store.Iterator;
        pub const KeyIterator = Store.KeyIterator;

        /// Caller-supplied per-value free function (custom for `Node`).
        pub const FreeFn = *const fn (allocator: std.mem.Allocator, value: *V) void;
        /// Caller-supplied hydrate-on-miss callback. Returns a freshly-built `V`
        /// (its heap owned by the cache) rebuilt from the durable engine, or
        /// null if the id does not exist there.
        pub const HydrateFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, key: K) anyerror!?V;

        pub const Options = struct {
            /// Max resident entries. 0 = unbounded (legacy mirror behaviour).
            cap: usize,
            free_fn: FreeFn,
            /// Optional — when null, `getOrHydrate` behaves like `getPtr`
            /// (no rehydration; used by isolated tests / pre-adapter startup).
            hydrate_fn: ?HydrateFn = null,
            hydrate_ctx: ?*anyopaque = null,
        };

        /// Per-shard eviction state. The cache is partitioned by the SAME
        /// `shardIndex(key)` as the backing `ShardedStore`, so a `put(key)`
        /// evicts ONLY within `shardIndex(key)`'s shard. The consumer holds that
        /// shard's lock EXCLUSIVE around the write (geode: ManagedGraph
        /// `shard_locks[idx]`), so eviction's map mutation is serialised against
        /// concurrent point reads of the same shard exactly like a normal insert
        /// — eviction adds no new cross-shard race.
        const Shard = struct {
            /// FIFO insertion-order queue of this shard's keys. A key may appear
            /// stale (already removed/re-inserted); eviction validates residence
            /// before unlinking, so stale entries are skipped cheaply.
            fifo: std.Deque(K) = .empty,
            /// Values unlinked from the map but not yet freed (reclaim phase).
            retired: std.ArrayList(V) = .empty,
            /// Serialises hydrate-on-miss INSERTS for this shard so two readers
            /// missing the same (or same-shard) key cannot race on the backing
            /// AutoHashMap. Hits do not take it (they rely, as before, on the
            /// caller's per-graph rwlock excluding per-graph-exclusive evict/
            /// reclaim). Leaf lock: held only across getOrPut+insert, never
            /// across the engine read or another cache call.
            hydrate_mutex: std.Io.Mutex = std.Io.Mutex.init,
        };

        allocator: std.mem.Allocator,
        store: Store,
        /// Effective TOTAL cap currently in force (0 = unbounded). Forced to 0
        /// while no hydrate hook is installed (see init / setHydrate).
        cap: usize,
        /// Cap requested by config, applied once a hydrate hook is installed.
        requested_cap: usize,
        free_fn: FreeFn,
        hydrate_fn: ?HydrateFn,
        hydrate_ctx: ?*anyopaque,

        shards: [SHARD_COUNT]Shard,

        // Observability counters (monotonic; read for metrics/tests).
        evictions_total: u64 = 0,
        hydrations_total: u64 = 0,
        reclaimed_total: u64 = 0,

        pub fn init(allocator: std.mem.Allocator, opts: Options) !Self {
            // SAFETY: eviction is only correct when evicted entries can be
            // rebuilt. Without a hydrate callback an evicted node would be lost,
            // so a cache with no hydrate_fn is forced UNBOUNDED regardless of
            // the requested cap. The consumer enables bounding by installing the
            // hydrate hook (setHydrate) once the durable engine is available.
            const effective_cap: usize = if (opts.hydrate_fn == null) 0 else opts.cap;
            return .{
                .allocator = allocator,
                .store = try Store.init(allocator),
                .cap = effective_cap,
                .requested_cap = opts.cap,
                .free_fn = opts.free_fn,
                .hydrate_fn = opts.hydrate_fn,
                .hydrate_ctx = opts.hydrate_ctx,
                .shards = [_]Shard{.{}} ** SHARD_COUNT,
            };
        }

        /// Per-shard resident cap (ceil(cap / SHARD_COUNT)). 0 = unbounded.
        inline fn perShardCap(self: *const Self) usize {
            if (self.cap == 0) return 0;
            return (self.cap + SHARD_COUNT - 1) / SHARD_COUNT;
        }

        pub fn deinit(self: *Self) void {
            // Free retired values first, then every resident value.
            self.reclaimRetired();
            var it = self.store.iterator();
            while (it.next()) |entry| {
                self.free_fn(self.allocator, entry.value_ptr);
            }
            self.store.deinit();
            for (&self.shards) |*sh| {
                sh.fifo.deinit(self.allocator);
                sh.retired.deinit(self.allocator);
            }
        }

        /// Number of entries currently resident in the map.
        pub fn residentCount(self: *const Self) usize {
            return self.store.count();
        }

        /// Alias for residentCount — mirrors `ShardedStore.count` so the cache
        /// can drop in for the old `GraphStore.nodes`.
        pub fn count(self: *const Self) usize {
            return self.store.count();
        }

        pub fn retiredCount(self: *const Self) usize {
            var total: usize = 0;
            for (&self.shards) |*sh| total += sh.retired.items.len;
            return total;
        }

        /// Install the hydrate-on-miss hook and activate the configured cap.
        /// Called by the consumer once the durable engine (storage adapter) is
        /// available, so eviction becomes safe (evicted entries can be rebuilt).
        /// Idempotent.
        pub fn setHydrate(self: *Self, hydrate_fn: HydrateFn, hydrate_ctx: *anyopaque) void {
            self.hydrate_fn = hydrate_fn;
            self.hydrate_ctx = hydrate_ctx;
            self.cap = self.requested_cap;
        }

        /// Current effective cap (0 = unbounded). For diagnostics/metrics.
        pub fn effectiveCap(self: *const Self) usize {
            return self.cap;
        }

        // ---- Read API (pure cache; no hydration) ----------------------------

        pub fn get(self: *const Self, key: K) ?V {
            return self.store.get(key);
        }

        pub fn getPtr(self: *const Self, key: K) ?*V {
            return self.store.getPtr(key);
        }

        pub fn contains(self: *const Self, key: K) bool {
            return self.store.contains(key);
        }

        // ---- Read API with hydrate-on-miss ----------------------------------

        /// Cache hit → return the resident pointer. Miss → hydrate from the
        /// engine, insert (evicting if over cap), and return the pointer. Null
        /// only if the id exists in neither the cache nor the engine.
        ///
        /// NOTE: on a miss this MUTATES the cache (insert + maybe evict), so the
        /// caller must hold whatever lock serializes cache writes — NOT merely a
        /// shared read lock. geode routes shared-lock read sites that may miss
        /// through this only where it already holds (or can take) the write-side
        /// guarantee; pure shared readers use `getPtr` and tolerate a null on a
        /// not-yet-hydrated id (then retry under the write path).
        pub fn getOrHydratePtr(self: *Self, key: K) !?*V {
            // Fast path: resident hit (lock-free, like a bare ShardedStore get).
            if (self.store.getPtr(key)) |p| return p;
            const hydrate = self.hydrate_fn orelse return null;
            const ctx = self.hydrate_ctx orelse return null;

            // Build the node from the engine OUTSIDE the shard lock (slow I/O,
            // and the callback must not re-enter this cache).
            var value = (try hydrate(ctx, self.allocator, key)) orelse return null;

            // Insert under the shard's hydrate mutex so concurrent hydrations of
            // the same shard cannot race on the backing AutoHashMap. Re-check
            // residence under the lock (another thread may have hydrated the same
            // key meanwhile) and, if so, drop our duplicate build.
            const idx = sharded_store.shardIndex(@as(u64, key));
            const io = std.Io.Threaded.global_single_threaded.io();
            self.shards[idx].hydrate_mutex.lockUncancelable(io);
            defer self.shards[idx].hydrate_mutex.unlock(io);
            if (self.store.getPtr(key)) |p| {
                self.free_fn(self.allocator, &value);
                return p;
            }
            self.hydrations_total += 1;
            try self.insertEvicting(key, value);
            return self.store.getPtr(key);
        }

        /// By-value variant of `getOrHydratePtr`.
        pub fn getOrHydrate(self: *Self, key: K) !?V {
            if (try self.getOrHydratePtr(key)) |p| return p.* else return null;
        }

        // ---- Write API ------------------------------------------------------

        /// Insert/overwrite. Self-bounding: if inserting a NEW key pushes the
        /// resident set past `cap`, cold entries are evicted (unlinked + retired)
        /// to make room. An overwrite of an existing key frees the OLD value via
        /// the retire list (its heap may still be referenced by a reader).
        pub fn put(self: *Self, key: K, value: V) !void {
            try self.insertEvicting(key, value);
        }

        /// Mirror of `ShardedStore.getOrPut`. The caller writes
        /// `result.value_ptr.*`. When this creates a NEW entry the caller is
        /// responsible for recording it for eviction via `noteInserted(key)`
        /// (we cannot evict mid-getOrPut because the value isn't written yet).
        pub fn getOrPut(self: *Self, key: K) !GetOrPutResult {
            return self.store.getOrPut(key);
        }

        /// Record that `key` was just inserted via `getOrPut` so it participates
        /// in eviction, then evict its shard down to cap if needed. Safe to call
        /// for an existing key (it just refreshes FIFO position).
        pub fn noteInserted(self: *Self, key: K) !void {
            const idx = sharded_store.shardIndex(@as(u64, key));
            try self.shards[idx].fifo.pushBack(self.allocator, key);
            try self.evictShardToCap(idx);
        }

        /// Remove `key`. The removed value is retired (freed at the next
        /// `reclaimRetired`), never freed inline, to protect outstanding
        /// pointers.
        pub fn remove(self: *Self, key: K) void {
            if (self.store.fetchRemove(key)) |kv| {
                const idx = sharded_store.shardIndex(@as(u64, key));
                self.shards[idx].retired.append(self.allocator, kv.value) catch {
                    // OOM on the retire list: fall back to inline free. This is
                    // only reached under memory pressure; the caller holds the
                    // exclusive write path for `remove`, so no shared reader is
                    // mid-use of this specific entry on THIS thread's op.
                    var v = kv.value;
                    self.free_fn(self.allocator, &v);
                };
            }
        }

        /// Mirror of `ShardedStore.fetchRemove` for callers that must inspect
        /// the removed value (e.g. to free sub-objects themselves). The caller
        /// then owns the value and must free it; it is NOT retired here.
        pub fn fetchRemove(self: *Self, key: K) ?KV {
            return self.store.fetchRemove(key);
        }

        /// Unlink `key` from the map WITHOUT retiring or freeing its value. For
        /// callers that have ALREADY freed (or will free) the value's heap
        /// themselves — e.g. the explicit delete path, which frees inline under
        /// the exclusive write lock exactly as the pre-cache mirror did. Using
        /// `remove` there would double-free (retire + caller free). Returns true
        /// if an entry was present. A stale FIFO entry, if any, is skipped at
        /// eviction time.
        pub fn unlink(self: *Self, key: K) bool {
            return self.store.remove(key) != null;
        }

        pub fn ensureTotalCapacity(self: *Self, total_capacity: u32) !void {
            // Cap the pre-reservation at the resident cap so a huge ingest hint
            // doesn't pre-allocate the very table we're trying to bound.
            const want: u32 = if (self.cap == 0)
                total_capacity
            else
                @min(total_capacity, @as(u32, @intCast(@min(self.cap, std.math.maxInt(u32)))));
            try self.store.ensureTotalCapacity(want);
        }

        pub fn ensureUnusedCapacity(self: *Self, additional: u32) !void {
            const want: u32 = if (self.cap == 0)
                additional
            else
                @min(additional, @as(u32, @intCast(@min(self.cap, std.math.maxInt(u32)))));
            try self.store.ensureUnusedCapacity(want);
        }

        /// Clear all resident entries (freeing their values) and every shard's
        /// retire list + FIFO. Used by snapshot-restore / reset paths.
        pub fn clearRetainingCapacity(self: *Self) void {
            self.reclaimRetired();
            var it = self.store.iterator();
            while (it.next()) |entry| self.free_fn(self.allocator, entry.value_ptr);
            self.store.clearRetainingCapacity();
            for (&self.shards) |*sh| {
                while (sh.fifo.popFront()) |_| {}
            }
        }

        // ---- Iteration ------------------------------------------------------

        /// Iterate resident entries. NOTE: this visits only what is currently
        /// resident — NOT every node in the engine. Callers that need every
        /// node must stream from the engine instead.
        pub fn iterator(self: *const Self) Iterator {
            return self.store.iterator();
        }

        pub fn keyIterator(self: *const Self) KeyIterator {
            return self.store.keyIterator();
        }

        // ---- Grace-point reclamation ----------------------------------------

        /// Free every retired value across all shards. MUST be called only at a
        /// grace boundary where no reader can hold a pointer to ANY retired value
        /// (geode: a GLOBAL exclusive window, or deinit). For the per-graph
        /// checkpoint window use `reclaimRetiredWhere` so only the checkpointed
        /// graph's nodes — whose readers the per-graph exclusive lock drained —
        /// are freed.
        pub fn reclaimRetired(self: *Self) void {
            for (&self.shards) |*sh| {
                if (sh.retired.items.len == 0) continue;
                for (sh.retired.items) |*v| self.free_fn(self.allocator, v);
                self.reclaimed_total += sh.retired.items.len;
                sh.retired.clearRetainingCapacity();
            }
        }

        pub const RetirePredicate = *const fn (ctx: *anyopaque, value: *const V) bool;

        /// Free only the retired values for which `pred` returns true, compacting
        /// each shard's retire list in place. Used at the per-graph EXCLUSIVE
        /// checkpoint window: the predicate matches the checkpointed graph, so
        /// only nodes whose readers that lock drained are freed; nodes of other
        /// graphs stay retired until their own grace window. Safe: a non-matching
        /// entry is neither freed nor moved out of the retire list.
        pub fn reclaimRetiredWhere(self: *Self, ctx: *anyopaque, pred: RetirePredicate) void {
            for (&self.shards) |*sh| {
                if (sh.retired.items.len == 0) continue;
                var w: usize = 0;
                for (sh.retired.items) |*v| {
                    if (pred(ctx, v)) {
                        self.free_fn(self.allocator, v);
                        self.reclaimed_total += 1;
                    } else {
                        // keep: compact toward the front
                        sh.retired.items[w] = v.*;
                        w += 1;
                    }
                }
                sh.retired.shrinkRetainingCapacity(w);
            }
        }

        // ---- Internals ------------------------------------------------------

        fn insertEvicting(self: *Self, key: K, value: V) !void {
            const idx = sharded_store.shardIndex(@as(u64, key));
            const gop = try self.store.getOrPut(key);
            if (gop.found_existing) {
                // Overwrite: retire the OLD value (a reader may hold a pointer
                // to it) and store the new one. Don't re-queue in FIFO — the key
                // is already tracked.
                try self.shards[idx].retired.append(self.allocator, gop.value_ptr.*);
                gop.value_ptr.* = value;
                return;
            }
            // New entry.
            gop.value_ptr.* = value;
            // Record for eviction. If the FIFO append fails we must not leave an
            // untracked entry (it could never be evicted), so undo the insert.
            self.shards[idx].fifo.pushBack(self.allocator, key) catch |err| {
                if (self.store.fetchRemove(key)) |kv| {
                    var v = kv.value;
                    self.free_fn(self.allocator, &v);
                }
                return err;
            };
            try self.evictShardToCap(idx);
        }

        /// Evict (unlink + retire) cold entries from shard `idx` until that
        /// shard's resident count <= the per-shard cap. cap==0 disables
        /// eviction. SAFETY: only mutates shard `idx`'s map partition, FIFO, and
        /// retire list — the consumer holds shard `idx`'s lock EXCLUSIVE, so this
        /// never touches a partition another thread could be reading.
        fn evictShardToCap(self: *Self, idx: usize) !void {
            const per_shard = self.perShardCap();
            if (per_shard == 0) return;
            while (self.store.shardLen(idx) > per_shard) {
                const victim_key = self.shards[idx].fifo.popFront() orelse return;
                if (self.store.fetchRemove(victim_key)) |kv| {
                    try self.shards[idx].retired.append(self.allocator, kv.value);
                    self.evictions_total += 1;
                }
                // else: stale FIFO entry (already removed/overwritten) — skip.
            }
        }
    };
}

// ============================================================================
// Inline unit tests (the comprehensive suite is tests/test_bounded_node_cache.zig)
// ============================================================================

test "node_cache: SHARD_COUNT re-exported" {
    try std.testing.expect(SHARD_COUNT >= 1);
}
