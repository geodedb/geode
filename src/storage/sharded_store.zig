// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! N-way sharded HashMap wrapper.  Each shard is an independent
//! `std.AutoHashMap` with its own allocator backing.  Keys route to
//! shard `shardIndex(key) = splitmix64(key) % SHARD_COUNT`.
//!
//! Concurrency model: this type is single-threaded by itself.  The
//! per-shard `std.Io.RwLock`s that gate concurrent access live on
//! `ManagedGraph` (see `graph_storage_adapter.zig`), NOT here —
//! the separation exists so tests can exercise the sharding logic
//! without a thread runtime.
//!
//! CANARY: REQ=REQ-PERF-SHARDED-STORE-001; FEATURE="ShardedStore"; ASPECT=DataStructure; STATUS=TESTED; TEST=tests/test_sharded_store.zig; OWNER=storage; UPDATED=2026-04-24

const std = @import("std");

/// Number of shards.  Powers of two are fastest (bitmask route) but
/// any value works.  16 is chosen to match the msft-graph worker
/// count and the target fan-in for the 8 k+ edge files.
pub const SHARD_COUNT: usize = 16;

/// Fast integer mixing (splitmix64) — avalanches both low and high
/// bits so consecutive node_ids spread across shards.  This matters:
/// `graph_store.next_node_id` allocates monotonically, so a
/// low-bits-only hash would put 16 consecutive new ids on 16
/// different shards which is actually fine, but the same function
/// is reused for edge source_ids which can be arbitrary.
pub fn shardIndex(key: u64) usize {
    var z = key +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    z = z ^ (z >> 31);
    return @as(usize, @intCast(z % SHARD_COUNT));
}

/// Generic sharded store over comptime-known K/V.  K must be an
/// unsigned integer type fitting in u64 — enforced at comptime so
/// a future accidental use with `i64` or `i32` fails to compile
/// rather than panicking at runtime on negative values.
pub fn ShardedStore(comptime K: type, comptime V: type) type {
    comptime {
        const info = @typeInfo(K);
        if (info != .int) @compileError("ShardedStore: K must be an integer type");
        if (info.int.bits > 64) @compileError("ShardedStore: K must fit in u64");
        if (info.int.signedness != .unsigned) @compileError("ShardedStore: K must be unsigned");
    }
    return struct {
        const Self = @This();
        pub const Shard = std.AutoHashMap(K, V);
        /// Re-export so callers can spell it the same way they would
        /// with a plain `AutoHashMap`: `GetOrPutResult { found_existing, value_ptr, key_ptr }`.
        pub const GetOrPutResult = Shard.GetOrPutResult;
        /// Entry returned by `fetchRemove` — `{ key, value }`.
        pub const KV = Shard.KV;

        allocator: std.mem.Allocator,
        shards: [SHARD_COUNT]Shard,

        pub fn init(allocator: std.mem.Allocator) !Self {
            var shards: [SHARD_COUNT]Shard = undefined;
            for (&shards) |*s| s.* = Shard.init(allocator);
            return .{ .allocator = allocator, .shards = shards };
        }

        pub fn deinit(self: *Self) void {
            for (&self.shards) |*s| s.deinit();
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            const idx = shardIndex(@as(u64, key));
            try self.shards[idx].put(key, value);
        }

        pub fn get(self: *const Self, key: K) ?V {
            const idx = shardIndex(@as(u64, key));
            return self.shards[idx].get(key);
        }

        pub fn getPtr(self: *const Self, key: K) ?*V {
            const idx = shardIndex(@as(u64, key));
            return self.shards[idx].getPtr(key);
        }

        /// Remove and return the prior value, or null if not present.
        /// Mirrors `AutoHashMap.fetchRemove(k).?.value`.
        pub fn remove(self: *Self, key: K) ?V {
            const idx = shardIndex(@as(u64, key));
            if (self.shards[idx].fetchRemove(key)) |kv| return kv.value;
            return null;
        }

        /// Mirror of `AutoHashMap.fetchRemove` returning the full
        /// `?KV` entry.  Kept separate from `remove` because callers
        /// that need to release `kv.value.deinit()` (e.g. ArrayList
        /// values in adjacency indexes) want direct access to the
        /// entry, not just the value.
        pub fn fetchRemove(self: *Self, key: K) ?KV {
            const idx = shardIndex(@as(u64, key));
            return self.shards[idx].fetchRemove(key);
        }

        pub fn contains(self: *const Self, key: K) bool {
            const idx = shardIndex(@as(u64, key));
            return self.shards[idx].contains(key);
        }

        /// Mirror of `AutoHashMap.getOrPut`.  Returns the underlying
        /// shard's `GetOrPutResult` — the caller reads / writes
        /// `result.value_ptr.*` in the usual way.
        pub fn getOrPut(self: *Self, key: K) !GetOrPutResult {
            const idx = shardIndex(@as(u64, key));
            return self.shards[idx].getOrPut(key);
        }

        pub fn count(self: *const Self) usize {
            var total: usize = 0;
            for (&self.shards) |*s| total += s.count();
            return total;
        }

        /// Number of entries in the shard at `idx`.  Used by tests
        /// and by Phase 2 rebalancing diagnostics.  Named `shardLen`
        /// (not `shardCount`) to avoid ambiguity with "number of
        /// shards" which is `SHARD_COUNT`.
        pub fn shardLen(self: *const Self, idx: usize) usize {
            return self.shards[idx].count();
        }

        /// Pre-size every shard to hold `total_capacity / SHARD_COUNT`
        /// entries (rounded up).  Matches the bulk-load reservation
        /// pattern in `GraphStore.reserve` — the caller specifies the
        /// total expected-entry count across all shards.
        pub fn ensureTotalCapacity(self: *Self, total_capacity: u32) !void {
            const per_shard: u32 = (total_capacity + @as(u32, @intCast(SHARD_COUNT)) - 1) /
                @as(u32, @intCast(SHARD_COUNT));
            for (&self.shards) |*s| try s.ensureTotalCapacity(per_shard);
        }

        /// Clear every shard in place, retaining each shard's backing
        /// capacity.  Used by persistence / snapshot-restore paths.
        pub fn clearRetainingCapacity(self: *Self) void {
            for (&self.shards) |*s| s.clearRetainingCapacity();
        }

        /// Pre-reserve additional capacity proportionally across all
        /// shards.  Each shard gets `ceil(additional / SHARD_COUNT)`
        /// reserved.  Mirrors `AutoHashMap.ensureUnusedCapacity`.
        pub fn ensureUnusedCapacity(self: *Self, additional: u32) !void {
            const per_shard: u32 = (additional + @as(u32, @intCast(SHARD_COUNT)) - 1) /
                @as(u32, @intCast(SHARD_COUNT));
            for (&self.shards) |*s| try s.ensureUnusedCapacity(per_shard);
        }

        /// Iterate every (k, v) pair across every shard, in shard
        /// order.  Used by persistence and full-scan reads.  Callers
        /// that need a consistent snapshot must take a read lock on
        /// EVERY shard before calling — see `ManagedGraph.scanRead`.
        pub fn iterator(self: *const Self) Iterator {
            return .{ .owner = self, .shard_idx = 0, .inner = self.shards[0].iterator() };
        }

        /// Iterate every key across every shard, in shard order.
        /// Equivalent to `iterator()` but yields `*K` instead of full
        /// `Entry` structs.
        pub fn keyIterator(self: *const Self) KeyIterator {
            return .{ .owner = self, .shard_idx = 0, .inner = self.shards[0].keyIterator() };
        }

        pub const Iterator = struct {
            owner: *const Self,
            shard_idx: usize,
            inner: Shard.Iterator,

            pub fn next(it: *Iterator) ?Shard.Entry {
                while (true) {
                    if (it.inner.next()) |entry| return entry;
                    it.shard_idx += 1;
                    if (it.shard_idx >= SHARD_COUNT) return null;
                    it.inner = it.owner.shards[it.shard_idx].iterator();
                }
            }
        };

        pub const KeyIterator = struct {
            owner: *const Self,
            shard_idx: usize,
            inner: Shard.KeyIterator,

            pub fn next(it: *KeyIterator) ?*K {
                while (true) {
                    if (it.inner.next()) |k| return k;
                    it.shard_idx += 1;
                    if (it.shard_idx >= SHARD_COUNT) return null;
                    it.inner = it.owner.shards[it.shard_idx].keyIterator();
                }
            }
        };
    };
}
