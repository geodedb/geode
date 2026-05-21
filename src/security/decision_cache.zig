// CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=Module; STATUS=TESTED; TEST=tests/test_gps_decision_cache.zig; OWNER=security; UPDATED=2026-05-20
//
// decision_cache.zig — bounded LRU decision cache for the GPS decide() hot path.
//
// Keyed by (auth_version, policy_version, action_tag, resource_hash).
// auth_version=0 is the legacy/anonymous path and is never cached.
// Invalidated atomically whenever a policy mutation occurs (addPolicy / removePolicy).
//
// Thread-safety: all public methods are serialized by an internal mutex.
// The hit/miss counters use atomic operations so they don't contend with the mutex.
//
// LRU eviction: O(n) walk over the hash-map to find the least-recently-used entry.
// At the default capacity of 1024 this costs ~4 µs on a modern core — acceptable
// for a security boundary, and far cheaper than re-evaluating the policy catalog.

const std = @import("std");
const gps_types = @import("gps.zig");

// CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=KeyType; STATUS=TESTED; TEST=tests/test_gps_decision_cache.zig; OWNER=security; UPDATED=2026-05-20

/// Four-tuple that uniquely identifies a cached authorization decision.
pub const Key = struct {
    auth_version: u64,
    policy_version: u64,
    action_tag: u8, // matches @intFromEnum(gps.Action)
    resource_hash: u64,
    /// CANARY: REQ=REQ-GPS-CACHE-002; FEATURE="GPS Decision Cache"; ASPECT=PrincipalIdentityKey; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/gps_phase7_alter_show_explain.yml; OWNER=security; UPDATED=2026-05-21
    /// Hash of the principal's username. Without this field, two principals
    /// sharing the same (auth_version, policy_version, action, resource) key
    /// would collide and the decision for one principal could be served to
    /// another — surfaced by the Phase 7 black-box specs as a critical
    /// correctness bug.
    principal_hash: u64 = 0,
};

// CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=EntryType; STATUS=TESTED; TEST=tests/test_gps_decision_cache.zig; OWNER=security; UPDATED=2026-05-20

/// One cached authorization outcome.
pub const Entry = struct {
    key: Key,
    decision: gps_types.PolicyDecision,
    /// Monotonic access counter (not a real timestamp). Larger = more recent.
    /// Sufficient for LRU ordering; sidesteps Zig 0.16's removal of
    /// std.time.nanoTimestamp.
    last_access_seq: u64,
};

/// Monotonic counter incremented on every cache access. Provides ordering
/// for LRU eviction without depending on a wall-clock or platform-specific
/// monotonic timer.
var g_access_seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);

fn nextAccessSeq() u64 {
    return g_access_seq.fetchAdd(1, .monotonic);
}

/// Default cache capacity (entries). 1024 covers the common workload of a few
/// hundred principals across a handful of graphs without exceeding a few KB of RAM.
pub const DEFAULT_CAPACITY: usize = 1024;

// CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=CacheImpl; STATUS=TESTED; TEST=tests/test_gps_decision_cache.zig; OWNER=security; UPDATED=2026-05-20

pub const DecisionCache = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMap(Key, Entry),
    capacity: usize,
    mutex: std.Io.Mutex,
    hits: std.atomic.Value(u64),
    misses: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, capacity: usize) DecisionCache {
        return .{
            .allocator = allocator,
            .map = std.AutoHashMap(Key, Entry).init(allocator),
            .capacity = capacity,
            .mutex = std.Io.Mutex.init,
            .hits = std.atomic.Value(u64).init(0),
            .misses = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *DecisionCache) void {
        self.map.deinit();
    }

    // CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=Lookup; STATUS=TESTED; TEST=tests/test_gps_decision_cache.zig; OWNER=security; UPDATED=2026-05-20
    /// Check the cache for a previously computed decision.
    /// Returns the cached PolicyDecision on a hit, null on a miss.
    /// Updates the entry's last_access_ns on a hit to refresh its LRU position.
    pub fn lookup(self: *DecisionCache, key: Key) ?gps_types.PolicyDecision {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        if (self.map.getPtr(key)) |entry| {
            entry.last_access_seq = nextAccessSeq();
            _ = self.hits.fetchAdd(1, .monotonic);
            return entry.decision;
        }
        _ = self.misses.fetchAdd(1, .monotonic);
        return null;
    }

    // CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=Insert; STATUS=TESTED; TEST=tests/test_gps_decision_cache.zig; OWNER=security; UPDATED=2026-05-20
    /// Store a decision.  If the cache is at capacity, the least-recently-used
    /// entry is evicted first.  Allocation errors are propagated to the caller;
    /// decide() should silently swallow them so a cache failure never blocks auth.
    pub fn insert(self: *DecisionCache, key: Key, decision: gps_types.PolicyDecision) !void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        if (self.map.count() >= self.capacity) {
            // Simple O(n) LRU eviction: walk the map and find the oldest entry.
            var oldest_key: ?Key = null;
            var oldest_seq: u64 = std.math.maxInt(u64);
            var it = self.map.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.last_access_seq < oldest_seq) {
                    oldest_seq = kv.value_ptr.last_access_seq;
                    oldest_key = kv.key_ptr.*;
                }
            }
            if (oldest_key) |k| _ = self.map.remove(k);
        }
        try self.map.put(key, .{
            .key = key,
            .decision = decision,
            .last_access_seq = nextAccessSeq(),
        });
    }

    // CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=Invalidate; STATUS=TESTED; TEST=tests/test_gps_decision_cache.zig; OWNER=security; UPDATED=2026-05-20
    /// Discard all cached decisions. Called after every policy mutation so that
    /// stale entries cannot override newly-added deny or allow policies.
    pub fn invalidateAll(self: *DecisionCache) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        self.map.clearRetainingCapacity();
    }

    /// Read the hit counter without acquiring the map mutex.
    pub fn getHits(self: *const DecisionCache) u64 {
        return self.hits.load(.monotonic);
    }

    /// Read the miss counter without acquiring the map mutex.
    pub fn getMisses(self: *const DecisionCache) u64 {
        return self.misses.load(.monotonic);
    }

    /// Return the number of entries currently stored in the cache.
    pub fn count(self: *DecisionCache) usize {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        return self.map.count();
    }
};

// ---------------------------------------------------------------------------
// Process-global singleton (set at server startup, null in test contexts)
// ---------------------------------------------------------------------------

var g_cache: ?*DecisionCache = null;

/// Install the process-global cache.  Called once at server startup.
pub fn setGlobalCache(c: *DecisionCache) void {
    g_cache = c;
}

/// Return the process-global cache, or null when not yet initialised.
pub fn getGlobalCache() ?*DecisionCache {
    return g_cache;
}

/// Reset the global cache pointer to null.  Use in tests or on shutdown.
pub fn clearGlobalCache() void {
    g_cache = null;
}
