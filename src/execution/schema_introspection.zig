// CANARY: REQ=REQ-LSP-SCHEMA-INTROSPECT-001; FEATURE="LspPermissionAwareCompletion"; ASPECT=PermissionFilter; STATUS=TESTED; TEST=tests/test_schema_introspection.zig; OWNER=lsp; UPDATED=2026-05-14
//
// Permission-filtered schema-listing module for the LSP.
//
// This module is the gating layer between the raw `GraphStore` accessors
// (`listNodeLabels`, `listEdgeTypes`, `listPropertiesForLabel`,
// `listGraphNames`) and the LSP's `SchemaProvider`. It enforces the
// "is this graph visible to this user?" check via the
// `AuthGraphManager.canUserAccessGraph` coarse-visibility gate, with an
// admin / no-auth-manager permissive fallback for tests and the
// `--no-auth` developer path.
//
// Imports are NAMED modules (`geode`, `auth_graph_manager`) rather than
// relative file paths so this module can live in its own build module
// without triggering the Zig 0.16 "file exists in modules X and X0"
// diamond. The named-module pattern mirrors `auth_graph_manager.zig`,
// which depends on `geode` (root_mod) the same way.

const std = @import("std");
const geode = @import("geode");
const auth_graph = @import("auth_graph_manager");
// Issue #817: per-label permission gate.  rls_types is a named build module
// (see build.zig:2793) so we can reach the process-global label-deny engine
// without dragging the rest of the security stack into this leaf module.
const rls_types = @import("rls_types");

const graph_store = geode.graph_store;
const user_management = geode.user_management;
// SONNY-1318 (GEO-UP-005): route the session tenant through the SHARED
// strict-tenancy decision instead of passing `ctx.tenant_id` raw, so this LSP
// metadata path and the `db.labels` / `db.relationshipTypes` dispatch path
// (`meta_dispatch.zig:115`) agree about strict mode. Raw pass-through gave an
// unscoped/"default" session the ALL-TENANTS label view from the LSP while
// `db.labels` correctly refused it — the same silent-widening footgun
// GAP-0840 closed for the executor.
const tenancy = geode.tenancy;
// SONNY-6344: the listings see what the session's MATCH sees (a parent tenant
// also its descendants' rows).
const tenant_visibility = geode.execution.tenant_visibility;

/// Per-call introspection context bound to the LSP session.
///
/// `tenant_id == null` is the un-scoped introspection path. SONNY-1318:
/// it is resolved through `tenancy.resolveTenantFilter`, so it means
/// "every label, edge type and property regardless of row-level tenant
/// tag" ONLY in a non-strict deployment; under strict tenancy an
/// unscoped (or empty / "default") scope is REFUSED with
/// `error.TenantScopeRequired`, exactly as `db.labels` refuses it. When
/// `tenant_id` names a concrete tenant, the underlying `GraphStore`
/// accessors filter by it so cross-tenant labels stay invisible.
///
/// `auth_mgr == null` is the permissive default used by unit tests and
/// the `--no-auth` developer flow. With a real auth manager wired in
/// (the LSP server installs the process-global on session start), the
/// per-graph visibility check is enforced.
pub const IntrospectionContext = struct {
    user: []const u8,
    tenant_id: ?[]const u8,
    role: user_management.Role,
    graph_name: []const u8,
    /// Optional injection point for the auth manager; null skips per-graph
    /// gating (permissive default for tests; the LSP wires in the global).
    auth_mgr: ?*auth_graph.AuthGraphManager = null,
};

/// Free a slice of allocator-owned strings produced by one of the
/// `list*ForUser` accessors. Frees each inner string, then the outer
/// slice. Safe to pass a zero-length slice.
pub fn freeStringList(allocator: std.mem.Allocator, list: [][]const u8) void {
    for (list) |s| allocator.free(s);
    allocator.free(list);
}

/// Returns `true` when the caller can see the active graph.
///
/// - `Role.Admin` short-circuits to `true` (admin sees every graph).
/// - `auth_mgr == null` is the permissive fallback for tests / no-auth.
/// - Otherwise the per-graph grant check decides.
fn graphVisible(ctx: IntrospectionContext) !bool {
    if (ctx.role == .Admin) return true;
    const mgr = ctx.auth_mgr orelse return true;
    return mgr.canUserAccessGraph(ctx.user, ctx.graph_name);
}

/// Issue #817: per-label permission gate.  Returns `true` when the caller
/// is allowed to see `label` in `ctx.graph_name`.
///
/// - `Role.Admin` always sees every label (admin debugging UX).
/// - When the process-global label-deny RLS engine is not configured (the
///   common case in unit tests and `--no-auth` developer flows), every
///   label is visible (no false positives).
/// - Otherwise we consult `RLSFilterEngine.isLabelDenied(graph, label, user)`,
///   the same primitive the match loop uses to filter rows
///   (`src/execution/match_operations.zig::passesRLSFilter`).  This keeps
///   schema introspection consistent with query execution: an LSP user
///   cannot see a label in completion that they would also be denied from
///   reading at query time.
///
/// Acceptance closure for #817: this is the LABEL-LEVEL gate the gap asks
/// for, layered on top of the existing graph-level `graphVisible` check.
/// Expression-policy-based row filtering still applies at query time but
/// is intentionally not consulted here -- evaluating arbitrary RLS row
/// predicates against the schema is both expensive and meaningless
/// (there's no real row to evaluate against).
fn labelVisible(ctx: IntrospectionContext, label: []const u8) bool {
    if (ctx.role == .Admin) return true;
    const engine = rls_types.getGlobalRLSFilterEngine() orelse return true;
    return !engine.isLabelDenied(ctx.graph_name, label, ctx.user);
}

/// Filter an allocator-owned list of labels in place, keeping only those
/// the caller may see.  Frees the inner string for every dropped entry
/// so the returned slice (and its remaining elements) can still be
/// released with `freeStringList`.
fn filterLabelsByPermission(
    allocator: std.mem.Allocator,
    ctx: IntrospectionContext,
    list: [][]const u8,
) ![][]const u8 {
    // Admins / no-engine short-circuit to avoid an O(n) walk per call.
    if (ctx.role == .Admin) return list;
    if (rls_types.getGlobalRLSFilterEngine() == null) return list;

    var keep = try std.ArrayList([]const u8).initCapacity(allocator, list.len);
    errdefer {
        // On error, free anything we already moved into `keep` and the
        // tail of the input that we have not yet inspected.
        for (keep.items) |s| allocator.free(s);
        keep.deinit(allocator);
    }
    for (list) |name| {
        if (labelVisible(ctx, name)) {
            try keep.append(allocator, name);
        } else {
            allocator.free(name);
        }
    }
    allocator.free(list);
    return keep.toOwnedSlice(allocator);
}

/// Returns the de-duplicated node-label set visible to `ctx`.
/// Empty slice if the user cannot see `ctx.graph_name`.
///
/// Caller owns the returned slice and each string inside it; use
/// `freeStringList` to release both.
///
/// Issue #817: labels denied by the process-global label-deny RLS engine
/// are dropped here so LSP completion never leaks names the caller could
/// not also read via MATCH.  Admin and the no-engine fallback short-circuit
/// for zero overhead in the common case.
pub fn listLabelsForUser(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    ctx: IntrospectionContext,
) ![][]const u8 {
    if (!try graphVisible(ctx)) return try allocator.alloc([]const u8, 0);
    const filter_tenant = try tenancy.resolveTenantFilter(ctx.tenant_id);
    const all = try tenant_visibility.listNodeLabelsVisible(allocator, store, filter_tenant);
    return filterLabelsByPermission(allocator, ctx, all);
}

/// Returns the de-duplicated edge-type set visible to `ctx`.
/// Empty slice if the user cannot see `ctx.graph_name`.
///
/// Caller owns the returned slice and each string inside it; use
/// `freeStringList` to release both.
///
/// Issue #817: edge types are filtered against the same per-label RLS deny
/// table as node labels (the engine treats them uniformly via the `table`
/// field of `LabelPolicy`).
pub fn listEdgeTypesForUser(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    ctx: IntrospectionContext,
) ![][]const u8 {
    if (!try graphVisible(ctx)) return try allocator.alloc([]const u8, 0);
    const filter_tenant = try tenancy.resolveTenantFilter(ctx.tenant_id);
    const all = try tenant_visibility.listEdgeTypesVisible(allocator, store, filter_tenant);
    return filterLabelsByPermission(allocator, ctx, all);
}

/// Returns the de-duplicated property-key set observed on every node
/// carrying `label` in the caller's tenant. Empty slice if the user
/// cannot see `ctx.graph_name` or cannot see `label` itself.
///
/// Caller owns the returned slice and each string inside it; use
/// `freeStringList` to release both.
///
/// Issue #817: when the caller is denied access to `label` itself we
/// return an empty list rather than an error -- this matches how the LSP
/// degrades for unknown labels and avoids leaking the existence of a
/// label via the error channel.
pub fn listPropertiesForLabelForUser(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    ctx: IntrospectionContext,
    label: []const u8,
) ![][]const u8 {
    if (!try graphVisible(ctx)) return try allocator.alloc([]const u8, 0);
    if (!labelVisible(ctx, label)) return try allocator.alloc([]const u8, 0);
    const filter_tenant = try tenancy.resolveTenantFilter(ctx.tenant_id);
    return tenant_visibility.listPropertiesForLabelVisible(allocator, store, filter_tenant, label);
}

/// Returns the graph-name list the caller can see.
///
/// - Admin or no-auth-manager: returns every graph (just like
///   `GraphStore.listGraphNames`), repackaged into a mutable outer
///   slice for API consistency with the other `list*ForUser` helpers.
/// - Otherwise: filters out graphs the user has no grant on; frees
///   the inner strings for graphs that are dropped.
///
/// Caller owns the returned slice and each string inside it; use
/// `freeStringList` to release both.
pub fn listGraphsForUser(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    ctx: IntrospectionContext,
) ![][]const u8 {
    // listGraphNames returns ![]const []const u8 — the outer slice is
    // const-typed but heap-owned. Repackage every path into a
    // [][]const u8 so callers can free with freeStringList uniformly.
    const all = try store.listGraphNames(allocator);

    if (ctx.role == .Admin or ctx.auth_mgr == null) {
        const out = try allocator.alloc([]const u8, all.len);
        @memcpy(out, all);
        allocator.free(all);
        return out;
    }

    var keep = try std.ArrayList([]const u8).initCapacity(allocator, all.len);
    errdefer keep.deinit(allocator);
    var i: usize = 0;
    while (i < all.len) : (i += 1) {
        if (try ctx.auth_mgr.?.canUserAccessGraph(ctx.user, all[i])) {
            try keep.append(allocator, all[i]);
        } else {
            allocator.free(all[i]);
        }
    }
    allocator.free(all);
    return keep.toOwnedSlice(allocator);
}
