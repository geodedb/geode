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

// CANARY: REQ=REQ-SONNY-2731-POLICY-TEXT-LIMITS; FEATURE="GPS Policy Persistence"; ASPECT=PersistableLengths; STATUS=TESTED; TEST=tests/test_gps_policy_persistence.zig; OWNER=security; UPDATED=2026-09-25
/// SONNY-2731: the longest name, scope graph and USING expression that
/// `__geode_security` can store (`UserStorageBackend.persistPolicy` refuses
/// longer ones; its record fields are one byte larger). DDL refuses a longer
/// policy up front: CREATE POLICY used to accept it, keep it in memory only
/// when the write-through failed, and lose it at the next restart, and the
/// startup loader cut a stored text to its field size and compiled the cut
/// text. tests/test_gps_policy_persistence.zig pins these to the record.
pub const max_policy_name_len: usize = 63;
pub const max_policy_scope_len: usize = 63;
pub const max_policy_expression_len: usize = 511;

pub const PolicyCatalog = struct {
    allocator: std.mem.Allocator,
    // Use ArrayList which in Zig 0.16 is the unmanaged form: allocator passed
    // per-operation rather than stored inside the list.
    policies: std.ArrayList(Policy),
    /// How many policies have a compiled row condition (enabled or not), so
    /// the read path can skip the row-policy scan in O(1) when there are none.
    row_condition_policies: usize = 0,

    pub fn init(allocator: std.mem.Allocator) PolicyCatalog {
        return .{
            .allocator = allocator,
            .policies = .{ .items = &.{}, .capacity = 0 },
        };
    }

    fn hasRowCondition(compiled: ?policy_expression.CompiledExpression) bool {
        return if (compiled) |c| c.reads_row else false;
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

    // CANARY: REQ=REQ-RLS-POLICY-COMPILE-ERROR-AT-DDL; FEATURE="GPS Policy DDL"; ASPECT=CompileFailureMode; STATUS=TESTED; TEST=tests/test_rls_policy_ddl.zig; OWNER=security; UPDATED=2026-08-25
    /// How `addPolicyWithMode` reacts when the policy predicate compiler cannot
    /// compile a non-trivial USING expression.
    ///
    /// RLS-POLICY-DDL: the two call sites need OPPOSITE answers, which is why this is
    /// a parameter and not a global policy.
    pub const CompileFailureMode = enum {
        /// DDL (`CREATE`/`ALTER POLICY`): REFUSE the statement with
        /// error.UnsupportedPolicyExpression. An expression outside the
        /// compiler's subset is stored with compiled=null, and decide() treats a
        /// null-compiled non-"true" policy as fail-closed — so accepting it
        /// silently installs a policy that denies everything it was written to
        /// allow. The author is the only one who can fix that, and only at DDL
        /// time, so the refusal belongs here.
        reject,
        /// Hydration / migration: RETAIN the record fail-closed (compiled=null)
        /// and log loudly. A record persisted in __geode_security before a
        /// grammar change must never brick startup; the operator sees the warn
        /// line and rewrites the policy, and until then it denies rather than
        /// allows.
        retain_fail_closed,
    };

    // CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=PolicyCatalogAdd; STATUS=TESTED; TEST=tests/test_gps_policy_catalog.zig; OWNER=security; UPDATED=2026-05-20
    // CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=PolicyCatalogAddCompile; STATUS=TESTED; TEST=tests/test_gps_policy_expression.zig; OWNER=security; UPDATED=2026-05-20
    /// Duplicate all string and slice fields and append a new Policy entry.
    ///
    /// Retains the tolerant (`retain_fail_closed`) behaviour so existing
    /// hydration / migration callers are unchanged. DDL call sites must use
    /// `addPolicyStrict`.
    pub fn addPolicy(self: *PolicyCatalog, args: PolicySpec) !void {
        return self.addPolicyWithMode(args, .retain_fail_closed);
    }

    // CANARY: REQ=REQ-RLS-POLICY-COMPILE-ERROR-AT-DDL; FEATURE="GPS Policy DDL"; ASPECT=PolicyCatalogAddStrict; STATUS=TESTED; TEST=tests/test_rls_policy_ddl.zig; OWNER=security; UPDATED=2026-08-25
    /// `addPolicy` for the DDL path: an uncompilable USING expression is
    /// refused with error.UnsupportedPolicyExpression instead of being stored
    /// compiled=null (which decide() then silently fail-closes).
    pub fn addPolicyStrict(self: *PolicyCatalog, args: PolicySpec) !void {
        return self.addPolicyWithMode(args, .reject);
    }

    pub fn addPolicyWithMode(self: *PolicyCatalog, args: PolicySpec, on_compile_failure: CompileFailureMode) !void {
        // SONNY-2731: DDL refuses what the store cannot hold.
        if (on_compile_failure == .reject) {
            if (args.name.len > max_policy_name_len or
                args.scope_graph.len > max_policy_scope_len or
                args.expression_source.len > max_policy_expression_len)
            {
                std.log.scoped(.gps).warn(
                    "refusing policy '{s}': a field is longer than __geode_security stores (name {d}/{d}, graph {d}/{d}, USING {d}/{d} bytes)",
                    .{ args.name[0..@min(args.name.len, max_policy_name_len)], args.name.len, max_policy_name_len, args.scope_graph.len, max_policy_scope_len, args.expression_source.len, max_policy_expression_len },
                );
                return error.PolicyFieldTooLong;
            }
        }
        // CANARY: REQ=REQ-GAP-0923-ABAC-POLICY-VALIDATION; FEATURE="ABAC"; ASPECT=DuplicateNameReject; STATUS=TESTED; TEST=tests/test_gap0923_abac_policy_validation.zig; OWNER=security; UPDATED=2026-07-10
        // GAP-0923(b): reject a duplicate policy name. Two same-named rows used
        // to coexist — SHOW POLICIES listed both and a single DROP POLICY
        // removed only the first, leaving a ghost duplicate. Names are unique.
        for (self.policies.items) |*existing| {
            if (std.mem.eql(u8, existing.name, args.name)) return error.PolicyAlreadyExists;
        }

        // RLS-POLICY-DDL: compile BEFORE any allocation so a refused DDL statement
        // leaves the catalog byte-for-byte untouched.
        var compiled: ?policy_expression.CompiledExpression = null;
        if (!std.mem.eql(u8, args.expression_source, "true")) {
            compiled = policy_expression.compileExpression(self.allocator, args.expression_source) catch |err| blk: {
                switch (on_compile_failure) {
                    .reject => {
                        std.log.scoped(.gps).warn(
                            "refusing policy '{s}': USING expression does not compile ({s}): {s}",
                            .{ args.name, @errorName(err), args.expression_source },
                        );
                        return error.UnsupportedPolicyExpression;
                    },
                    .retain_fail_closed => {
                        // GAP-0923(a) / RLS-POLICY-DDL: a persisted record whose
                        // expression no longer compiles is kept fail-closed and
                        // logged, never dropped and never promoted to ALLOW.
                        std.log.scoped(.gps).warn(
                            "policy '{s}' retained FAIL-CLOSED: USING expression does not compile ({s}) and the policy will never grant access until it is rewritten: {s}",
                            .{ args.name, @errorName(err), args.expression_source },
                        );
                        break :blk null;
                    },
                }
            };
        }
        errdefer if (compiled) |*c| c.deinit();

        // CANARY: REQ=REQ-RLS-SESSION-ROW-CONDITIONS; FEATURE="GPS Row Conditions"; ASPECT=ReadOnlyRowConditions; STATUS=TESTED; TEST=tests/test_rls_session_row_conditions.zig; OWNER=security; UPDATED=2026-10-11
        // A row condition (`owner = current_user()`) filters the rows a read
        // returns (gps.rowPoliciesAllow); no write path evaluates one. DDL
        // refuses it on a policy for any other action rather than install a
        // write policy whose row condition is never true. A stored record
        // like that is kept, and its row condition stays false.
        if (on_compile_failure == .reject) {
            if (compiled) |*c| {
                if (c.reads_row) {
                    for (args.actions) |a| {
                        if (a != .read and a != .match_) {
                            std.log.scoped(.gps).warn(
                                "refusing policy '{s}': a row condition applies to READ and MATCH policies only, not {s}: {s}",
                                .{ args.name, @tagName(a), args.expression_source },
                            );
                            return error.RowConditionRequiresReadPolicy;
                        }
                    }
                }
            }
        }

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
            .compiled = compiled,
        });
        if (hasRowCondition(compiled)) self.row_condition_policies += 1;
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
                if (hasRowCondition(removed.compiled)) self.row_condition_policies -= 1;
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

    // CANARY: REQ=REQ-SONNY-2732-RLS-STRICT-POLICIES; FEATURE="GPS Policy DDL"; ASPECT=InvalidPolicyListing; STATUS=TESTED; TEST=tests/test_rls_policy_ddl.zig; OWNER=security; UPDATED=2026-09-25
    /// SONNY-2732: can `p` ever grant access? Not when its non-trivial USING
    /// expression failed to compile as it was loaded (`retain_fail_closed`):
    /// it is kept, fail-closed, until an operator rewrites it. SHOW POLICIES
    /// and `geode.auth.policy_list` report this as `valid`.
    pub fn policyIsValid(p: *const Policy) bool {
        return p.compiled != null or std.mem.eql(u8, p.expression_source, "true");
    }

    /// SONNY-2732: how many policies are not `policyIsValid` (logged at
    /// startup after hydration).
    pub fn invalidPolicyCount(self: *const PolicyCatalog) usize {
        var n: usize = 0;
        for (self.policies.items) |*p| {
            if (!policyIsValid(p)) n += 1;
        }
        return n;
    }

    // CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS Policy DDL"; ASPECT=PolicyCatalogList; STATUS=TESTED; TEST=tests/test_gps_policy_catalog.zig; OWNER=security; UPDATED=2026-05-20
    /// Return a read-only slice of the current policies.  The slice is valid
    /// only until the next addPolicy or removePolicy call.
    pub fn listPolicies(self: *const PolicyCatalog) []const Policy {
        return self.policies.items;
    }

    // CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS ALTER POLICY DDL"; ASPECT=PolicyCatalogAlter; STATUS=TESTED; TEST=tests/test_gap0858_alter_policy_persist.zig; OWNER=security; UPDATED=2026-06-09
    /// Update mutable fields of an existing policy in-place.
    /// `set_enabled` toggles the enabled flag; `rename_to` reassigns the policy
    /// name (the old name is freed and replaced — no stale entry remains).
    /// Returns error.PolicyNotFound when no matching entry exists.
    /// Returns error.PolicyAlreadyExists when `rename_to` collides with another
    /// existing policy name.
    /// Bumps the policy version and invalidates the decision cache after any mutation.
    pub fn alterPolicy(self: *PolicyCatalog, name: []const u8, set_enabled: ?bool, rename_to: ?[]const u8) !void {
        // SONNY-2731: a name the store cannot hold.
        if (rename_to) |new_name| {
            if (new_name.len > max_policy_name_len) return error.PolicyFieldTooLong;
        }
        // Reject a rename that would collide with a different existing policy.
        if (rename_to) |new_name| {
            if (!std.mem.eql(u8, new_name, name)) {
                for (self.policies.items) |*other| {
                    if (std.mem.eql(u8, other.name, new_name)) return error.PolicyAlreadyExists;
                }
            }
        }

        for (self.policies.items) |*p| {
            if (std.mem.eql(u8, p.name, name)) {
                if (set_enabled) |e| p.enabled = e;
                if (rename_to) |new_name| {
                    if (!std.mem.eql(u8, new_name, p.name)) {
                        const new_dupe = try self.allocator.dupe(u8, new_name);
                        self.allocator.free(p.name);
                        p.name = new_dupe;
                    }
                }
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

/// Called with the same PolicySpec passed to addPolicy. An error fails the
/// statement and the policy is taken out of the catalog again (SONNY-2731,
/// SONNY-2757: `execution/policy_ddl.zig`).
pub const PersistFn = *const fn (ctx: *anyopaque, spec: PolicySpec) anyerror!void;

/// Called with the policy name before removePolicy. An error (other than
/// PolicyNotFound: no stored record) fails the statement and the policy stays
/// (SONNY-2757).
pub const DropFn = *const fn (ctx: *anyopaque, name: []const u8) anyerror!void;

// CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=AlterWriteThroughHook; STATUS=TESTED; TEST=tests/test_gap0858_alter_policy_persist.zig; OWNER=security; UPDATED=2026-06-09
/// GAP-0858: called after alterPolicy mutates the in-memory catalog so the
/// enable/disable + rename change is written through to __geode_security.
/// `name` is the CURRENT (pre-rename) policy name used to locate the durable
/// record; `set_enabled` and `rename_to` mirror the alterPolicy arguments.
/// An error fails the statement and the catalog change is undone (SONNY-2757).
pub const AlterFn = *const fn (ctx: *anyopaque, name: []const u8, set_enabled: ?bool, rename_to: ?[]const u8) anyerror!void;

pub const WriteThroughHooks = struct {
    ctx: *anyopaque,
    persist: PersistFn,
    drop: DropFn,
    alter: AlterFn,
};

var g_hooks: ?WriteThroughHooks = null;

pub fn setWriteThroughHooks(hooks: ?WriteThroughHooks) void {
    g_hooks = hooks;
}

pub fn getWriteThroughHooks() ?WriteThroughHooks {
    return g_hooks;
}
