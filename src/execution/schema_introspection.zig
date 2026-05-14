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

const graph_store = geode.graph_store;
const user_management = geode.user_management;

/// Per-call introspection context bound to the LSP session.
///
/// `tenant_id == null` is the admin / un-scoped introspection path —
/// every label, edge type, and property is visible regardless of the
/// row-level tenant tag. When `tenant_id` is set, the underlying
/// `GraphStore` accessors filter by `tenant_id` so cross-tenant labels
/// stay invisible.
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
fn graphVisible(ctx: IntrospectionContext) bool {
    if (ctx.role == .Admin) return true;
    const mgr = ctx.auth_mgr orelse return true;
    return mgr.canUserAccessGraph(ctx.user, ctx.graph_name);
}

/// Returns the de-duplicated node-label set visible to `ctx`.
/// Empty slice if the user cannot see `ctx.graph_name`.
///
/// Caller owns the returned slice and each string inside it; use
/// `freeStringList` to release both.
pub fn listLabelsForUser(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    ctx: IntrospectionContext,
) ![][]const u8 {
    if (!graphVisible(ctx)) return try allocator.alloc([]const u8, 0);
    return store.listNodeLabels(allocator, ctx.tenant_id);
}

/// Returns the de-duplicated edge-type set visible to `ctx`.
/// Empty slice if the user cannot see `ctx.graph_name`.
///
/// Caller owns the returned slice and each string inside it; use
/// `freeStringList` to release both.
pub fn listEdgeTypesForUser(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    ctx: IntrospectionContext,
) ![][]const u8 {
    if (!graphVisible(ctx)) return try allocator.alloc([]const u8, 0);
    return store.listEdgeTypes(allocator, ctx.tenant_id);
}

/// Returns the de-duplicated property-key set observed on every node
/// carrying `label` in the caller's tenant. Empty slice if the user
/// cannot see `ctx.graph_name`.
///
/// Caller owns the returned slice and each string inside it; use
/// `freeStringList` to release both.
pub fn listPropertiesForLabelForUser(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    ctx: IntrospectionContext,
    label: []const u8,
) ![][]const u8 {
    if (!graphVisible(ctx)) return try allocator.alloc([]const u8, 0);
    return store.listPropertiesForLabel(allocator, ctx.tenant_id, label);
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
        if (ctx.auth_mgr.?.canUserAccessGraph(ctx.user, all[i])) {
            try keep.append(allocator, all[i]);
        } else {
            allocator.free(all[i]);
        }
    }
    allocator.free(all);
    return keep.toOwnedSlice(allocator);
}
