const std = @import("std");
const gs = @import("graph_storage");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const statement_undo = @import("../statement_undo.zig");
const execution = @import("../execution.zig");
const write_walk = @import("write_walk.zig");
const result_utils = @import("result_utils.zig");
const value_utilities = @import("value_utilities.zig");
const graph_store = @import("../graph_store.zig");
const graph_storage_adapter = @import("../storage/graph_storage_adapter.zig");
const stored_property_equality = @import("stored_property_equality.zig");
const distinct_set = @import("distinct_set.zig");
const property_codec = @import("../property_value_codec.zig");
const value_types = @import("../value_types.zig");
const query_arena = @import("../server/query_arena.zig");
const pattern_helpers = @import("pattern_helpers.zig");
// GAP-0846: shared tenant-filter decision. The planned (storage-native) read
// runtime has NO per-tenant filtering of its own; tenant isolation + hierarchy
// access live in `match_operations` (the legacy executor). When the session has
// a concrete tenant scope, this fast path is bypassed so tenant-scoped reads go
// through the tenant-aware path. The common single-tenant case (null/"default"
// scope) keeps the fast path with zero overhead.
const tenancy = @import("tenancy.zig");
// GAP-ENT-0044/0045 (T5): read-executor budget + cancel. Polled at every
// row-materialization boundary (right before g_path_rows_materialized ticks),
// so a runaway/abandoned planned read aborts within one row of the trip.
const read_budget = @import("../read_budget.zig");

// Task 1.5 / GAP-0806: interior-dupe scratch allocator resolver. Mirrors
// `match_operations.scratchAllocatorOr` — when a per-query arena is installed
// on the current thread (GAP-0755), arena-back Node/Edge interior bytes so
// they drop with the query. `OwnedGraphEntities.deinit` only destroys the
// Node/Edge struct itself; interior `graph_name`/`labels`/property keys +
// values would otherwise leak per row (observed: 3,422 leak stacks over a
// 90-min loadtest, pegged the server at 8 cores — M0_10_CONCERNS.md).
inline fn scratchOr(fallback: std.mem.Allocator) std.mem.Allocator {
    return query_arena.currentScratchAllocator() orelse fallback;
}

// GAP-ENT-0002: TDD observable gate. Counts path/node rows materialized by
// materializePathRow + materializeNodeOnlyRow. Pre-fix, `MATCH ()-[r]->()
// RETURN count(r)` increments once per edge; post-fix the count(r) fast path
// serves the answer without calling either function, so this stays at 0.
// Test-only; not exported through execution.zig (use lib.zig planned_read_runtime).
var g_path_rows_materialized: std.atomic.Value(u64) = .init(0);
pub fn getPathRowsMaterialized() u64 {
    return g_path_rows_materialized.load(.monotonic);
}
pub fn resetPathRowsMaterialized() void {
    g_path_rows_materialized.store(0, .release);
}

const ExecutionContext = execution.ExecutionContext;
const ExecutionResult = execution.ExecutionResult;
const OwnedGraphEntities = execution.OwnedGraphEntities;
const Value = value_types.Value;
const Env = value_types.Env;

pub const OpKind = enum {
    ConstProjection,
    AllNodesScan,
    LabelScan,
    IndexSeek,
    ExpandOut,
    ExpandIn,
    ExpandEither,
    OptionalMatch,
    VarLengthExpand,
    ShortestPath,
    PathModeExpand,
    PathCapture,
    CallProcedure,
    CallSubquery,
    Create,
    Merge,
    Unwind,
    Set,
    Remove,
    Delete,
    RecursiveCTE,
    QueryChain,
    LegacyExecute,
    Filter,
    Aggregate,
    Project,
    Distinct,
    Limit,
    Sort,
};

pub const PlanOp = struct {
    kind: OpKind,
    est_rows: u64 = 0,
};

const BindingKind = enum {
    node,
    edge,
};

pub const HopBinding = struct {
    rel_index: usize,
    right_index: usize,
};

/// Binding indices for the single covered OPTIONAL-MATCH chain's hop
/// (`OPTIONAL MATCH (p)-[r:R]->(c)`). The shared seed var (`p`) is already
/// bound by the main chain; only the optional rel (`r`) and optional
/// endpoint (`c`) get fresh binding slots, filled per left-outer match and
/// left at NULL for the zero-match row. See `executeOptionalLeftOuter`.
pub const OptionalJoin = struct {
    rel_index: usize,
    right_index: usize,
};

/// Binding indices for the single covered bounded var-length endpoint shape
/// (`MATCH (p {bound})-[:R*a..b]->(c) RETURN c`). The seed (`p`) and endpoint
/// (`c`) each get a node binding slot; the bare pattern carries no rel/path
/// binding (gate enforces). When set, `buildInitialResult` routes to
/// `executeVarLengthEndpoint`. min/max/dir/rel-type are read from the chain at
/// execution time. `seed_index`/`endpoint_index` may name anonymous patterns
/// (a generated binding name); both are always present (ensureBinding never
/// fails to allocate a slot).
pub const VarLengthEndpoint = struct {
    seed_index: usize,
    endpoint_index: usize,
};

const ExecutionMode = enum {
    storage_native,
    legacy,
};

pub const Plan = struct {
    graph_name: []const u8,
    binding_names: [][]const u8,
    binding_kinds: []BindingKind,
    ops: []PlanOp,
    execution_mode: ExecutionMode = .legacy,
    root_index: ?usize = null,
    hops: []HopBinding,
    /// Set only for the covered single OPTIONAL-MATCH left-outer shape; null
    /// for every other plan. When set, `buildInitialResult` routes to
    /// `executeOptionalLeftOuter` instead of the single/multi-chain path.
    optional_join: ?OptionalJoin = null,
    /// Set only for the covered bounded var-length endpoint shape; null for
    /// every other plan. When set, `buildInitialResult` routes to
    /// `executeVarLengthEndpoint` (depth-bounded acyclic per-path expand, no
    /// whole-graph clone).
    var_length_endpoint: ?VarLengthEndpoint = null,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.graph_name);
        for (self.binding_names) |name| {
            allocator.free(name);
        }
        allocator.free(self.binding_names);
        allocator.free(self.binding_kinds);
        allocator.free(self.ops);
        allocator.free(self.hops);
    }
};

pub const RuntimeOp = struct {
    kind: OpKind,
    input_rows: u64 = 0,
    rows: u64 = 0,
    time_ns: u64 = 0,
    /// SONNY-1335: for an `IndexSeek` the executor ran, the catalog index
    /// that served it (owned by the trace); null for every other operator.
    index_name: ?[]const u8 = null,
};

pub const RuntimeTrace = struct {
    ops: []RuntimeOp,

    pub fn deinit(self: *RuntimeTrace, allocator: std.mem.Allocator) void {
        for (self.ops) |op| if (op.index_name) |name| allocator.free(name);
        allocator.free(self.ops);
    }

    pub fn totalTimeNs(self: RuntimeTrace) u64 {
        var total: u64 = 0;
        for (self.ops) |op| total += op.time_ns;
        return total;
    }
};

pub const ProfiledExecution = struct {
    plan: Plan,
    result: ExecutionResult,
    trace: RuntimeTrace,

    pub fn deinitMetadata(self: *ProfiledExecution, allocator: std.mem.Allocator) void {
        self.plan.deinit(allocator);
        self.trace.deinit(allocator);
    }
};

const PathEdge = struct {
    edge_id: u64,
    actual_from_slot: u64,
    actual_to_slot: u64,
    next_slot: u64,
    rel_type: gs.LabelId,
    // GAP-0060: edge prop_head is a full u64 (may be a slab head, bit 63).
    prop_head: u64,
};

/// Does the session resolve to a concrete tenant scope? A strict-tenancy
/// refusal counts as concrete: the legacy path re-resolves and surfaces it.
fn sessionTenantConcrete(context: ExecutionContext) bool {
    const resolved = tenancy.resolveTenantFilter(context.tenant_id) catch return true;
    return resolved != null;
}

/// SONNY-2679: may this session's rows be hidden from it (a concrete tenant
/// scope, or an RLS policy that may deny a row)? The storage-native runtime
/// enforces neither, so `buildPlanIfSupported` demotes such a session to the
/// legacy executor, and the ungated walks here refuse to run for one.
fn sessionIsRestricted(context: ExecutionContext) bool {
    return sessionTenantConcrete(context) or execution.wouldEvaluateRLS();
}

pub fn buildPlanIfSupported(allocator: std.mem.Allocator, q: *const ast.Query, context: ExecutionContext) !?Plan {
    var binding_names = std.ArrayList([]const u8).empty;
    errdefer {
        for (binding_names.items) |name| allocator.free(name);
        binding_names.deinit(allocator);
    }
    var binding_kinds = std.ArrayList(BindingKind).empty;
    defer binding_kinds.deinit(allocator);
    var ops = try std.ArrayList(PlanOp).initCapacity(allocator, 8);
    defer ops.deinit(allocator);
    var hop_bindings = std.ArrayList(HopBinding).empty;
    defer hop_bindings.deinit(allocator);

    const graph_name = try allocator.dupe(u8, resolveGraphName(context));
    errdefer allocator.free(graph_name);
    const execution_mode: ExecutionMode = if (isStorageNativeQuery(q)) .storage_native else .legacy;

    // GAP-0846 / GAP-0509: the storage-native runtime collects start slots and
    // emits rows WITHOUT consulting `tenant_id`, so it can neither enforce
    // exact-match tenant isolation nor hierarchy (ancestor-or-self) access. When
    // the session resolves to a CONCRETE tenant scope, demote a data-touching
    // (MATCH-chain) plan to the legacy executor (`match_operations`), which
    // applies `passesTenantFilter` (now hierarchy-aware) at every read site.
    // The common single-tenant case (null/empty/"default" scope) keeps the fast
    // path with zero added work. `resolveTenantFilter` may reject in strict
    // mode; we ignore that error here and let the legacy path re-resolve and
    // surface it (so this guard never changes error behaviour).
    if (execution_mode == .storage_native and q.match.chains.len > 0) {
        const concrete = sessionTenantConcrete(context);
        // REQ-PROFILE-RLS-TENANT-001: the storage-native runtime also has NO
        // RLS enforcement of its own — passesRLSFilter/passesRLSExprFilter
        // live in match_operations (the legacy executor). Normal
        // (non-PROFILE) execution never reaches this fast path when RLS would
        // apply: query_execution.zig gates its call to
        // planned_read_runtime.executeIfSupported behind
        // `!match_operations.wouldEvaluateRLS()`. PROFILE calls
        // executeProfiledIfSupported directly, bypassing that outer gate
        // entirely, so the same decision is reproduced here: demote to the
        // legacy (RLS-aware) executor whenever the active session (pushed by
        // executeProfiledIfSupported above) would evaluate RLS policies.
        // CANARY: REQ=REQ-PROFILE-RLS-TENANT-001; FEATURE="PROFILE"; ASPECT=RLSBlindFastPathDemotion; STATUS=TESTED; TEST=tests/test_profile_rls_tenant.zig; OWNER=security; UPDATED=2026-08-29
        if (concrete or execution.wouldEvaluateRLS()) {
            // Bail to the legacy (tenant/RLS-aware) executor. Free the only
            // two allocations made so far (`graph_name` dupe + any binding
            // names); the rest are `defer`-freed. A `null` return is NOT an
            // error, so the errdefers above do not run.
            for (binding_names.items) |name| allocator.free(name);
            binding_names.deinit(allocator);
            allocator.free(graph_name);
            return null;
        }
    }

    var root_index: ?usize = null;
    var optional_join: ?OptionalJoin = null;
    var var_length_endpoint: ?VarLengthEndpoint = null;
    if (execution_mode == .storage_native) {
        if (q.match.chains.len == 0) {
            try ops.append(allocator, .{ .kind = .ConstProjection, .est_rows = 1 });
        } else if (coveredOptionalLeftOuter(q)) {
            // Covered OPTIONAL MATCH left-outer: register the MAIN chain's
            // bindings + scan/expand ops exactly as the single-chain branch
            // below, then add fresh binding slots for the optional hop's rel
            // and endpoint. The optional hop is NOT given an expand op — it is
            // folded into the per-main-row left-outer join in
            // executeOptionalLeftOuter.
            const main_chain = q.match.chains[0];
            const first_node = if (main_chain.head) |head| head else main_chain.hops[0].left;
            root_index = try ensureBinding(allocator, &binding_names, &binding_kinds, .node, first_node.name, "node", 0);
            const scan_kind: OpKind = if (nodeCanUseIndex(context, first_node, q.where_clause))
                .IndexSeek
            else if (first_node.labels.len > 0)
                .LabelScan
            else
                .AllNodesScan;
            try ops.append(allocator, .{
                .kind = scan_kind,
                .est_rows = try estimateScanRows(allocator, graph_name, first_node),
            });
            for (main_chain.hops, 0..) |hop, hop_idx| {
                try hop_bindings.append(allocator, .{
                    .rel_index = try ensureBinding(allocator, &binding_names, &binding_kinds, .edge, hop.rel.name, "edge", hop_idx),
                    .right_index = try ensureBinding(allocator, &binding_names, &binding_kinds, .node, hop.right.name, "node", hop_idx + 1),
                });
                try ops.append(allocator, .{
                    .kind = switch (hop.rel.dir) {
                        .right => .ExpandOut,
                        .left => .ExpandIn,
                        .undirected => .ExpandEither,
                    },
                });
            }
            const opt_hop = q.match.chains[1].hops[0];
            const opt_rel_index = try ensureBinding(allocator, &binding_names, &binding_kinds, .edge, opt_hop.rel.name, "edge", main_chain.hops.len);
            const opt_right_index = try ensureBinding(allocator, &binding_names, &binding_kinds, .node, opt_hop.right.name, "node", main_chain.hops.len + 1);
            optional_join = .{ .rel_index = opt_rel_index, .right_index = opt_right_index };
        } else if (coveredVarLengthEndpoint(q)) {
            // Covered bounded var-length endpoint shape: register a node
            // binding for the seed (p) and the endpoint (c), a scan op for the
            // seed, and one expand op (the depth-bounded acyclic per-path walk
            // is folded into executeVarLengthEndpoint). root_index stays null —
            // the seed/endpoint are addressed via var_length_endpoint indices.
            const chain = q.match.chains[0];
            const hop = chain.hops[0];
            const vle_seed_index = try ensureBinding(allocator, &binding_names, &binding_kinds, .node, hop.left.name, "node", 0);
            const scan_kind: OpKind = if (nodeCanUseIndex(context, hop.left, q.where_clause))
                .IndexSeek
            else if (hop.left.labels.len > 0)
                .LabelScan
            else
                .AllNodesScan;
            try ops.append(allocator, .{
                .kind = scan_kind,
                .est_rows = try estimateScanRows(allocator, graph_name, hop.left),
            });
            const vle_endpoint_index = try ensureBinding(allocator, &binding_names, &binding_kinds, .node, hop.right.name, "node", 1);
            try ops.append(allocator, .{
                .kind = switch (hop.rel.dir) {
                    .right => .ExpandOut,
                    .left => .ExpandIn,
                    .undirected => .ExpandEither,
                },
            });
            var_length_endpoint = .{ .seed_index = vle_seed_index, .endpoint_index = vle_endpoint_index };
        } else if (q.match.chains.len > 1) {
            // Multi-chain hash-join: register each chain's root node binding in order.
            // root_index stays null — executeMultiChainHashJoin uses per-chain indices.
            for (q.match.chains, 0..) |chain, ci| {
                const root = if (chain.head) |head| head else chain.hops[0].left;
                _ = try ensureBinding(allocator, &binding_names, &binding_kinds, .node, root.name, "node", ci);
                try ops.append(allocator, .{
                    .kind = if (root.labels.len > 0) .LabelScan else .AllNodesScan,
                    .est_rows = try estimateScanRows(allocator, graph_name, root),
                });
            }
        } else {
            const chain = q.match.chains[0];
            const first_node = if (chain.head) |head| head else chain.hops[0].left;
            root_index = try ensureBinding(allocator, &binding_names, &binding_kinds, .node, first_node.name, "node", 0);
            const scan_kind: OpKind = if (nodeCanUseIndex(context, first_node, q.where_clause))
                .IndexSeek
            else if (first_node.labels.len > 0)
                .LabelScan
            else
                .AllNodesScan;
            try ops.append(allocator, .{
                .kind = scan_kind,
                .est_rows = try estimateScanRows(allocator, graph_name, first_node),
            });

            for (chain.hops, 0..) |hop, hop_idx| {
                try hop_bindings.append(allocator, .{
                    .rel_index = try ensureBinding(allocator, &binding_names, &binding_kinds, .edge, hop.rel.name, "edge", hop_idx),
                    .right_index = try ensureBinding(allocator, &binding_names, &binding_kinds, .node, hop.right.name, "node", hop_idx + 1),
                });
                try ops.append(allocator, .{
                    .kind = switch (hop.rel.dir) {
                        .right => .ExpandOut,
                        .left => .ExpandIn,
                        .undirected => .ExpandEither,
                    },
                });
            }
        }
    } else {
        try appendLegacyPlanOps(allocator, &ops, q);
        if (ops.items.len == 0) {
            try ops.append(allocator, .{ .kind = .LegacyExecute });
        }
    }

    if (execution_mode == .storage_native) {
        if (hasPreProjectionFilter(q)) {
            try ops.append(allocator, .{ .kind = .Filter });
        }
        if (q.with_clause) |with_clause| {
            try ops.append(allocator, .{
                .kind = if (q.withStageGroupBy() != null or hasAggregationItems(with_clause.items)) .Aggregate else .Project,
            });
            if (with_clause.distinct) {
                try ops.append(allocator, .{ .kind = .Distinct });
            }
            if (with_clause.order_by != null) {
                try ops.append(allocator, .{ .kind = .Sort });
            }
            if (with_clause.limit != null or with_clause.offset != null or with_clause.limit_param != null or with_clause.offset_param != null) {
                try ops.append(allocator, .{ .kind = .Limit });
            }
            if (withStageWhere(q) != null) {
                try ops.append(allocator, .{ .kind = .Filter });
            }
        }

        if (needsFinalProjection(q)) {
            try ops.append(allocator, .{
                .kind = if (q.returnStageGroupBy() != null or hasAggregationItems(q.ret.items)) .Aggregate else .Project,
            });
            if (q.ret.distinct) {
                try ops.append(allocator, .{ .kind = .Distinct });
            }
            if (q.order_by != null) {
                try ops.append(allocator, .{ .kind = .Sort });
            }
            if (q.limit != null or q.offset != null or q.limit_param != null or q.offset_param != null) {
                try ops.append(allocator, .{ .kind = .Limit });
            }
        }
    }

    return Plan{
        .graph_name = graph_name,
        .binding_names = try binding_names.toOwnedSlice(allocator),
        .binding_kinds = try binding_kinds.toOwnedSlice(allocator),
        .ops = try ops.toOwnedSlice(allocator),
        .execution_mode = execution_mode,
        .root_index = root_index,
        .hops = try hop_bindings.toOwnedSlice(allocator),
        .optional_join = optional_join,
        .var_length_endpoint = var_length_endpoint,
    };
}

pub fn executeIfSupported(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    param_names: []const []const u8,
    param_values: []const Value,
) !?ExecutionResult {
    if (!isStorageNativeQuery(q) or (q.match.chains.len > 0 and graph_store.getGlobalAdapter() == null)) {
        return null;
    }

    if (try executeProfiledIfSupported(allocator, q, context, param_names, param_values, false)) |profiled| {
        var owned_profiled = profiled;
        defer owned_profiled.deinitMetadata(allocator);
        return owned_profiled.result;
    }
    return null;
}

pub fn executeProfiledIfSupported(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    param_names: []const []const u8,
    param_values: []const Value,
    apply_window: bool,
) !?ProfiledExecution {
    // The profiled execution paths (storage-native fast path AND
    // executeLegacyProfiled) bypass executeQueryWithContext, which is the
    // choke point that normally installs the thread-local active context read
    // by passesRLSFilter/passesRLSExprFilter and getSessionTenantFilter.
    // Without this push, PROFILE fails open for both RLS and tenant scoping.
    // Nested push (normal path already pushed) is safe: save-prev/restore-prev.
    // CANARY: REQ=REQ-PROFILE-RLS-TENANT-001; FEATURE="PROFILE"; ASPECT=ActiveContextPush; STATUS=TESTED; TEST=tests/test_profile_rls_tenant.zig; OWNER=security; UPDATED=2026-08-29
    const prev_ctx = execution.pushActiveContext(&context);
    defer execution.popActiveContext(prev_ctx);
    // CANARY: REQ=REQ-SONNY-6460-PROFILE-SCRATCH; FEATURE="ExecutionResultOwnership"; ASPECT=ProfiledEntryPointScratch; STATUS=TESTED; TEST=tests/test_sonny6460_unscoped_eval.zig; OWNER=execution; UPDATED=2026-11-13
    // SONNY-6460 item 4: a statement scratch arena, as the executor's other
    // entry points open one (`execution.executeStatementWithContext`). An
    // embedded caller of this `pub` entry point had none, so what the
    // evaluator lends (a list property's copy, a decrypted or redacted FLE
    // string: `eval.lentValueAllocator`) fell back to `allocator` and was
    // freed by no one. With an arena already installed (a transport's, or a
    // statement's when `executeIfSupported` runs inside one) it does nothing.
    var scratch: query_arena.StatementScratch = .{};
    scratch.open(allocator);
    defer scratch.close();
    // CANARY: REQ=REQ-SONNY-3027-PROFILE-ENGINE-TXN; FEATURE="TransactionManagement"; ASPECT=ProfiledEntryPoint; STATUS=TESTED; TEST=tests/test_sonny3027_profile_engine_txn.zig; OWNER=storage; UPDATED=2026-09-27
    // SONNY-3027: a profiled query is a program of its own, like one run
    // through `executeProgramWithContext`: the session engine transaction a
    // change in it opened (`executeMerge`, `executeCreate`) is committed when
    // it returns, while the handler still holds the request's write lock. It
    // stayed open, and the backstop committed it after the lock was released.
    execution.enterEntryPoint();
    defer execution.leaveEntryPoint();
    // SONNY-3135 (N7b): a failed profiled change aborts its engine transaction.
    errdefer execution.failEntryPoint();

    // CANARY: REQ=REQ-SONNY-3349-PROFILE-RELAY; FEATURE="ExpressionEvaluator"; ASPECT=ProfiledRelayScope; STATUS=TESTED; TEST=tests/test_sonny3349_profile_relay.zig; OWNER=eval; UPDATED=2026-09-28
    // SONNY-3349 (round 17): the profiled run is a statement of its own, so
    // it opens the relay's scope (`execution.executeStatementWithContext`
    // does for every other statement) and fails with what a caller
    // swallowed in it: a limit (54001, out of memory, the read budget) or an
    // IN type error. PROFILE answered those as a profile (00000), and a
    // PROFILE'd change kept its writes; inside the scope the store's write
    // fence refuses them too (SONNY-3348). Nested under a statement's own
    // scope (`executeIfSupported`), it does not own the scope, and the
    // statement fails instead.
    const owns_scope = eval.enterInPredicateScope();
    // SONNY-3348 (round 18): and its statement undo record: a profiled
    // statement that fails has its changes undone, as any other statement
    // (`execution.executeStatementWithContext`).
    // SONNY-3348 (round 19): and its held replicated writes (one entry).
    execution.beginStatementScope(owns_scope);
    var profiled = (executeProfiledInScope(allocator, q, context, param_names, param_values, apply_window) catch |err| {
        _ = eval.exitInPredicateScope(owns_scope);
        _ = eval.takeDeferredLimitError(owns_scope);
        return execution.endStatementFailed(owns_scope, err);
    }) orelse {
        _ = eval.exitInPredicateScope(owns_scope);
        _ = eval.takeDeferredLimitError(owns_scope);
        // Nothing ran (no plan); the caller runs the statement another way.
        switch (execution.endStatementFailed(owns_scope, error.NoPlan)) {
            error.NoPlan => {},
            else => |e| return e,
        }
        return null;
    };
    const limit_error = eval.takeDeferredLimitError(owns_scope);
    const in_type_error = eval.exitInPredicateScope(owns_scope);
    if (in_type_error or limit_error != null) {
        profiled.result.deinit(allocator);
        profiled.deinitMetadata(allocator);
        if (in_type_error) return execution.endStatementFailed(owns_scope, error.InListRequiresList);
        return execution.endStatementFailed(owns_scope, limit_error.?);
    }
    execution.endStatementSucceeded(owns_scope, context.catalog) catch |err| {
        profiled.result.deinit(allocator);
        profiled.deinitMetadata(allocator);
        return err;
    };
    // SONNY-6460 item 4: the result is copied out of the arena opened above
    // before it closes (it frees the result on failure).
    execution.detachFromStatementScratch(allocator, &scratch, &profiled.result) catch |err| {
        profiled.deinitMetadata(allocator);
        return err;
    };
    return profiled;
}

/// SONNY-3349: `executeProfiledIfSupported`'s run, inside its relay scope.
fn executeProfiledInScope(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    param_names: []const []const u8,
    param_values: []const Value,
    apply_window: bool,
) !?ProfiledExecution {
    // CANARY: REQ=REQ-SONNY-3139-WRITE-SHAPES; FEATURE="WriteShapeValidator"; ASPECT=PlannedRuntimeDeclinesWrites; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4.zig; OWNER=engine; UPDATED=2026-09-28
    // SONNY-3139, SONNY-3182 (round-3 review C1): the planned runtime is a
    // read runtime. A query that writes (a write clause, a part that writes,
    // a write hidden in an expression or a CTE body: the one write walk) is
    // declined, so it runs through the statement dispatcher, which validates
    // it against the write-shape allowlist. The QUIC and gRPC PROFILE arms
    // handed a write straight to `executeLegacyProfiled`, unvalidated.
    if (write_walk.queryWrites(q, .{})) return null;

    var plan = (try buildPlanIfSupported(allocator, q, context)) orelse return null;
    errdefer plan.deinit(allocator);
    // REQ-GQL-028 fail-closed: storage-native plans read the engine directly
    // and never pass the hydration chokepoint, so refuse a quarantined graph
    // here (its data is known damaged; the plan would answer OK from the
    // records that are left).
    if (graph_store.quarantineErrorForGraph(allocator, plan.graph_name)) |err| return err;

    if (plan.execution_mode != .storage_native or (q.match.chains.len > 0 and graph_store.getGlobalAdapter() == null)) {
        return try executeLegacyProfiled(allocator, q, context, param_names, param_values, plan);
    }

    var trace = RuntimeTrace{
        .ops = try allocator.alloc(RuntimeOp, plan.ops.len),
    };
    errdefer trace.deinit(allocator);
    for (plan.ops, 0..) |op, idx| {
        // SONNY-1335: the plan's IndexSeek is what it expected; the scan
        // operator says what ran once the start slots are collected
        // (`recordStartAccess`). Until then it is the label scan an IndexSeek
        // plan falls back to (only a labelled node is planned as one).
        trace.ops[idx] = .{ .kind = if (op.kind == .IndexSeek) .LabelScan else op.kind };
    }

    var filter_occurrence: usize = 0;
    var aggregate_occurrence: usize = 0;
    var project_occurrence: usize = 0;
    var distinct_occurrence: usize = 0;
    var sort_occurrence: usize = 0;
    var limit_occurrence: usize = 0;

    var result = try buildInitialResult(allocator, q, context, &plan, param_names, param_values, &trace);
    errdefer result.deinit(allocator);

    if (hasPreProjectionFilter(q)) {
        const op_index = nextOpIndex(trace.ops, .Filter, &filter_occurrence) orelse unreachable;
        try applyResultFilters(
            allocator,
            &result,
            if (q.with_clause == null) q.where_clause else preWithWhere(q),
            q.filter_clause,
            context,
            param_names,
            param_values,
            &trace.ops[op_index],
        );
    }

    if (q.with_clause) |with_clause| {
        const with_kind: OpKind = if (q.withStageGroupBy() != null or hasAggregationItems(with_clause.items)) .Aggregate else .Project;
        const with_op_index = switch (with_kind) {
            .Aggregate => nextOpIndex(trace.ops, .Aggregate, &aggregate_occurrence),
            .Project => nextOpIndex(trace.ops, .Project, &project_occurrence),
            else => unreachable,
        } orelse unreachable;

        const with_stage = stripWithExecutionModifiers(with_clause);
        const input_rows = result.rows.len;
        const start_ns = nowNs();
        // SONNY-2667: a HAVING without a GROUP BY is a WHERE after RETURN, so it
        // belongs to the RETURN stage below, not to this one.
        var with_result = try transformResultRowsWithParams(allocator, result, with_stage, q.withStageGroupBy(), execution.withStageHaving(q.*), param_names, param_values);
        transferOwnedGraphEntities(&result, &with_result);
        deinitResultKeepingOwnedGraphEntities(allocator, &result);

        trace.ops[with_op_index].input_rows = @intCast(input_rows);
        trace.ops[with_op_index].rows = @intCast(with_result.rows.len);
        trace.ops[with_op_index].time_ns = elapsedSince(start_ns);

        result = with_result;

        if (with_clause.distinct) {
            const op_index = nextOpIndex(trace.ops, .Distinct, &distinct_occurrence) orelse unreachable;
            try applyDistinctStage(allocator, &result, &trace.ops[op_index]);
        }
        if (with_clause.order_by) |order_ptr| {
            const op_index = nextOpIndex(trace.ops, .Sort, &sort_occurrence) orelse unreachable;
            try applySortStage(allocator, &result, order_ptr.*, with_clause.items, &trace.ops[op_index]);
        }
        if (with_clause.limit != null or with_clause.offset != null or with_clause.limit_param != null or with_clause.offset_param != null) {
            const op_index = nextOpIndex(trace.ops, .Limit, &limit_occurrence) orelse unreachable;
            try applyWindowStage(
                allocator,
                &result,
                if (with_clause.offset) |value| @as(usize, @intCast(value)) else null,
                with_clause.offset_param,
                if (with_clause.limit) |value| @as(usize, @intCast(value)) else null,
                with_clause.limit_param,
                param_names,
                param_values,
                &trace.ops[op_index],
            );
        }
        if (withStageWhere(q) != null) {
            const op_index = nextOpIndex(trace.ops, .Filter, &filter_occurrence) orelse unreachable;
            try applyResultFilters(
                allocator,
                &result,
                withStageWhere(q),
                null,
                context,
                param_names,
                param_values,
                &trace.ops[op_index],
            );
        }
    }

    if (needsFinalProjection(q)) {
        // SONNY-2667: a WHERE after RETURN (parsed as a HAVING with no GROUP BY)
        // filters the RETURN's rows, with or without a WITH before it.
        // SONNY-2698: a GROUP BY and HAVING written after the RETURN are the
        // RETURN's, with or without a WITH before it.
        const return_group_by = q.returnStageGroupBy();
        const return_having = q.returnStageHaving();
        const return_kind: OpKind = if (return_group_by != null or hasAggregationItems(q.ret.items)) .Aggregate else .Project;
        const return_op_index = switch (return_kind) {
            .Aggregate => nextOpIndex(trace.ops, .Aggregate, &aggregate_occurrence),
            .Project => nextOpIndex(trace.ops, .Project, &project_occurrence),
            else => unreachable,
        } orelse unreachable;

        const return_stage = ast.WithClause{
            .items = q.ret.items,
        };
        const input_rows = result.rows.len;
        const start_ns = nowNs();
        var projected = try transformResultRowsWithParams(allocator, result, return_stage, return_group_by, return_having, param_names, param_values);
        // GAP-0535: the final projection is the result handed to the caller —
        // make it fully OWN its row values (adopt provably-fresh call results,
        // deep-duplicate everything else) so ExecutionResult.deinit is
        // leak-free and dangle-free under a strict allocator. Intermediate
        // WITH-stage results above stay borrowed (legacy semantics) because
        // later stages read them as Env values.
        // CANARY: REQ=REQ-EXEC-RESULT-OWNERSHIP-001; FEATURE="ExecutionResultOwnership"; ASPECT=PlannedFinalProjection; STATUS=TESTED; TEST=tests/test_gap0535_result_ownership.zig; OWNER=execution; UPDATED=2026-06-11
        try value_utilities.adoptProjectionRowValues(allocator, &projected, q.ret.items);
        transferOwnedGraphEntities(&result, &projected);
        deinitResultKeepingOwnedGraphEntities(allocator, &result);

        trace.ops[return_op_index].input_rows = @intCast(input_rows);
        trace.ops[return_op_index].rows = @intCast(projected.rows.len);
        trace.ops[return_op_index].time_ns = elapsedSince(start_ns);

        result = projected;

        if (q.ret.distinct) {
            const op_index = nextOpIndex(trace.ops, .Distinct, &distinct_occurrence) orelse unreachable;
            try applyDistinctStage(allocator, &result, &trace.ops[op_index]);
        }
        if (q.order_by) |order| {
            const op_index = nextOpIndex(trace.ops, .Sort, &sort_occurrence) orelse unreachable;
            try applySortStage(allocator, &result, order, q.ret.items, &trace.ops[op_index]);
        }
        if (apply_window and (q.limit != null or q.offset != null or q.limit_param != null or q.offset_param != null)) {
            const op_index = nextOpIndex(trace.ops, .Limit, &limit_occurrence) orelse unreachable;
            try applyWindowStage(
                allocator,
                &result,
                q.offset,
                q.offset_param,
                q.limit,
                q.limit_param,
                param_names,
                param_values,
                &trace.ops[op_index],
            );
        }
    }

    return ProfiledExecution{
        .plan = plan,
        .result = result,
        .trace = trace,
    };
}

fn executeLegacyProfiled(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    param_names: []const []const u8,
    param_values: []const Value,
    plan: Plan,
) !ProfiledExecution {
    var trace = RuntimeTrace{
        .ops = try allocator.alloc(RuntimeOp, plan.ops.len),
    };
    errdefer trace.deinit(allocator);
    for (plan.ops, 0..) |op, idx| {
        trace.ops[idx] = .{ .kind = op.kind };
    }

    const start_ns = nowNs();
    var result = try execution.executeLegacyQueryWithResolvedParams(allocator, q.*, context, param_names, param_values);
    errdefer result.deinit(allocator);

    if (trace.ops.len > 0) {
        const last = &trace.ops[trace.ops.len - 1];
        last.input_rows = @intCast(result.rows.len);
        last.rows = @intCast(result.rows.len);
        last.time_ns = elapsedSince(start_ns);
    }

    return ProfiledExecution{
        .plan = plan,
        .result = result,
        .trace = trace,
    };
}

fn buildInitialResult(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    plan: *const Plan,
    param_names: []const []const u8,
    param_values: []const Value,
    trace: *RuntimeTrace,
) !ExecutionResult {
    if (q.match.chains.len == 0) {
        const empty_row = try allocator.alloc(Value, 0);
        errdefer allocator.free(empty_row);
        const rows = try allocator.alloc([]Value, 1);
        rows[0] = empty_row;
        return ExecutionResult{
            .columns = try allocator.alloc([]const u8, 0),
            .rows = rows,
            .flags = std.ArrayList([]const u8).empty,
        };
    }

    if (plan.optional_join != null) {
        return executeOptionalLeftOuter(allocator, q, context, plan, param_names, param_values, trace);
    }

    if (plan.var_length_endpoint != null) {
        return executeVarLengthEndpoint(allocator, q, context, plan, param_names, param_values, trace);
    }

    if (q.match.chains.len > 1) {
        return executeMultiChainHashJoin(allocator, q, context, plan, param_names, param_values, trace);
    }
    return executePatternQuery(allocator, q, context, plan, param_names, param_values, trace);
}

/// Estimate the minimum posting-list length for a NodePattern's indexed inline props.
/// Returns std.math.maxInt(usize) when the pattern has no indexed prop (label-only
/// or no props at all) — meaning a full label scan would be needed. Safe to call as a
/// selectivity probe: uses countCandidateNodesByLabelAndProperty which does NOT
/// increment g_exact_node_property_lookup_count.
fn estimatePatternSelectivity(
    adapter: *graph_storage_adapter.StorageAdapter,
    graph_name: []const u8,
    pattern: ast.NodePattern,
    param_names: []const []const u8,
    param_values: []const Value,
    allocator: std.mem.Allocator,
) usize {
    if (pattern.labels.len != 1) return std.math.maxInt(usize);
    const props = pattern.props orelse return std.math.maxInt(usize);
    if (props.len == 0) return std.math.maxInt(usize);
    const prop_env = Env{
        .names = &.{},
        .values = &.{},
        .param_names = param_names,
        .param_values = param_values,
        .allocator = allocator,
    };
    var best_len: usize = std.math.maxInt(usize);
    for (props) |prop| {
        if (pattern_helpers.containsVariableReference(prop.value.*)) continue;
        if (!graph_store.shouldIndexProperty(prop.key)) continue;
        const expected_val = eval.evalExpr(allocator, prop.value.*, prop_env) catch continue;
        const pv: graph_store.PropertyValue = switch (expected_val) {
            .Str => |s| .{ .String = s },
            .Int => |i| .{ .Int = i },
            .Bool => |b| .{ .Bool = b },
            else => continue,
        };
        const plen = adapter.countCandidateNodesByLabelAndProperty(graph_name, pattern.labels[0], prop.key, pv) catch continue;
        if (plen < best_len) {
            best_len = plen;
            if (plen <= 1) break;
        }
    }
    return best_len;
}

fn executePatternQuery(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    plan: *const Plan,
    param_names: []const []const u8,
    param_values: []const Value,
    trace: *RuntimeTrace,
) !ExecutionResult {
    const adapter = graph_store.getGlobalAdapter() orelse return error.Unsupported;
    const chain = q.match.chains[0];
    var rows = std.ArrayList([]Value).empty;
    defer rows.deinit(allocator);
    var owned_entities = try OwnedGraphEntities.init(allocator);
    errdefer owned_entities.deinit();

    // GAP residual: cap single-chain path materialization at offset+limit.
    // Mirrors the shipped multi-chain cartesian cap (executeMultiChainHashJoin):
    // safe ONLY when the first offset+limit materialized rows ARE the final
    // window — no WHERE residual filter, no ORDER BY (reorders), no
    // DISTINCT/aggregate (cardinality), no WITH (reshape). Otherwise null =
    // materialize all (unchanged); the window is applied post-hoc.
    // SONNY-2652: the bound is `materializeWindowEnd` (null without a LIMIT),
    // not the start-slot threshold, which answers offset+1 for an OFFSET alone.
    // A FILTER removes rows after materialization exactly as a WHERE does. A
    // GROUP BY merges rows (with or without an aggregate) and a HAVING removes
    // them, both after materialization too.
    const materialize_cap: ?usize = blk: {
        if (q.where_clause != null) break :blk null;
        if (q.filter_clause != null) break :blk null;
        if (q.group_by != null) break :blk null;
        if (q.having != null) break :blk null;
        if (q.order_by != null) break :blk null;
        if (q.with_clause != null) break :blk null;
        if (q.ret.distinct) break :blk null;
        if (hasAggregationItems(q.ret.items)) break :blk null;
        break :blk materializeWindowEnd(q, param_names, param_values); // null if no limit
    };

    if (!adapter.graphExists(plan.graph_name)) {
        const column_result = try buildBindingColumns(allocator, plan.binding_names, q.inline_let_bindings);
        const empty_result = ExecutionResult{
            .columns = column_result.columns,
            .rows = try rows.toOwnedSlice(allocator),
            .flags = std.ArrayList([]const u8).empty,
            .column_buffer = column_result.buffer,
        };
        owned_entities.deinit();
        return empty_result;
    }

    // Bug B fix: for single-hop directed queries, probe both endpoints'
    // selectivity and seed the more-selective one.  Gate is strict:
    //   - chain.hops.len == 1 (multi-hop deferred)
    //   - hop.rel.dir != .undirected (undirected: unchanged path)
    //   - tail strictly more selective than head
    // All other cases take the existing seeded_from_tail==false path unchanged.
    const seeded_from_tail: bool = sel: {
        if (chain.hops.len == 1) {
            const hop = chain.hops[0];
            if (hop.rel.dir != .undirected) {
                const head_sel = estimatePatternSelectivity(adapter, plan.graph_name, hop.left, param_names, param_values, allocator);
                const tail_sel = estimatePatternSelectivity(adapter, plan.graph_name, hop.right, param_names, param_values, allocator);
                if (tail_sel < head_sel) break :sel true;
            }
        }
        break :sel false;
    };
    const start_pattern = if (seeded_from_tail)
        chain.hops[0].right
    else if (chain.head) |head|
        head
    else
        chain.hops[0].left;
    const scan_op_index = 0;
    const scan_start_ns = nowNs();
    var start_seek: ?StartSeek = null;
    const start_slots = try collectStartSlots(
        allocator,
        adapter,
        plan.graph_name,
        start_pattern,
        staleLabelIndexThreshold(q, param_names, param_values),
        param_names,
        param_values,
        context,
        q.where_clause,
        &start_seek,
    );
    defer allocator.free(start_slots);
    trace.ops[scan_op_index].rows = @intCast(start_slots.len);
    trace.ops[scan_op_index].time_ns = elapsedSince(scan_start_ns);
    try recordStartAccess(allocator, context, &trace.ops[scan_op_index], start_pattern, start_seek);

    if (chain.hops.len == 0) {
        for (start_slots) |slot_id| {
            if (materialize_cap) |cap| if (rows.items.len >= cap) break;
            try materializeNodeOnlyRow(allocator, q, context, plan, slot_id, param_names, param_values, &rows, owned_entities);
        }
    } else {
        var current_nodes = try allocator.alloc(u64, chain.hops.len + 1);
        defer allocator.free(current_nodes);
        const current_edges = try allocator.alloc(PathEdge, chain.hops.len);
        defer allocator.free(current_edges);

        // GAP-0813: build projection plan once per query so every path
        // row can skip fetching properties the downstream consumers never
        // touch. `buildProjectionPlan` returns null when pruning isn't
        // applicable — the materialize path falls back to full per-node
        // property fetch in that case.
        const projection_plan = try buildProjectionPlan(allocator, q, plan);
        defer if (projection_plan) |pp| freeProjectionPlan(allocator, pp);

        for (start_slots) |start_slot| {
            if (materialize_cap) |cap| if (rows.items.len >= cap) break;
            if (seeded_from_tail) {
                // Bug B single-hop reverse walk: start_slot is the terminal c.
                // Expand backwards (flipped direction) to find the head p.
                // Populate current_nodes in logical chain order: [0]=p, [1]=c.
                const hop = chain.hops[0];
                const rev_candidates = try collectHopEdges(allocator, adapter, plan.graph_name, start_slot, flipRelDir(hop.rel.dir));
                defer allocator.free(rev_candidates);
                for (rev_candidates) |edge| {
                    if (materialize_cap) |cap| if (rows.items.len >= cap) break;
                    if (!try edgeMatchesPattern(allocator, adapter, plan.graph_name, edge, hop.rel, param_names, param_values, context)) continue;
                    if (!try nodeMatchesPatternBySlot(allocator, adapter, plan.graph_name, edge.next_slot, hop.left, param_names, param_values, context)) continue;
                    current_nodes[0] = edge.next_slot; // p — logical position 0
                    current_nodes[1] = start_slot; // c — logical position 1
                    current_edges[0] = edge;
                    try materializePathRow(allocator, q, context, plan, plan.graph_name, current_nodes, current_edges, param_names, param_values, &rows, owned_entities, projection_plan);
                }
            } else {
                current_nodes[0] = start_slot;
                try exploreHops(allocator, adapter, plan.graph_name, q, context, plan, param_names, param_values, &rows, owned_entities, trace, current_nodes, current_edges, 0, projection_plan, materialize_cap);
            }
        }
    }

    const column_result = try buildBindingColumns(allocator, plan.binding_names, q.inline_let_bindings);
    const result = ExecutionResult{
        .columns = column_result.columns,
        .rows = try rows.toOwnedSlice(allocator),
        .flags = std.ArrayList([]const u8).empty,
        .column_buffer = column_result.buffer,
        .owned_graph_entities = if (owned_entities.nodes.items.len > 0 or owned_entities.edges.items.len > 0) owned_entities else null,
    };
    if (result.owned_graph_entities == null) {
        owned_entities.deinit();
    }
    return result;
}

fn exploreHops(
    allocator: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    graph_name: []const u8,
    q: *const ast.Query,
    context: ExecutionContext,
    plan: *const Plan,
    param_names: []const []const u8,
    param_values: []const Value,
    rows: *std.ArrayList([]Value),
    owned_entities: *OwnedGraphEntities,
    trace: *RuntimeTrace,
    current_nodes: []u64,
    current_edges: []PathEdge,
    hop_index: usize,
    projection_plan: ?[]const BindingProjection,
    cap: ?usize,
) !void {
    // GAP residual: LIMIT pushdown — stop once offset+limit rows exist (the
    // caller windows the prefix post-hoc; cap is null unless that is safe).
    if (cap) |c| if (rows.items.len >= c) return;
    const chain = q.match.chains[0];
    if (hop_index == chain.hops.len) {
        try materializePathRow(allocator, q, context, plan, graph_name, current_nodes, current_edges, param_names, param_values, rows, owned_entities, projection_plan);
        return;
    }

    const hop = chain.hops[hop_index];
    const op_index = 1 + hop_index;
    trace.ops[op_index].input_rows += 1;
    const start_ns = nowNs();

    const candidates = try collectHopEdges(allocator, adapter, graph_name, current_nodes[hop_index], hop.rel.dir);
    defer allocator.free(candidates);

    var produced: u64 = 0;
    for (candidates) |edge| {
        if (cap) |c| if (rows.items.len >= c) break;
        if (!try edgeMatchesPattern(allocator, adapter, graph_name, edge, hop.rel, param_names, param_values, context)) {
            continue;
        }
        if (!try nodeMatchesPatternBySlot(allocator, adapter, graph_name, edge.next_slot, hop.right, param_names, param_values, context)) {
            continue;
        }
        current_edges[hop_index] = edge;
        current_nodes[hop_index + 1] = edge.next_slot;
        produced += 1;
        try exploreHops(allocator, adapter, graph_name, q, context, plan, param_names, param_values, rows, owned_entities, trace, current_nodes, current_edges, hop_index + 1, projection_plan, cap);
    }

    trace.ops[op_index].rows += produced;
    trace.ops[op_index].time_ns += elapsedSince(start_ns);
}

fn materializeNodeOnlyRow(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    plan: *const Plan,
    node_slot: u64,
    param_names: []const []const u8,
    param_values: []const Value,
    rows: *std.ArrayList([]Value),
    owned_entities: *OwnedGraphEntities,
) !void {
    var local_nodes = std.ArrayList(*graph_store.Node).empty;
    defer local_nodes.deinit(allocator);
    var local_edges = std.ArrayList(*graph_store.Edge).empty;
    defer local_edges.deinit(allocator);

    const node = try materializeNode(allocator, plan.graph_name, node_slot);
    try local_nodes.append(allocator, node);

    const binding_values = try allocator.alloc(Value, plan.binding_names.len);
    defer allocator.free(binding_values);
    for (binding_values) |*value| value.* = Value{ .Null = {} };
    if (plan.root_index) |idx| {
        binding_values[idx] = Value{ .Node = node };
    }

    const env = Env{
        .names = plan.binding_names,
        .values = binding_values,
        .param_names = param_names,
        .param_values = param_values,
        .allocator = allocator,
        .exec_context = @constCast(&context),
    };

    const row = try buildBindingRow(allocator, q, env, binding_values);
    try read_budget.check(); // T5: budget/cancel poll at the row-materialization boundary
    _ = g_path_rows_materialized.fetchAdd(1, .monotonic);
    try rows.append(allocator, row);
    for (local_nodes.items) |tracked_node| {
        try owned_entities.trackNode(tracked_node);
    }
}

// ---------------------------------------------------------------------------
// Covered OPTIONAL MATCH left-outer support.
//
// Serves the covered shape (see `coveredOptionalLeftOuter`):
//   MATCH (<main storage-native single chain>)
//   OPTIONAL MATCH (<main-bound var>)-[r?:R?]->(c?)
//   RETURN ...
// ENGINE-DIRECT with correct openCypher left-outer semantics and NO
// whole-graph clone. The main chain is enumerated exactly as
// `executePatternQuery` does; for each complete main path the single optional
// hop is expanded from the shared seed slot. >=1 optional match → one row per
// match; 0 matches → one row with the optional bindings NULL (the differential
// oracle is `match_operations.executeMatchWithOptionalPatterns`).
// ---------------------------------------------------------------------------

fn executeOptionalLeftOuter(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    plan: *const Plan,
    param_names: []const []const u8,
    param_values: []const Value,
    trace: *RuntimeTrace,
) !ExecutionResult {
    const adapter = graph_store.getGlobalAdapter() orelse return error.Unsupported;
    const main_chain = q.match.chains[0];
    const opt_hop = q.match.chains[1].hops[0];
    const oj = plan.optional_join orelse return error.Unsupported;

    var rows = std.ArrayList([]Value).empty;
    defer rows.deinit(allocator);
    var owned_entities = try OwnedGraphEntities.init(allocator);
    errdefer owned_entities.deinit();

    if (!adapter.graphExists(plan.graph_name)) {
        const column_result = try buildBindingColumns(allocator, plan.binding_names, q.inline_let_bindings);
        const empty_result = ExecutionResult{
            .columns = column_result.columns,
            .rows = try rows.toOwnedSlice(allocator),
            .flags = std.ArrayList([]const u8).empty,
            .column_buffer = column_result.buffer,
        };
        owned_entities.deinit();
        return empty_result;
    }

    // Position of the shared seed var within the main chain's node-slot array
    // (node 0 = root, node i+1 = hop[i].right). The gate guarantees this var
    // is a main-bound node, so the lookup always resolves.
    const seed_name = opt_hop.left.name orelse return error.Unsupported;
    const shared_pos: usize = blk: {
        const root = if (main_chain.head) |head| head else main_chain.hops[0].left;
        if (root.name) |n| {
            if (std.mem.eql(u8, n, seed_name)) break :blk 0;
        }
        for (main_chain.hops, 0..) |hop, i| {
            if (hop.right.name) |n| {
                if (std.mem.eql(u8, n, seed_name)) break :blk i + 1;
            }
        }
        return error.Unsupported;
    };

    // Seed the MAIN chain's start nodes (no tail-selectivity flip — correctness
    // over the micro-optimization; the covered shape is dominated by the bound
    // point-read seed anyway). where_clause is null by gate.
    const start_pattern = if (main_chain.head) |head| head else main_chain.hops[0].left;
    const scan_start_ns = nowNs();
    var start_seek: ?StartSeek = null;
    const start_slots = try collectStartSlots(
        allocator,
        adapter,
        plan.graph_name,
        start_pattern,
        null,
        param_names,
        param_values,
        context,
        null,
        &start_seek,
    );
    defer allocator.free(start_slots);
    if (trace.ops.len > 0) {
        trace.ops[0].rows = @intCast(start_slots.len);
        trace.ops[0].time_ns = elapsedSince(scan_start_ns);
        try recordStartAccess(allocator, context, &trace.ops[0], start_pattern, start_seek);
    }

    const projection_plan = try buildProjectionPlan(allocator, q, plan);
    defer if (projection_plan) |pp| freeProjectionPlan(allocator, pp);

    if (main_chain.hops.len == 0) {
        // Bare main node: shared_pos is necessarily 0.
        for (start_slots) |start_slot| {
            var node_slots = [_]u64{start_slot};
            try emitOptionalLeftOuterRow(
                allocator,
                q,
                context,
                plan,
                plan.graph_name,
                node_slots[0..],
                &.{},
                start_slot,
                oj,
                opt_hop,
                adapter,
                param_names,
                param_values,
                &rows,
                owned_entities,
                projection_plan,
            );
        }
    } else {
        var current_nodes = try allocator.alloc(u64, main_chain.hops.len + 1);
        defer allocator.free(current_nodes);
        const current_edges = try allocator.alloc(PathEdge, main_chain.hops.len);
        defer allocator.free(current_edges);

        for (start_slots) |start_slot| {
            current_nodes[0] = start_slot;
            try exploreMainHopsForOptional(
                allocator,
                adapter,
                plan.graph_name,
                q,
                context,
                plan,
                param_names,
                param_values,
                &rows,
                owned_entities,
                trace,
                current_nodes,
                current_edges,
                0,
                projection_plan,
                shared_pos,
                oj,
                opt_hop,
            );
        }
    }

    const column_result = try buildBindingColumns(allocator, plan.binding_names, q.inline_let_bindings);
    const result = ExecutionResult{
        .columns = column_result.columns,
        .rows = try rows.toOwnedSlice(allocator),
        .flags = std.ArrayList([]const u8).empty,
        .column_buffer = column_result.buffer,
        .owned_graph_entities = if (owned_entities.nodes.items.len > 0 or owned_entities.edges.items.len > 0) owned_entities else null,
    };
    if (result.owned_graph_entities == null) {
        owned_entities.deinit();
    }
    return result;
}

/// Depth-first enumeration of the MAIN chain (mirrors `exploreHops`); at the
/// leaf (all main hops walked) it performs the optional left-outer join from
/// the shared seed slot rather than materializing a plain path row.
fn exploreMainHopsForOptional(
    allocator: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    graph_name: []const u8,
    q: *const ast.Query,
    context: ExecutionContext,
    plan: *const Plan,
    param_names: []const []const u8,
    param_values: []const Value,
    rows: *std.ArrayList([]Value),
    owned_entities: *OwnedGraphEntities,
    trace: *RuntimeTrace,
    current_nodes: []u64,
    current_edges: []PathEdge,
    hop_index: usize,
    projection_plan: ?[]const BindingProjection,
    shared_pos: usize,
    oj: OptionalJoin,
    opt_hop: ast.Hop,
) !void {
    const chain = q.match.chains[0];
    if (hop_index == chain.hops.len) {
        const seed_slot = current_nodes[shared_pos];
        try emitOptionalLeftOuterRow(
            allocator,
            q,
            context,
            plan,
            graph_name,
            current_nodes,
            current_edges,
            seed_slot,
            oj,
            opt_hop,
            adapter,
            param_names,
            param_values,
            rows,
            owned_entities,
            projection_plan,
        );
        return;
    }

    const hop = chain.hops[hop_index];
    const op_index = 1 + hop_index;
    trace.ops[op_index].input_rows += 1;
    const start_ns = nowNs();

    const candidates = try collectHopEdges(allocator, adapter, graph_name, current_nodes[hop_index], hop.rel.dir);
    defer allocator.free(candidates);

    var produced: u64 = 0;
    for (candidates) |edge| {
        if (!try edgeMatchesPattern(allocator, adapter, graph_name, edge, hop.rel, param_names, param_values, context)) {
            continue;
        }
        if (!try nodeMatchesPatternBySlot(allocator, adapter, graph_name, edge.next_slot, hop.right, param_names, param_values, context)) {
            continue;
        }
        current_edges[hop_index] = edge;
        current_nodes[hop_index + 1] = edge.next_slot;
        produced += 1;
        try exploreMainHopsForOptional(allocator, adapter, graph_name, q, context, plan, param_names, param_values, rows, owned_entities, trace, current_nodes, current_edges, hop_index + 1, projection_plan, shared_pos, oj, opt_hop);
    }

    trace.ops[op_index].rows += produced;
    trace.ops[op_index].time_ns += elapsedSince(start_ns);
}

/// Materialize one complete main path's bindings, then expand the single
/// optional hop from `seed_slot`. Emits one row per optional match; if there
/// are ZERO optional matches, emits exactly one row with the optional bindings
/// left NULL (openCypher left-outer). Main-chain entities are materialized once
/// and shared across the emitted rows (each entity is tracked exactly once in
/// `owned_entities`; the result keeps `owns_value_memory == false`, so row
/// slices are freed without touching the shared pointers, which are freed once
/// via OwnedGraphEntities).
fn emitOptionalLeftOuterRow(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    plan: *const Plan,
    graph_name: []const u8,
    node_slots: []const u64,
    edge_steps: []const PathEdge,
    seed_slot: u64,
    oj: OptionalJoin,
    opt_hop: ast.Hop,
    adapter: *graph_storage_adapter.StorageAdapter,
    param_names: []const []const u8,
    param_values: []const Value,
    rows: *std.ArrayList([]Value),
    owned_entities: *OwnedGraphEntities,
    projection_plan: ?[]const BindingProjection,
) !void {
    // Materialize the MAIN chain bindings once (shared across emitted rows).
    var main_values = try allocator.alloc(Value, plan.binding_names.len);
    defer allocator.free(main_values);
    for (main_values) |*v| v.* = Value{ .Null = {} };

    if (plan.root_index) |idx| {
        const root_node = try materializeNodeForBinding(allocator, graph_name, node_slots[0], projection_plan, idx);
        try owned_entities.trackNode(root_node);
        main_values[idx] = Value{ .Node = root_node };
    }
    for (plan.hops, 0..) |hop_binding, hop_idx| {
        const edge = try materializeEdge(allocator, graph_name, edge_steps[hop_idx]);
        try owned_entities.trackEdge(edge);
        main_values[hop_binding.rel_index] = Value{ .Edge = edge };

        const right_node = try materializeNodeForBinding(allocator, graph_name, node_slots[hop_idx + 1], projection_plan, hop_binding.right_index);
        try owned_entities.trackNode(right_node);
        main_values[hop_binding.right_index] = Value{ .Node = right_node };
    }

    // Expand the single optional hop from the shared seed slot.
    const candidates = try collectHopEdges(allocator, adapter, graph_name, seed_slot, opt_hop.rel.dir);
    defer allocator.free(candidates);

    var emitted: usize = 0;
    for (candidates) |edge| {
        if (!try edgeMatchesPattern(allocator, adapter, graph_name, edge, opt_hop.rel, param_names, param_values, context)) {
            continue;
        }
        if (!try nodeMatchesPatternBySlot(allocator, adapter, graph_name, edge.next_slot, opt_hop.right, param_names, param_values, context)) {
            continue;
        }

        const opt_edge = try materializeEdge(allocator, graph_name, edge);
        try owned_entities.trackEdge(opt_edge);
        const opt_node = try materializeNodeForBinding(allocator, graph_name, edge.next_slot, projection_plan, oj.right_index);
        try owned_entities.trackNode(opt_node);

        const binding_values = try allocator.alloc(Value, plan.binding_names.len);
        defer allocator.free(binding_values);
        @memcpy(binding_values, main_values);
        binding_values[oj.rel_index] = Value{ .Edge = opt_edge };
        binding_values[oj.right_index] = Value{ .Node = opt_node };

        const env = Env{
            .names = plan.binding_names,
            .values = binding_values,
            .param_names = param_names,
            .param_values = param_values,
            .allocator = allocator,
            .exec_context = @constCast(&context),
        };
        const row = try buildBindingRow(allocator, q, env, binding_values);
        try read_budget.check(); // T5: budget/cancel poll at the row-materialization boundary
        _ = g_path_rows_materialized.fetchAdd(1, .monotonic);
        try rows.append(allocator, row);
        emitted += 1;
    }

    if (emitted == 0) {
        // Zero optional matches → exactly one row, optional bindings NULL.
        const binding_values = try allocator.alloc(Value, plan.binding_names.len);
        defer allocator.free(binding_values);
        @memcpy(binding_values, main_values); // oj.rel_index/right_index stay Null
        const env = Env{
            .names = plan.binding_names,
            .values = binding_values,
            .param_names = param_names,
            .param_values = param_values,
            .allocator = allocator,
            .exec_context = @constCast(&context),
        };
        const row = try buildBindingRow(allocator, q, env, binding_values);
        try read_budget.check(); // T5: budget/cancel poll at the row-materialization boundary
        _ = g_path_rows_materialized.fetchAdd(1, .monotonic);
        try rows.append(allocator, row);
    }
}

// ---------------------------------------------------------------------------
// Covered bounded var-length endpoint support.
//
// Serves the covered shape (see `coveredVarLengthEndpoint`):
//   MATCH (p {bound})-[:R*a..b]->(c) RETURN c        // finite b, directed,
//                                                    // bare/acyclic, endpoint
// ENGINE-DIRECT with NO whole-graph clone. The traversal is a faithful,
// engine-direct port of the clone-path oracle's BFS
// (execution.PathIterator, driven by
// match_operations.executeVariableLengthPathTraversal): a breadth-first expand
// with ACYCLIC per-path semantics (no repeated node per path), every path
// expanding (SONNY-6264: no (node,depth) dedup), and the same
// 10_000-iteration / 5_000-queue safety caps. Emission is ONE ROW PER
// QUALIFYING PATH (duplicates allowed; downstream DISTINCT dedups); min_len==0
// emits the seed as a 0-length path; the endpoint label/prop filter restricts
// emitted rows but NOT expansion. Edges are read via the storage adapter
// (`collectHopEdges`) instead of a snapshot store, so no node is deep-cloned.
// ---------------------------------------------------------------------------

const VarLenBfsItem = struct {
    last: u64,
    depth: u32,
    node_set: std.AutoHashMapUnmanaged(u64, void),
};

const VarLenExec = struct {
    allocator: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    graph_name: []const u8,
    q: *const ast.Query,
    context: ExecutionContext,
    plan: *const Plan,
    vle: VarLengthEndpoint,
    hop: ast.Hop,
    min_len: u32,
    max_len: u32,
    dir: ast.RelDir,
    param_names: []const []const u8,
    param_values: []const Value,
    rows: *std.ArrayList([]Value),
    owned_entities: *OwnedGraphEntities,

    const max_iterations: u64 = 10_000;
    const max_queue_size: usize = 5_000;

    /// Emit one endpoint row for a qualifying path, applying the endpoint
    /// label/prop filter first (mirrors the oracle's right-node filter at
    /// emission time). The shared seed node is bound once per seed; the
    /// endpoint node is materialized per row.
    fn emit(self: *VarLenExec, seed_node: *graph_store.Node, endpoint_slot: u64) !void {
        if (!try nodeMatchesPatternBySlot(self.allocator, self.adapter, self.graph_name, endpoint_slot, self.hop.right, self.param_names, self.param_values, self.context)) {
            return;
        }
        const endpoint_node = try materializeNode(self.allocator, self.graph_name, endpoint_slot);
        try self.owned_entities.trackNode(endpoint_node);

        const binding_values = try self.allocator.alloc(Value, self.plan.binding_names.len);
        defer self.allocator.free(binding_values);
        for (binding_values) |*v| v.* = Value{ .Null = {} };
        binding_values[self.vle.seed_index] = Value{ .Node = seed_node };
        binding_values[self.vle.endpoint_index] = Value{ .Node = endpoint_node };

        const env = Env{
            .names = self.plan.binding_names,
            .values = binding_values,
            .param_names = self.param_names,
            .param_values = self.param_values,
            .allocator = self.allocator,
            .exec_context = @constCast(&self.context),
        };
        const row = try buildBindingRow(self.allocator, self.q, env, binding_values);
        try read_budget.check(); // T5: budget/cancel poll at the row-materialization boundary
        _ = g_path_rows_materialized.fetchAdd(1, .monotonic);
        try self.rows.append(self.allocator, row);
    }

    fn cloneNodeSet(self: *VarLenExec, src: *const std.AutoHashMapUnmanaged(u64, void)) !std.AutoHashMapUnmanaged(u64, void) {
        var dst: std.AutoHashMapUnmanaged(u64, void) = .empty;
        errdefer dst.deinit(self.allocator);
        try dst.ensureTotalCapacity(self.allocator, src.count() + 1);
        var it = src.keyIterator();
        while (it.next()) |k| dst.putAssumeCapacity(k.*, {});
        return dst;
    }

    /// Faithful engine-direct port of PathIterator.next() drained to
    /// completion, emitting endpoint rows for one seed.
    ///
    /// SONNY-2679: this BFS applies NO tenant, RLS or per-edge visibility
    /// check to the nodes and edges it walks (PathIterator's HopScope gate has
    /// no counterpart here). It is safe only because `buildPlanIfSupported`
    /// never builds a storage-native plan for a restricted session (a concrete
    /// tenant scope, strict tenancy, or an RLS policy that may deny a row), so
    /// such a session never gets here. Fail closed if that ever changes.
    fn runSeed(self: *VarLenExec, seed_slot: u64) !void {
        if (sessionIsRestricted(self.context)) return error.RestrictedSessionOnPlannedRead;
        const seed_node = try materializeNode(self.allocator, self.graph_name, seed_slot);
        try self.owned_entities.trackNode(seed_node);

        var queue: std.ArrayList(VarLenBfsItem) = .empty;
        var front: usize = 0;
        defer {
            for (queue.items[front..]) |*it| it.node_set.deinit(self.allocator);
            queue.deinit(self.allocator);
        }
        var seed_set: std.AutoHashMapUnmanaged(u64, void) = .empty;
        {
            errdefer seed_set.deinit(self.allocator);
            try seed_set.put(self.allocator, seed_slot, {});
            try queue.append(self.allocator, .{ .last = seed_slot, .depth = 0, .node_set = seed_set });
        }

        // pending_zero_path: min_len==0 emits the seed itself (0-length path).
        if (self.min_len == 0) {
            try self.emit(seed_node, seed_slot);
        }

        var iteration_count: u64 = 0;
        while (front < queue.items.len) {
            iteration_count += 1;
            const queue_len = queue.items.len - front;
            if (iteration_count > max_iterations or queue_len > max_queue_size) break;

            var current = queue.items[front];
            front += 1;
            const depth = current.depth;

            // At max depth: never expand further. Emit if depth>=min_len
            // (mirrors the oracle's dequeue early-return branch; for max>=1 this
            // is unreachable since queued items always have depth<max, but it
            // keeps parity for the degenerate max==0 / min>max cases).
            if (depth >= self.max_len) {
                if (depth >= self.min_len) {
                    try self.emit(seed_node, current.last);
                }
                current.node_set.deinit(self.allocator);
                continue;
            }

            // SONNY-6264: every path expands, as in `execution.PathIterator`
            // (a later path through the same node at the same depth lost
            // every extension).
            const edges = try collectHopEdges(self.allocator, self.adapter, self.graph_name, current.last, self.dir);
            defer self.allocator.free(edges);
            for (edges) |edge| {
                // rel-type filter (gate guarantees <=1 type and null rel props,
                // so edgeMatchesPattern is a pure type check == oracle types[0]).
                if (!try edgeMatchesPattern(self.allocator, self.adapter, self.graph_name, edge, self.hop.rel, self.param_names, self.param_values, self.context)) continue;
                const next = edge.next_slot;
                // ACYCLIC: skip a node already on this path.
                if (current.node_set.contains(next)) continue;

                const new_depth = depth + 1;
                const meets_min = new_depth >= self.min_len;
                const reached_max = new_depth >= self.max_len;
                if (meets_min) {
                    try self.emit(seed_node, next);
                }
                if (!reached_max) {
                    var new_set = try self.cloneNodeSet(&current.node_set);
                    errdefer new_set.deinit(self.allocator);
                    try new_set.put(self.allocator, next, {});
                    try queue.append(self.allocator, .{ .last = next, .depth = new_depth, .node_set = new_set });
                }
            }
            current.node_set.deinit(self.allocator);
        }
    }
};

fn executeVarLengthEndpoint(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    plan: *const Plan,
    param_names: []const []const u8,
    param_values: []const Value,
    trace: *RuntimeTrace,
) !ExecutionResult {
    const adapter = graph_store.getGlobalAdapter() orelse return error.Unsupported;
    const chain = q.match.chains[0];
    const hop = chain.hops[0];
    const vle = plan.var_length_endpoint orelse return error.Unsupported;
    const min_len: u32 = hop.rel.min_len orelse 0;
    const max_len: u32 = hop.rel.max_len orelse return error.Unsupported;

    var rows = std.ArrayList([]Value).empty;
    defer rows.deinit(allocator);
    var owned_entities = try OwnedGraphEntities.init(allocator);
    errdefer owned_entities.deinit();

    if (!adapter.graphExists(plan.graph_name)) {
        const column_result = try buildBindingColumns(allocator, plan.binding_names, q.inline_let_bindings);
        const empty_result = ExecutionResult{
            .columns = column_result.columns,
            .rows = try rows.toOwnedSlice(allocator),
            .flags = std.ArrayList([]const u8).empty,
            .column_buffer = column_result.buffer,
        };
        owned_entities.deinit();
        return empty_result;
    }

    // Seed the start nodes from the bound seed pattern (where_clause is null by
    // gate). The endpoint filter is applied per emitted row, not here.
    const scan_start_ns = nowNs();
    var start_seek: ?StartSeek = null;
    const start_slots = try collectStartSlots(
        allocator,
        adapter,
        plan.graph_name,
        hop.left,
        null,
        param_names,
        param_values,
        context,
        null,
        &start_seek,
    );
    defer allocator.free(start_slots);
    if (trace.ops.len > 0) {
        trace.ops[0].rows = @intCast(start_slots.len);
        trace.ops[0].time_ns = elapsedSince(scan_start_ns);
        try recordStartAccess(allocator, context, &trace.ops[0], hop.left, start_seek);
    }

    var exec = VarLenExec{
        .allocator = allocator,
        .adapter = adapter,
        .graph_name = plan.graph_name,
        .q = q,
        .context = context,
        .plan = plan,
        .vle = vle,
        .hop = hop,
        .min_len = min_len,
        .max_len = max_len,
        .dir = hop.rel.dir,
        .param_names = param_names,
        .param_values = param_values,
        .rows = &rows,
        .owned_entities = owned_entities,
    };

    for (start_slots) |seed_slot| {
        try exec.runSeed(seed_slot);
    }

    const column_result = try buildBindingColumns(allocator, plan.binding_names, q.inline_let_bindings);
    const result = ExecutionResult{
        .columns = column_result.columns,
        .rows = try rows.toOwnedSlice(allocator),
        .flags = std.ArrayList([]const u8).empty,
        .column_buffer = column_result.buffer,
        .owned_graph_entities = if (owned_entities.nodes.items.len > 0 or owned_entities.edges.items.len > 0) owned_entities else null,
    };
    if (result.owned_graph_entities == null) {
        owned_entities.deinit();
    }
    return result;
}

// ---------------------------------------------------------------------------
// Multi-chain hash-join support (P3b).
//
// isAllSimpleNodeMultiChain verifies all chains are bare node patterns (no
// hops, not optional, not shortest, walk mode).  extractJoinPredicate finds
// a cross-chain equality in the WHERE clause for hash-join keying.
// executeMultiChainHashJoin collects one slot list per chain, builds a hash
// map on chain[0]'s join-key property, probes with chain[1] (or falls back
// to true-cartesian when no join key), and materializes matched pairs without
// any whole-graph snapshot clone.
// ---------------------------------------------------------------------------

const JoinPredicate = struct {
    var_a: []const u8,
    prop_a: []const u8,
    var_b: []const u8,
    prop_b: []const u8,
};

fn propertyAccessVar(expr: ast.Expr) ?struct { obj: []const u8, prop: []const u8 } {
    switch (expr) {
        .Member => |m| {
            if (m.target.* != .Ident) return null;
            return .{ .obj = m.target.*.Ident.orig, .prop = m.field };
        },
        .PropertyAccess => |pa| return .{ .obj = pa.object, .prop = pa.property },
        else => return null,
    }
}

fn extractJoinPredicate(root: ast.Expr, chain_vars: []const ?[]const u8) ?JoinPredicate {
    // SONNY-3189: an AND chain with a loop, not one recursion per AND: its
    // innermost left conjunct first, then the right ones from the bottom up,
    // the order the recursion tried them in (the first join predicate wins).
    if (root == .Binary and root.Binary.op == .And) {
        var sfa = std.heap.stackFallback(64 * @sizeOf(*const ast.Expr), std.heap.smp_allocator);
        const la = sfa.get();
        var rights: std.ArrayList(*const ast.Expr) = .empty;
        defer rights.deinit(la);
        var leaf: *const ast.Expr = &root;
        while (leaf.* == .Binary and leaf.Binary.op == .And) : (leaf = leaf.Binary.left) {
            rights.append(la, leaf.Binary.right) catch return null;
        }
        if (extractJoinPredicate(leaf.*, chain_vars)) |p| return p;
        var i = rights.items.len;
        while (i > 0) {
            i -= 1;
            if (extractJoinPredicate(rights.items[i].*, chain_vars)) |p| return p;
        }
        return null;
    }
    const expr = root;
    switch (expr) {
        .Binary => |b| {
            switch (b.op) {
                .And => return extractJoinPredicate(b.left.*, chain_vars) orelse
                    extractJoinPredicate(b.right.*, chain_vars),
                .Eq => {
                    const left_pa = propertyAccessVar(b.left.*) orelse return null;
                    const right_pa = propertyAccessVar(b.right.*) orelse return null;
                    var left_chain: ?usize = null;
                    var right_chain: ?usize = null;
                    for (chain_vars, 0..) |cv, ci| {
                        if (cv) |name| {
                            if (std.mem.eql(u8, name, left_pa.obj)) left_chain = ci;
                            if (std.mem.eql(u8, name, right_pa.obj)) right_chain = ci;
                        }
                    }
                    const lc = left_chain orelse return null;
                    const rc = right_chain orelse return null;
                    if (lc == rc) return null;
                    return JoinPredicate{
                        .var_a = left_pa.obj,
                        .prop_a = left_pa.prop,
                        .var_b = right_pa.obj,
                        .prop_b = right_pa.prop,
                    };
                },
                else => return null,
            }
        },
        else => return null,
    }
}

// Get a node property as a hash-join key using an arena allocator so no
// explicit cleanup is needed — the arena frees everything at once. NULL (or
// no property) joins nothing, as `=` with NULL is never true.
//
// SONNY-2807: the key is the canonical value key GROUP BY and DISTINCT use
// (distinct_set.writeKey), so two values join exactly when they are one
// group: numbers by exact value, whatever their type. The key was the text of
// an INT ("i:1") or a DOUBLE ("f:1"), the raw bytes of a string, and nothing
// for a decimal or any extended value: `MATCH (a:T), (b:T) WHERE a.x = b.x`
// returned no row for decimal or DOUBLE-parameter properties, an INT never
// joined a DOUBLE of the same value, and the string 'i:1' shared a key with
// the integer 1.
fn slotPropertyAsHashKey(
    arena: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    graph_name: []const u8,
    slot_id: u64,
    prop_name: []const u8,
) !?[]const u8 {
    const maybe_val = adapter.getNodeProperty(graph_name, slot_id, prop_name, arena) catch return null;
    const stored = maybe_val orelse return null;
    const decoded = try graph_storage_adapter.fromStorageProperty(arena, stored);
    var key: std.Io.Writer.Allocating = .init(arena);
    if (!try distinct_set.writeKey(&key.writer, arena, property_codec.propertyValueToValue(decoded))) return null;
    return key.written();
}

fn materializeMultiChainRow(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    plan: *const Plan,
    slot_ids: []const u64,
    binding_indices: []const usize,
    param_names: []const []const u8,
    param_values: []const Value,
    rows: *std.ArrayList([]Value),
    owned_entities: *OwnedGraphEntities,
) !void {
    var local_nodes = std.ArrayList(*graph_store.Node).empty;
    defer local_nodes.deinit(allocator);

    const binding_values = try allocator.alloc(Value, plan.binding_names.len);
    defer allocator.free(binding_values);
    for (binding_values) |*v| v.* = .{ .Null = {} };

    for (slot_ids, binding_indices) |slot_id, bind_idx| {
        const node = try materializeNode(allocator, plan.graph_name, slot_id);
        try local_nodes.append(allocator, node);
        if (bind_idx < binding_values.len) {
            binding_values[bind_idx] = .{ .Node = node };
        }
    }

    const env = Env{
        .names = plan.binding_names,
        .values = binding_values,
        .param_names = param_names,
        .param_values = param_values,
        .allocator = allocator,
        .exec_context = @constCast(&context),
    };

    const row = try buildBindingRow(allocator, q, env, binding_values);
    try read_budget.check(); // T5: budget/cancel poll at the row-materialization boundary
    _ = g_path_rows_materialized.fetchAdd(1, .monotonic);
    try rows.append(allocator, row);
    for (local_nodes.items) |n| {
        try owned_entities.trackNode(n);
    }
}

fn nestedLoopCartesian(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    plan: *const Plan,
    all_slots: []const []u64,
    chain_binding_indices: []const usize,
    param_names: []const []const u8,
    param_values: []const Value,
    rows: *std.ArrayList([]Value),
    owned_entities: *OwnedGraphEntities,
    slot_combo: []u64,
    depth: usize,
    cap: ?usize,
) !void {
    // GAP residual: early-exit at offset+limit on the pure-cartesian path.
    if (cap) |c| if (rows.items.len >= c) return;
    if (depth == all_slots.len) {
        try materializeMultiChainRow(allocator, q, context, plan, slot_combo, chain_binding_indices, param_names, param_values, rows, owned_entities);
        return;
    }
    for (all_slots[depth]) |slot_id| {
        if (cap) |c| if (rows.items.len >= c) return;
        slot_combo[depth] = slot_id;
        try nestedLoopCartesian(allocator, q, context, plan, all_slots, chain_binding_indices, param_names, param_values, rows, owned_entities, slot_combo, depth + 1, cap);
    }
}

fn executeMultiChainHashJoin(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    plan: *const Plan,
    param_names: []const []const u8,
    param_values: []const Value,
    trace: *RuntimeTrace,
) !ExecutionResult {
    const adapter = graph_store.getGlobalAdapter() orelse return error.Unsupported;

    var rows = std.ArrayList([]Value).empty;
    defer rows.deinit(allocator);
    var owned_entities = try OwnedGraphEntities.init(allocator);
    errdefer owned_entities.deinit();

    if (!adapter.graphExists(plan.graph_name)) {
        const col_result = try buildBindingColumns(allocator, plan.binding_names, q.inline_let_bindings);
        // Release the tracker only after the last fallible step: a failed
        // toOwnedSlice would otherwise run the errdefer on a freed tracker
        // (same order as the other three early-return sites).
        const empty_result = ExecutionResult{
            .columns = col_result.columns,
            .rows = try rows.toOwnedSlice(allocator),
            .flags = std.ArrayList([]const u8).empty,
            .column_buffer = col_result.buffer,
        };
        owned_entities.deinit();
        return empty_result;
    }

    const n_chains = q.match.chains.len;

    // Collect chain variables (may be null for anonymous patterns).
    const chain_vars = try allocator.alloc(?[]const u8, n_chains);
    defer allocator.free(chain_vars);
    const chain_binding_indices = try allocator.alloc(usize, n_chains);
    defer allocator.free(chain_binding_indices);

    for (q.match.chains, 0..) |chain, ci| {
        const root = if (chain.head) |head| head else chain.hops[0].left;
        chain_vars[ci] = root.name;
        // Find this chain's binding index in the plan. Bindings are added in
        // chain order by buildPlanIfSupported, so the index is ci unless an
        // anonymous name was generated.
        chain_binding_indices[ci] = blk: {
            if (root.name) |name| {
                for (plan.binding_names, 0..) |bn, bi| {
                    if (std.mem.eql(u8, bn, name)) break :blk bi;
                }
            }
            break :blk ci;
        };
    }

    // Collect start slots for each chain (pass null for where_clause: cross-chain
    // predicates can't be applied per-chain; the outer WHERE filter handles them).
    var all_slots_list = try std.ArrayList([]u64).initCapacity(allocator, n_chains);
    defer {
        for (all_slots_list.items) |slots| allocator.free(slots);
        all_slots_list.deinit(allocator);
    }

    for (q.match.chains, 0..) |chain, ci| {
        const root = if (chain.head) |head| head else chain.hops[0].left;
        const scan_start_ns = nowNs();
        var start_seek: ?StartSeek = null;
        const slots = try collectStartSlots(
            allocator,
            adapter,
            plan.graph_name,
            root,
            null,
            param_names,
            param_values,
            context,
            null,
            &start_seek,
        );
        all_slots_list.appendAssumeCapacity(slots);
        if (ci < trace.ops.len) {
            trace.ops[ci].rows = @intCast(slots.len);
            trace.ops[ci].time_ns = elapsedSince(scan_start_ns);
            try recordStartAccess(allocator, context, &trace.ops[ci], root, start_seek);
        }
    }

    const all_slots = all_slots_list.items;

    // GAP residual: cap pure-cartesian materialization at offset+limit. Safe ONLY
    // when the first offset+limit produced rows ARE the final window — no WHERE
    // residual filter, no ORDER BY (reorders), no DISTINCT/aggregate (cardinality),
    // no WITH (reshape). The hash-join branch requires where_clause != null, so this
    // cap applies only to the pure-cartesian loops.
    // SONNY-2652: the bound is `materializeWindowEnd` (null without a LIMIT);
    // an OFFSET alone used to cap the loops at offset+1 rows. A FILTER removes
    // rows after materialization exactly as a WHERE does. A GROUP BY merges
    // rows (with or without an aggregate) and a HAVING removes them, both
    // after materialization too.
    const materialize_cap: ?usize = blk: {
        if (q.where_clause != null) break :blk null;
        if (q.filter_clause != null) break :blk null;
        if (q.group_by != null) break :blk null;
        if (q.having != null) break :blk null;
        if (q.order_by != null) break :blk null;
        if (q.with_clause != null) break :blk null;
        if (q.ret.distinct) break :blk null;
        if (hasAggregationItems(q.ret.items)) break :blk null;
        break :blk materializeWindowEnd(q, param_names, param_values); // null if no limit
    };

    // Extract a cross-chain join predicate from the WHERE clause (if any).
    const join_pred: ?JoinPredicate = if (q.where_clause) |wc|
        extractJoinPredicate(wc, chain_vars)
    else
        null;

    if (n_chains == 2) {
        // Two-chain case: hash join on join key, or true-cartesian fallback.
        const slots_a = all_slots[0];
        const slots_b = all_slots[1];
        const bind_a = chain_binding_indices[0];
        const bind_b = chain_binding_indices[1];

        if (join_pred) |jp| {
            // Determine which side of the predicate corresponds to chain[0] (build)
            // and chain[1] (probe).
            const a_var = chain_vars[0];
            const a_is_left = a_var != null and std.mem.eql(u8, a_var.?, jp.var_a);
            const prop_build = if (a_is_left) jp.prop_a else jp.prop_b;
            const prop_probe = if (a_is_left) jp.prop_b else jp.prop_a;

            var key_arena = std.heap.ArenaAllocator.init(allocator);
            defer key_arena.deinit();

            var build_map = std.StringHashMap(std.ArrayList(u64)).init(allocator);
            defer {
                var it = build_map.iterator();
                while (it.next()) |entry| entry.value_ptr.deinit(allocator);
                build_map.deinit();
            }

            for (slots_a) |slot_a| {
                const key = (try slotPropertyAsHashKey(key_arena.allocator(), adapter, plan.graph_name, slot_a, prop_build)) orelse continue;
                const gop = try build_map.getOrPut(key);
                if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(u64).empty;
                try gop.value_ptr.append(allocator, slot_a);
            }

            for (slots_b) |slot_b| {
                const probe_key = (try slotPropertyAsHashKey(key_arena.allocator(), adapter, plan.graph_name, slot_b, prop_probe)) orelse continue;
                const matching = build_map.get(probe_key) orelse continue;
                for (matching.items) |slot_a| {
                    const slot_ids = [2]u64{ slot_a, slot_b };
                    const bind_ids = [2]usize{ bind_a, bind_b };
                    try materializeMultiChainRow(allocator, q, context, plan, &slot_ids, &bind_ids, param_names, param_values, &rows, owned_entities);
                }
            }
        } else {
            // True-cartesian: N×M nested loop. Early-exit at offset+limit when
            // safe (materialize_cap non-null); otherwise materialize all.
            outer: for (slots_a) |slot_a| {
                for (slots_b) |slot_b| {
                    if (materialize_cap) |cap| if (rows.items.len >= cap) break :outer;
                    const slot_ids = [2]u64{ slot_a, slot_b };
                    const bind_ids = [2]usize{ bind_a, bind_b };
                    try materializeMultiChainRow(allocator, q, context, plan, &slot_ids, &bind_ids, param_names, param_values, &rows, owned_entities);
                }
            }
        }
    } else {
        // N-chain (>2): recursive nested-loop cartesian.
        const slot_combo = try allocator.alloc(u64, n_chains);
        defer allocator.free(slot_combo);
        try nestedLoopCartesian(allocator, q, context, plan, all_slots, chain_binding_indices, param_names, param_values, &rows, owned_entities, slot_combo, 0, materialize_cap);
    }

    const col_result = try buildBindingColumns(allocator, plan.binding_names, q.inline_let_bindings);
    const result = ExecutionResult{
        .columns = col_result.columns,
        .rows = try rows.toOwnedSlice(allocator),
        .flags = std.ArrayList([]const u8).empty,
        .column_buffer = col_result.buffer,
        .owned_graph_entities = if (owned_entities.nodes.items.len > 0 or owned_entities.edges.items.len > 0) owned_entities else null,
    };
    if (result.owned_graph_entities == null) owned_entities.deinit();
    return result;
}

// GAP-0813: per-binding projection plan for multi-hop path materialization.
//
// `materializePathRow` previously called the full `materializeNode` for every
// path endpoint, which populated a `StringHashMap` of every persisted
// property + dupe'd the `graph_name`. For a query like
//
//     MATCH (a:LT_Person {lt_id: 42})-[:LT_KNOWS]->(b)-[:LT_KNOWS]->(c)
//     RETURN DISTINCT c.name, c.lt_id LIMIT 20
//
// the intermediate `b` never has its properties read by anything — the
// projection throws them away. This plan lets us:
//
//   * skip property fetch for unused bindings (`unused`),
//   * fetch only the referenced keys for partially-used bindings (`keys`),
//   * fall back to full materialize for bindings the analyzer can't prove
//     are projection-bounded (`full`).
const BindingProjection = union(enum) {
    unused,
    keys: []const []const u8,
    full,
};

/// Build a per-binding projection plan by walking every expression that
/// can read a bound variable after the path row is materialized.
///
/// Returns `null` if the caller should fall back to full materialize —
/// e.g. there are no bindings of node kind, or every binding is `full`
/// anyway (nothing to gain).
///
/// Conservative by design: any reference we don't fully understand
/// (bare `Ident("c")`, nested call on a node value, etc.) promotes the
/// binding to `full`. The returned slice + its per-binding `keys`
/// sub-slices all live on `allocator` and must be freed by
/// `freeProjectionPlan`.
fn buildProjectionPlan(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    plan: *const Plan,
) !?[]BindingProjection {
    if (plan.binding_names.len == 0) return null;

    // Start all node bindings in `unused` and all edge bindings in `full`.
    // We don't try to prune edge properties — edges typically carry 0-2
    // properties so the hashmap+dupe overhead is dwarfed by the node-side
    // cost, and edges use a different adapter path (`getAllEdgeProperties`)
    // that doesn't have a cheap single-key lookup without extra plumbing.
    var projections = try allocator.alloc(BindingProjection, plan.binding_names.len);
    errdefer allocator.free(projections);

    // Per-binding key lists, one ArrayList per node binding. Indices that
    // correspond to edge bindings stay unused.
    var key_lists = try allocator.alloc(std.ArrayList([]const u8), plan.binding_names.len);
    defer allocator.free(key_lists);
    for (key_lists) |*list| list.* = std.ArrayList([]const u8).empty;
    errdefer {
        // Free any keys we may have duped into the lists on error path.
        for (key_lists) |*list| {
            for (list.items) |k| allocator.free(k);
            list.deinit(allocator);
        }
    }

    for (projections, 0..) |*proj, idx| {
        proj.* = if (plan.binding_kinds[idx] == .node) .unused else .full;
    }

    // Analyze the union of expressions that could touch a bound variable
    // after the initial row is materialized.
    var failed = false;
    analyzeExpressionsForProjection(allocator, q, plan, projections, key_lists, &failed);

    if (failed) {
        for (key_lists) |*list| {
            for (list.items) |k| allocator.free(k);
            list.deinit(allocator);
        }
        allocator.free(projections);
        return null;
    }

    // Commit the per-binding keys from the scratch ArrayLists into the
    // returned projection slice. Keys themselves are already owned by
    // `allocator` (see `recordBindingKey`); we dedupe in place and
    // transfer ownership of the slice.
    for (projections, 0..) |*proj, idx| {
        switch (proj.*) {
            .unused => {
                // Defensive: analyzer only promotes to .keys on member
                // accesses; .unused + non-empty list shouldn't happen,
                // but clean up just in case.
                for (key_lists[idx].items) |k| allocator.free(k);
                key_lists[idx].deinit(allocator);
            },
            .keys => {
                const deduped = dedupInPlace(key_lists[idx].items, allocator);
                // Truncate the list to the dedup length before transferring.
                key_lists[idx].items = key_lists[idx].items[0..deduped];
                const owned = key_lists[idx].toOwnedSlice(allocator) catch |err| {
                    // toOwnedSlice on Zig 0.16 can OOM — treat as bail.
                    // Free remaining keys and unwind.
                    for (key_lists[idx].items) |k| allocator.free(k);
                    key_lists[idx].deinit(allocator);
                    // Free everything we already committed.
                    for (projections[0..idx]) |p| switch (p) {
                        .keys => |k| {
                            for (k) |s| allocator.free(s);
                            allocator.free(k);
                        },
                        else => {},
                    };
                    // And the remaining scratch lists.
                    for (key_lists[idx + 1 ..]) |*rest| {
                        for (rest.items) |s| allocator.free(s);
                        rest.deinit(allocator);
                    }
                    allocator.free(projections);
                    return err;
                };
                proj.* = .{ .keys = owned };
            },
            .full => {
                for (key_lists[idx].items) |k| allocator.free(k);
                key_lists[idx].deinit(allocator);
            },
        }
    }

    // If nothing is prunable (every node binding went `.full`), skip the
    // work and signal caller to take the plain path.
    var any_pruned = false;
    for (projections, 0..) |proj, idx| {
        if (plan.binding_kinds[idx] != .node) continue;
        switch (proj) {
            .unused, .keys => {
                any_pruned = true;
                break;
            },
            .full => {},
        }
    }
    if (!any_pruned) {
        freeProjectionPlan(allocator, projections);
        return null;
    }

    return projections;
}

/// Dedup a slice of owned strings in place. Duplicates are freed via
/// `allocator`. Returns the new logical length; the caller should slice
/// the backing array to that length.
fn dedupInPlace(keys: [][]const u8, allocator: std.mem.Allocator) usize {
    var write: usize = 0;
    outer: for (keys) |k| {
        for (keys[0..write]) |existing| {
            if (std.mem.eql(u8, existing, k)) {
                allocator.free(k);
                continue :outer;
            }
        }
        keys[write] = k;
        write += 1;
    }
    return write;
}

fn freeProjectionPlan(allocator: std.mem.Allocator, plan: []BindingProjection) void {
    for (plan) |proj| {
        switch (proj) {
            .keys => |keys| {
                for (keys) |k| allocator.free(k);
                allocator.free(keys);
            },
            else => {},
        }
    }
    allocator.free(plan);
}

fn analyzeExpressionsForProjection(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    plan: *const Plan,
    projections: []BindingProjection,
    key_lists: []std.ArrayList([]const u8),
    failed: *bool,
) void {
    // RETURN items
    for (q.ret.items) |item| {
        analyzeExprForProjection(allocator, item.expr, plan, projections, key_lists, failed);
        if (failed.*) return;
    }
    // Inline LET bindings (LET foo = expr AFTER match).
    for (q.inline_let_bindings) |binding| {
        analyzeExprForProjection(allocator, binding.value, plan, projections, key_lists, failed);
        if (failed.*) return;
    }
    // WHERE / FILTER — if they fire post-materialize.
    if (q.where_clause) |w| {
        analyzeExprForProjection(allocator, w, plan, projections, key_lists, failed);
        if (failed.*) return;
    }
    if (q.filter_clause) |f| {
        analyzeExprForProjection(allocator, f, plan, projections, key_lists, failed);
        if (failed.*) return;
    }
    // ORDER BY keys
    if (q.order_by) |ob| {
        for (ob.keys) |ok| {
            analyzeExprForProjection(allocator, ok.expr, plan, projections, key_lists, failed);
            if (failed.*) return;
        }
    }
    // GROUP BY / HAVING
    if (q.group_by) |gb| {
        for (gb.keys) |k| {
            analyzeExprForProjection(allocator, k, plan, projections, key_lists, failed);
            if (failed.*) return;
        }
    }
    if (q.having) |h| {
        analyzeExprForProjection(allocator, h, plan, projections, key_lists, failed);
        if (failed.*) return;
    }
    // WITH clause: if present, its items read the bound vars directly.
    if (q.with_clause) |wc| {
        for (wc.items) |item| {
            analyzeExprForProjection(allocator, item.expr, plan, projections, key_lists, failed);
            if (failed.*) return;
        }
        if (wc.order_by) |ob_ptr| {
            for (ob_ptr.keys) |ok| {
                analyzeExprForProjection(allocator, ok.expr, plan, projections, key_lists, failed);
                if (failed.*) return;
            }
        }
    }
    // Path variable assignment reads every node + edge in the row. If a
    // path var is bound, we cannot prune any node binding.
    if (q.path_variable != null) {
        for (projections, 0..) |*proj, idx| {
            if (plan.binding_kinds[idx] == .node) proj.* = .full;
        }
    }
    // SET / REMOVE / DELETE write-side operations may reference the nodes.
    // Analyzer doesn't inspect these — if any of them is present, bail.
    if (q.set_clauses.len > 0 or q.remove_clauses.len > 0 or q.delete_items.len > 0) {
        failed.* = true;
        return;
    }
    // Call clause / subqueries / next_query / CTEs / CREATE / MERGE —
    // any of these may reference the bound vars opaquely. Bail out.
    if (q.call_clause != null or q.initial_call_subquery != null or
        q.next_query != null or q.cte_list != null or
        q.create_pattern != null or q.merge_statement != null or
        q.unwind_clause != null or q.for_statement != null)
    {
        failed.* = true;
        return;
    }
}

/// Look up the binding index for a plan variable name. Case-sensitive
/// match on the binding's original identifier text.
fn findBindingIndex(plan: *const Plan, name: []const u8) ?usize {
    for (plan.binding_names, 0..) |bn, idx| {
        if (std.mem.eql(u8, bn, name)) return idx;
    }
    return null;
}

// CANARY: REQ=REQ-SONNY-3189-HAVING-WALKERS; FEATURE="PlannedReadRuntime"; ASPECT=ProjectionWalker; STATUS=TESTED; TEST=tests/test_sonny3189_grouped_having_chains.zig; OWNER=engine; UPDATED=2026-09-28
/// SONNY-3189 (round 15): the projection analysis walks every RETURN and
/// WITH item, GROUP BY key, HAVING and ORDER BY key of a planned read with a
/// hop. Round 14 looped binary and member chains, but an index or slice
/// link recursed on its target with no stack guard: `RETURN l[0][0] ... [0]`
/// with 4,000 links is one frame per link. Now every chain the parser builds
/// as long as its input (a binary link's left operand, a unary operand, and
/// the target of a member, index or slice link) is followed with a loop; a
/// link's other children (a right operand, an index, a slice's bounds) are
/// analysed after the chain's innermost operand, innermost link first: the
/// order the recursion took. They are nested expressions, bounded by the
/// parser's 128 levels.
fn analyzeExprForProjection(
    allocator: std.mem.Allocator,
    expr: ast.Expr,
    plan: *const Plan,
    projections: []BindingProjection,
    key_lists: []std.ArrayList([]const u8),
    failed: *bool,
) void {
    if (failed.*) return;
    var sfa = std.heap.stackFallback(64 * @sizeOf(*const ast.Expr), std.heap.smp_allocator);
    const la = sfa.get();
    var links: std.ArrayList(*const ast.Expr) = .empty;
    defer links.deinit(la);
    var at: *const ast.Expr = &expr;
    spine: while (true) {
        switch (at.*) {
            .Binary => |bin| {
                links.append(la, at) catch {
                    failed.* = true;
                    return;
                };
                at = bin.left;
            },
            .Index => |ix| {
                links.append(la, at) catch {
                    failed.* = true;
                    return;
                };
                at = ix.target;
            },
            .Slice => |sl| {
                links.append(la, at) catch {
                    failed.* = true;
                    return;
                };
                at = sl.target;
            },
            .Unary => |un| at = un.expr,
            // p.key → record (p, key). Down a member chain: the link whose
            // target is not a member access decides.
            .Member => |top| {
                var m = top;
                while (m.target.* == .Member) m = m.target.Member;
                if (m.target.* == .Ident) {
                    const target_ident = m.target.Ident;
                    if (findBindingIndex(plan, target_ident.orig)) |idx| {
                        if (plan.binding_kinds[idx] == .node) {
                            recordBindingKey(allocator, idx, m.field, projections, key_lists, failed);
                        }
                        break :spine;
                    }
                }
                at = m.target;
            },
            else => {
                analyzeLeafForProjection(allocator, at.*, plan, projections, key_lists, failed);
                break :spine;
            },
        }
    }
    var i = links.items.len;
    while (i > 0) {
        i -= 1;
        if (failed.*) return;
        switch (links.items[i].*) {
            .Binary => |bin| analyzeExprForProjection(allocator, bin.right.*, plan, projections, key_lists, failed),
            .Index => |ix| analyzeExprForProjection(allocator, ix.index.*, plan, projections, key_lists, failed),
            .Slice => |sl| {
                if (sl.start) |st| {
                    analyzeExprForProjection(allocator, st.*, plan, projections, key_lists, failed);
                    if (failed.*) return;
                }
                if (sl.end) |en| analyzeExprForProjection(allocator, en.*, plan, projections, key_lists, failed);
            },
            else => unreachable,
        }
    }
}

/// `analyzeExprForProjection` for an expression that is no chain link.
fn analyzeLeafForProjection(
    allocator: std.mem.Allocator,
    expr: ast.Expr,
    plan: *const Plan,
    projections: []BindingProjection,
    key_lists: []std.ArrayList([]const u8),
    failed: *bool,
) void {
    if (failed.*) return;
    switch (expr) {
        // Bare identifier — if it names a binding, we must keep full
        // props (someone is asking for the Node value itself).
        .Ident => |ident| {
            if (findBindingIndex(plan, ident.orig)) |idx| {
                // Only promote if this binding is a node. Edge bindings
                // already sit at .full per buildProjectionPlan init.
                if (plan.binding_kinds[idx] == .node) {
                    projections[idx] = .full;
                }
            }
        },
        // Chain links: `analyzeExprForProjection`.
        .Member, .Binary, .Unary, .Index, .Slice => analyzeExprForProjection(allocator, expr, plan, projections, key_lists, failed),
        .PropertyAccess => |pa| {
            if (findBindingIndex(plan, pa.object)) |idx| {
                if (plan.binding_kinds[idx] == .node) {
                    recordBindingKey(allocator, idx, pa.property, projections, key_lists, failed);
                }
            }
        },
        .Call => |call| {
            for (call.args) |arg| {
                analyzeExprForProjection(allocator, arg.*, plan, projections, key_lists, failed);
                if (failed.*) return;
            }
        },
        .List => |items| {
            for (items) |item| {
                analyzeExprForProjection(allocator, item.*, plan, projections, key_lists, failed);
                if (failed.*) return;
            }
        },
        .In => |in_expr| {
            analyzeExprForProjection(allocator, in_expr.value.*, plan, projections, key_lists, failed);
            if (failed.*) return;
            for (in_expr.set) |s| {
                analyzeExprForProjection(allocator, s.*, plan, projections, key_lists, failed);
                if (failed.*) return;
            }
        },
        .InListExpr => |ile| {
            analyzeExprForProjection(allocator, ile.value.*, plan, projections, key_lists, failed);
            if (failed.*) return;
            analyzeExprForProjection(allocator, ile.list_expr.*, plan, projections, key_lists, failed);
        },
        .IsNull => |isn| {
            analyzeExprForProjection(allocator, isn.target.*, plan, projections, key_lists, failed);
        },
        .IsUnknown => |isu| {
            analyzeExprForProjection(allocator, isu.target.*, plan, projections, key_lists, failed);
        },
        .StartsWith => |sw| {
            analyzeExprForProjection(allocator, sw.value.*, plan, projections, key_lists, failed);
            if (failed.*) return;
            analyzeExprForProjection(allocator, sw.prefix.*, plan, projections, key_lists, failed);
        },
        .EndsWith => |ew| {
            analyzeExprForProjection(allocator, ew.value.*, plan, projections, key_lists, failed);
            if (failed.*) return;
            analyzeExprForProjection(allocator, ew.suffix.*, plan, projections, key_lists, failed);
        },
        // Anything else — subqueries, exists, unknown shapes — conservatively bail.
        .InSubquery => failed.* = true,
        // Pure literals are safe — no bound-variable refs.
        .Int,
        .String,
        .Bool,
        .Null,
        .Decimal,
        .SmallIntLit,
        .BigIntLit,
        .RealLit,
        .DoubleLit,
        .CharLit,
        .VarcharLit,
        .TextLit,
        .ByteaLit,
        .JsonLit,
        .JsonbLit,
        .XmlLit,
        .UrlLit,
        .DomainLit,
        .UuidLit,
        .EnumLit,
        .ArrayLit,
        .BitLit,
        .VarBitLit,
        .Date,
        .DateTime,
        .Time,
        .LocalDateTime,
        => {},
        else => failed.* = true,
    }
}

fn recordBindingKey(
    allocator: std.mem.Allocator,
    idx: usize,
    key: []const u8,
    projections: []BindingProjection,
    key_lists: []std.ArrayList([]const u8),
    failed: *bool,
) void {
    switch (projections[idx]) {
        .unused => projections[idx] = .{ .keys = &.{} },
        .keys, .full => {},
    }
    if (projections[idx] == .full) return;
    // Dupe the key onto the caller's allocator so the scratch list owns
    // it. buildProjectionPlan re-dupes on commit, but this keeps lifetime
    // management uniform whether we commit or bail.
    const owned = allocator.dupe(u8, key) catch {
        failed.* = true;
        return;
    };
    key_lists[idx].append(allocator, owned) catch {
        allocator.free(owned);
        failed.* = true;
        return;
    };
}

fn materializePathRow(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    context: ExecutionContext,
    plan: *const Plan,
    graph_name: []const u8,
    node_slots: []const u64,
    edge_steps: []const PathEdge,
    param_names: []const []const u8,
    param_values: []const Value,
    rows: *std.ArrayList([]Value),
    owned_entities: *OwnedGraphEntities,
    projection_plan: ?[]const BindingProjection,
) !void {
    var local_nodes = std.ArrayList(*graph_store.Node).empty;
    defer local_nodes.deinit(allocator);
    var local_edges = std.ArrayList(*graph_store.Edge).empty;
    defer local_edges.deinit(allocator);

    const binding_values = try allocator.alloc(Value, plan.binding_names.len);
    defer allocator.free(binding_values);
    for (binding_values) |*value| value.* = Value{ .Null = {} };

    if (plan.root_index) |idx| {
        const root_node = try materializeNodeForBinding(allocator, graph_name, node_slots[0], projection_plan, idx);
        try local_nodes.append(allocator, root_node);
        binding_values[idx] = Value{ .Node = root_node };
    }

    for (plan.hops, 0..) |hop_binding, hop_idx| {
        const edge = try materializeEdge(allocator, graph_name, edge_steps[hop_idx]);
        try local_edges.append(allocator, edge);
        binding_values[hop_binding.rel_index] = Value{ .Edge = edge };

        const right_node = try materializeNodeForBinding(allocator, graph_name, node_slots[hop_idx + 1], projection_plan, hop_binding.right_index);
        try local_nodes.append(allocator, right_node);
        binding_values[hop_binding.right_index] = Value{ .Node = right_node };
    }

    const env = Env{
        .names = plan.binding_names,
        .values = binding_values,
        .param_names = param_names,
        .param_values = param_values,
        .allocator = allocator,
        .exec_context = @constCast(&context),
    };

    const row = try buildBindingRow(allocator, q, env, binding_values);
    try read_budget.check(); // T5: budget/cancel poll at the row-materialization boundary
    _ = g_path_rows_materialized.fetchAdd(1, .monotonic);
    try rows.append(allocator, row);
    for (local_nodes.items) |node| {
        try owned_entities.trackNode(node);
    }
    for (local_edges.items) |edge| {
        try owned_entities.trackEdge(edge);
    }
}

/// Route to the right materialize variant based on this binding's
/// projection entry. Node bindings marked `.unused` get a minimal node
/// (no property map population); `.keys` get only those keys fetched;
/// `.full` (or no projection plan at all) takes the full-materialize path.
fn materializeNodeForBinding(
    allocator: std.mem.Allocator,
    graph_name: []const u8,
    slot_id: u64,
    projection_plan: ?[]const BindingProjection,
    binding_idx: usize,
) !*graph_store.Node {
    const plan = projection_plan orelse return materializeNode(allocator, graph_name, slot_id);
    if (binding_idx >= plan.len) return materializeNode(allocator, graph_name, slot_id);
    return switch (plan[binding_idx]) {
        .full => materializeNode(allocator, graph_name, slot_id),
        .unused => materializeNodeProjected(allocator, graph_name, slot_id, &.{}),
        .keys => |keys| materializeNodeProjected(allocator, graph_name, slot_id, keys),
    };
}

/// Simple equality predicate extracted from a WHERE clause, pointing
/// into the caller's AST. Returned by `tryExtractPatternEqPredicate`.
const PatternEqPredicate = struct {
    key: []const u8,
    value: *const ast.Expr,
};

/// If `where` is a simple `<pattern_name>.<key> = <literal-ish>` (or the
/// mirror with the property on the right), return the property key + the
/// literal-side expression. Returns null for anything else — AND-trees,
/// OR-trees, ranges, cross-variable joins, etc. — to keep the fast path
/// conservative.
///
/// The parser lowers `p.key` into `.Member{ .target = Ident("p"),
/// .field = "key" }`; the legacy `.PropertyAccess` shape is also
/// accepted for forward-compat.
///
/// This is the WHERE-side parity of the inline-prop fast path below:
/// `MATCH (p:Label) WHERE p.key = 42` should hit the adapter-level
/// property index just like `MATCH (p:Label {key: 42})` does (GAP-0808
/// via GAP-0809).
fn propertyAccessMatches(expr: ast.Expr, pattern_name: []const u8) ?[]const u8 {
    return switch (expr) {
        .Member => |m| blk: {
            const target = m.target.*;
            if (target != .Ident) break :blk null;
            // Match on the original identifier text; patterns are
            // case-sensitive at this layer (consistent with property-
            // access evaluation elsewhere in the executor).
            if (!std.mem.eql(u8, target.Ident.orig, pattern_name)) break :blk null;
            break :blk m.field;
        },
        .PropertyAccess => |pa| blk: {
            if (!std.mem.eql(u8, pa.object, pattern_name)) break :blk null;
            break :blk pa.property;
        },
        else => null,
    };
}

fn tryExtractPatternEqPredicate(
    pattern_name: ?[]const u8,
    where: ast.Expr,
) ?PatternEqPredicate {
    const name = pattern_name orelse return null;
    const bin = switch (where) {
        .Binary => |b| b,
        else => return null,
    };
    if (bin.op != .Eq) return null;

    // Two shapes: `name.key = literal` or `literal = name.key`.
    if (propertyAccessMatches(bin.left.*, name)) |key| {
        if (!pattern_helpers.containsVariableReference(bin.right.*)) {
            return .{ .key = key, .value = bin.right };
        }
    }
    if (propertyAccessMatches(bin.right.*, name)) |key| {
        if (!pattern_helpers.containsVariableReference(bin.left.*)) {
            return .{ .key = key, .value = bin.left };
        }
    }
    return null;
}

fn collectStartSlots(
    allocator: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    graph_name: []const u8,
    pattern: ast.NodePattern,
    /// `staleLabelIndexThreshold`, or null. Never a cap on the slots returned.
    stale_index_threshold: ?usize,
    param_names: []const []const u8,
    param_values: []const Value,
    context: ExecutionContext,
    where_clause: ?ast.Expr,
    /// SONNY-1335: set to the exact-index seek the slots came from, if any.
    seek_out: ?*?StartSeek,
) ![]u64 {
    if (seek_out) |o| o.* = null;
    if (!adapter.graphExists(graph_name)) {
        return try allocator.alloc(u64, 0);
    }

    // GAP-0808 point-read fast path — FIXED to use the ADAPTER index.
    //
    // First land used the store-level `merge_prop_index`, which is
    // populated only by live `setNodeProperty` calls and is empty after
    // a server restart (the store reconstructs node records lazily from
    // the adapter on demand but doesn't rebuild the merge index). A
    // post-restart point-read therefore returned zero rows even when the
    // data was present. That's a correctness bug.
    //
    // The adapter-level `exact_node_property_index` IS persisted to disk
    // and rebuilt on startup (see `graph_storage_adapter.openGraph`'s
    // "property index loaded from disk" / "rebuilt from scan" branches).
    // Use it instead, via `getCandidateNodesByLabelAndProperty`. Candidates
    // may include hash collisions; we verify each via
    // `nodeMatchesPatternBySlot` so the final result exactly matches what
    // the scan-path below would produce.
    //
    // For `(:Label {key: scalar})` this reduces `O(|label posting list|)`
    // to `O(|hash-bucket|)` — typically 1 on well-distributed keys. For
    // the loadtest's 500-2000-node scenarios this is the ~20x QPS win.
    //
    // GAP-0809: extended to also fire on `MATCH (p:Label) WHERE p.key =
    // literal`. Before: WHERE-style queries fell back to a full label
    // scan + post-filter (~900 ms on 5k nodes vs ~290 µs for the inline
    // variant — a 3000× gap). The `fp_key` / `fp_value` prelude below
    // reads from pattern.props when present, otherwise tries to extract
    // a single simple equality from the WHERE clause. Subsequent WHERE
    // evaluation is still performed by the normal filter stage, so even
    // if the extracted predicate is a subset of WHERE, correctness is
    // preserved.
    fp: {
        if (pattern.labels.len != 1) break :fp;

        // GAP-ENT-0001 Bug A fix: pick the most-selective indexed inline prop
        // (mirrors node_scan_stream.seekIndexedCandidates). Previously the block
        // required exactly ONE inline prop and bailed for composite patterns —
        // `(p:Taxon {source, source_id})` has two, so the fp: fired the O(graph)
        // label scan at 14.27M nodes. Now we loop ALL props, probe each indexed
        // prop's posting length via countCandidateNodesByLabelAndProperty, and
        // seed from the smallest (most selective). Non-indexed props are left to
        // per-candidate verification by nodeMatchesPatternBySlot (invariant 2).
        // Seed key+value are set atomically so neither is ever valid without
        // the other — eliminates the `undefined` field and the dead `orelse`.
        var seed: ?struct { key: []const u8, pv: graph_store.PropertyValue } = null;

        if (pattern.props) |props| {
            if (props.len == 0) break :fp;
            const prop_env = Env{
                .names = &.{},
                .values = &.{},
                .param_names = param_names,
                .param_values = param_values,
                .allocator = allocator,
            };
            var best_len: usize = std.math.maxInt(usize);
            for (props) |prop| {
                if (pattern_helpers.containsVariableReference(prop.value.*)) continue;
                // GAP-0900 Layer-3 (Fix 2): in lean-index mode only MERGE/declared
                // keys are present in the exact property index. An empty result from
                // a non-indexed key is meaningless — skip it and try the next prop.
                // No-op when lean mode is off (shouldIndexProperty is then true for all).
                if (!graph_store.shouldIndexProperty(prop.key)) continue;
                const expected_val = eval.evalExpr(allocator, prop.value.*, prop_env) catch continue;
                const pv: graph_store.PropertyValue = switch (expected_val) {
                    .Str => |s| .{ .String = s },
                    .Int => |i| .{ .Int = i },
                    .Bool => |b| .{ .Bool = b },
                    else => continue,
                };
                const plen = adapter.countCandidateNodesByLabelAndProperty(graph_name, pattern.labels[0], prop.key, pv) catch continue;
                if (plen < best_len) {
                    best_len = plen;
                    seed = .{ .key = prop.key, .pv = pv };
                    // zero postings = authoritative miss for an indexed key;
                    // one posting = unique hit — neither can be beaten by any other prop.
                    if (plen <= 1) break;
                }
            }
            if (seed == null) break :fp; // no indexed prop → fall to label-scan path
        } else if (where_clause) |wc| {
            const extracted = tryExtractPatternEqPredicate(pattern.name, wc) orelse break :fp;
            // GAP-0900 Layer-3 (Fix 2): same lean-index guard as the props arm above.
            if (!graph_store.shouldIndexProperty(extracted.key)) break :fp;
            const prop_env = Env{
                .names = &.{},
                .values = &.{},
                .param_names = param_names,
                .param_values = param_values,
                .allocator = allocator,
            };
            const expected_val = eval.evalExpr(allocator, extracted.value.*, prop_env) catch break :fp;
            const seed_pv: graph_store.PropertyValue = switch (expected_val) {
                .Str => |s| graph_store.PropertyValue{ .String = s },
                // SONNY-2807: `=` compares numbers by exact value, as the
                // exact index keys them, so the integer's own posting is every
                // node `=` can find (a stored DOUBLE 2^53 is not 2^53 + 1).
                .Int => |i| graph_store.PropertyValue{ .Int = i },
                .Bool => |b| graph_store.PropertyValue{ .Bool = b },
                else => break :fp,
            };
            seed = .{ .key = extracted.key, .pv = seed_pv };
        } else {
            break :fp;
        }

        const s = seed orelse break :fp;
        const candidates = adapter.getCandidateNodesByLabelAndProperty(graph_name, pattern.labels[0], s.key, s.pv, allocator) catch break :fp;
        defer allocator.free(candidates);

        var verified = try std.ArrayList(u64).initCapacity(allocator, candidates.len);
        defer verified.deinit(allocator);
        for (candidates) |slot_id| {
            if (try nodeMatchesPatternBySlot(allocator, adapter, graph_name, slot_id, pattern, param_names, param_values, context)) {
                try verified.append(allocator, slot_id);
            }
        }
        const out = try verified.toOwnedSlice(allocator);
        if (seek_out) |o| o.* = .{ .label = pattern.labels[0], .key = s.key };
        return out;
    }

    const initial = if (pattern.labels.len > 0)
        try adapter.getNodesByLabel(graph_name, pattern.labels[0], allocator)
    else blk: {
        const scan_entries = try adapter.scanAllNodes(graph_name, allocator);
        defer allocator.free(scan_entries);
        var slots = try std.ArrayList(u64).initCapacity(allocator, scan_entries.len);
        defer slots.deinit(allocator);
        for (scan_entries) |entry| {
            try slots.append(allocator, entry.slot_id);
        }
        break :blk try slots.toOwnedSlice(allocator);
    };
    errdefer allocator.free(initial);

    // Fewer label-index slots than the window needs: the index may be stale,
    // so collect the start slots from a full scan instead.
    if (stale_index_threshold) |needed| {
        if (pattern.labels.len > 0 and initial.len < needed) {
            allocator.free(initial);
            return scanAndFilterStartSlots(allocator, adapter, graph_name, pattern, param_names, param_values, context);
        }
    }

    if (pattern.labels.len <= 1 and pattern.props == null) {
        return initial;
    }

    var filtered = try std.ArrayList(u64).initCapacity(allocator, initial.len);
    defer filtered.deinit(allocator);
    for (initial) |slot_id| {
        if (try nodeMatchesPatternBySlot(allocator, adapter, graph_name, slot_id, pattern, param_names, param_values, context)) {
            try filtered.append(allocator, slot_id);
        }
    }
    allocator.free(initial);
    return try filtered.toOwnedSlice(allocator);
}

fn scanAndFilterStartSlots(
    allocator: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    graph_name: []const u8,
    pattern: ast.NodePattern,
    param_names: []const []const u8,
    param_values: []const Value,
    context: ExecutionContext,
) ![]u64 {
    const scan_entries = try adapter.scanAllNodes(graph_name, allocator);
    defer allocator.free(scan_entries);

    var filtered = try std.ArrayList(u64).initCapacity(allocator, scan_entries.len);
    defer filtered.deinit(allocator);

    for (scan_entries) |entry| {
        if (try nodeMatchesPatternBySlot(allocator, adapter, graph_name, entry.slot_id, pattern, param_names, param_values, context)) {
            try filtered.append(allocator, entry.slot_id);
        }
    }

    return try filtered.toOwnedSlice(allocator);
}

fn flipRelDir(dir: ast.RelDir) ast.RelDir {
    return switch (dir) {
        .right => .left,
        .left => .right,
        .undirected => .undirected,
    };
}

fn collectHopEdges(
    allocator: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    graph_name: []const u8,
    node_slot: u64,
    dir: ast.RelDir,
) ![]PathEdge {
    var edges = std.ArrayList(PathEdge).empty;
    defer edges.deinit(allocator);

    switch (dir) {
        .right => {
            var out = try adapter.iterateOutgoingEdges(graph_name, node_slot, allocator);
            defer out.deinit();
            while (try out.next()) |entry| {
                try edges.append(allocator, .{
                    .edge_id = entry.edge_id,
                    .actual_from_slot = node_slot,
                    .actual_to_slot = entry.neighbor,
                    .next_slot = entry.neighbor,
                    .rel_type = entry.rel_type,
                    .prop_head = entry.prop_head,
                });
            }
        },
        .left => {
            var incoming = try adapter.iterateIncomingEdges(graph_name, node_slot, allocator);
            defer incoming.deinit();
            while (try incoming.next()) |entry| {
                try edges.append(allocator, .{
                    .edge_id = entry.edge_id,
                    .actual_from_slot = entry.neighbor,
                    .actual_to_slot = node_slot,
                    .next_slot = entry.neighbor,
                    .rel_type = entry.rel_type,
                    // SONNY-6266: from the edge index (`edgePropHeadFromIndex`).
                    .prop_head = try adapter.edgePropHeadFromIndex(graph_name, entry.neighbor, entry.edge_id, entry.prop_head),
                });
            }
        },
        .undirected => {
            var seen = std.AutoHashMap(u64, void).init(allocator);
            defer seen.deinit();

            var out = try adapter.iterateOutgoingEdges(graph_name, node_slot, allocator);
            defer out.deinit();
            while (try out.next()) |entry| {
                if (seen.contains(entry.edge_id)) continue;
                try seen.put(entry.edge_id, {});
                try edges.append(allocator, .{
                    .edge_id = entry.edge_id,
                    .actual_from_slot = node_slot,
                    .actual_to_slot = entry.neighbor,
                    .next_slot = entry.neighbor,
                    .rel_type = entry.rel_type,
                    .prop_head = entry.prop_head,
                });
            }

            var incoming = try adapter.iterateIncomingEdges(graph_name, node_slot, allocator);
            defer incoming.deinit();
            while (try incoming.next()) |entry| {
                if (seen.contains(entry.edge_id)) continue;
                try seen.put(entry.edge_id, {});
                try edges.append(allocator, .{
                    .edge_id = entry.edge_id,
                    .actual_from_slot = entry.neighbor,
                    .actual_to_slot = node_slot,
                    .next_slot = entry.neighbor,
                    .rel_type = entry.rel_type,
                    // SONNY-6266: from the edge index (`edgePropHeadFromIndex`).
                    .prop_head = try adapter.edgePropHeadFromIndex(graph_name, entry.neighbor, entry.edge_id, entry.prop_head),
                });
            }
        },
    }

    return try edges.toOwnedSlice(allocator);
}

fn nodeMatchesPatternBySlot(
    allocator: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    graph_name: []const u8,
    slot_id: u64,
    pattern: ast.NodePattern,
    param_names: []const []const u8,
    param_values: []const Value,
    context: ExecutionContext,
) !bool {
    const labels = try adapter.getNodeLabels(graph_name, slot_id, allocator);
    defer {
        for (labels) |label| allocator.free(label);
        allocator.free(labels);
    }

    if (!labelsContainAll(labels, pattern.labels)) {
        return false;
    }
    if (pattern.props == null) return true;

    var props = try adapter.getAllNodeProperties(graph_name, slot_id, allocator);
    defer freeStoragePropertyMap(allocator, &props);

    return propsMatch(allocator, pattern.props.?, &props, param_names, param_values, context);
}

fn edgeMatchesPattern(
    allocator: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    graph_name: []const u8,
    edge: PathEdge,
    pattern: ast.RelPattern,
    param_names: []const []const u8,
    param_values: []const Value,
    context: ExecutionContext,
) !bool {
    if (pattern.types.len > 0) {
        const rel_name = try edgeTypeName(allocator, graph_name, edge.rel_type);
        defer allocator.free(rel_name);

        var matched = false;
        for (pattern.types) |rel_type| {
            if (std.mem.eql(u8, rel_name, rel_type)) {
                matched = true;
                break;
            }
        }
        if (!matched) return false;
    }

    if (pattern.props == null) return true;

    // Pass the source-node SLOT id (shard-striped) so the adapter routes
    // via the per-shard engine that owns the edge's property pages. See
    // graph_storage_adapter.getAllEdgeProperties.
    var props = try adapter.getAllEdgeProperties(graph_name, edge.actual_from_slot, edge.prop_head, allocator);
    defer freeStoragePropertyMap(allocator, &props);

    return propsMatch(allocator, pattern.props.?, &props, param_names, param_values, context);
}

fn propsMatch(
    allocator: std.mem.Allocator,
    props: []ast.Property,
    actual_props: *std.StringHashMap(gs.PropertyValue),
    param_names: []const []const u8,
    param_values: []const Value,
    context: ExecutionContext,
) !bool {
    for (props) |prop| {
        const expected = eval.evalExpr(allocator, prop.value.*, Env{
            .names = &.{},
            .values = &.{},
            .param_names = param_names,
            .param_values = param_values,
            .allocator = allocator,
            .exec_context = @constCast(&context),
        }) catch return false;
        const actual = actual_props.get(prop.key) orelse return false;
        // SONNY-2806: by value, as the legacy executor compares (a decimal by
        // representation, a DOUBLE and every extended value never). A stored
        // value that cannot be decoded fails the read.
        if (!try stored_property_equality.matches(allocator, expected, actual)) {
            return false;
        }
    }
    return true;
}

/// GAP-0813: like `materializeNode` but fetches only the property keys
/// named in `needed_keys`. Pass an empty slice when no properties are
/// required — the resulting Node still has its id, labels and graph_name
/// populated, just an empty property map. This skips the per-node
/// `getAllNodeProperties` hashmap+dupe work.
fn materializeNodeProjected(
    allocator: std.mem.Allocator,
    graph_name: []const u8,
    slot_id: u64,
    needed_keys: []const []const u8,
) !*graph_store.Node {
    const scratch = scratchOr(allocator);

    const adapter = graph_store.getGlobalAdapter() orelse return error.Unsupported;
    const store = graph_store.getGlobalStore(allocator);
    const external_id = try resolveExternalNodeId(allocator, adapter, store, graph_name, slot_id);

    const labels = try adapter.getNodeLabels(graph_name, slot_id, scratch);
    errdefer {
        for (labels) |label| scratch.free(label);
        scratch.free(labels);
    }

    const node = try allocator.create(graph_store.Node);
    errdefer allocator.destroy(node);
    node.* = .{
        .id = external_id,
        .labels = labels,
        .properties = graph_store.CompactPropertyMap.init(scratch),
        .graph_name = try scratch.dupe(u8, graph_name),
    };
    errdefer {
        node.properties.deinit();
        scratch.free(node.graph_name);
    }

    // Per-key lookup: `getNodeProperty` uses a per-page directory hash
    // scan (PERF-0023 in graph_storage/prop_store.zig). For the 1-2
    // keys typical of projection-pruned reads this is dramatically
    // cheaper than `getAllNodeProperties` — no iterator state, no full
    // hashmap population, no dupe of every persisted key.
    for (needed_keys) |key| {
        const maybe_val = adapter.getNodeProperty(graph_name, slot_id, key, scratch) catch |err| switch (err) {
            error.NodeNotFound => return error.NodeNotFound,
            else => return err,
        };
        const val = maybe_val orelse continue;
        defer freeStoragePropertyValue(scratch, val);
        const decoded = try graph_storage_adapter.fromStorageProperty(scratch, val);
        const owned_key = try scratch.dupe(u8, key);
        try node.properties.put(owned_key, decoded);
    }

    return node;
}

pub fn materializeNode(allocator: std.mem.Allocator, graph_name: []const u8, slot_id: u64) !*graph_store.Node {
    // Task 1.5 / GAP-0806: the Node struct itself stays on `allocator`
    // (OwnedGraphEntities.deinit destroys it). All interior bytes go through
    // `scratch` — the per-query arena when installed — so they drop with the
    // query instead of leaking row-by-row. REQ-EXEC-MATERIALIZE-OWNERSHIP-002:
    // the two non-arena callers (materialized-view refresh, distributed local
    // fragment) install their own scoped arena so their interior drops too.
    const scratch = scratchOr(allocator);

    const adapter = graph_store.getGlobalAdapter() orelse return error.Unsupported;
    const store = graph_store.getGlobalStore(allocator);
    const external_id = try resolveExternalNodeId(allocator, adapter, store, graph_name, slot_id);

    const labels = try adapter.getNodeLabels(graph_name, slot_id, scratch);
    errdefer {
        for (labels) |label| scratch.free(label);
        scratch.free(labels);
    }

    const node = try allocator.create(graph_store.Node);
    errdefer allocator.destroy(node);
    node.* = .{
        .id = external_id,
        .labels = labels,
        .properties = graph_store.CompactPropertyMap.init(scratch),
        .graph_name = try scratch.dupe(u8, graph_name),
    };
    errdefer {
        node.properties.deinit();
        scratch.free(node.graph_name);
    }

    var props = try adapter.getAllNodeProperties(graph_name, slot_id, scratch);
    defer freeStoragePropertyMap(scratch, &props);

    var iter = props.iterator();
    while (iter.next()) |entry| {
        const key = try scratch.dupe(u8, entry.key_ptr.*);
        const value = try graph_storage_adapter.fromStorageProperty(scratch, entry.value_ptr.*);
        try node.properties.put(key, value);
    }

    return node;
}

fn materializeEdge(allocator: std.mem.Allocator, graph_name: []const u8, edge_step: PathEdge) !*graph_store.Edge {
    // Task 1.5 / GAP-0806: mirror of `materializeNode` — Edge struct stays on
    // `allocator`; interior bytes route through the per-query arena.
    const scratch = scratchOr(allocator);

    const adapter = graph_store.getGlobalAdapter() orelse return error.Unsupported;
    const store = graph_store.getGlobalStore(allocator);
    // SONNY-3350: read with the IdMap pinned (`GraphStore.idMapEdgeId`).
    const edge_id = store.idMapEdgeId(graph_name, edge_step.edge_id) orelse return error.EdgeSlotMappingMissing;
    const from_id = try resolveExternalNodeId(allocator, adapter, store, graph_name, edge_step.actual_from_slot);
    const to_id = try resolveExternalNodeId(allocator, adapter, store, graph_name, edge_step.actual_to_slot);

    const edge = try allocator.create(graph_store.Edge);
    errdefer allocator.destroy(edge);
    edge.* = .{
        .id = edge_id,
        .from_id = from_id,
        .to_id = to_id,
        .label = try edgeTypeName(scratch, graph_name, edge_step.rel_type),
        .properties = graph_store.CompactPropertyMap.init(scratch),
        .graph_name = try scratch.dupe(u8, graph_name),
    };
    errdefer {
        edge.properties.deinit();
        scratch.free(edge.label);
        scratch.free(edge.graph_name);
    }

    // Source-node SLOT id (shard-striped) for correct routing — see
    // graph_storage_adapter.getAllEdgeProperties.
    var props = try adapter.getAllEdgeProperties(graph_name, edge_step.actual_from_slot, edge_step.prop_head, scratch);
    defer freeStoragePropertyMap(scratch, &props);

    var iter = props.iterator();
    while (iter.next()) |entry| {
        const key = try scratch.dupe(u8, entry.key_ptr.*);
        const value = try graph_storage_adapter.fromStorageProperty(scratch, entry.value_ptr.*);
        try edge.properties.put(key, value);
    }

    return edge;
}

/// Resolve the external (public) node ID for a given adapter slot.
/// First checks the in-memory IdMap; if missing, falls back to reading the
/// persisted `__geode_internal_node_id` property from the adapter and
/// back-fills the IdMap so subsequent lookups are O(1).
fn resolveExternalNodeId(
    allocator: std.mem.Allocator,
    adapter: *graph_storage_adapter.StorageAdapter,
    store: *graph_store.GraphStore,
    graph_name: []const u8,
    slot_id: u64,
) !u64 {
    // Fast path: IdMap already has the mapping. SONNY-3350: read with the
    // map pinned (`GraphStore.idMapNodeId`).
    if (store.idMapNodeId(graph_name, slot_id)) |id| return id;

    // Slow path: read the persisted public ID property from the adapter.
    // SONNY-3348 round 18 (review M1): a resource limit fails the query (it
    // was swallowed, and the slot used as the id: a wrong row).
    // SONNY-3348 round 19 (review m4): only a node or graph that is gone
    // is skipped; any other read error (an engine I/O error) fails the
    // query instead of dropping the row silently.
    const stored = adapter.getNodeProperty(graph_name, slot_id, graph_store.INTERNAL_NODE_ID_PROPERTY_KEY, allocator) catch |err| switch (err) {
        error.NodeNotFound, error.GraphNotFound => return error.NodeNotFound,
        else => return err,
    };
    if (stored) |stored_prop| {
        defer freeStoragePropertyValue(allocator, stored_prop);
        const public_id: ?u64 = switch (stored_prop) {
            .string => |text| graph_store.parsePersistedPublicId(text),
            .int => |n| if (n >= 0) @as(u64, @intCast(n)) else null,
            else => null,
        };
        if (public_id) |pid| {
            // Back-fill the IdMap for future lookups (SONNY-3350: pinned).
            store.idMapBackfillNode(graph_name, pid, slot_id);
            return pid;
        }
    }

    // Neither the IdMap nor the persisted property has a public id for this
    // slot: the node is gone (a DROP GRAPH, or a delete, after the scan read
    // the slot). SONNY-3348 round 18 (review M1): the caller skips it. The
    // slot was returned as the node's id, a row with an id no node has.
    return error.NodeNotFound;
}

fn buildColumns(allocator: std.mem.Allocator, items: []const ast.ReturnItem) !struct { columns: [][]const u8, buffer: []u8 } {
    var names = try std.ArrayList([]const u8).initCapacity(allocator, items.len);
    defer names.deinit(allocator);

    for (items) |item| {
        const name = item.alias orelse switch (item.expr) {
            .Ident => |ident| ident.orig,
            else => "column",
        };
        try names.append(allocator, name);
    }

    const columns = try execution.allocateColumnStrings(allocator, names.items);
    return .{ .columns = columns.columns, .buffer = columns.buffer };
}

fn buildBindingColumns(
    allocator: std.mem.Allocator,
    binding_names: []const []const u8,
    inline_let_bindings: []const ast.LetBinding,
) !struct { columns: [][]const u8, buffer: []u8 } {
    var names = try std.ArrayList([]const u8).initCapacity(allocator, binding_names.len + inline_let_bindings.len);
    defer names.deinit(allocator);

    try names.appendSlice(allocator, binding_names);
    for (inline_let_bindings) |binding| {
        try names.append(allocator, binding.variable);
    }

    const columns = try execution.allocateColumnStrings(allocator, names.items);
    return .{ .columns = columns.columns, .buffer = columns.buffer };
}

fn buildBindingRow(
    allocator: std.mem.Allocator,
    q: *const ast.Query,
    env: Env,
    binding_values: []const Value,
) ![]Value {
    const total_values = binding_values.len + q.inline_let_bindings.len;
    const row = try allocator.alloc(Value, total_values);

    for (binding_values, 0..) |value, idx| {
        row[idx] = value;
    }
    for (q.inline_let_bindings, 0..) |binding, idx| {
        row[binding_values.len + idx] = try eval.evalExpr(allocator, binding.value, env);
    }

    return row;
}

fn transformResultRows(
    allocator: std.mem.Allocator,
    input_result: ExecutionResult,
    with_clause: ast.WithClause,
    group_by: ?ast.GroupBy,
    having: ?ast.Expr,
) !ExecutionResult {
    return transformResultRowsWithParams(allocator, input_result, with_clause, group_by, having, &.{}, &.{});
}

fn transformResultRowsWithParams(
    allocator: std.mem.Allocator,
    input_result: ExecutionResult,
    with_clause: ast.WithClause,
    group_by: ?ast.GroupBy,
    having: ?ast.Expr,
    param_names: []const []const u8,
    param_values: []const Value,
) !ExecutionResult {
    return execution.executeWithClauseWithGroupByAndParams(allocator, input_result, with_clause, group_by, having, param_names, param_values);
}

fn applyResultFilters(
    allocator: std.mem.Allocator,
    result: *ExecutionResult,
    where_expr: ?ast.Expr,
    filter_expr: ?ast.Expr,
    context: ExecutionContext,
    param_names: []const []const u8,
    param_values: []const Value,
    trace_op: *RuntimeOp,
) !void {
    const start_ns = nowNs();
    trace_op.input_rows = @intCast(result.rows.len);

    var filtered_rows = try std.ArrayList([]Value).initCapacity(allocator, result.rows.len);
    defer filtered_rows.deinit(allocator);

    // CANARY: REQ=REQ-SONNY-6296-PLANNED-WHERE-ERRORS; FEATURE="PlannedRead"; ASPECT=WhereErrorsFailTheQuery; STATUS=TESTED; TEST=tests/test_sonny6296_legacy_read_gaps.zig; OWNER=execution; UPDATED=2026-11-13
    // SONNY-6296 (5): an error evaluating the WHERE or the FILTER for a row
    // fails the query (ISO/IEC 39075:2024 19.1 GR 1 evaluates the search
    // condition for every row; an exception it raises is the statement's),
    // as on the other executors. Only a limit (SONNY-3251) and an FLE read
    // refusal (SONNY-6327) did; any other error was the row's false, so
    // `WHERE t.k + 9223372036854775807 > 0` answered over the rows that did
    // not overflow. Every row is decided before any is freed: an error
    // leaves `result` whole for the caller to free once (a row freed here
    // before a later row's error was freed again).
    const keep = try allocator.alloc(bool, result.rows.len);
    defer allocator.free(keep);
    for (result.rows, keep) |row, *k| {
        const env = Env{
            .names = result.columns,
            .values = row,
            .param_names = param_names,
            .param_values = param_values,
            .allocator = allocator,
            .exec_context = @constCast(&context),
        };
        const passes_where = if (where_expr) |expr| truthyPredicate(try eval.evalExpr(allocator, expr, env)) else true;
        k.* = passes_where and if (filter_expr) |expr| truthyPredicate(try eval.evalExpr(allocator, expr, env)) else true;
    }
    for (result.rows, keep) |row, k| {
        if (k) filtered_rows.appendAssumeCapacity(row) else allocator.free(row);
    }

    const old_rows = result.rows;
    result.rows = try filtered_rows.toOwnedSlice(allocator);
    allocator.free(old_rows);
    trace_op.rows = @intCast(result.rows.len);
    trace_op.time_ns = elapsedSince(start_ns);
}

fn applyDistinctStage(allocator: std.mem.Allocator, result: *ExecutionResult, trace_op: *RuntimeOp) !void {
    const start_ns = nowNs();
    trace_op.input_rows = @intCast(result.rows.len);
    try result_utils.applyDistinct(allocator, result);
    trace_op.rows = @intCast(result.rows.len);
    trace_op.time_ns = elapsedSince(start_ns);
}

fn applySortStage(
    allocator: std.mem.Allocator,
    result: *ExecutionResult,
    order: ast.OrderBy,
    return_items: []const ast.ReturnItem,
    trace_op: *RuntimeOp,
) !void {
    const start_ns = nowNs();
    trace_op.input_rows = @intCast(result.rows.len);
    try execution.sortRowsEx(allocator, result, order, return_items);
    trace_op.rows = @intCast(result.rows.len);
    trace_op.time_ns = elapsedSince(start_ns);
}

fn applyWindowStage(
    allocator: std.mem.Allocator,
    result: *ExecutionResult,
    offset_literal: ?usize,
    offset_param: ?[]const u8,
    limit_literal: ?usize,
    limit_param: ?[]const u8,
    param_names: []const []const u8,
    param_values: []const Value,
    trace_op: *RuntimeOp,
) !void {
    const start_ns = nowNs();
    trace_op.input_rows = @intCast(result.rows.len);

    const offset = offset_literal orelse resolveWindowValue(null, offset_param, param_names, param_values) orelse 0;
    const end_limit = if (limit_literal) |value|
        @min(result.rows.len, std.math.add(usize, offset, value) catch std.math.maxInt(usize))
    else if (resolveWindowValue(null, limit_param, param_names, param_values)) |limit_value|
        @min(result.rows.len, std.math.add(usize, offset, limit_value) catch std.math.maxInt(usize))
    else
        result.rows.len;

    if (offset != 0 or end_limit != result.rows.len) {
        try execution.applyRowWindow(allocator, result, offset, end_limit);
    }

    trace_op.rows = @intCast(result.rows.len);
    trace_op.time_ns = elapsedSince(start_ns);
}

fn transferOwnedGraphEntities(source: *ExecutionResult, destination: *ExecutionResult) void {
    destination.owned_graph_entities = source.owned_graph_entities;
    source.owned_graph_entities = null;
}

fn deinitResultKeepingOwnedGraphEntities(allocator: std.mem.Allocator, result: *ExecutionResult) void {
    result.owned_graph_entities = null;
    result.deinit(allocator);
}

fn stripWithExecutionModifiers(with_clause: ast.WithClause) ast.WithClause {
    var stripped = with_clause;
    stripped.distinct = false;
    stripped.order_by = null;
    stripped.limit = null;
    stripped.offset = null;
    stripped.limit_param = null;
    stripped.offset_param = null;
    return stripped;
}

fn resolveWindowValue(
    literal: ?usize,
    param_name: ?[]const u8,
    param_names: []const []const u8,
    param_values: []const Value,
) ?usize {
    if (literal) |value| return value;
    if (param_name) |name| {
        for (param_names, param_values) |param, value| {
            if (!std.mem.eql(u8, param, name)) continue;
            return switch (value) {
                .Int => |int_value| if (int_value >= 0) @as(usize, @intCast(int_value)) else null,
                else => null,
            };
        }
    }
    return null;
}

fn passesPredicates(allocator: std.mem.Allocator, q: *const ast.Query, env: Env) bool {
    if (q.where_clause) |where_expr| {
        const value = eval.evalExpr(allocator, where_expr, env) catch return false;
        if (!truthyPredicate(value)) return false;
    }
    if (q.filter_clause) |filter_expr| {
        const value = eval.evalExpr(allocator, filter_expr, env) catch return false;
        if (!truthyPredicate(value)) return false;
    }
    return true;
}

/// SONNY-6425: only the Boolean True keeps a row (ISO/IEC 39075 19.1 GR2);
/// a non-zero integer did.
fn truthyPredicate(value: Value) bool {
    return switch (value) {
        .Bool => |boolean| boolean,
        else => false,
    };
}

fn labelsContainAll(actual: []const []const u8, required: []const []const u8) bool {
    for (required) |required_label| {
        var found = false;
        for (actual) |actual_label| {
            if (std.mem.eql(u8, actual_label, required_label)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn freeTrackedEntities(allocator: std.mem.Allocator, nodes: []const *graph_store.Node, edges: []const *graph_store.Edge) void {
    for (nodes) |node| {
        execution.destroyOwnedNode(allocator, @constCast(node));
    }
    for (edges) |edge| {
        execution.destroyOwnedEdge(allocator, @constCast(edge));
    }
}

// CANARY: REQ=REQ-SONNY-2653-PLANNED-READ-EXT-LEAK; FEATURE="PlannedReadStorageReads"; ASPECT=FreeExtendedReadCopy; STATUS=TESTED; TEST=tests/test_sonny2653_planned_read_ext_read_leak.zig; OWNER=engine; UPDATED=2026-09-25
/// Free a value the storage adapter read for this file (`getNodeProperty`,
/// `getAllNodeProperties`, `getAllEdgeProperties`). The engine's decode copies
/// both a string and an extended value's bytes onto the caller's allocator
/// (SONNY-2653: the extended value's bytes used to leak on every read, the
/// planned-read twin of SONNY-2464).
fn freeStoragePropertyValue(allocator: std.mem.Allocator, value: gs.PropertyValue) void {
    switch (value) {
        .string => |text| allocator.free(text),
        .ext => |ext| allocator.free(ext.data),
        else => {},
    }
}

fn freeStoragePropertyMap(allocator: std.mem.Allocator, map: *std.StringHashMap(gs.PropertyValue)) void {
    var iter = map.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        freeStoragePropertyValue(allocator, entry.value_ptr.*);
    }
    map.deinit();
}

/// SONNY-3122: a read resolves an edge type's name from the graph it read,
/// looked up only and pinned while its dictionary is read. It called
/// `getOrCreateGraph`: on the read path, with no lock of the adapter's, it
/// could create a graph dropped meanwhile again, and read one that a DROP
/// was freeing (review of round 13).
fn edgeTypeName(allocator: std.mem.Allocator, graph_name: []const u8, rel_type: gs.LabelId) ![]const u8 {
    const adapter = graph_store.getGlobalAdapter() orelse return error.Unsupported;
    const managed_graph = adapter.pinGraph(graph_name) orelse return error.GraphNotFound;
    defer adapter.unpinGraph(managed_graph);
    return try allocator.dupe(u8, managed_graph.label_dict.getString(rel_type) orelse "UNKNOWN");
}

fn ensureBinding(
    allocator: std.mem.Allocator,
    names: *std.ArrayList([]const u8),
    kinds: *std.ArrayList(BindingKind),
    kind: BindingKind,
    preferred_name: ?[]const u8,
    prefix: []const u8,
    ordinal: usize,
) !usize {
    if (preferred_name) |name| {
        for (names.items, 0..) |existing, idx| {
            if (std.mem.eql(u8, existing, name)) {
                if (kinds.items[idx] != kind) return error.Unsupported;
                return idx;
            }
        }
        try names.append(allocator, try allocator.dupe(u8, name));
        try kinds.append(allocator, kind);
        return names.items.len - 1;
    }

    const generated = try std.fmt.allocPrint(allocator, "__planned_{s}_{d}", .{ prefix, ordinal });
    try names.append(allocator, generated);
    try kinds.append(allocator, kind);
    return names.items.len - 1;
}

fn estimateScanRows(allocator: std.mem.Allocator, graph_name: []const u8, pattern: ast.NodePattern) !u64 {
    const adapter = graph_store.getGlobalAdapter() orelse return 0;
    if (!adapter.graphExists(graph_name)) return 0;

    if (pattern.labels.len > 0) {
        // 2026-07-05 (read-path source split): source the label cardinality
        // from the AUTHORITATIVE in-memory maintained refcount
        // (`GraphStore.countNodesByLabel`, hydration-guarded via
        // `ensureGraphHydrated`), NOT `adapter.countNodesByLabel` — the
        // engine's per-shard `label_index` is a DEFERRED derived structure
        // that reads empty/partial after a catalog-mediated reopen and
        // retains deleted slots. These estimates are user-visible (EXPLAIN
        // `est_rows`) and steer plan selection, so they get the same
        // hydration-guaranteed source as user counts. Tenantless refcount
        // read: O(1), matches this function's historical (tenant-unaware)
        // semantics.
        return @intCast(graph_store.getGlobalStore(allocator).countNodesByLabel(graph_name, pattern.labels[0], null));
    }

    return adapter.nodeCount(graph_name) catch 0;
}

// CANARY: REQ=REQ-AUTO-INDEX-EXPLAIN-004; FEATURE="AutoIdIndex"; ASPECT=PlanIndexSeek; STATUS=IMPL; OWNER=planner; UPDATED=2026-04-02
/// Returns true if the catalog has an index on the given label+property pair,
/// enabling the planner to choose IndexSeek over LabelScan.
fn labelHasIndexForProp(context: ExecutionContext, label: []const u8, prop: []const u8) bool {
    const cat = context.catalog;
    cat.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer cat.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());
    var iter = cat.indexes.valueIterator();
    while (iter.next()) |info| {
        if (std.mem.eql(u8, info.table_name, label) and
            info.columns.len > 0 and
            std.mem.eql(u8, info.columns[0], prop))
        {
            return true;
        }
    }
    return false;
}

// CANARY: REQ=REQ-SONNY-1335-PROFILE-ACCESS-PATH; FEATURE="PROFILE"; ASPECT=CatalogIndexForSeek; STATUS=TESTED; TEST=tests/test_sonny1335_profile_access_path.zig; OWNER=engine; UPDATED=2026-11-11
/// SONNY-1335: the name of the catalog index that serves an equality seek on
/// `label`.`prop`, duplicated into `allocator`, or null when there is none.
/// Only a btree or hash index serves an equality (a fulltext, vector or
/// spatial index on the same property does not). When several do, the
/// smallest name, so the answer does not depend on hash map order. The
/// catalog is process-wide (its rows carry no graph), so this is the index
/// SHOW INDEXES lists for the label and property in every graph.
fn equalityIndexName(allocator: std.mem.Allocator, context: ExecutionContext, label: []const u8, prop: []const u8) !?[]u8 {
    const cat = context.catalog;
    cat.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer cat.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());
    var best: ?[]const u8 = null;
    var iter = cat.indexes.valueIterator();
    while (iter.next()) |info| {
        if (!std.mem.eql(u8, info.table_name, label)) continue;
        if (info.columns.len == 0 or !std.mem.eql(u8, info.columns[0], prop)) continue;
        if (!std.mem.eql(u8, info.index_type, "btree") and !std.mem.eql(u8, info.index_type, "hash")) continue;
        if (best == null or std.mem.lessThan(u8, info.name, best.?)) best = info.name;
    }
    const name = best orelse return null;
    return try allocator.dupe(u8, name);
}

/// SONNY-1335: the exact-index seek `collectStartSlots` collected its start
/// slots with. Borrowed from the pattern (or the WHERE clause) it was given.
const StartSeek = struct {
    label: []const u8,
    key: []const u8,
};

/// SONNY-1335: record on a scan operator the access path its start slots were
/// collected with. A seek is reported as `IndexSeek`, named after the catalog
/// index that serves it, only when `collectStartSlots` seeked AND a catalog
/// index covers the label and key; anything else is the scan it was (an
/// equality the internal exact-property lookup answered without a declared
/// index reports a scan, as EXPLAIN does).
fn recordStartAccess(
    allocator: std.mem.Allocator,
    context: ExecutionContext,
    op: *RuntimeOp,
    pattern: ast.NodePattern,
    seek: ?StartSeek,
) !void {
    op.kind = if (pattern.labels.len > 0) .LabelScan else .AllNodesScan;
    const s = seek orelse return;
    const name = (try equalityIndexName(allocator, context, s.label, s.key)) orelse return;
    if (op.index_name) |old| allocator.free(old);
    op.index_name = name;
    op.kind = .IndexSeek;
}

/// Returns true if the node has an inline property that matches a catalog index,
/// or if the WHERE clause contains an equality on an indexed property.
fn nodeCanUseIndex(context: ExecutionContext, node: ast.NodePattern, where_clause: ?ast.Expr) bool {
    if (node.labels.len == 0) return false;
    const label = node.labels[0];

    // Check inline properties (MATCH (n:Label {prop: value}))
    if (node.props) |props| {
        for (props) |prop| {
            if (labelHasIndexForProp(context, label, prop.key)) return true;
        }
    }

    // Check WHERE clause equality (MATCH (n:Label) WHERE n.prop = value)
    if (where_clause) |where| {
        if (node.name) |var_name| {
            return whereClauseHasIndexedEquality(where, var_name, label, context);
        }
    }
    return false;
}

fn whereClauseHasIndexedEquality(root: ast.Expr, var_name: []const u8, label: []const u8, context: ExecutionContext) bool {
    // SONNY-3189: down an AND chain with a loop, not one recursion per AND.
    var at: *const ast.Expr = &root;
    while (at.* == .Binary and at.Binary.op == .And) {
        if (whereClauseHasIndexedEquality(at.Binary.right.*, var_name, label, context)) return true;
        at = at.Binary.left;
    }
    const expr = at.*;
    switch (expr) {
        .Binary => |bin| {
            if (bin.op == .And) {
                if (whereClauseHasIndexedEquality(bin.left.*, var_name, label, context)) return true;
                return whereClauseHasIndexedEquality(bin.right.*, var_name, label, context);
            }
            if (bin.op == .Eq) {
                const prop = extractVarPropName(bin.left.*, var_name) orelse
                    extractVarPropName(bin.right.*, var_name) orelse return false;
                return labelHasIndexForProp(context, label, prop);
            }
            return false;
        },
        else => return false,
    }
}

fn extractVarPropName(expr: ast.Expr, var_name: []const u8) ?[]const u8 {
    switch (expr) {
        .PropertyAccess => |pa| {
            if (std.mem.eql(u8, pa.object, var_name)) return pa.property;
        },
        .Member => |m| {
            if (m.target.* == .Ident and std.mem.eql(u8, m.target.Ident.orig, var_name)) return m.field;
        },
        else => {},
    }
    return null;
}

fn resolveGraphName(context: ExecutionContext) []const u8 {
    return if (context.session_state) |session|
        session.graph orelse graph_store.DEFAULT_GRAPH_NAME
    else
        graph_store.DEFAULT_GRAPH_NAME;
}

fn nextOpIndex(ops: []const RuntimeOp, kind: OpKind, occurrence: *usize) ?usize {
    var seen: usize = 0;
    for (ops, 0..) |op, idx| {
        if (op.kind != kind) continue;
        if (seen == occurrence.*) {
            occurrence.* += 1;
            return idx;
        }
        seen += 1;
    }
    return null;
}

fn nowNs() i128 {
    var ts_tmp: std.posix.timespec = undefined;
    const rc = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.REALTIME, &ts_tmp)
    else
        std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts_tmp);
    if (rc != 0) return 0;
    return @as(i128, ts_tmp.sec) * std.time.ns_per_s + @as(i128, ts_tmp.nsec);
}

fn elapsedSince(start_ns: i128) u64 {
    const now = nowNs();
    return if (now > start_ns) @intCast(now - start_ns) else 0;
}

// CANARY: REQ=REQ-SONNY-2652-PLANNED-READ-SKIP; FEATURE="PlannedReadRowWindow"; ASPECT=MaterializeCapNeedsLimit; STATUS=TESTED; TEST=tests/test_sonny2652_planned_read_skip_without_limit.zig; OWNER=engine; UPDATED=2026-09-25
/// The most rows a planned read needs to materialize when its first rows are
/// the answer's first rows (the caller decides that): OFFSET + LIMIT, or null
/// (every row) when there is no LIMIT. It feeds `materialize_cap`, which stops
/// the materialization loops. An OFFSET alone bounds nothing: `SKIP k` returns
/// every row after the first k (SONNY-2652: the cap used to be
/// `staleLabelIndexThreshold`, which answers k+1 for it, so `SKIP k` returned
/// one row).
fn materializeWindowEnd(
    q: *const ast.Query,
    param_names: []const []const u8,
    param_values: []const Value,
) ?usize {
    const limit = resolveWindowValue(q.limit, q.limit_param, param_names, param_values) orelse return null;
    const offset = resolveWindowValue(q.offset, q.offset_param, param_names, param_values) orelse 0;
    return std.math.add(usize, offset, limit) catch std.math.maxInt(usize);
}

/// The fewest start slots `collectStartSlots` expects from a label index
/// before it trusts it: OFFSET + LIMIT with a LIMIT, OFFSET + 1 with an OFFSET
/// alone (the window needs at least one row after the offset), and null (no
/// expectation) with neither. A label index that returns fewer is treated as
/// possibly stale, and the start slots come from a full scan instead. This is
/// a threshold, not a cap: it never bounds how many rows are materialized
/// (that is `materializeWindowEnd`).
fn staleLabelIndexThreshold(
    q: *const ast.Query,
    param_names: []const []const u8,
    param_values: []const Value,
) ?usize {
    if (materializeWindowEnd(q, param_names, param_values)) |end| return end;
    const offset = resolveWindowValue(q.offset, q.offset_param, param_names, param_values) orelse 0;
    if (offset == 0) return null;
    return std.math.add(usize, offset, 1) catch std.math.maxInt(usize);
}

fn hasPreProjectionFilter(q: *const ast.Query) bool {
    return q.filter_clause != null or (q.with_clause == null and q.where_clause != null) or preWithWhere(q) != null;
}

/// SONNY-3140: with a WITH after the MATCH, the WHERE before it filters the
/// pattern's rows. The parser joins it to the WHERE after the WITH in
/// `where_clause`, which was evaluated over the WITH's rows, where a variable
/// the WITH renamed or dropped no longer exists.
fn preWithWhere(q: *const ast.Query) ?ast.Expr {
    if (q.with_clause == null or q.is_initial_with) return null;
    return q.pre_with_where;
}

/// The WHERE over a WITH's rows: the one after it (or, for a query the
/// parser did not split, the joined one, as before).
fn withStageWhere(q: *const ast.Query) ?ast.Expr {
    if (q.with_clause != null and !q.is_initial_with and (q.pre_with_where != null or q.with_where != null)) return q.with_where;
    return q.where_clause;
}

fn hasAggregationItems(items: []const ast.ReturnItem) bool {
    for (items) |item| {
        if (execution.isAggregationExpr(item.expr)) return true;
    }
    return false;
}

fn needsFinalProjection(q: *const ast.Query) bool {
    if (q.ret.items.len == 0) return false;
    if (q.with_clause) |with_clause| {
        const same_items = q.ret.items.ptr == with_clause.items.ptr and q.ret.items.len == with_clause.items.len;
        if (same_items) return false;
    }
    return true;
}

fn appendLegacyPlanOps(
    allocator: std.mem.Allocator,
    ops: *std.ArrayList(PlanOp),
    q: *const ast.Query,
) !void {
    if (q.cte_list) |cte_list| {
        for (cte_list.ctes) |cte| {
            try ops.append(allocator, .{ .kind = .RecursiveCTE });
            switch (cte.body) {
                .simple => |subquery| try appendLegacyPlanOps(allocator, ops, subquery),
                .recursive => |recursive| {
                    try appendLegacyPlanOps(allocator, ops, recursive.anchor);
                    try appendLegacyPlanOps(allocator, ops, recursive.recursive_term);
                },
            }
        }
    }

    if (q.initial_call_subquery) |call_subquery| {
        try ops.append(allocator, .{ .kind = .CallSubquery });
        try appendLegacyPlanOps(allocator, ops, call_subquery);
    }

    if (q.unwind_clause != null) {
        try ops.append(allocator, .{ .kind = .Unwind });
    }

    if (q.path_variable != null) {
        try ops.append(allocator, .{ .kind = .PathCapture });
    }

    if (q.match.chains.len == 0 and q.unwind_clause == null and q.initial_call_subquery == null) {
        try ops.append(allocator, .{ .kind = .ConstProjection, .est_rows = 1 });
    }

    const saw_optional = q.optional_match;
    for (q.match.chains) |chain| {
        if (saw_optional or chain.is_optional) {
            try ops.append(allocator, .{ .kind = .OptionalMatch });
        }
        if (chain.head) |head| {
            try ops.append(allocator, .{
                .kind = if (head.labels.len > 0) .LabelScan else .AllNodesScan,
            });
        } else if (chain.hops.len > 0) {
            const root = chain.hops[0].left;
            try ops.append(allocator, .{
                .kind = if (root.labels.len > 0) .LabelScan else .AllNodesScan,
            });
        }

        if (chain.name != null) {
            try ops.append(allocator, .{ .kind = .PathCapture });
        }

        for (chain.hops) |hop| {
            if (chain.is_shortest) {
                try ops.append(allocator, .{ .kind = .ShortestPath });
                continue;
            }
            if (hop.rel.min_len != null or hop.rel.max_len != null) {
                try ops.append(allocator, .{ .kind = .VarLengthExpand });
                continue;
            }
            if (chain.path_mode != .walk) {
                try ops.append(allocator, .{ .kind = .PathModeExpand });
                continue;
            }
            try ops.append(allocator, .{
                .kind = switch (hop.rel.dir) {
                    .right => .ExpandOut,
                    .left => .ExpandIn,
                    .undirected => .ExpandEither,
                },
            });
        }
    }

    if (hasPreProjectionFilter(q)) {
        try ops.append(allocator, .{ .kind = .Filter });
    }

    if (q.call_clause != null) {
        try ops.append(allocator, .{ .kind = .CallProcedure });
    }

    if (q.create_pattern != null) {
        try ops.append(allocator, .{ .kind = .Create });
    }
    if (q.merge_statement != null) {
        try ops.append(allocator, .{ .kind = .Merge });
    }
    if (q.set_clauses.len != 0) {
        try ops.append(allocator, .{ .kind = .Set });
    }
    if (q.remove_clauses.len != 0) {
        try ops.append(allocator, .{ .kind = .Remove });
    }
    if (q.delete_items.len != 0) {
        try ops.append(allocator, .{ .kind = .Delete });
    }

    if (q.with_clause) |with_clause| {
        try ops.append(allocator, .{
            .kind = if (q.withStageGroupBy() != null or hasAggregationItems(with_clause.items)) .Aggregate else .Project,
        });
        if (with_clause.distinct) {
            try ops.append(allocator, .{ .kind = .Distinct });
        }
        if (with_clause.order_by != null) {
            try ops.append(allocator, .{ .kind = .Sort });
        }
        if (with_clause.limit != null or with_clause.offset != null or with_clause.limit_param != null or with_clause.offset_param != null) {
            try ops.append(allocator, .{ .kind = .Limit });
        }
        if (withStageWhere(q) != null) {
            try ops.append(allocator, .{ .kind = .Filter });
        }
    }

    if (needsFinalProjection(q)) {
        try ops.append(allocator, .{
            .kind = if (q.returnStageGroupBy() != null or hasAggregationItems(q.ret.items)) .Aggregate else .Project,
        });
        if (q.ret.distinct) {
            try ops.append(allocator, .{ .kind = .Distinct });
        }
        if (q.order_by != null) {
            try ops.append(allocator, .{ .kind = .Sort });
        }
        if (q.limit != null or q.offset != null or q.limit_param != null or q.offset_param != null) {
            try ops.append(allocator, .{ .kind = .Limit });
        }
    }

    if (q.next_query != null or q.for_statement != null) {
        try ops.append(allocator, .{ .kind = .QueryChain });
    }
    if (q.next_query) |next_query| {
        try appendLegacyPlanOps(allocator, ops, next_query);
    }

    try ops.append(allocator, .{ .kind = .LegacyExecute });
}

fn isAllSimpleNodeMultiChain(q: *const ast.Query) bool {
    if (q.match.chains.len < 2) return false;
    for (q.match.chains) |chain| {
        if (chain.is_optional or chain.is_shortest or chain.path_mode != .walk) return false;
        if (chain.hops.len > 0) return false;
    }
    return true;
}

/// GAP-0902: pure-AST predicate — true iff this read is served ENGINE-DIRECT by
/// the storage-native planned-read path (single-chain MATCH reads incl. ORDER
/// BY / DISTINCT / aggregates, no mutations / RLS-needing shapes / multi-chain
/// traversal). When true, `executeIfSupported` builds the plan in storage_native
/// mode and NEVER falls back to the legacy resident-only executor (see
/// buildPlanIfSupported: execution_mode = storage_native ⇔ this predicate), so
/// the read reads every live node straight from the engine with NO whole-graph
/// snapshot clone. The transport handler uses this (with its own RLS / preamble
/// gates) to skip the O(all-nodes) `snapshotUnderReadLock` deep-clone for these
/// analytical shapes under the bounded node cache — the RAM-balloon source.
/// Does no I/O; safe to call before acquiring any lock.
pub fn isStorageNativeReadShape(q: *const ast.Query) bool {
    return isStorageNativeQuery(q);
}

fn isStorageNativeQuery(q: *const ast.Query) bool {
    if (q.next_query != null) return false;
    // A `WITH … FOR …` shape must NOT be served as a plain WITH projection —
    // the storage-native path would drop the FOR body entirely (write loss for
    // `WITH … FOR … CREATE`, and a collapsed one-row result for a read-bodied
    // FOR). Route it to the executeForWithBindings path instead. Mirrors the 4
    // sibling gates (:2157/:3680/:3848/:3932).
    if (q.for_statement != null) return false;
    if (q.unwind_clause != null or q.create_pattern != null) return false;
    if (q.call_clause != null or q.initial_call_subquery != null or q.merge_statement != null) return false;
    if (q.path_variable != null or q.has_recursive_cte) return false;
    if (q.set_clauses.len != 0 or q.remove_clauses.len != 0 or q.delete_items.len != 0) return false;

    // Covered OPTIONAL MATCH left-outer shape: admitted BEFORE the optional
    // rejects below, served engine-direct by executeOptionalLeftOuter with no
    // whole-graph clone. The gate is strict (see coveredOptionalLeftOuter);
    // every uncovered optional shape falls through to the rejects.
    if (coveredOptionalLeftOuter(q)) return true;

    // Covered bounded var-length endpoint shape: admitted BEFORE the
    // single-chain var-length reject (isStorageNativeSingleChain rejects any
    // hop with min_len/max_len). Served engine-direct by
    // executeVarLengthEndpoint with no whole-graph clone; the gate is strict
    // (see coveredVarLengthEndpoint), every uncovered var-length shape falls
    // through to the rejects.
    if (coveredVarLengthEndpoint(q)) return true;

    if (q.optional_match) return false;
    if (q.match.chains.len > 1) return isAllSimpleNodeMultiChain(q);
    if (q.match.chains.len == 0) return true;

    const chain = q.match.chains[0];
    if (chain.is_optional) return false;
    return isStorageNativeSingleChain(chain);
}

/// True iff `chain` is a single non-optional storage-native walk chain (head
/// node or directed/undirected hops, no var-length, no shortest, no non-walk
/// path mode, and uniquely-nameable bindings). Extracted from
/// isStorageNativeQuery so coveredOptionalLeftOuter can reuse it for the main
/// chain. Does NOT check `chain.is_optional` — callers decide that.
fn isStorageNativeSingleChain(chain: ast.Chain) bool {
    if (chain.is_shortest or chain.path_mode != .walk) return false;
    if (chain.head != null and chain.hops.len > 0) return false;
    if (chain.head == null and chain.hops.len == 0) return false;

    var names: [32][]const u8 = undefined;
    var name_count: usize = 0;
    const root = if (chain.head) |head| head else chain.hops[0].left;
    if (root.name) |name| {
        if (name_count >= names.len) return false;
        names[name_count] = name;
        name_count += 1;
    }

    for (chain.hops, 0..) |hop, hop_idx| {
        if (hop.rel.min_len != null or hop.rel.max_len != null) return false;
        if (hop_idx != 0) {
            // GAP-0813: the left node of any non-first hop is the same
            // entity as the right node of the previous hop. If a name is
            // given, it MUST match the previous hop's right.name (or the
            // anonymous chain continuation). It is NOT a duplicate — it
            // is a reference to the node we already know about. We
            // simply skip re-registration. If the previous hop's right
            // was anonymous but this left is named, add it; if both
            // named and they disagree, reject (the planner can't resolve
            // that without extra work).
            if (hop.left.name) |left_name| {
                const prev_right_name = chain.hops[hop_idx - 1].right.name;
                if (prev_right_name) |prn| {
                    if (!std.mem.eql(u8, prn, left_name)) return false;
                    // Same name — already registered. Skip.
                } else {
                    // Previous hop's right was anonymous. Register this name now.
                    if (containsName(names[0..name_count], left_name)) return false;
                    if (name_count >= names.len) return false;
                    names[name_count] = left_name;
                    name_count += 1;
                }
            }
        }
        if (hop.rel.name) |name| {
            if (containsName(names[0..name_count], name)) return false;
            if (name_count >= names.len) return false;
            names[name_count] = name;
            name_count += 1;
        }
        if (hop.right.name) |name| {
            if (containsName(names[0..name_count], name)) return false;
            if (name_count >= names.len) return false;
            names[name_count] = name;
            name_count += 1;
        }
    }

    return true;
}

/// Does the main (non-optional) chain bind a NODE variable named `name`?
/// Node vars are: the root, and each hop's right endpoint. (A non-first
/// hop's left endpoint is the previous hop's right — already covered.)
fn mainChainBindsNodeVar(chain: ast.Chain, name: []const u8) bool {
    const root = if (chain.head) |head| head else chain.hops[0].left;
    if (root.name) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    for (chain.hops) |hop| {
        if (hop.right.name) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
    }
    return false;
}

/// Does the main chain bind ANY variable (node OR relationship) named `name`?
fn mainChainBindsAnyVar(chain: ast.Chain, name: []const u8) bool {
    if (mainChainBindsNodeVar(chain, name)) return true;
    for (chain.hops) |hop| {
        if (hop.rel.name) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
    }
    return false;
}

/// STRICT gate for the single covered OPTIONAL MATCH left-outer shape:
///   MATCH (<main storage-native single chain>)
///   OPTIONAL MATCH (<main-bound var>)-[r?:R?]->(c?)   // exactly one walk hop
///   RETURN ...                                         // no WHERE / WITH
///
/// ALL conditions must hold, else return false (the caller falls back to the
/// clone path, which is correct for every shape). When in doubt: false.
fn coveredOptionalLeftOuter(q: *const ast.Query) bool {
    // Structural rejects (mirror isStorageNativeQuery's early guards so this
    // predicate is self-contained and safe to call standalone).
    if (q.next_query != null) return false;
    if (q.unwind_clause != null or q.create_pattern != null) return false;
    if (q.call_clause != null or q.initial_call_subquery != null or q.merge_statement != null) return false;
    if (q.path_variable != null or q.has_recursive_cte) return false;
    if (q.set_clauses.len != 0 or q.remove_clauses.len != 0 or q.delete_items.len != 0) return false;
    if (q.cte_list != null or q.for_statement != null) return false;
    if (q.let_bindings.len != 0) return false;

    // v1 scope: no WHERE / FILTER / WITH (avoid optional-var correctness risk).
    if (q.where_clause != null or q.filter_clause != null) return false;
    if (q.with_clause != null) return false;

    // Exactly two chains: a non-optional main, then one optional.
    if (q.match.chains.len != 2) return false;
    const main_chain = q.match.chains[0];
    const opt_chain = q.match.chains[1];
    if (main_chain.is_optional) return false;
    if (!opt_chain.is_optional) return false;
    if (!isStorageNativeSingleChain(main_chain)) return false;

    // GAP fix: multi-hop main chains ARE served engine-direct. The legacy
    // clone-path oracle (executeMatchWithOptionalPatterns) only bound hops[0]
    // of the main chain (NULLs for hops[1+] = a real bug); the engine-direct
    // exploreMainHopsForOptional traverses ALL main hops with correct
    // left-outer semantics. isStorageNativeSingleChain already validates the
    // full multi-hop main (distinct vars, no var-length), so no hop cap here.

    // Optional chain: exactly one walk hop, no var-length, no shortest, a hop
    // chain (not a bare node).
    if (opt_chain.is_shortest) return false;
    if (opt_chain.path_mode != .walk) return false;
    if (opt_chain.head != null) return false;
    if (opt_chain.hops.len != 1) return false;
    const hop = opt_chain.hops[0];
    if (hop.rel.min_len != null or hop.rel.max_len != null) return false;

    // FIX 1 (review): `propsMatch` evaluates inline prop VALUES with an EMPTY
    // binding Env, so a correlated value (e.g. `(c {k: p.k})`) or any value
    // referencing a variable silently drops the candidate -> engine-direct
    // emits the NULL row regardless of data, while the clone oracle matches
    // correctly. Only literal/param-constant inline props are safe; otherwise
    // fall back to the (correct) clone path. Cover the optional endpoint node,
    // the re-stated seed node, and the optional relationship.
    if (!allPropsLiteralOrParam(hop.left.props)) return false;
    if (!allPropsLiteralOrParam(hop.rel.props)) return false;
    if (!allPropsLiteralOrParam(hop.right.props)) return false;

    // The optional hop's seed (left) must be a variable already bound as a
    // NODE by the main chain (the shared join var). Anonymous seed → fall back.
    const seed_name = hop.left.name orelse return false;
    if (!mainChainBindsNodeVar(main_chain, seed_name)) return false;

    // The optional rel / endpoint vars must be fresh — they must not collide
    // with any main-chain var (nor with the seed or each other). A collision
    // would re-bind an already-bound slot; reject conservatively.
    if (hop.rel.name) |rn| {
        if (std.mem.eql(u8, rn, seed_name)) return false;
        if (mainChainBindsAnyVar(main_chain, rn)) return false;
    }
    if (hop.right.name) |wn| {
        if (std.mem.eql(u8, wn, seed_name)) return false;
        if (mainChainBindsAnyVar(main_chain, wn)) return false;
        if (hop.rel.name) |rn| {
            if (std.mem.eql(u8, wn, rn)) return false;
        }
    }

    return true;
}

/// STRICT gate for the single covered bounded var-length endpoint shape:
///   MATCH (p {bound})-[:R*a..b]->(c) RETURN c   // finite b, directed, bare,
///                                                // no edge/path binding, no
///                                                // WHERE/WITH
///
/// Served engine-direct by `executeVarLengthEndpoint` via a depth-bounded
/// acyclic per-path expand whose emission is byte-identical to the clone-path
/// oracle (`match_operations.executeVariableLengthPathTraversal`, which drives
/// the same `PathIterator` BFS with the effective ACYCLIC mode of a bare
/// pattern). ALL conditions must hold, else fall back to the (correct) clone
/// path. When in doubt: false.
fn coveredVarLengthEndpoint(q: *const ast.Query) bool {
    // Structural rejects (mirror coveredOptionalLeftOuter so this predicate is
    // self-contained and safe to call standalone).
    if (q.next_query != null) return false;
    if (q.unwind_clause != null or q.create_pattern != null) return false;
    if (q.call_clause != null or q.initial_call_subquery != null or q.merge_statement != null) return false;
    if (q.path_variable != null or q.has_recursive_cte) return false;
    if (q.set_clauses.len != 0 or q.remove_clauses.len != 0 or q.delete_items.len != 0) return false;
    if (q.cte_list != null or q.for_statement != null) return false;
    if (q.let_bindings.len != 0) return false;

    // v1 scope: no WHERE / FILTER / WITH / OPTIONAL.
    if (q.where_clause != null or q.filter_clause != null) return false;
    if (q.with_clause != null) return false;
    if (q.optional_match) return false;

    // Exactly one non-optional chain.
    if (q.match.chains.len != 1) return false;
    const chain = q.match.chains[0];
    if (chain.is_optional) return false;
    if (chain.is_shortest) return false;

    // Bare pattern only: `path_mode == .walk` AND not explicitly spelled. A bare
    // pattern's EFFECTIVE traversal mode is ACYCLIC (effectivePathMode), which
    // `executeVarLengthEndpoint` implements; any explicit mode keyword falls
    // back to the clone path.
    if (chain.path_mode != .walk) return false;
    if (chain.path_mode_explicit) return false;

    // Endpoint shape, not a path variable; a hop chain (not a bare node).
    if (chain.name != null) return false;
    if (chain.head != null) return false;
    if (chain.hops.len != 1) return false;

    const hop = chain.hops[0];
    const rel = hop.rel;

    // Variable-length present AND a FINITE upper bound (reject unbounded).
    if (rel.min_len == null and rel.max_len == null) return false;
    if (rel.max_len == null) return false;

    // Directed only (v1); no edge-list binding; single rel type (the oracle's
    // PathIterator filters by types[0] only); no rel props (the oracle ignores
    // them for var-length — gating them out avoids any divergence).
    if (rel.dir == .undirected) return false;
    if (rel.name != null) return false;
    if (rel.types.len > 1) return false;
    if (rel.props != null) return false;

    // Seed and endpoint vars (if both named) must be distinct.
    if (hop.left.name) |ln| {
        if (hop.right.name) |rn| {
            if (std.mem.eql(u8, ln, rn)) return false;
        }
    }

    // Inline seed/endpoint props must be literal/param constants (empty-Env
    // safe for propsMatch / nodeMatchesPatternBySlot).
    if (!allPropsLiteralOrParam(hop.left.props)) return false;
    if (!allPropsLiteralOrParam(hop.right.props)) return false;

    return true;
}

/// True only when `expr` is a constant literal or a query parameter — i.e. a
/// value `propsMatch` can evaluate correctly against an EMPTY binding Env.
/// Anything that references a variable (Ident / Member / PropertyAccess), a
/// function call, an arithmetic/logical expression, or a composite (List /
/// ArrayLit) is NOT safe and returns false (conservative).
fn exprIsLiteralOrParam(expr: ast.Expr) bool {
    return switch (expr) {
        .String,
        .Int,
        .Decimal,
        .Bool,
        .Null,
        .Date,
        .DateTime,
        .Time,
        .LocalDateTime,
        .SmallIntLit,
        .BigIntLit,
        .RealLit,
        .DoubleLit,
        .CharLit,
        .VarcharLit,
        .TextLit,
        .ByteaLit,
        .JsonLit,
        .JsonbLit,
        .XmlLit,
        .UrlLit,
        .DomainLit,
        .UuidLit,
        .EnumLit,
        .BitLit,
        .VarBitLit,
        .Param,
        => true,
        else => false,
    };
}

/// Every inline property VALUE in `props` (if any) is a literal/param constant.
fn allPropsLiteralOrParam(props: ?[]ast.Property) bool {
    const list = props orelse return true;
    for (list) |prop| {
        if (!exprIsLiteralOrParam(prop.value.*)) return false;
    }
    return true;
}

fn containsName(names: []const []const u8, candidate: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

/// SONNY-3350 (round 17): a test seam: `resolveExternalNodeId`.
pub fn resolveExternalNodeIdForTest(allocator: std.mem.Allocator, graph_name: []const u8, slot_id: u64) !u64 {
    const adapter = graph_store.getGlobalAdapter() orelse return error.Unsupported;
    return resolveExternalNodeId(allocator, adapter, graph_store.getGlobalStore(allocator), graph_name, slot_id);
}
