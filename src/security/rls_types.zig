/// RLS label- and property-level filtering types and THE label-deny engine:
/// the executor's and (SONNY-2729) the transport post-filter's
/// (src/server/rls_filter.zig re-exports it). This file must NOT import the `geode` module to avoid
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
///
/// SONNY-2710: each label (a node label, or an edge type) is a table, as in
/// the expression engine, and its policies combine as PostgreSQL's do
/// (`rls_core.PolicyVerdict`). A deny entry is a RESTRICTIVE policy that
/// fails for the user: it hides the row whatever else applies. An allow
/// entry is a PERMISSIVE policy that passes for the user: it can never hide
/// a row, and it admits one that only failing permissive expression
/// policies on the same table would hide.
pub const LabelPolicy = struct {
    graph: []const u8,
    label: []const u8,
    /// When `deny` is true the label is blocked; when false the label is allowed.
    deny: bool = true,
    /// Applicable username (empty = all users).
    username: []const u8 = "",
};

/// SONNY-2710: the label policies that apply to one user on one label (one
/// table) in one graph.
pub const LabelEntries = struct {
    /// A deny entry applies: a restrictive policy that fails.
    denied: bool = false,
    /// An allow entry applies: a permissive policy that passes.
    allowed: bool = false,
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

        // SONNY-3038: nothing kept (or leaked) when an allocation fails.
        const g = try self.allocator.dupe(u8, graph);
        errdefer self.allocator.free(g);
        const l = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(l);
        const u: []const u8 = if (username.len > 0) try self.allocator.dupe(u8, username) else "";
        errdefer if (u.len > 0) self.allocator.free(u);
        try self.policies.append(self.allocator, .{ .graph = g, .label = l, .deny = true, .username = u });
    }

    /// SONNY-2710: register an allow entry: a permissive policy on `label`
    /// in `graph` that passes for `username` (empty = all users). See
    /// `LabelPolicy`: it never hides a row.
    pub fn addAllowPolicy(self: *Self, graph: []const u8, label: []const u8, username: []const u8) !void {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        const g = try self.allocator.dupe(u8, graph);
        errdefer self.allocator.free(g);
        const l = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(l);
        const u: []const u8 = if (username.len > 0) try self.allocator.dupe(u8, username) else "";
        errdefer if (u.len > 0) self.allocator.free(u);
        try self.policies.append(self.allocator, .{ .graph = g, .label = l, .deny = false, .username = u });
    }

    /// Remove all deny policies matching graph+label+username exactly.
    /// SONNY-2710: allow entries are left alone (`removeAllowPolicy`).
    pub fn removeDenyPolicy(self: *Self, graph: []const u8, label: []const u8, username: []const u8) void {
        self.removeEntries(graph, label, username, true);
    }

    /// SONNY-2710: remove all allow policies matching graph+label+username
    /// exactly.
    pub fn removeAllowPolicy(self: *Self, graph: []const u8, label: []const u8, username: []const u8) void {
        self.removeEntries(graph, label, username, false);
    }

    fn removeEntries(self: *Self, graph: []const u8, label: []const u8, username: []const u8, deny: bool) void {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        var i: usize = 0;
        while (i < self.policies.items.len) {
            const p = self.policies.items[i];
            if (p.deny == deny and
                std.mem.eql(u8, p.graph, graph) and
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
        return self.labelEntries(graph, label, username).denied;
    }

    // CANARY: REQ=REQ-SONNY-2710-PG-POLICY-COMBINATION; FEATURE="RLS Expression Wiring"; ASPECT=LabelEntries; STATUS=TESTED; TEST=tests/test_sonny2710_policy_combination.zig; OWNER=security; UPDATED=2026-09-26
    /// SONNY-2710: which label policies apply to `username` on `label` in
    /// `graph` (an entry for all users applies to everyone).
    pub fn labelEntries(self: *Self, graph: []const u8, label: []const u8, username: []const u8) LabelEntries {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        var entries: LabelEntries = .{};
        for (self.policies.items) |p| {
            if (!std.mem.eql(u8, p.graph, graph)) continue;
            if (!std.mem.eql(u8, p.label, label)) continue;
            if (p.username.len != 0 and !std.mem.eql(u8, p.username, username)) continue;
            if (p.deny) entries.denied = true else entries.allowed = true;
        }
        return entries;
    }

    /// SONNY-2710: the label policies that apply to one user in one graph,
    /// each label copied (see `snapshotDeniedLabels`). Free with `deinit`.
    pub const LabelPolicySnapshot = struct {
        denied: std.StringHashMap(void),
        allowed: std.StringHashMap(void),

        /// The entries that apply on `label`.
        pub fn entries(self: *const LabelPolicySnapshot, label: []const u8) LabelEntries {
            return .{ .denied = self.denied.contains(label), .allowed = self.allowed.contains(label) };
        }

        pub fn deinit(self: *LabelPolicySnapshot) void {
            freeDeniedLabels(&self.denied);
            freeDeniedLabels(&self.allowed);
        }
    };

    /// SONNY-2710: `snapshotDeniedLabels` for both kinds of entry, taken under
    /// one lock.
    pub fn snapshotLabelPolicies(self: *Self, allocator: std.mem.Allocator, graph: []const u8, username: []const u8) !LabelPolicySnapshot {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        var snapshot: LabelPolicySnapshot = .{
            .denied = std.StringHashMap(void).init(allocator),
            .allowed = std.StringHashMap(void).init(allocator),
        };
        errdefer snapshot.deinit();
        for (self.policies.items) |p| {
            if (!std.mem.eql(u8, p.graph, graph)) continue;
            if (p.username.len != 0 and !std.mem.eql(u8, p.username, username)) continue;
            const set = if (p.deny) &snapshot.denied else &snapshot.allowed;
            if (set.contains(p.label)) continue;
            const label = try allocator.dupe(u8, p.label);
            errdefer allocator.free(label);
            try set.put(label, {});
        }
        return snapshot;
    }

    // CANARY: REQ=REQ-SONNY-2679-LABEL-SNAPSHOT-OWNED; FEATURE="RLS Query Enforcement"; ASPECT=SnapshotOwnsLabels; STATUS=TESTED; TEST=tests/test_sonny2679_rls_hop_targets.zig; OWNER=security; UPDATED=2026-09-25
    /// Snapshot denied labels for a specific user+graph into a HashSet that
    /// holds its own copy of every label (SONNY-2679 review: it used to borrow
    /// each policy's string, which `removeDenyPolicy` frees while a caller
    /// still reads the set). Taken once per traversal
    /// (`match_operations.LabelDenySnapshot`) instead of calling
    /// `isLabelDenied`, which takes the lock, per label. Free the set with
    /// `freeDeniedLabels`.
    pub fn snapshotDeniedLabels(self: *Self, allocator: std.mem.Allocator, graph: []const u8, username: []const u8) !std.StringHashMap(void) {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        var denied = std.StringHashMap(void).init(allocator);
        errdefer freeDeniedLabels(&denied);
        for (self.policies.items) |p| {
            if (!p.deny) continue;
            if (!std.mem.eql(u8, p.graph, graph)) continue;
            if (p.username.len != 0 and !std.mem.eql(u8, p.username, username)) continue;
            if (denied.contains(p.label)) continue;
            const label = try allocator.dupe(u8, p.label);
            errdefer allocator.free(label);
            try denied.put(label, {});
        }
        return denied;
    }

    /// Free a set from `snapshotDeniedLabels`: its labels, then the set.
    pub fn freeDeniedLabels(set: *std.StringHashMap(void)) void {
        var it = set.keyIterator();
        while (it.next()) |key| set.allocator.free(key.*);
        set.deinit();
    }

    /// Return the number of currently active label policies.
    pub fn policyCount(self: *Self) usize {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
        return self.policies.items.len;
    }

    /// SONNY-3038: remove one deny entry matching graph+label+username
    /// exactly (the undo of one `addDenyPolicy`; another identical entry, if
    /// any, stays). SONNY-2729: moved here from the post-filter's engine.
    pub fn removeOneDenyPolicy(self: *Self, graph: []const u8, label: []const u8, username: []const u8) void {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());

        var i = self.policies.items.len;
        while (i > 0) {
            i -= 1;
            const p = self.policies.items[i];
            if (p.deny and
                std.mem.eql(u8, p.graph, graph) and
                std.mem.eql(u8, p.label, label) and
                std.mem.eql(u8, p.username, username))
            {
                self.allocator.free(p.graph);
                self.allocator.free(p.label);
                if (p.username.len > 0) self.allocator.free(p.username);
                _ = self.policies.orderedRemove(i);
                return;
            }
        }
    }

    /// True iff at least one deny entry applies to `graph`: the transport
    /// post-filter's fast-path gate, which skips the snapshot and the row
    /// scan for a graph with no label denies. SONNY-2729: moved here from
    /// the post-filter's engine.
    pub fn hasPoliciesForGraph(self: *Self, graph: []const u8) bool {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
        for (self.policies.items) |p| {
            if (!p.deny) continue;
            if (std.mem.eql(u8, p.graph, graph)) return true;
        }
        return false;
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
