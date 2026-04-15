/// RLS property-level filtering types and engine shared between rls_filter.zig and
/// procedure_registry.zig. This file must NOT import the `geode` module to avoid
/// circular module dependencies.
///
/// GAP-0280: These types bridge the rls_core.zig Value incompatibility by working with
/// string-based property comparisons using value_types.Value directly.
const std = @import("std");

// CANARY: REQ=REQ-SEC-RLS-WIRE-007; FEATURE="RLS Property Filtering"; ASPECT=SharedTypes; STATUS=TESTED; OWNER=security; UPDATED=2026-04-01

/// Comparison operators for property predicates.
pub const ComparisonOp = enum {
    eq, // equals
    neq, // not equals
    gt, // greater than
    lt, // less than
    gte, // greater than or equal
    lte, // less than or equal

    /// Parse a comparison operator from a string.
    pub fn fromString(s: []const u8) ?ComparisonOp {
        if (std.mem.eql(u8, s, "eq") or std.mem.eql(u8, s, "=")) return .eq;
        if (std.mem.eql(u8, s, "neq") or std.mem.eql(u8, s, "!=") or std.mem.eql(u8, s, "<>")) return .neq;
        if (std.mem.eql(u8, s, "gt") or std.mem.eql(u8, s, ">")) return .gt;
        if (std.mem.eql(u8, s, "lt") or std.mem.eql(u8, s, "<")) return .lt;
        if (std.mem.eql(u8, s, "gte") or std.mem.eql(u8, s, ">=")) return .gte;
        if (std.mem.eql(u8, s, "lte") or std.mem.eql(u8, s, "<=")) return .lte;
        return null;
    }
};

/// A single property comparison: "property_name op expected_value".
pub const PropertyPredicate = struct {
    property_name: []const u8,
    op: ComparisonOp,
    /// String representation of the expected value.
    expected_value: []const u8,
    /// When true, rows matching this predicate are denied (filtered out).
    /// When false, only rows matching this predicate are allowed.
    deny: bool = true,
};

/// A property-level RLS policy: binds a set of predicates to a user and optional graph.
pub const PropertyPolicy = struct {
    graph_name: ?[]const u8 = null, // null = all graphs
    user: []const u8,
    predicates: []const PropertyPredicate,
};

/// A label-level RLS policy binding: "user U must not see rows containing label L in graph G".
pub const LabelPolicy = struct {
    graph: []const u8,
    label: []const u8,
    /// When `deny` is true the label is blocked; when false the label is allowed.
    deny: bool = true,
    /// Applicable username (empty = all users).
    username: []const u8 = "",
};

/// Thread-safe, server-lifetime collection of label-level and property-level RLS policies.
/// Designed as a singleton that lives for the duration of the server process.
pub const RLSFilterEngine = struct {
    allocator: std.mem.Allocator,
    /// Protected by `mu`.
    policies: std.ArrayList(LabelPolicy),
    /// Property-level policies, protected by the same `mu`.
    property_policies: std.ArrayList(PropertyPolicy),
    mu: std.Io.Mutex = std.Io.Mutex.init,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .policies = std.ArrayList(LabelPolicy).empty,
            .property_policies = std.ArrayList(PropertyPolicy).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        // Free duped strings for each label policy.
        for (self.policies.items) |p| {
            self.allocator.free(p.graph);
            self.allocator.free(p.label);
            if (p.username.len > 0) self.allocator.free(p.username);
        }
        self.policies.deinit(self.allocator);

        // Free duped strings for each property policy.
        for (self.property_policies.items) |pp| {
            if (pp.graph_name) |g| self.allocator.free(g);
            if (pp.user.len > 0) self.allocator.free(pp.user);
            for (pp.predicates) |pred| {
                self.allocator.free(pred.property_name);
                self.allocator.free(pred.expected_value);
            }
            self.allocator.free(pp.predicates);
        }
        self.property_policies.deinit(self.allocator);
    }

    /// Register a deny policy: rows containing nodes/edges with `label` in `graph` will be
    /// filtered out for `username` (empty string = all users).
    pub fn addDenyPolicy(self: *Self, graph: []const u8, label: []const u8, username: []const u8) !void {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

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
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

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
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        for (self.policies.items) |p| {
            if (!p.deny) continue;
            if (!std.mem.eql(u8, p.graph, graph)) continue;
            if (!std.mem.eql(u8, p.label, label)) continue;
            if (p.username.len == 0 or std.mem.eql(u8, p.username, username)) {
                return true;
            }
        }
        return false;
    }

    /// Snapshot denied labels for a specific user+graph into a HashSet.
    pub fn snapshotDeniedLabels(self: *Self, allocator: std.mem.Allocator, graph: []const u8, username: []const u8) !std.StringHashMap(void) {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

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

    /// Return the number of currently active label policies.
    pub fn policyCount(self: *Self) usize {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
        return self.policies.items.len;
    }

    // ---- Property policy management ----

    /// Add a property-level policy: deny (or allow-only) rows where a node/edge property
    /// matches the given predicate, for a specific user and optional graph.
    // CANARY: REQ=REQ-SEC-RLS-WIRE-008; FEATURE="RLS Property Filtering"; ASPECT=PolicyCRUD; STATUS=TESTED; OWNER=security; UPDATED=2026-04-01
    pub fn addPropertyPolicy(self: *Self, user: []const u8, graph_name: ?[]const u8, property_name: []const u8, op: ComparisonOp, expected_value: []const u8, deny: bool) !void {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        const pred = PropertyPredicate{
            .property_name = try self.allocator.dupe(u8, property_name),
            .op = op,
            .expected_value = try self.allocator.dupe(u8, expected_value),
            .deny = deny,
        };
        const preds = try self.allocator.alloc(PropertyPredicate, 1);
        preds[0] = pred;

        const policy = PropertyPolicy{
            .graph_name = if (graph_name) |g| try self.allocator.dupe(u8, g) else null,
            .user = if (user.len > 0) try self.allocator.dupe(u8, user) else "",
            .predicates = preds,
        };
        try self.property_policies.append(self.allocator, policy);
    }

    /// Remove all property policies matching user + graph + property_name exactly.
    pub fn removePropertyPolicy(self: *Self, user: []const u8, graph_name: ?[]const u8, property_name: []const u8) void {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        var i: usize = 0;
        while (i < self.property_policies.items.len) {
            const pp = self.property_policies.items[i];
            const graph_match = blk: {
                if (graph_name == null and pp.graph_name == null) break :blk true;
                if (graph_name != null and pp.graph_name != null) break :blk std.mem.eql(u8, graph_name.?, pp.graph_name.?);
                break :blk false;
            };
            const user_match = std.mem.eql(u8, pp.user, user);
            const prop_match = blk: {
                for (pp.predicates) |pred| {
                    if (std.mem.eql(u8, pred.property_name, property_name)) break :blk true;
                }
                break :blk false;
            };

            if (graph_match and user_match and prop_match) {
                if (pp.graph_name) |g| self.allocator.free(g);
                if (pp.user.len > 0) self.allocator.free(pp.user);
                for (pp.predicates) |pred| {
                    self.allocator.free(pred.property_name);
                    self.allocator.free(pred.expected_value);
                }
                self.allocator.free(pp.predicates);
                _ = self.property_policies.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Return the number of currently active property policies.
    pub fn propertyPolicyCount(self: *Self) usize {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
        return self.property_policies.items.len;
    }

    /// Snapshot property policies applicable to a user+graph.
    pub fn snapshotPropertyPolicies(self: *Self, allocator: std.mem.Allocator, graph: []const u8, username: []const u8) !std.ArrayList(PropertyPredicate) {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        var result = std.ArrayList(PropertyPredicate).empty;
        for (self.property_policies.items) |pp| {
            if (pp.graph_name) |pg| {
                if (!std.mem.eql(u8, pg, graph)) continue;
            }
            if (pp.user.len > 0 and !std.mem.eql(u8, pp.user, username)) continue;

            for (pp.predicates) |pred| {
                try result.append(allocator, pred);
            }
        }
        return result;
    }
};

/// Global singleton -- set once at server startup, read by every connection handler.
var g_rls_filter_engine: ?*RLSFilterEngine = null;

/// Called from server/main.zig during startup.
pub fn setGlobalRLSFilterEngine(engine: ?*RLSFilterEngine) void {
    g_rls_filter_engine = engine;
}

/// Called by connection handlers and procedure registry to retrieve the engine.
pub fn getGlobalRLSFilterEngine() ?*RLSFilterEngine {
    return g_rls_filter_engine;
}

// GAP-0510 Task 3a: Global accessor for the expression-based RLS engine (rls_core.zig).
// Stored as ?*anyopaque to avoid pulling the full rls_core dependency into this
// lightweight shared-types module.  Set once at server startup; read by
// ExecutionContext wiring in the connection handler.
// CANARY: REQ=REQ-SEC-RLS-WIRE-011; FEATURE="RLS Expression Wiring"; ASPECT=ExprEngineGlobal; STATUS=IMPL; OWNER=security; UPDATED=2026-04-06
var g_expr_rls_engine: ?*anyopaque = null;

pub fn setGlobalExprRLSEngine(engine: ?*anyopaque) void {
    g_expr_rls_engine = engine;
}

pub fn getGlobalExprRLSEngine() ?*anyopaque {
    return g_expr_rls_engine;
}
