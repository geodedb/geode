//! SONNY-3240 (round-3 review C3), SONNY-3242 (round-3 review I2): the
//! variables a write statement has bound so far, and the one way a list of SET
//! clauses is applied to them.
//!
//! C3. The CREATE, INSERT and MERGE executors evaluated every expression with
//! no variable bound (`envFromContext`: the parameters only). So a MERGE's own
//! ON CREATE / ON MATCH / bare SET read the merged element as null (`MERGE
//! (z:Z {k:1}) ON CREATE SET z.n = 0 ON MATCH SET z.n = z.n + 1` left n null,
//! and go/oidc's JTI replay guard answered "first use" to a replay), and a
//! later chain read an earlier chain's variables as null (`CREATE (a:Z {k:1}),
//! (b:Z {k: a.k+1})` gave b.k null). A `WriteScope` holds each variable the
//! statement has bound (a node as a detached box, `getNodePtrForScan`, read
//! again after it is written; a relationship as the resident edge), and the
//! executors evaluate with `env()`: those variables, then the parameters
//! (which carry a MATCH row's variables for MATCH ... CREATE / MERGE).
//!
//! What is bound where is what the write-shape validator lets an expression
//! name (write_shape.zig `checkScope`): a chain's property map sees the
//! variables of the chains before it; a SET, a MERGE action and the RETURN see
//! every variable of the pattern.
//!
//! I2. `applySetGroups` applies a SET list one clause at a time
//! (`ast.SetClauseGroups`): every value of a clause is evaluated against the
//! bindings as they stood before it, then its assignments apply; the next
//! clause sees them.
//!
//! CANARY: REQ=REQ-SONNY-3240-WRITE-SCOPE; FEATURE="WriteScope"; ASPECT=BoundVariables; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4.zig; OWNER=engine; UPDATED=2026-09-28

const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const value_types = @import("../value_types.zig");
const graph_store = @import("../graph_store.zig");
const property_mutation = @import("property_mutation.zig");
const write_precheck = @import("write_precheck.zig");

const Value = value_types.Value;
const Env = value_types.Env;

pub const WriteScope = struct {
    allocator: std.mem.Allocator,
    names: std.ArrayList([]const u8) = .empty,
    values: std.ArrayList(Value) = .empty,
    param_names: []const []const u8,
    param_values: []const Value,
    /// SONNY-3322: the scope's copies of the relationships it binds, and the
    /// store they are read again from.
    edge_boxes: std.ArrayList(*graph_store.Edge) = .empty,
    edge_store: ?*graph_store.GraphStore = null,

    pub fn init(allocator: std.mem.Allocator, param_names: []const []const u8, param_values: []const Value) WriteScope {
        return .{ .allocator = allocator, .param_names = param_names, .param_values = param_values };
    }

    /// A scope that starts with `base`'s variables (a MATCH row) and
    /// parameters.
    pub fn initFrom(allocator: std.mem.Allocator, base: Env) !WriteScope {
        var scope = WriteScope.init(allocator, base.param_names, base.param_values);
        errdefer scope.deinit();
        try scope.names.appendSlice(allocator, base.names);
        try scope.values.appendSlice(allocator, base.values);
        return scope;
    }

    pub fn deinit(self: *WriteScope) void {
        for (self.edge_boxes.items) |box| self.allocator.destroy(box);
        self.edge_boxes.deinit(self.allocator);
        self.names.deinit(self.allocator);
        self.values.deinit(self.allocator);
    }

    /// The environment to evaluate in: the bound variables, then the
    /// parameters.
    pub fn env(self: *const WriteScope, allocator: std.mem.Allocator) Env {
        // SONNY-3322: each relationship copy as the store holds it now (a
        // copy shares the edge's property storage, which a later edge insert
        // may have moved).
        if (self.edge_store) |store| for (self.edge_boxes.items) |box| {
            if (store.getEdgePtrHydrated(box.id)) |fresh| box.* = fresh.*;
        };
        return .{
            .allocator = allocator,
            .names = self.names.items,
            .values = self.values.items,
            .param_names = self.param_names,
            .param_values = self.param_values,
        };
    }

    pub fn get(self: *const WriteScope, name: []const u8) ?Value {
        for (self.names.items, self.values.items) |n, v| {
            if (std.mem.eql(u8, n, name)) return v;
        }
        return null;
    }

    /// Bind `name` to `value` (a rebinding replaces the old one).
    pub fn bind(self: *WriteScope, name: []const u8, value: Value) !void {
        for (self.names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) {
                self.values.items[i] = value;
                return;
            }
        }
        try self.names.append(self.allocator, name);
        try self.values.append(self.allocator, value);
    }

    /// Bind `name` to node `id` as it is now (a detached box, stable across
    /// later writes; `refresh` reads it again).
    pub fn bindNode(self: *WriteScope, store: *graph_store.GraphStore, name: []const u8, id: u64) !void {
        const box = store.getNodePtrForScan(id) orelse return error.NodeNotFound;
        try self.bind(name, .{ .Node = box });
    }

    // CANARY: REQ=REQ-SONNY-3322-EDGE-BY-ID; FEATURE="WriteScope"; ASPECT=BoxedEdges; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-28
    /// Bind `name` to relationship `id`, as a copy the scope owns.
    ///
    /// SONNY-3322: it bound the resident edge, and a later chain's edge
    /// insert can move the store's edges, so the chain after it (and
    /// `refresh`, which read the id through it) read freed memory. The copy
    /// shares the edge's label and properties, which the edge cache frees at
    /// the graph's grace boundary, not on a move; `refresh` copies the edge
    /// again after a write.
    pub fn bindEdge(self: *WriteScope, store: *graph_store.GraphStore, name: []const u8, id: u64) !void {
        const edge = store.getEdgePtrHydrated(id) orelse return error.EdgeBodyUnresolvable;
        self.edge_store = store;
        try self.bind(name, .{ .Edge = try self.boxEdge(edge) });
    }

    fn boxEdge(self: *WriteScope, edge: *const graph_store.Edge) !*const graph_store.Edge {
        try self.edge_boxes.ensureUnusedCapacity(self.allocator, 1);
        const box = try self.allocator.create(graph_store.Edge);
        box.* = edge.*;
        self.edge_boxes.appendAssumeCapacity(box);
        return box;
    }

    fn ownsBox(self: *const WriteScope, edge: *const graph_store.Edge) ?*graph_store.Edge {
        for (self.edge_boxes.items) |box| {
            if (box == edge) return box;
        }
        return null;
    }

    /// SONNY-3322: `v` with every relationship copy this scope owns replaced
    /// by the store's edge, for a value that outlives the scope (a RETURN).
    pub fn residentEdges(self: *const WriteScope, store: *graph_store.GraphStore, v: *Value) !void {
        switch (v.*) {
            .Edge => |edge| if (self.ownsBox(edge) != null) {
                v.* = .{ .Edge = store.getEdgePtrHydrated(edge.id) orelse return error.EdgeBodyUnresolvable };
            },
            .List => |items| for (items) |*item| try self.residentEdges(store, item),
            else => {},
        }
    }

    /// Read every bound node and relationship again, so what was written
    /// since it was bound is seen. A relationship is read by the id of the
    /// copy the scope holds (SONNY-3322); one the caller bound (a MATCH row's)
    /// is copied too.
    pub fn refresh(self: *WriteScope, store: *graph_store.GraphStore) !void {
        for (self.values.items) |*v| switch (v.*) {
            .Node => |node| v.* = .{ .Node = store.getNodePtrForScan(node.id) orelse return error.NodeNotFound },
            .Edge => |edge| {
                const fresh = store.getEdgePtrHydrated(edge.id) orelse return error.EdgeBodyUnresolvable;
                if (self.ownsBox(edge)) |box| {
                    box.* = fresh.*;
                } else {
                    self.edge_store = store;
                    v.* = .{ .Edge = try self.boxEdge(fresh) };
                }
            },
            else => {},
        };
    }
};

/// The variable a SET clause writes.
pub fn setTarget(sc: ast.SetClause) []const u8 {
    return switch (sc) {
        .Property => |p| p.target.object,
        .Labels => |l| l.node,
        .AllProperties => |a| a.node,
    };
}

// CANARY: REQ=REQ-SONNY-3319-CURRENT-LABELS; FEATURE="VectorIndex"; ASPECT=SetPrePassLabels; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-28
/// SONNY-3319: the labels a node bound to `name` carries once `clauses` have
/// applied: `current` and every label a clause of the list sets on `name`.
/// The statement-atomicity pre-pass checks a value against these, so `SET
/// n:VD, n.emb = <2-dim vector>` is refused before anything is written when
/// VD's vector index holds 4 dimensions (the pre-pass used the labels from
/// before the SET). The caller frees the slice (not the strings).
pub fn labelsAfterSet(allocator: std.mem.Allocator, current: []const []const u8, clauses: []const ast.SetClause, name: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, current);
    for (clauses) |sc| switch (sc) {
        .Labels => |l| if (std.mem.eql(u8, l.node, name)) for (l.labels) |label| {
            const have = for (out.items) |x| {
                if (std.mem.eql(u8, x, label)) break true;
            } else false;
            if (!have) try out.append(allocator, label);
        },
        else => {},
    };
    return out.toOwnedSlice(allocator);
}

// CANARY: REQ=REQ-SONNY-3248-REPEATED-SET-TARGET; FEATURE="SetClauseSemantics"; ASPECT=RepeatedTarget; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-28
/// SONNY-3248 (round-4a review M-2): one SET clause assigns each property of
/// an element at most once. A clause's values are all evaluated before any
/// of its assignments (SONNY-3242), so two assignments to one (element,
/// property) have no order to settle them, and the second silently won
/// (`SET q.a = 1, q.a = 2`; `SET a.c = 1, b.c = 2` with a and b the same
/// node). ISO GQL raises a data exception for multiple assignments to a graph
/// element property; so does Geode now (error.RepeatedSetTarget, 22G03), before
/// anything is written. `SET n = {map}` assigns every property of n, so it
/// shares its element with no other assignment of the clause. `elements[i]`
/// is what `group[i]` targets on this row (null: nothing, or not applied).
pub fn refuseRepeatedTargets(group: []const ast.SetClause, elements: []const ?Value) !void {
    for (group, elements, 0..) |a, ea_opt, i| {
        if (a == .Labels) continue;
        const ea = ea_opt orelse continue;
        for (group[i + 1 ..], elements[i + 1 ..]) |b, eb_opt| {
            if (b == .Labels) continue;
            const eb = eb_opt orelse continue;
            if (!sameElement(ea, eb)) continue;
            const clash = switch (a) {
                .Property => |pa| switch (b) {
                    .Property => |pb| std.mem.eql(u8, pa.target.property, pb.target.property),
                    else => true,
                },
                else => true,
            };
            if (clash) return error.RepeatedSetTarget;
        }
    }
}

fn sameElement(a: Value, b: Value) bool {
    return switch (a) {
        .Node => |n| b == .Node and b.Node.id == n.id,
        .Edge => |e| b == .Edge and b.Edge.id == e.id,
        else => false,
    };
}

/// SONNY-3319: the statement-atomicity pre-pass for `clauses` over the nodes
/// `scope` binds that `filter` accepts, with each node's labels after the
/// clauses (`labelsAfterSet`): every value storable, a vector's dimension
/// included, before any assignment.
fn precheckNodeTargets(allocator: std.mem.Allocator, clauses: []const ast.SetClause, ends: []const usize, scope: *const WriteScope, filter: anytype) !void {
    // SONNY-3248: no clause assigns one property twice.
    var elements: std.ArrayList(?Value) = .empty;
    defer elements.deinit(allocator);
    var groups = ast.SetClauseGroups.init(clauses, ends);
    while (groups.next()) |group| {
        elements.clearRetainingCapacity();
        for (group) |sc| {
            const name = setTarget(sc);
            try elements.append(allocator, if (filter.applies(name)) scope.get(name) else null);
        }
        try refuseRepeatedTargets(group, elements.items);
    }
    const env = scope.env(allocator);
    for (clauses, 0..) |sc, i| {
        const name = setTarget(sc);
        const seen = for (clauses[0..i]) |prev| {
            if (std.mem.eql(u8, setTarget(prev), name)) break true;
        } else false;
        if (seen or !filter.applies(name)) continue;
        const node = switch (scope.get(name) orelse continue) {
            .Node => |n| n,
            else => continue,
        };
        const labels = try labelsAfterSet(allocator, node.labels, clauses, name);
        defer allocator.free(labels);
        try write_precheck.checkSetClausesWritableExcluding(allocator, clauses, env, name, labels, node.id);
    }
}

/// Every SET clause's target, when `filter` has no opinion.
pub const AllTargets = struct {
    pub fn applies(_: AllTargets, _: []const u8) bool {
        return true;
    }
};

// CANARY: REQ=REQ-SONNY-3242-SET-SEMANTICS; FEATURE="SetClauseSemantics"; ASPECT=ApplySetGroups; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4.zig; OWNER=engine; UPDATED=2026-09-28
/// Apply `clauses` (whose clauses end at `ends`, `ast.SetClauseGroups`) to the
/// elements `scope` binds, one SET clause at a time: every value of a clause
/// is evaluated against the bindings as they stood before it (`scope.env`),
/// then its assignments apply, then the scope is read again for the next
/// clause (and for the caller). A clause is applied only to a target
/// `filter.applies` accepts (a MERGE applies ON CREATE SET to what it created
/// and ON MATCH SET to what it matched) and that the scope binds to a node or
/// a relationship.
pub fn applySetGroups(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    clauses: []const ast.SetClause,
    ends: []const usize,
    scope: *WriteScope,
    filter: anytype,
) !void {
    if (clauses.len == 0) return;
    try precheckNodeTargets(allocator, clauses, ends, scope, filter);
    var values: std.ArrayList(Value) = .empty;
    defer values.deinit(allocator);
    var groups = ast.SetClauseGroups.init(clauses, ends);
    while (groups.next()) |group| {
        const env = scope.env(allocator);
        // Every value first, against the bindings before the clause.
        values.clearRetainingCapacity();
        for (group) |sc| {
            const name = setTarget(sc);
            const bound = if (filter.applies(name)) scope.get(name) else null;
            const element = bound != null and (bound.? == .Node or bound.? == .Edge);
            try values.append(allocator, if (!element) .Null else switch (sc) {
                .Property => |p| try eval.evalExpr(allocator, p.value, env),
                .AllProperties => |a| try eval.evalExpr(allocator, a.properties, env),
                .Labels => .Null,
            });
        }
        // Then the assignments.
        var wrote = false;
        for (group, values.items) |sc, value| {
            const name = setTarget(sc);
            if (!filter.applies(name)) continue;
            switch (scope.get(name) orelse continue) {
                .Node => |node| switch (sc) {
                    .Property => |p| try property_mutation.setNodePropertyFromValue(allocator, store, node.labels, node.id, p.target.property, value),
                    .Labels => |l| for (l.labels) |label| try store.addNodeLabel(node.id, label),
                    .AllProperties => {
                        const node_ptr = (store.nodes.getOrHydratePtr(node.id) catch null) orelse return error.NodeNotFound;
                        try property_mutation.replaceNodeProperties(allocator, store, node_ptr, value);
                    },
                },
                .Edge => |edge| switch (sc) {
                    .Property => |p| try property_mutation.setEdgePropertyFromValue(allocator, store, edge.label, edge.id, p.target.property, value),
                    // A relationship has a type, not labels (the validator refuses it).
                    .Labels => continue,
                    .AllProperties => {
                        const edge_ptr = store.getEdgePtrHydrated(edge.id) orelse return error.EdgeBodyUnresolvable;
                        try property_mutation.replaceEdgeProperties(allocator, store, edge_ptr, value);
                    },
                },
                else => continue,
            }
            wrote = true;
        }
        // The next clause (and the caller) reads what this one wrote.
        if (wrote) try scope.refresh(store);
    }
}
