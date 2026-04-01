const std = @import("std");
const geode = @import("geode");
const execution = geode.execution;
const value_types = geode.value_types;
const Value = value_types.Value;
const graph_store = geode.graph_store;

const logging = @import("logging");
const log = logging.scoped("rls");
const Attr = logging.Attr;

// CANARY: REQ=REQ-SEC-RLS-WIRE-001; FEATURE="RLS Query Enforcement"; ASPECT=PostResultFilter; STATUS=TESTED; OWNER=security; UPDATED=2026-04-01
// S1: Post-execution RLS filter that removes rows from query results based on label-level
// and property-level policies.  The RLS engine (rls_core.zig) has full policy CRUD, expression
// evaluation, and caching, but was never wired into the execution pipeline.  This module bridges
// the gap by performing label-based and property-based access checks on every result row that
// contains Node or Edge values.

// CANARY: REQ=REQ-SEC-RLS-WIRE-007; FEATURE="RLS Property Filtering"; ASPECT=PropertyPredicate; STATUS=TESTED; OWNER=security; UPDATED=2026-04-01
// GAP-0280: Property-level RLS predicates using value_types.Value directly, bypassing
// the incompatible rls_core.zig Value union. Shared types and engine live in rls_types.zig
// to avoid circular module dependencies between server/ and execution/.
const rls_types = @import("rls_types");

// Re-export shared types so existing callers (quic_connection_handler, grpc_server, main)
// continue to work without changing their imports.
pub const ComparisonOp = rls_types.ComparisonOp;
pub const PropertyPredicate = rls_types.PropertyPredicate;
pub const PropertyPolicy = rls_types.PropertyPolicy;
pub const LabelPolicy = rls_types.LabelPolicy;
pub const RLSFilterEngine = rls_types.RLSFilterEngine;
pub const setGlobalRLSFilterEngine = rls_types.setGlobalRLSFilterEngine;
pub const getGlobalRLSFilterEngine = rls_types.getGlobalRLSFilterEngine;

/// Convert a graph_store.PropertyValue to its string representation for comparison.
/// Returns null if the property value cannot be represented as a string.
fn propertyValueToString(allocator: std.mem.Allocator, pv: graph_store.PropertyValue) ?[]const u8 {
    return switch (pv) {
        .String => |s| s,
        .Int => |i| std.fmt.allocPrint(allocator, "{d}", .{i}) catch null,
        .Float => |f| std.fmt.allocPrint(allocator, "{d}", .{f}) catch null,
        .Bool => |b| if (b) "true" else "false",
        .Null => "null",
        .Decimal => |d| std.fmt.allocPrint(allocator, "{d}e-{d}", .{ d.coeff, d.scale }) catch null,
        .ExtValue => null,
    };
}

/// Compare a property value string against an expected value using the given operator.
/// For eq/neq, uses string comparison. For gt/lt/gte/lte, attempts numeric comparison
/// first, falls back to lexicographic comparison.
fn comparePropertyValue(actual: []const u8, op: ComparisonOp, expected: []const u8) bool {
    switch (op) {
        .eq => return std.mem.eql(u8, actual, expected),
        .neq => return !std.mem.eql(u8, actual, expected),
        .gt, .lt, .gte, .lte => {
            // Try numeric comparison first.
            const actual_num = std.fmt.parseFloat(f64, actual) catch null;
            const expected_num = std.fmt.parseFloat(f64, expected) catch null;

            if (actual_num != null and expected_num != null) {
                const a = actual_num.?;
                const e = expected_num.?;
                return switch (op) {
                    .gt => a > e,
                    .lt => a < e,
                    .gte => a >= e,
                    .lte => a <= e,
                    else => unreachable,
                };
            }

            // Fall back to lexicographic comparison.
            const order = std.mem.order(u8, actual, expected);
            return switch (op) {
                .gt => order == .gt,
                .lt => order == .lt,
                .gte => order != .lt,
                .lte => order != .gt,
                else => unreachable,
            };
        },
    }
}

/// Check whether a single row matches any property predicate.
/// Returns true if the row should be DENIED (filtered out).
fn rowMatchesPropertyPredicate(
    allocator: std.mem.Allocator,
    predicates: []const PropertyPredicate,
    row: []const Value,
) bool {
    for (row) |val| {
        const properties: *const std.StringHashMap(graph_store.PropertyValue) = switch (val) {
            .Node => |node| &node.properties,
            .Edge => |edge| &edge.properties,
            else => continue,
        };

        for (predicates) |pred| {
            if (properties.get(pred.property_name)) |pv| {
                const actual_str = propertyValueToString(allocator, pv) orelse continue;
                defer {
                    // Free allocated strings (Int, Float, Decimal produce allocations).
                    switch (pv) {
                        .Int, .Float, .Decimal => allocator.free(actual_str),
                        else => {},
                    }
                }

                const matches = comparePropertyValue(actual_str, pred.op, pred.expected_value);
                if (pred.deny and matches) {
                    return true; // Deny this row.
                }
                // For allow-only predicates (deny=false): if a predicate does NOT match,
                // the row is denied.
                if (!pred.deny and !matches) {
                    return true; // Deny this row (doesn't match allow predicate).
                }
            } else {
                // Property not found on this element.
                // For allow-only predicates, missing property means deny.
                if (!pred.deny) {
                    return true;
                }
            }
        }
    }
    return false;
}

/// Apply label-based and property-based RLS filtering to an execution result in place.
/// Rows that contain Node or Edge values whose labels are denied, or whose properties
/// match deny predicates, for the given user+graph are removed from `result.rows`.
/// The row memory is freed via `allocator`.
///
/// This is a post-execution filter -- it runs AFTER the store lock has been released and
/// does NOT require any store access.
///
/// Returns the number of rows removed.
// CANARY: REQ=REQ-SEC-RLS-WIRE-002; FEATURE="RLS Query Enforcement"; ASPECT=FilterApplication; STATUS=TESTED; OWNER=security; UPDATED=2026-04-01
pub fn applyRLSFilter(
    allocator: std.mem.Allocator,
    result: *execution.ExecutionResult,
    engine: *RLSFilterEngine,
    username: []const u8,
    graph_name: []const u8,
) usize {
    // Fast path: no policies at all -> nothing to filter.
    const label_count = engine.policyCount();
    const prop_count = engine.propertyPolicyCount();
    if (label_count == 0 and prop_count == 0) return 0;

    // Snapshot denied labels once (single lock acquisition).
    var denied = engine.snapshotDeniedLabels(allocator, graph_name, username) catch return 0;
    defer denied.deinit();

    // Snapshot property predicates once.
    var prop_predicates = engine.snapshotPropertyPolicies(allocator, graph_name, username) catch return 0;
    defer prop_predicates.deinit(allocator);

    // If nothing applicable for this user+graph, skip the row scan.
    if (denied.count() == 0 and prop_predicates.items.len == 0) return 0;

    var removed: usize = 0;
    var i: usize = 0;
    while (i < result.rows.len) {
        const deny_label = denied.count() > 0 and rowContainsDeniedLabel(&denied, result.rows[i]);
        const deny_prop = prop_predicates.items.len > 0 and rowMatchesPropertyPredicate(allocator, prop_predicates.items, result.rows[i]);

        if (deny_label or deny_prop) {
            // Free the row's value memory if owned.
            if (result.owns_value_memory) {
                for (result.rows[i]) |v| {
                    execution.freeValue(allocator, v);
                }
            }
            allocator.free(result.rows[i]);

            // Swap-remove: replace with last element.
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
        log.info("rls_filter", &.{
            Attr.string("action", "rows_filtered"),
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

// ---- Property-level RLS tests ----

test "ComparisonOp.fromString parses all operators" {
    try std.testing.expectEqual(ComparisonOp.eq, ComparisonOp.fromString("eq").?);
    try std.testing.expectEqual(ComparisonOp.eq, ComparisonOp.fromString("=").?);
    try std.testing.expectEqual(ComparisonOp.neq, ComparisonOp.fromString("neq").?);
    try std.testing.expectEqual(ComparisonOp.neq, ComparisonOp.fromString("!=").?);
    try std.testing.expectEqual(ComparisonOp.neq, ComparisonOp.fromString("<>").?);
    try std.testing.expectEqual(ComparisonOp.gt, ComparisonOp.fromString(">").?);
    try std.testing.expectEqual(ComparisonOp.lt, ComparisonOp.fromString("<").?);
    try std.testing.expectEqual(ComparisonOp.gte, ComparisonOp.fromString(">=").?);
    try std.testing.expectEqual(ComparisonOp.lte, ComparisonOp.fromString("<=").?);
    try std.testing.expect(ComparisonOp.fromString("bogus") == null);
}

test "comparePropertyValue: string equality" {
    try std.testing.expect(comparePropertyValue("secret", .eq, "secret"));
    try std.testing.expect(!comparePropertyValue("public", .eq, "secret"));
    try std.testing.expect(comparePropertyValue("public", .neq, "secret"));
    try std.testing.expect(!comparePropertyValue("secret", .neq, "secret"));
}

test "comparePropertyValue: numeric comparison" {
    try std.testing.expect(comparePropertyValue("100", .gt, "50"));
    try std.testing.expect(!comparePropertyValue("50", .gt, "100"));
    try std.testing.expect(comparePropertyValue("50", .lt, "100"));
    try std.testing.expect(comparePropertyValue("100", .gte, "100"));
    try std.testing.expect(comparePropertyValue("100", .lte, "100"));
    try std.testing.expect(comparePropertyValue("101", .gte, "100"));
    try std.testing.expect(!comparePropertyValue("99", .gte, "100"));
}

test "RLSFilterEngine: addPropertyPolicy and propertyPolicyCount" {
    const allocator = std.testing.allocator;
    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();

    try std.testing.expectEqual(@as(usize, 0), engine.propertyPolicyCount());

    try engine.addPropertyPolicy("alice", "default", "classification", .eq, "secret", true);
    try std.testing.expectEqual(@as(usize, 1), engine.propertyPolicyCount());

    try engine.addPropertyPolicy("bob", null, "clearance_level", .lt, "3", true);
    try std.testing.expectEqual(@as(usize, 2), engine.propertyPolicyCount());
}

test "RLSFilterEngine: removePropertyPolicy" {
    const allocator = std.testing.allocator;
    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();

    try engine.addPropertyPolicy("alice", "default", "classification", .eq, "secret", true);
    try std.testing.expectEqual(@as(usize, 1), engine.propertyPolicyCount());

    engine.removePropertyPolicy("alice", "default", "classification");
    try std.testing.expectEqual(@as(usize, 0), engine.propertyPolicyCount());
}

test "RLSFilterEngine: removePropertyPolicy with null graph" {
    const allocator = std.testing.allocator;
    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();

    try engine.addPropertyPolicy("bob", null, "clearance_level", .lt, "3", true);
    try std.testing.expectEqual(@as(usize, 1), engine.propertyPolicyCount());

    engine.removePropertyPolicy("bob", null, "clearance_level");
    try std.testing.expectEqual(@as(usize, 0), engine.propertyPolicyCount());
}

test "RLSFilterEngine: snapshotPropertyPolicies filters by user and graph" {
    const allocator = std.testing.allocator;
    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();

    // Policy for alice on default graph
    try engine.addPropertyPolicy("alice", "default", "classification", .eq, "secret", true);
    // Policy for all users on all graphs
    try engine.addPropertyPolicy("", null, "restricted", .eq, "true", true);

    // alice in "default" should see both predicates
    var preds_alice = try engine.snapshotPropertyPolicies(allocator, "default", "alice");
    defer preds_alice.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), preds_alice.items.len);

    // bob in "default" should see only the wildcard predicate
    var preds_bob = try engine.snapshotPropertyPolicies(allocator, "default", "bob");
    defer preds_bob.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), preds_bob.items.len);

    // alice in "other" should see only the wildcard predicate (graph-specific doesn't match)
    var preds_other = try engine.snapshotPropertyPolicies(allocator, "other", "alice");
    defer preds_other.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), preds_other.items.len);
}

test "rowMatchesPropertyPredicate: denies rows with matching string property" {
    const allocator = std.testing.allocator;

    // Create a node with classification = "secret"
    var props = std.StringHashMap(graph_store.PropertyValue).init(allocator);
    defer props.deinit();
    try props.put("classification", graph_store.PropertyValue{ .String = "secret" });
    try props.put("name", graph_store.PropertyValue{ .String = "doc1" });

    var labels_buf = [_][]const u8{"Document"};
    const node = graph_store.Node{
        .id = 1,
        .labels = &labels_buf,
        .properties = props,
    };

    const node_val = Value{ .Node = &node };
    const row = [_]Value{node_val};

    // Predicate: deny where classification = "secret"
    const pred_deny = [_]PropertyPredicate{.{
        .property_name = "classification",
        .op = .eq,
        .expected_value = "secret",
        .deny = true,
    }};

    try std.testing.expect(rowMatchesPropertyPredicate(allocator, &pred_deny, &row));

    // Predicate: deny where classification = "public" -- should NOT match
    const pred_no_match = [_]PropertyPredicate{.{
        .property_name = "classification",
        .op = .eq,
        .expected_value = "public",
        .deny = true,
    }};

    try std.testing.expect(!rowMatchesPropertyPredicate(allocator, &pred_no_match, &row));
}

test "rowMatchesPropertyPredicate: denies rows with matching integer property" {
    const allocator = std.testing.allocator;

    var props = std.StringHashMap(graph_store.PropertyValue).init(allocator);
    defer props.deinit();
    try props.put("clearance_level", graph_store.PropertyValue{ .Int = 5 });

    var labels_buf = [_][]const u8{"Person"};
    const node = graph_store.Node{
        .id = 2,
        .labels = &labels_buf,
        .properties = props,
    };

    const node_val = Value{ .Node = &node };
    const row = [_]Value{node_val};

    // Predicate: deny where clearance_level > 3
    const pred = [_]PropertyPredicate{.{
        .property_name = "clearance_level",
        .op = .gt,
        .expected_value = "3",
        .deny = true,
    }};

    try std.testing.expect(rowMatchesPropertyPredicate(allocator, &pred, &row));

    // Predicate: deny where clearance_level < 3 -- should NOT match (5 < 3 is false)
    const pred_no = [_]PropertyPredicate{.{
        .property_name = "clearance_level",
        .op = .lt,
        .expected_value = "3",
        .deny = true,
    }};

    try std.testing.expect(!rowMatchesPropertyPredicate(allocator, &pred_no, &row));
}

test "applyRLSFilter: property policy filters secret rows from mixed result set" {
    const allocator = std.testing.allocator;

    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();

    // Add a property policy: deny rows where classification = "secret" for alice
    try engine.addPropertyPolicy("alice", "default", "classification", .eq, "secret", true);

    // Create two nodes: one secret, one public
    var props_secret = std.StringHashMap(graph_store.PropertyValue).init(allocator);
    try props_secret.put("classification", graph_store.PropertyValue{ .String = "secret" });
    try props_secret.put("name", graph_store.PropertyValue{ .String = "secret_doc" });

    var props_public = std.StringHashMap(graph_store.PropertyValue).init(allocator);
    try props_public.put("classification", graph_store.PropertyValue{ .String = "public" });
    try props_public.put("name", graph_store.PropertyValue{ .String = "public_doc" });

    var labels_buf = [_][]const u8{"Document"};
    const secret_node = graph_store.Node{
        .id = 1,
        .labels = &labels_buf,
        .properties = props_secret,
    };
    const public_node = graph_store.Node{
        .id = 2,
        .labels = &labels_buf,
        .properties = props_public,
    };

    // Build rows
    const row1 = try allocator.alloc(Value, 1);
    row1[0] = Value{ .Node = &secret_node };

    const row2 = try allocator.alloc(Value, 1);
    row2[0] = Value{ .Node = &public_node };

    const rows = try allocator.alloc([]Value, 2);
    rows[0] = row1;
    rows[1] = row2;

    var result = execution.ExecutionResult{
        .columns = &.{},
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };

    // Save original allocation for cleanup (applyRLSFilter shrinks the slice via swap-remove).
    const original_rows = rows;

    const removed = applyRLSFilter(allocator, &result, &engine, "alice", "default");

    try std.testing.expectEqual(@as(usize, 1), removed);
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);

    // The remaining row should be the public one
    const remaining_node = result.rows[0][0].Node;
    try std.testing.expect(std.mem.eql(u8, remaining_node.properties.get("classification").?.String, "public"));

    // Clean up remaining row values and the original rows allocation.
    allocator.free(result.rows[0]);
    allocator.free(original_rows);

    // Clean up property maps (these are not owned by the result)
    props_secret.deinit();
    props_public.deinit();
}

test "applyRLSFilter: no property policies means no filtering" {
    const allocator = std.testing.allocator;

    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();

    // No policies added -- should not filter anything
    var props = std.StringHashMap(graph_store.PropertyValue).init(allocator);
    defer props.deinit();
    try props.put("classification", graph_store.PropertyValue{ .String = "secret" });

    var labels_buf = [_][]const u8{"Document"};
    const node = graph_store.Node{
        .id = 1,
        .labels = &labels_buf,
        .properties = props,
    };

    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Node = &node };

    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;

    var result = execution.ExecutionResult{
        .columns = &.{},
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };

    const removed = applyRLSFilter(allocator, &result, &engine, "alice", "default");
    try std.testing.expectEqual(@as(usize, 0), removed);
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);

    allocator.free(result.rows[0]);
    allocator.free(result.rows);
}

test "applyRLSFilter: property policy for different user does not filter" {
    const allocator = std.testing.allocator;

    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();

    // Policy for alice only
    try engine.addPropertyPolicy("alice", "default", "classification", .eq, "secret", true);

    var props = std.StringHashMap(graph_store.PropertyValue).init(allocator);
    defer props.deinit();
    try props.put("classification", graph_store.PropertyValue{ .String = "secret" });

    var labels_buf = [_][]const u8{"Document"};
    const node = graph_store.Node{
        .id = 1,
        .labels = &labels_buf,
        .properties = props,
    };

    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Node = &node };

    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;

    var result = execution.ExecutionResult{
        .columns = &.{},
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };

    // bob should NOT be filtered
    const removed = applyRLSFilter(allocator, &result, &engine, "bob", "default");
    try std.testing.expectEqual(@as(usize, 0), removed);
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);

    allocator.free(result.rows[0]);
    allocator.free(result.rows);
}

test "applyRLSFilter: combined label and property filtering" {
    const allocator = std.testing.allocator;

    var engine = RLSFilterEngine.init(allocator);
    defer engine.deinit();

    // Label policy: deny "Classified" label
    try engine.addDenyPolicy("default", "Classified", "alice");
    // Property policy: deny classification = "secret"
    try engine.addPropertyPolicy("alice", "default", "classification", .eq, "secret", true);

    // Node 1: has Classified label (caught by label policy)
    var props1 = std.StringHashMap(graph_store.PropertyValue).init(allocator);
    defer props1.deinit();
    try props1.put("classification", graph_store.PropertyValue{ .String = "public" });
    var labels_classified = [_][]const u8{"Classified"};
    const node1 = graph_store.Node{
        .id = 1,
        .labels = &labels_classified,
        .properties = props1,
    };

    // Node 2: has secret property (caught by property policy)
    var props2 = std.StringHashMap(graph_store.PropertyValue).init(allocator);
    defer props2.deinit();
    try props2.put("classification", graph_store.PropertyValue{ .String = "secret" });
    var labels_doc = [_][]const u8{"Document"};
    const node2 = graph_store.Node{
        .id = 2,
        .labels = &labels_doc,
        .properties = props2,
    };

    // Node 3: public, should pass both filters
    var props3 = std.StringHashMap(graph_store.PropertyValue).init(allocator);
    defer props3.deinit();
    try props3.put("classification", graph_store.PropertyValue{ .String = "public" });
    var labels_public = [_][]const u8{"Document"};
    const node3 = graph_store.Node{
        .id = 3,
        .labels = &labels_public,
        .properties = props3,
    };

    const row1 = try allocator.alloc(Value, 1);
    row1[0] = Value{ .Node = &node1 };
    const row2 = try allocator.alloc(Value, 1);
    row2[0] = Value{ .Node = &node2 };
    const row3 = try allocator.alloc(Value, 1);
    row3[0] = Value{ .Node = &node3 };

    const rows = try allocator.alloc([]Value, 3);
    rows[0] = row1;
    rows[1] = row2;
    rows[2] = row3;

    var result = execution.ExecutionResult{
        .columns = &.{},
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };

    const original_rows = rows;

    const removed = applyRLSFilter(allocator, &result, &engine, "alice", "default");

    try std.testing.expectEqual(@as(usize, 2), removed);
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);

    // Remaining row should be node3 (public)
    const remaining = result.rows[0][0].Node;
    try std.testing.expectEqual(@as(u64, 3), remaining.id);

    allocator.free(result.rows[0]);
    allocator.free(original_rows);
}
