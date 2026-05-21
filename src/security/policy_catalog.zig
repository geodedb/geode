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
// CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=PolicyCatalogIntegration; STATUS=TESTED; TEST=tests/test_gps_policy_expression.zig; OWNER=security; UPDATED=2026-05-20
const policy_expression = @import("policy_expression.zig");
// CANARY: REQ=REQ-GPS-DIST-001; FEATURE="GPS PolicyVersion"; ASPECT=PolicyCatalogVersionBump; STATUS=TESTED; TEST=tests/test_gps_policy_version.zig; OWNER=security; UPDATED=2026-05-20
const policy_version = @import("policy_version.zig");
// CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=PolicyCatalogInvalidate; STATUS=TESTED; TEST=tests/test_gps_decision_cache.zig; OWNER=security; UPDATED=2026-05-20
const decision_cache = @import("decision_cache.zig");

pub const Action = enum {
    read,
    write,
    match_,
    create,
    update,
    delete,
    schema,
    // CANARY: REQ=REQ-GPS-FLE-001; FEATURE="GPS FLE Enforcement"; ASPECT=PolicyCatalogActions; STATUS=TESTED; TEST=tests/test_gps_fle_enforcement.zig; OWNER=security; UPDATED=2026-05-20
    // Phase 5 task 5-3: explicit FLE actions expressible in policy catalog.
    // Allows operators to grant decrypt_field or unwrap_key to specific principals
    // via CREATE POLICY … ACTIONS (decrypt_field) … .
    decrypt_field,
    unwrap_key,
};

pub const Effect = enum { allow, deny };

pub const Policy = struct {
    name: []const u8,
    scope_graph: []const u8,
    actions: []const Action,
    effect: Effect,
    expression_source: []const u8,
    enabled: bool,
    // CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=PolicyCompiledField; STATUS=TESTED; TEST=tests/test_gps_policy_expression.zig; OWNER=security; UPDATED=2026-05-20
    // Phase 5 Task 5-4: compiled expression for attribute-based predicates.
    // null when expression_source == "true" (trivial predicate, no compilation needed).
    // Non-null when a non-trivial expression was successfully compiled.
    compiled: ?policy_expression.CompiledExpression = null,
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
        for (self.policies.items) |*p| {
            self.allocator.free(p.name);
            self.allocator.free(p.scope_graph);
            self.allocator.free(p.expression_source);
            self.allocator.free(p.actions);
            // CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=PolicyCatalogDeinit; STATUS=TESTED; TEST=tests/test_gps_policy_expression.zig; OWNER=security; UPDATED=2026-05-20
            if (p.compiled) |*c| c.deinit();
        }
        self.policies.deinit(self.allocator);
    }

    // CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=PolicyCatalogAdd; STATUS=TESTED; TEST=tests/test_gps_policy_catalog.zig; OWNER=security; UPDATED=2026-05-20
    // CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=PolicyCatalogAddCompile; STATUS=TESTED; TEST=tests/test_gps_policy_expression.zig; OWNER=security; UPDATED=2026-05-20
    /// Duplicate all string and slice fields and append a new Policy entry.
    /// If expression_source is not "true", attempt to compile it into a
    /// CompiledExpression for fast evaluation in decide().  Compilation errors
    /// for non-trivial expressions are silently treated as "fail-closed":
    /// the policy is stored with compiled=null and decide() will skip it.
    pub fn addPolicy(self: *PolicyCatalog, args: PolicySpec) !void {
        const name_dupe = try self.allocator.dupe(u8, args.name);
        errdefer self.allocator.free(name_dupe);
        const scope_dupe = try self.allocator.dupe(u8, args.scope_graph);
        errdefer self.allocator.free(scope_dupe);
        const src_dupe = try self.allocator.dupe(u8, args.expression_source);
        errdefer self.allocator.free(src_dupe);
        const actions_dupe = try self.allocator.dupe(Action, args.actions);
        errdefer self.allocator.free(actions_dupe);

        // Compile the predicate expression if it is non-trivial.
        // The trivial "true" predicate is handled without a CompiledExpression.
        var compiled: ?policy_expression.CompiledExpression = null;
        if (!std.mem.eql(u8, args.expression_source, "true")) {
            compiled = policy_expression.compileExpression(self.allocator, args.expression_source) catch null;
        }
        errdefer if (compiled) |*c| c.deinit();

        try self.policies.append(self.allocator, .{
            .name = name_dupe,
            .scope_graph = scope_dupe,
            .actions = actions_dupe,
            .effect = args.effect,
            .expression_source = src_dupe,
            .enabled = args.enabled,
            .compiled = compiled,
        });
        // CANARY: REQ=REQ-GPS-DIST-001; FEATURE="GPS PolicyVersion"; ASPECT=PolicyCatalogAddBump; STATUS=TESTED; TEST=tests/test_gps_policy_version.zig; OWNER=security; UPDATED=2026-05-20
        _ = policy_version.incrementPolicyVersion();
        // CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=PolicyCatalogAddInvalidate; STATUS=TESTED; TEST=tests/test_gps_decision_cache.zig; OWNER=security; UPDATED=2026-05-20
        if (decision_cache.getGlobalCache()) |c| c.invalidateAll();
    }

    // CANARY: REQ=REQ-GPS-DDL-002; FEATURE="GPS Policy DDL"; ASPECT=PolicyCatalogRemove; STATUS=TESTED; TEST=tests/test_gps_policy_catalog.zig; OWNER=security; UPDATED=2026-05-20
    /// Remove the first policy whose name matches.  Returns error.PolicyNotFound
    /// when no matching entry exists.
    pub fn removePolicy(self: *PolicyCatalog, name: []const u8) !void {
        var i: usize = 0;
        while (i < self.policies.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.policies.items[i].name, name)) {
                var removed = self.policies.orderedRemove(i);
                self.allocator.free(removed.name);
                self.allocator.free(removed.scope_graph);
                self.allocator.free(removed.expression_source);
                self.allocator.free(removed.actions);
                // CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=PolicyCatalogRemoveDeinit; STATUS=TESTED; TEST=tests/test_gps_policy_expression.zig; OWNER=security; UPDATED=2026-05-20
                if (removed.compiled) |*c| c.deinit();
                // CANARY: REQ=REQ-GPS-DIST-001; FEATURE="GPS PolicyVersion"; ASPECT=PolicyCatalogRemoveBump; STATUS=TESTED; TEST=tests/test_gps_policy_version.zig; OWNER=security; UPDATED=2026-05-20
                _ = policy_version.incrementPolicyVersion();
                // CANARY: REQ=REQ-GPS-CACHE-001; FEATURE="GPS Decision Cache"; ASPECT=PolicyCatalogRemoveInvalidate; STATUS=TESTED; TEST=tests/test_gps_decision_cache.zig; OWNER=security; UPDATED=2026-05-20
                if (decision_cache.getGlobalCache()) |c| c.invalidateAll();
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

    // CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS ALTER POLICY DDL"; ASPECT=PolicyCatalogAlter; STATUS=TESTED; TEST=tests/test_gps_alter_policy.zig; OWNER=security; UPDATED=2026-05-21
    /// Update mutable fields of an existing policy in-place.
    /// Returns error.PolicyNotFound when no matching entry exists.
    /// Bumps the policy version and invalidates the decision cache after any mutation.
    pub fn alterPolicy(self: *PolicyCatalog, name: []const u8, set_enabled: ?bool) !void {
        for (self.policies.items) |*p| {
            if (std.mem.eql(u8, p.name, name)) {
                if (set_enabled) |e| p.enabled = e;
                _ = policy_version.incrementPolicyVersion();
                if (decision_cache.getGlobalCache()) |c| c.invalidateAll();
                return;
            }
        }
        return error.PolicyNotFound;
    }
};

// ---------------------------------------------------------------------------
// Global singleton (init'd at server startup, nil before that)
// ---------------------------------------------------------------------------

var g_catalog: ?*PolicyCatalog = null;

pub fn setGlobalCatalog(c: *PolicyCatalog) void {
    g_catalog = c;
}

/// Set the global catalog pointer to null.  Use in tests or on shutdown to
/// prevent stale pointers from escaping scope.
pub fn clearGlobalCatalog() void {
    g_catalog = null;
}

pub fn getGlobalCatalog() ?*PolicyCatalog {
    return g_catalog;
}

// ---------------------------------------------------------------------------
// Write-through hooks — set by server startup to persist DDL to
// __geode_security without creating a circular import from execution.zig.
//
// If no hooks are installed (CLI / test contexts) DDL is in-memory only.
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=WriteThroughHooks; STATUS=TESTED; TEST=tests/test_gps_policy_persistence.zig; OWNER=security; UPDATED=2026-05-20

/// Called with the same PolicySpec passed to addPolicy.  Errors are non-fatal
/// and logged by the server; execution continues with the in-memory update.
pub const PersistFn = *const fn (ctx: *anyopaque, spec: PolicySpec) anyerror!void;

/// Called with the policy name before removePolicy. Errors are non-fatal.
pub const DropFn = *const fn (ctx: *anyopaque, name: []const u8) anyerror!void;

pub const WriteThroughHooks = struct {
    ctx: *anyopaque,
    persist: PersistFn,
    drop: DropFn,
};

var g_hooks: ?WriteThroughHooks = null;

pub fn setWriteThroughHooks(hooks: ?WriteThroughHooks) void {
    g_hooks = hooks;
}

pub fn getWriteThroughHooks() ?WriteThroughHooks {
    return g_hooks;
}
