const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");
const property_codec = @import("../property_value_codec.zig");
const property_mutation = @import("property_mutation.zig");
const write_precheck = @import("write_precheck.zig");
// A4b: fulltext write-maintenance hook (delete postings on node DELETE).
const fts_index_ops = @import("fts_index_ops.zig");
const value_types = @import("../value_types.zig");
// GAP-0840: shared strict-tenancy decision (opt-in rejection of unscoped reads).
const tenancy = @import("tenancy.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=Execution; STATUS=EXEMPT; OWNER=execution; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("execution");
const Attr = logging.Attr;

// CANARY: REQ=REQ-TXN-UNDO-008; FEATURE="TransactionUndoLog"; ASPECT=CrudImport; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
const txn_undo_log = @import("../txn_undo_log.zig");
// CANARY: REQ=REQ-CONSTRAINT-ENFORCE-001; FEATURE="ConstraintEnforcement"; ASPECT=CatalogImport; STATUS=TESTED; TEST=geodetestlab/specs/gql_catalog_operations_comprehensive.yml; OWNER=engine; UPDATED=2026-01-09
const catalog_mod = @import("../schema/catalog.zig");

// Import from parent execution module
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const executeReturnClauseWithEnv = execution.executeReturnClauseWithEnv;

// Import for unique column name generation
const match_operations = @import("match_operations.zig");
const generateUniqueColumnNames = match_operations.generateUniqueColumnNames;

// SONNY-2686: the RLS scratch row MERGE's match phase hands to
// `match_operations.passesRowVisibilityFilters` holds `rls.Value`s.
const rls = @import("rls");

// SONNY-1841: poll cancellation in the write apply loops so an abandoned
// write-carrying mutation (DELETE/DETACH DELETE/leader SET) aborts at a safe
// boundary and releases the per-graph write lock instead of running to its
// deadline. `write_budget.check()` is a no-op unless the executor installed a
// scope (query_execution.zig) that captured the stream's cancel source.
const write_budget = @import("../write_budget.zig");

// Cluster write replication (root cause #2 of
// docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md). These
// imports are read-only here; the executor consults the coordinator only when a
// cluster is active (single-node mode has no coordinator and is unaffected).
const cluster_mod = @import("../distributed/cluster.zig");
const raft_consensus = @import("../distributed/raft_consensus.zig");
const cluster_replication = @import("../distributed/cluster_replication.zig");

// Local type aliases
const Value = value_types.Value;
const Env = value_types.Env;
const ExecutionContext = execution.ExecutionContext;
const EvaluatedPatternProp = struct {
    key: []const u8,
    value: Value,
};

/// GAP-0815 regression probe: counts successful entries into the homogeneous
/// batch-CREATE fast path. Tests read this before/after a CREATE to assert
/// the fast path was exercised, replacing the prior wall-clock budget tests
/// (which flaked on contended hosts). Monotonic; never decremented.
pub var batch_create_invocations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Build an Env populated with query parameters from ExecutionContext.
/// GAP #54: Ensures $param references resolve inside CREATE/MERGE/DELETE property maps.
fn envFromContext(allocator: std.mem.Allocator, context: ExecutionContext) Env {
    return Env{
        .allocator = allocator,
        .names = &.{},
        .values = &.{},
        .param_names = context.query_param_names,
        .param_values = context.query_param_values,
    };
}

// GAP-0840: resolve the tenant filter via the shared strict-tenancy decision.
// In strict mode an unscoped / empty / "default" tenant scope returns
// error.TenantScopeRequired (rejecting the silent cross-tenant read) instead of
// null (all-tenants); in the default non-strict mode behaviour is unchanged.
fn tenantFilterFromContext(context: ExecutionContext) tenancy.TenancyError!?[]const u8 {
    return tenancy.resolveTenantFilter(context.tenant_id);
}

/// REQ=REQ-MERGE-RELPROPS-001 ASPECT=MatchBoundEndpoints
/// Look up a MATCH-bound variable name in `context.query_param_*` and return
/// its node id when the parameter slot holds a `Value.Node`. Used by the
/// MERGE edge branch to recover endpoints supplied by the upstream dispatcher
/// (query_execution.zig) which threads MATCH bindings through `query_param_*`
/// rather than `context.bindings`.
fn lookupNodeIdInQueryParams(context: ExecutionContext, name: []const u8) ?u64 {
    const names = context.query_param_names;
    const values = context.query_param_values;
    const n = @min(names.len, values.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (std.mem.eql(u8, names[i], name)) {
            switch (values[i]) {
                .Node => |node_ptr| return node_ptr.id,
                else => {},
            }
        }
    }
    return null;
}

/// REQ=REQ-MERGE-RELPROPS-001 ASPECT=OnCreateSet/BareSetOnRelationship
/// Apply MERGE SET clauses (`m.on_create` for newly created edges or
/// `m.on_match` for matched edges; bare-SET duplicates both lists by
/// construction in the parser) whose target binding name matches the
/// relationship variable on the freshly merged edge.
///
/// SET clauses targeting a node variable are intentionally ignored here
/// (the node MERGE branch above handles those). Only items whose target
/// equals `rel_var_name` reach the edge property writer.
fn applySetClausesToEdge(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    rel_var_name: ?[]const u8,
    edge_type: []const u8,
    edge_id: u64,
    set_items: []ast.SetClause,
    context: ExecutionContext,
) !void {
    const var_name = rel_var_name orelse return;
    if (set_items.len == 0) return;

    // Statement-atomicity pre-pass — this clause list is all-or-nothing.
    // CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=SetPrePass; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25
    try write_precheck.checkSetClausesWritable(allocator, set_items, envFromContext(allocator, context), var_name, &.{});

    for (set_items) |set_clause| {
        switch (set_clause) {
            .Property => |prop| {
                if (!std.mem.eql(u8, prop.target.object, var_name)) continue;
                const value = try eval.evalExpr(allocator, prop.value, envFromContext(allocator, context));
                try property_mutation.setEdgePropertyFromValue(allocator, store, edge_type, edge_id, prop.target.property, value);
            },
            .AllProperties => |all_props| {
                if (!std.mem.eql(u8, all_props.node, var_name)) continue;
                const props_value = try eval.evalExpr(allocator, all_props.properties, envFromContext(allocator, context));
                if (store.getEdgePtrHydrated(edge_id)) |edge_ptr| {
                    try property_mutation.replaceEdgeProperties(allocator, store, edge_ptr, props_value);
                }
            },
            .Labels => {
                // Edges do not carry labels in the same shape as nodes; this
                // form is parsed against node variables. Nothing to do here.
            },
        }
    }
}

/// Evaluate a MERGE/MATCH pattern's inline properties into comparable `Value`s.
///
/// OWNERSHIP CONTRACT — `arena_allocator` MUST be an arena the caller tears down
/// once it is finished with the returned slice, and the returned values must not
/// outlive it.
///
/// The reason is that `evalExpr` returns a MIX of ownerships and the caller
/// cannot tell them apart:
///   * OWNED heap — `vectorf32('[...]')` ends in `allocator.dupe(f32, ...)`
///     (types/vector.zig:55), as do the other constructed ExtValues;
///   * BORROWED from the AST — a string literal is a slice of parser memory;
///   * ALIASED live store memory — `n.emb` hands back the stored value itself.
/// Freeing each result unconditionally therefore double-frees the AST/store
/// cases (`value_utilities.freeValue` does not even handle `.ExtValue`), and
/// freeing none of them leaks the owned ones — which is what this used to do
/// for every evaluated MERGE property. An arena is the only discipline that is
/// correct for all three: owned allocations are reclaimed in one pass, borrowed
/// and aliased ones are never touched.
fn evaluatePatternProps(arena_allocator: std.mem.Allocator, props: ?[]ast.Property, context: ExecutionContext) !?[]EvaluatedPatternProp {
    const pattern_props = props orelse return null;

    const owned = try arena_allocator.alloc(EvaluatedPatternProp, pattern_props.len);

    const pattern_env = envFromContext(arena_allocator, context);
    for (pattern_props, 0..) |prop, i| {
        owned[i] = .{
            .key = prop.key,
            .value = try eval.evalExpr(arena_allocator, prop.value.*, pattern_env),
        };
    }
    return owned;
}

fn nodeHasAllLabels(node: *const graph_store.Node, labels: []const []const u8) bool {
    for (labels) |required_label| {
        var found_label = false;
        for (node.labels) |actual_label| {
            if (std.mem.eql(u8, actual_label, required_label)) {
                found_label = true;
                break;
            }
        }
        if (!found_label) return false;
    }
    return true;
}

fn nodeMatchesEvaluatedProps(node: *const graph_store.Node, props: ?[]const EvaluatedPatternProp) bool {
    const evaluated_props = props orelse return true;
    for (evaluated_props) |prop| {
        if (node.properties.get(prop.key)) |actual| {
            if (!valuesEqual(actual, prop.value)) return false;
        } else {
            return false;
        }
    }
    return true;
}

fn nodeMatchesPattern(
    node: *const graph_store.Node,
    graph_name: []const u8,
    tenant_id: ?[]const u8,
    labels: []const []const u8,
    props: ?[]const EvaluatedPatternProp,
) bool {
    if (!std.mem.eql(u8, node.graph_name, graph_name)) return false;
    if (tenant_id) |tid| {
        if (!std.mem.eql(u8, node.tenant_id, tid)) return false;
    }
    if (labels.len > 0 and !nodeHasAllLabels(node, labels)) return false;
    return nodeMatchesEvaluatedProps(node, props);
}

/// Convert an eval Value to a GraphStore PropertyValue for merge index lookup.
/// Only handles simple scalar types that the index supports.
fn valueToPropertyValueForIndex(val: Value) ?graph_store.PropertyValue {
    return switch (val) {
        .Str => |s| graph_store.PropertyValue{ .String = s },
        .Int => |i| graph_store.PropertyValue{ .Int = i },
        .Bool => |b| graph_store.PropertyValue{ .Bool = b },
        else => null,
    };
}

// CANARY: REQ=REQ-SONNY-2819-AUDIT-JSON-ESCAPE; FEATURE="AuditDurability"; ASPECT=RefusalKeysHexEncoded; STATUS=TESTED; TEST=tests/test_sonny2819_audit_log_injection.zig; OWNER=security; UPDATED=2026-09-27
/// SONNY-2819: `items` joined with ',' for an audit record's details, each
/// control character (and DEL) hex-encoded as `\xHH`. A MERGE pattern's
/// property keys are the client's: a string-literal key can carry a quote and
/// a newline, which the audit writer printed unescaped, so a restricted user
/// could forge a second record. The writer now escapes every string; this is
/// the defence in depth, so the text never holds a line break at all.
fn joinAuditText(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (items, 0..) |item, i| {
        if (i > 0) try out.append(allocator, ',');
        for (item) |c| {
            if (c < 0x20 or c == 0x7f) {
                try out.print(allocator, "\\x{x:0>2}", .{c});
            } else {
                try out.append(allocator, c);
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

// CANARY: REQ=REQ-SONNY-2686-MERGE-ROW-VISIBILITY; FEATURE="MergeRowVisibility"; ASPECT=MatchPhaseVisibility; STATUS=TESTED; TEST=tests/test_sonny2686_merge_rls.zig; OWNER=security; UPDATED=2026-09-25
/// SONNY-2686: the row visibility MERGE's match phase applies to every node it
/// finds, for a node chain and for each relationship endpoint alike.
///
/// The pattern predicate (`nodeMatchesPattern`) confines a candidate to the
/// statement's graph and the session's exact tenant, and it matched on labels
/// and properties only. It never applied the session's RLS policies, so a MERGE
/// bound a node the session may not read: RETURN projected it, ON MATCH SET and
/// a bare SET rewrote it, and a relationship MERGE attached an edge to it. Every
/// node that matches the pattern now also has to pass
/// `passesRowVisibilityFilters`, the combinator the other engine-direct read
/// paths use, before MERGE may bind it.
///
/// Whether a policy can deny this session anything is decided once per
/// statement (`rlsMayDenyForSession`, as `HopScope` does per traversal). When
/// none can (no policy is installed, or the session has no user) the check is
/// skipped, and MERGE behaves exactly as it did.
const MergeVisibility = struct {
    allocator: std.mem.Allocator,
    filter_tenant: ?[]const u8,
    rls_may_deny: bool,
    rls_row: std.StringHashMap(rls.Value),
    /// SONNY-2728: the statement's graph and the session's identity, for the
    /// audit record of a refusal.
    graph: []const u8,
    username: []const u8,
    user_id: u64,

    /// Call with the statement's context active: the RLS half reads it.
    fn init(allocator: std.mem.Allocator, filter_tenant: ?[]const u8, graph: []const u8, context: ExecutionContext) MergeVisibility {
        const principal_name: ?[]const u8 = if (context.principal) |p| p.username else null;
        return .{
            .allocator = allocator,
            .filter_tenant = filter_tenant,
            .rls_may_deny = match_operations.rlsMayDenyForSession(),
            .rls_row = std.StringHashMap(rls.Value).init(allocator),
            .graph = graph,
            .username = principal_name orelse (context.user orelse ""),
            .user_id = if (context.principal) |p| (p.user_id orelse 0) else 0,
        };
    }

    // CANARY: REQ=REQ-SONNY-2728-MERGE-REFUSAL-AUDIT; FEATURE="MergeRowVisibility"; ASPECT=RefusalAudit; STATUS=TESTED; TEST=tests/test_sonny2686_merge_rls.zig; OWNER=security; UPDATED=2026-09-26
    /// SONNY-2728: the node MERGE binds for `match` (`MergeMatch.bindable`),
    /// auditing a refusal. The refusal is a covert channel: it tells the
    /// session that some row it may not see equals the pattern (see
    /// docs/kb/RLS_IMPLEMENTATION.md), so every one is recorded with the
    /// user, the graph, the labels and the property KEYS, never the values
    /// (the values are the secret being guessed).
    fn bindNode(self: *MergeVisibility, match: MergeMatch, labels: []const []const u8, props: ?[]const EvaluatedPatternProp) error{MergeMatchNotVisible}!?u64 {
        return match.bindable() catch |err| {
            var keys: [16][]const u8 = undefined;
            var n: usize = 0;
            if (props) |ps| for (ps) |p| {
                if (n == keys.len) break;
                keys[n] = p.key;
                n += 1;
            };
            self.auditRefusal("node", labels, keys[0..n]);
            return err;
        };
    }

    /// SONNY-2728: `bindNode` for the edge of a relationship pattern: its
    /// types and the keys of its inline properties.
    fn bindEdge(self: *MergeVisibility, match: EdgeMatch, rel: ast.RelPattern) error{MergeMatchNotVisible}!?u64 {
        return match.bindable() catch |err| {
            var keys: [16][]const u8 = undefined;
            var n: usize = 0;
            if (rel.props) |ps| for (ps) |p| {
                if (n == keys.len) break;
                keys[n] = p.key;
                n += 1;
            };
            self.auditRefusal("relationship", rel.types, keys[0..n]);
            return err;
        };
    }

    fn auditRefusal(self: *MergeVisibility, pattern: []const u8, labels: []const []const u8, keys: []const []const u8) void {
        const audit_mod = @import("../security/audit.zig");
        // SONNY-2819: the labels and keys are the client's text; their
        // control characters are hex-encoded here, and the audit writer
        // escapes the whole record as well.
        const joined_labels = joinAuditText(self.allocator, labels) catch return;
        defer self.allocator.free(joined_labels);
        const joined_keys = joinAuditText(self.allocator, keys) catch return;
        defer self.allocator.free(joined_keys);
        const details = std.fmt.allocPrint(
            self.allocator,
            "MERGE refused (MergeMatchNotVisible, 42501): only rows row-level security hides from the session match the {s} pattern; graph={s} labels=[{s}] keys=[{s}] (values withheld)",
            .{ pattern, self.graph, joined_labels, joined_keys },
        ) catch return;
        defer self.allocator.free(details);
        audit_mod.logSecurityGraphEvent(self.allocator, .{
            .event_type = .access_denied,
            .action = "MERGE_MATCH_NOT_VISIBLE",
            .user_id = self.user_id,
            .username = self.username,
            .details = details,
            .result_failure = true,
            .resource_graph = self.graph,
        });
    }

    fn deinit(self: *MergeVisibility) void {
        self.rls_row.deinit();
    }

    /// May MERGE bind `node`, a node that already matches its pattern?
    fn allows(self: *MergeVisibility, node: *const graph_store.Node) bool {
        if (!self.rls_may_deny) return true;
        return match_operations.passesRowVisibilityFilters(&self.rls_row, node.*, self.filter_tenant);
    }

    /// P12: may MERGE bind `edge`, an edge that already matches its
    /// relationship pattern (graph, tenant tag and type)? The RLS policies of
    /// its type: the label-deny policy on the type and the expression policies
    /// over the edge's own properties (`passesEdgeRLSFilter`, the check every
    /// traversal applies to an edge it walks).
    fn allowsEdge(self: *MergeVisibility, edge: *const graph_store.Edge) bool {
        if (!self.rls_may_deny) return true;
        return match_operations.passesEdgeRLSFilter(&self.rls_row, edge);
    }
};

/// SONNY-2686: what MERGE's match phase found for one node pattern.
const MergeMatch = union(enum) {
    /// No node in the statement's graph and the session's tenant matches.
    none,
    /// A node the session may see matches (the first one found).
    visible: u64,
    /// Nodes match, and the session may see none of them.
    hidden,

    /// The node MERGE binds, or null when it creates one.
    ///
    /// A pattern whose only matches are hidden REFUSES the statement with
    /// `error.MergeMatchNotVisible` (42501, proto_util.mapError), before
    /// anything is bound, updated or created. The two other answers are both
    /// wrong:
    ///   * binding the hidden node is the leak: RETURN reads it, ON MATCH SET
    ///     rewrites it (under an expression policy, reclassifying it so that it
    ///     becomes visible), and a relationship attaches to it;
    ///   * treating it as absent CREATES A DUPLICATE of an existing row. That
    ///     breaks the one-node-per-pattern contract MERGE exists for (the merge
    ///     index keeps one id per key, so later MERGEs bind either copy), and
    ///     it surfaces as two rows the moment the policy changes.
    /// The refusal does tell the session that some row it may not see matches
    /// the pattern, the fact a unique-key violation reveals, but never which
    /// row, nor anything it holds, and nothing is written.
    fn bindable(self: MergeMatch) error{MergeMatchNotVisible}!?u64 {
        return switch (self) {
            .none => null,
            .visible => |id| id,
            .hidden => error.MergeMatchNotVisible,
        };
    }
};

/// Find the node MERGE binds for a pattern: the first node in the graph and
/// the tenant that carries every label and property of the pattern AND that
/// the session may see (SONNY-2686). A visible match is preferred over a
/// hidden one wherever the two sit, so a hidden node found first (for
/// example, by the merge index) never ends the search.
fn findMergeMatch(
    read_store: *graph_store.GraphStore,
    graph_name: []const u8,
    tenant_id: ?[]const u8,
    labels: []const []const u8,
    props: ?[]const EvaluatedPatternProp,
    visibility: *MergeVisibility,
) MergeMatch {
    // A node that matches the pattern but that the session may not see.
    var saw_hidden = false;

    // Fast path: use the merge property index for O(1) lookup when we have
    // at least one label and at least one property.
    if (labels.len > 0) {
        if (props) |evaluated_props| {
            if (evaluated_props.len > 0) {
                // CANARY: REQ=REQ-ENG-3914-MERGE-GENERAL-PATH-IDEMPOTENCY; FEATURE="MergeIdempotency"; ASPECT=IndexProbeAuthority; STATUS=TESTED; TEST=tests/test_eng3914_merge_idempotency.zig; OWNER=crud_operations; UPDATED=2026-08-25
                // ENG-3914 — DETERMINISTIC (not concurrent) MERGE duplication.
                //
                // `merge_prop_index` holds exactly ONE node id per
                // (graph, label, key, value): `putOrUpdate` OVERWRITES. So for
                // a multi-property MERGE key whose FIRST property value is
                // SHARED across rows, the bucket's occupant is whichever row
                // was written last.
                //
                // The old code probed `evaluated_props[0]` only, and when the
                // returned candidate failed full verification it fell through
                // leaving `index_authoritative` TRUE — which the code below
                // reads as "the index proved this node does not exist" and
                // uses to SKIP the label-scan fallback. MERGE then took the
                // CREATE branch and duplicated an existing row, every single
                // run (verified: 3 passes -> 3x rows).
                //
                // Two changes, both required:
                //   1. a candidate that fails verification clears
                //      `index_authoritative` — a shared-value bucket can only
                //      ever prove PRESENCE, never absence;
                //   2. every evaluated property is probed, not just the first,
                //      so a discriminating property still resolves the row in
                //      O(1) instead of dropping to the label scan.
                var index_authoritative = true;
                for (evaluated_props) |probe_prop| {
                    const pv = valueToPropertyValueForIndex(probe_prop.value) orelse {
                        // Non-scalar (list/map/…) values are not in the index,
                        // so it cannot answer for this property.
                        index_authoritative = false;
                        continue;
                    };
                    for (labels) |label| {
                        var out_id: u64 = undefined;
                        switch (read_store.lookupMergeCandidate(graph_name, label, probe_prop.key, pv, &out_id)) {
                            .found => {
                                // Verify the candidate matches ALL labels, ALL properties, and tenant
                                if ((read_store.nodes.getOrHydratePtr(out_id) catch null)) |node| {
                                    if (nodeMatchesPattern(node, graph_name, tenant_id, labels, evaluated_props)) {
                                        if (visibility.allows(node)) return .{ .visible = out_id };
                                        // SONNY-2686: the bucket holds a node
                                        // the session may not see. It holds
                                        // ONE id per key, so a visible node
                                        // with the same key can still exist:
                                        // the fallback scan looks for it.
                                        saw_hidden = true;
                                    }
                                }
                                // The bucket is occupied by a DIFFERENT node,
                                // which says nothing about whether the node we
                                // want exists. Force the fallback scan.
                                index_authoritative = false;
                            },
                            .not_found => {},
                            .not_indexable => {
                                index_authoritative = false;
                            },
                        }
                    }
                }
                // Only when every probe came back as an authoritative MISS can
                // the node be declared absent and the expensive O(n) label
                // scan skipped.
                if (index_authoritative) return .none;
            }
        }

        // Fallback: stream through the label index directly (no ArrayList materialization).
        // Uses the first label for O(1) index lookup, then checks remaining labels + props inline.
        // Only reached when the merge property index could not be consulted
        // (non-indexable value type or key too long for the 1024-byte buffer),
        // or when its bucket held a node the session may not see.
        const first_label_nodes = read_store.getNodesByLabel(graph_name, labels[0]) orelse
            return if (saw_hidden) .hidden else .none;
        for (first_label_nodes) |node_id| {
            if ((read_store.nodes.getOrHydratePtr(node_id) catch null)) |node| {
                if (nodeMatchesPattern(node, graph_name, tenant_id, labels, props)) {
                    if (visibility.allows(node)) return .{ .visible = node_id };
                    saw_hidden = true;
                }
            }
        }
        return if (saw_hidden) .hidden else .none;
    }

    // No labels — must scan all nodes (unchanged behavior, but streaming)
    var iter = read_store.nodes.iterator();
    while (iter.next()) |entry| {
        if (nodeMatchesPattern(entry.value_ptr, graph_name, tenant_id, &.{}, props)) {
            if (visibility.allows(entry.value_ptr)) return .{ .visible = entry.key_ptr.* };
            saw_hidden = true;
        }
    }
    return if (saw_hidden) .hidden else .none;
}

/// Collect ALL candidate node IDs matching labels (used by relationship MERGE and DELETE).
/// For single-node MERGE, prefer findMergeMatch which uses the merge property index.
fn collectCandidateNodeIds(
    allocator: std.mem.Allocator,
    read_store: *graph_store.GraphStore,
    graph_name: []const u8,
    tenant_id: ?[]const u8,
    labels: []const []const u8,
    props: ?[]const EvaluatedPatternProp,
) ![]u64 {
    _ = props;
    if (labels.len > 0) {
        var candidates = try read_store.getNodesByLabels(allocator, graph_name, labels, tenant_id);
        return try candidates.toOwnedSlice(allocator);
    }

    var candidates = std.ArrayList(u64).empty;
    errdefer candidates.deinit(allocator);

    var iter = read_store.nodes.iterator();
    while (iter.next()) |entry| {
        const node = entry.value_ptr;
        if (!std.mem.eql(u8, node.graph_name, graph_name)) continue;
        if (tenant_id) |tid| {
            if (!std.mem.eql(u8, node.tenant_id, tid)) continue;
        }
        try candidates.append(allocator, entry.key_ptr.*);
    }

    return try candidates.toOwnedSlice(allocator);
}

fn edgeMatchesScopeAndType(
    edge: *const graph_store.Edge,
    graph_name: []const u8,
    tenant_id: ?[]const u8,
    rel_types: []const []const u8,
) bool {
    if (!std.mem.eql(u8, edge.graph_name, graph_name)) return false;
    if (tenant_id) |tid| {
        if (!std.mem.eql(u8, edge.tenant_id, tid)) return false;
    }
    if (rel_types.len == 0) return true;
    for (rel_types) |rel_type| {
        if (std.mem.eql(u8, edge.label, rel_type)) return true;
    }
    return false;
}

// CANARY: REQ=REQ-SONNY-2686-MERGE-EDGE-RLS; FEATURE="MergeRowVisibility"; ASPECT=RelationshipMatchEdgeRls; STATUS=TESTED; TEST=tests/test_sonny2686_merge_rls.zig; OWNER=security; UPDATED=2026-09-26
/// P12 (the SONNY-2686 security review): the edge a relationship MERGE binds
/// between two resolved endpoints. It matched on the edge's graph, tenant tag
/// and type only, never on the RLS policies of its type, so `MERGE
/// (a)-[r:SECRET]->(b) ON MATCH SET r.v = ..` rewrote an edge every MATCH
/// hides. An edge the session may not see is treated like a hidden node
/// (`MergeMatch`): a visible match wins wherever it sits, and when only
/// hidden edges match the statement is refused.
const EdgeMatch = union(enum) {
    /// No edge of the pattern's type joins the endpoints.
    none,
    /// An edge the session may see (the first one found).
    visible: u64,
    /// Edges match, and the session may see none of them.
    hidden,

    /// The edge MERGE binds, or null when it creates one; refuses with
    /// `error.MergeMatchNotVisible` when only hidden edges match (see
    /// `MergeMatch.bindable` for why neither binding nor duplicating is right).
    fn bindable(self: EdgeMatch) error{MergeMatchNotVisible}!?u64 {
        return switch (self) {
            .none => null,
            .visible => |id| id,
            .hidden => error.MergeMatchNotVisible,
        };
    }
};

fn findExistingEdge(
    read_store: *graph_store.GraphStore,
    graph_name: []const u8,
    tenant_id: ?[]const u8,
    source_id: u64,
    target_id: u64,
    rel_types: []const []const u8,
    visibility: *MergeVisibility,
) EdgeMatch {
    const outgoing_ids = read_store.getOutgoingEdgeIds(source_id) orelse return .none;
    var saw_hidden = false;
    for (outgoing_ids) |edge_id| {
        const edge = read_store.getEdgePtrHydrated(edge_id) orelse continue;
        if (edge.to_id != target_id) continue;
        if (!edgeMatchesScopeAndType(edge, graph_name, tenant_id, rel_types)) continue;
        if (visibility.allowsEdge(edge)) return .{ .visible = edge_id };
        saw_hidden = true;
    }
    return if (saw_hidden) .hidden else .none;
}

/// ENG-3913: the deduplicated entity sets a `MATCH … DELETE …` statement targets.
const DeleteTargets = struct {
    node_ids: []u64,
    edge_ids: []u64,

    fn deinit(self: DeleteTargets, allocator: std.mem.Allocator) void {
        allocator.free(self.node_ids);
        allocator.free(self.edge_ids);
    }
};

fn appendUniqueId(allocator: std.mem.Allocator, list: *std.ArrayList(u64), id: u64) !void {
    for (list.items) |existing| if (existing == id) return;
    try list.append(allocator, id);
}

// CANARY: REQ=REQ-DELETE-MATCH-SET-RESOLUTION; FEATURE="DeleteWhereEvaluation"; ASPECT=MatchSetResolution; STATUS=TESTED; TEST=tests/test_eng3913_where_delete.zig; OWNER=crud_operations; UPDATED=2026-08-25
/// ENG-3913 — resolve the entities a `MATCH … [WHERE …] DELETE …` statement
/// targets by running the SAME matching path a `RETURN` of those variables
/// runs, then reading the bound entities straight out of the projected rows.
///
/// WHY THIS IS NOT A HAND-ROLLED PATTERN WALK ANY MORE. The reconstruction
/// this replaces was independently wrong in four ways, every one of which
/// either lost data or refused to delete data:
///
///   (A) the WHERE `Env` was built with NO parameter bindings, so a `$param`
///       predicate evaluated to NULL and the whole DELETE silently no-opped;
///   (B) the `Env` bound ONLY `chains[0].head.name`, so a cross-variable
///       predicate (`… WHERE b.tag = 'x' DELETE a`) resolved NULL (no-op),
///       and when the delete target was a HOP node the head's NAME was bound
///       to the TARGET's value (wrong rows evaluated);
///   (C) the candidate set came from `chains[0].head`'s labels + inline
///       properties ONLY — relationship hops were never traversed — so a
///       pattern-restricted delete OVER-DELETED, removing nodes the pattern
///       excludes (verified: an isolated, edge-less node was destroyed by
///       `MATCH (a:A)-[:R]->(b:B) DETACH DELETE a`);
///   (D) the relationship branch had NO `where_clause` handling at all, so
///       `MATCH ()-[r:R]->() WHERE r.w = 1 DELETE r` deleted 100% of the `R`
///       edges instead of the one.
///
/// Routing through the match engine subsumes all four AND makes a predicate
/// that fails to evaluate propagate its error (it used to be swallowed into
/// `should_delete = false`, i.e. a silent partial delete). It also makes
/// DELETE observe the same tenant / RLS row filters the read path applies, so
/// a session can no longer destroy rows it is not allowed to read.
fn resolveDeleteTargets(
    allocator: std.mem.Allocator,
    d: ast.DeleteStatement,
    match_pattern: ast.GraphPattern,
    context: ExecutionContext,
) !DeleteTargets {
    // Ordered, deduplicated list of the variables named by the DELETE items.
    var target_vars = std.ArrayList([]const u8).empty;
    defer target_vars.deinit(allocator);

    if (d.items.len > 0) {
        for (d.items) |item| {
            const var_name = switch (item) {
                .Variable => |n| n,
                .Node => |n| n,
                .Relationship => |n| n,
            };
            var seen = false;
            for (target_vars.items) |existing| {
                if (std.mem.eql(u8, existing, var_name)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try target_vars.append(allocator, var_name);
        }
    } else {
        // Defensive: the parser always requires at least one DELETE item after a
        // MATCH clause, so this branch is unreachable today. Target every named
        // node in the pattern rather than guessing at the head.
        for (match_pattern.chains) |chain| {
            if (chain.head) |head| {
                if (head.name) |name| try appendUniqueVar(allocator, &target_vars, name);
            }
            for (chain.hops) |hop| {
                if (hop.left.name) |name| try appendUniqueVar(allocator, &target_vars, name);
                if (hop.right.name) |name| try appendUniqueVar(allocator, &target_vars, name);
            }
        }
    }

    var node_ids = std.ArrayList(u64).empty;
    errdefer node_ids.deinit(allocator);
    var edge_ids = std.ArrayList(u64).empty;
    errdefer edge_ids.deinit(allocator);

    if (target_vars.items.len == 0) {
        return .{
            .node_ids = try node_ids.toOwnedSlice(allocator),
            .edge_ids = try edge_ids.toOwnedSlice(allocator),
        };
    }

    // Project exactly the delete variables. `caseFoldToUpper` mirrors what the
    // parser stores in `IdentRepr.cnf` for a bare identifier.
    const unicode = @import("../unicode/unicode_tables.zig");
    const items = try allocator.alloc(ast.ReturnItem, target_vars.items.len);
    defer {
        for (items) |item| {
            const cnf = item.expr.Ident.cnf;
            if (cnf.ptr != item.expr.Ident.orig.ptr) allocator.free(cnf);
        }
        allocator.free(items);
    }
    for (items, target_vars.items) |*item, name| {
        const cnf = unicode.caseFoldToUpper(allocator, name) catch name;
        item.* = .{ .expr = .{ .Ident = .{ .orig = name, .cnf = cnf } }, .alias = null };
    }

    const q = ast.Query{
        .optional_match = false,
        .match = match_pattern,
        .where_clause = d.where_clause,
        .with_clause = null,
        .ret = .{ .items = items, .distinct = false },
        .order_by = null,
        .limit = null,
        .offset = null,
    };

    // `executeQueryWithContext` is the SAME entry point the statement dispatcher
    // uses for a plain `MATCH … RETURN …`, so the resolved set is by
    // construction the set a RETURN of these variables would project (it also
    // pushes the active ExecutionContext, which is what carries the tenant
    // scope into the scan). The statement dispatcher's row-window / match-guard
    // truncation is deliberately NOT applied: a guard-trimmed DELETE would be a
    // silent partial delete.
    var result = try execution.executeQueryWithContext(allocator, q, context);
    defer result.deinit(allocator);

    for (result.rows) |row| {
        for (row) |value| {
            switch (value) {
                .Node => |node| try appendUniqueId(allocator, &node_ids, node.id),
                .Edge => |edge| try appendUniqueId(allocator, &edge_ids, edge.id),
                // An unbound / non-entity projection (e.g. a DELETE item naming a
                // variable the pattern never binds) targets nothing.
                else => {},
            }
        }
    }

    return .{
        .node_ids = try node_ids.toOwnedSlice(allocator),
        .edge_ids = try edge_ids.toOwnedSlice(allocator),
    };
}

fn appendUniqueVar(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), name: []const u8) !void {
    for (list.items) |existing| if (std.mem.eql(u8, existing, name)) return;
    try list.append(allocator, name);
}

// CANARY: REQ=REQ-AUTO-INDEX-003; FEATURE="AutoIdIndex"; ASPECT=CrudAutoIndex; STATUS=TESTED; OWNER=crud_operations; UPDATED=2026-04-30
/// Ensure auto-indexes exist for the given labels.
/// Called after node/edge creation to auto-create btree indexes on the `id` property.
/// Made `pub` so the bulk fast paths in `src/server/quic_connection_handler.zig`
/// (which bypass `executeProgramWithContext` and therefore skip the regular-
/// path auto-index hook at the CREATE site) can call it directly after a
/// successful bulk insert.  Mirrors the regular pattern already used at
/// line 690 of this file.
pub fn ensureAutoIndexes(allocator: std.mem.Allocator, labels: []const []const u8) void {
    const cat = execution.ensureCatalogInstance(allocator) catch return;
    for (labels) |label| {
        cat.ensureAutoIdIndex(label) catch |err| {
            log.warn("Failed to create auto-index", &.{
                Attr.string("label", label),
                Attr.string("error", @errorName(err)),
            });
        };
    }
}

// CANARY: REQ=REQ-CONSTRAINT-ENFORCE-002; FEATURE="ConstraintEnforcement"; ASPECT=Validation; STATUS=TESTED; TEST=geodetestlab/specs/gql_catalog_operations_comprehensive.yml; OWNER=engine; UPDATED=2026-01-09
/// Constraint violation error
pub const ConstraintViolationError = error{
    UniqueConstraintViolation,
    NotNullConstraintViolation,
    NodeKeyConstraintViolation,
};

/// Validate constraints before creating a node
/// Checks UNIQUE, NOT NULL, and NODE KEY constraints
fn validateConstraints(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    labels: []const []const u8,
    props: ?[]const ast.PropSpec,
    context: *const execution.ExecutionContext,
) ConstraintViolationError!void {
    // Get catalog from context
    const cat = context.catalog;

    // Check constraints for each label
    for (labels) |label| {
        const constraints = cat.getConstraintsForLabel(label) catch continue;
        defer allocator.free(constraints);

        for (constraints) |constraint| {
            if (!constraint.is_enforced) continue;

            switch (constraint.constraint_type) {
                .unique => {
                    // Check if any existing node has same property value
                    if (props) |prop_specs| {
                        for (constraint.properties) |prop_name| {
                            for (prop_specs) |prop_spec| {
                                if (std.mem.eql(u8, prop_spec.key, prop_name)) {
                                    // Found the property, check for duplicates
                                    const value = eval.evalExpr(allocator, prop_spec.value.*, Env{
                                        .names = &.{},
                                        .values = &.{},
                                        .allocator = allocator,
                                    }) catch continue;

                                    // Check if value exists in any node with this label
                                    if (checkUniqueViolation(store, label, prop_name, value)) {
                                        return ConstraintViolationError.UniqueConstraintViolation;
                                    }
                                }
                            }
                        }
                    }
                },
                .not_null => {
                    // Check if required property is present and non-null
                    for (constraint.properties) |prop_name| {
                        var found = false;
                        if (props) |prop_specs| {
                            for (prop_specs) |prop_spec| {
                                if (std.mem.eql(u8, prop_spec.key, prop_name)) {
                                    found = true;
                                    // Check if value is null
                                    const value = eval.evalExpr(allocator, prop_spec.value.*, Env{
                                        .names = &.{},
                                        .values = &.{},
                                        .allocator = allocator,
                                    }) catch continue;

                                    if (value == .Null) {
                                        return ConstraintViolationError.NotNullConstraintViolation;
                                    }
                                    break;
                                }
                            }
                        }
                        if (!found) {
                            return ConstraintViolationError.NotNullConstraintViolation;
                        }
                    }
                },
                .node_key => {
                    // NODE KEY is combination of NOT NULL + UNIQUE
                    // First check all properties present
                    for (constraint.properties) |prop_name| {
                        var found = false;
                        if (props) |prop_specs| {
                            for (prop_specs) |prop_spec| {
                                if (std.mem.eql(u8, prop_spec.key, prop_name)) {
                                    found = true;
                                    break;
                                }
                            }
                        }
                        if (!found) {
                            return ConstraintViolationError.NodeKeyConstraintViolation;
                        }
                    }
                    // Then check uniqueness of combination (simplified: check first property)
                    if (constraint.properties.len > 0 and props != null) {
                        const first_prop = constraint.properties[0];
                        for (props.?) |prop_spec| {
                            if (std.mem.eql(u8, prop_spec.key, first_prop)) {
                                const value = eval.evalExpr(allocator, prop_spec.value.*, Env{
                                    .names = &.{},
                                    .values = &.{},
                                    .allocator = allocator,
                                }) catch continue;

                                if (checkUniqueViolation(store, label, first_prop, value)) {
                                    return ConstraintViolationError.NodeKeyConstraintViolation;
                                }
                            }
                        }
                    }
                },
                .exists => {
                    // EXISTS just requires property to be present (not necessarily non-null)
                    for (constraint.properties) |prop_name| {
                        var found = false;
                        if (props) |prop_specs| {
                            for (prop_specs) |prop_spec| {
                                if (std.mem.eql(u8, prop_spec.key, prop_name)) {
                                    found = true;
                                    break;
                                }
                            }
                        }
                        if (!found) {
                            return ConstraintViolationError.NotNullConstraintViolation;
                        }
                    }
                },
            }
        }
    }
}

/// Check if a unique constraint would be violated
fn checkUniqueViolation(
    store: *graph_store.GraphStore,
    label: []const u8,
    property: []const u8,
    value: Value,
) bool {
    if (graph_store.getGlobalAdapter()) |adapter| {
        const storage_prop = property_codec.valueToPropertyValue(store.allocator, value) catch {
            return false;
        };
        defer property_codec.freePropertyValue(store.allocator, storage_prop);

        const candidate_ids = adapter.getCandidateNodesByLabelAndProperty(
            "default",
            label,
            property,
            storage_prop,
            store.allocator,
        ) catch {
            return false;
        };
        defer store.allocator.free(candidate_ids);

        for (candidate_ids) |node_id| {
            const existing_value = store.getNodePropertyValue(node_id, property) catch continue;
            if (valuesEqual(existing_value, value)) {
                return true;
            }
        }
        return false;
    }

    // Get all nodes with this label
    const nodes = store.getNodesByLabel("default", label) orelse return false;

    // Check if any node has same property value
    for (nodes) |node_id| {
        const existing_value = store.getNodePropertyValue(node_id, property) catch continue;
        if (valuesEqual(existing_value, value)) {
            return true; // Violation found
        }
    }

    return false;
}

/// Compare two values for equality
fn valuesEqual(prop_val: graph_store.PropertyValue, value: Value) bool {
    return execution.valuesEqual(property_codec.propertyValueToValue(prop_val), value);
}

// CANARY: REQ=REQ-EXEC-REFACTOR-004; FEATURE="ExecutionRefactoring"; ASPECT=CRUD_OPERATIONS; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-10-17
// Extracted CRUD operations (CREATE/INSERT/MERGE/DELETE) from execution.zig for better modularity (M1 Phase 4)

// CANARY: REQ=REQ-MULTI-GRAPH-016; FEATURE="MultiGraphIsolation"; ASPECT=CreateForBatch; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
pub fn executeCreateForBatch(allocator: std.mem.Allocator, create_pattern: ast.GraphPattern, matched_bindings: std.StringHashMap(u64), current_graph: ?[]const u8) !i64 {
    const store = graph_store.getGlobalStore(allocator);
    const target_graph = current_graph orelse "default";
    var created_relationships: i64 = 0;

    // Track created nodes by variable name
    var created_nodes = std.StringHashMap(u64).init(allocator);
    defer {
        // Free all duplicated keys (both from matched_bindings and new creates)
        var key_iter = created_nodes.iterator();
        while (key_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        created_nodes.deinit();
    }

    // Copy matched bindings to created_nodes (keys are already duplicated by caller)
    var iter = matched_bindings.iterator();
    while (iter.next()) |entry| {
        // Duplicate the key since we need our own copy for created_nodes
        const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
        try created_nodes.put(key_copy, entry.value_ptr.*);
    }

    // Statement-atomicity pre-pass — see `executeCreate`. Same empty env the
    // apply loops below use.
    // CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=CreatePrePass; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25
    const row_env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };
    try write_precheck.checkPatternWritable(allocator, create_pattern, row_env);

    // Process CREATE pattern
    for (create_pattern.chains) |chain| {
        // Handle single node creation
        if (chain.head) |node_pattern| {
            // Check if this node already exists in matched bindings
            const node_id = if (node_pattern.name) |var_name| blk: {
                if (created_nodes.get(var_name)) |existing_id| {
                    // Node already matched from MATCH clause, don't create new
                    break :blk existing_id;
                } else {
                    // Variable not bound, create new node in target graph
                    const new_id = try store.createNodeWithGraph(node_pattern.labels, target_graph);
                    // CANARY: REQ=REQ-TXN-UNDO-009; FEATURE="TransactionUndoLog"; ASPECT=LogCreateNode; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
                    // Log node creation for rollback support
                    const undo_log = txn_undo_log.getGlobalUndoLog(allocator);
                    undo_log.logCreateNode(new_id, current_graph) catch |err| {
                        log.err("undo log failed", &.{Attr.string("error", @errorName(err))});
                    };
                    const var_name_copy = try allocator.dupe(u8, var_name);
                    try created_nodes.put(var_name_copy, new_id);
                    break :blk new_id;
                }
            } else blk: {
                // No variable name, always create new node in target graph
                const new_id = try store.createNodeWithGraph(node_pattern.labels, target_graph);
                // Log node creation for rollback support
                const undo_log = txn_undo_log.getGlobalUndoLog(allocator);
                undo_log.logCreateNode(new_id, current_graph) catch |err| {
                    log.err("undo log failed", &.{Attr.string("error", @errorName(err))});
                };
                break :blk new_id;
            };

            // Set properties if present
            if (node_pattern.props) |props| {
                for (props) |prop| {
                    const value = try eval.evalExpr(allocator, prop.value.*, row_env);
                    try property_mutation.setNodePropertyFromValue(allocator, store, node_pattern.labels, node_id, prop.key, value);
                }
            }

            // Auto-create indexes for node labels
            ensureAutoIndexes(allocator, node_pattern.labels);
        }

        // Handle relationship creation
        for (chain.hops) |hop| {
            // For batch CREATE from MATCH, nodes must already exist in bindings
            // Only create new nodes if they're anonymous or not from MATCH
            const left_id = if (hop.left.name) |var_name| blk: {
                if (created_nodes.get(var_name)) |node_id| {
                    // Use existing node from bindings
                    break :blk node_id;
                } else if (matched_bindings.count() > 0) {
                    // In batch mode with matched bindings, skip if node not found
                    // This shouldn't happen if the query is well-formed
                    continue;
                } else {
                    // Not in batch mode - create new node in target graph
                    const new_id = try store.createNodeWithGraph(hop.left.labels, target_graph);
                    const var_name_copy = try allocator.dupe(u8, var_name);
                    try created_nodes.put(var_name_copy, new_id);
                    ensureAutoIndexes(allocator, hop.left.labels);
                    break :blk new_id;
                }
            } else blk: {
                // Anonymous node - always create new in target graph
                const new_id = try store.createNodeWithGraph(hop.left.labels, target_graph);
                ensureAutoIndexes(allocator, hop.left.labels);
                break :blk new_id;
            };

            const right_id = if (hop.right.name) |var_name| blk: {
                if (created_nodes.get(var_name)) |node_id| {
                    // Use existing node from bindings
                    break :blk node_id;
                } else if (matched_bindings.count() > 0) {
                    // In batch mode with matched bindings, skip if node not found
                    // This shouldn't happen if the query is well-formed
                    continue;
                } else {
                    // Not in batch mode - create new node in target graph
                    const new_id = try store.createNodeWithGraph(hop.right.labels, target_graph);
                    const var_name_copy = try allocator.dupe(u8, var_name);
                    try created_nodes.put(var_name_copy, new_id);
                    ensureAutoIndexes(allocator, hop.right.labels);
                    break :blk new_id;
                }
            } else blk: {
                // Anonymous node - always create new in target graph
                const new_id = try store.createNodeWithGraph(hop.right.labels, target_graph);
                ensureAutoIndexes(allocator, hop.right.labels);
                break :blk new_id;
            };

            // Create the relationship in target graph
            const edge_label = if (hop.rel.types.len > 0) hop.rel.types[0] else "RELATED";
            const edge_id = try store.createEdgeWithGraph(left_id, right_id, edge_label, target_graph);
            // Log edge creation for rollback support
            const undo_log_edge = txn_undo_log.getGlobalUndoLog(allocator);
            undo_log_edge.logCreateEdge(edge_id, current_graph) catch |err| {
                log.err("undo log failed", &.{Attr.string("error", @errorName(err))});
            };
            created_relationships += 1;

            // Auto-create index for edge type
            ensureAutoIndexes(allocator, &.{edge_label});

            // Set relationship properties if present
            if (hop.rel.props) |props| {
                for (props) |prop| {
                    const value = try eval.evalExpr(allocator, prop.value.*, row_env);
                    try property_mutation.setEdgePropertyFromValue(allocator, store, edge_label, edge_id, prop.key, value);
                }
            }
        }
    }

    return created_relationships;
}

// Result struct for tracking created entities
const CreateBatchResult = struct {
    // Sum of nodes + relationships (kept for compatibility; prefer the
    // per-kind counts below — summing them mislabeled relationships as
    // nodes in the MATCH…CREATE summary row).
    created_count: i64,
    created_nodes_count: i64,
    created_relationships_count: i64,
    created_nodes: std.StringHashMap(u64),
    created_relationships: std.StringHashMap(Value),
};

fn isMatchVar(match_var_names: []const []const u8, name: []const u8) bool {
    for (match_var_names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

// Apply a hop endpoint NodePattern's inline props to a newly created node.
// Mirrors `executeCreate`'s hop path (endpoint-prop application after node
// resolution) using the same Env/eval machinery as the relationship-props
// block in `executeCreateForBatchWithTracking` — this batch path carries no
// query parameters, so the Env is empty.
fn applyEndpointProps(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    node_pattern: ast.NodePattern,
    node_id: u64,
    env: Env,
) !void {
    const props = node_pattern.props orelse return;
    for (props) |prop| {
        const value = try eval.evalExpr(allocator, prop.value.*, env);
        try property_mutation.setNodePropertyFromValue(allocator, store, node_pattern.labels, node_id, prop.key, value);
    }
}

// True when a hop endpoint is a MATCH variable that failed to bind for this
// row (the GAP-0336 conservative-skip rule). Resolved for BOTH endpoints
// BEFORE either node is created so a skipped hop never leaves an orphan
// newly-created endpoint behind (e.g. `MATCH (a) CREATE (new:X)-[:R]->(a)`
// with `a` absent from the row's bindings must not create `new`).
fn hopEndpointSkips(
    endpoint: ast.NodePattern,
    created_nodes: *const std.StringHashMap(u64),
    matched_bindings: *const std.StringHashMap(u64),
    match_var_names: []const []const u8,
) bool {
    const var_name = endpoint.name orelse return false;
    if (created_nodes.contains(var_name)) return false;
    return matched_bindings.count() > 0 and isMatchVar(match_var_names, var_name);
}

// CANARY: REQ=REQ-MULTI-GRAPH-017; FEATURE="MultiGraphIsolation"; ASPECT=CreateForBatchWithTracking; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
// Enhanced version of executeCreateForBatch that returns created entities for RETURN clause evaluation.
//
// `match_var_names` is the set of node-variable names that appear in the
// query's MATCH pattern. A hop endpoint whose name is a MATCH variable but is
// absent from `matched_bindings` failed to bind for this row, so the hop is
// conservatively skipped (the GAP-0336 anonymous-node footgun). A name that is
// NOT a MATCH variable is a NEW variable introduced by the CREATE pattern
// (e.g. `MATCH (a) CREATE (a)-[:R]->(new:Label)`) and MUST be created.
//
// SONNY-2694: `row_env` is the matched row (its variables and the statement's
// parameters), which the CREATE pattern's property values are evaluated in.
// They were evaluated in an empty environment, so `MATCH (n) CREATE (:Z {k:
// n.i})` and a `$parameter` wrote null.
pub fn executeCreateForBatchWithTracking(allocator: std.mem.Allocator, create_pattern: ast.GraphPattern, matched_bindings: std.StringHashMap(u64), match_var_names: []const []const u8, current_graph: ?[]const u8, row_env: Env) !CreateBatchResult {
    const store = graph_store.getGlobalStore(allocator);
    const target_graph = current_graph orelse "default";
    var created_relationships_count: i64 = 0;
    var created_nodes_count: i64 = 0;

    // R12 (2026-04-22): hook `executeCreateForBatchWithTracking` into the
    // R11 lazy session-txn infrastructure.  This path is hit for MATCH
    // + CREATE statements (the msft-graph edge-creation pattern), which
    // were not covered by the `executeCreate` / `executeMerge` hooks.
    // Without this, every per-property adapter call on a batch-created
    // edge auto-commits one WAL fsync, overwhelming the 120 s lock
    // budget on large edge files.
    const gsa = @import("../storage/graph_storage_adapter.zig");
    var batch_stmt_txn: gsa.StatementTxn = undefined;
    var batch_stmt_txn_open = false;
    if (graph_store.getGlobalAdapter()) |ad| {
        if (gsa.sessionEngineTxnGraph() == null) {
            // No session txn (we can't see `context` from here, so open a
            // per-statement txn unconditionally when the thread has no
            // pre-existing txn).  This is safe: the adapter's per-graph
            // exclusive write lock serialises callers.
            if (ad.beginStatementTxn(target_graph, &batch_stmt_txn)) |_| {
                batch_stmt_txn_open = true;
            } else |err| switch (err) {
                error.GraphNotFound, error.NestedStatementTxn => {},
                else => return err,
            }
        }
    }
    errdefer if (batch_stmt_txn_open) batch_stmt_txn.abort();

    // Track created nodes by variable name
    var created_nodes = std.StringHashMap(u64).init(allocator);
    errdefer created_nodes.deinit();

    // Track created relationships by variable name for RETURN clauses
    var created_relationships = std.StringHashMap(Value).init(allocator);
    errdefer created_relationships.deinit();

    // Copy matched bindings to created_nodes
    var iter = matched_bindings.iterator();
    while (iter.next()) |entry| {
        try created_nodes.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    // Statement-atomicity pre-pass — see `executeCreate`.
    // CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=CreatePrePass; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25
    try write_precheck.checkPatternWritable(allocator, create_pattern, row_env);

    // Process CREATE pattern
    for (create_pattern.chains) |chain| {
        // Handle single node creation
        if (chain.head) |node_pattern| {
            // Check if this node already exists in matched bindings
            const node_id = if (node_pattern.name) |var_name| blk: {
                if (created_nodes.get(var_name)) |existing_id| {
                    // Node already matched from MATCH clause, don't create new
                    break :blk existing_id;
                } else {
                    // Variable not bound, create new node in target graph
                    const new_id = try store.createNodeWithGraph(node_pattern.labels, target_graph);
                    try created_nodes.put(var_name, new_id);
                    created_nodes_count += 1;
                    break :blk new_id;
                }
            } else blk: {
                // No variable name, always create new node in target graph
                created_nodes_count += 1;
                break :blk try store.createNodeWithGraph(node_pattern.labels, target_graph);
            };

            // Set properties if present
            if (node_pattern.props) |props| {
                for (props) |prop| {
                    const value = try eval.evalExpr(allocator, prop.value.*, row_env);
                    try property_mutation.setNodePropertyFromValue(allocator, store, node_pattern.labels, node_id, prop.key, value);
                }
            }

            // Auto-create indexes for node labels
            ensureAutoIndexes(allocator, node_pattern.labels);
        }

        // Handle relationship creation
        for (chain.hops) |hop| {
            // Resolve BOTH endpoints' skip-status BEFORE creating either node:
            // if one endpoint is a MATCH variable that failed to bind for this
            // row, the whole hop is skipped and no orphan endpoint node may be
            // created (or counted) for the other side.
            if (hopEndpointSkips(hop.left, &created_nodes, &matched_bindings, match_var_names) or
                hopEndpointSkips(hop.right, &created_nodes, &matched_bindings, match_var_names))
            {
                continue;
            }

            // For batch CREATE from MATCH, nodes must already exist in bindings
            const left_id = if (hop.left.name) |var_name| blk: {
                if (created_nodes.get(var_name)) |node_id| {
                    break :blk node_id;
                } else {
                    const new_id = try store.createNodeWithGraph(hop.left.labels, target_graph);
                    try created_nodes.put(var_name, new_id);
                    created_nodes_count += 1;
                    ensureAutoIndexes(allocator, hop.left.labels);
                    try applyEndpointProps(allocator, store, hop.left, new_id, row_env);
                    break :blk new_id;
                }
            } else blk: {
                const new_id = try store.createNodeWithGraph(hop.left.labels, target_graph);
                created_nodes_count += 1;
                ensureAutoIndexes(allocator, hop.left.labels);
                try applyEndpointProps(allocator, store, hop.left, new_id, row_env);
                break :blk new_id;
            };

            const right_id = if (hop.right.name) |var_name| blk: {
                if (created_nodes.get(var_name)) |node_id| {
                    break :blk node_id;
                } else {
                    const new_id = try store.createNodeWithGraph(hop.right.labels, target_graph);
                    try created_nodes.put(var_name, new_id);
                    created_nodes_count += 1;
                    ensureAutoIndexes(allocator, hop.right.labels);
                    try applyEndpointProps(allocator, store, hop.right, new_id, row_env);
                    break :blk new_id;
                }
            } else blk: {
                const new_id = try store.createNodeWithGraph(hop.right.labels, target_graph);
                created_nodes_count += 1;
                ensureAutoIndexes(allocator, hop.right.labels);
                try applyEndpointProps(allocator, store, hop.right, new_id, row_env);
                break :blk new_id;
            };

            // Create the relationship in target graph
            const edge_label = if (hop.rel.types.len > 0) hop.rel.types[0] else "RELATED";
            const edge_id = try store.createEdgeWithGraph(left_id, right_id, edge_label, target_graph);
            // Log edge creation for rollback support
            const undo_log2 = txn_undo_log.getGlobalUndoLog(allocator);
            undo_log2.logCreateEdge(edge_id, current_graph) catch |err| {
                log.err("undo log failed", &.{Attr.string("error", @errorName(err))});
            };
            created_relationships_count += 1;

            // Auto-create index for edge type
            ensureAutoIndexes(allocator, &.{edge_label});

            // Set relationship properties if present
            if (hop.rel.props) |props| {
                for (props) |prop| {
                    const value = try eval.evalExpr(allocator, prop.value.*, row_env);
                    try property_mutation.setEdgePropertyFromValue(allocator, store, edge_label, edge_id, prop.key, value);
                }
            }

            // Track created relationship by variable name
            if (hop.rel.name) |rel_var_name| {
                const edge_ptr = store.getEdgePtrHydrated(edge_id) orelse return error.EdgeNotFound;
                const edge_value = Value{ .Edge = edge_ptr };
                try created_relationships.put(rel_var_name, edge_value);
            }
        }
    }

    if (batch_stmt_txn_open) try batch_stmt_txn.commit();
    return CreateBatchResult{
        .created_count = created_nodes_count + created_relationships_count,
        .created_nodes_count = created_nodes_count,
        .created_relationships_count = created_relationships_count,
        .created_nodes = created_nodes,
        .created_relationships = created_relationships,
    };
}

// CANARY: REQ=REQ-PERF-QPS-0815; FEATURE="BatchCreateFastPath"; ASPECT=HomogeneousDetection; STATUS=TESTED; TEST=tests/test_gap0815_batch_create.zig; OWNER=performance; UPDATED=2026-04-20
//
// GAP-0815: detect a query shape where the CREATE pattern contains N >= 3
// inline standalone node patterns (no hops, no variable references, no edges)
// that all share the SAME label set and the SAME prop-key set. Matching
// queries flow into `executeBatchCreateHomogeneous` which allocates all
// slots and writes properties via `setNodePropertiesBatch` (one adapter
// lock per node, not one per property setter).
//
// Any heterogeneity — different label count / order, different prop key
// count / order, missing head, hops present, variable names on nodes
// (so other clauses can reference them), WITH/SET/REMOVE/RETURN clauses —
// disqualifies the query and the caller falls back to the serial
// `executeCreateQuery` path.
const BATCH_CREATE_MIN_CLAUSES: usize = 3;

fn homogeneousPatternEligible(create_pattern: ast.GraphPattern) bool {
    // Require a minimum clause count — for small N the per-call adapter
    // lock overhead is in the noise and the detection cost is not worth it.
    if (create_pattern.chains.len < BATCH_CREATE_MIN_CLAUSES) return false;

    // Use the first chain's head as the template.
    const first_chain = create_pattern.chains[0];
    if (first_chain.hops.len != 0) return false;
    const first_head = first_chain.head orelse return false;
    // Named nodes may be referenced from subsequent SET/RETURN; also
    // closes the door on pattern chains that reference this node later.
    if (first_head.name != null) return false;
    // At least one label required (match-index predicate shape expected).
    if (first_head.labels.len == 0) return false;

    const first_props_len: usize = if (first_head.props) |p| p.len else 0;

    // All subsequent chains must mirror the template.
    for (create_pattern.chains[1..]) |chain| {
        if (chain.hops.len != 0) return false;
        const head = chain.head orelse return false;
        if (head.name != null) return false;
        if (head.labels.len != first_head.labels.len) return false;
        for (head.labels, first_head.labels) |a, b| {
            if (!std.mem.eql(u8, a, b)) return false;
        }

        const props_len: usize = if (head.props) |p| p.len else 0;
        if (props_len != first_props_len) return false;

        if (first_props_len != 0) {
            const head_props = head.props.?;
            const first_props = first_head.props.?;
            // Property keys must match in the SAME order — this is the
            // parse-time order and is stable for a given literal layout.
            for (head_props, first_props) |hp, fp| {
                if (!std.mem.eql(u8, hp.key, fp.key)) return false;
            }
        }
    }

    return true;
}

fn homogeneousCreateEligible(
    q: ast.Query,
    create_pattern: ast.GraphPattern,
    matched_bindings: ?std.StringHashMap(u64),
) bool {
    // The batch path emits an empty result set. If the caller wants a
    // WITH/SET/REMOVE/RETURN or count(*) aggregation we must fall through
    // to the slow path which tracks created_nodes / total_created_count.
    if (q.with_clause != null) return false;
    if (q.set_clauses.len != 0) return false;
    if (q.remove_clauses.len != 0) return false;
    if (q.ret.items.len != 0) return false;

    // MATCH-bound variables interact with created_nodes; skip.
    if (matched_bindings != null) return false;

    return homogeneousPatternEligible(create_pattern);
}

fn homogeneousCreateStatementEligible(c: ast.CreateStatement) bool {
    if (c.return_clause != null) return false;
    return homogeneousPatternEligible(c.pattern);
}

fn executeBatchCreateHomogeneous(
    allocator: std.mem.Allocator,
    create_pattern: ast.GraphPattern,
    param_names: []const []const u8,
    param_values: []const Value,
    current_graph: ?[]const u8,
) !ExecutionResult {
    // GAP-0815 regression probe: test harness reads this counter to verify
    // the batch path was taken. Increment on entry so a test that observes
    // an error from this function still sees the attempted invocation.
    _ = batch_create_invocations.fetchAdd(1, .monotonic);
    const store = graph_store.getGlobalStore(allocator);
    const target_graph = current_graph orelse "default";
    const undo_log = txn_undo_log.getGlobalUndoLog(allocator);

    // Template derived from the first chain.
    const template_head = create_pattern.chains[0].head.?;
    const labels = template_head.labels;
    const template_props: []ast.Property = if (template_head.props) |p| p else &.{};

    // Arena for per-node coerced PropertyValue allocations — all values
    // live for the duration of the batch call and are freed in one pass
    // after the adapter writes via `batch_arena.deinit()`.
    var batch_arena = std.heap.ArenaAllocator.init(allocator);
    defer batch_arena.deinit();
    const ba = batch_arena.allocator();

    const env = Env{
        .names = &.{},
        .values = &.{},
        .param_names = param_names,
        .param_values = param_values,
        .allocator = allocator,
    };

    // Statement-atomicity pre-pass — see `executeCreate`. This path allocates
    // ALL N node slots up front, so an unstorable property in clause k would
    // otherwise leave k-1 populated nodes plus N-k+1 empty ones behind.
    // CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=CreatePrePass; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25
    try write_precheck.checkPatternWritable(allocator, create_pattern, env);

    // Reusable batch buffer of adapter-consumable property entries.
    // Allocated once, overwritten per clause; ba-backed so it's released
    // in one `batch_arena.deinit()` at the end.
    var batch_entries: []graph_store.GraphStore.BatchPropertyEntry = &.{};
    if (template_props.len > 0) {
        batch_entries = try ba.alloc(graph_store.GraphStore.BatchPropertyEntry, template_props.len);
    }

    // GAP-0815-deep: allocate all N slots under a single adapter mutex
    // acquisition + a single pre-sized label-posting-list append pass,
    // instead of calling `createNodeWithGraph` N times. This collapses
    // the per-clause `getOrCreateGraph` mutex round-trip + the per-node
    // O(len) `sortedInsert` into one lock + one resize.
    //
    // Route the result slice through the per-request `allocator` (via
    // `createNodesBatchWithAllocator`) so the `defer ... free(slot_ids)`
    // below pairs with the same allocator. The plain `createNodesBatch`
    // uses `store.allocator`, which triggers an invalid-free panic on
    // DebugAllocator when the caller frees with a different arena.
    const slot_ids = try store.createNodesBatchWithAllocator(labels, target_graph, create_pattern.chains.len, allocator);
    defer allocator.free(slot_ids);

    // Per-node undo entries. The undo log API is row-oriented — logging
    // N entries here keeps rollback semantics identical to the serial
    // path. The undo log has its own (tier-4+) mutex, so logging N times
    // does not contend with the storage mutex we just released.
    for (slot_ids) |node_id| {
        undo_log.logCreateNode(node_id, current_graph) catch |err| {
            log.err("undo log failed", &.{Attr.string("error", @errorName(err))});
        };
    }

    // Walk each CREATE clause in order to attach properties. The slot has
    // already been allocated above, so this loop is pure property-write
    // work (one adapter-lock acquisition per node via `setNodePropertiesBatch`).
    for (create_pattern.chains, slot_ids) |chain, node_id| {
        const head = chain.head.?;
        const props: []ast.Property = if (head.props) |p| p else &.{};

        if (props.len == 0) continue;

        // Evaluate each property expression in this clause and coerce to
        // a PropertyValue that `setNodePropertiesBatch` can consume.
        for (props, 0..) |prop, pi| {
            // Evaluate into the batch arena, not the request allocator: an
            // evaluated Value can OWN heap (a `vectorf32(...)` literal dupes
            // its payload) and `coercePropertyValue` DEEP-COPIES it into `ba`,
            // so the intermediate is pure garbage the instant the copy is made.
            // `ba` dies at the end of this call and the batch path (chosen by
            // `homogeneousCreateEligible`, which excludes RETURN) lets nothing
            // escape, so this is the right scope — and it is correct for the
            // AST-borrowed / store-aliased results too, which an explicit free
            // would corrupt.
            const value = try eval.evalExpr(ba, prop.value.*, env);
            const prop_value = try property_mutation.coercePropertyValue(ba, value);
            batch_entries[pi] = .{ .key = prop.key, .value = prop_value };
        }

        // Single adapter lock acquisition per node for ALL properties
        // (vs N separate `setNodeProperty` calls in the serial path).
        try store.setNodePropertiesBatch(node_id, batch_entries);
    }

    // Fire advanced-index rebuilds once per (label, key) tuple after all
    // nodes are written. In the common batch-CREATE case no advanced
    // index is registered for these labels, so this is a fast O(1)
    // probe per key.
    if (template_props.len > 0 and labels.len > 0) {
        for (template_props) |prop| {
            property_mutation.rebuildAdvancedIndexesForPropertyPublic(store, labels[0], prop.key);
        }
    }

    // A4b: keep fulltext indexes current for the homogeneous batch-CREATE fast
    // path. This path writes via `setNodePropertiesBatch` (NOT
    // `setNodePropertyFromValue`), so the SET chokepoint hook does NOT fire here
    // — index each just-created node explicitly. Runs on the executor/connection
    // thread (this function is the serial fast path, never a worker), so it
    // respects the fts engine's owning-thread contract. Cheap-exits per node
    // when no FTS index covers `labels`.
    if (template_props.len > 0 and labels.len > 0) {
        for (slot_ids) |node_id| {
            fts_index_ops.maintainFulltextOnWrite(allocator, target_graph, node_id, labels, .create) catch |err| {
                log.warn("fts maintain (batch CREATE) failed", &.{
                    Attr.uint("node_id", node_id),
                    Attr.string("error", @errorName(err)),
                });
            };
        }
    }

    // Auto-create indexes for the label(s) once for the whole batch.
    ensureAutoIndexes(allocator, labels);

    return ExecutionResult{
        .columns = try allocator.alloc([]const u8, 0),
        .rows = try allocator.alloc([]Value, 0),
        .flags = std.ArrayList([]const u8).empty,
    };
}

// CANARY: REQ=REQ-MULTI-GRAPH-015; FEATURE="MultiGraphIsolation"; ASPECT=CreateQuery; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
pub fn executeCreateQuery(
    allocator: std.mem.Allocator,
    q: ast.Query,
    create_pattern: ast.GraphPattern,
    matched_bindings: ?std.StringHashMap(u64),
    param_names: []const []const u8,
    param_values: []const Value,
    current_graph: ?[]const u8,
) !ExecutionResult {
    // Cluster write routing: a `CREATE (...)` issued as a query reaches this
    // function (not executeCreate), including `CREATE (...) RETURN ...`. In
    // cluster mode the write must be ordered through Raft on the leader and
    // never applied to a single node's local store. A follower fails closed
    // (clients retry the leader); the leader replicates a pure single-node
    // create (optionally with a constant RETURN) or fails closed for shapes
    // outside the replicable slice (MATCH/WITH/SET/REMOVE/DELETE, multi-node,
    // relationship hops). See the re-open notes in the bug doc + the distinct-IP
    // regression test tests/cluster/netns_cluster_replication_test.sh.
    // CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-CREATE; FEATURE="DistributedCluster"; ASPECT=QueryProposeNodeCreate; STATUS=TESTED; TEST=tests/cluster/netns_cluster_replication_test.sh; OWNER=distributed; UPDATED=2026-06-06
    switch (try clusterWriteRole()) {
        .standalone => {}, // single-node: unchanged local path below
        .leader => {
            const pure_create = matched_bindings == null and
                q.match.chains.len == 0 and
                q.with_clause == null and
                q.set_clauses.len == 0 and
                q.remove_clauses.len == 0 and
                q.delete_items.len == 0;
            if (!pure_create) return error.ClusterWriteNotReplicable;
            return clusterReplicateNodeCreate(
                allocator,
                create_pattern,
                if (q.ret.items.len > 0) q.ret else null,
                param_names,
                param_values,
                current_graph,
            );
        },
    }

    // GAP-0815: homogeneous batch-CREATE fast path. Declines on any
    // heterogeneity (mixed labels, mixed key sets, named nodes, hops,
    // WITH/SET/REMOVE/RETURN clauses, MATCH-bound vars), falling through
    // to the serial loop below.
    if (homogeneousCreateEligible(q, create_pattern, matched_bindings)) {
        return executeBatchCreateHomogeneous(allocator, create_pattern, param_names, param_values, current_graph);
    }

    const store = graph_store.getGlobalStore(allocator);
    const target_graph = current_graph orelse "default";

    // Track created nodes by variable name for WITH/SET/RETURN clauses (store IDs not pointers)
    var created_nodes = std.StringHashMap(u64).init(allocator);
    // Don't defer deinit - we'll transfer ownership to ExecutionResult for UNION support
    errdefer created_nodes.deinit();

    // If we have matched bindings, copy them to created_nodes
    if (matched_bindings) |bindings| {
        var iter = bindings.iterator();
        while (iter.next()) |entry| {
            try created_nodes.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    // Track created relationships by variable name for RETURN clauses
    var created_relationships = std.StringHashMap(Value).init(allocator);
    defer created_relationships.deinit();

    // Track total created entities for count(*) aggregation
    var total_created_count: i64 = 0;

    // Statement-atomicity pre-pass — see `executeCreate`.
    // CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=CreatePrePass; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25
    try write_precheck.checkPatternWritable(allocator, create_pattern, Env{
        .names = &.{},
        .values = &.{},
        .param_names = param_names,
        .param_values = param_values,
        .allocator = allocator,
    });

    // Create nodes from pattern
    for (create_pattern.chains) |chain| {
        // OWNERSHIP for the GAP-0930 pre-evaluation buffers in this chain.
        //
        // `evalExpr` results are a MIX of ownerships — OWNED heap (a
        // `vectorf32(...)` literal ends in `allocator.dupe`, types/vector.zig:55),
        // AST-BORROWED (string literals), and ALIASES of live store memory
        // (`n.emb`) — so neither "free every value" (double free / UAF of store
        // memory) nor "free nothing" (the pre-fix behaviour: only the []Value
        // SLICE was freed, orphaning every owned payload) is correct. The apply
        // calls below DEEP-COPY into the store and nothing derived from these
        // values escapes the chain iteration, so an arena scoped to one chain
        // reclaims exactly the owned intermediates and touches nothing else.
        var chain_arena = std.heap.ArenaAllocator.init(allocator);
        defer chain_arena.deinit();
        const ca = chain_arena.allocator();

        // Handle single node creation
        if (chain.head) |node_pattern| {
            // GAP-0930: evaluate ALL property-value expressions BEFORE creating
            // the node, so a mid-property eval error (e.g. malformed geometry
            // WKT -> TypeMismatch) aborts the whole CREATE atomically instead of
            // committing an orphan node with the failed property defaulted to
            // NULL. Pre-evaluation is self-contained (no undo-log dependency):
            // if any expression errors, we return before the first store write.
            const evaluated_values: []Value = if (node_pattern.props) |props| blk_eval: {
                const env = Env{
                    .names = &.{},
                    .values = &.{},
                    .param_names = param_names,
                    .param_values = param_values,
                    .allocator = ca,
                };
                const buf = try ca.alloc(Value, props.len);
                for (props, 0..) |prop, i| {
                    buf[i] = try eval.evalExpr(ca, prop.value.*, env);
                }
                break :blk_eval buf;
            } else &.{};

            // Check if this node already exists in matched bindings
            const node_id = if (node_pattern.name) |var_name| blk: {
                if (created_nodes.get(var_name)) |existing_id| {
                    // Node already matched from MATCH clause, don't create new
                    break :blk existing_id;
                } else {
                    // Variable not bound, create new node in target graph
                    const new_id = try store.createNodeWithGraph(node_pattern.labels, target_graph);
                    try created_nodes.put(var_name, new_id);
                    total_created_count += 1;
                    break :blk new_id;
                }
            } else blk: {
                // No variable name, always create new node in target graph
                total_created_count += 1;
                break :blk try store.createNodeWithGraph(node_pattern.labels, target_graph);
            };

            // Apply the pre-evaluated property values.
            if (node_pattern.props) |props| {
                for (props, evaluated_values) |prop, value| {
                    try property_mutation.setNodePropertyFromValue(allocator, store, node_pattern.labels, node_id, prop.key, value);
                }
            }

            // Auto-create indexes for node labels
            ensureAutoIndexes(allocator, node_pattern.labels);
        }

        // Handle relationship creation
        for (chain.hops) |hop| {
            // GAP-0930: evaluate ALL property-value expressions (left endpoint,
            // right endpoint, and the relationship) BEFORE creating any node or
            // edge, so a mid-property eval error aborts the whole relationship
            // CREATE atomically instead of committing partially-populated
            // endpoints with the failed property defaulted to NULL.
            const hop_env = Env{
                .names = &.{},
                .values = &.{},
                .param_names = param_names,
                .param_values = param_values,
                .allocator = ca,
            };
            const left_values: []Value = if (hop.left.props) |props| blk_lv: {
                const buf = try ca.alloc(Value, props.len);
                for (props, 0..) |prop, i| buf[i] = try eval.evalExpr(ca, prop.value.*, hop_env);
                break :blk_lv buf;
            } else &.{};
            const right_values: []Value = if (hop.right.props) |props| blk_rv: {
                const buf = try ca.alloc(Value, props.len);
                for (props, 0..) |prop, i| buf[i] = try eval.evalExpr(ca, prop.value.*, hop_env);
                break :blk_rv buf;
            } else &.{};
            const rel_values: []Value = if (hop.rel.props) |props| blk_rev: {
                const buf = try ca.alloc(Value, props.len);
                for (props, 0..) |prop, i| buf[i] = try eval.evalExpr(ca, prop.value.*, hop_env);
                break :blk_rev buf;
            } else &.{};

            // Check if left node exists in bindings (from MATCH), otherwise create new
            const left_id = blk: {
                if (hop.left.name) |var_name| {
                    if (created_nodes.get(var_name)) |node_id| {
                        break :blk node_id;
                    }
                }
                // Variable not bound - create new node in target graph
                const new_id = try store.createNodeWithGraph(hop.left.labels, target_graph);
                total_created_count += 1;
                ensureAutoIndexes(allocator, hop.left.labels);
                if (hop.left.name) |var_name| {
                    try created_nodes.put(var_name, new_id);
                }
                break :blk new_id;
            };

            // Check if right node exists in bindings (from MATCH), otherwise create new
            const right_id = blk: {
                if (hop.right.name) |var_name| {
                    if (created_nodes.get(var_name)) |node_id| {
                        break :blk node_id;
                    }
                }
                // Variable not bound - create new node in target graph
                const new_id = try store.createNodeWithGraph(hop.right.labels, target_graph);
                total_created_count += 1;
                ensureAutoIndexes(allocator, hop.right.labels);
                if (hop.right.name) |var_name| {
                    try created_nodes.put(var_name, new_id);
                }
                break :blk new_id;
            };

            // Set properties for left node (pre-evaluated above for atomicity)
            if (hop.left.props) |props| {
                for (props, left_values) |prop, value| {
                    try property_mutation.setNodePropertyFromValue(allocator, store, hop.left.labels, left_id, prop.key, value);
                }
            }

            // Set properties for right node (pre-evaluated above for atomicity)
            if (hop.right.props) |props| {
                for (props, right_values) |prop, value| {
                    try property_mutation.setNodePropertyFromValue(allocator, store, hop.right.labels, right_id, prop.key, value);
                }
            }

            // Create the relationship in target graph
            const rel_type = if (hop.rel.types.len > 0) hop.rel.types[0] else "RELATES_TO";
            const edge_id = try store.createEdgeWithGraph(left_id, right_id, rel_type, target_graph);
            total_created_count += 1;
            // Log edge creation for rollback support
            const undo_log3 = txn_undo_log.getGlobalUndoLog(allocator);
            undo_log3.logCreateEdge(edge_id, current_graph) catch |err| {
                log.err("undo log failed", &.{Attr.string("error", @errorName(err))});
            };

            // Auto-create index for edge type
            ensureAutoIndexes(allocator, &.{rel_type});

            // Set relationship properties (pre-evaluated above for atomicity)
            if (hop.rel.props) |props| {
                for (props, rel_values) |prop, value| {
                    try property_mutation.setEdgePropertyFromValue(allocator, store, rel_type, edge_id, prop.key, value);
                }
            }

            // Track created nodes by variable names
            if (hop.left.name) |var_name| {
                try created_nodes.put(var_name, left_id);
            }
            if (hop.right.name) |var_name| {
                try created_nodes.put(var_name, right_id);
            }

            // Track created relationship by variable name
            if (hop.rel.name) |rel_var_name| {
                // Get edge from store to create Edge value
                const edge_ptr = store.getEdgePtrHydrated(edge_id) orelse return error.EdgeNotFound;

                // Create Edge value for the relationship
                const edge_value = Value{ .Edge = edge_ptr };
                try created_relationships.put(rel_var_name, edge_value);
            }
        }
    }

    // Apply WITH clause if present
    var result: ExecutionResult = undefined;
    if (q.with_clause) |with_clause| {
        // Create result from created nodes and apply WITH transformation
        var rows = try allocator.alloc([]Value, 1);
        var row = try allocator.alloc(Value, with_clause.items.len);

        for (with_clause.items, 0..) |item, i| {
            // Evaluate expression based on created nodes
            if (item.expr == .Ident) {
                const var_name = item.expr.Ident.orig;
                if (created_nodes.get(var_name)) |node_id| {
                    const node = (store.nodes.getOrHydratePtr(node_id) catch null) orelse return error.NodeNotFound;
                    row[i] = Value{ .Node = node };
                } else {
                    row[i] = Value{ .Null = {} };
                }
            } else {
                // Create environment with created nodes
                var names = std.ArrayList([]const u8).empty;
                var values = std.ArrayList(Value).empty;

                var iter = created_nodes.iterator();
                while (iter.next()) |entry| {
                    try names.append(allocator, entry.key_ptr.*);
                    const entry_node_id = entry.value_ptr.*;
                    const entry_node = (store.nodes.getOrHydratePtr(entry_node_id) catch null) orelse return error.NodeNotFound;
                    try values.append(allocator, Value{ .Node = entry_node });
                }

                const env = Env{
                    .names = names.items,
                    .values = values.items,
                    .param_names = param_names,
                    .param_values = param_values,
                    .allocator = allocator,
                };
                row[i] = try eval.evalExpr(allocator, item.expr, env);
            }
        }
        rows[0] = row;

        var columns = try allocator.alloc([]const u8, with_clause.items.len);
        for (with_clause.items, 0..) |item, i| {
            const col_name = item.alias orelse switch (item.expr) {
                .Ident => |ident| ident.orig,
                else => "column",
            };
            columns[i] = try allocator.dupe(u8, col_name);
        }

        result = ExecutionResult{
            .columns = columns,
            .rows = rows,
            .flags = std.ArrayList([]const u8).empty,
        };
    } else {
        // No WITH clause - created nodes are ready for SET/RETURN
        result = ExecutionResult{
            .columns = try allocator.alloc([]const u8, 0),
            .rows = try allocator.alloc([]Value, 0),
            .flags = std.ArrayList([]const u8).empty,
        };
    }

    // Statement-atomicity pre-pass: a SET clause list is all-or-nothing, so no
    // assignment is applied unless every assignment can be. Builds the SAME
    // environment the apply loop below builds per clause.
    //
    // SCOPE: clause-list atomicity only. It cannot run before the CREATE above,
    // because the environment these values are evaluated in IS the set of nodes
    // the CREATE just made. So `CREATE (n:L {..}) ... SET n.x = <unstorable>`
    // still leaves the created node behind; only a statement-scoped undo log
    // closes that, and the pattern props themselves are already covered by the
    // pre-pass at the top of this function.
    // CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=SetPrePass; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25
    if (q.set_clauses.len > 0) {
        var pc_names = std.ArrayList([]const u8).empty;
        defer pc_names.deinit(allocator);
        var pc_values = std.ArrayList(Value).empty;
        defer pc_values.deinit(allocator);

        if (q.with_clause != null) {
            if (result.rows.len > 0) {
                for (result.columns, 0..) |col_name, idx| {
                    try pc_names.append(allocator, col_name);
                    try pc_values.append(allocator, result.rows[0][idx]);
                }
            }
        } else {
            var pc_iter = created_nodes.iterator();
            while (pc_iter.next()) |entry| {
                if ((store.nodes.getOrHydratePtr(entry.value_ptr.*) catch null)) |n| {
                    try pc_names.append(allocator, entry.key_ptr.*);
                    try pc_values.append(allocator, Value{ .Node = n });
                }
            }
        }

        try write_precheck.checkSetClausesWritable(allocator, q.set_clauses, Env{
            .names = pc_names.items,
            .values = pc_values.items,
            .param_names = param_names,
            .param_values = param_values,
            .allocator = allocator,
        }, null, &.{});
    }

    // Apply SET clauses if present
    // If WITH clause exists, SET should work on the WITH result environment
    for (q.set_clauses) |set_clause| {
        switch (set_clause) {
            .Property => |prop| {
                if (created_nodes.get(prop.target.object)) |node_id| {
                    // Create environment - if WITH is present, use WITH result; otherwise use created_nodes
                    var names = std.ArrayList([]const u8).empty;
                    var values = std.ArrayList(Value).empty;

                    if (q.with_clause != null) {
                        // Use WITH result columns and first row as environment
                        for (result.columns, 0..) |col_name, idx| {
                            try names.append(allocator, col_name);
                            try values.append(allocator, result.rows[0][idx]);
                        }
                    } else {
                        // Use created nodes as environment
                        var iter = created_nodes.iterator();
                        while (iter.next()) |entry| {
                            try names.append(allocator, entry.key_ptr.*);
                            const entry_node_id = entry.value_ptr.*;
                            const entry_node = (store.nodes.getOrHydratePtr(entry_node_id) catch null) orelse return error.NodeNotFound;
                            try values.append(allocator, Value{ .Node = entry_node });
                        }
                    }

                    const env = Env{
                        .names = names.items,
                        .values = values.items,
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                    };

                    const value = try eval.evalExpr(allocator, prop.value, env);
                    const node = (store.nodes.getOrHydratePtr(node_id) catch null) orelse return error.NodeNotFound;
                    try property_mutation.setNodePropertyFromValue(allocator, store, node.labels, node_id, prop.target.property, value);
                }
            },
            .Labels => |label_set| {
                if (created_nodes.get(label_set.node)) |node_id| {
                    for (label_set.labels) |label| {
                        try store.addNodeLabel(node_id, label);
                    }
                }
            },
            .AllProperties => |all_props| {
                if (created_nodes.get(all_props.node)) |node_id| {
                    // Create environment - if WITH is present, use WITH result; otherwise use created_nodes
                    var names = std.ArrayList([]const u8).empty;
                    var values = std.ArrayList(Value).empty;

                    if (q.with_clause != null) {
                        // Use WITH result columns and first row as environment
                        for (result.columns, 0..) |col_name, idx| {
                            try names.append(allocator, col_name);
                            try values.append(allocator, result.rows[0][idx]);
                        }
                    } else {
                        // Use created nodes as environment
                        var iter = created_nodes.iterator();
                        while (iter.next()) |entry| {
                            try names.append(allocator, entry.key_ptr.*);
                            const entry_node_id = entry.value_ptr.*;
                            const entry_node = (store.nodes.getOrHydratePtr(entry_node_id) catch null) orelse return error.NodeNotFound;
                            try values.append(allocator, Value{ .Node = entry_node });
                        }
                    }

                    const env = Env{
                        .names = names.items,
                        .values = values.items,
                        .param_names = param_names,
                        .param_values = param_values,
                        .allocator = allocator,
                    };

                    // Evaluate the properties expression (should be a map literal)
                    const props_value = try eval.evalExpr(allocator, all_props.properties, env);

                    // Clear all existing properties by getting node and manually clearing
                    if ((store.nodes.getOrHydratePtr(node_id) catch null)) |node| {
                        try property_mutation.replaceNodeProperties(allocator, store, node, props_value);
                    }
                }
            },
        }
    }

    // Apply REMOVE clauses if present
    for (q.remove_clauses) |remove_clause| {
        switch (remove_clause) {
            .Property => |prop| {
                if (created_nodes.get(prop.object)) |node_id| {
                    if ((store.nodes.getOrHydratePtr(node_id) catch null)) |node_ptr| {
                        property_mutation.removeNodeProperty(store, node_ptr, prop.property);
                    }
                }
            },
            .Labels => |label_removal| {
                if (created_nodes.get(label_removal.node)) |node_id| {
                    for (label_removal.labels) |label| {
                        try store.removeNodeLabel(node_id, label);
                    }
                }
            },
        }
    }

    // CANARY: REQ=REQ-GQL-083; FEATURE="CreateWithClause"; ASPECT=VariablePropagation; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
    // Execute RETURN clause
    // If WITH clause was present, use the WITH result columns/rows as the environment for RETURN
    if (q.with_clause != null) {
        // WITH clause creates a result that filters/transforms the created nodes
        // RETURN should evaluate in the context of the WITH result
        var return_columns = try allocator.alloc([]const u8, q.ret.items.len);
        for (q.ret.items, 0..) |item, i| {
            const col_name = item.alias orelse switch (item.expr) {
                .Ident => |ident| ident.orig,
                .PropertyAccess => |prop| prop.property,
                .Member => |mem| mem.field,
                else => "column",
            };
            return_columns[i] = try allocator.dupe(u8, col_name);
        }

        // Evaluate RETURN items using the WITH result as environment
        var return_rows = try allocator.alloc([]Value, result.rows.len);
        for (result.rows, 0..) |with_row, row_idx| {
            var return_row = try allocator.alloc(Value, q.ret.items.len);

            // Create environment from WITH result columns and this row's values
            const env = Env{
                .names = result.columns,
                .values = with_row,
                .param_names = param_names,
                .param_values = param_values,
                .allocator = allocator,
            };

            for (q.ret.items, 0..) |item, col_idx| {
                return_row[col_idx] = try eval.evalExpr(allocator, item.expr, env);
            }
            return_rows[row_idx] = return_row;
        }

        // Clean up WITH result arrays (note: column names are from parser arena, don't free them)
        allocator.free(result.columns);
        for (result.rows) |row| {
            allocator.free(row);
        }
        allocator.free(result.rows);

        // Clone created_nodes for variable_bindings
        const bindings_ptr = try allocator.create(std.StringHashMap(u64));
        bindings_ptr.* = try created_nodes.clone();
        errdefer {
            bindings_ptr.deinit();
            allocator.destroy(bindings_ptr);
        }

        // Clean up local created_nodes
        created_nodes.deinit();

        return ExecutionResult{
            .columns = return_columns,
            .rows = return_rows,
            .flags = result.flags,
            .variable_bindings = bindings_ptr,
        };
    } else {
        // Check if RETURN uses count(*) aggregation — return total created entity count
        // Only match count(*), not count(variable) which should be evaluated normally
        if (q.ret.items.len == 1 and q.ret.items[0].expr == .Call) {
            const call = q.ret.items[0].expr.Call;
            const is_count_star = call.callee.* == .Ident and
                (std.mem.eql(u8, call.callee.Ident.orig, "count") or
                    std.mem.eql(u8, call.callee.Ident.orig, "COUNT")) and
                call.args.len == 1 and call.args[0].* == .Ident and
                std.mem.eql(u8, call.args[0].Ident.orig, "*");
            if (is_count_star) {
                var columns = try allocator.alloc([]const u8, 1);
                columns[0] = try allocator.dupe(u8, q.ret.items[0].alias orelse "count");
                var rows = try allocator.alloc([]Value, 1);
                var ret_row = try allocator.alloc(Value, 1);
                ret_row[0] = Value{ .Int = total_created_count };
                rows[0] = ret_row;

                const bindings_ptr = try allocator.create(std.StringHashMap(u64));
                bindings_ptr.* = try created_nodes.clone();
                created_nodes.deinit();

                return ExecutionResult{
                    .columns = columns,
                    .rows = rows,
                    .flags = std.ArrayList([]const u8).empty,
                    .variable_bindings = bindings_ptr,
                };
            }
        }

        // No WITH clause - use created nodes and relationships directly for RETURN
        var ret_result = try executeReturnClauseWithNodes(allocator, q.ret, created_nodes, created_relationships);

        // Clone created_nodes for variable_bindings before they get freed
        const bindings_ptr = try allocator.create(std.StringHashMap(u64));
        bindings_ptr.* = try created_nodes.clone();
        ret_result.variable_bindings = bindings_ptr;

        // Clean up local created_nodes
        created_nodes.deinit();

        return ret_result;
    }
}

pub fn executeReturnClauseWithNodes(
    allocator: std.mem.Allocator,
    ret: ast.ReturnClause,
    nodes: std.StringHashMap(u64),
    relationships: std.StringHashMap(Value),
) !ExecutionResult {
    const store = graph_store.getGlobalStore(allocator);
    const items = ret.items;
    var columns = try allocator.alloc([]const u8, items.len);
    var rows = try allocator.alloc([]Value, 1);
    var row = try allocator.alloc(Value, items.len);

    // Create environment with the nodes and relationships
    var names = std.ArrayList([]const u8).empty;
    var values = std.ArrayList(Value).empty;

    // Add nodes to environment
    var node_iter = nodes.iterator();
    while (node_iter.next()) |entry| {
        try names.append(allocator, entry.key_ptr.*);
        const node_id = entry.value_ptr.*;
        const node = (store.nodes.getOrHydratePtr(node_id) catch null) orelse return error.NodeNotFound;
        try values.append(allocator, Value{ .Node = node });
    }

    // Add relationships to environment
    var rel_iter = relationships.iterator();
    while (rel_iter.next()) |entry| {
        try names.append(allocator, entry.key_ptr.*);
        try values.append(allocator, entry.value_ptr.*);
    }

    const env = Env{
        .allocator = allocator,
        .names = names.items,
        .values = values.items,
    };

    for (items, 0..) |item, i| {
        const col_name = item.alias orelse switch (item.expr) {
            .Ident => |ident| ident.orig,
            .PropertyAccess => |prop| prop.property,
            .Member => |mem| mem.field,
            else => "column",
        };
        columns[i] = try allocator.dupe(u8, col_name);
        row[i] = try eval.evalExpr(allocator, item.expr, env);
    }

    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// ── Cluster write routing ────────────────────────────────────────────────────
// Re-open fix for docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md.
//
// In cluster mode EVERY graph-data write must be ordered through Raft on the
// leader and applied uniformly on all nodes. Two silent-divergence holes were
// reproduced on a distinct-IP (non-loopback) 3-node cluster
// (tests/cluster/netns_cluster_replication_test.sh):
//
//   1. A write sent to a FOLLOWER fell through to the follower's local store —
//      the write existed on exactly one node and the rest of the cluster never
//      saw it (the re-open's "exit 0 fast, committed locally, never replicated").
//   2. A `CREATE ... RETURN ...` (and any non-trivial create) on the LEADER
//      skipped the Raft path entirely and was written leader-local only, so the
//      followers stayed empty (the re-open's "count=1 on the leader only").
//
// The gate below makes those fail closed instead of diverging: a follower
// rejects the write (error.ClusterNotLeader — clients retry against the leader,
// standard Raft semantics), and the leader either replicates the write through
// Raft or rejects it (error.ClusterWriteNotReplicable) when the create shape is
// outside the replicable slice. NOTHING is ever applied to a single node's
// local store in cluster mode.
const ClusterWriteRole = enum { standalone, leader };

/// Resolve how a graph-data write must be handled. `.standalone` => no cluster
/// coordinator, take the unchanged single-node local path. `.leader` => this
/// node is the leader, the write must be replicated via Raft.
/// `error.ClusterNotLeader` => follower/candidate; the caller must NOT apply
/// the write locally (that diverges the cluster).
fn clusterWriteRole() error{ClusterNotLeader}!ClusterWriteRole {
    const coord = cluster_mod.getGlobalClusterCoordinator() orelse return .standalone;
    if (coord.role() != .leader) return error.ClusterNotLeader;
    return .leader;
}

/// Map an evaluated GQL Value to a scalar PropertyValue the single-node-create
/// replication codec supports, or null when the type is outside that slice (so
/// the caller fails closed rather than writing leader-local).
fn clusterPropValue(v: Value) ?graph_store.PropertyValue {
    return switch (v) {
        .Null => .Null,
        .Int => |i| .{ .Int = i },
        .BigInt => |i| .{ .Int = i },
        .SmallInt => |i| .{ .Int = @as(i64, i) },
        .Bool => |b| .{ .Bool = b },
        .Double => |f| .{ .Float = f },
        .Real => |f| .{ .Float = @as(f64, f) },
        .Str => |s| .{ .String = s },
        .Text => |s| .{ .String = s },
        else => null,
    };
}

/// Resolve the idempotency key for a cluster-replicated write (RC-3, 2026-06-12).
/// Prefers a client-supplied key from the active ExecutionContext (ExecuteRequest
/// field 5) — that is what lets an EXTERNAL client retry dedup. When the client
/// supplied none, the leader generates a random per-request key into `buf` and
/// returns that slice: this keys the replicated payload (so the apply dedup path
/// is exercised and a future client adoption needs no further server change) but
/// does NOT dedup an external retry (each retry re-enters here and mints a fresh
/// key — the documented residual). A leader-generated key is 32 lowercase hex
/// chars; `buf` must be at least 32 bytes. The returned slice borrows the client
/// key (valid for the request) or `buf` (valid for the caller's frame).
fn effectiveIdempotencyKey(buf: *[32]u8) []const u8 {
    if (execution.getActiveContext()) |ctx| {
        if (ctx.idempotency_key) |k| {
            if (k.len > 0) return k;
        }
    }
    var raw: [16]u8 = undefined;
    // fips-exempt: non-security idempotency key (coordination token, not secret material)
    // Zig 0.16 compat: std.crypto.random was removed; use the getrandom syscall.
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(&raw, raw.len, 0);
    } else {
        std.c.arc4random_buf(&raw, raw.len);
    }
    const hex = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        buf[i * 2] = hex[b >> 4];
        buf[i * 2 + 1] = hex[b & 0x0f];
    }
    return buf[0..32];
}

/// Replicate an eligible single-node `CREATE (:Label {props})` through Raft and
/// return its result. Called ONLY when this node is the cluster leader. The
/// create is proposed to the Raft log (never written locally) and applied
/// deterministically on every node. An optional constant RETURN clause is
/// evaluated and returned to the client.
///
/// Returns `error.ClusterWriteNotReplicable` for any create shape this slice
/// does not replicate (relationship hops, multiple nodes, a non-scalar/param
/// property, or a RETURN clause that references the created node), so the write
/// fails closed instead of being applied leader-local.
fn clusterReplicateNodeCreate(
    allocator: std.mem.Allocator,
    pattern: ast.GraphPattern,
    return_clause: ?ast.ReturnClause,
    param_names: []const []const u8,
    param_values: []const Value,
    current_graph: ?[]const u8,
) !ExecutionResult {
    const coord = cluster_mod.getGlobalClusterCoordinator() orelse return error.ClusterWriteNotReplicable;

    // Only a single chain is replicable in this slice.
    if (pattern.chains.len != 1) return error.ClusterWriteNotReplicable;
    const chain = pattern.chains[0];

    // Slice A: a single-chain CREATE WITH relationship hops
    // (`CREATE (a)-[:R]->(b)...`) replicates as a deterministic GNC2 multi-create.
    // Delegate to the edge path, which fails closed for any shape it cannot
    // serialize (non-scalar props, etc.). A constant/param RETURN is honored
    // there; a RETURN that references a created var fails closed.
    if (chain.hops.len != 0) {
        return clusterReplicateEdgeCreate(
            allocator,
            coord,
            chain,
            return_clause,
            param_names,
            param_values,
            current_graph,
        );
    }

    const node = chain.head orelse return error.ClusterWriteNotReplicable;

    const env = Env{
        .names = &.{},
        .values = &.{},
        .param_names = param_names,
        .param_values = param_values,
        .allocator = allocator,
    };

    // Evaluate the RETURN projection BEFORE proposing so a non-replicable RETURN
    // (one that references the created node variable, which is unbound here)
    // fails closed without writing anything. Constant/param RETURNs evaluate
    // fine; the result is held and returned after the write commits.
    var ret_result: ?ExecutionResult = null;
    errdefer if (ret_result) |*r| r.deinit(allocator);
    if (return_clause) |rc| {
        if (rc.items.len > 0) {
            ret_result = executeReturnClauseWithEnv(allocator, rc, env) catch
                return error.ClusterWriteNotReplicable;
        }
    }

    // Evaluate properties (literals AND parameters) into replicable scalars.
    var props = std.ArrayList(cluster_replication.Prop).empty;
    defer props.deinit(allocator);
    if (node.props) |plist| {
        for (plist) |p| {
            const val = eval.evalExpr(allocator, p.value.*, env) catch
                return error.ClusterWriteNotReplicable;
            const pv = clusterPropValue(val) orelse return error.ClusterWriteNotReplicable;
            try props.append(allocator, .{ .key = p.key, .value = pv });
        }
    }

    const graph = current_graph orelse "default";
    // RC-3 (2026-06-12): carry an idempotency key so a retried CREATE dedups at
    // apply time (no duplicate row). Client key from the request, else leader-generated.
    var idem_buf: [32]u8 = undefined;
    const idem_key = effectiveIdempotencyKey(&idem_buf);
    const payload = cluster_replication.serializeNodeCreateKeyed(allocator, graph, node.labels, props.items, idem_key) catch |err| switch (err) {
        cluster_replication.CodecError.UnsupportedPropertyType => return error.ClusterWriteNotReplicable,
        else => return err,
    };
    defer allocator.free(payload); // proposeCommand serializes a copy; safe to free after.

    const cmd = raft_consensus.Command{ .graph_mutation = .{
        .graph = graph,
        .mutation_type = .create,
        .data = payload,
        .txn_id = null,
    } };
    const idx = coord.proposeWrite(cmd) catch |err| switch (err) {
        // Lost leadership between the role check and the propose — fail closed.
        error.NotLeader => return error.ClusterNotLeader,
        else => return err,
    };
    // Commit-aware wait (RC-1, 2026-06-12): block until the entry is CONFIRMED
    // COMMITTED (durably replicated to a quorum) — at which point Raft guarantees
    // it WILL apply, so this returns success. error.Timeout is surfaced ONLY when
    // commit itself cannot be confirmed in budget (a genuine unknown), NEVER for a
    // committed-but-apply-lagged entry. Reporting apply lag as Timeout was the
    // wrong signal that drove the client to retry an already-committed write,
    // minting the duplicate row.
    try coord.waitForCommittedThenApplied(idx, 5000);

    if (ret_result) |r| {
        ret_result = null; // ownership transferred to the caller
        return r;
    }
    return ExecutionResult{
        .columns = try allocator.alloc([]const u8, 0),
        .rows = try allocator.alloc([]Value, 0),
        .flags = std.ArrayList([]const u8).empty,
    };
}

/// Build the ordered, deduplicated node-spec list + edge-spec list for a single
/// CREATE chain with relationship hops, evaluating every node/edge property into
/// a replicable scalar. Named nodes that recur across hops collapse to one
/// positional spec; anonymous nodes always get a fresh position. Returns
/// `error.ClusterWriteNotReplicable` for any shape outside the slice (a
/// non-scalar property, a variable-length hop). Endpoints are encoded as
/// `.position` references into the node list (all nodes here are NEW).
///
/// `node_specs`/`edge_specs`/their backing label & prop arrays are arena-style
/// allocations off `allocator` (the per-statement allocator); the serializer
/// deep-copies into the payload, so they can be freed by the caller's arena.
fn buildEdgeCreateSpecs(
    allocator: std.mem.Allocator,
    chain: ast.Chain,
    env: Env,
    node_specs: *std.ArrayList(cluster_replication.NodeSpec),
    edge_specs: *std.ArrayList(cluster_replication.EdgeSpec),
) !void {
    // Map a node variable name -> its assigned position in node_specs.
    var name_to_pos = std.StringHashMap(u32).init(allocator);
    defer name_to_pos.deinit();

    const Helper = struct {
        fn evalProps(
            a: std.mem.Allocator,
            e: Env,
            props_opt: ?[]ast.Property,
        ) ![]cluster_replication.Prop {
            const plist = props_opt orelse return &.{};
            var out = try a.alloc(cluster_replication.Prop, plist.len);
            for (plist, 0..) |p, i| {
                const val = eval.evalExpr(a, p.value.*, e) catch return error.ClusterWriteNotReplicable;
                const pv = clusterPropValue(val) orelse return error.ClusterWriteNotReplicable;
                out[i] = .{ .key = p.key, .value = pv };
            }
            return out;
        }
    };

    // Register (or look up) a node pattern, returning its position. A named node
    // already seen reuses its position (and does NOT re-add props — the first
    // occurrence in the chain owns them, matching local-create semantics where
    // the bound var is reused).
    const Register = struct {
        fn run(
            a: std.mem.Allocator,
            e: Env,
            np: ast.NodePattern,
            specs: *std.ArrayList(cluster_replication.NodeSpec),
            map: *std.StringHashMap(u32),
        ) !u32 {
            if (np.name) |nm| {
                if (map.get(nm)) |pos| return pos;
            }
            const pos: u32 = @intCast(specs.items.len);
            const labels = try a.dupe([]const u8, np.labels);
            const props = try Helper.evalProps(a, e, np.props);
            try specs.append(a, .{ .labels = labels, .props = props });
            if (np.name) |nm| try map.put(nm, pos);
            return pos;
        }
    };

    for (chain.hops) |hop| {
        // Variable-length / quantified hops are not replicable in this slice.
        if (hop.rel.min_len != null or hop.rel.max_len != null)
            return error.ClusterWriteNotReplicable;

        const left_pos = try Register.run(allocator, env, hop.left, node_specs, &name_to_pos);
        const right_pos = try Register.run(allocator, env, hop.right, node_specs, &name_to_pos);

        if (node_specs.items.len > cluster_replication.MAX_MULTI_NODES)
            return error.ClusterWriteNotReplicable;

        // Direction: store edges are directed left->right. `.left` reverses the
        // endpoints; `.undirected` is stored left->right (matching treats it as
        // a directionless adjacency).
        const from_pos = if (hop.rel.dir == .left) right_pos else left_pos;
        const to_pos = if (hop.rel.dir == .left) left_pos else right_pos;

        const rel_type = if (hop.rel.types.len > 0) hop.rel.types[0] else "RELATES_TO";
        const eprops = try Helper.evalProps(allocator, env, hop.rel.props);

        try edge_specs.append(allocator, .{
            .from = .{ .position = from_pos },
            .to = .{ .position = to_pos },
            .edge_type = rel_type,
            .props = eprops,
        });
        if (edge_specs.items.len > cluster_replication.MAX_MULTI_EDGES)
            return error.ClusterWriteNotReplicable;
    }
}

/// Replicate an eligible single-chain `CREATE (a)-[:R]->(b)...` (relationship
/// hops) through Raft as a deterministic GNC2 multi-create, and return its
/// result. Called ONLY when this node is the cluster leader. The create is
/// proposed to the Raft log (never written locally) and applied deterministically
/// on every node (node/edge ids derived from the committed log index).
///
/// Returns `error.ClusterWriteNotReplicable` for any shape this slice does not
/// replicate (a non-scalar/param property, a variable-length hop, more than
/// MAX_MULTI_* entities, or a RETURN clause that references a created variable),
/// so the write fails closed instead of being applied leader-local.
// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-EDGE-CREATE; FEATURE="DistributedCluster"; ASPECT=LeaderProposeEdgeCreate; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-09
fn clusterReplicateEdgeCreate(
    allocator: std.mem.Allocator,
    coord: *cluster_mod.ClusterCoordinator,
    chain: ast.Chain,
    return_clause: ?ast.ReturnClause,
    param_names: []const []const u8,
    param_values: []const Value,
    current_graph: ?[]const u8,
) !ExecutionResult {
    const env = Env{
        .names = &.{},
        .values = &.{},
        .param_names = param_names,
        .param_values = param_values,
        .allocator = allocator,
    };

    // Evaluate the RETURN projection BEFORE proposing so a non-replicable RETURN
    // (one that references a created node/edge variable, which is unbound here)
    // fails closed without writing anything. Constant/param RETURNs evaluate fine.
    var ret_result: ?ExecutionResult = null;
    errdefer if (ret_result) |*r| r.deinit(allocator);
    if (return_clause) |rc| {
        if (rc.items.len > 0) {
            ret_result = executeReturnClauseWithEnv(allocator, rc, env) catch
                return error.ClusterWriteNotReplicable;
        }
    }

    var node_specs = std.ArrayList(cluster_replication.NodeSpec).empty;
    defer node_specs.deinit(allocator);
    var edge_specs = std.ArrayList(cluster_replication.EdgeSpec).empty;
    defer edge_specs.deinit(allocator);

    try buildEdgeCreateSpecs(allocator, chain, env, &node_specs, &edge_specs);

    const graph = current_graph orelse "default";
    // RC-3 (2026-06-12): carry an idempotency key so a retried edge-CREATE dedups
    // at apply time (no duplicate subgraph). Client key from the request, else leader-generated.
    var idem_buf: [32]u8 = undefined;
    const idem_key = effectiveIdempotencyKey(&idem_buf);
    const payload = cluster_replication.serializeMultiCreateKeyed(
        allocator,
        graph,
        node_specs.items,
        edge_specs.items,
        idem_key,
    ) catch |err| switch (err) {
        cluster_replication.CodecError.UnsupportedPropertyType,
        cluster_replication.CodecError.CorruptPayload,
        => return error.ClusterWriteNotReplicable,
        else => return err,
    };
    defer allocator.free(payload); // proposeCommand serializes a copy; safe to free after.

    const cmd = raft_consensus.Command{ .graph_mutation = .{
        .graph = graph,
        .mutation_type = .create,
        .data = payload,
        .txn_id = null,
    } };
    const idx = coord.proposeWrite(cmd) catch |err| switch (err) {
        error.NotLeader => return error.ClusterNotLeader,
        else => return err,
    };
    // Commit-aware wait (RC-1, 2026-06-12): success on confirmed COMMIT (apply is
    // then guaranteed); error.Timeout only when commit cannot be confirmed in
    // budget — never for a committed-but-apply-lagged entry.
    try coord.waitForCommittedThenApplied(idx, 5000);

    if (ret_result) |r| {
        ret_result = null; // ownership transferred to the caller
        return r;
    }
    return ExecutionResult{
        .columns = try allocator.alloc([]const u8, 0),
        .rows = try allocator.alloc([]Value, 0),
        .flags = std.ArrayList([]const u8).empty,
    };
}

pub fn executeCreate(allocator: std.mem.Allocator, c: ast.CreateStatement, current_graph: ?[]const u8, context: ExecutionContext) !ExecutionResult {
    // Cluster write routing: in cluster mode the write is ordered through Raft
    // on the leader and never written to a single node's local store. A
    // follower fails closed (error.ClusterNotLeader — clients retry the
    // leader); the leader replicates an eligible single-node create (optionally
    // with a constant RETURN) or fails closed for non-replicable shapes. See
    // tests/cluster/netns_cluster_replication_test.sh.
    // CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-CREATE; FEATURE="DistributedCluster"; ASPECT=ExecutorProposeNodeCreate; STATUS=TESTED; TEST=tests/cluster/netns_cluster_replication_test.sh; OWNER=distributed; UPDATED=2026-06-06
    switch (try clusterWriteRole()) {
        .standalone => {}, // single-node: unchanged local path below
        .leader => return clusterReplicateNodeCreate(
            allocator,
            c.pattern,
            c.return_clause,
            context.query_param_names,
            context.query_param_values,
            current_graph,
        ),
    }

    // GAP-0815: homogeneous batch-CREATE fast path for a top-level
    // `CREATE (:L {...}), (:L {...}), ...` statement (no RETURN). See
    // `homogeneousPatternEligible` for the detection rules. Declines on
    // any heterogeneity and falls through to the serial loop below.
    if (homogeneousCreateStatementEligible(c)) {
        return executeBatchCreateHomogeneous(
            allocator,
            c.pattern,
            context.query_param_names,
            context.query_param_values,
            current_graph,
        );
    }

    const store = graph_store.getGlobalStore(allocator);
    const target_graph = current_graph orelse "default";

    // R8 (2026-04-22): open a per-statement engine transaction so every
    // adapter sub-op (createNode + N × setNodeProperty + createEdge …)
    // for this CREATE joins a single engine txn → ONE WAL fsync for the
    // whole statement instead of one per sub-op.
    //
    // R9 (2026-04-22): when a Geode-level session txn is active
    // (BEGIN TX … COMMIT batch from the client), the adapter already
    // has a session-scoped engine txn installed on this thread for the
    // current graph — skip opening our own per-statement txn and let
    // the session txn batch this statement's sub-ops with every OTHER
    // statement in the batch.  The whole Geode batch will commit with a
    // single fsync in the COMMIT handler.
    //
    // R9 (2026-04-22, fixed): the session engine txn is opened LAZILY
    // here on the first mutation of a Geode txn, pinned to the actual
    // `target_graph` the statement targets — earlier versions opened it
    // eagerly in the QUIC BEGIN handler on `state.current_graph` which
    // is null under DSN graph-binding and caused orphan "graph=default"
    // txns to get rolled back on stream close.
    //
    // Falls back silently if no per-graph adapter is registered
    // (legacy test paths).
    const gsa = @import("../storage/graph_storage_adapter.zig");
    var stmt_txn: gsa.StatementTxn = undefined;
    var stmt_txn_open = false;
    var session_txn_covers_us = false;

    if (graph_store.getGlobalAdapter()) |ad| {
        if (gsa.sessionEngineTxnGraph()) |g| {
            session_txn_covers_us = std.mem.eql(u8, g, target_graph);
        } else if (context.transaction_state == .Active) {
            // R9 lazy open: Geode txn is active but no session engine
            // txn is open yet — pin it to `target_graph`.  SONNY-2823:
            // it is opened into the slot of the session whose request
            // runs on this thread (`ServerState.session_engine_txn`), not
            // a thread-local one, and committed when this program ends
            // (`execution.leaveEntryPoint`), not at the Geode txn's
            // COMMIT.  Failure falls through to per-statement R8.
            if (ad.beginSessionTxnLazy(target_graph)) |_| {
                session_txn_covers_us = true;
            } else |err| switch (err) {
                // SONNY-2823: no session slot on the thread (an embedded
                // caller, not a transport request): per-statement txns.
                error.GraphNotFound, error.NestedSessionTxn, error.NestedStatementTxn, error.NoSessionEngineTxnSlot => {},
                else => return err,
            }
        }
        if (!session_txn_covers_us) {
            if (ad.beginStatementTxn(target_graph, &stmt_txn)) |_| {
                stmt_txn_open = true;
            } else |err| switch (err) {
                // GraphNotFound: the graph doesn't exist yet — the first
                // createNode on this path will lazily create it and handle
                // its own txn.  Nested: defensive (shouldn't happen given
                // the per-graph write lock), fall through to legacy path.
                error.GraphNotFound, error.NestedStatementTxn => {},
                else => return err,
            }
        }
    }
    errdefer if (stmt_txn_open) stmt_txn.abort();

    // Statement-atomicity pre-pass: refuse an unstorable property entry
    // ANYWHERE in the pattern before the first node/edge is created. GAP-0930
    // already pre-evaluates each chain's property expressions for the same
    // reason (a mid-property eval error must not commit an orphan); this
    // extends that guarantee across the WHOLE statement and to values that
    // evaluate fine but the storage layer will refuse.
    // CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=CreatePrePass; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25
    try write_precheck.checkPatternWritable(allocator, c.pattern, envFromContext(allocator, context));

    // Track created nodes by variable name
    var created_nodes = std.StringHashMap(u64).init(allocator);
    defer created_nodes.deinit();

    // Track created relationships by variable name for RETURN clauses
    var created_relationships = std.StringHashMap(Value).init(allocator);
    defer created_relationships.deinit();

    // Create nodes from pattern
    for (c.pattern.chains) |chain| {
        // OWNERSHIP for the GAP-0930 pre-evaluation buffers in this chain.
        //
        // `evalExpr` results are a MIX of ownerships — OWNED heap (a
        // `vectorf32(...)` literal ends in `allocator.dupe`, types/vector.zig:55),
        // AST-BORROWED (string literals), and ALIASES of live store memory
        // (`n.emb`) — so neither "free every value" (double free / UAF of store
        // memory) nor "free nothing" (the pre-fix behaviour: only the []Value
        // SLICE was freed, orphaning every owned payload) is correct. The apply
        // calls below DEEP-COPY into the store and nothing derived from these
        // values escapes the chain iteration, so an arena scoped to one chain
        // reclaims exactly the owned intermediates and touches nothing else.
        var chain_arena = std.heap.ArenaAllocator.init(allocator);
        defer chain_arena.deinit();
        const ca = chain_arena.allocator();

        // Handle single node creation
        if (chain.head) |node_pattern| {
            // GAP-0930: evaluate ALL property-value expressions BEFORE creating
            // the node, so a mid-property eval error (e.g. malformed geometry
            // WKT -> TypeMismatch) aborts the whole CREATE atomically instead of
            // committing an orphan node with the failed property defaulted to
            // NULL. Pre-evaluation is self-contained and does NOT rely on the
            // stmt_txn / undo-log rollback: when this statement lazily creates
            // its target graph, beginStatementTxn returns GraphNotFound and
            // stmt_txn_open stays false, so no engine txn would roll the node
            // back on error.
            const evaluated_values: []Value = if (node_pattern.props) |props| blk_ev: {
                const env = envFromContext(ca, context);
                const buf = try ca.alloc(Value, props.len);
                for (props, 0..) |prop, i| buf[i] = try eval.evalExpr(ca, prop.value.*, env);
                break :blk_ev buf;
            } else &.{};

            const node_id = try store.createNodeWithGraph(node_pattern.labels, target_graph);

            // CANARY: REQ=REQ-TXN-UNDO-018; FEATURE="TransactionUndoLog"; ASPECT=ExecuteCreateUndoLog; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
            // Log node creation for rollback support
            const undo_log = txn_undo_log.getGlobalUndoLog(allocator);
            undo_log.logCreateNode(node_id, current_graph) catch |err| {
                log.err("undo log failed", &.{Attr.string("error", @errorName(err))});
            };

            // Apply the pre-evaluated property values.
            if (node_pattern.props) |props| {
                for (props, evaluated_values) |prop, value| {
                    try property_mutation.setNodePropertyFromValue(allocator, store, node_pattern.labels, node_id, prop.key, value);
                }
            }

            // Store node ID if it has a variable name
            if (node_pattern.name) |name| {
                try created_nodes.put(name, node_id);
            }

            // Auto-create indexes for node labels
            ensureAutoIndexes(allocator, node_pattern.labels);
        }

        // Handle chains with relationships
        for (chain.hops) |hop| {
            // GAP-0930: evaluate ALL property-value expressions (left endpoint,
            // right endpoint, and the relationship) BEFORE creating any node or
            // edge, so a mid-property eval error aborts the whole relationship
            // CREATE atomically rather than committing partially-populated
            // endpoints. Self-contained (no reliance on stmt_txn/undo-log).
            const hop_env = envFromContext(ca, context);
            const left_values: []Value = if (hop.left.props) |props| blk_lv: {
                const buf = try ca.alloc(Value, props.len);
                for (props, 0..) |prop, i| buf[i] = try eval.evalExpr(ca, prop.value.*, hop_env);
                break :blk_lv buf;
            } else &.{};
            const right_values: []Value = if (hop.right.props) |props| blk_rv: {
                const buf = try ca.alloc(Value, props.len);
                for (props, 0..) |prop, i| buf[i] = try eval.evalExpr(ca, prop.value.*, hop_env);
                break :blk_rv buf;
            } else &.{};
            const rel_values: []Value = if (hop.rel.props) |props| blk_rev: {
                const buf = try ca.alloc(Value, props.len);
                for (props, 0..) |prop, i| buf[i] = try eval.evalExpr(ca, prop.value.*, hop_env);
                break :blk_rev buf;
            } else &.{};

            // Create left node if not already created (in target graph)
            var left_node_id: u64 = undefined;
            if (hop.left.name) |left_name| {
                if (created_nodes.get(left_name)) |existing| {
                    left_node_id = existing;
                } else {
                    left_node_id = try store.createNodeWithGraph(hop.left.labels, target_graph);
                    // Log left node creation for rollback support
                    const undo_log_left = txn_undo_log.getGlobalUndoLog(allocator);
                    undo_log_left.logCreateNode(left_node_id, current_graph) catch |err| {
                        log.err("undo log failed", &.{Attr.string("error", @errorName(err))});
                    };
                    try created_nodes.put(left_name, left_node_id);
                    ensureAutoIndexes(allocator, hop.left.labels);
                }
            } else {
                left_node_id = try store.createNodeWithGraph(hop.left.labels, target_graph);
                // Log left node creation for rollback support (unnamed node)
                const undo_log_left2 = txn_undo_log.getGlobalUndoLog(allocator);
                undo_log_left2.logCreateNode(left_node_id, current_graph) catch |err| {
                    log.err("undo log failed", &.{Attr.string("error", @errorName(err))});
                };
                ensureAutoIndexes(allocator, hop.left.labels);
            }

            // Set properties on left node (pre-evaluated above for atomicity)
            if (hop.left.props) |props| {
                for (props, left_values) |prop, value| {
                    try property_mutation.setNodePropertyFromValue(allocator, store, hop.left.labels, left_node_id, prop.key, value);
                }
            }

            // Create right node if not already created (in target graph)
            var right_node_id: u64 = undefined;
            if (hop.right.name) |right_name| {
                if (created_nodes.get(right_name)) |existing| {
                    right_node_id = existing;
                } else {
                    right_node_id = try store.createNodeWithGraph(hop.right.labels, target_graph);
                    // Log right node creation for rollback support
                    const undo_log_right = txn_undo_log.getGlobalUndoLog(allocator);
                    undo_log_right.logCreateNode(right_node_id, current_graph) catch |err| {
                        log.err("undo log failed", &.{Attr.string("error", @errorName(err))});
                    };
                    try created_nodes.put(right_name, right_node_id);
                    ensureAutoIndexes(allocator, hop.right.labels);
                }
            } else {
                right_node_id = try store.createNodeWithGraph(hop.right.labels, target_graph);
                // Log right node creation for rollback support (unnamed node)
                const undo_log_right2 = txn_undo_log.getGlobalUndoLog(allocator);
                undo_log_right2.logCreateNode(right_node_id, current_graph) catch |err| {
                    log.err("undo log failed", &.{Attr.string("error", @errorName(err))});
                };
                ensureAutoIndexes(allocator, hop.right.labels);
            }

            // Set properties on right node (pre-evaluated above for atomicity)
            if (hop.right.props) |props| {
                for (props, right_values) |prop, value| {
                    try property_mutation.setNodePropertyFromValue(allocator, store, hop.right.labels, right_node_id, prop.key, value);
                }
            }

            // Create edge in target graph
            const edge_type = if (hop.rel.types.len > 0) hop.rel.types[0] else "RELATES_TO";
            const edge_id = switch (hop.rel.dir) {
                .right => try store.createEdgeWithGraph(left_node_id, right_node_id, edge_type, target_graph),
                .left => try store.createEdgeWithGraph(right_node_id, left_node_id, edge_type, target_graph),
                .undirected => try store.createEdgeWithGraph(left_node_id, right_node_id, edge_type, target_graph),
            };
            // Log edge creation for rollback support
            const undo_log_merge = txn_undo_log.getGlobalUndoLog(allocator);
            undo_log_merge.logCreateEdge(edge_id, current_graph) catch |err| {
                log.err("undo log failed", &.{Attr.string("error", @errorName(err))});
            };

            // Auto-create index for edge type
            ensureAutoIndexes(allocator, &.{edge_type});

            // Set edge properties (pre-evaluated above for atomicity)
            if (hop.rel.props) |props| {
                for (props, rel_values) |prop, value| {
                    try property_mutation.setEdgePropertyFromValue(allocator, store, edge_type, edge_id, prop.key, value);
                }
            }

            // Track created relationship by variable name
            if (hop.rel.name) |rel_var_name| {
                const edge_ptr = store.getEdgePtrHydrated(edge_id) orelse return error.EdgeNotFound;
                const edge_value = Value{ .Edge = edge_ptr };
                try created_relationships.put(rel_var_name, edge_value);
            }
        }
    }

    // Handle RETURN clause if present
    if (c.return_clause) |ret| {
        // Check if RETURN uses count(*) aggregation — return total created entity count
        // Only match count(*), not count(variable) which should be evaluated normally
        if (ret.items.len == 1 and ret.items[0].expr == .Call) {
            const call = ret.items[0].expr.Call;
            if (call.callee.* == .Ident and
                (std.mem.eql(u8, call.callee.Ident.orig, "count") or
                    std.mem.eql(u8, call.callee.Ident.orig, "COUNT")) and
                call.args.len == 1 and call.args[0].* == .Ident and
                std.mem.eql(u8, call.args[0].Ident.orig, "*"))
            {
                const created_entity_count: i64 = @intCast(created_nodes.count() + created_relationships.count());
                var columns = try allocator.alloc([]const u8, 1);
                columns[0] = try allocator.dupe(u8, ret.items[0].alias orelse "count");
                var rows = try allocator.alloc([]Value, 1);
                var ret_row = try allocator.alloc(Value, 1);
                ret_row[0] = Value{ .Int = created_entity_count };
                rows[0] = ret_row;
                if (stmt_txn_open) try stmt_txn.commit();
                return ExecutionResult{
                    .columns = columns,
                    .rows = rows,
                    .flags = std.ArrayList([]const u8).empty,
                };
            }
        }

        // Build environment with created nodes and relationships
        const total_count = created_nodes.count() + created_relationships.count();
        var names = try allocator.alloc([]const u8, total_count);
        var values = try allocator.alloc(Value, total_count);
        defer allocator.free(names);
        defer allocator.free(values);

        var idx: usize = 0;

        // Add nodes to environment
        var node_iter = created_nodes.iterator();
        while (node_iter.next()) |entry| {
            names[idx] = entry.key_ptr.*;
            // Look up node by ID from store
            const node_id = entry.value_ptr.*;
            const node = (store.nodes.getOrHydratePtr(node_id) catch null) orelse return error.NodeNotFound;
            values[idx] = Value{ .Node = node };
            idx += 1;
        }

        // Add relationships to environment
        var rel_iter = created_relationships.iterator();
        while (rel_iter.next()) |entry| {
            names[idx] = entry.key_ptr.*;
            values[idx] = entry.value_ptr.*;
            idx += 1;
        }

        const env = Env{
            .allocator = allocator,
            .names = names,
            .values = values,
        };

        // Execute RETURN with the created nodes and relationships in scope
        const ret_result = try executeReturnClauseWithEnv(allocator, ret, env);
        if (stmt_txn_open) try stmt_txn.commit();
        return ret_result;
    }

    if (stmt_txn_open) try stmt_txn.commit();
    return ExecutionResult{
        .columns = try allocator.alloc([]const u8, 0),
        .rows = try allocator.alloc([]Value, 0),
        .flags = blk: {
            const list = std.ArrayList([]const u8).empty;
            break :blk list;
        },
    };
}

// CANARY: REQ=REQ-MULTI-GRAPH-019; FEATURE="MultiGraphIsolation"; ASPECT=ExecuteInsert; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
pub fn executeInsert(allocator: std.mem.Allocator, ins: ast.InsertStatement, current_graph: ?[]const u8) !ExecutionResult {
    // Cluster write routing: INSERT is not in the Raft-replicable slice yet, so
    // in cluster mode it must fail closed rather than be written to a single
    // node's local store (follower => ClusterNotLeader; leader => not
    // replicable). See tests/cluster/netns_cluster_replication_test.sh.
    switch (try clusterWriteRole()) {
        .standalone => {},
        .leader => return error.ClusterWriteNotReplicable,
    }

    const store = graph_store.getGlobalStore(allocator);
    const target_graph = current_graph orelse "default";

    // Track created nodes by variable name
    var created_nodes = std.StringHashMap(u64).init(allocator);
    defer created_nodes.deinit();

    // Statement-atomicity pre-pass — see `executeCreate`.
    // CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=InsertPrePass; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25
    try write_precheck.checkPatternWritable(
        allocator,
        ins.pattern,
        Env{ .allocator = allocator, .names = &.{}, .values = &.{} },
    );

    // Create nodes from pattern
    for (ins.pattern.chains) |chain| {
        // OWNERSHIP for the GAP-0930 pre-evaluation buffers in this chain.
        //
        // `evalExpr` results are a MIX of ownerships — OWNED heap (a
        // `vectorf32(...)` literal ends in `allocator.dupe`, types/vector.zig:55),
        // AST-BORROWED (string literals), and ALIASES of live store memory
        // (`n.emb`) — so neither "free every value" (double free / UAF of store
        // memory) nor "free nothing" (the pre-fix behaviour: only the []Value
        // SLICE was freed, orphaning every owned payload) is correct. The apply
        // calls below DEEP-COPY into the store and nothing derived from these
        // values escapes the chain iteration, so an arena scoped to one chain
        // reclaims exactly the owned intermediates and touches nothing else.
        var chain_arena = std.heap.ArenaAllocator.init(allocator);
        defer chain_arena.deinit();
        const ca = chain_arena.allocator();

        // Handle single node creation
        if (chain.head) |node_pattern| {
            // GAP-0930: evaluate property-value expressions BEFORE creating the
            // node so an eval error aborts the INSERT atomically (no orphan node
            // with the failed property defaulted to NULL).
            const evaluated_values: []Value = if (node_pattern.props) |props| blk_ev: {
                const env = Env{ .allocator = ca, .names = &.{}, .values = &.{} };
                const buf = try ca.alloc(Value, props.len);
                for (props, 0..) |prop, i| buf[i] = try eval.evalExpr(ca, prop.value.*, env);
                break :blk_ev buf;
            } else &.{};

            const node_id = try store.createNodeWithGraph(node_pattern.labels, target_graph);

            // Apply the pre-evaluated property values.
            if (node_pattern.props) |props| {
                for (props, evaluated_values) |prop, value| {
                    try property_mutation.setNodePropertyFromValue(allocator, store, node_pattern.labels, node_id, prop.key, value);
                }
            }

            // Store node ID if it has a variable name
            if (node_pattern.name) |name| {
                try created_nodes.put(name, node_id);
            }

            // Auto-create indexes for node labels
            ensureAutoIndexes(allocator, node_pattern.labels);
        }

        // Handle chains with relationships
        for (chain.hops) |hop| {
            // GAP-0930: pre-evaluate all endpoint + relationship property
            // expressions before creating any node/edge so an eval error aborts
            // the INSERT atomically instead of committing partial endpoints.
            const hop_env = Env{ .allocator = ca, .names = &.{}, .values = &.{} };
            const left_values: []Value = if (hop.left.props) |props| blk_lv: {
                const buf = try ca.alloc(Value, props.len);
                for (props, 0..) |prop, i| buf[i] = try eval.evalExpr(ca, prop.value.*, hop_env);
                break :blk_lv buf;
            } else &.{};
            const right_values: []Value = if (hop.right.props) |props| blk_rv: {
                const buf = try ca.alloc(Value, props.len);
                for (props, 0..) |prop, i| buf[i] = try eval.evalExpr(ca, prop.value.*, hop_env);
                break :blk_rv buf;
            } else &.{};
            const rel_values: []Value = if (hop.rel.props) |props| blk_rev: {
                const buf = try ca.alloc(Value, props.len);
                for (props, 0..) |prop, i| buf[i] = try eval.evalExpr(ca, prop.value.*, hop_env);
                break :blk_rev buf;
            } else &.{};

            // Create left node if not already created (in target graph)
            var left_node_id: u64 = undefined;
            if (hop.left.name) |left_name| {
                if (created_nodes.get(left_name)) |existing| {
                    left_node_id = existing;
                } else {
                    left_node_id = try store.createNodeWithGraph(hop.left.labels, target_graph);
                    // Log left node creation for rollback support
                    const undo_log_left = txn_undo_log.getGlobalUndoLog(allocator);
                    undo_log_left.logCreateNode(left_node_id, current_graph) catch |err| {
                        log.err("undo log failed", &.{Attr.string("error", @errorName(err))});
                    };
                    try created_nodes.put(left_name, left_node_id);
                    ensureAutoIndexes(allocator, hop.left.labels);
                }
            } else {
                left_node_id = try store.createNodeWithGraph(hop.left.labels, target_graph);
                // Log left node creation for rollback support (unnamed node)
                const undo_log_left2 = txn_undo_log.getGlobalUndoLog(allocator);
                undo_log_left2.logCreateNode(left_node_id, current_graph) catch |err| {
                    log.err("undo log failed", &.{Attr.string("error", @errorName(err))});
                };
                ensureAutoIndexes(allocator, hop.left.labels);
            }

            // Set properties on left node (pre-evaluated above for atomicity)
            if (hop.left.props) |props| {
                for (props, left_values) |prop, value| {
                    try property_mutation.setNodePropertyFromValue(allocator, store, hop.left.labels, left_node_id, prop.key, value);
                }
            }

            // Create right node if not already created (in target graph)
            var right_node_id: u64 = undefined;
            if (hop.right.name) |right_name| {
                if (created_nodes.get(right_name)) |existing| {
                    right_node_id = existing;
                } else {
                    right_node_id = try store.createNodeWithGraph(hop.right.labels, target_graph);
                    // Log right node creation for rollback support
                    const undo_log_right = txn_undo_log.getGlobalUndoLog(allocator);
                    undo_log_right.logCreateNode(right_node_id, current_graph) catch |err| {
                        log.err("undo log failed", &.{Attr.string("error", @errorName(err))});
                    };
                    try created_nodes.put(right_name, right_node_id);
                    ensureAutoIndexes(allocator, hop.right.labels);
                }
            } else {
                right_node_id = try store.createNodeWithGraph(hop.right.labels, target_graph);
                // Log right node creation for rollback support (unnamed node)
                const undo_log_right2 = txn_undo_log.getGlobalUndoLog(allocator);
                undo_log_right2.logCreateNode(right_node_id, current_graph) catch |err| {
                    log.err("undo log failed", &.{Attr.string("error", @errorName(err))});
                };
                ensureAutoIndexes(allocator, hop.right.labels);
            }

            // Set properties on right node (pre-evaluated above for atomicity)
            if (hop.right.props) |props| {
                for (props, right_values) |prop, value| {
                    try property_mutation.setNodePropertyFromValue(allocator, store, hop.right.labels, right_node_id, prop.key, value);
                }
            }

            // Create edge in target graph
            const edge_type = if (hop.rel.types.len > 0) hop.rel.types[0] else "RELATES_TO";
            const edge_id = switch (hop.rel.dir) {
                .right => try store.createEdgeWithGraph(left_node_id, right_node_id, edge_type, target_graph),
                .left => try store.createEdgeWithGraph(right_node_id, left_node_id, edge_type, target_graph),
                .undirected => try store.createEdgeWithGraph(left_node_id, right_node_id, edge_type, target_graph),
            };
            // Log edge creation for rollback support
            const undo_log_merge = txn_undo_log.getGlobalUndoLog(allocator);
            undo_log_merge.logCreateEdge(edge_id, current_graph) catch |err| {
                log.err("undo log failed", &.{Attr.string("error", @errorName(err))});
            };

            // Auto-create index for edge type
            ensureAutoIndexes(allocator, &.{edge_type});

            // Set edge properties (pre-evaluated above for atomicity)
            if (hop.rel.props) |props| {
                for (props, rel_values) |prop, value| {
                    try property_mutation.setEdgePropertyFromValue(allocator, store, edge_type, edge_id, prop.key, value);
                }
            }
        }
    }

    // Handle RETURN clause if present
    if (ins.return_clause) |ret| {
        // Build environment with created nodes
        var names = try allocator.alloc([]const u8, created_nodes.count());
        var values = try allocator.alloc(Value, created_nodes.count());
        defer allocator.free(names);
        defer allocator.free(values);

        var iter = created_nodes.iterator();
        var idx: usize = 0;
        while (iter.next()) |entry| {
            names[idx] = entry.key_ptr.*;
            // Look up node by ID from store
            const node_id = entry.value_ptr.*;
            const node = (store.nodes.getOrHydratePtr(node_id) catch null) orelse return error.NodeNotFound;
            values[idx] = Value{ .Node = node };
            idx += 1;
        }

        const env = Env{
            .allocator = allocator,
            .names = names,
            .values = values,
        };

        // Execute RETURN with the created nodes in scope
        return executeReturnClauseWithEnv(allocator, ret, env);
    }

    return ExecutionResult{
        .columns = try allocator.alloc([]const u8, 0),
        .rows = try allocator.alloc([]Value, 0),
        .flags = blk: {
            const list = std.ArrayList([]const u8).empty;
            break :blk list;
        },
    };
}

/// Resolve a list of `ON CREATE SET` / `ON MATCH SET` clauses targeting the
/// merged node variable into concrete scalar `cluster_replication.Prop` entries,
/// appended to `out`. Returns `error.ClusterWriteNotReplicable` for any clause
/// this slice cannot replicate deterministically (a `.Labels` / `.AllProperties`
/// form, a non-scalar value, or a `.Property` targeting some other variable),
/// so the leader fails closed instead of writing leader-local.
fn resolveMergeSetProps(
    allocator: std.mem.Allocator,
    set_items: []const ast.SetClause,
    var_name: ?[]const u8,
    context: ExecutionContext,
    out: *std.ArrayList(cluster_replication.Prop),
) !void {
    if (set_items.len == 0) return;
    const target_var = var_name orelse return error.ClusterWriteNotReplicable;
    for (set_items) |set_clause| {
        switch (set_clause) {
            .Property => |prop| {
                if (!std.mem.eql(u8, prop.target.object, target_var))
                    return error.ClusterWriteNotReplicable;
                const value = eval.evalExpr(allocator, prop.value, envFromContext(allocator, context)) catch
                    return error.ClusterWriteNotReplicable;
                // Statement-atomicity pre-pass: refuse an unstorable entry
                // before the leader PROPOSES it, rather than letting every
                // follower fail half-way through applying it.
                // CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=ClusterMergePrePass; STATUS=IMPL; OWNER=engine; UPDATED=2026-08-25
                try write_precheck.checkPropertyWritable(allocator, &.{}, prop.target.property, value);
                const pv = clusterPropValue(value) orelse return error.ClusterWriteNotReplicable;
                try out.append(allocator, .{ .key = prop.target.property, .value = pv });
            },
            // SET label / SET = {map} are not in the replicable MERGE slice.
            .Labels, .AllProperties => return error.ClusterWriteNotReplicable,
        }
    }
}

/// Replicate an eligible node `MERGE (:Label {props})` through Raft and return
/// its result. Called ONLY when this node is the cluster leader.
///
/// THE CRITICAL DETERMINISM RULE: the match-or-create decision is made ONCE on
/// the LEADER and shipped as a concrete OUTCOME. Followers NEVER re-evaluate the
/// match (their scan order could differ → divergence). Outcomes:
///   * NOT MATCHED → reuse the GNC1 node-create codec (merge props + ON CREATE
///     SET resolved to concrete scalars). The create rides the already-
///     idempotent, raft-index-keyed create apply path.
///   * MATCHED, no ON MATCH SET → NO-OP: short-circuit WITHOUT proposing
///     anything (nothing mutates — semantically correct and cheap, so the
///     second MERGE of the same key is free).
///   * MATCHED, with ON MATCH SET → ship a GMRG payload (leader-resolved stable
///     id + concrete props), applied idempotently by id on every node.
///
/// CONCURRENT-MERGE RACE: between the leader's match evaluation and the raft
/// commit, another committed entry could create the same node (two concurrent
/// MERGEs of the same key). Geode serializes leader writes through
/// proposeWrite + waitForApplied per statement, so this is bounded by the
/// single-writer leader model; it is documented as a known limitation rather
/// than re-introducing non-deterministic follower-side matching.
///
/// Returns `error.ClusterWriteNotReplicable` for any shape outside the slice (a
/// relationship MERGE, a RETURN clause, or a non-scalar/label/map SET), so the
/// write fails closed instead of being applied leader-local.
// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MERGE; FEATURE="DistributedCluster"; ASPECT=LeaderProposeMerge; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-09
fn clusterReplicateMerge(
    allocator: std.mem.Allocator,
    m: ast.MergeStatement,
    current_graph: ?[]const u8,
    context: ExecutionContext,
) !ExecutionResult {
    const coord = cluster_mod.getGlobalClusterCoordinator() orelse return error.ClusterWriteNotReplicable;

    // RETURN clause projects the merged node + `created` flag — not determinable
    // pre-commit (the create id is the raft index, unknown until applied). Fail
    // closed for this slice.
    if (m.return_clause != null) return error.ClusterWriteNotReplicable;

    // Only a single-node MERGE (no relationship hops) is replicable here. A
    // relationship MERGE `(a)-[r]->(b)` resolves matched endpoints + edge
    // semantics that are out of this slice — fail closed.
    if (m.pattern.chains.len != 1) return error.ClusterWriteNotReplicable;
    const chain = m.pattern.chains[0];
    if (chain.hops.len != 0) return error.ClusterWriteNotReplicable;
    const node_pattern = chain.head orelse return error.ClusterWriteNotReplicable;

    const read_store = graph_store.getWritableGlobalStore(allocator);
    const target_graph = current_graph orelse "default";
    const filter_tenant = try tenantFilterFromContext(context);

    // Evaluate the MERGE match locally on the leader (same predicate the local
    // path uses) — this is the ONE authoritative match-or-create decision.
    var prop_arena = std.heap.ArenaAllocator.init(allocator);
    defer prop_arena.deinit();
    const evaluated_props = try evaluatePatternProps(prop_arena.allocator(), node_pattern.props, context);

    // SONNY-2686: including the session's row visibility, so the leader never
    // proposes an ON MATCH SET for a node the session may not see.
    var visibility = MergeVisibility.init(allocator, filter_tenant, target_graph, context);
    defer visibility.deinit();
    const matched_id = try visibility.bindNode(findMergeMatch(
        read_store,
        target_graph,
        filter_tenant,
        node_pattern.labels,
        evaluated_props,
        &visibility,
    ), node_pattern.labels, evaluated_props);

    const empty_result = ExecutionResult{
        .columns = try allocator.alloc([]const u8, 0),
        .rows = try allocator.alloc([]Value, 0),
        .flags = std.ArrayList([]const u8).empty,
    };

    if (matched_id) |node_id| {
        // MATCHED. With no ON MATCH SET this is a NO-OP — short-circuit without
        // proposing anything (nothing mutates). The second MERGE of the same key
        // in the regression takes this cheap path.
        if (m.on_match.len == 0) return empty_result;

        // MATCHED + ON MATCH SET: resolve to concrete props and ship a GMRG
        // payload applied idempotently by the leader-resolved stable id.
        var set_props = std.ArrayList(cluster_replication.Prop).empty;
        defer set_props.deinit(allocator);
        try resolveMergeSetProps(allocator, m.on_match, node_pattern.name, context, &set_props);
        if (set_props.items.len == 0) return empty_result;

        const payload = cluster_replication.serializeMerge(allocator, target_graph, node_id, set_props.items) catch |err| switch (err) {
            cluster_replication.CodecError.UnsupportedPropertyType => return error.ClusterWriteNotReplicable,
            else => return err,
        };
        defer allocator.free(payload); // proposeCommand serializes a copy; safe to free after.

        const cmd = raft_consensus.Command{ .graph_mutation = .{
            .graph = target_graph,
            .mutation_type = .merge,
            .data = payload,
            .txn_id = null,
        } };
        const idx = coord.proposeWrite(cmd) catch |err| switch (err) {
            error.NotLeader => return error.ClusterNotLeader,
            else => return err,
        };
        // Commit-aware wait (RC-1, 2026-06-12): success on confirmed COMMIT; no
        // spurious Timeout for a committed-but-apply-lagged entry.
        try coord.waitForCommittedThenApplied(idx, 5000);
        return empty_result;
    }

    // NOT MATCHED → create. Reuse the GNC1 node-create codec: merge pattern props
    // PLUS ON CREATE SET, both resolved to concrete scalars on the leader.
    var props = std.ArrayList(cluster_replication.Prop).empty;
    defer props.deinit(allocator);
    if (node_pattern.props) |plist| {
        const env = envFromContext(allocator, context);
        for (plist) |p| {
            const val = eval.evalExpr(allocator, p.value.*, env) catch
                return error.ClusterWriteNotReplicable;
            const pv = clusterPropValue(val) orelse return error.ClusterWriteNotReplicable;
            try props.append(allocator, .{ .key = p.key, .value = pv });
        }
    }
    try resolveMergeSetProps(allocator, m.on_create, node_pattern.name, context, &props);

    const payload = cluster_replication.serializeNodeCreate(allocator, target_graph, node_pattern.labels, props.items) catch |err| switch (err) {
        cluster_replication.CodecError.UnsupportedPropertyType => return error.ClusterWriteNotReplicable,
        else => return err,
    };
    defer allocator.free(payload); // proposeCommand serializes a copy; safe to free after.

    const cmd = raft_consensus.Command{ .graph_mutation = .{
        .graph = target_graph,
        .mutation_type = .create,
        .data = payload,
        .txn_id = null,
    } };
    const idx = coord.proposeWrite(cmd) catch |err| switch (err) {
        error.NotLeader => return error.ClusterNotLeader,
        else => return err,
    };
    // Commit-aware wait (RC-1, 2026-06-12): success on confirmed COMMIT; no
    // spurious Timeout for a committed-but-apply-lagged entry.
    try coord.waitForCommittedThenApplied(idx, 5000);
    return empty_result;
}

/// ENG-3903: one MERGE statement can carry SEVERAL chains — comma-separated
/// chains (`MERGE (a:T {..}), (b:T {..})`) and consecutive MERGE clauses
/// (`MERGE (a:T {..}) MERGE (b:T {..}) MERGE (a)-[:REL]->(b)`) both parse into a
/// single GraphPattern. Every node chain records the variable it bound here so a
/// later relationship chain can resolve its endpoints to the nodes the earlier
/// clauses merged.
const MergedNodeBinding = struct {
    pattern: ast.NodePattern,
    node_id: u64,
    created: bool,
};

// CANARY: REQ=REQ-TXN-UNDO-MERGE-CREATES; FEATURE="TransactionUndoLog"; ASPECT=MergeCreateUndoLog; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-09-27
/// A node or edge that MERGE creates goes into the transaction's undo log, as
/// CREATE's do (REQ-TXN-UNDO-009), so ROLLBACK removes it, and with it the
/// properties the MERGE set on it. MERGE logged nothing: `START TRANSACTION;
/// MERGE (:M {k: 1}); ROLLBACK` kept the node, and so did a MERGE'd edge.
/// Logged at once, before a property write that can fail. The log records
/// only for a thread in a transaction (SONNY-2799). A change it cannot record
/// fails the statement, rather than leave a change ROLLBACK would not undo.
fn logMergeCreatedNode(allocator: std.mem.Allocator, node_id: u64, target_graph: []const u8) !void {
    try txn_undo_log.getGlobalUndoLog(allocator).logCreateNode(node_id, target_graph);
}

/// `logMergeCreatedNode` for an edge.
fn logMergeCreatedEdge(allocator: std.mem.Allocator, edge_id: u64, target_graph: []const u8) !void {
    try txn_undo_log.getGlobalUndoLog(allocator).logCreateEdge(edge_id, target_graph);
}

/// Merge ONE single-node chain (`MERGE (a:Label {props})`): match-or-create the
/// node, then apply the statement's ON MATCH / ON CREATE SET clauses that target
/// this chain's variable.
// CANARY: REQ=REQ-MERGE-RELPROPS-001; FEATURE="MergeRelationship"; ASPECT=ChainedMergeEndpoints; STATUS=TESTED; TEST=tests/test_merge_relationship_bugs.zig; OWNER=execution; UPDATED=2026-08-24
fn mergeNodeChain(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    read_store: *graph_store.GraphStore,
    target_graph: []const u8,
    filter_tenant: ?[]const u8,
    node_pattern: ast.NodePattern,
    m: ast.MergeStatement,
    context: ExecutionContext,
    visibility: *MergeVisibility,
) !MergedNodeBinding {
    // GAP-0900 Layer-3 (Fix 2): in lean-index mode the MERGE pattern keys
    // MUST stay indexed in the merge_prop_index, otherwise dedup breaks (a
    // second MERGE on the same key would not find the first node and would
    // create a duplicate). The bulk fast path registers its merge_key; the
    // regular executor MERGE registers here so both paths dedup correctly.
    // No-op when lean mode is off.
    if (node_pattern.props) |pp| {
        for (pp) |prop| graph_store.registerMergeIndexKey(prop.key);
    }

    // Look for existing node matching the pattern (filtered by graph)
    var found_node: ?*graph_store.Node = null;
    // Function-scoped evaluation arena. It backs BOTH the match predicate
    // (`evaluatePatternProps`, see its ownership contract) and every apply-side
    // `evalExpr` below: the pattern props and the ON CREATE / ON MATCH SET
    // values are all handed to `setNodePropertyFromValue` /
    // `replaceNodeProperties`, which DEEP-COPY into the store and never take
    // ownership. Nothing evaluated here reaches `MergedNodeBinding` (ids and
    // the AST pattern only), so the arena outlives every consumer.
    var prop_arena = std.heap.ArenaAllocator.init(allocator);
    defer prop_arena.deinit();
    const pa = prop_arena.allocator();
    const evaluated_props = try evaluatePatternProps(pa, node_pattern.props, context);

    // SONNY-2686: a node the session may not see is never bound, so none of
    // the ON MATCH clauses below can reach it; a pattern that only such a node
    // matches refuses the statement here, before anything is written.
    if (try visibility.bindNode(findMergeMatch(
        read_store,
        target_graph,
        filter_tenant,
        node_pattern.labels,
        evaluated_props,
        visibility,
    ), node_pattern.labels, evaluated_props)) |found_id| {
        found_node = (read_store.nodes.getOrHydratePtr(found_id) catch null);
    }

    var node_id: u64 = undefined;
    var created = false;

    if (found_node) |node| {
        // Node exists - apply ON MATCH clauses
        node_id = node.id;
        for (m.on_match) |set_clause| {
            switch (set_clause) {
                .Property => |prop| {
                    if (node_pattern.name) |var_name| {
                        if (std.mem.eql(u8, prop.target.object, var_name)) {
                            // Evaluate the property expression
                            const value = try eval.evalExpr(pa, prop.value, envFromContext(pa, context));
                            const node_ptr = (store.nodes.getOrHydratePtr(node_id) catch null) orelse return error.NodeNotFound;
                            try property_mutation.setNodePropertyFromValue(allocator, store, node_ptr.labels, node_id, prop.target.property, value);
                        }
                    }
                },
                .Labels => |label_set| {
                    if (node_pattern.name) |var_name| {
                        if (std.mem.eql(u8, label_set.node, var_name)) {
                            for (label_set.labels) |label| {
                                try store.addNodeLabel(node_id, label);
                            }
                        }
                    }
                },
                .AllProperties => |all_props| {
                    if (node_pattern.name) |var_name| {
                        if (std.mem.eql(u8, all_props.node, var_name)) {
                            // Evaluate the properties expression (should be a map literal)
                            const props_value = try eval.evalExpr(pa, all_props.properties, envFromContext(pa, context));

                            // Clear all existing properties by getting node and manually clearing
                            if ((store.nodes.getOrHydratePtr(node_id) catch null)) |node_ptr| {
                                try property_mutation.replaceNodeProperties(allocator, store, node_ptr, props_value);
                            }
                        }
                    }
                },
            }
        }
    } else {
        // Node doesn't exist - create it in target graph and apply ON CREATE clauses
        created = true;
        node_id = try store.createNodeWithGraph(node_pattern.labels, target_graph);
        try logMergeCreatedNode(allocator, node_id, target_graph);

        // Auto-create indexes for node labels
        ensureAutoIndexes(allocator, node_pattern.labels);

        // Set properties from pattern
        if (node_pattern.props) |props| {
            for (props) |prop| {
                const value = try eval.evalExpr(pa, prop.value.*, envFromContext(pa, context));
                try property_mutation.setNodePropertyFromValue(allocator, store, node_pattern.labels, node_id, prop.key, value);
            }
        }

        // Apply ON CREATE clauses
        for (m.on_create) |set_clause| {
            switch (set_clause) {
                .Property => |prop| {
                    if (node_pattern.name) |var_name| {
                        if (std.mem.eql(u8, prop.target.object, var_name)) {
                            // Evaluate the property expression
                            const value = try eval.evalExpr(pa, prop.value, envFromContext(pa, context));
                            const node_ptr = (store.nodes.getOrHydratePtr(node_id) catch null) orelse return error.NodeNotFound;
                            try property_mutation.setNodePropertyFromValue(allocator, store, node_ptr.labels, node_id, prop.target.property, value);
                        }
                    }
                },
                .Labels => |label_set| {
                    if (node_pattern.name) |var_name| {
                        if (std.mem.eql(u8, label_set.node, var_name)) {
                            for (label_set.labels) |label| {
                                try store.addNodeLabel(node_id, label);
                            }
                        }
                    }
                },
                .AllProperties => |all_props| {
                    if (node_pattern.name) |var_name| {
                        if (std.mem.eql(u8, all_props.node, var_name)) {
                            // Evaluate the properties expression (should be a map literal)
                            const props_value = try eval.evalExpr(pa, all_props.properties, envFromContext(pa, context));

                            // Clear all existing properties by getting node and manually clearing
                            if ((store.nodes.getOrHydratePtr(node_id) catch null)) |node_ptr| {
                                try property_mutation.replaceNodeProperties(allocator, store, node_ptr, props_value);
                            }
                        }
                    }
                },
            }
        }
    }

    return .{ .pattern = node_pattern, .node_id = node_id, .created = created };
}

/// The node the statement's caller bound to the endpoint variable `name`: a
/// procedure binding (`context.bindings`) or the MATCH row the dispatcher
/// threads through the query parameters. Null when the caller bound nothing.
fn endpointBoundByCaller(context: ExecutionContext, name: []const u8) ?u64 {
    if (context.bindings) |bindings| {
        if (bindings.get(name)) |binding| {
            switch (binding) {
                .node_id => |nid| return nid,
                .edge_id => {},
            }
        }
    }
    return lookupNodeIdInQueryParams(context, name);
}

/// SONNY-2686: refuse a MERGE, BEFORE it writes anything, when any node
/// pattern it would match inline (a chain's node, or a relationship endpoint
/// its caller did not bind) is matched only by nodes the session may not see,
/// or (P12) when a relationship between two endpoints that already exist is
/// matched only by edges the session may not see.
///
/// The chains run in order, and an endpoint that does not exist is created
/// before the next one is matched, so the inline refusal alone could leave the
/// first half of a pattern behind a refused statement: an aborted statement's
/// engine txn discards what it wrote, but the in-memory store keeps it. The
/// inline checks stay, for the answer this pre-pass cannot give (a pattern an
/// earlier chain's CREATE makes match a visible node); this pass can only be
/// stricter than they are, never looser.
fn refuseHiddenMergeMatches(
    allocator: std.mem.Allocator,
    read_store: *graph_store.GraphStore,
    target_graph: []const u8,
    filter_tenant: ?[]const u8,
    m: ast.MergeStatement,
    context: ExecutionContext,
    visibility: *MergeVisibility,
) !void {
    // Nothing can be hidden from this session.
    if (!visibility.rls_may_deny) return;
    // The variables this pass has resolved, as the statement will bind them:
    // the existing node a pattern matches, or null when the statement creates
    // it (no edge can join a node that does not exist yet).
    var known = std.StringHashMap(?u64).init(allocator);
    defer known.deinit();
    for (m.pattern.chains) |chain| {
        // A chain's node is always matched (`mergeNodeChain`).
        if (chain.head) |node_pattern| {
            const id = try preResolveMergeNode(allocator, read_store, target_graph, filter_tenant, node_pattern, context, visibility);
            if (node_pattern.name) |name| try known.put(name, id);
        }
        for (chain.hops) |hop| {
            const source = try preResolveMergeEndpoint(allocator, read_store, target_graph, filter_tenant, hop.left, context, visibility, &known);
            const target = try preResolveMergeEndpoint(allocator, read_store, target_graph, filter_tenant, hop.right, context, visibility, &known);
            // P12: both endpoints exist, so the edge `mergeRelationshipHop`
            // would bind exists already: refuse now when only hidden edges
            // match, before an earlier chain writes anything.
            if (source != null and target != null) {
                _ = try visibility.bindEdge(findExistingEdge(read_store, target_graph, filter_tenant, source.?, target.?, hop.rel.types, visibility), hop.rel);
            }
        }
    }
}

/// The existing node a MERGE node pattern binds, or null when it creates one;
/// a pattern only hidden nodes match refuses the statement.
fn preResolveMergeNode(
    allocator: std.mem.Allocator,
    read_store: *graph_store.GraphStore,
    target_graph: []const u8,
    filter_tenant: ?[]const u8,
    node_pattern: ast.NodePattern,
    context: ExecutionContext,
    visibility: *MergeVisibility,
) !?u64 {
    var prop_arena = std.heap.ArenaAllocator.init(allocator);
    defer prop_arena.deinit();
    const evaluated_props = try evaluatePatternProps(prop_arena.allocator(), node_pattern.props, context);
    return try visibility.bindNode(findMergeMatch(read_store, target_graph, filter_tenant, node_pattern.labels, evaluated_props, visibility), node_pattern.labels, evaluated_props);
}

/// `resolveMergeEndpoint`'s answer, without creating anything: a variable an
/// earlier pattern of this statement bound, then one the caller bound (not
/// re-checked: the clause that bound it applied the session's visibility),
/// then an inline match of a node the session may see. Null when the
/// statement would create the endpoint, or refuse it as an unbound variable.
fn preResolveMergeEndpoint(
    allocator: std.mem.Allocator,
    read_store: *graph_store.GraphStore,
    target_graph: []const u8,
    filter_tenant: ?[]const u8,
    endpoint: ast.NodePattern,
    context: ExecutionContext,
    visibility: *MergeVisibility,
    known: *std.StringHashMap(?u64),
) !?u64 {
    if (endpoint.name) |name| {
        if (known.get(name)) |id| return id;
        if (endpointBoundByCaller(context, name)) |nid| return nid;
    }
    // Nothing to match on (`resolveMergeEndpoint` refuses it).
    if (endpoint.labels.len == 0 and endpoint.props == null) return null;
    const id = try preResolveMergeNode(allocator, read_store, target_graph, filter_tenant, endpoint, context, visibility);
    if (endpoint.name) |name| try known.put(name, id);
    return id;
}

/// Resolve ONE endpoint of a MERGE relationship pattern to a concrete node id.
///
/// Resolution order: variables bound by an earlier chain of THIS statement,
/// then `context.bindings`, then the MATCH-row parameters the dispatcher
/// propagates (query_execution.zig:1911-1920), then an inline label/property
/// match of a node the session may see (SONNY-2686: a pattern that only hidden
/// nodes match refuses the statement). An endpoint that still does not resolve
/// but DOES carry a label or properties is CREATED — that is the
/// match-or-create contract MERGE promises for the whole pattern. A bare,
/// unbound variable (`(zz)`) carries nothing to match or create on, so the
/// statement is REJECTED instead of silently committing an empty success
/// (ENG-3903 silent write loss).
///
/// A bound endpoint is not re-checked for visibility: the clause that bound it
/// (the MATCH that produced the row, or an earlier chain of this MERGE) already
/// applied the session's visibility, or created the node itself.
// CANARY: REQ=REQ-MERGE-RELPROPS-001; FEATURE="MergeRelationship"; ASPECT=UnresolvableEndpointFailsLoud; STATUS=TESTED; TEST=tests/test_merge_relationship_bugs.zig; OWNER=execution; UPDATED=2026-08-24
fn resolveMergeEndpoint(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    read_store: *graph_store.GraphStore,
    target_graph: []const u8,
    filter_tenant: ?[]const u8,
    node_pattern: ast.NodePattern,
    context: ExecutionContext,
    merged_vars: *std.StringHashMap(u64),
    visibility: *MergeVisibility,
) !u64 {
    if (node_pattern.name) |name| {
        if (merged_vars.get(name)) |bound_id| return bound_id;
        if (endpointBoundByCaller(context, name)) |nid| return nid;
    }

    // Nothing to match on and nothing bound: the variable is undefined.
    if (node_pattern.labels.len == 0 and node_pattern.props == null) {
        return error.UnboundVariable;
    }

    if (node_pattern.props) |pp| {
        for (pp) |prop| graph_store.registerMergeIndexKey(prop.key);
    }

    var prop_arena = std.heap.ArenaAllocator.init(allocator);
    defer prop_arena.deinit();
    const evaluated_props = try evaluatePatternProps(prop_arena.allocator(), node_pattern.props, context);

    if (try visibility.bindNode(findMergeMatch(
        read_store,
        target_graph,
        filter_tenant,
        node_pattern.labels,
        evaluated_props,
        visibility,
    ), node_pattern.labels, evaluated_props)) |matched_id| {
        if (node_pattern.name) |name| try merged_vars.put(name, matched_id);
        return matched_id;
    }

    // No match — create the endpoint (MERGE creates what it cannot match).
    const node_id = try store.createNodeWithGraph(node_pattern.labels, target_graph);
    try logMergeCreatedNode(allocator, node_id, target_graph);
    ensureAutoIndexes(allocator, node_pattern.labels);
    if (node_pattern.props) |props| {
        const env = envFromContext(allocator, context);
        for (props) |prop| {
            const value = try eval.evalExpr(allocator, prop.value.*, env);
            try property_mutation.setNodePropertyFromValue(allocator, store, node_pattern.labels, node_id, prop.key, value);
        }
    }
    if (node_pattern.name) |name| try merged_vars.put(name, node_id);
    return node_id;
}

/// Merge ONE relationship hop of a MERGE pattern: resolve both endpoints, then
/// match-or-create the edge and persist inline rel props / the SET clauses that
/// target the relationship variable.
// CANARY: REQ=REQ-MERGE-RELPROPS-001; FEATURE="MergeRelationship"; ASPECT=MatchBoundEndpoints; STATUS=TESTED; TEST=tests/test_merge_relationship_bugs.zig; OWNER=execution; UPDATED=2026-08-24
fn mergeRelationshipHop(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    read_store: *graph_store.GraphStore,
    target_graph: []const u8,
    filter_tenant: ?[]const u8,
    hop: ast.Hop,
    m: ast.MergeStatement,
    context: ExecutionContext,
    merged_vars: *std.StringHashMap(u64),
    visibility: *MergeVisibility,
) !void {
    const rel_types = hop.rel.types;

    const source_id = try resolveMergeEndpoint(allocator, store, read_store, target_graph, filter_tenant, hop.left, context, merged_vars, visibility);
    const target_id = try resolveMergeEndpoint(allocator, store, read_store, target_graph, filter_tenant, hop.right, context, merged_vars, visibility);

    const edge_type = if (rel_types.len > 0) rel_types[0] else "";
    // P12: an edge the session may not see is never bound; when only hidden
    // edges match, the statement is refused (`refuseHiddenMergeMatches`
    // already refused it before any write when both endpoints existed).
    const existing_edge = try visibility.bindEdge(findExistingEdge(
        read_store,
        target_graph,
        filter_tenant,
        source_id,
        target_id,
        rel_types,
        visibility,
    ), hop.rel);

    // Pick the edge_id we will operate on: existing one (ON MATCH path)
    // or a freshly created one (ON CREATE path). Either way we then
    // apply inline rel props (create-only) plus the appropriate
    // on_create/on_match SET clauses targeting the relationship
    // variable.
    const created_new = existing_edge == null;
    const edge_id: u64 = if (existing_edge) |eid|
        eid
    else
        try store.createEdgeWithGraph(source_id, target_id, edge_type, target_graph);
    if (created_new) try logMergeCreatedEdge(allocator, edge_id, target_graph);

    // REQ=REQ-MERGE-RELPROPS-001 ASPECT=InlineRelProps (Bug B1):
    // Inline `[:REL {key: val}]` literals are applied only on the
    // create path. This mirrors how the executeCreate / executeInsert
    // paths set rel props after `createEdgeWithGraph` (lines 697-708,
    // 861-873, 1249-1257, 1830-1838, 2058-2070).
    if (created_new) {
        if (hop.rel.props) |props| {
            const env = envFromContext(allocator, context);
            for (props) |prop| {
                const value = try eval.evalExpr(allocator, prop.value.*, env);
                try property_mutation.setEdgePropertyFromValue(allocator, store, edge_type, edge_id, prop.key, value);
            }
        }
    }

    // REQ=REQ-MERGE-RELPROPS-001 ASPECT=OnCreateSet/BareSetOnRelationship
    // (Bugs B2, B3): apply SET items targeting the relationship
    // variable. Bare SET (parser flag `set_is_bare`) duplicates the
    // clauses into both on_create and on_match by construction
    // (parser.zig:4575-4586), so picking the right list per branch
    // and routing only items whose target binding name matches the
    // rel variable name is correct for all three SET forms.
    const rel_set_items: []ast.SetClause = if (created_new) m.on_create else m.on_match;
    try applySetClausesToEdge(allocator, store, hop.rel.name, edge_type, edge_id, rel_set_items, context);
}

// CANARY: REQ=REQ-MULTI-GRAPH-020; FEATURE="MultiGraphIsolation"; ASPECT=ExecuteMerge; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
// CANARY: REQ=REQ-PERF-LABEL-INDEX-004; FEATURE="LabelBasedIndex"; ASPECT=MergeOptimization; STATUS=IMPL; OWNER=perf; UPDATED=2026-01-28
// Issue #391: Optimized MERGE using label index instead of O(n) full table scan
pub fn executeMerge(allocator: std.mem.Allocator, m: ast.MergeStatement, current_graph: ?[]const u8, context: ExecutionContext) !ExecutionResult {
    // SONNY-2686: run the statement under its own context. Row-level security
    // reads the ACTIVE context (`passesRLSFilter`), while the tenant filter
    // below comes from `context`; `executeStatementWithContext` installs the
    // context only when it carries a session, so without this a MERGE could
    // match with no RLS identity at all. `executeQueryWithContext` does the
    // same for every query (and so for DELETE / SET target resolution).
    const prev_active_ctx = execution.pushActiveContext(&context);
    defer execution.popActiveContext(prev_active_ctx);

    // Cluster write routing: in cluster mode the MERGE is ordered through Raft on
    // the leader and never applied to a single node's local store. A follower
    // fails closed (error.ClusterNotLeader — clients retry the leader); the leader
    // makes the match-or-create decision ONCE and replicates a concrete outcome
    // (GNC1 create / GMRG matched-set / no-op), or fails closed for shapes outside
    // the slice. See tests/test_cluster_replicable_mutations.zig.
    // CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MERGE; FEATURE="DistributedCluster"; ASPECT=ExecutorProposeMerge; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-09
    switch (try clusterWriteRole()) {
        .standalone => {},
        .leader => return clusterReplicateMerge(allocator, m, current_graph, context),
    }

    const store = graph_store.getWritableGlobalStore(allocator);
    // GAP-0511: MERGE already executes under the graph write lock, so an
    // adapter-backed QueryReadSession would clone the entire graph once per
    // statement. During bulk ingest that turns MERGE into O(total graph size)
    // before any pattern matching happens and triggers connection timeouts.
    const read_store: *graph_store.GraphStore = store;
    const target_graph = current_graph orelse "default";
    // GAP-0509: Extract tenant filter from context for getNodesByLabels filtering.
    // Null means no filtering (default tenant or unset). GAP-0840: in strict mode
    // an unscoped/"default" scope is rejected with error.TenantScopeRequired.
    const filter_tenant = try tenantFilterFromContext(context);

    // R8 (2026-04-22): open a per-statement engine txn so MERGE's
    // createNode + on_create property SETs (or on_match property SETs)
    // commit with a single WAL fsync instead of one per sub-op.  Same
    // pattern as `executeCreate`, including the R9 lazy session-txn
    // shortcut (pin to target_graph on first mutation in Geode txn).
    const gsa = @import("../storage/graph_storage_adapter.zig");
    var stmt_txn: gsa.StatementTxn = undefined;
    var stmt_txn_open = false;
    var session_txn_covers_us = false;
    if (graph_store.getGlobalAdapter()) |ad| {
        if (gsa.sessionEngineTxnGraph()) |g| {
            session_txn_covers_us = std.mem.eql(u8, g, target_graph);
        } else if (context.transaction_state == .Active) {
            if (ad.beginSessionTxnLazy(target_graph)) |_| {
                session_txn_covers_us = true;
            } else |err| switch (err) {
                // SONNY-2823: no session slot on the thread (an embedded
                // caller, not a transport request): per-statement txns.
                error.GraphNotFound, error.NestedSessionTxn, error.NestedStatementTxn, error.NoSessionEngineTxnSlot => {},
                else => return err,
            }
        }
        if (!session_txn_covers_us) {
            if (ad.beginStatementTxn(target_graph, &stmt_txn)) |_| {
                stmt_txn_open = true;
            } else |err| switch (err) {
                error.GraphNotFound, error.NestedStatementTxn => {},
                else => return err,
            }
        }
    }
    errdefer if (stmt_txn_open) stmt_txn.abort();

    // Statement-atomicity pre-pass — see `executeCreate`. MERGE is the shape
    // that hurt most: `MERGE (n:L {k}) ON CREATE SET n.big = ...` minted the
    // node, then failed the SET, leaving a node the caller never asked for and
    // which the next MERGE of the same key silently adopts. Cover the pattern
    // props of every chain plus BOTH clause lists (the parser duplicates a bare
    // SET into both, so validating both is exact for all three SET forms).
    // CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=MergePrePass; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25
    {
        const precheck_env = envFromContext(allocator, context);
        try write_precheck.checkPatternWritable(allocator, m.pattern, precheck_env);
        try write_precheck.checkSetClausesWritable(allocator, m.on_create, precheck_env, null, &.{});
        try write_precheck.checkSetClausesWritable(allocator, m.on_match, precheck_env, null, &.{});
    }

    // SONNY-2686: every node MERGE matches must be one the session may see; a
    // pattern only hidden nodes match refuses the statement, and it is refused
    // before any chain writes.
    var visibility = MergeVisibility.init(allocator, filter_tenant, target_graph, context);
    defer visibility.deinit();
    try refuseHiddenMergeMatches(allocator, read_store, target_graph, filter_tenant, m, context, &visibility);

    // MERGE is like a CREATE but checks if the pattern already exists.
    // ENG-3903: EVERY chain of the pattern runs, in clause order, and the node
    // variables an earlier chain bound are visible to the later ones — that is
    // what makes `MERGE (a:T {..}) MERGE (b:T {..}) MERGE (a)-[:REL]->(b)` and
    // the comma-separated form write the whole pattern instead of chains[0]
    // only.
    var merged_vars = std.StringHashMap(u64).init(allocator);
    defer merged_vars.deinit();

    var merged_nodes = std.ArrayList(MergedNodeBinding).empty;
    defer merged_nodes.deinit(allocator);

    for (m.pattern.chains) |chain| {
        if (chain.head) |node_pattern| {
            const binding = try mergeNodeChain(
                allocator,
                store,
                read_store,
                target_graph,
                filter_tenant,
                node_pattern,
                m,
                context,
                &visibility,
            );
            if (node_pattern.name) |var_name| try merged_vars.put(var_name, binding.node_id);
            try merged_nodes.append(allocator, binding);
        } else {
            // GAP #58: edge MERGE patterns (e.g. MATCH (a), (b) MERGE (a)-[:REL]->(b))
            // REQ=REQ-MERGE-RELPROPS-001 — endpoint resolution for MATCH-bound
            // vars, and persistence of inline rel props / on_create / on_match /
            // bare SET on the merged relationship variable.
            for (chain.hops) |hop| {
                try mergeRelationshipHop(
                    allocator,
                    store,
                    read_store,
                    target_graph,
                    filter_tenant,
                    hop,
                    m,
                    context,
                    &merged_vars,
                    &visibility,
                );
            }
        }
    }

    // Return the merged node(s) if there's a RETURN clause
    if (m.return_clause) |ret| {
        if (merged_nodes.items.len > 0) {
            const columns = try generateUniqueColumnNames(allocator, ret.items);

            var rows = try allocator.alloc([]Value, 1);
            var row = try allocator.alloc(Value, ret.items.len);

            // Create environment with the merged node(s) and the 'created' flag.
            // `created` reflects the LAST merged node chain (with the single-chain
            // form — the only shape that reached here before ENG-3903 — this is
            // exactly the previous behaviour).
            var env_names = std.ArrayList([]const u8).empty;
            defer env_names.deinit(allocator);
            var env_values = std.ArrayList(Value).empty;
            defer env_values.deinit(allocator);

            try env_names.append(allocator, "created");
            try env_values.append(allocator, Value{ .Bool = merged_nodes.items[merged_nodes.items.len - 1].created });

            for (merged_nodes.items, 0..) |binding, bi| {
                const var_name = binding.pattern.name orelse continue;
                // A variable merged more than once keeps its LAST binding.
                var rebound = false;
                for (merged_nodes.items[bi + 1 ..]) |later| {
                    if (later.pattern.name) |later_name| {
                        if (std.mem.eql(u8, later_name, var_name)) {
                            rebound = true;
                            break;
                        }
                    }
                }
                if (rebound) continue;
                const node = (store.nodes.getOrHydratePtr(binding.node_id) catch null) orelse return error.NodeNotFound;
                try env_names.append(allocator, var_name);
                try env_values.append(allocator, Value{ .Node = node });
            }

            const env = Env{
                .allocator = allocator,
                .names = env_names.items,
                .values = env_values.items,
            };

            for (ret.items, 0..) |item, i| {
                row[i] = try eval.evalExpr(allocator, item.expr, env);
            }

            rows[0] = row;

            if (stmt_txn_open) try stmt_txn.commit();
            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = blk: {
                    const list = std.ArrayList([]const u8).empty;
                    break :blk list;
                },
            };
        }
    }

    // Return empty result if no RETURN clause
    if (stmt_txn_open) try stmt_txn.commit();
    return ExecutionResult{
        .columns = try allocator.alloc([]const u8, 0),
        .rows = try allocator.alloc([]Value, 0),
        .flags = blk: {
            const list = std.ArrayList([]const u8).empty;
            break :blk list;
        },
    };
}

/// Replicate an eligible `MATCH ... DELETE`/`DETACH DELETE` through Raft and
/// return its result. Called ONLY when this node is the cluster leader. THE
/// LEADER resolves the MATCH set to explicit STABLE node ids (+ incident edge
/// ids for DETACH, + explicit edge ids for relationship-targeted DELETE) under
/// the store read it already holds — followers NEVER re-run the MATCH. The
/// resolved id set is serialized into a GDEL payload, proposed to the Raft log
/// (never deleted locally — the apply callback deletes on every node, leader
/// included), and `waitForApplied` blocks until quorum-commit lands locally.
///
/// GQL plain-DELETE semantics are validated BEFORE proposing: a non-DETACH
/// delete of a node that still has incident edges returns `error.NodeHasEdges`
/// (mirroring the local path) and nothing is proposed.
///
/// Returns `error.ClusterWriteNotReplicable` for any shape outside the slice (no
/// MATCH clause / item-only delete relying on cross-statement bindings, or a
/// resolved id set larger than the GDEL cap), so the write fails closed instead
/// of being applied leader-local.
// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-DELETE; FEATURE="DistributedCluster"; ASPECT=LeaderProposeDelete; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-09
fn clusterReplicateDelete(
    allocator: std.mem.Allocator,
    d: ast.DeleteStatement,
    current_graph: ?[]const u8,
    context: ExecutionContext,
) !ExecutionResult {
    const coord = cluster_mod.getGlobalClusterCoordinator() orelse return error.ClusterWriteNotReplicable;

    // Only a MATCH-clause delete is replicable in this slice. An item-only delete
    // (`DELETE n` resolved from a preceding statement's bindings) cannot be
    // resolved deterministically across nodes here — fail closed.
    const match_pattern = d.match_clause orelse return error.ClusterWriteNotReplicable;

    const read_store = graph_store.getWritableGlobalStore(allocator);
    const filter_graph = current_graph orelse "default";
    // GAP-0840: strict mode rejects an unscoped/"default" tenant scope here. The
    // resolved value is no longer read directly (the match path applies the same
    // tenant scope for us) — the call is kept for its fail-closed rejection.
    _ = try tenantFilterFromContext(context);

    // ENG-3913: resolve the target set through the SAME matching path the
    // standalone executor uses, so the ids replicated to followers are the ids
    // a `RETURN` of the delete variables would have projected (parameters,
    // cross-variable predicates, relationship hops and a relationship WHERE all
    // honoured). Previously this mirrored the hand-rolled reconstruction and so
    // replicated an OVER-BROAD delete set to every node in the cluster.
    const targets = try resolveDeleteTargets(allocator, d, match_pattern, context);
    defer targets.deinit(allocator);

    // Resolved, deduplicated id sets to encode into the GDEL payload.
    var node_ids = std.ArrayList(u64).empty;
    defer node_ids.deinit(allocator);
    var edge_ids = std.ArrayList(u64).empty;
    defer edge_ids.deinit(allocator);

    try node_ids.appendSlice(allocator, targets.node_ids);
    for (targets.edge_ids) |eid| try appendUniqueId(allocator, &edge_ids, eid);

    // GQL plain-DELETE validation: a node that still has incident edges errors
    // (mirror the local path) BEFORE proposing anything. DETACH collects the
    // incident edges instead.
    // ENG-3983: the CHECKED adjacency readers. An unreadable adjacency laundered
    // into "no incident edges" would replicate a GDEL payload that drops the
    // node but keeps its edges — the same dangling-edge corruption as the
    // standalone path, propagated to EVERY node in the cluster. Fail closed.
    for (node_ids.items) |node_id| {
        if (d.detach) {
            for (try read_store.getOutgoingEdgeIdsChecked(node_id)) |eid| try appendUniqueId(allocator, &edge_ids, eid);
            for (try read_store.getIncomingEdgeIdsChecked(node_id)) |eid| try appendUniqueId(allocator, &edge_ids, eid);
        } else {
            const has_outgoing = (try read_store.getOutgoingEdgeIdsChecked(node_id)).len > 0;
            const has_incoming = (try read_store.getIncomingEdgeIdsChecked(node_id)).len > 0;
            if (has_outgoing or has_incoming) return error.NodeHasEdges;
        }
    }

    // Bounds: refuse to propose a payload larger than the GDEL cap (fail-closed).
    if (node_ids.items.len > cluster_replication.MAX_DELETE_IDS or
        edge_ids.items.len > cluster_replication.MAX_DELETE_IDS)
        return error.ClusterWriteNotReplicable;

    const deleted_count = node_ids.items.len + edge_ids.items.len;

    const payload = cluster_replication.serializeDelete(
        allocator,
        filter_graph,
        edge_ids.items,
        node_ids.items,
    ) catch |err| switch (err) {
        cluster_replication.CodecError.UnsupportedPropertyType,
        cluster_replication.CodecError.CorruptPayload,
        => return error.ClusterWriteNotReplicable,
        else => return err,
    };
    defer allocator.free(payload); // proposeCommand serializes a copy; safe to free after.

    const cmd = raft_consensus.Command{ .graph_mutation = .{
        .graph = filter_graph,
        .mutation_type = .delete,
        .data = payload,
        .txn_id = null,
    } };
    const idx = coord.proposeWrite(cmd) catch |err| switch (err) {
        error.NotLeader => return error.ClusterNotLeader,
        else => return err,
    };
    // Commit-aware wait (RC-1, 2026-06-12): success on confirmed COMMIT (apply is
    // then guaranteed); error.Timeout only when commit cannot be confirmed in
    // budget — never for a committed-but-apply-lagged entry.
    try coord.waitForCommittedThenApplied(idx, 5000);

    // RETURN clause: mirror the local path's "deleted_count" projection.
    if (d.return_clause) |_| {
        var columns = try allocator.alloc([]const u8, 1);
        columns[0] = try allocator.dupe(u8, "deleted_count");
        var rows = try allocator.alloc([]Value, 1);
        var row = try allocator.alloc(Value, 1);
        row[0] = Value{ .Int = @intCast(deleted_count) };
        rows[0] = row;
        return ExecutionResult{
            .columns = columns,
            .rows = rows,
            .flags = std.ArrayList([]const u8).empty,
        };
    }

    return ExecutionResult{
        .columns = try allocator.alloc([]const u8, 0),
        .rows = try allocator.alloc([]Value, 0),
        .flags = std.ArrayList([]const u8).empty,
    };
}

/// Replicate an eligible `MATCH (n:Label [{props}]) [WHERE …] SET …/REMOVE …`
/// through Raft. Called ONLY when this node is the cluster leader.
///
/// THE SILENT-DIVERGENCE FIX: at HEAD this path mutated the leader's local store
/// directly and never proposed anything (followers kept the old value). Here the
/// LEADER resolves the MATCH set to explicit STABLE node ids AND evaluates the
/// SET expressions to CONCRETE scalar values (binding the matched node, so
/// `n.v + 1` is computed on the leader's value), then ships a GUPD payload.
/// Followers NEVER re-MATCH and NEVER re-evaluate an expression — they apply the
/// concrete per-node (set, remove, add-label, remove-label) tuples by id.
///
/// Scope (fail-closed for anything else, so the write never lands leader-local):
///   * single-chain, single head-node MATCH (no relationship hops / multi-chain),
///   * SET n.prop = <scalar-expr> / SET n:Label / REMOVE n.prop / REMOVE n:Label
///     all targeting the matched node variable,
///   * `SET n = {map}` (AllProperties) is OUT of this slice → fail closed,
///   * a RETURN that projects matched data is not resolvable pre-commit → fail closed,
///   * a resolved set larger than the GUPD cap → fail closed.
///
/// Returns `error.ClusterWriteNotReplicable` for any shape outside the slice.
// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MATCH-SET; FEATURE="DistributedCluster"; ASPECT=LeaderProposeUpdate; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-09
fn clusterReplicateMatchSet(
    allocator: std.mem.Allocator,
    q: ast.Query,
    current_graph: ?[]const u8,
    context: ExecutionContext,
) !ExecutionResult {
    const coord = cluster_mod.getGlobalClusterCoordinator() orelse return error.ClusterWriteNotReplicable;

    // A RETURN that projects matched data is not resolvable pre-commit (the read
    // races the not-yet-applied write); fail closed for this slice.
    if (q.ret.items.len > 0) return error.ClusterWriteNotReplicable;

    // A WITH projection / FILTER / GROUP BY layered onto the update is out of this
    // slice (its post-MATCH transform is not modeled by the GUPD outcome) — fail
    // closed rather than silently dropping it.
    if (q.with_clause != null or q.filter_clause != null) return error.ClusterWriteNotReplicable;

    // Only a single-chain, single head-node MATCH is replicable here. A
    // relationship/edge-property SET (`MATCH ()-[r]->() SET r.x = 1`) or a
    // multi-chain MATCH resolves bindings outside this slice — fail closed.
    if (q.match.chains.len != 1) return error.ClusterWriteNotReplicable;
    const chain = q.match.chains[0];
    if (chain.hops.len != 0) return error.ClusterWriteNotReplicable;
    const node_pattern = chain.head orelse return error.ClusterWriteNotReplicable;
    const match_var = node_pattern.name orelse return error.ClusterWriteNotReplicable;

    // Every SET/REMOVE clause must target the matched node variable and be a
    // replicable form. Validate up front so we fail closed BEFORE touching Raft.
    for (q.set_clauses) |sc| {
        switch (sc) {
            .Property => |prop| if (!std.mem.eql(u8, prop.target.object, match_var))
                return error.ClusterWriteNotReplicable,
            .Labels => |ls| if (!std.mem.eql(u8, ls.node, match_var))
                return error.ClusterWriteNotReplicable,
            // SET n = {map} replaces ALL props (non-scalar shape) — out of slice.
            .AllProperties => return error.ClusterWriteNotReplicable,
        }
    }
    for (q.remove_clauses) |rc| {
        switch (rc) {
            .Property => |prop| if (!std.mem.eql(u8, prop.object, match_var))
                return error.ClusterWriteNotReplicable,
            .Labels => |ls| if (!std.mem.eql(u8, ls.node, match_var))
                return error.ClusterWriteNotReplicable,
        }
    }

    const read_store = graph_store.getWritableGlobalStore(allocator);
    const filter_graph = current_graph orelse "default";
    const filter_tenant = try tenantFilterFromContext(context);

    // Resolve the MATCH set to stable candidate ids (tenant-honored, GAP-0840).
    var match_prop_arena = std.heap.ArenaAllocator.init(allocator);
    defer match_prop_arena.deinit();
    const evaluated_match_props = evaluatePatternProps(match_prop_arena.allocator(), node_pattern.props, context) catch
        return error.ClusterWriteNotReplicable;

    const candidate_ids = try collectCandidateNodeIds(
        allocator,
        read_store,
        filter_graph,
        filter_tenant,
        node_pattern.labels,
        evaluated_match_props,
    );
    defer allocator.free(candidate_ids);

    var updates = std.ArrayList(cluster_replication.NodeUpdate).empty;
    // Each NodeUpdate owns four heap slices allocated from `allocator`; free them
    // (plus the outer list) on every exit path — `allocator` is not assumed to be
    // an arena. The Prop.value scalars and the label/prop key slices are borrowed
    // (AST-owned or store-owned), so only the OUTER slices are freed.
    defer {
        for (updates.items) |u| {
            allocator.free(u.set_props);
            allocator.free(u.remove_props);
            allocator.free(u.add_labels);
            allocator.free(u.remove_labels);
        }
        updates.deinit(allocator);
    }

    for (candidate_ids) |node_id| {
        // SONNY-1841: the leader's SET/REMOVE candidate loop (an alternate,
        // distributed write executor) can iterate a large match set — poll
        // cancellation here so an abandoned mutation aborts before proposing.
        try write_budget.check();
        const node = (read_store.nodes.getOrHydratePtr(node_id) catch null) orelse continue;
        if (!nodeMatchesPattern(node, filter_graph, filter_tenant, node_pattern.labels, evaluated_match_props)) continue;

        // Bind the matched node so SET expressions (`n.v + 1`, `n.k`) evaluate on
        // THIS leader's concrete value — followers never re-evaluate.
        var names = [_][]const u8{match_var};
        var values = [_]Value{Value{ .Node = node }};
        const env = Env{
            .allocator = allocator,
            .names = &names,
            .values = &values,
            .param_names = context.query_param_names,
            .param_values = context.query_param_values,
        };

        if (q.where_clause) |where_expr| {
            const where_result = eval.evalExpr(allocator, where_expr, env) catch
                return error.ClusterWriteNotReplicable;
            const keep = switch (where_result) {
                .Bool => |b| b,
                else => false,
            };
            if (!keep) continue;
        }

        var set_props = std.ArrayList(cluster_replication.Prop).empty;
        errdefer set_props.deinit(allocator);
        var remove_props = std.ArrayList([]const u8).empty;
        errdefer remove_props.deinit(allocator);
        var add_labels = std.ArrayList([]const u8).empty;
        errdefer add_labels.deinit(allocator);
        var remove_labels = std.ArrayList([]const u8).empty;
        errdefer remove_labels.deinit(allocator);

        for (q.set_clauses) |sc| {
            switch (sc) {
                .Property => |prop| {
                    const val = eval.evalExpr(allocator, prop.value, env) catch
                        return error.ClusterWriteNotReplicable;
                    // Statement-atomicity pre-pass: refuse before PROPOSING.
                    // CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=ClusterSetPrePass; STATUS=IMPL; OWNER=engine; UPDATED=2026-08-25
                    try write_precheck.checkPropertyWritable(allocator, &.{}, prop.target.property, val);
                    const pv = clusterPropValue(val) orelse return error.ClusterWriteNotReplicable;
                    try set_props.append(allocator, .{ .key = prop.target.property, .value = pv });
                },
                .Labels => |ls| {
                    for (ls.labels) |label| try add_labels.append(allocator, label);
                },
                .AllProperties => unreachable, // rejected in the validation pass above
            }
        }
        for (q.remove_clauses) |rc| {
            switch (rc) {
                .Property => |prop| try remove_props.append(allocator, prop.property),
                .Labels => |ls| {
                    for (ls.labels) |label| try remove_labels.append(allocator, label);
                },
            }
        }

        // Detach the four owned slices, then append. If `append` OOMs, free the
        // just-detached slices so nothing leaks (the errdefers above no longer
        // cover them — the ArrayLists are now empty).
        const owned_set = try set_props.toOwnedSlice(allocator);
        errdefer allocator.free(owned_set);
        const owned_remove = try remove_props.toOwnedSlice(allocator);
        errdefer allocator.free(owned_remove);
        const owned_add = try add_labels.toOwnedSlice(allocator);
        errdefer allocator.free(owned_add);
        const owned_rem_labels = try remove_labels.toOwnedSlice(allocator);
        errdefer allocator.free(owned_rem_labels);

        try updates.append(allocator, .{
            .node_id = node_id,
            .set_props = owned_set,
            .remove_props = owned_remove,
            .add_labels = owned_add,
            .remove_labels = owned_rem_labels,
        });
    }

    // Bounds: refuse to propose a payload larger than the GUPD cap (fail-closed).
    if (updates.items.len > cluster_replication.MAX_UPDATE_NODES)
        return error.ClusterWriteNotReplicable;

    const empty_result = ExecutionResult{
        .columns = try allocator.alloc([]const u8, 0),
        .rows = try allocator.alloc([]Value, 0),
        .flags = std.ArrayList([]const u8).empty,
    };

    // Nothing matched → semantically a no-op; short-circuit WITHOUT proposing.
    if (updates.items.len == 0) return empty_result;

    const payload = cluster_replication.serializeUpdate(allocator, filter_graph, updates.items) catch |err| switch (err) {
        cluster_replication.CodecError.UnsupportedPropertyType,
        cluster_replication.CodecError.CorruptPayload,
        => return error.ClusterWriteNotReplicable,
        else => return err,
    };
    defer allocator.free(payload); // proposeCommand serializes a copy; safe to free after.

    const cmd = raft_consensus.Command{ .graph_mutation = .{
        .graph = filter_graph,
        .mutation_type = .update,
        .data = payload,
        .txn_id = null,
    } };
    const idx = coord.proposeWrite(cmd) catch |err| switch (err) {
        error.NotLeader => return error.ClusterNotLeader,
        else => return err,
    };
    // Commit-aware wait (RC-1, 2026-06-12): success on confirmed COMMIT (apply is
    // then guaranteed); error.Timeout only when commit cannot be confirmed in
    // budget — never for a committed-but-apply-lagged entry.
    try coord.waitForCommittedThenApplied(idx, 5000);

    return empty_result;
}

/// Cluster write routing for a bare `MATCH … SET/REMOVE` query (no CREATE / MERGE
/// / DELETE keyword). Returns `null` in standalone (no coordinator) mode so the
/// dispatcher takes the unchanged local MATCH path. On the leader it replicates
/// the update through Raft (or fails closed). On a follower it rejects the write
/// (error.ClusterNotLeader — clients retry the leader). THIS CLOSES THE SILENT
/// LEADER-ONLY DIVERGENCE: MATCH…SET/REMOVE was previously never cluster-gated.
// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MATCH-SET; FEATURE="DistributedCluster"; ASPECT=ExecutorRouteUpdate; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-09
pub fn executeClusterMatchUpdateIfNeeded(
    allocator: std.mem.Allocator,
    q: ast.Query,
    current_graph: ?[]const u8,
    context: ExecutionContext,
) !?ExecutionResult {
    switch (try clusterWriteRole()) {
        .standalone => return null,
        .leader => return try clusterReplicateMatchSet(allocator, q, current_graph, context),
    }
}

/// Empty (no columns / no rows) ExecutionResult — the success shape for a
/// replicated or no-op cluster write. Allocated fresh per call so each early
/// exit owns its result independently; fail-closed error paths never construct
/// one (nothing to leak).
fn emptyExecutionResult(allocator: std.mem.Allocator) !ExecutionResult {
    return ExecutionResult{
        .columns = try allocator.alloc([]const u8, 0),
        .rows = try allocator.alloc([]Value, 0),
        .flags = std.ArrayList([]const u8).empty,
    };
}

/// Replicate an eligible `MATCH (a:L {p}),(b:M {q}) CREATE (a)-[:R {props}]->(b)`
/// through Raft as a GNC2 multi-create with ZERO new nodes and `absolute_id`
/// endpoints. Called ONLY when this node is the cluster leader. The create is
/// proposed to the Raft log (never written locally) and applied
/// deterministically on every node.
///
/// THE SILENT-DIVERGENCE FIX (2026-06-04 bug doc §MATCH…CREATE): at HEAD this
/// shape reached the local edge-create path with no clusterWriteRole() gate on
/// EVERY node — leader-local and follower-local edges, never proposed through
/// Raft. Here the LEADER resolves each MATCH variable to exactly ONE stable
/// node id (tenant-honored, GAP-0840) and ships explicit endpoint ids;
/// followers never re-MATCH.
///
/// Scope (`error.ClusterWriteNotReplicable` for anything else, fail-closed):
///   * every MATCH chain: head-only (no hops), named variable,
///   * each variable resolves to EXACTLY one node (0 → no-op; >1 → fail closed),
///   * CREATE endpoints are pure var refs (no labels/props on endpoint patterns),
///   * no RETURN / WITH / FILTER / SET / REMOVE / DELETE attached,
///   * scalar edge props only; ≤ MAX_MULTI_EDGES edges; no variable-length hops.
// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MATCH-CREATE; FEATURE="DistributedCluster"; ASPECT=LeaderProposeMatchCreate; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-10
fn clusterReplicateMatchCreate(
    allocator: std.mem.Allocator,
    q: ast.Query,
    current_graph: ?[]const u8,
    context: ExecutionContext,
) !ExecutionResult {
    const coord = cluster_mod.getGlobalClusterCoordinator() orelse return error.ClusterWriteNotReplicable;

    // Attached clauses whose semantics this slice does not model → fail closed.
    if (q.ret.items.len > 0) return error.ClusterWriteNotReplicable;
    if (q.with_clause != null or q.filter_clause != null) return error.ClusterWriteNotReplicable;
    if (q.set_clauses.len > 0 or q.remove_clauses.len > 0) return error.ClusterWriteNotReplicable;
    if (q.delete_items.len > 0) return error.ClusterWriteNotReplicable;
    // A MATCH…CREATE without a CREATE pattern is malformed for this slice —
    // fail closed up front (NOT after MATCH resolution, where a zero-match
    // chain would silently no-op instead).
    const create_pattern = q.create_pattern orelse return error.ClusterWriteNotReplicable;

    const read_store = graph_store.getWritableGlobalStore(allocator);
    const filter_graph = current_graph orelse "default";
    const filter_tenant = try tenantFilterFromContext(context);

    // Resolve every MATCH variable to exactly one stable node id (tenant-honored).
    var var_names = std.ArrayList([]const u8).empty;
    defer var_names.deinit(allocator);
    var var_nodes = std.ArrayList(Value).empty; // .Node values for the WHERE/prop Env
    defer var_nodes.deinit(allocator);
    var var_ids = std.StringHashMap(u64).init(allocator);
    defer var_ids.deinit();

    for (q.match.chains) |chain| {
        if (chain.hops.len != 0) return error.ClusterWriteNotReplicable;
        const node_pattern = chain.head orelse return error.ClusterWriteNotReplicable;
        const match_var = node_pattern.name orelse return error.ClusterWriteNotReplicable;

        var prop_arena = std.heap.ArenaAllocator.init(allocator);
        defer prop_arena.deinit();
        const evaluated_props = evaluatePatternProps(prop_arena.allocator(), node_pattern.props, context) catch
            return error.ClusterWriteNotReplicable;

        const candidate_ids = try collectCandidateNodeIds(
            allocator,
            read_store,
            filter_graph,
            filter_tenant,
            node_pattern.labels,
            evaluated_props,
        );
        defer allocator.free(candidate_ids);

        var resolved: ?u64 = null;
        for (candidate_ids) |node_id| {
            const node = (read_store.nodes.getOrHydratePtr(node_id) catch null) orelse continue;
            if (!nodeMatchesPattern(node, filter_graph, filter_tenant, node_pattern.labels, evaluated_props)) continue;
            // Ambiguous (>1 match) → a Cartesian-product CREATE is out of this
            // slice; fail closed BEFORE touching Raft.
            if (resolved != null) return error.ClusterWriteNotReplicable;
            resolved = node_id;
        }
        const rid = resolved orelse {
            // Nothing matched → semantically a no-op; short-circuit WITHOUT proposing.
            return try emptyExecutionResult(allocator);
        };
        // Duplicate MATCH variable names would make the Env lookup (first
        // binding wins) disagree with endpoint resolution (last put wins) —
        // out of this slice, fail closed.
        if (var_ids.contains(match_var)) return error.ClusterWriteNotReplicable;
        try var_names.append(allocator, match_var);
        try var_nodes.append(allocator, Value{ .Node = ((read_store.nodes.getOrHydratePtr(rid) catch null).?) });
        try var_ids.put(match_var, rid);
    }

    // Bind every matched node so WHERE / edge-prop expressions evaluate on THIS
    // leader's concrete values — followers never re-evaluate.
    const env = Env{
        .allocator = allocator,
        .names = var_names.items,
        .values = var_nodes.items,
        .param_names = context.query_param_names,
        .param_values = context.query_param_values,
    };

    if (q.where_clause) |where_expr| {
        const where_result = eval.evalExpr(allocator, where_expr, env) catch
            return error.ClusterWriteNotReplicable;
        const keep = switch (where_result) {
            .Bool => |b| b,
            else => false,
        };
        if (!keep) return try emptyExecutionResult(allocator);
    }

    // Build edge specs from the CREATE pattern: endpoints must be pure refs to
    // matched vars (no labels, no props) → `.absolute_id`. Each EdgeSpec owns
    // one heap props slice off `allocator` (not assumed to be an arena); free
    // them on every exit path. Prop keys/string values are borrowed (AST- or
    // eval-owned), so only the OUTER slices are freed — same discipline as
    // clusterReplicateMatchSet.
    var edge_specs = std.ArrayList(cluster_replication.EdgeSpec).empty;
    defer {
        for (edge_specs.items) |es| if (es.props.len > 0) allocator.free(es.props);
        edge_specs.deinit(allocator);
    }

    for (create_pattern.chains) |cchain| {
        // A bare node CREATE after MATCH is out of this slice — fail closed.
        if (cchain.hops.len == 0) return error.ClusterWriteNotReplicable;
        for (cchain.hops) |hop| {
            // Variable-length / quantified hops are not replicable in this slice.
            if (hop.rel.min_len != null or hop.rel.max_len != null)
                return error.ClusterWriteNotReplicable;

            const EndpointOf = struct {
                fn run(np: ast.NodePattern, ids: *const std.StringHashMap(u64)) error{ClusterWriteNotReplicable}!u64 {
                    const nm = np.name orelse return error.ClusterWriteNotReplicable;
                    if (np.labels.len != 0) return error.ClusterWriteNotReplicable;
                    if (np.props != null and np.props.?.len != 0) return error.ClusterWriteNotReplicable;
                    return ids.get(nm) orelse error.ClusterWriteNotReplicable;
                }
            };
            const left_id = try EndpointOf.run(hop.left, &var_ids);
            const right_id = try EndpointOf.run(hop.right, &var_ids);

            // Direction: store edges are directed left->right. `.left` reverses
            // the endpoints; `.undirected` is stored left->right (matching treats
            // it as a directionless adjacency). Same as buildEdgeCreateSpecs.
            const from_id = if (hop.rel.dir == .left) right_id else left_id;
            const to_id = if (hop.rel.dir == .left) left_id else right_id;

            // Bounds: refuse to propose a payload larger than the GNC2 cap.
            // Checked BEFORE constructing/appending the spec so every exit
            // path leaves exactly one owner of the props slice (a post-append
            // check would double-free: the function-level defer frees the
            // appended es.props while the loop-body errdefer was still live).
            if (edge_specs.items.len == cluster_replication.MAX_MULTI_EDGES)
                return error.ClusterWriteNotReplicable;

            // Scalar edge props, evaluated on the leader (matched vars bound).
            var eprops: []cluster_replication.Prop = &.{};
            if (hop.rel.props) |plist| {
                const out = try allocator.alloc(cluster_replication.Prop, plist.len);
                errdefer allocator.free(out);
                for (plist, 0..) |p, i| {
                    const val = eval.evalExpr(allocator, p.value.*, env) catch
                        return error.ClusterWriteNotReplicable;
                    const pv = clusterPropValue(val) orelse return error.ClusterWriteNotReplicable;
                    out[i] = .{ .key = p.key, .value = pv };
                }
                eprops = out;
            }
            errdefer if (eprops.len > 0) allocator.free(eprops);

            const rel_type = if (hop.rel.types.len > 0) hop.rel.types[0] else "RELATES_TO";
            try edge_specs.append(allocator, .{
                .from = .{ .absolute_id = from_id },
                .to = .{ .absolute_id = to_id },
                .edge_type = rel_type,
                .props = eprops,
            });
        }
    }
    if (edge_specs.items.len == 0) return error.ClusterWriteNotReplicable;

    // RC-3 (2026-06-12): carry an idempotency key so a retried MATCH…CREATE edge
    // dedups at apply time (no duplicate edge). Client key from the request, else
    // leader-generated.
    var idem_buf: [32]u8 = undefined;
    const idem_key = effectiveIdempotencyKey(&idem_buf);
    const payload = cluster_replication.serializeMultiCreateKeyed(
        allocator,
        filter_graph,
        &.{},
        edge_specs.items,
        idem_key,
    ) catch |err| switch (err) {
        cluster_replication.CodecError.UnsupportedPropertyType,
        cluster_replication.CodecError.CorruptPayload,
        => return error.ClusterWriteNotReplicable,
        else => return err,
    };
    defer allocator.free(payload); // proposeCommand serializes a copy; safe to free after.

    const cmd = raft_consensus.Command{ .graph_mutation = .{
        .graph = filter_graph,
        .mutation_type = .create,
        .data = payload,
        .txn_id = null,
    } };
    const idx = coord.proposeWrite(cmd) catch |err| switch (err) {
        // Lost leadership between the role check and the propose — fail closed.
        error.NotLeader => return error.ClusterNotLeader,
        else => return err,
    };
    // Commit-aware wait (RC-1, 2026-06-12): success on confirmed COMMIT (apply is
    // then guaranteed); error.Timeout only when commit cannot be confirmed in
    // budget — never for a committed-but-apply-lagged entry.
    try coord.waitForCommittedThenApplied(idx, 5000);

    return try emptyExecutionResult(allocator);
}

/// Cluster write routing for a `MATCH … CREATE …` query. Returns `null` in
/// standalone (no coordinator) mode so the dispatcher takes the unchanged local
/// MATCH…CREATE path. On the leader it replicates the create through Raft (or
/// fails closed). On a follower it rejects the write (error.ClusterNotLeader —
/// clients retry the leader). THIS CLOSES THE 2026-06-04 SILENT-DIVERGENCE
/// HOLE: MATCH…CREATE edge writes were previously never cluster-gated.
// CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-MATCH-CREATE; FEATURE="DistributedCluster"; ASPECT=ExecutorRouteMatchCreate; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-10
pub fn executeClusterMatchCreateIfNeeded(
    allocator: std.mem.Allocator,
    q: ast.Query,
    current_graph: ?[]const u8,
    context: ExecutionContext,
) !?ExecutionResult {
    switch (try clusterWriteRole()) {
        .standalone => return null,
        .leader => return try clusterReplicateMatchCreate(allocator, q, current_graph, context),
    }
}

/// SONNY-2694: delete one statement's resolved nodes, then its resolved edges,
/// and return how many were deleted (`executeDelete`, and a DELETE after a SET
/// or REMOVE, `executeMatchDeleteQuery`). A node that still has an edge refuses
/// the whole statement, before anything is deleted, unless `detach`, which
/// deletes its edges with it. Called with the graph's write lock held.
pub fn deleteElements(allocator: std.mem.Allocator, node_ids: []const u64, edge_ids: []const u64, detach: bool, current_graph: ?[]const u8) !usize {
    const store = graph_store.getWritableGlobalStore(allocator);
    // GAP-0511: DELETE stages IDs before mutating, so cloning a QueryReadSession
    // adds O(total graph size) overhead without improving correctness under the
    // graph write lock.
    const read_store: *graph_store.GraphStore = store;
    var deleted_count: usize = 0;

    if (!detach) {
        for (node_ids) |node_id| {
            // ENG-3983: the CHECKED readers — an unreadable adjacency must
            // NOT be mistaken for "this node has no edges" and let a plain
            // DELETE through the GQL edge guard.
            const has_outgoing = (try read_store.getOutgoingEdgeIdsChecked(node_id)).len > 0;
            const has_incoming = (try read_store.getIncomingEdgeIdsChecked(node_id)).len > 0;
            if (has_outgoing or has_incoming) {
                return error.NodeHasEdges;
            }
        }
    }

    // ENG-3983: edge ids removed as incident edges of a DETACH'd node in THIS
    // statement. The relationship loop below needs them to tell "already
    // deleted here" (fine) apart from "resolved by the MATCH but its body
    // cannot be read back" (a silent no-op — fail closed instead).
    var detached_edge_ids = std.ArrayList(u64).empty;
    defer detached_edge_ids.deinit(allocator);

    // Delete the resolved nodes
    for (node_ids) |node_id| {
        // SONNY-1841: poll cancellation BETWEEN node deletes — an abandoned
        // DETACH DELETE over a large match set must release the write lock
        // promptly, not run to the deadline (no-op without a write scope).
        try write_budget.check();
        // A4b: drop the node's fulltext postings BEFORE the store delete,
        // while its labels are still readable (covering-index lookup is
        // keyed by label). Runs on the executor/connection thread
        // (executeDelete is never invoked from bulkMergeNode / worker
        // threads — verified). Cheap-exits when no FTS index covers the
        // labels. Graph passed explicitly from current_graph.
        if ((read_store.nodes.getOrHydratePtr(node_id) catch null)) |node_ptr| {
            fts_index_ops.maintainFulltextOnWrite(allocator, current_graph, node_id, node_ptr.labels, .delete) catch |err| {
                log.warn("fts maintain (DELETE) failed", &.{
                    Attr.uint("node_id", node_id),
                    Attr.string("error", @errorName(err)),
                });
            };
        }

        if (detach) {
            // P8: Use adjacency indexes instead of full edge scan.
            // Collect edge IDs first since deleteEdgeNoSave mutates the
            // adjacency lists whose slices we are reading.
            var edges_to_delete = std.ArrayList(u64).empty;
            defer edges_to_delete.deinit(allocator);
            // ENG-3983: CHECKED reads — an adjacency the engine cannot serve
            // must abort the DETACH, never be read as "no incident edges"
            // (which deletes the node and orphans every one of them).
            for (try read_store.getOutgoingEdgeIdsChecked(node_id)) |eid| {
                try edges_to_delete.append(allocator, eid);
            }
            for (try read_store.getIncomingEdgeIdsChecked(node_id)) |eid| {
                // Avoid duplicating self-loop edges already collected above
                var already = false;
                for (edges_to_delete.items) |existing| {
                    if (existing == eid) {
                        already = true;
                        break;
                    }
                }
                if (!already) {
                    try edges_to_delete.append(allocator, eid);
                }
            }
            for (edges_to_delete.items) |edge_id| {
                // SONNY-1841: a high-degree DETACH can spin here for a long
                // time — poll cancellation between incident-edge deletes.
                try write_budget.check();
                // ENG-3983: an incident edge whose body cannot be resolved
                // cannot be durably deleted (`deleteEdge` needs its endpoint
                // + edge slots), so proceeding would leave it DANGLING once
                // the node goes. Refuse the whole DETACH instead.
                if (store.getEdgePtr(edge_id) == null) return error.IncidentEdgeUnresolvable;
                store.deleteEdge(edge_id);
                try detached_edge_ids.append(allocator, edge_id);
            }
        }
        store.deleteNode(node_id);
        if (store.getNodePtr(node_id) == null) {
            deleted_count += 1;
        }
    }

    // GAP #56: relationship-targeted DELETE. The ids come from the same
    // resolved match set, so a WHERE over the relationship variable is
    // honoured here exactly as it is for nodes.
    for (edge_ids) |edge_id| {
        // SONNY-1841: poll cancellation between edge deletes too.
        try write_budget.check();
        if (store.getEdgePtr(edge_id) == null) {
            // Already gone (removed as an incident edge of a DETACH'd node
            // above) — do not double-count it.
            var already_detached = false;
            for (detached_edge_ids.items) |done| {
                if (done == edge_id) {
                    already_detached = true;
                    break;
                }
            }
            if (already_detached) continue;
            // ENG-3983: the MATCH resolved this edge id, so the row is NOT
            // an honestly-empty match — the body simply cannot be read back,
            // and `deleteEdge` would be a silent no-op. Fail closed rather
            // than report success for a delete that did not happen. (An
            // empty match resolves zero edge ids and never reaches here, so
            // `MATCH … DELETE r` over no rows stays a successful 00000.)
            return error.EdgeBodyUnresolvable;
        }
        store.deleteEdge(edge_id);
        if (store.getEdgePtr(edge_id) == null) {
            deleted_count += 1;
        }
    }

    return deleted_count;
}

// CANARY: REQ=REQ-SONNY-2694-MATCH-SET-DELETE; FEATURE="WriteBehindAggregate"; ASPECT=QueryDelete; STATUS=TESTED; TEST=tests/test_sonny2694_write_behind_aggregate.zig; OWNER=engine; UPDATED=2026-09-27
/// SONNY-2694: a DELETE the parser keeps in a query, `MATCH ... SET ...
/// DELETE n [RETURN ...]` (a DELETE after a SET or REMOVE; a MATCH ... DELETE
/// without one is a DELETE statement, `executeDelete`). The match executor
/// applied the SET or REMOVE and never the DELETE, so the statement returned
/// its rows and deleted nothing.
///
/// The bindings are read (`readPatternBindings`), which applies the SET and
/// REMOVE to every matched row; the RETURN is computed over them before the
/// DELETE, owning its values (`ownReturnBeforeDelete`); then the nodes and
/// edges the DELETE names in the rows are deleted as a DELETE statement
/// deletes them (`deleteElements`: a node that still has an edge refuses the
/// statement). In a cluster the shape is not replicable and fails closed.
pub fn executeMatchDeleteQuery(
    allocator: std.mem.Allocator,
    q: ast.Query,
    param_names: []const []const u8,
    param_values: []const Value,
    current_graph: ?[]const u8,
) !ExecutionResult {
    // SONNY-2683: refuse a grouped or filtered RETURN before anything is written.
    try match_operations.validateGroupedReturnShape(q);
    switch (try clusterWriteRole()) {
        .standalone => {},
        .leader => return error.ClusterWriteNotReplicable,
    }

    var bindings = try match_operations.readPatternBindings(allocator, q, param_names, param_values, q.inline_let_bindings, current_graph);
    defer bindings.deinit(allocator);
    var deleted = try match_operations.DeletedElements.fromBindings(allocator, q.delete_items, bindings.rows, false);
    defer deleted.deinit(allocator);

    var returned: ?ExecutionResult = null;
    errdefer if (returned) |*r| r.deinit(allocator);
    if (q.ret.items.len != 0) {
        returned = try match_operations.projectReturnOverRows(allocator, q, &bindings.rows, param_names, param_values);
        try match_operations.ownReturnBeforeDelete(allocator, &returned.?, deleted);
    }

    _ = try deleteElements(allocator, deleted.node_ids, deleted.edge_ids, false, current_graph);

    if (returned) |r| return r;
    return emptyExecutionResult(allocator);
}

// CANARY: REQ=REQ-MULTI-GRAPH-DELETE-001; FEATURE="MultiGraphIsolation"; ASPECT=DeleteGraphFilter; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-24
pub fn executeDelete(allocator: std.mem.Allocator, d: ast.DeleteStatement, current_graph: ?[]const u8, context: ExecutionContext) !ExecutionResult {
    // Cluster write routing: in cluster mode the DELETE is ordered through Raft on
    // the leader and never applied to a single node's local store. A follower
    // fails closed (error.ClusterNotLeader — clients retry the leader); the leader
    // resolves the MATCH set to explicit stable ids and replicates them via a GDEL
    // payload, or fails closed for non-replicable shapes.
    // CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-DELETE; FEATURE="DistributedCluster"; ASPECT=ExecutorProposeDelete; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-09
    switch (try clusterWriteRole()) {
        .standalone => {},
        .leader => return clusterReplicateDelete(allocator, d, current_graph, context),
    }

    const store = graph_store.getWritableGlobalStore(allocator);
    // GAP-0511: DELETE stages IDs before mutating, so cloning a QueryReadSession
    // adds O(total graph size) overhead without improving correctness under the
    // graph write lock.
    const read_store: *graph_store.GraphStore = store;
    // GAP-0840: strict mode rejects an unscoped/"default" tenant scope here. The
    // resolved graph/tenant values are no longer read directly — ENG-3913 routes
    // the match-set resolution through the match path, which applies both — but
    // the call is kept for its fail-closed rejection.
    _ = try tenantFilterFromContext(context);

    // Track deleted node count
    var deleted_count: usize = 0;
    // SONNY-2694: the RETURN of a MATCH ... DELETE, computed over the rows the
    // statement matches before it deletes them.
    var returned: ?ExecutionResult = null;
    errdefer if (returned) |*r| r.deinit(allocator);

    // If there's a MATCH clause, delete matching nodes/edges
    if (d.match_clause) |match_pattern| {
        // ENG-3913: resolve the target set through the same matching path a
        // RETURN of these variables would take. See `resolveDeleteTargets` for
        // the four data-loss defects the previous hand-rolled reconstruction
        // carried (no parameter bindings, single-variable Env, hop-blind
        // candidate set, and a relationship branch that ignored WHERE).
        // CANARY: REQ=REQ-DELETE-WHERE-001; FEATURE="DeleteWhereEvaluation"; ASPECT=WhereClause; STATUS=TESTED; TEST=tests/test_eng3913_where_delete.zig; OWNER=crud_operations; UPDATED=2026-08-25
        const targets = try resolveDeleteTargets(allocator, d, match_pattern, context);
        defer targets.deinit(allocator);

        // CANARY: REQ=REQ-SONNY-2694-DELETE-RETURN; FEATURE="WriteBehindAggregate"; ASPECT=DeleteReturn; STATUS=TESTED; TEST=tests/test_sonny2694_write_behind_aggregate.zig; OWNER=engine; UPDATED=2026-09-27
        // SONNY-2694: the RETURN is the statement's own, over the rows it
        // matches (the same read `resolveDeleteTargets` runs), computed before
        // they are deleted. It returned the number of deleted elements, as
        // `deleted_count`, whatever it asked for: `MATCH (q:Q) DELETE q RETURN
        // sum(q.i)` returned the count. The RETURN owns its values, and one
        // that would hold a deleted element is refused before any delete.
        if (d.return_clause) |rc| if (rc.items.len != 0) {
            returned = try execution.executeQueryWithContext(allocator, .{
                .optional_match = false,
                .match = match_pattern,
                .where_clause = d.where_clause,
                .with_clause = null,
                .ret = rc,
                .order_by = null,
                .limit = null,
                .offset = null,
            }, context);
            try match_operations.ownReturnBeforeDelete(allocator, &returned.?, .{ .node_ids = targets.node_ids, .edge_ids = targets.edge_ids, .detach = d.detach });
        };

        deleted_count = try deleteElements(allocator, targets.node_ids, targets.edge_ids, d.detach, current_graph);

        // Persistence is handled by the background persistence loop (graph_store.zig)
        // which saves dirty graphs every second. No synchronous save needed here.
    } else if (d.items.len > 0) {
        // GAP #56: Delete specific items by variable name.
        // Without a MATCH clause, items refer to variables bound in a preceding
        // MATCH statement (query-level delete_items path). For standalone DELETE
        // statements, attempt to resolve items via context bindings.
        if (context.bindings) |bindings| {
            if (!d.detach) {
                for (d.items) |item| {
                    const var_name = switch (item) {
                        .Variable => |n| n,
                        .Node => |n| n,
                        .Relationship => |n| n,
                    };
                    if (bindings.get(var_name)) |binding| {
                        switch (binding) {
                            .node_id => |nid| {
                                // ENG-3983: CHECKED reads (see the match-clause path above).
                                const has_outgoing = (try read_store.getOutgoingEdgeIdsChecked(nid)).len > 0;
                                const has_incoming = (try read_store.getIncomingEdgeIdsChecked(nid)).len > 0;
                                if (has_outgoing or has_incoming) {
                                    return error.NodeHasEdges;
                                }
                            },
                            .edge_id => {},
                        }
                    }
                }
            }
            for (d.items) |item| {
                const var_name = switch (item) {
                    .Variable => |n| n,
                    .Node => |n| n,
                    .Relationship => |n| n,
                };
                if (bindings.get(var_name)) |binding| {
                    switch (binding) {
                        .node_id => |nid| {
                            if (d.detach) {
                                // P8: DETACH — use adjacency indexes instead of full edge scan.
                                // Collect edge IDs first since deleteEdgeNoSave mutates the
                                // adjacency lists whose slices we are reading.
                                var edges_to_remove = std.ArrayList(u64).empty;
                                defer edges_to_remove.deinit(allocator);
                                // ENG-3983: CHECKED reads — see the match-clause
                                // DETACH path above for why a swallowed hydrate
                                // failure here orphans every incident edge.
                                for (try read_store.getOutgoingEdgeIdsChecked(nid)) |eid| {
                                    try edges_to_remove.append(allocator, eid);
                                }
                                for (try read_store.getIncomingEdgeIdsChecked(nid)) |eid| {
                                    var already = false;
                                    for (edges_to_remove.items) |existing| {
                                        if (existing == eid) {
                                            already = true;
                                            break;
                                        }
                                    }
                                    if (!already) {
                                        try edges_to_remove.append(allocator, eid);
                                    }
                                }
                                for (edges_to_remove.items) |eid| {
                                    if (store.getEdgePtr(eid) == null) return error.IncidentEdgeUnresolvable;
                                    store.deleteEdge(eid);
                                }
                            }
                            store.deleteNode(nid);
                            if (store.getNodePtr(nid) == null) {
                                deleted_count += 1;
                            }
                        },
                        .edge_id => |eid| {
                            if (store.getEdgePtr(eid) != null) {
                                store.deleteEdge(eid);
                            }
                            if (store.getEdgePtr(eid) == null) {
                                deleted_count += 1;
                            }
                        },
                    }
                }
            }
            // Persistence is handled by the background persistence loop (graph_store.zig)
            // which saves dirty graphs every second. No synchronous save needed here.
        }
    }

    // Note: The global store persists changes automatically

    if (returned) |r| return r;

    // Handle RETURN clause if present (a DELETE without a MATCH: the count of
    // the elements it deleted)
    if (d.return_clause) |_| {
        var columns = try allocator.alloc([]const u8, 1);
        columns[0] = try allocator.dupe(u8, "deleted_count");

        var rows = try allocator.alloc([]Value, 1);
        var row = try allocator.alloc(Value, 1);
        row[0] = Value{ .Int = @intCast(deleted_count) };
        rows[0] = row;

        return ExecutionResult{
            .columns = columns,
            .rows = rows,
            .flags = blk: {
                const list = std.ArrayList([]const u8).empty;
                break :blk list;
            },
        };
    }

    // Return empty result if no RETURN clause
    return ExecutionResult{
        .columns = try allocator.alloc([]const u8, 0),
        .rows = try allocator.alloc([]Value, 0),
        .flags = blk: {
            const list = std.ArrayList([]const u8).empty;
            break :blk list;
        },
    };
}

// Execute MATCH + CALL pattern with node binding
