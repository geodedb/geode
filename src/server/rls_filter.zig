const std = @import("std");
const geode = @import("geode");
const execution = geode.execution;
const value_types = geode.value_types;
const Value = value_types.Value;
const graph_store = geode.graph_store;

const rls_types = @import("rls_types");
const logging = @import("logging");
const log = logging.scoped("rls");
const Attr = logging.Attr;

// CANARY: REQ=REQ-SEC-RLS-WIRE-001; FEATURE="RLS Query Enforcement"; ASPECT=PostResultFilter; STATUS=IMPL; OWNER=security; UPDATED=2026-03-26
// S1: Post-execution RLS filter that removes rows from query results based on label-level
// policies.  The RLS engine (rls_core.zig) has full policy CRUD, expression evaluation, and
// caching, but was never wired into the execution pipeline.  This module bridges the gap by
// performing a label-based access check on every result row that contains Node or Edge values.

// CANARY: REQ=REQ-SONNY-2729-ONE-LABEL-DENY-ENGINE; FEATURE="RLS Query Enforcement"; ASPECT=OneEngine; STATUS=TESTED; TEST=tests/test_sonny2729_one_label_deny_engine.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-2729 (part 2): the label-deny engine is rls_types' — the one the
/// executor filters with inside the traversal — and so is its global.
/// This module had a second engine type of its own (the same list of
/// label entries, with its own global), which server/main.zig kept in step
/// with the executor's by writing every deny to both
/// (`addDenyToEngines`) and listing, counting and removing against one of
/// them; a path that changed one and not the other, or a process that
/// installed only one, left the post-filter and the executor disagreeing.
/// A label is a table and its entries combine as PostgreSQL's policies do
/// (SONNY-2710, `rls_types.LabelPolicy`); the post-filter sees no
/// expression policies, so here only deny entries decide.
pub const LabelPolicy = rls_types.LabelPolicy;
pub const RLSFilterEngine = rls_types.RLSFilterEngine;

/// The label-deny engine, set once at server startup (server/main.zig):
/// rls_types' global, which the executor reads too.
pub fn setGlobalRLSFilterEngine(engine: ?*RLSFilterEngine) void {
    rls_types.setGlobalRLSFilterEngine(engine);
}

/// Called by connection handlers to retrieve the engine.
pub fn getGlobalRLSFilterEngine() ?*RLSFilterEngine {
    return rls_types.getGlobalRLSFilterEngine();
}

// CANARY: REQ=REQ-SONNY-2729-POSTFILTER-FAIL-CLOSED; FEATURE="RLS Query Enforcement"; ASPECT=FailClosed; STATUS=TESTED; TEST=tests/test_sonny2729_postfilter_fail_closed.zig; OWNER=security; UPDATED=2026-09-26
/// SONNY-2729: a post-filter could not run: it could not allocate its policy
/// snapshot, or the result's shorter row list. It has withheld every row of
/// the result, so no row it did not check is returned, and the caller
/// answers with this error (`proto_util.mapError`: 53200). The filters used
/// to return the rows unfiltered when the snapshot failed.
pub const FilterError = error{RowSecurityFilterUnavailable};

/// Free every row of `result` and leave it with none (SONNY-2729).
fn withholdAllRows(allocator: std.mem.Allocator, result: *execution.ExecutionResult) FilterError {
    const rows = result.rows;
    result.rows = rows[0..0];
    for (rows) |row| freeResultRow(allocator, result, row);
    allocator.free(rows);
    return error.RowSecurityFilterUnavailable;
}

/// Free one row of `result`: its values when the result owns them (with the
/// result's own free function, as `ExecutionResult.deinit` does), then the row.
fn freeResultRow(allocator: std.mem.Allocator, result: *const execution.ExecutionResult, row: []Value) void {
    if (result.owns_value_memory) {
        const free_value = result.free_value orelse &execution.freeValue;
        for (row) |val| free_value(allocator, val);
    }
    allocator.free(row);
}

/// Keep the rows of `result` that `check.keeps(row)` accepts, in their order,
/// and free the rest. The row list is reallocated to the rows kept: it used
/// to be shortened in place (a swap-remove that also reordered the rows), so
/// `ExecutionResult.deinit` freed it with the wrong length. If that
/// reallocation fails, every row is withheld (SONNY-2729). Returns the
/// number of rows removed.
fn retainRows(allocator: std.mem.Allocator, result: *execution.ExecutionResult, check: anytype) FilterError!usize {
    const rows = result.rows;
    var kept: usize = 0;
    for (rows) |row| {
        if (check.keeps(row)) {
            rows[kept] = row;
            kept += 1;
        } else {
            freeResultRow(allocator, result, row);
        }
    }
    const removed = rows.len - kept;
    if (removed == 0) return 0;
    result.rows = allocator.realloc(rows, kept) catch {
        // SONNY-2729: withhold the rows kept too, and free the full list.
        for (rows[0..kept]) |row| freeResultRow(allocator, result, row);
        allocator.free(rows);
        result.rows = rows[0..0];
        return error.RowSecurityFilterUnavailable;
    };
    return removed;
}

/// The row check of `applyRLSFilter`.
const LabelRowCheck = struct {
    denied: *const std.StringHashMap(void),

    fn keeps(self: LabelRowCheck, row: []const Value) bool {
        return !rowContainsDeniedLabel(self.denied, row);
    }
};

/// Apply label-based RLS filtering to an execution result in place.
/// Rows that contain Node or Edge values whose labels are denied for the given user+graph
/// are removed from `result.rows`.  The row memory is freed via `allocator`.
///
/// This is a post-execution filter — it runs AFTER the store lock has been released and
/// does NOT require any store access.
///
/// Returns the number of rows removed. SONNY-2729: when it cannot run, it
/// withholds every row and returns `error.RowSecurityFilterUnavailable`.
pub fn applyRLSFilter(
    allocator: std.mem.Allocator,
    result: *execution.ExecutionResult,
    engine: *RLSFilterEngine,
    username: []const u8,
    graph_name: []const u8,
) FilterError!usize {
    // Fast path: no rows → nothing to filter, even if policies exist.
    if (result.rows.len == 0) return 0;

    // Fast path: no policies anywhere → nothing to filter.
    if (engine.policyCount() == 0) return 0;

    // Fast path (user requirement 2026-04-23): skip the filter entirely
    // when this graph has no RLS policies attached.  Avoids the
    // snapshot allocation + row scan for the common case where most
    // graphs have zero RLS config.
    if (!engine.hasPoliciesForGraph(graph_name)) return 0;

    // Snapshot denied labels once (single lock acquisition) instead of
    // acquiring the mutex per-label per-row — O(1) lock instead of O(R*L).
    // SONNY-2729: without the snapshot no row is checked, so none is returned.
    var denied = engine.snapshotDeniedLabels(allocator, graph_name, username) catch
        return withholdAllRows(allocator, result);
    defer RLSFilterEngine.freeDeniedLabels(&denied);

    // If no labels are denied for this user+graph, skip the row scan.
    if (denied.count() == 0) return 0;

    const removed = try retainRows(allocator, result, LabelRowCheck{ .denied = &denied });

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

/// The row check of `applyAlgorithmRLSFilter`: the row's node-id columns
/// must name no node that carries a denied label.
const AlgorithmRowCheck = struct {
    denied: *const std.StringHashMap(void),
    store: *graph_store.GraphStore,
    node_id_cols: []const usize,

    fn keeps(self: AlgorithmRowCheck, row: []const Value) bool {
        for (self.node_id_cols) |col_idx| {
            if (col_idx >= row.len) continue;
            const node_id: u64 = switch (row[col_idx]) {
                .Int => |v| std.math.cast(u64, v) orelse continue,
                else => continue,
            };
            // CANARY: REQ=REQ-SONNY-3038-ALGO-EVICTED-NODE; FEATURE="RLS Algorithm Filtering"; ASPECT=EvictedNode; STATUS=TESTED; TEST=tests/test_sonny3038_auth_rls_low_findings.zig; OWNER=security; UPDATED=2026-11-11
            // SONNY-3038: a node evicted from the bounded resident cache is
            // read from the engine, from a transient copy that touches no
            // cache (`decideOnTransientNode`). The raw cache lookup missed it,
            // and the row was kept as if the node had been deleted. Only a
            // node in neither (deleted) has no label to deny.
            const denied = self.store.decideOnTransientNode(node_id, self.denied, carriesDeniedLabel) orelse continue;
            if (denied) return false;
        }
        return true;
    }

    fn carriesDeniedLabel(denied: *const std.StringHashMap(void), node: *const graph_store.Node) bool {
        for (node.labels) |label| {
            if (denied.contains(label)) return true;
        }
        return false;
    }
};

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
/// Returns the number of rows removed. SONNY-2729: when it cannot run, it
/// withholds every row and returns `error.RowSecurityFilterUnavailable`.
pub fn applyAlgorithmRLSFilter(
    allocator: std.mem.Allocator,
    result: *execution.ExecutionResult,
    engine: *RLSFilterEngine,
    store: *graph_store.GraphStore,
    username: []const u8,
    graph_name: []const u8,
) FilterError!usize {
    // Fast path: no policies, nothing to filter.
    if (engine.policyCount() == 0) return 0;

    // Fast path: no columns or no rows.
    if (result.columns.len == 0 or result.rows.len == 0) return 0;

    // Fast path (user requirement 2026-04-23): skip the filter entirely
    // when this graph has no RLS policies attached.  Avoids the
    // snapshot allocation + per-row node lookup for the common case
    // where most graphs have zero RLS config.
    if (!engine.hasPoliciesForGraph(graph_name)) return 0;

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

    // Snapshot denied labels (single lock acquisition). SONNY-2729: without
    // it no row is checked, so none is returned.
    var denied = engine.snapshotDeniedLabels(allocator, graph_name, username) catch
        return withholdAllRows(allocator, result);
    defer RLSFilterEngine.freeDeniedLabels(&denied);

    if (denied.count() == 0) return 0;

    const removed = try retainRows(allocator, result, AlgorithmRowCheck{
        .denied = &denied,
        .store = store,
        .node_id_cols = node_id_col_indices[0..node_id_col_count],
    });

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
        if (valueContainsDeniedLabel(denied_labels, val)) return true;
    }
    return false;
}

/// How many lists and maps deep `valueContainsDeniedLabel` searches. A list or
/// map nested deeper is not searched, and counts as carrying a denied label:
/// the search has to end, and a row the filter could not search is not a row
/// it may pass (fail closed). Real rows nest a few levels; this only bounds the
/// recursion, and the stack it uses, for an adversarial value.
const max_nested_value_depth: usize = 64;

// CANARY: REQ=REQ-SONNY-2687-NESTED-POSTFILTER; FEATURE="RLS Query Enforcement"; ASPECT=NestedValues; STATUS=TESTED; TEST=test-rls-filter; OWNER=security; UPDATED=2026-09-25
/// Does `val`, or any value nested in it, carry a denied label? A node, an
/// edge, and every node and edge of a path are checked; a list or a map is
/// searched element by element (SONNY-2687: `collect(h)`, `[h]`, `{n: h}` and
/// the like carry whole nodes, and this filter used to look at top-level
/// values only). The executor drops denied rows itself (SONNY-2679); this is
/// the defence-in-depth layer behind it. Past `max_nested_value_depth` it
/// answers true.
fn valueContainsDeniedLabel(denied_labels: *const std.StringHashMap(void), val: Value) bool {
    return valueContainsDeniedLabelAt(denied_labels, val, 0);
}

/// `valueContainsDeniedLabel` for a value `depth` lists or maps down.
fn valueContainsDeniedLabelAt(denied_labels: *const std.StringHashMap(void), val: Value, depth: usize) bool {
    switch (val) {
        .Node => |node| {
            for (node.labels) |label| {
                if (denied_labels.contains(label)) return true;
            }
        },
        .Edge => |edge| {
            if (denied_labels.contains(edge.label)) return true;
        },
        .Path => |path| {
            // Check all nodes and edges in the path.
            for (path.nodes) |node| {
                for (node.labels) |label| {
                    if (denied_labels.contains(label)) return true;
                }
            }
            for (path.edges) |edge| {
                if (denied_labels.contains(edge.label)) return true;
            }
        },
        .List => |items| {
            if (depth >= max_nested_value_depth) return true;
            for (items) |item| {
                if (valueContainsDeniedLabelAt(denied_labels, item, depth + 1)) return true;
            }
        },
        .Map => |map| {
            if (depth >= max_nested_value_depth) return true;
            var it = map.valueIterator();
            while (it.next()) |item| {
                if (valueContainsDeniedLabelAt(denied_labels, item.*, depth + 1)) return true;
            }
        },
        else => {},
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

test "RLSFilterEngine: hasPoliciesForGraph per-graph fast path" {
    const allocator = std.testing.allocator;
    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();

    // Empty engine → no graph has policies.
    try std.testing.expect(!engine.hasPoliciesForGraph("default"));
    try std.testing.expect(!engine.hasPoliciesForGraph("graph_a"));

    try engine.addDenyPolicy("graph_a", "Secret", "alice");

    // Only graph_a now has a policy — default must still short-circuit.
    try std.testing.expect(engine.hasPoliciesForGraph("graph_a"));
    try std.testing.expect(!engine.hasPoliciesForGraph("default"));
    try std.testing.expect(!engine.hasPoliciesForGraph("graph_b"));

    // Second policy on different graph — both hit, others still miss.
    try engine.addDenyPolicy("graph_b", "PII", "");
    try std.testing.expect(engine.hasPoliciesForGraph("graph_a"));
    try std.testing.expect(engine.hasPoliciesForGraph("graph_b"));
    try std.testing.expect(!engine.hasPoliciesForGraph("default"));
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
    defer RLSFilterEngine.freeDeniedLabels(&denied);

    try std.testing.expect(denied.contains("Secret"));
    try std.testing.expect(denied.contains("TopSecret"));
    try std.testing.expect(!denied.contains("Private")); // wrong graph
    try std.testing.expectEqual(@as(usize, 2), denied.count());
}

// CANARY: REQ=REQ-SONNY-2679-LABEL-SNAPSHOT-OWNED; FEATURE="RLS Query Enforcement"; ASPECT=SnapshotOwnsLabels; STATUS=TESTED; TEST=test-rls-filter; OWNER=security; UPDATED=2026-09-25
// Review (round 4): the snapshot borrowed each policy's label string, which
// `removeDenyPolicy` frees, while the post-filter still reads the snapshot.
// A policy removed between a snapshot and its use is the race; run in order
// on one thread it is deterministic: the snapshot must still hold "Secret",
// read from its own copy.
test "RLSFilterEngine: a snapshot keeps its labels after the policy is removed" {
    const allocator = std.testing.allocator;
    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();
    try engine.addDenyPolicy("default", "Secret", "alice");

    var denied = try engine.snapshotDeniedLabels(allocator, "default", "alice");
    defer RLSFilterEngine.freeDeniedLabels(&denied);

    // Frees the engine's copy of "Secret"; a new policy of the same size may
    // take that memory.
    engine.removeDenyPolicy("default", "Secret", "alice");
    try engine.addDenyPolicy("default", "Public", "bob");

    try std.testing.expect(denied.contains("Secret"));
    try std.testing.expect(!denied.contains("Public"));
    var it = denied.keyIterator();
    while (it.next()) |key| try std.testing.expectEqualStrings("Secret", key.*);
}

test "RLSFilterEngine: snapshotDeniedLabels empty for non-matching user" {
    const allocator = std.testing.allocator;
    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();

    try engine.addDenyPolicy("default", "Secret", "alice");

    // bob should get empty snapshot (user-specific policy for alice only)
    var denied = try engine.snapshotDeniedLabels(allocator, "default", "bob");
    defer RLSFilterEngine.freeDeniedLabels(&denied);

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
        .properties = graph_store.CompactPropertyMap.init(allocator),
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
        .properties = graph_store.CompactPropertyMap.init(allocator),
    };
    const ok_edge_val = Value{ .Edge = &public_edge };
    const ok_row = [_]Value{ok_edge_val};
    try std.testing.expect(!rowContainsDeniedLabel(&denied, &ok_row));
}

// CANARY: REQ=REQ-SONNY-2687-NESTED-POSTFILTER; FEATURE="RLS Query Enforcement"; ASPECT=NestedValues; STATUS=TESTED; TEST=test-rls-filter; OWNER=security; UPDATED=2026-09-25
test "SONNY-2687: rowContainsDeniedLabel looks inside lists, maps and paths nested in them" {
    const allocator = std.testing.allocator;
    var denied = std.StringHashMap(void).init(allocator);
    defer denied.deinit();
    try denied.put("Secret", {});

    var secret_labels = [_][]const u8{"Secret"};
    var public_labels = [_][]const u8{"Public"};
    const secret_node = graph_store.Node{ .id = 1, .labels = &secret_labels, .properties = graph_store.CompactPropertyMap.init(allocator) };
    const public_node = graph_store.Node{ .id = 2, .labels = &public_labels, .properties = graph_store.CompactPropertyMap.init(allocator) };
    const secret_edge = graph_store.Edge{ .id = 3, .label = "Secret", .from_id = 2, .to_id = 2, .properties = graph_store.CompactPropertyMap.init(allocator) };

    // collect(h) carrying a denied node.
    var collected = [_]Value{ .{ .Node = &public_node }, .{ .Node = &secret_node } };
    try std.testing.expect(rowContainsDeniedLabel(&denied, &[_]Value{.{ .List = &collected }}));

    // A denied edge two lists deep.
    var inner = [_]Value{.{ .Edge = &secret_edge }};
    var outer = [_]Value{ .{ .Int = 1 }, .{ .List = &inner } };
    try std.testing.expect(rowContainsDeniedLabel(&denied, &[_]Value{.{ .List = &outer }}));

    // A path through a denied node, inside a list.
    const path_nodes = [_]*const graph_store.Node{ &public_node, &secret_node };
    var paths = [_]Value{.{ .Path = .{ .nodes = &path_nodes, .edges = &.{} } }};
    try std.testing.expect(rowContainsDeniedLabel(&denied, &[_]Value{.{ .List = &paths }}));

    // A map value holding a denied node, and a list inside a map.
    var map = std.StringHashMap(Value).init(allocator);
    defer map.deinit();
    try map.put("who", .{ .Node = &secret_node });
    try std.testing.expect(rowContainsDeniedLabel(&denied, &[_]Value{.{ .Map = map }}));
    var map_list = std.StringHashMap(Value).init(allocator);
    defer map_list.deinit();
    try map_list.put("all", .{ .List = &inner });
    try std.testing.expect(rowContainsDeniedLabel(&denied, &[_]Value{.{ .Map = map_list }}));

    // Nothing denied anywhere: kept.
    var clean = [_]Value{ .{ .Node = &public_node }, .{ .Str = "Secret" } };
    var clean_map = std.StringHashMap(Value).init(allocator);
    defer clean_map.deinit();
    try clean_map.put("n", .{ .Node = &public_node });
    try std.testing.expect(!rowContainsDeniedLabel(&denied, &[_]Value{ .{ .List = &clean }, .{ .Map = clean_map } }));
}

// CANARY: REQ=REQ-SONNY-2687-NESTED-POSTFILTER; FEATURE="RLS Query Enforcement"; ASPECT=NestedDepthLimit; STATUS=TESTED; TEST=test-rls-filter; OWNER=security; UPDATED=2026-09-25
test "SONNY-2687: a value nested past the search depth is treated as denied" {
    const allocator = std.testing.allocator;
    var denied = std.StringHashMap(void).init(allocator);
    defer denied.deinit();
    try denied.put("Secret", {});

    // Lists nested one past the limit, with nothing denied at the bottom:
    // the search stops at the limit and the row is dropped.
    const deep = max_nested_value_depth + 2;
    var deep_cells: [deep][1]Value = undefined;
    deep_cells[deep - 1][0] = .{ .Int = 1 };
    var i: usize = deep - 1;
    while (i > 0) : (i -= 1) deep_cells[i - 1][0] = .{ .List = &deep_cells[i] };
    try std.testing.expect(rowContainsDeniedLabel(&denied, &[_]Value{.{ .List = &deep_cells[0] }}));

    // The same shape at the limit is searched to the bottom and kept...
    const at_limit = max_nested_value_depth;
    var cells: [at_limit][1]Value = undefined;
    cells[at_limit - 1][0] = .{ .Int = 1 };
    i = at_limit - 1;
    while (i > 0) : (i -= 1) cells[i - 1][0] = .{ .List = &cells[i] };
    try std.testing.expect(!rowContainsDeniedLabel(&denied, &[_]Value{.{ .List = &cells[0] }}));

    // ...and a denied node at its bottom is still found.
    var secret_labels = [_][]const u8{"Secret"};
    const secret_node = graph_store.Node{ .id = 1, .labels = &secret_labels, .properties = graph_store.CompactPropertyMap.init(allocator) };
    cells[at_limit - 1][0] = .{ .Node = &secret_node };
    try std.testing.expect(rowContainsDeniedLabel(&denied, &[_]Value{.{ .List = &cells[0] }}));

    // A map past the limit fails closed the same way.
    var map = std.StringHashMap(Value).init(allocator);
    defer map.deinit();
    try map.put("deep", .{ .List = &deep_cells[0] });
    try std.testing.expect(rowContainsDeniedLabel(&denied, &[_]Value{.{ .Map = map }}));
}

test "SONNY-2687: applyRLSFilter drops a row whose collected list carries a denied node" {
    const allocator = std.testing.allocator;
    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();
    try engine.addDenyPolicy("default", "Secret", "alice");

    var secret_labels = [_][]const u8{"Secret"};
    var public_labels = [_][]const u8{"Public"};
    const secret_node = graph_store.Node{ .id = 1, .labels = &secret_labels, .properties = graph_store.CompactPropertyMap.init(allocator) };
    const public_node = graph_store.Node{ .id = 2, .labels = &public_labels, .properties = graph_store.CompactPropertyMap.init(allocator) };
    var leaked = [_]Value{ .{ .Node = &public_node }, .{ .Node = &secret_node } };
    var kept = [_]Value{.{ .Node = &public_node }};

    const columns = try allocator.alloc([]const u8, 1);
    defer allocator.free(columns);
    columns[0] = "hs";
    const rows = try allocator.alloc([]Value, 2);
    rows[0] = try allocator.alloc(Value, 1);
    rows[0][0] = .{ .List = &leaked };
    rows[1] = try allocator.alloc(Value, 1);
    rows[1][0] = .{ .List = &kept };
    var result = execution.ExecutionResult{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };

    const removed = try applyRLSFilter(allocator, &result, &engine, "alice", "default");
    try std.testing.expectEqual(@as(usize, 1), removed);
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqual(@as(usize, 1), result.rows[0][0].List.len);

    // SONNY-2729: the filter reallocates the row list to the rows it keeps.
    for (result.rows) |row| allocator.free(row);
    allocator.free(result.rows);
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

    const removed = try applyAlgorithmRLSFilter(allocator, &result, &engine, &store, "alice", "default");
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

    // SONNY-2729: the filter keeps the rows' order and reallocates the row
    // list to the rows it keeps.
    const rows = try allocator.alloc([]Value, 2);
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

    const removed = try applyAlgorithmRLSFilter(allocator, &result, &engine, &store, "alice", "default");
    try std.testing.expectEqual(@as(usize, 1), removed);
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    // Remaining row should be the Public node
    try std.testing.expectEqual(@as(i64, @intCast(node2_id)), result.rows[0][0].Int);

    for (result.rows) |row| allocator.free(row);
    allocator.free(result.rows);
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

    const removed = try applyAlgorithmRLSFilter(allocator, &result, &engine, &store, "alice", "default");
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

    const removed = try applyAlgorithmRLSFilter(allocator, &result, &engine, &store, "alice", "default");
    try std.testing.expectEqual(@as(usize, 1), removed);
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);

    for (result.rows) |row| allocator.free(row);
    allocator.free(result.rows);
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
    const removed = try applyAlgorithmRLSFilter(allocator, &result, &engine, &store, "bob", "default");
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

    const removed = try applyAlgorithmRLSFilter(allocator, &result, &engine, &store, "alice", "default");
    try std.testing.expectEqual(@as(usize, 0), removed);
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
}
