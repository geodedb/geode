# Distributed Security Hardening Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close four distributed security gaps: RLS enforcement on federated results, replay protection for Raft/2PC messages, tenant isolation in federation queries, and atomic Raft state persistence.
**Architecture:** An RLS adapter function filters `QueryResults` rows post-merge in the federation path. Raft and 2PC messages gain a `nonce` field with a bounded ring-buffer dedup set. Federation queries propagate `tenant_id` through the HELLO handshake. Raft persistent state uses write-to-temp-then-rename for crash safety.
**Tech Stack:** Zig 0.15.1, `std.crypto.random`, `src/server/rls_filter.zig`, `src/distributed/federation.zig`, `src/distributed/raft_consensus.zig`, `src/distributed/twophase.zig`

---

## Task 1: Apply RLS to federated query results (SEC-D007)

**Files:**

- Modify: `src/server/rls_filter.zig` (add adapter function after line ~200)
- Modify: `src/distributed/federation.zig` (after mergeResults, line ~744)

### Steps

- [ ] **1.1** Add an adapter function in `rls_filter.zig` that works with `QueryResults` (protocol BindingRow format) instead of `ExecutionResult`:

```zig
// Add at the end of src/server/rls_filter.zig, before the closing tests

// CANARY: REQ=REQ-SEC-RLS-FEDERATION-001; FEATURE="RLS Federation Filter"; ASPECT=PostMergeFilter; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
/// Apply RLS filtering to federated QueryResults.
/// Checks each row for Node/Edge values whose labels are denied.
/// Returns the number of rows removed.
pub fn applyRLSToQueryResults(
    allocator: std.mem.Allocator,
    results: *federation.QueryResults,
    engine: *RLSFilterEngine,
    username: []const u8,
    graph_name: []const u8,
) usize {
    if (engine.policyCount() == 0) return 0;

    var denied = engine.snapshotDeniedLabels(allocator, graph_name, username) catch return 0;
    defer denied.deinit();

    if (denied.count() == 0) return 0;

    var removed: usize = 0;
    var i: usize = 0;
    while (i < results.rows.len) {
        if (bindingRowContainsDeniedLabel(&denied, results.rows[i])) {
            // Swap-remove
            const last = results.rows.len - 1;
            if (i < last) {
                results.rows[i] = results.rows[last];
            }
            results.rows = results.rows[0..last];
            removed += 1;
        } else {
            i += 1;
        }
    }

    return removed;
}

/// Check if a BindingRow contains any denied labels.
/// BindingRow values that represent Node or Edge types carry label metadata.
fn bindingRowContainsDeniedLabel(denied: *const DeniedLabelSet, row: protocol.BindingRow) bool {
    for (row.values) |val| {
        switch (val.kind orelse continue) {
            .node_val => |node| {
                for (node.labels) |label| {
                    if (denied.contains(label)) return true;
                }
            },
            .edge_val => |edge| {
                if (denied.contains(edge.label)) return true;
            },
            else => {},
        }
    }
    return false;
}
```

- [ ] **1.2** Add the necessary imports to `rls_filter.zig`:

```zig
// Add near the top of rls_filter.zig:
const federation = @import("../distributed/federation.zig");
const protocol = @import("../protocol.zig");
```

- [ ] **1.3** Wire the filter into `FederationManager.executeQuery` in `federation.zig`. After `mergeResults` (line ~744) and before caching:

```zig
// After line 744 (const merged_results = try self.mergeResults(...)):
// Apply RLS filter to federated results
const rls_filter = @import("../server/rls_filter.zig");
if (rls_filter.getGlobalRLSFilterEngine()) |engine| {
    // Extract username and graph from the query context
    const username = query.username orelse "anonymous";
    const graph = query.target_graph orelse "default";
    _ = rls_filter.applyRLSToQueryResults(allocator, &merged_results, engine, username, graph);
}
```

- [ ] **1.4** Add `username` and `target_graph` optional fields to `FederatedQuery` if not present:

```zig
// In FederatedQuery struct:
username: ?[]const u8 = null,
target_graph: ?[]const u8 = null,
```

### Test command

```bash
cd /home/benji/src/devnw/codepros/geode/geode/.worktrees/session-20260401 && zig build test 2>&1 | head -20
```

### Commit message

```
feat(security): apply RLS filtering to federated query results

Adds applyRLSToQueryResults adapter that checks BindingRow values
for denied labels post-merge. Closes SEC-D007.
```

---

## Task 2: Add nonce to Raft/2PC messages (SEC-D009)

**Files:**

- Modify: `src/distributed/raft_consensus.zig` (RaftNode struct, message encoding ~line 361)
- Modify: `src/distributed/twophase.zig` (TwoPhaseMessage send paths)

### Steps

- [ ] **2.1** Add a nonce tracking structure. Create a new file `src/distributed/nonce_tracker.zig`:

```zig
const std = @import("std");

/// Ring-buffer based nonce tracker for replay protection.
/// Tracks the last N nonces and rejects duplicates.
// CANARY: REQ=REQ-SEC-REPLAY-001; FEATURE="Replay Protection"; ASPECT=NonceTracker; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
pub const NonceTracker = struct {
    nonces: [capacity]u64,
    index: usize,
    count: usize,
    lookup: std.AutoHashMap(u64, void),

    const capacity: usize = 10_000;

    pub fn init(allocator: std.mem.Allocator) NonceTracker {
        return .{
            .nonces = [_]u64{0} ** capacity,
            .index = 0,
            .count = 0,
            .lookup = std.AutoHashMap(u64, void).init(allocator),
        };
    }

    pub fn deinit(self: *NonceTracker) void {
        self.lookup.deinit();
    }

    /// Generate a fresh random nonce.
    pub fn generate() u64 {
        return std.crypto.random.int(u64);
    }

    /// Record a nonce. Returns false if the nonce is a duplicate (replay).
    pub fn recordAndCheck(self: *NonceTracker, nonce: u64) !bool {
        if (self.lookup.contains(nonce)) return false;

        // If at capacity, evict the oldest entry
        if (self.count >= capacity) {
            const evicted = self.nonces[self.index];
            _ = self.lookup.remove(evicted);
        } else {
            self.count += 1;
        }

        self.nonces[self.index] = nonce;
        try self.lookup.put(nonce, {});
        self.index = (self.index + 1) % capacity;

        return true;
    }
};

test "NonceTracker rejects duplicate nonces" {
    var tracker = NonceTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const nonce = NonceTracker.generate();
    try std.testing.expect(try tracker.recordAndCheck(nonce));
    try std.testing.expect(!try tracker.recordAndCheck(nonce)); // duplicate
}

test "NonceTracker accepts unique nonces" {
    var tracker = NonceTracker.init(std.testing.allocator);
    defer tracker.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const nonce = NonceTracker.generate();
        try std.testing.expect(try tracker.recordAndCheck(nonce));
    }
}
```

- [ ] **2.2** In `raft_consensus.zig`, add a `NonceTracker` field to `RaftNode` and check nonces on message receipt. In `encodeMessage` (line ~361), add a nonce field to the `RaftEnvelope`:

```zig
// When building the envelope for sending:
var envelope = raft_schema.RaftEnvelope{
    // ... existing fields ...
    .nonce = nonce_tracker.NonceTracker.generate(),
};
```

Note: The `raft_schema.RaftEnvelope` protobuf type must also have a `nonce` field. If it does not, add it as an optional `u64` field in the `.proto` definition and regenerate, or use a reserved field.

- [ ] **2.3** In `twophase.zig`, when constructing `TwoPhaseMessage` in `prepare()` and `commit()`, add a nonce. The `dist_schema.TwoPhaseMessage` must support a `nonce` field. If the protobuf schema does not have it, add a comment documenting the schema change needed:

```zig
// In prepare() and commit() TwoPhaseMessage construction:
// .nonce = nonce_tracker.NonceTracker.generate(),
// NOTE: Requires adding `uint64 nonce = 10;` to TwoPhaseMessage in distributed.proto
```

- [ ] **2.4** On the receive side (in `handlePrepare`, `handleCommit`, etc.), validate the nonce:

```zig
// At message receipt:
if (!try self.nonce_tracker.recordAndCheck(msg.nonce)) {
    log.warn("rejected replayed message", &.{
        Attr.int("nonce", @intCast(msg.nonce)),
    });
    return error.ReplayDetected;
}
```

### Test command

```bash
cd /home/benji/src/devnw/codepros/geode/geode/.worktrees/session-20260401 && zig build test 2>&1 | head -20
```

### Commit message

```
feat(security): add nonce-based replay protection for Raft and 2PC messages

Introduces NonceTracker with 10K-entry ring buffer for dedup.
Messages are rejected if their nonce was already seen. Closes SEC-D009.
```

---

## Task 3: Add tenant_id to federation queries (SEC-D010)

**Files:**

- Modify: `src/distributed/cluster_auth.zig` (line 28, buildClusterHelloRequest)
- Modify: `src/distributed/federation.zig` (FederatedQuery struct, executeQuery, buildHelloForFederation ~line 176)

### Steps

- [ ] **3.1** The `FederatedQuery` struct already needs `username` and `target_graph` from Task 1. Add `tenant_id`:

```zig
// In FederatedQuery struct in federation.zig:
tenant_id: ?[]const u8 = null,
```

- [ ] **3.2** Update `buildClusterHelloRequest` in `cluster_auth.zig` to accept an optional `tenant_id`:

```zig
pub fn buildClusterHelloRequest(allocator: std.mem.Allocator, tenant_id: ?[]const u8) !schema.HelloRequest {
    const token = std.posix.getenv("GEODE_CLUSTER_TOKEN") orelse {
        log.warn("GEODE_CLUSTER_TOKEN not set", &.{});
        return schema.HelloRequest{
            .username = "",
            .password = "",
            .tenant_id = if (tenant_id) |t| try allocator.dupe(u8, t) else null,
            .client_name = "geode-cluster",
            .client_version = "",
            .wanted_conformance = "",
        };
    };
    const password_copy = try allocator.dupe(u8, token);
    return schema.HelloRequest{
        .username = "geode-cluster",
        .password = password_copy,
        .tenant_id = if (tenant_id) |t| try allocator.dupe(u8, t) else null,
        .client_name = "geode-cluster",
        .client_version = "",
        .wanted_conformance = "",
    };
}
```

- [ ] **3.3** Update all call sites of `buildClusterHelloRequest` to pass the tenant_id. Search:

```bash
cd /home/benji/src/devnw/codepros/geode/geode/.worktrees/session-20260401 && grep -rn "buildClusterHelloRequest(" src/ --include="*.zig"
```

For federation paths, pass `query.tenant_id`. For non-federation paths (cluster.zig, query_transport.zig), pass `null`.

- [ ] **3.4** In `federation.zig` `buildHelloForFederation` (line ~176-180), propagate the tenant_id:

```zig
fn buildHelloForFederation(self: *FederationManager, allocator: std.mem.Allocator, query: FederatedQuery) !schema.HelloRequest {
    const cluster_auth = @import("cluster_auth.zig");
    var req = cluster_auth.buildClusterHelloRequest(allocator, query.tenant_id) catch {
        return schema.HelloRequest{ /* fallback */ };
    };
    req.client_name = "geode-federation";
    return req;
}
```

- [ ] **3.5** Update the existing test `buildClusterHelloRequest returns empty credentials when no token set` to pass `null`:

```zig
test "buildClusterHelloRequest returns empty credentials when no token set" {
    const req = try buildClusterHelloRequest(std.testing.allocator, null);
    // ...existing assertions...
}
```

### Test command

```bash
cd /home/benji/src/devnw/codepros/geode/geode/.worktrees/session-20260401 && zig build test 2>&1 | head -20
```

### Commit message

```
feat(security): propagate tenant_id through federation HELLO requests

buildClusterHelloRequest now accepts optional tenant_id, and
FederatedQuery carries it to remote nodes. Closes SEC-D010.
```

---

## Task 4: Atomic file write for Raft persistent state (SEC-D014)

**Files:**

- Modify: `src/distributed/raft_consensus.zig` (PersistentStorage, lines 248-288)

### Steps

- [ ] **4.1** Refactor `saveCurrentTerm` to use write-to-temp-then-rename:

```zig
// CANARY: REQ=REQ-SEC-RAFT-ATOMIC-001; FEATURE="Atomic Raft State Persistence"; ASPECT=TOCTOU; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
pub fn saveCurrentTerm(self: *PersistentStorage, term: u64) !void {
    std.fs.cwd().makePath(self.data_dir) catch {};
    var dir = try std.fs.cwd().openDir(self.data_dir, .{});
    defer dir.close();
    const term_str = try std.fmt.allocPrint(self.allocator, "{d}", .{term});
    defer self.allocator.free(term_str);

    // Write to temp file, fsync, then atomic rename
    const tmp_name = "current_term.tmp";
    const f = try dir.createFile(tmp_name, .{});
    try f.writeAll(term_str);
    try f.sync(); // fsync before rename
    f.close();

    try dir.rename(tmp_name, "current_term");
}
```

- [ ] **4.2** Apply the same pattern to `saveVotedFor`:

```zig
pub fn saveVotedFor(self: *PersistentStorage, voted_for: ?u64) !void {
    std.fs.cwd().makePath(self.data_dir) catch {};
    var dir = try std.fs.cwd().openDir(self.data_dir, .{});
    defer dir.close();

    if (voted_for) |v| {
        const v_str = try std.fmt.allocPrint(self.allocator, "{d}", .{v});
        defer self.allocator.free(v_str);

        const tmp_name = "voted_for.tmp";
        const f = try dir.createFile(tmp_name, .{});
        try f.writeAll(v_str);
        try f.sync(); // fsync before rename
        f.close();

        try dir.rename(tmp_name, "voted_for");
    } else {
        dir.deleteFile("voted_for") catch {};
    }
}
```

- [ ] **4.3** Add an inline test verifying the atomic write pattern:

```zig
test "PersistentStorage saveCurrentTerm atomic write" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{&tmp.sub_path},
    );
    defer std.testing.allocator.free(dir_path);

    var storage = try PersistentStorage.init(std.testing.allocator, dir_path);
    defer storage.close();

    try storage.saveCurrentTerm(42);
    const term = try storage.getCurrentTerm();
    try std.testing.expectEqual(@as(?u64, 42), term);

    // Write again to verify overwrite works
    try storage.saveCurrentTerm(99);
    const term2 = try storage.getCurrentTerm();
    try std.testing.expectEqual(@as(?u64, 99), term2);
}
```

### Test command

```bash
cd /home/benji/src/devnw/codepros/geode/geode/.worktrees/session-20260401 && zig build test 2>&1 | head -20
```

### Commit message

```
fix(security): use atomic write-then-rename for Raft persistent state

Prevents TOCTOU corruption by writing to a temp file, fsyncing,
then renaming to the final path. Closes SEC-D014.
```
