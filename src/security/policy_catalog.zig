// CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=PolicyCatalogModule; STATUS=TESTED; TEST=tests/test_gps_policy_catalog.zig; OWNER=security; UPDATED=2026-05-20
//
// policy_catalog.zig — in-memory store of GPS access-control policies.
//
// A Policy is the atomic unit of GPS authorization: it names an effect
// (allow/deny) for a set of actions on a graph scope, guarded by an optional
// filter expression.  The catalog is the runtime container; Phase 5 will add
// persistence to __geode_security.
//
// Thread-safety: the catalog itself is NOT mutex-protected.  Callers that
// need concurrent access must wrap with their own lock (Phase 4+ will add a
// RwLock in the global accessor).

const std = @import("std");

pub const Action = enum {
    read,
    write,
    match_,
    create,
    update,
    delete,
    schema,
};

pub const Effect = enum { allow, deny };

pub const Policy = struct {
    name: []const u8,
    scope_graph: []const u8,
    actions: []const Action,
    effect: Effect,
    expression_source: []const u8,
    enabled: bool,
};

/// Arguments for adding a new policy.  Separate from Policy so that callers
/// do not need to pre-allocate slices before calling addPolicy.
pub const PolicySpec = struct {
    name: []const u8,
    scope_graph: []const u8,
    actions: []const Action,
    effect: Effect,
    expression_source: []const u8,
    enabled: bool,
};

pub const PolicyCatalog = struct {
    allocator: std.mem.Allocator,
    // Use ArrayList which in Zig 0.16 is the unmanaged form: allocator passed
    // per-operation rather than stored inside the list.
    policies: std.ArrayList(Policy),

    pub fn init(allocator: std.mem.Allocator) PolicyCatalog {
        return .{
            .allocator = allocator,
            .policies = .{ .items = &.{}, .capacity = 0 },
        };
    }

    pub fn deinit(self: *PolicyCatalog) void {
        for (self.policies.items) |p| {
            self.allocator.free(p.name);
            self.allocator.free(p.scope_graph);
            self.allocator.free(p.expression_source);
            self.allocator.free(p.actions);
        }
        self.policies.deinit(self.allocator);
    }

    // CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=PolicyCatalogAdd; STATUS=TESTED; TEST=tests/test_gps_policy_catalog.zig; OWNER=security; UPDATED=2026-05-20
    /// Duplicate all string and slice fields and append a new Policy entry.
    pub fn addPolicy(self: *PolicyCatalog, args: PolicySpec) !void {
        const name_dupe = try self.allocator.dupe(u8, args.name);
        errdefer self.allocator.free(name_dupe);
        const scope_dupe = try self.allocator.dupe(u8, args.scope_graph);
        errdefer self.allocator.free(scope_dupe);
        const src_dupe = try self.allocator.dupe(u8, args.expression_source);
        errdefer self.allocator.free(src_dupe);
        const actions_dupe = try self.allocator.dupe(Action, args.actions);
        errdefer self.allocator.free(actions_dupe);

        try self.policies.append(self.allocator, .{
            .name = name_dupe,
            .scope_graph = scope_dupe,
            .actions = actions_dupe,
            .effect = args.effect,
            .expression_source = src_dupe,
            .enabled = args.enabled,
        });
    }

    // CANARY: REQ=REQ-GPS-DDL-002; FEATURE="GPS Policy DDL"; ASPECT=PolicyCatalogRemove; STATUS=TESTED; TEST=tests/test_gps_policy_catalog.zig; OWNER=security; UPDATED=2026-05-20
    /// Remove the first policy whose name matches.  Returns error.PolicyNotFound
    /// when no matching entry exists.
    pub fn removePolicy(self: *PolicyCatalog, name: []const u8) !void {
        var i: usize = 0;
        while (i < self.policies.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.policies.items[i].name, name)) {
                const removed = self.policies.orderedRemove(i);
                self.allocator.free(removed.name);
                self.allocator.free(removed.scope_graph);
                self.allocator.free(removed.expression_source);
                self.allocator.free(removed.actions);
                return;
            }
        }
        return error.PolicyNotFound;
    }

    // CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS Policy DDL"; ASPECT=PolicyCatalogList; STATUS=TESTED; TEST=tests/test_gps_policy_catalog.zig; OWNER=security; UPDATED=2026-05-20
    /// Return a read-only slice of the current policies.  The slice is valid
    /// only until the next addPolicy or removePolicy call.
    pub fn listPolicies(self: *const PolicyCatalog) []const Policy {
        return self.policies.items;
    }
};

// ---------------------------------------------------------------------------
// Global singleton (init'd at server startup, nil before that)
// ---------------------------------------------------------------------------

var g_catalog: ?*PolicyCatalog = null;

pub fn setGlobalCatalog(c: *PolicyCatalog) void {
    g_catalog = c;
}

pub fn getGlobalCatalog() ?*PolicyCatalog {
    return g_catalog;
}
