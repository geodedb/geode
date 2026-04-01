const std = @import("std");
const geode = @import("geode");
const execution = geode.execution;
const value_types = geode.value_types;
const Value = value_types.Value;
const graph_store = geode.graph_store;

const logging = @import("logging");
const log = logging.scoped("rls");
const Attr = logging.Attr;

// CANARY: REQ=REQ-SEC-RLS-WIRE-001; FEATURE="RLS Query Enforcement"; ASPECT=PostResultFilter; STATUS=IMPL; OWNER=security; UPDATED=2026-03-26
// S1: Post-execution RLS filter that removes rows from query results based on label-level
// policies.  The RLS engine (rls_core.zig) has full policy CRUD, expression evaluation, and
// caching, but was never wired into the execution pipeline.  This module bridges the gap by
// performing a label-based access check on every result row that contains Node or Edge values.

/// A label-level RLS policy binding: "user U must not see rows containing label L in graph G".
/// This is the minimum enforcement granularity — expression-level evaluation is deferred to a
/// later phase once the value-type bridge between execution Values and RLS Values is complete.
pub const LabelPolicy = struct {
    graph: []const u8,
    label: []const u8,
    /// When `deny` is true the label is blocked; when false the label is allowed.
    deny: bool = true,
    /// Applicable username (empty = all users).
    username: []const u8 = "",
};

/// Thread-safe, server-lifetime collection of label-level RLS policies.
/// Designed as a singleton that lives for the duration of the server process.
pub const RLSFilterEngine = struct {
    allocator: std.mem.Allocator,
    /// Protected by `mu`.
    policies: std.ArrayList(LabelPolicy),
    mu: std.Thread.Mutex = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .policies = std.ArrayList(LabelPolicy).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        // Free duped strings for each policy.
        for (self.policies.items) |p| {
            self.allocator.free(p.graph);
            self.allocator.free(p.label);
            if (p.username.len > 0) self.allocator.free(p.username);
        }
        self.policies.deinit(self.allocator);
    }

    /// Register a deny policy: rows containing nodes/edges with `label` in `graph` will be
    /// filtered out for `username` (empty string = all users).
    pub fn addDenyPolicy(self: *Self, graph: []const u8, label: []const u8, username: []const u8) !void {
        self.mu.lock();
        defer self.mu.unlock();

        const policy = LabelPolicy{
            .graph = try self.allocator.dupe(u8, graph),
            .label = try self.allocator.dupe(u8, label),
            .deny = true,
            .username = if (username.len > 0) try self.allocator.dupe(u8, username) else "",
        };
        try self.policies.append(self.allocator, policy);
    }

    /// Remove all policies matching graph+label+username exactly.
    pub fn removeDenyPolicy(self: *Self, graph: []const u8, label: []const u8, username: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();

        var i: usize = 0;
        while (i < self.policies.items.len) {
            const p = self.policies.items[i];
            if (std.mem.eql(u8, p.graph, graph) and
                std.mem.eql(u8, p.label, label) and
                std.mem.eql(u8, p.username, username))
            {
                self.allocator.free(p.graph);
                self.allocator.free(p.label);
                if (p.username.len > 0) self.allocator.free(p.username);
                _ = self.policies.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Returns true if the given label is denied for user+graph.
    pub fn isLabelDenied(self: *Self, graph: []const u8, label: []const u8, username: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();

        for (self.policies.items) |p| {
            if (!p.deny) continue;
            if (!std.mem.eql(u8, p.graph, graph)) continue;
            if (!std.mem.eql(u8, p.label, label)) continue;
            // Empty username in policy means "applies to all users"
            if (p.username.len == 0 or std.mem.eql(u8, p.username, username)) {
                return true;
            }
        }
        return false;
    }

    /// Snapshot denied labels for a specific user+graph into a HashSet.
    /// Single lock acquisition instead of per-label locking.  Caller must call
    /// `deinit()` on the returned map when done.
    pub fn snapshotDeniedLabels(self: *Self, allocator: std.mem.Allocator, graph: []const u8, username: []const u8) !std.StringHashMap(void) {
        self.mu.lock();
        defer self.mu.unlock();

        var denied = std.StringHashMap(void).init(allocator);
        for (self.policies.items) |p| {
            if (!p.deny) continue;
            if (!std.mem.eql(u8, p.graph, graph)) continue;
            if (p.username.len == 0 or std.mem.eql(u8, p.username, username)) {
                try denied.put(p.label, {});
            }
        }
        return denied;
    }

    /// Return the number of currently active policies.
    pub fn policyCount(self: *Self) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.policies.items.len;
    }
};

/// Global singleton — set once at server startup, read by every connection handler.
var g_rls_filter_engine: ?*RLSFilterEngine = null;

/// Called from server/main.zig (or server_init.zig) during startup.
pub fn setGlobalRLSFilterEngine(engine: ?*RLSFilterEngine) void {
    g_rls_filter_engine = engine;
}

/// Called by connection handlers to retrieve the engine.
pub fn getGlobalRLSFilterEngine() ?*RLSFilterEngine {
    return g_rls_filter_engine;
}

/// Apply label-based RLS filtering to an execution result in place.
/// Rows that contain Node or Edge values whose labels are denied for the given user+graph
/// are removed from `result.rows`.  The row memory is freed via `allocator`.
///
/// This is a post-execution filter — it runs AFTER the store lock has been released and
/// does NOT require any store access.
///
/// Returns the number of rows removed.
pub fn applyRLSFilter(
    allocator: std.mem.Allocator,
    result: *execution.ExecutionResult,
    engine: *RLSFilterEngine,
    username: []const u8,
    graph_name: []const u8,
) usize {
    // Fast path: no policies → nothing to filter.
    if (engine.policyCount() == 0) return 0;

    // Snapshot denied labels once (single lock acquisition) instead of
    // acquiring the mutex per-label per-row — O(1) lock instead of O(R*L).
    var denied = engine.snapshotDeniedLabels(allocator, graph_name, username) catch return 0;
    defer denied.deinit();

    // If no labels are denied for this user+graph, skip the row scan.
    if (denied.count() == 0) return 0;

    var removed: usize = 0;
    var i: usize = 0;
    while (i < result.rows.len) {
        if (rowContainsDeniedLabel(&denied, result.rows[i])) {
            // Free the row's value memory if owned.
            if (result.owns_value_memory) {
                for (result.rows[i]) |val| {
                    execution.freeValue(allocator, val);
                }
            }
            allocator.free(result.rows[i]);

            // Swap-remove: replace with last element.
            const last = result.rows.len - 1;
            if (i < last) {
                // Need to modify the rows slice in place.  ExecutionResult.rows is `[][]Value`
                // (a fat pointer); we can shrink it by adjusting the len field via a mutable
                // pointer.  We do NOT reallocate — the underlying allocation stays the same.
                @constCast(&result.rows[i]).* = result.rows[last];
            }
            // Shrink the slice length by 1.
            result.rows = result.rows[0..last];
            removed += 1;
            // Don't increment i — re-check the swapped-in element.
        } else {
            i += 1;
        }
    }

    if (removed > 0) {
        log.info("rls_filter", &.{
            Attr.string("action", "rows_filtered"),
            Attr.string("user", username),
            Attr.string("graph", graph_name),
        });
    }

    return removed;
}

// CANARY: REQ=REQ-SEC-RLS-ALGO-001; FEATURE="RLS Algorithm Filtering"; ASPECT=PostResultFilter; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
// S1: Algorithm results return Value.Int (nodeId) and Value.Float/Decimal (scores) which
// bypass the label-based Node/Edge filter in applyRLSFilter.  This function handles that
// gap by looking up each nodeId in the graph store and checking its labels against the
// denied set.  Only rows whose column[0] is named "nodeId" (or "sourceId"/"targetId" for
// bridge results) are inspected — graph-level aggregates (density, diameter, etc.) pass
// through unchanged because they carry no per-node information.

/// Apply RLS filtering to algorithm results that contain integer nodeIds instead of
/// full Node/Edge values.  This complements `applyRLSFilter` which handles structured
/// Node/Edge/Path values.
///
/// The function checks if result columns include "nodeId" (or "sourceId"/"targetId") and,
/// for each such row, looks up the corresponding node in the graph store to retrieve its
/// labels.  If any label is denied, the row is removed.
///
/// SECURITY: Without this filter, a user with RLS restrictions can run
/// `CALL algo.pagerank.stream()` and see centrality scores for ALL nodes — including
/// nodes whose labels are denied by RLS policy.
///
/// Returns the number of rows removed.
pub fn applyAlgorithmRLSFilter(
    allocator: std.mem.Allocator,
    result: *execution.ExecutionResult,
    engine: *RLSFilterEngine,
    store: *graph_store.GraphStore,
    username: []const u8,
    graph_name: []const u8,
) usize {
    // Fast path: no policies, nothing to filter.
    if (engine.policyCount() == 0) return 0;

    // Fast path: no columns or no rows.
    if (result.columns.len == 0 or result.rows.len == 0) return 0;

    // Determine which column indices contain nodeIds that must be checked.
    // Algorithm results use "nodeId" in column 0; bridges use "sourceId"/"targetId".
    var node_id_col_indices: [2]usize = undefined;
    var node_id_col_count: usize = 0;

    for (result.columns, 0..) |col_name, idx| {
        if (std.mem.eql(u8, col_name, "nodeId") or
            std.mem.eql(u8, col_name, "sourceId") or
            std.mem.eql(u8, col_name, "targetId"))
        {
            if (node_id_col_count < 2) {
                node_id_col_indices[node_id_col_count] = idx;
                node_id_col_count += 1;
            }
        }
    }

    // If no nodeId columns found, this is a graph-level aggregate — nothing to filter.
    if (node_id_col_count == 0) return 0;

    // Snapshot denied labels (single lock acquisition).
    var denied = engine.snapshotDeniedLabels(allocator, graph_name, username) catch return 0;
    defer denied.deinit();

    if (denied.count() == 0) return 0;

    var removed: usize = 0;
    var i: usize = 0;
    while (i < result.rows.len) {
        var should_remove = false;

        for (node_id_col_indices[0..node_id_col_count]) |col_idx| {
            if (col_idx >= result.rows[i].len) continue;

            const val = result.rows[i][col_idx];
            const node_id: ?u64 = switch (val) {
                .Int => |v| if (v >= 0) @intCast(v) else null,
                else => null,
            };

            if (node_id) |nid| {
                if (store.getNodePtr(nid)) |node| {
                    for (node.labels) |label| {
                        if (denied.contains(label)) {
                            should_remove = true;
                            break;
                        }
                    }
                }
                // If node not found in store, it may have been deleted — keep the row
                // since there is no label to deny.
            }
            if (should_remove) break;
        }

        if (should_remove) {
            // Free row memory (same logic as applyRLSFilter).
            if (result.owns_value_memory) {
                for (result.rows[i]) |v| {
                    execution.freeValue(allocator, v);
                }
            }
            allocator.free(result.rows[i]);

            const last = result.rows.len - 1;
            if (i < last) {
                @constCast(&result.rows[i]).* = result.rows[last];
            }
            result.rows = result.rows[0..last];
            removed += 1;
        } else {
            i += 1;
        }
    }

    if (removed > 0) {
        log.info("rls_algo_filter", &.{
            Attr.string("action", "algorithm_rows_filtered"),
            Attr.string("user", username),
            Attr.string("graph", graph_name),
        });
    }

    return removed;
}

/// Check whether a single row contains any Node or Edge value with a denied label.
/// Uses a pre-snapshotted HashSet for O(1) lookups instead of per-call mutex acquisition.
fn rowContainsDeniedLabel(
    denied_labels: *const std.StringHashMap(void),
    row: []const Value,
) bool {
    for (row) |val| {
        switch (val) {
            .Node => |node| {
                for (node.labels) |label| {
                    if (denied_labels.contains(label)) {
                        return true;
                    }
                }
            },
            .Edge => |edge| {
                if (denied_labels.contains(edge.label)) {
                    return true;
                }
            },
            .Path => |path| {
                // Check all nodes and edges in the path.
                for (path.nodes) |node| {
                    for (node.labels) |label| {
                        if (denied_labels.contains(label)) {
                            return true;
                        }
                    }
                }
                for (path.edges) |edge| {
                    if (denied_labels.contains(edge.label)) {
                        return true;
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

// ---- Unit tests ----

test "RLSFilterEngine: addDenyPolicy and isLabelDenied" {
    const allocator = std.testing.allocator;
    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();

    try engine.addDenyPolicy("default", "Secret", "alice");

    // alice should be denied
    try std.testing.expect(engine.isLabelDenied("default", "Secret", "alice"));
    // bob should not be denied (policy is user-specific)
    try std.testing.expect(!engine.isLabelDenied("default", "Secret", "bob"));
    // different graph should not be denied
    try std.testing.expect(!engine.isLabelDenied("other", "Secret", "alice"));
    // different label should not be denied
    try std.testing.expect(!engine.isLabelDenied("default", "Public", "alice"));
}

test "RLSFilterEngine: wildcard user policy" {
    const allocator = std.testing.allocator;
    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();

    // Empty username = applies to all users
    try engine.addDenyPolicy("default", "Classified", "");

    try std.testing.expect(engine.isLabelDenied("default", "Classified", "alice"));
    try std.testing.expect(engine.isLabelDenied("default", "Classified", "bob"));
    try std.testing.expect(engine.isLabelDenied("default", "Classified", ""));
}

test "RLSFilterEngine: removeDenyPolicy" {
    const allocator = std.testing.allocator;
    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();

    try engine.addDenyPolicy("default", "Secret", "alice");
    try std.testing.expectEqual(@as(usize, 1), engine.policyCount());

    engine.removeDenyPolicy("default", "Secret", "alice");
    try std.testing.expectEqual(@as(usize, 0), engine.policyCount());
    try std.testing.expect(!engine.isLabelDenied("default", "Secret", "alice"));
}

test "RLSFilterEngine: policyCount" {
    const allocator = std.testing.allocator;
    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();

    try std.testing.expectEqual(@as(usize, 0), engine.policyCount());
    try engine.addDenyPolicy("g1", "L1", "u1");
    try std.testing.expectEqual(@as(usize, 1), engine.policyCount());
    try engine.addDenyPolicy("g1", "L2", "u1");
    try std.testing.expectEqual(@as(usize, 2), engine.policyCount());
}

test "global RLS filter engine getter/setter" {
    const allocator = std.testing.allocator;
    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();

    try std.testing.expect(getGlobalRLSFilterEngine() == null);
    setGlobalRLSFilterEngine(&engine);
    try std.testing.expect(getGlobalRLSFilterEngine() != null);
    setGlobalRLSFilterEngine(null);
    try std.testing.expect(getGlobalRLSFilterEngine() == null);
}

test "RLSFilterEngine: snapshotDeniedLabels returns correct labels" {
    const allocator = std.testing.allocator;
    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();

    try engine.addDenyPolicy("default", "Secret", "alice");
    try engine.addDenyPolicy("default", "TopSecret", "");
    try engine.addDenyPolicy("other", "Private", "alice");

    // alice in "default" graph should see Secret + TopSecret denied
    var denied = try engine.snapshotDeniedLabels(allocator, "default", "alice");
    defer denied.deinit();

    try std.testing.expect(denied.contains("Secret"));
    try std.testing.expect(denied.contains("TopSecret"));
    try std.testing.expect(!denied.contains("Private")); // wrong graph
    try std.testing.expectEqual(@as(usize, 2), denied.count());
}

test "RLSFilterEngine: snapshotDeniedLabels empty for non-matching user" {
    const allocator = std.testing.allocator;
    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();

    try engine.addDenyPolicy("default", "Secret", "alice");

    // bob should get empty snapshot (user-specific policy for alice only)
    var denied = try engine.snapshotDeniedLabels(allocator, "default", "bob");
    defer denied.deinit();

    try std.testing.expectEqual(@as(usize, 0), denied.count());
}

test "rowContainsDeniedLabel uses snapshot correctly" {
    const allocator = std.testing.allocator;

    // Build a denied labels set manually
    var denied = std.StringHashMap(void).init(allocator);
    defer denied.deinit();
    try denied.put("Secret", {});

    // Create a row with an Edge that has the denied label
    const secret_edge = graph_store.Edge{
        .id = 1,
        .label = "Secret",
        .from_id = 1,
        .to_id = 2,
        .properties = std.StringHashMap(graph_store.PropertyValue).init(allocator),
    };
    const edge_val = Value{ .Edge = &secret_edge };
    const row = [_]Value{edge_val};

    try std.testing.expect(rowContainsDeniedLabel(&denied, &row));

    // Row with non-denied label should pass
    const public_edge = graph_store.Edge{
        .id = 2,
        .label = "Public",
        .from_id = 1,
        .to_id = 2,
        .properties = std.StringHashMap(graph_store.PropertyValue).init(allocator),
    };
    const ok_edge_val = Value{ .Edge = &public_edge };
    const ok_row = [_]Value{ok_edge_val};
    try std.testing.expect(!rowContainsDeniedLabel(&denied, &ok_row));
}

// ---- Algorithm RLS filter tests ----

test "applyAlgorithmRLSFilter: no policies returns 0" {
    const allocator = std.testing.allocator;
    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    const columns = try allocator.alloc([]const u8, 2);
    defer allocator.free(columns);
    columns[0] = "nodeId";
    columns[1] = "score";

    const rows = try allocator.alloc([]Value, 0);
    defer allocator.free(rows);

    var result = execution.ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };

    const removed = applyAlgorithmRLSFilter(allocator, &result, &engine, &store, "alice", "default");
    try std.testing.expectEqual(@as(usize, 0), removed);
}

test "applyAlgorithmRLSFilter: filters rows with denied node labels" {
    const allocator = std.testing.allocator;
    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    // Create nodes: node 1 has "Secret" label, node 2 has "Public" label
    const labels_secret = try allocator.alloc([]const u8, 1);
    defer allocator.free(labels_secret);
    labels_secret[0] = "Secret";
    const node1_id = try store.createNode(labels_secret);

    const labels_public = try allocator.alloc([]const u8, 1);
    defer allocator.free(labels_public);
    labels_public[0] = "Public";
    const node2_id = try store.createNode(labels_public);

    // Add deny policy for "Secret" label
    try engine.addDenyPolicy("default", "Secret", "alice");

    // Build algorithm result with two rows: [nodeId=1, score], [nodeId=2, score]
    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "nodeId");
    columns[1] = try allocator.dupe(u8, "score");

    // Allocate rows — the filter will swap-remove and shrink the slice.
    // We must keep the original pointer to free the full allocation.
    const rows = try allocator.alloc([]Value, 2);
    const rows_orig_ptr = rows.ptr;
    const rows_orig_len = rows.len;
    rows[0] = try allocator.alloc(Value, 2);
    rows[0][0] = Value{ .Int = @intCast(node1_id) }; // Secret node
    rows[0][1] = Value{ .Int = 42 };
    rows[1] = try allocator.alloc(Value, 2);
    rows[1][0] = Value{ .Int = @intCast(node2_id) }; // Public node
    rows[1][1] = Value{ .Int = 10 };

    var result = execution.ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };

    const removed = applyAlgorithmRLSFilter(allocator, &result, &engine, &store, "alice", "default");
    try std.testing.expectEqual(@as(usize, 1), removed);
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    // Remaining row should be the Public node
    try std.testing.expectEqual(@as(i64, @intCast(node2_id)), result.rows[0][0].Int);

    // Clean up: free remaining rows, then free the original allocation with correct size
    for (result.rows) |row| allocator.free(row);
    allocator.free(rows_orig_ptr[0..rows_orig_len]);
    allocator.free(columns[0]);
    allocator.free(columns[1]);
    allocator.free(columns);
}

test "applyAlgorithmRLSFilter: skips non-nodeId columns" {
    const allocator = std.testing.allocator;
    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    try engine.addDenyPolicy("default", "Secret", "alice");

    // Result with "density" column (graph-level stat) — should not be filtered
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "density");

    var rows = try allocator.alloc([]Value, 1);
    rows[0] = try allocator.alloc(Value, 1);
    rows[0][0] = Value{ .Int = 50 };

    var result = execution.ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
    defer result.deinit(allocator);

    const removed = applyAlgorithmRLSFilter(allocator, &result, &engine, &store, "alice", "default");
    try std.testing.expectEqual(@as(usize, 0), removed);
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
}

test "applyAlgorithmRLSFilter: filters bridge results with sourceId/targetId" {
    const allocator = std.testing.allocator;
    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    // Create nodes
    const labels_secret = try allocator.alloc([]const u8, 1);
    defer allocator.free(labels_secret);
    labels_secret[0] = "Secret";
    const node1_id = try store.createNode(labels_secret);

    const labels_public = try allocator.alloc([]const u8, 1);
    defer allocator.free(labels_public);
    labels_public[0] = "Public";
    const node2_id = try store.createNode(labels_public);

    const labels_pub2 = try allocator.alloc([]const u8, 1);
    defer allocator.free(labels_pub2);
    labels_pub2[0] = "Public";
    const node3_id = try store.createNode(labels_pub2);

    try engine.addDenyPolicy("default", "Secret", "alice");

    // Bridge result: [sourceId, targetId]
    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "sourceId");
    columns[1] = try allocator.dupe(u8, "targetId");

    const rows = try allocator.alloc([]Value, 2);
    const rows_orig_ptr = rows.ptr;
    const rows_orig_len = rows.len;
    // Row 0: bridge between Secret and Public — should be filtered
    rows[0] = try allocator.alloc(Value, 2);
    rows[0][0] = Value{ .Int = @intCast(node1_id) };
    rows[0][1] = Value{ .Int = @intCast(node2_id) };
    // Row 1: bridge between Public and Public — should remain
    rows[1] = try allocator.alloc(Value, 2);
    rows[1][0] = Value{ .Int = @intCast(node2_id) };
    rows[1][1] = Value{ .Int = @intCast(node3_id) };

    var result = execution.ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };

    const removed = applyAlgorithmRLSFilter(allocator, &result, &engine, &store, "alice", "default");
    try std.testing.expectEqual(@as(usize, 1), removed);
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);

    // Clean up with original allocation size
    for (result.rows) |row| allocator.free(row);
    allocator.free(rows_orig_ptr[0..rows_orig_len]);
    allocator.free(columns[0]);
    allocator.free(columns[1]);
    allocator.free(columns);
}

test "applyAlgorithmRLSFilter: bob not affected by alice-specific policy" {
    const allocator = std.testing.allocator;
    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    const labels_secret = try allocator.alloc([]const u8, 1);
    defer allocator.free(labels_secret);
    labels_secret[0] = "Secret";
    const node1_id = try store.createNode(labels_secret);

    // Policy for alice only
    try engine.addDenyPolicy("default", "Secret", "alice");

    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "nodeId");
    columns[1] = try allocator.dupe(u8, "score");

    var rows = try allocator.alloc([]Value, 1);
    rows[0] = try allocator.alloc(Value, 2);
    rows[0][0] = Value{ .Int = @intCast(node1_id) };
    rows[0][1] = Value{ .Int = 99 };

    var result = execution.ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
    defer result.deinit(allocator);

    // bob should NOT be filtered
    const removed = applyAlgorithmRLSFilter(allocator, &result, &engine, &store, "bob", "default");
    try std.testing.expectEqual(@as(usize, 0), removed);
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
}

test "applyAlgorithmRLSFilter: deleted node passes through" {
    const allocator = std.testing.allocator;
    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    try engine.addDenyPolicy("default", "Secret", "alice");

    // nodeId 999 does not exist in store — should pass through (no label to deny)
    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "nodeId");
    columns[1] = try allocator.dupe(u8, "score");

    var rows = try allocator.alloc([]Value, 1);
    rows[0] = try allocator.alloc(Value, 2);
    rows[0][0] = Value{ .Int = 999 };
    rows[0][1] = Value{ .Int = 50 };

    var result = execution.ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
    defer result.deinit(allocator);

    const removed = applyAlgorithmRLSFilter(allocator, &result, &engine, &store, "alice", "default");
    try std.testing.expectEqual(@as(usize, 0), removed);
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
}
