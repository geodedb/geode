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
/// integer type (u64 is the only caller today).
pub fn ShardedStore(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        pub const Shard = std.AutoHashMap(K, V);

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
            const idx = shardIndex(@as(u64, @intCast(key)));
            try self.shards[idx].put(key, value);
        }

        pub fn get(self: *const Self, key: K) ?V {
            const idx = shardIndex(@as(u64, @intCast(key)));
            return self.shards[idx].get(key);
        }

        pub fn getPtr(self: *Self, key: K) ?*V {
            const idx = shardIndex(@as(u64, @intCast(key)));
            return self.shards[idx].getPtr(key);
        }

        pub fn remove(self: *Self, key: K) ?V {
            const idx = shardIndex(@as(u64, @intCast(key)));
            if (self.shards[idx].fetchRemove(key)) |kv| return kv.value;
            return null;
        }

        pub fn contains(self: *const Self, key: K) bool {
            const idx = shardIndex(@as(u64, @intCast(key)));
            return self.shards[idx].contains(key);
        }

        pub fn count(self: *const Self) usize {
            var total: usize = 0;
            for (&self.shards) |*s| total += s.count();
            return total;
        }

        pub fn shardCount(self: *const Self, idx: usize) usize {
            return self.shards[idx].count();
        }

        /// Iterate every (k, v) pair across every shard, in shard
        /// order.  Used by persistence and full-scan reads.  Callers
        /// that need a consistent snapshot must take a read lock on
        /// EVERY shard before calling — see `ManagedGraph.scanRead`.
        pub fn iterator(self: *Self) Iterator {
            return .{ .owner = self, .shard_idx = 0, .inner = self.shards[0].iterator() };
        }

        pub const Iterator = struct {
            owner: *Self,
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
    };
}
