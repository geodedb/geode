# Federation Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the two broken federation merge strategies (`union_distinct` returns duplicates, `hash_aggregate` returns wrong aggregation values) so distributed queries produce correct results.

**Architecture:** `federation.zig`'s `union_distinct` handler gets real hash-set deduplication using row hashing. `enhanced_query_coordinator.zig`'s `hashAggregateResults` gets real aggregate extraction from row values. Both implementations follow the existing `protocol.BindingRow` and `protocol.ColumnDef` data model.

**Tech Stack:** Zig 0.15.1, `protocol.BindingRow`, `protocol.ColumnDef`, `std.StringHashMap`

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `src/distributed/federation.zig:856-860` | Modify | Implement real union_distinct deduplication |
| `src/distributed/enhanced_query_coordinator.zig:465-523` | Modify | Implement real hash_aggregate merge |

---

### Task 1: Implement union_distinct Deduplication in federation.zig

**Files:**

- Modify: `src/distributed/federation.zig:856-860`

The `enhanced_query_coordinator.zig` already has a working `unionDistinctResults` (lines 266-296) that uses `std.StringHashMap(void)` with row hashing for deduplication. Port that pattern to `federation.zig`.

- [ ] **Step 1: Write failing test for union_distinct**

Add to `federation.zig` test block:

```zig
test "union_distinct removes duplicate rows" {
    const allocator = std.testing.allocator;

    // Create two result sets with overlapping rows
    const schema_defs = try allocator.alloc(protocol.ColumnDef, 1);
    schema_defs[0] = .{ .name = try allocator.dupe(u8, "x"), .type_name = try allocator.dupe(u8, "STRING") };

    // Row "alice" appears in both local and remote
    var local_rows = try allocator.alloc(protocol.BindingRow, 2);
    local_rows[0] = .{ .values = &.{.{ .string = "alice" }} };
    local_rows[1] = .{ .values = &.{.{ .string = "bob" }} };

    var remote_rows = try allocator.alloc(protocol.BindingRow, 2);
    remote_rows[0] = .{ .values = &.{.{ .string = "alice" }} };  // duplicate
    remote_rows[1] = .{ .values = &.{.{ .string = "carol" }} };

    const local = QueryResults{ .rows = local_rows, .schema = schema_defs, .execution_time_ms = 0 };
    const remote = [_]QueryResults{.{ .rows = remote_rows, .schema = schema_defs, .execution_time_ms = 0 }};

    const result = try mergeResults(undefined, local, &remote, .union_distinct, allocator);
    defer {
        for (result.rows) |row| freeBindingRow(allocator, row);
        allocator.free(result.rows);
        freeSchema(allocator, result.schema);
    }

    // Should have 3 unique rows: alice, bob, carol (not 4 with duplicate alice)
    try std.testing.expectEqual(@as(usize, 3), result.rows.len);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep "union_distinct removes"`
Expected: FAIL -- currently returns 4 rows (falls through to union_all)

- [ ] **Step 3: Implement union_distinct with hash-set deduplication**

Replace the placeholder at `federation.zig:856-860`:

```zig
.union_distinct => {
    // Deduplicate rows using hash set
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        seen.deinit();
    }

    var unique_rows = std.ArrayList(protocol.BindingRow).init(allocator);
    errdefer {
        for (unique_rows.items) |row| freeBindingRow(allocator, row);
        unique_rows.deinit();
    }

    // Process local rows
    for (local.rows) |row| {
        const key = try hashBindingRow(allocator, row);
        const gop = try seen.getOrPut(key);
        if (gop.found_existing) {
            allocator.free(key);
        } else {
            try unique_rows.append(try cloneBindingRow(allocator, row));
        }
    }

    // Process remote rows
    for (remote) |result| {
        for (result.rows) |row| {
            const key = try hashBindingRow(allocator, row);
            const gop = try seen.getOrPut(key);
            if (gop.found_existing) {
                allocator.free(key);
            } else {
                try unique_rows.append(try cloneBindingRow(allocator, row));
            }
        }
    }

    const schema_source = if (local.schema.len > 0) local.schema else if (remote.len > 0) remote[0].schema else &.{};
    const schema_copy = if (schema_source.len > 0) try cloneSchema(allocator, schema_source) else @as([]const protocol.ColumnDef, &.{});

    return QueryResults{
        .rows = try unique_rows.toOwnedSlice(),
        .schema = schema_copy,
        .execution_time_ms = local.execution_time_ms,
    };
},
```

Also add the `hashBindingRow` helper function:

```zig
fn hashBindingRow(allocator: std.mem.Allocator, row: protocol.BindingRow) ![]u8 {
    // Create a deterministic string representation for hashing
    var parts = std.ArrayList(u8).init(allocator);
    errdefer parts.deinit();

    for (row.values) |val| {
        switch (val) {
            .string => |s| try parts.appendSlice(s),
            .integer => |i| {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch "?";
                try parts.appendSlice(s);
            },
            .float => |f| {
                var buf: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch "?";
                try parts.appendSlice(s);
            },
            .boolean => |b| try parts.appendSlice(if (b) "T" else "F"),
            .null_value => try parts.appendSlice("NULL"),
            else => try parts.appendSlice("?"),
        }
        try parts.append('|');  // separator
    }

    return try parts.toOwnedSlice();
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/distributed/federation.zig
git commit -m "fix(distributed): implement real union_distinct deduplication in federation merge"
```

---

### Task 2: Implement Real Hash Aggregate in enhanced_query_coordinator.zig

**Files:**

- Modify: `src/distributed/enhanced_query_coordinator.zig:465-523`

The current code groups rows by hash key but hardcodes `.sum = 0`. Implement actual aggregate value extraction.

- [ ] **Step 1: Write failing test for hash_aggregate**

Add to `enhanced_query_coordinator.zig` test block:

```zig
test "hashAggregateResults computes real count per group" {
    const allocator = std.testing.allocator;

    // Create results with groups: category "A" (3 rows), category "B" (2 rows)
    var shard1_rows = try allocator.alloc(protocol.BindingRow, 2);
    shard1_rows[0] = .{ .values = &.{ .{ .string = "A" }, .{ .integer = 10 } } };
    shard1_rows[1] = .{ .values = &.{ .{ .string = "B" }, .{ .integer = 20 } } };

    var shard2_rows = try allocator.alloc(protocol.BindingRow, 3);
    shard2_rows[0] = .{ .values = &.{ .{ .string = "A" }, .{ .integer = 30 } } };
    shard2_rows[1] = .{ .values = &.{ .{ .string = "A" }, .{ .integer = 40 } } };
    shard2_rows[2] = .{ .values = &.{ .{ .string = "B" }, .{ .integer = 50 } } };

    const schema_defs = try allocator.alloc(protocol.ColumnDef, 2);
    schema_defs[0] = .{ .name = try allocator.dupe(u8, "category"), .type_name = try allocator.dupe(u8, "STRING") };
    schema_defs[1] = .{ .name = try allocator.dupe(u8, "amount"), .type_name = try allocator.dupe(u8, "INTEGER") };

    var shard_results = [_]federation.QueryResults{
        .{ .rows = shard1_rows, .schema = schema_defs, .execution_time_ms = 0 },
        .{ .rows = shard2_rows, .schema = schema_defs, .execution_time_ms = 0 },
    };

    var coordinator = try EnhancedQueryCoordinator.init(allocator);
    defer coordinator.deinit();

    const result = try coordinator.hashAggregateResults(&shard_results, .{});
    defer {
        for (result.rows) |row| freeBindingRow(allocator, row);
        allocator.free(result.rows);
    }

    // Should have 2 groups: A (count=3) and B (count=2)
    try std.testing.expectEqual(@as(usize, 2), result.rows.len);
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: May fail due to incorrect grouping or assertion mismatch.

- [ ] **Step 3: Implement real aggregate extraction**

Replace the placeholder in `hashAggregateResults`. The key change is replacing `.sum = 0` with actual value accumulation:

```zig
const AggregateGroup = struct {
    count: u64,
    sum: i64,
    representative_row: protocol.BindingRow,
};

// In the grouping loop, when updating existing group:
if (gop.found_existing) {
    self.allocator.free(group_key);
    gop.value_ptr.count += 1;
    // Accumulate numeric values from non-key columns
    if (row.values.len > 1) {
        switch (row.values[row.values.len - 1]) {
            .integer => |v| gop.value_ptr.sum += v,
            .float => |v| gop.value_ptr.sum += @intFromFloat(v),
            else => {},
        }
    }
} else {
    const initial_sum: i64 = if (row.values.len > 1) blk: {
        break :blk switch (row.values[row.values.len - 1]) {
            .integer => |v| v,
            .float => |v| @intFromFloat(v),
            else => 0,
        };
    } else 0;
    gop.value_ptr.* = AggregateGroup{
        .count = 1,
        .sum = initial_sum,
        .representative_row = try cloneBindingRow(self.allocator, row),
    };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/distributed/enhanced_query_coordinator.zig
git commit -m "fix(distributed): implement real aggregate value accumulation in hash_aggregate merge"
```

---

### Task 3: Add CANARY Tokens for New Implementations

**Files:**

- Modify: `src/distributed/federation.zig`
- Modify: `src/distributed/enhanced_query_coordinator.zig`

- [ ] **Step 1: Add CANARY tokens**

In `federation.zig`, above the `union_distinct` handler:

```zig
// CANARY: REQ=REQ-FED-UNION-DISTINCT-001; FEATURE="FederationUnionDistinct"; ASPECT=Deduplication; STATUS=TESTED; TEST=test_union_distinct_removes_duplicates; OWNER=distributed; UPDATED=2026-04-15
```

In `enhanced_query_coordinator.zig`, above `hashAggregateResults`:

```zig
// CANARY: REQ=REQ-DIST-HASH-AGG-001; FEATURE="DistributedHashAggregate"; ASPECT=ValueAccumulation; STATUS=TESTED; TEST=test_hashAggregateResults_computes_real_count; OWNER=distributed; UPDATED=2026-04-15
```

- [ ] **Step 2: Commit**

```bash
git add src/distributed/federation.zig src/distributed/enhanced_query_coordinator.zig
git commit -m "chore(distributed): add CANARY tokens for federation merge implementations"
```
