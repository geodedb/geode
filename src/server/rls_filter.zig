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

    var removed: usize = 0;
    var i: usize = 0;
    while (i < result.rows.len) {
        if (rowContainsDeniedLabel(engine, result.rows[i], username, graph_name)) {
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

/// Check whether a single row contains any Node or Edge value with a denied label.
fn rowContainsDeniedLabel(
    engine: *RLSFilterEngine,
    row: []const Value,
    username: []const u8,
    graph_name: []const u8,
) bool {
    for (row) |val| {
        switch (val) {
            .Node => |node| {
                for (node.labels) |label| {
                    if (engine.isLabelDenied(graph_name, label, username)) {
                        return true;
                    }
                }
            },
            .Edge => |edge| {
                if (engine.isLabelDenied(graph_name, edge.label, username)) {
                    return true;
                }
            },
            .Path => |path| {
                // Check all nodes and edges in the path.
                for (path.nodes) |node| {
                    for (node.labels) |label| {
                        if (engine.isLabelDenied(graph_name, label, username)) {
                            return true;
                        }
                    }
                }
                for (path.edges) |edge| {
                    if (engine.isLabelDenied(graph_name, edge.label, username)) {
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
