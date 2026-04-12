# Distributed Module Performance Optimization Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate per-call parallel-pool allocation, parallelize 2PC messaging, add connection limits, use atomic counters, add cache eviction, and optimize ConsistentHash lookup.
**Architecture:** `ParallelPool` becomes a long-lived struct field on coordinators instead of per-call allocation. 2PC prepare/commit loops dispatch to shards in parallel via the shared thread-pool wrapper. TransportStatistics counters become atomic. QueryCache gains a max-size eviction policy. ConsistentHash.getNodes reuses the existing binary search from getNode.
**Tech Stack:** Zig 0.15.1, `@import("parallel/thread_pool_parallel")`, `std.atomic.Value`, `std.AutoHashMap`

---

## Task 1: Store ParallelPool as struct field (PERF-D007)

**Files:**

- Modify: `src/distributed/query_coordinator.zig` (lines 19-43, 148-149)
- Modify: `src/distributed/txn_coordinator.zig` (lines 35-49)

### Steps

- [ ] **1.1** Add a `pool` field to `QueryCoordinator`:

```zig
// In QueryCoordinator struct (line ~19), add field:
pool: parallel_wrapper.ParallelPool,
```

- [ ] **1.2** Initialize the pool in `QueryCoordinator.init` and deinit in `deinit`:

```zig
// In init (line ~30), add to the return struct:
.pool = parallel_wrapper.ParallelPool.init(allocator, null),

// In deinit (line ~40), add before existing deinit calls:
self.pool.deinit();
```

- [ ] **1.3** Replace the per-call pool creation in `scatterQuery` (line ~148):

```zig
// Replace lines 148-149:
//     var pool = parallel_wrapper.ParallelPool.init(self.allocator, null);
//     defer pool.deinit();
// With:
// Reuse coordinator-owned pool (no per-call allocation)
```

Update the `parallelForEach` call (line ~167) to use `&self.pool` instead of `&pool`.

- [ ] **1.4** Add a `pool` field to `TxnCoordinator` (line ~35) with the same init/deinit pattern:

```zig
// In TxnCoordinator struct:
pool: parallel_wrapper.ParallelPool,

// In init:
.pool = parallel_wrapper.ParallelPool.init(allocator, null),

// In deinit:
self.pool.deinit();
```

### Test command

```bash
cd /home/benji/src/devnw/codepros/geode/geode/.worktrees/session-20260401 && zig build test 2>&1 | head -20
```

### Commit message

```
perf(distributed): reuse ParallelPool as struct field instead of per-call allocation

QueryCoordinator and TxnCoordinator now hold a long-lived ParallelPool,
avoiding repeated init/deinit overhead. Closes PERF-D007.
```

---

## Task 2: Parallel 2PC prepare/commit (PERF-D003/D004)

**Files:**

- Modify: `src/distributed/twophase.zig` (lines 517-561 prepare, 563-606 commit)

### Steps

- [ ] **2.1** Add the parallel wrapper import and field. At the top of `twophase.zig`, add:

```zig
// After line 7 (value_convert import):
const parallel_wrapper = @import("parallel/thread_pool_parallel");
```

- [ ] **2.2** Parallelize the prepare phase. Replace the sequential loop in `Transaction.prepare()` (lines 523-551) with parallel dispatch:

```zig
pub fn prepare(self: *Transaction) !bool {
    self.state = .preparing;

    // CANARY: REQ=REQ-DIST-2PC-001; FEATURE="Two-Phase Commit Messaging"; ASPECT=Prepare; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-01
    // Parallel prepare: send to all participants concurrently
    const participant_count = self.participants.items.len;
    if (participant_count == 0) {
        self.state = .prepared;
        return true;
    }

    var vote_results = try self.allocator.alloc(bool, participant_count);
    defer self.allocator.free(vote_results);
    for (vote_results) |*v| v.* = false;

    var pool = parallel_wrapper.ParallelPool.init(self.allocator, null);
    defer pool.deinit();

    const PrepareCtx = struct {
        txn: *Transaction,
        votes: []bool,
    };
    const ctx = PrepareCtx{ .txn = self, .votes = vote_results };

    parallel_wrapper.parallelForEach(
        &pool,
        0,
        participant_count,
        ctx,
        struct {
            fn work(_: *parallel_wrapper.Task, idx: usize, c: PrepareCtx) void {
                const participant = &c.txn.participants.items[idx];
                participant.state = .preparing;

                const msg = TwoPhaseMessage{
                    .msg_type = .PREPARE,
                    .transaction_id = c.txn.id,
                    .coordinator_id = c.txn.coordinator_id,
                    .timestamp = std.time.timestamp(),
                    .operations = c.txn.operations,
                };

                const response = c.txn.send_fn(c.txn.send_ctx, participant.endpoint, msg, c.txn.timeout_ms) catch {
                    participant.prepare_response = .VOTE_TIMEOUT;
                    return;
                };
                defer response.deinit(c.txn.allocator);

                participant.prepare_response = response.vote;
                participant.last_message_time = std.time.timestamp();
                if (response.vote == .VOTE_COMMIT) {
                    c.votes[idx] = true;
                }
            }
        }.work,
    );

    // Check all votes
    var all_voted_commit = true;
    for (vote_results) |v| {
        if (!v) {
            all_voted_commit = false;
            break;
        }
    }

    if (!all_voted_commit) {
        self.state = .aborting;
        return false;
    }

    self.state = .prepared;
    return true;
}
```

- [ ] **2.3** Similarly parallelize the commit phase (lines 563-606). The retry logic per participant remains sequential within each participant's work item but participants are dispatched in parallel.

### Test command

```bash
cd /home/benji/src/devnw/codepros/geode/geode/.worktrees/session-20260401 && zig build test 2>&1 | head -20
```

### Commit message

```
perf(distributed): parallelize 2PC prepare and commit phases

Participants are now contacted concurrently via ParallelPool instead
of sequentially. Closes PERF-D003, PERF-D004.
```

---

## Task 3: Connection semaphore for cluster (PERF-D006)

**Files:**

- Modify: `src/distributed/cluster.zig`

### Steps

- [ ] **3.1** Add connection tracking fields to `ClusterCoordinator`:

```zig
// Add to ClusterCoordinator struct fields:
active_connections: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
max_connections: u32 = 100,
```

- [ ] **3.2** Find the `networkLoop` or `handleQuicConnection` entry point in `cluster.zig`. Before spawning a handler thread, check the counter:

```zig
// Before spawning connection handler:
const current = self.active_connections.load(.acquire);
if (current >= self.max_connections) {
    log.warn("connection limit reached, rejecting", &.{
        Attr.int("active", @intCast(current)),
        Attr.int("max", @intCast(self.max_connections)),
    });
    // Close the connection or return error
    return;
}
_ = self.active_connections.fetchAdd(1, .acq_rel);
```

- [ ] **3.3** Decrement the counter when the connection handler exits:

```zig
// At the end of handleQuicConnection (or in a defer):
defer _ = self.active_connections.fetchSub(1, .acq_rel);
```

### Test command

```bash
cd /home/benji/src/devnw/codepros/geode/geode/.worktrees/session-20260401 && zig build test 2>&1 | head -20
```

### Commit message

```
perf(distributed): add connection semaphore to ClusterCoordinator

Limits concurrent cluster connections to max_connections (default 100)
using an atomic counter. Closes PERF-D006.
```

---

## Task 4: Atomic statistics counters (PERF-D010)

**Files:**

- Modify: `src/distributed/enhanced_query_transport.zig` (lines 51-68)

### Steps

- [ ] **4.1** Replace plain `u64` counter fields in `TransportStatistics` with `std.atomic.Value(u64)`:

```zig
pub const TransportStatistics = struct {
    messages_sent: std.atomic.Value(u64),
    messages_received: std.atomic.Value(u64),
    bytes_transferred: std.atomic.Value(u64),
    query_latency_ms: std.atomic.Value(u64), // store as integer microseconds
    connection_errors: std.atomic.Value(u64),
    retry_count: std.atomic.Value(u64),
    active_connections: std.atomic.Value(u32),
    shard_utilization: std.AutoHashMap(u64, ShardUtilization),

    pub const ShardUtilization = struct {
        queries_executed: u64,
        avg_response_time_ms: f64,
        cpu_usage_percent: f32,
        memory_usage_mb: f64,
        error_rate: f32,
    };

    pub fn init() TransportStatistics {
        return .{
            .messages_sent = std.atomic.Value(u64).init(0),
            .messages_received = std.atomic.Value(u64).init(0),
            .bytes_transferred = std.atomic.Value(u64).init(0),
            .query_latency_ms = std.atomic.Value(u64).init(0),
            .connection_errors = std.atomic.Value(u64).init(0),
            .retry_count = std.atomic.Value(u64).init(0),
            .active_connections = std.atomic.Value(u32).init(0),
            .shard_utilization = undefined, // initialized in EnhancedQueryTransport.init
        };
    }
};
```

- [ ] **4.2** Find all increment sites (search for `.messages_sent +=`, `.connection_errors +=`, etc.) and replace with atomic operations:

```zig
// Replace: self.statistics.messages_sent += 1;
// With:
_ = self.statistics.messages_sent.fetchAdd(1, .monotonic);
```

- [ ] **4.3** Find all read sites and replace with atomic loads:

```zig
// Replace: self.statistics.messages_sent
// With:    self.statistics.messages_sent.load(.monotonic)
```

### Test command

```bash
cd /home/benji/src/devnw/codepros/geode/geode/.worktrees/session-20260401 && zig build test 2>&1 | head -20
```

### Commit message

```
perf(distributed): use atomic counters for transport statistics

Prevents data races on TransportStatistics fields accessed from
multiple connection handler threads. Closes PERF-D010.
```

---

## Task 5: QueryCache max-size eviction (PERF-D016)

**Files:**

- Modify: `src/distributed/federation.zig` (lines 1195-1253)

### Steps

- [ ] **5.1** Add `max_entries` field to `QueryCache`:

```zig
pub const QueryCache = struct {
    allocator: std.mem.Allocator,
    cache: std.StringHashMap(CacheEntry),
    ttl_seconds: u64,
    max_entries: usize,

    const CacheEntry = struct {
        results: QueryResults,
        timestamp: i64,
    };

    pub fn init(allocator: std.mem.Allocator, ttl_seconds: u64) !QueryCache {
        return .{
            .allocator = allocator,
            .cache = std.StringHashMap(CacheEntry).init(allocator),
            .ttl_seconds = ttl_seconds,
            .max_entries = 1000,
        };
    }
```

- [ ] **5.2** Add eviction logic to `put()` (after line 1240). Before inserting, if at capacity, evict the oldest entry:

```zig
pub fn put(self: *QueryCache, query: FederatedQuery, results: QueryResults) !void {
    const key = self.computeKey(query);
    defer self.allocator.free(key);

    if (self.cache.get(key)) |existing| {
        var old = existing.results;
        old.deinit(self.allocator);
    }

    // Evict oldest entry if at capacity
    if (self.cache.count() >= self.max_entries) {
        self.evictOldest();
    }

    try self.cache.put(try self.allocator.dupe(u8, key), .{
        .results = try cloneQueryResults(self.allocator, results),
        .timestamp = std.time.milliTimestamp(),
    });
}

fn evictOldest(self: *QueryCache) void {
    var oldest_key: ?[]const u8 = null;
    var oldest_time: i64 = std.math.maxInt(i64);

    var iter = self.cache.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.timestamp < oldest_time) {
            oldest_time = entry.value_ptr.timestamp;
            oldest_key = entry.key_ptr.*;
        }
    }

    if (oldest_key) |key| {
        if (self.cache.fetchRemove(key)) |kv| {
            var res = kv.value.results;
            res.deinit(self.allocator);
            self.allocator.free(kv.key);
        }
    }
}
```

### Test command

```bash
cd /home/benji/src/devnw/codepros/geode/geode/.worktrees/session-20260401 && zig build test 2>&1 | head -20
```

### Commit message

```
perf(distributed): add max-size eviction to federation QueryCache

Evicts the oldest entry when cache reaches 1000 entries, preventing
unbounded memory growth. Closes PERF-D016.
```

---

## Task 6: ConsistentHash getNodes binary search (PERF-D017)

**Files:**

- Modify: `src/distributed/sharding.zig` (lines 941-970)

### Steps

- [ ] **6.1** Extract the binary search from `getNode` (lines 915-938) into a shared helper:

```zig
/// Find the ring index of the first node with hash >= key_hash.
/// Returns 0 (wrap-around) if no node hash is >= key_hash.
fn findStartIndex(self: *ConsistentHash, key_hash: u64) usize {
    if (self.ring.items.len == 0) return 0;

    var left: usize = 0;
    var right: usize = self.ring.items.len;

    while (left < right) {
        const mid = (left + right) / 2;
        if (self.ring.items[mid].hash < key_hash) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }

    if (left >= self.ring.items.len) return 0;
    return left;
}
```

- [ ] **6.2** Refactor `getNode` to use the helper:

```zig
pub fn getNode(self: *ConsistentHash, key: []const u8) ?Node {
    if (self.ring.items.len == 0) return null;
    const idx = self.findStartIndex(self.hash(key));
    return self.ring.items[idx];
}
```

- [ ] **6.3** Replace the O(n) linear scan in `getNodes` (lines 949-958) with the binary search helper:

```zig
pub fn getNodes(self: *ConsistentHash, key: []const u8, count: usize) ![]Node {
    if (self.ring.items.len == 0) return &[_]Node{};

    const max_count = @min(count, self.ring.items.len / self.virtual_nodes);
    var nodes = std.ArrayList(Node){};
    var seen_ids = std.AutoHashMap(u64, void).init(self.allocator);
    defer seen_ids.deinit();

    // Use binary search instead of O(n) linear scan
    const start_idx = self.findStartIndex(self.hash(key));

    // Collect unique nodes
    var i: usize = 0;
    while (nodes.items.len < max_count and i < self.ring.items.len) : (i += 1) {
        const idx = (start_idx + i) % self.ring.items.len;
        const node = self.ring.items[idx];

        if (!seen_ids.contains(node.id)) {
            try nodes.append(node);
            try seen_ids.put(node.id, {});
        }
    }

    return nodes.toOwnedSlice(self.allocator);
}
```

### Test command

```bash
cd /home/benji/src/devnw/codepros/geode/geode/.worktrees/session-20260401 && zig build test 2>&1 | head -20
```

### Commit message

```
perf(distributed): use binary search in ConsistentHash.getNodes

Extracts findStartIndex helper from getNode and reuses it in
getNodes, replacing O(n) linear scan. Closes PERF-D017.
```
