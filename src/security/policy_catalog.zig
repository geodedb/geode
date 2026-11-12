// CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=PolicyCatalogModule; STATUS=TESTED; TEST=tests/test_gps_policy_catalog.zig; OWNER=security; UPDATED=2026-05-20
//
// policy_catalog.zig — in-memory store of GPS access-control policies.
//
// A Policy is the atomic unit of GPS authorization: it names an effect
// (allow/deny) for a set of actions on a graph scope, guarded by an optional
// filter expression.  The catalog is the runtime container; Phase 5 will add
// persistence to __geode_security.
//
// Thread-safety (SONNY-2756): `PolicyCatalog.rwlock`. Every change (add,
// remove, alter, disable) takes it exclusively for the change alone; a reader
// walks the policies only through `acquireRead` (shared) and copies what it
// keeps before `release`. See `PolicyCatalog.rwlock` for the lock order.

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

/// SONNY-2781: does some enforcement point ask `gps.decide` for a request a
/// deny naming `action` matches? READ and MATCH: the handlers' read gate and
/// read-only procedures; WRITE, CREATE, UPDATE, DELETE: the handlers' write
/// gate per statement; SCHEMA: the DDL gates; DECRYPT_FIELD: field
/// decryption. UNWRAP_KEY: nothing.
pub fn denyEnforced(action: Action) bool {
    return switch (action) {
        .read, .match_, .write, .create, .update, .delete, .schema, .decrypt_field => true,
        .unwrap_key => false,
    };
}

const lock_io = std.Io.Threaded.global_single_threaded.io();

pub const PolicyCatalog = struct {
    allocator: std.mem.Allocator,
    // Use ArrayList which in Zig 0.16 is the unmanaged form: allocator passed
    // per-operation rather than stored inside the list.
    policies: std.ArrayList(Policy),
    // CANARY: REQ=REQ-SONNY-2756-POLICY-CATALOG-LOCK; FEATURE="GPS Policy Evaluation"; ASPECT=CatalogRwLock; STATUS=TESTED; TEST=tests/test_sonny2756_policy_catalog_concurrency.zig; OWNER=security; UPDATED=2026-11-11
    /// SONNY-2756: guards `policies` and every policy's fields. `gps.decide`
    /// (and its helpers), SHOW POLICIES, SHOW GRANTS FOR,
    /// `geode.auth.policy_list` and the policy DDL's lookups hold it shared
    /// (`acquireRead`) while they walk the policies; `addPolicy*`,
    /// `removePolicy`, `alterPolicy` and `disableAllowPoliciesWithPrefix`
    /// hold it exclusively for the change alone, never across a
    /// `__geode_security` write-through, I/O or a graph lock. The catalog had
    /// no lock: a reader on one connection walked a list another
    /// connection's DDL was reallocating, read a dropped or renamed policy's
    /// freed strings, and a decision's deny scan and allow scan could see two
    /// different catalogs.
    ///
    /// Lock order (CLAUDE.md, tier 6.5): taken while a caller holds a graph
    /// lock or any lower tier. While it is held only leaf locks are taken:
    /// the decision cache's mutex (`invalidateAll` under exclusive, `insert`
    /// under shared), `GraphRBACPolicy.grants_mutex` and the user attribute
    /// store's mutex (decide's grant lookup and USING evaluation, shared);
    /// none of them is ever held while this one is taken. `std.Io.RwLock`
    /// prefers writers: a thread holding it shared must not take it shared
    /// again (a waiting writer would deadlock both), so `decide` takes it
    /// once and its helpers never nest.
    rwlock: std.Io.RwLock = .init,

    pub fn init(allocator: std.mem.Allocator) PolicyCatalog {
        return .{
            .allocator = allocator,
            .policies = .{ .items = &.{}, .capacity = 0 },
        };
    }

    /// SONNY-2756: a shared hold on the catalog (`acquireRead`). The
    /// policies, and every slice in them, are valid until `release`; a
    /// caller copies what it keeps past it, and takes no other lock but the
    /// leaves `rwlock` names while it holds this.
    pub const ReadView = struct {
        cat: *PolicyCatalog,

        pub fn policies(self: ReadView) []const Policy {
            return self.cat.policies.items;
        }

        pub fn release(self: ReadView) void {
            self.cat.rwlock.unlockShared(lock_io);
        }
    };

    /// SONNY-2756: hold the catalog shared until `ReadView.release`.
    pub fn acquireRead(self: *PolicyCatalog) ReadView {
        self.rwlock.lockSharedUncancelable(lock_io);
        return .{ .cat = self };
    }

    /// SONNY-2756: is there a policy named `name`?
    pub fn contains(self: *PolicyCatalog, name: []const u8) bool {
        return self.enabledOf(name) != null;
    }

    /// SONNY-2756: the enabled flag of the policy named `name`, or null when
    /// there is none.
    pub fn enabledOf(self: *PolicyCatalog, name: []const u8) ?bool {
        const view = self.acquireRead();
        defer view.release();
        for (view.policies()) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p.enabled;
        }
        return null;
    }

    /// SONNY-2756: how many policies the catalog holds.
    pub fn count(self: *PolicyCatalog) usize {
        const view = self.acquireRead();
        defer view.release();
        return view.policies().len;
    }

    fn nameTakenLocked(self: *const PolicyCatalog, name: []const u8) bool {
        for (self.policies.items) |*existing| {
            if (std.mem.eql(u8, existing.name, name)) return true;
        }
        return false;
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
        // CANARY: REQ=REQ-SONNY-2781-GPS-ACTION-ENFORCEMENT; FEATURE="GPS Policy Evaluation"; ASPECT=UnenforcedDenyRefused; STATUS=TESTED; TEST=tests/test_sonny2781_gps_action_enforcement.zig; OWNER=security; UPDATED=2026-11-11
        // SONNY-2781: a deny must deny. No enforcement point asks for
        // UNWRAP_KEY (key unwrapping is Admin-only and not policy-gated), so a
        // deny naming it would be accepted and do nothing: refused, in every
        // mode (DDL and hydration alike; hydration fails closed on it, and no
        // stored record can carry it: the record has no bit for it). Every
        // other action a policy can name is enforced (docs/security/
        // gps-decide.md, "What each action enforces"). An allow naming
        // UNWRAP_KEY grants nothing and is accepted, as before.
        if (args.effect == .deny) {
            for (args.actions) |a| {
                if (!denyEnforced(a)) {
                    std.log.scoped(.gps).warn("refusing deny policy '{s}': no enforcement point asks for the {s} action, so the deny would do nothing", .{ args.name[0..@min(args.name.len, max_policy_name_len)], @tagName(a) });
                    return error.PolicyActionNotEnforced;
                }
            }
        }
        // CANARY: REQ=REQ-GAP-0923-ABAC-POLICY-VALIDATION; FEATURE="ABAC"; ASPECT=DuplicateNameReject; STATUS=TESTED; TEST=tests/test_gap0923_abac_policy_validation.zig; OWNER=security; UPDATED=2026-07-10
        // GAP-0923(b): reject a duplicate policy name. Two same-named rows used
        // to coexist — SHOW POLICIES listed both and a single DROP POLICY
        // removed only the first, leaving a ghost duplicate. Names are unique.
        // SONNY-2756: checked here, before the expression is compiled (so a
        // duplicate is reported as one whatever its USING), and again under
        // the exclusive hold that appends.
        if (self.contains(args.name)) return error.PolicyAlreadyExists;

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

        const name_dupe = try self.allocator.dupe(u8, args.name);
        errdefer self.allocator.free(name_dupe);
        const scope_dupe = try self.allocator.dupe(u8, args.scope_graph);
        errdefer self.allocator.free(scope_dupe);
        const src_dupe = try self.allocator.dupe(u8, args.expression_source);
        errdefer self.allocator.free(src_dupe);
        const actions_dupe = try self.allocator.dupe(Action, args.actions);
        errdefer self.allocator.free(actions_dupe);

        // SONNY-2756: the change, the version bump and the cache
        // invalidation under one exclusive hold, so no reader sees the new
        // catalog with the old version or the reverse.
        self.rwlock.lockUncancelable(lock_io);
        defer self.rwlock.unlock(lock_io);
        if (self.nameTakenLocked(args.name)) return error.PolicyAlreadyExists;
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
        self.rwlock.lockUncancelable(lock_io);
        defer self.rwlock.unlock(lock_io);
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

    // CANARY: REQ=REQ-SONNY-4877-GRANT-RETIRE-FAIL-CLOSED; FEATURE="PerGraphGrants"; ASPECT=DisableAllowsByPrefix; STATUS=TESTED; TEST=tests/test_sonny4877_grant_retire_fail_closed.zig; OWNER=security; UPDATED=2026-11-11
    /// SONNY-4877: disable every enabled allow-effect policy whose name starts
    /// with `prefix`, in place. Deny policies are left as they are. Cannot
    /// fail and allocates nothing, so a caller can take allows out of force
    /// before any step that can fail. Bumps the policy version and
    /// invalidates the decision cache when anything changed. Returns how many
    /// policies were disabled.
    pub fn disableAllowPoliciesWithPrefix(self: *PolicyCatalog, prefix: []const u8) usize {
        self.rwlock.lockUncancelable(lock_io);
        defer self.rwlock.unlock(lock_io);
        var n: usize = 0;
        for (self.policies.items) |*p| {
            if (p.effect != .allow or !p.enabled) continue;
            if (!std.mem.startsWith(u8, p.name, prefix)) continue;
            p.enabled = false;
            n += 1;
        }
        if (n > 0) {
            _ = policy_version.incrementPolicyVersion();
            if (decision_cache.getGlobalCache()) |c| c.invalidateAll();
        }
        return n;
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
    pub fn invalidPolicyCount(self: *PolicyCatalog) usize {
        const view = self.acquireRead();
        defer view.release();
        var n: usize = 0;
        for (view.policies()) |*p| {
            if (!policyIsValid(p)) n += 1;
        }
        return n;
    }

    // CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS Policy DDL"; ASPECT=PolicyCatalogList; STATUS=TESTED; TEST=tests/test_gps_policy_catalog.zig; OWNER=security; UPDATED=2026-05-20
    /// Return a read-only slice of the current policies, WITHOUT the lock.
    /// The slice is valid only until the next change. SONNY-2756: for a
    /// catalog no other thread can reach (a test's own catalog, or startup
    /// before any listener); code that runs while the server serves uses
    /// `acquireRead` (tests/test_sonny2756_policy_catalog_concurrency.zig
    /// keeps it out of src/).
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
        // SONNY-2756: the new name is copied before the exclusive hold, and
        // freed again when it is not used.
        var new_dupe: ?[]u8 = if (rename_to) |new_name| try self.allocator.dupe(u8, new_name) else null;
        defer if (new_dupe) |d| self.allocator.free(d);
        self.rwlock.lockUncancelable(lock_io);
        defer self.rwlock.unlock(lock_io);
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
                        self.allocator.free(p.name);
                        p.name = new_dupe.?;
                        new_dupe = null;
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
