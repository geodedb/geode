# Replication Snapshot Serialization & 2PC Undo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate empty replication snapshots (GAP-D001) and implement real 2PC undo operations for CREATE reversal (GAP-D004).
**Architecture:** GraphStore gets a `serializeSnapshot` method that iterates all nodes/edges and encodes them as JSON-lines for transport. The 2PC `applyUndoOperation` function is extended to accept a `*GraphStore` parameter and reverse CREATE operations by deleting the created node/edge by ID. UPDATE/DELETE undo requires stored pre-images (future work) and logs a warning.
**Tech Stack:** Zig 0.15.1, `std.json`, `graph_store.zig`, `distributed/cluster.zig`, `distributed/twophase.zig`

---

## Task 1: Implement GraphStore snapshot serialization

**Files:**

- Modify: `src/graph_store.zig`
- Test: `src/graph_store.zig` (inline test)

### Steps

- [ ] **1.1** Add `serializeSnapshot` method to `GraphStore` after the existing `serializeToBuffer` (line ~2992). This method iterates all nodes and edges, writing one JSON object per line.

```zig
// Add after line 2992 in src/graph_store.zig

// CANARY: REQ=REQ-DIST-CLUSTER-002; FEATURE="ClusterReplicationSnapshot"; ASPECT=Serialization; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-01
/// Serialize all graph data to a JSON-lines snapshot for cluster replication.
/// Each line is a JSON object: {"type":"node",...} or {"type":"edge",...}.
/// Caller owns the returned slice.
pub fn serializeSnapshot(self: *GraphStore, allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit(allocator);

    // Serialize nodes
    var node_iter = self.nodes.iterator();
    while (node_iter.next()) |entry| {
        const node = entry.value_ptr.*;
        try appendNodeJson(&buf, allocator, node);
        try buf.append(allocator, '\n');
    }

    // Serialize edges
    var edge_iter = self.edges.iterator();
    while (edge_iter.next()) |entry| {
        const edge = entry.value_ptr.*;
        try appendEdgeJson(&buf, allocator, edge);
        try buf.append(allocator, '\n');
    }

    return buf.toOwnedSlice(allocator);
}

fn appendNodeJson(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, node: Node) !void {
    // Build JSON manually to avoid std.json writer complexity
    try buf.appendSlice(allocator, "{\"type\":\"node\",\"id\":");
    const id_str = try std.fmt.allocPrint(allocator, "{d}", .{node.id});
    defer allocator.free(id_str);
    try buf.appendSlice(allocator, id_str);

    try buf.appendSlice(allocator, ",\"graph\":\"");
    try appendJsonEscaped(buf, allocator, node.graph_name);
    try buf.appendSlice(allocator, "\",\"labels\":[");
    for (node.labels, 0..) |label, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '"');
        try appendJsonEscaped(buf, allocator, label);
        try buf.append(allocator, '"');
    }
    try buf.appendSlice(allocator, "],\"properties\":{");
    try appendPropertiesJson(buf, allocator, node.properties);
    try buf.appendSlice(allocator, "}}");
}

fn appendEdgeJson(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, edge: Edge) !void {
    try buf.appendSlice(allocator, "{\"type\":\"edge\",\"id\":");
    const id_str = try std.fmt.allocPrint(allocator, "{d}", .{edge.id});
    defer allocator.free(id_str);
    try buf.appendSlice(allocator, id_str);

    try buf.appendSlice(allocator, ",\"from\":");
    const from_str = try std.fmt.allocPrint(allocator, "{d}", .{edge.from_id});
    defer allocator.free(from_str);
    try buf.appendSlice(allocator, from_str);

    try buf.appendSlice(allocator, ",\"to\":");
    const to_str = try std.fmt.allocPrint(allocator, "{d}", .{edge.to_id});
    defer allocator.free(to_str);
    try buf.appendSlice(allocator, to_str);

    try buf.appendSlice(allocator, ",\"graph\":\"");
    try appendJsonEscaped(buf, allocator, edge.graph_name);
    try buf.appendSlice(allocator, "\",\"label\":\"");
    try appendJsonEscaped(buf, allocator, edge.label);
    try buf.appendSlice(allocator, "\",\"properties\":{");
    try appendPropertiesJson(buf, allocator, edge.properties);
    try buf.appendSlice(allocator, "}}");
}

fn appendJsonEscaped(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
}

fn appendPropertiesJson(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, props: std.StringHashMap(PropertyValue)) !void {
    var first = true;
    var iter = props.iterator();
    while (iter.next()) |entry| {
        if (!first) try buf.append(allocator, ',');
        first = false;
        try buf.append(allocator, '"');
        try appendJsonEscaped(buf, allocator, entry.key_ptr.*);
        try buf.appendSlice(allocator, "\":");
        try appendPropertyValueJson(buf, allocator, entry.value_ptr.*);
    }
}

fn appendPropertyValueJson(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, val: PropertyValue) !void {
    switch (val) {
        .String => |s| {
            try buf.append(allocator, '"');
            try appendJsonEscaped(buf, allocator, s);
            try buf.append(allocator, '"');
        },
        .Int => |i| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{i});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .Float => |f| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{f});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .Bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .Null => try buf.appendSlice(allocator, "null"),
        .Decimal => |d| {
            const s = try std.fmt.allocPrint(allocator, "\"{d}e-{d}\"", .{ d.coeff, d.scale });
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .ExtValue => try buf.appendSlice(allocator, "null"),
    }
}
```

- [ ] **1.2** Add inline test for round-trip verification at the bottom of `src/graph_store.zig`:

```zig
test "serializeSnapshot produces valid JSON-lines for nodes and edges" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator, "");
    defer store.deinit();

    // Add a test node
    const node_id = try store.addNode(&.{"Person"}, "default");
    try store.setNodeProperty(node_id, "name", .{ .String = "Alice" });

    // Add a test edge
    const node_id2 = try store.addNode(&.{"Person"}, "default");
    _ = try store.addEdge(node_id, node_id2, "KNOWS", "default");

    const snapshot = try store.serializeSnapshot(allocator);
    defer allocator.free(snapshot);

    // Snapshot must be non-empty
    try std.testing.expect(snapshot.len > 0);

    // Must contain node and edge markers
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"type\":\"node\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"type\":\"edge\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"name\":\"Alice\"") != null);
}
```

### Test command

```bash
cd /home/benji/src/devnw/codepros/geode/geode/.worktrees/session-20260401 && zig build test 2>&1 | head -20
```

### Commit message

```
feat(storage): implement GraphStore.serializeSnapshot for cluster replication

Adds JSON-lines serialization of all nodes and edges for use
by the cluster replication subsystem. Closes GAP-D001 (partial).
```

---

## Task 2: Wire snapshot serialization into replication

**Files:**

- Modify: `src/distributed/cluster.zig` (lines 686-709)

### Steps

- [ ] **2.1** In `replicateShardToNode` (line 686), replace the empty snapshot allocation with a call to `serializeSnapshot`:

```zig
fn replicateShardToNode(self: *ClusterCoordinator, shard_id: u64, node_id: u64) !void {
    // CANARY: REQ=REQ-DIST-CLUSTER-002; FEATURE="ClusterReplicationSnapshot"; ASPECT=Transport; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-01
    // Checkpoint adapter storage before snapshotting.
    try self.store.saveToFile();

    // Serialize current graph state for replication
    const snapshot = try self.store.serializeSnapshot(self.allocator);
    defer self.allocator.free(snapshot);

    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 256);
    defer aw.deinit();
    const payload_msg = ReplicationPayload{
        .shard_id = shard_id,
        .snapshot = snapshot,
    };
    try protobuf.encode(&aw.writer, self.allocator, payload_msg);
    const payload = try self.allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
    defer self.allocator.free(payload);

    const msg = Message{
        .msg_type = .REPLICATE_DATA,
        .data = payload,
    };

    try self.sendToNode(node_id, msg);
}
```

- [ ] **2.2** Verify `ClusterCoordinator` has a `store` field of type `*graph_store.GraphStore`. If not, add it to the struct and wire it through `init()`.

### Test command

```bash
cd /home/benji/src/devnw/codepros/geode/geode/.worktrees/session-20260401 && zig build test 2>&1 | head -20
```

### Commit message

```
feat(distributed): wire snapshot serialization into cluster replication

replicateShardToNode now sends real graph data instead of
empty bytes. Closes GAP-D001.
```

---

## Task 3: Implement applyUndoOperation for CREATE reversal

**Files:**

- Modify: `src/distributed/twophase.zig` (line 416)

### Steps

- [ ] **3.1** Replace the no-op `applyUndoOperation` with a real implementation. Change the function signature to accept a `*graph_store.GraphStore` parameter:

```zig
/// Apply an undo operation to rollback a change.
/// Currently supports CREATE reversal (delete the created entity).
/// UPDATE and DELETE undo require stored pre-images (future work).
// CANARY: REQ=REQ-DIST-2PC-UNDO-001; FEATURE="2PC Undo Operations"; ASPECT=CreateReversal; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-01
fn applyUndoOperation(store: *graph_store.GraphStore, entry: UndoEntry) !void {
    switch (entry.operation.op_type) {
        .node_op => |node_op| {
            switch (node_op.op_type) {
                .CREATE => {
                    // Reverse a CREATE by deleting the node
                    store.deleteNode(node_op.node_id) catch |err| {
                        log.warn("undo CREATE node failed", &.{
                            Attr.int("node_id", @intCast(node_op.node_id)),
                            Attr.string("error", @errorName(err)),
                        });
                    };
                },
                .UPDATE, .DELETE => {
                    // UPDATE/DELETE undo requires stored pre-images (not yet captured)
                    log.warn("undo for UPDATE/DELETE not yet implemented — requires pre-image storage", &.{
                        Attr.int("node_id", @intCast(node_op.node_id)),
                    });
                },
            }
        },
        .edge_op => |edge_op| {
            switch (edge_op.op_type) {
                .CREATE => {
                    // Reverse a CREATE by deleting the edge
                    store.deleteEdge(edge_op.edge_id) catch |err| {
                        log.warn("undo CREATE edge failed", &.{
                            Attr.int("edge_id", @intCast(edge_op.edge_id)),
                            Attr.string("error", @errorName(err)),
                        });
                    };
                },
                .UPDATE, .DELETE => {
                    log.warn("undo for UPDATE/DELETE not yet implemented — requires pre-image storage", &.{
                        Attr.int("edge_id", @intCast(edge_op.edge_id)),
                    });
                },
            }
        },
    }
}
```

- [ ] **3.2** Verify the `dist_schema.TwoPhaseOperation` union tag names match. Check the `distributed_schema` module for the actual field names (`.node_op` / `.edge_op` with `.op_type` enum values `.CREATE`, `.UPDATE`, `.DELETE`). Adjust the switch cases if field names differ.

### Test command

```bash
cd /home/benji/src/devnw/codepros/geode/geode/.worktrees/session-20260401 && zig build test 2>&1 | head -20
```

### Commit message

```
feat(distributed): implement 2PC undo for CREATE operations

applyUndoOperation now reverses CREATE by deleting the node/edge.
UPDATE/DELETE undo is deferred (requires pre-image storage). Closes GAP-D004.
```

---

## Task 4: Wire store into applyUndoOperation call chain

**Files:**

- Modify: `src/distributed/twophase.zig` (lines 608-645, Transaction.abort)

### Steps

- [ ] **4.1** Add a `store` field to the `Transaction` struct:

```zig
// In Transaction struct (line ~421), add after send_ctx field:
store: ?*graph_store.GraphStore,
```

- [ ] **4.2** Update `Transaction.init` to accept and store the optional `store` parameter. Update the initializer:

```zig
pub fn init(
    allocator: Allocator,
    id: []const u8,
    coordinator_id: []const u8,
    send_fn: SendFn,
    send_ctx: ?*anyopaque,
    timeout_ms: u64,
    store: ?*graph_store.GraphStore,
) !Transaction {
    return .{
        .allocator = allocator,
        .id = try allocator.dupe(u8, id),
        .coordinator_id = try allocator.dupe(u8, coordinator_id),
        .participants = std.ArrayList(Participant).init(allocator),
        .state = .active,
        .start_time = std.time.timestamp(),
        .timeout_ms = timeout_ms,
        .send_fn = send_fn,
        .send_ctx = send_ctx,
        .operations = std.ArrayList(Operation).init(allocator),
        .isolation_level = .read_committed,
        .savepoints = std.ArrayList(Savepoint).init(allocator),
        .store = store,
    };
}
```

- [ ] **4.3** Update the `abort` method (line ~635) to pass the store to `applyUndoOperation`:

```zig
// Replace line 637:
//     try applyUndoOperation(undo_entry);
// With:
if (self.store) |store| {
    try applyUndoOperation(store, undo_entry);
} else {
    log.warn("2PC abort: no store available for undo — skipping", &.{});
}
```

- [ ] **4.4** Find all call sites of `Transaction.init` across the codebase and add `null` (or the real store reference) as the new `store` parameter. Search with:

```bash
cd /home/benji/src/devnw/codepros/geode/geode/.worktrees/session-20260401 && grep -rn "Transaction.init(" src/ tests/ --include="*.zig"
```

### Test command

```bash
cd /home/benji/src/devnw/codepros/geode/geode/.worktrees/session-20260401 && zig build test 2>&1 | head -20
```

### Commit message

```
refactor(distributed): wire GraphStore into 2PC undo call chain

Transaction.abort() now passes the store to applyUndoOperation,
enabling real rollback of CREATE operations during 2PC abort.
```
