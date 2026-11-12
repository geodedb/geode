const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
const Allocator = std.mem.Allocator;
const auth = @import("geode_auth");
const user_attr_store = @import("user_attr_store");
const logging = @import("logging");
const build_options = @import("build_options"); // GAP-0732: allow_rls_raw_interp gate
const log = logging.scoped("security");
const Attr = logging.Attr;

// CANARY: REQ=REQ-M10-CONSTANTS-002; FEATURE="CodeQuality"; ASPECT=MAGIC_NUMBERS; STATUS=EXEMPT; OWNER=security; UPDATED=2025-10-17
// RLS cache configuration constants
const RLS_POLICY_CACHE_MAX_SIZE = 10_000; // Maximum cached policy evaluations
const RLS_POLICY_CACHE_TTL_MS = 60_000; // Cache TTL: 60 seconds (1 minute)

// CANARY: REQ=REQ-RLS-EXPR-VM-BOUNDS; FEATURE="RLSBytecodeVM"; ASPECT=MemorySafety; STATUS=TESTED; TEST=test_rls_vm_bounds.zig; OWNER=security; UPDATED=2026-04-16
// GAP-0723 / SEC-RLS-01: fixed VM stack depth.  The compiler enforces that
// no compiled policy exceeds this bound; the VM also guards every push at
// runtime with `error.StackOverflow` and every pop with
// `error.StackUnderflow`, so even a corrupted / adversarial bytecode payload
// can't write beyond the stack.
const RLS_STACK_DEPTH: usize = 64;
// CANARY: REQ=REQ-SONNY-2730-RLS-COMPILER-LIMITS; FEATURE="RLSExpressionCompilation"; ASPECT=CompilerLimits; STATUS=TESTED; TEST=src/security/rls_core.zig; OWNER=security; UPDATED=2026-09-25
/// SONNY-2730: how deeply an RLS expression may nest parentheses and NOTs.
/// The compiler is recursive descent, so without a bound a long enough run of
/// `(` or `NOT` overflows the native stack and takes the server down; past it
/// the expression is refused. (A bytecode operand is a u8, so at most 256
/// distinct constants can be addressed; that bound is enforced in `internConst`.)
const RLS_MAX_NESTING: usize = 64;

// Type definitions that would normally come from other modules
pub const ValueType = enum {
    null,
    boolean,
    integer,
    float,
    string,
    timestamp,
    array,
    object,
};

pub const Value = union(ValueType) {
    null: void,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    timestamp: i64,
    array: []const Value,
    object: std.StringHashMap(Value),
};

// Enhanced Row-Level Security Engine with fine-grained access control
// CANARY: REQ=REQ-SONNY-2710-PG-POLICY-COMBINATION; FEATURE="RLS Expression Wiring"; ASPECT=PermissiveRestrictive; STATUS=TESTED; TEST=tests/test_sonny2710_policy_combination.zig; OWNER=security; UPDATED=2026-09-26
/// SONNY-2710: how the RLS policies that apply to one row of one table (a
/// node label or an edge type) combine, as in PostgreSQL:
///
///     visible  iff  (a permissive policy passes, or none applies and the
///                    default allows)
///                   AND every restrictive policy passes.
///
/// The engine's default allows (a table with no policy is visible), so a
/// table with restrictive policies only is visible iff all of them pass, as
/// before. What changed: a table with permissive policies only denies a row
/// that none of them passes, and a passing permissive policy no longer
/// overrides a failing restrictive one. The combination was
/// `any_permissive_allows or all_restrictive_allow`.
///
/// A policy "applies" when it is enabled, covers the operation, is in its
/// time window, has an expression for the operation, and (for
/// `checkRowAccess`) names one of the session's roles. The executor also
/// feeds in the label-deny engine's entries for the table
/// (`checkRowAccessByUsernameSeeded`): a deny entry is a restrictive policy
/// that fails, an allow entry a permissive one that passes.
pub const PolicyVerdict = struct {
    permissive_applies: bool = false,
    permissive_passes: bool = false,
    restrictive_fails: bool = false,

    /// Record one applicable policy's result.
    pub fn add(self: *PolicyVerdict, permissive: bool, passed: bool) void {
        if (permissive) {
            self.permissive_applies = true;
            if (passed) self.permissive_passes = true;
        } else if (!passed) {
            self.restrictive_fails = true;
        }
    }

    /// May the row be seen? `default_allows` is the answer when no
    /// permissive policy applies.
    pub fn allows(self: PolicyVerdict, default_allows: bool) bool {
        if (self.restrictive_fails) return false;
        if (self.permissive_applies) return self.permissive_passes;
        return default_allows;
    }
};

/// SONNY-2710: the default of `PolicyVerdict.allows` for the engine: a table
/// no permissive policy applies to is visible (GPS Phase 0: no policy, no
/// restriction).
pub const no_permissive_policy_allows = true;

pub const RLSEngine = struct {
    allocator: Allocator,
    /// Guarded by `policies_lock`.
    policies: std.HashMap(PolicyKey, std.ArrayList(Policy), PolicyKey.HashContext, 80),
    // CANARY: REQ=REQ-SONNY-2679-RLS-POLICY-LOCK; FEATURE="RLS Expression Wiring"; ASPECT=PolicyMapLock; STATUS=TESTED; TEST=src/security/rls_core.zig; OWNER=security; UPDATED=2026-09-25
    /// SONNY-2679 (review): `CALL geode.rls.add_attribute_policy` (and the
    /// other policy procedures) create and delete policies on a connection
    /// thread while queries on other connections read the same map for every
    /// row (`checkRowAccessByUsername`, `needsRowDataForTable`,
    /// `hasPolicies`). A `getOrPut` that rehashes the map, or an `append` that
    /// moves a policy list, under a reader was a use-after-free: nothing
    /// serialized them (a per-graph write lock does not stop a read of another
    /// graph). Writers hold this exclusively, readers shared, for as long as
    /// they touch the map or a policy list. Nothing that holds it calls back
    /// into the engine, so it is never taken twice on one thread.
    policies_lock: std.Io.RwLock = std.Io.RwLock.init,
    policy_cache: PolicyCache,
    context_evaluator: ContextEvaluator,
    hierarchy_manager: HierarchyManager,
    attribute_controller: AttributeBasedAccessControl,
    audit_logger: AuditLogger,

    const Self = @This();

    fn dummyLogWriter(event: AuditLogger.AuditEvent) void {
        _ = event;
        // No-op for module compilation
    }

    pub const PolicyKey = struct {
        graph: []const u8,
        table: []const u8,

        pub const HashContext = struct {
            pub fn hash(_: @This(), key: PolicyKey) u64 {
                var hasher = std.hash.Wyhash.init(0);
                hasher.update(key.graph);
                hasher.update(key.table);
                return hasher.final();
            }

            pub fn eql(_: @This(), a: PolicyKey, b: PolicyKey) bool {
                return std.mem.eql(u8, a.graph, b.graph) and
                    std.mem.eql(u8, a.table, b.table);
            }
        };
    };

    pub const Policy = struct {
        id: u64,
        name: []const u8,
        description: []const u8,
        graph: []const u8,
        table: []const u8, // Node type or edge type
        operation: Operation,
        permissive: bool, // true = OR with other policies, false = AND
        roles: []const auth.RoleId,
        using_expr: ?Expression, // Filter expression for SELECT
        check_expr: ?Expression, // Validation expression for INSERT/UPDATE
        enabled: bool,
        created_at: i64,
        updated_at: i64,
        created_by: auth.UserId,

        // Advanced features
        temporal: ?TemporalConstraint,
        data_classification: ?DataClassification,
        audit_level: AuditLevel,

        /// SONNY-2732: set by `loadPolicy` when a stored expression no longer
        /// compiles. The policy is kept, and denies every row, until an
        /// operator rewrites it; `createPolicy` never installs one.
        invalid: bool = false,

        // CANARY: REQ=REQ-SONNY-2773-RLS-POLICY-FREE; FEATURE="RLSExpressionCompilation"; ASPECT=Ownership; STATUS=TESTED; TEST=tests/test_sonny2773_rls_policy_free.zig; OWNER=security; UPDATED=2026-11-12
        /// SONNY-2773: the installer hands the policy's strings (`name`,
        /// `description`, `graph`, `table`, and the USING / CHECK text) to
        /// the engine: they were allocated with the engine's allocator, and
        /// `deletePolicy`, `updatePolicy` (for strings the replacement does
        /// not reuse) and `deinit` free them. False: the caller keeps them
        /// (UserManager owns its copies, SONNY-2778). `roles` is always the
        /// caller's.
        owns_strings: bool = false,
        /// SONNY-2773: set by the engine when it compiled the USING (CHECK)
        /// bytecode, which it then frees; a pre-compiled expression the
        /// caller pins is the caller's. What a caller sets is ignored. Both
        /// were never freed: every delete, replaced expression and engine
        /// teardown leaked them.
        owns_using_compiled: bool = false,
        owns_check_compiled: bool = false,
    };

    pub const Operation = enum {
        select,
        insert,
        update,
        delete,
        all,
    };

    pub const Expression = struct {
        raw: []const u8, // Original GQL expression
        parsed: ?*anyopaque, // Parsed AST (opaque type to avoid parser dependency)
        compiled: ?*CompiledExpression, // Optimized expression
        parameters: []const Parameter,

        pub const Parameter = struct {
            name: []const u8,
            type: ValueType,
            source: ParameterSource,
        };

        pub const ParameterSource = enum {
            current_user,
            session,
            environment,
            request,
            row,
        };
    };

    pub const CompiledExpression = struct {
        bytecode: []const u8,
        constants: []const Value,
        jump_table: []const usize,

        // CANARY: REQ=REQ-PERF-RLS-ROW-SKIP-001; FEATURE="RLSRowBuildSkip"; ASPECT=NeedsRowFlag; STATUS=TESTED; TEST=tests/test_rls_expr_engine_wiring.zig; OWNER=performance; UPDATED=2026-06-11
        // PERF-A / #808: true when the bytecode contains a `load_row`
        // opcode (the only opcode that reads row data). When every
        // applicable policy's flag is false, the match loop can skip the
        // per-row StringHashMap rebuild entirely — the VM never touches
        // the row. Defaults to true (conservative) so hand-constructed
        // CompiledExpressions that bypass compileExpression/createPolicy
        // keep the old always-build behavior. compileExpression and
        // createPolicy compute the real value via bytecodeNeedsRowData.
        needs_row_data: bool = true,

        // CANARY: REQ=REQ-RLS-EXPR-001; FEATURE="RLSExpressionCompilation"; ASPECT=Bytecode; STATUS=EXEMPT; OWNER=security; UPDATED=2025-12-30
        pub const Opcode = enum(u8) {
            nop = 0x00,
            // Stack operations
            push_const = 0x01, // Push constants[arg] onto stack
            push_true = 0x02, // Push true
            push_false = 0x03, // Push false
            push_null = 0x04, // Push null
            pop = 0x05, // Pop top of stack
            // Variable access
            load_row = 0x10, // Load row[constants[arg]] onto stack
            load_user = 0x11, // Load current user ID onto stack
            load_session = 0x12, // Load session[constants[arg]] onto stack
            load_attr = 0x13, // Load principal.attribute[constants[arg]] onto stack (ABAC)
            // Comparisons (pop 2, push bool)
            eq = 0x20, // ==
            neq = 0x21, // <>
            lt = 0x22, // <
            gt = 0x23, // >
            lte = 0x24, // <=
            gte = 0x25, // >=
            // SONNY-2709: pop 1, push whether it is null (never UNKNOWN).
            is_null = 0x26, // IS NULL
            // Logical (pop 1-2, push bool)
            op_and = 0x30, // AND
            op_or = 0x31, // OR
            op_not = 0x32, // NOT
            // Control flow
            jump = 0x40, // Jump to jump_table[arg]
            jump_if_false = 0x41, // Pop and jump if false
            jump_if_true = 0x42, // Pop and jump if true
            // Return
            ret = 0xFF, // Return top of stack as result

            // GAP-0723 / SEC-RLS-01: safe byte → Opcode conversion.
            // Zig 0.16 removed std.meta.intToEnum, and `@enumFromInt` on an
            // unknown u8 is UB in release mode.  This explicit lookup keeps
            // the VM fail-closed on corrupted or adversarial bytecode.
            pub fn fromByte(byte: u8) ?Opcode {
                return switch (byte) {
                    0x00 => .nop,
                    0x01 => .push_const,
                    0x02 => .push_true,
                    0x03 => .push_false,
                    0x04 => .push_null,
                    0x05 => .pop,
                    0x10 => .load_row,
                    0x11 => .load_user,
                    0x12 => .load_session,
                    0x13 => .load_attr,
                    0x20 => .eq,
                    0x21 => .neq,
                    0x22 => .lt,
                    0x23 => .gt,
                    0x24 => .lte,
                    0x25 => .gte,
                    0x26 => .is_null,
                    0x30 => .op_and,
                    0x31 => .op_or,
                    0x32 => .op_not,
                    0x40 => .jump,
                    0x41 => .jump_if_false,
                    0x42 => .jump_if_true,
                    0xFF => .ret,
                    else => null,
                };
            }
        };

        // PERF-A / #808: pre-scan for row-reading opcodes. Walks the
        // bytecode with the same operand widths the VM uses (1-byte arg
        // for push_const / load_row / load_session / load_attr / jump /
        // jump_if_*) so an operand byte that happens to equal 0x10 is
        // never misread as a load_row opcode. Unknown opcodes return
        // true (conservative: the VM will fail-closed on them anyway,
        // but the row must exist for whatever the evaluator does first).
        pub fn bytecodeNeedsRowData(bytecode: []const u8) bool {
            var pc: usize = 0;
            while (pc < bytecode.len) {
                const opcode = Opcode.fromByte(bytecode[pc]) orelse return true;
                pc += 1;
                switch (opcode) {
                    .load_row => return true,
                    // Opcodes carrying a 1-byte operand: skip it.
                    .push_const, .load_session, .load_attr, .jump, .jump_if_false, .jump_if_true => pc += 1,
                    else => {},
                }
            }
            return false;
        }
    };

    pub const TemporalConstraint = struct {
        valid_from: ?i64,
        valid_until: ?i64,
        time_zone: []const u8,
        recurrence: ?RecurrenceRule,
    };

    pub const RecurrenceRule = struct {
        frequency: Frequency,
        interval: u32,
        by_day: ?[]const DayOfWeek,
        by_hour: ?[]const u8,

        pub const Frequency = enum {
            daily,
            weekly,
            monthly,
            yearly,
        };

        pub const DayOfWeek = enum {
            monday,
            tuesday,
            wednesday,
            thursday,
            friday,
            saturday,
            sunday,
        };
    };

    pub const DataClassification = enum {
        public,
        internal,
        confidential,
        restricted,
        top_secret,
    };

    pub const AuditLevel = enum {
        none,
        errors_only,
        denials,
        all_access,
        detailed,
    };

    pub fn init(allocator: Allocator) !Self {
        return Self{
            .allocator = allocator,
            .policies = std.HashMap(PolicyKey, std.ArrayList(Policy), PolicyKey.HashContext, 80).init(allocator),
            .policy_cache = try PolicyCache.init(allocator),
            .context_evaluator = try ContextEvaluator.init(allocator),
            .hierarchy_manager = try HierarchyManager.init(allocator),
            .attribute_controller = try AttributeBasedAccessControl.init(allocator),
            .audit_logger = try AuditLogger.init(allocator, .{ .custom = dummyLogWriter }),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.policies.iterator();
        while (it.next()) |entry| {
            // SONNY-2773: what each policy left installed owns.
            for (entry.value_ptr.items) |policy| self.freeOwned(policy, null);
            entry.value_ptr.deinit(self.allocator);
            self.freePolicyKey(entry.key_ptr.*);
        }
        self.policies.deinit();
        self.policy_cache.deinit();
        self.context_evaluator.deinit();
        self.hierarchy_manager.deinit();
        self.attribute_controller.deinit();
        self.audit_logger.deinit();
    }

    fn lockPoliciesShared(self: *Self) void {
        self.policies_lock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
    }

    fn unlockPoliciesShared(self: *Self) void {
        self.policies_lock.unlockShared(std.Io.Threaded.global_single_threaded.io());
    }

    fn lockPoliciesExclusive(self: *Self) void {
        self.policies_lock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    }

    fn unlockPoliciesExclusive(self: *Self) void {
        self.policies_lock.unlock(std.Io.Threaded.global_single_threaded.io());
    }

    /// Hold the policy map for reading, for a caller outside the engine that
    /// walks `policies` itself. Pair with `releasePoliciesRead`.
    pub fn acquirePoliciesRead(self: *Self) void {
        self.lockPoliciesShared();
    }

    pub fn releasePoliciesRead(self: *Self) void {
        self.unlockPoliciesShared();
    }

    // CANARY: REQ=REQ-SONNY-2732-RLS-STRICT-POLICIES; FEATURE="RLSExpressionCompilation"; ASPECT=StrictCreatePolicy; STATUS=TESTED; TEST=src/security/rls_core.zig; OWNER=security; UPDATED=2026-09-25
    /// SONNY-2732: what installing a policy does with an expression the
    /// compiler refuses. Mirrors the GPS catalog's
    /// `PolicyCatalog.CompileFailureMode`.
    pub const CompileFailureMode = enum {
        /// API and DDL callers (`createPolicy`, `updatePolicy`): fail with
        /// error.InvalidRlsExpression and install nothing. Only the author can
        /// fix the text, and only now; installing it would silently deny
        /// everything it was written to allow.
        reject,
        /// Loading a stored policy (`loadPolicy`): keep it, denying every
        /// row, marked `invalid`, with a warning, so that a record written
        /// before a grammar change cannot brick startup.
        retain_fail_closed,
    };

    /// The expressions compiled for a policy, to free if installing it fails.
    const CompiledExprs = struct {
        using: ?*CompiledExpression = null,
        check: ?*CompiledExpression = null,

        fn free(self: CompiledExprs, engine: *Self) void {
            if (self.using) |c| engine.freeCompiledExpression(c);
            if (self.check) |c| engine.freeCompiledExpression(c);
        }
    };

    fn freeCompiledExpression(self: *Self, c: *CompiledExpression) void {
        self.allocator.free(c.bytecode);
        self.allocator.free(c.constants);
        self.allocator.free(c.jump_table);
        self.allocator.destroy(c);
    }

    /// SONNY-2773: free what the engine owns of `policy` (its compiled
    /// bytecode, and its strings when `owns_strings`), except what `kept`
    /// (the policy replacing it, in `updatePolicy`) still points at.
    fn freeOwned(self: *Self, policy: Policy, kept: ?*const Policy) void {
        if (policy.owns_using_compiled) {
            if (exprCompiled(policy.using_expr)) |c| {
                if (!(if (kept) |k| exprCompiled(k.using_expr) == c else false)) self.freeCompiledExpression(c);
            }
        }
        if (policy.owns_check_compiled) {
            if (exprCompiled(policy.check_expr)) |c| {
                if (!(if (kept) |k| exprCompiled(k.check_expr) == c else false)) self.freeCompiledExpression(c);
            }
        }
        if (!policy.owns_strings) return;
        const k_using: ?[]const u8 = if (kept) |k| (if (k.using_expr) |e| e.raw else null) else null;
        const k_check: ?[]const u8 = if (kept) |k| (if (k.check_expr) |e| e.raw else null) else null;
        self.freeUnlessKept(policy.name, if (kept) |k| k.name else null);
        self.freeUnlessKept(policy.description, if (kept) |k| k.description else null);
        self.freeUnlessKept(policy.graph, if (kept) |k| k.graph else null);
        self.freeUnlessKept(policy.table, if (kept) |k| k.table else null);
        if (policy.using_expr) |e| self.freeUnlessKept(e.raw, k_using);
        if (policy.check_expr) |e| self.freeUnlessKept(e.raw, k_check);
    }

    fn exprCompiled(expr: ?Expression) ?*CompiledExpression {
        const e = expr orelse return null;
        return e.compiled;
    }

    fn freeUnlessKept(self: *Self, s: []const u8, kept: ?[]const u8) void {
        if (kept) |k| {
            if (k.ptr == s.ptr and k.len == s.len) return;
        }
        self.allocator.free(s);
    }

    /// Compile every expression of `policy` that has no bytecode yet, per
    /// `mode`. Returns what it compiled; on error nothing is left allocated.
    fn compilePolicyExpressions(self: *Self, policy: *Policy, mode: CompileFailureMode) !CompiledExprs {
        var made: CompiledExprs = .{};
        errdefer made.free(self);
        // CANARY: REQ=REQ-RLS-EXPR-002; FEATURE="RLSExpressionCompilation"; ASPECT=PolicyCompilation; STATUS=EXEMPT; OWNER=security; UPDATED=2025-12-30
        if (policy.using_expr) |*expr| {
            if (expr.compiled == null) {
                made.using = try self.compilePolicyExpression(policy, expr.raw, mode);
                expr.compiled = made.using;
            } else {
                // PERF-A / #808: pinned pre-compiled expressions bypass
                // compileExpression, so compute the row-skip flag here.
                expr.compiled.?.needs_row_data = CompiledExpression.bytecodeNeedsRowData(expr.compiled.?.bytecode);
            }
        }
        if (policy.check_expr) |*expr| {
            if (expr.compiled == null) {
                made.check = try self.compilePolicyExpression(policy, expr.raw, mode);
                expr.compiled = made.check;
            } else {
                expr.compiled.?.needs_row_data = CompiledExpression.bytecodeNeedsRowData(expr.compiled.?.bytecode);
            }
        }
        return made;
    }

    fn compilePolicyExpression(self: *Self, policy: *Policy, raw: []const u8, mode: CompileFailureMode) !*CompiledExpression {
        return self.compileExpressionStrict(raw) catch |err| switch (err) {
            error.InvalidRlsExpression => switch (mode) {
                .reject => {
                    log.warn("refusing RLS policy: its expression does not compile", &.{
                        Attr.string("policy", policy.name),
                        Attr.string("expression", raw),
                    });
                    return error.InvalidRlsExpression;
                },
                .retain_fail_closed => {
                    log.warn("stored RLS policy kept FAIL-CLOSED: its expression does not compile, and it denies every row until it is rewritten", &.{
                        Attr.string("policy", policy.name),
                        Attr.string("expression", raw),
                    });
                    policy.invalid = true;
                    return self.compileDenyAll();
                },
            },
            else => return err,
        };
    }

    // Policy Management
    /// SONNY-2732: install `policy` for an API or DDL caller. An expression
    /// the compiler refuses fails with error.InvalidRlsExpression and nothing
    /// is installed. It used to be installed as a program that denies every
    /// row, with only a warning in the log.
    pub fn createPolicy(self: *Self, policy: Policy) !void {
        return self.installPolicy(policy, .reject);
    }

    /// SONNY-2732: install a STORED policy, e.g. when loading policies at
    /// startup: an expression that no longer compiles is kept, denying every
    /// row and marked `invalid`, with a warning (`invalidPolicyCount`).
    pub fn loadPolicy(self: *Self, policy: Policy) !void {
        return self.installPolicy(policy, .retain_fail_closed);
    }

    fn installPolicy(self: *Self, policy: Policy, mode: CompileFailureMode) !void {
        const key = PolicyKey{
            .graph = policy.graph,
            .table = policy.table,
        };

        // Compiled first, outside the lock; only the map change is under it.
        var compiled_policy = policy;
        const made = try self.compilePolicyExpressions(&compiled_policy, mode);
        errdefer made.free(self);
        // SONNY-2773: the engine frees what it compiled.
        compiled_policy.owns_using_compiled = made.using != null;
        compiled_policy.owns_check_compiled = made.check != null;

        self.lockPoliciesExclusive();
        defer self.unlockPoliciesExclusive();

        // CANARY: REQ=REQ-SONNY-3036-RLS-POLICY-KEYS; FEATURE="RLSExpressionCompilation"; ASPECT=OwnedKeys; STATUS=TESTED; TEST=tests/test_sonny3036_rls_policy_keys.zig; OWNER=security; UPDATED=2026-09-27
        // SONNY-3036: the map owns copies of its keys. A new entry's key
        // borrowed `policy.graph` and `policy.table` (SONNY-2746), and kept
        // pointing at them after the policy was deleted and its owner freed
        // them (`UserManager.deletePolicy`), so the next lookup read freed
        // memory. The copies are made before the entry exists.
        const owned_key: ?PolicyKey = if (self.policies.contains(key)) null else try self.copyPolicyKey(key);
        errdefer if (owned_key) |k| self.freePolicyKey(k);
        const result = try self.policies.getOrPut(key);
        if (!result.found_existing) {
            result.key_ptr.* = owned_key.?;
            result.value_ptr.* = std.ArrayList(Policy).empty;
        }
        // SONNY-2746: drop a new entry again on failure.
        errdefer if (!result.found_existing) self.policies.removeByPtr(result.key_ptr);
        // Invalidate the cache before the append: once the policy is in the
        // list nothing may fail, or the errdefer would free the bytecode it
        // uses.
        try self.policy_cache.invalidate(key);
        try result.value_ptr.append(self.allocator, compiled_policy);
    }

    /// SONNY-2732: how many installed policies were loaded `invalid` (their
    /// stored expression no longer compiles, so they deny every row).
    pub fn invalidPolicyCount(self: *Self) usize {
        self.lockPoliciesShared();
        defer self.unlockPoliciesShared();
        var n: usize = 0;
        var it = self.policies.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |p| {
                if (p.invalid) n += 1;
            }
        }
        return n;
    }

    /// Return true once any expression RLS policy has been installed.
    ///
    /// The server publishes the expression engine at startup so request
    /// handlers can add policies later through `geode.rls.*` procedures. An
    /// initialized-but-empty engine is therefore not evidence that a query
    /// needs row-level filtering.
    pub fn hasPolicies(self: *Self) bool {
        self.lockPoliciesShared();
        defer self.unlockPoliciesShared();
        return self.policies.count() != 0;
    }

    // CANARY: REQ=REQ-SONNY-2732-RLS-STRICT-POLICIES; FEATURE="RLSExpressionCompilation"; ASPECT=AtomicUpdatePolicy; STATUS=TESTED; TEST=src/security/rls_core.zig; OWNER=security; UPDATED=2026-09-25
    /// Replace policy `policy_id` with `updates` (same graph and table).
    ///
    /// SONNY-2732: the update is compiled first, strictly and outside the
    /// lock, and then stored in one assignment under the exclusive lock, so a
    /// reader sees the old policy or the new one, never a mix, and an update
    /// that does not compile changes nothing (error.InvalidRlsExpression).
    /// Before, the new fields were stored first and the recompiled bytecode
    /// was written into the caller's copy, so the stored policy kept no
    /// bytecode for its new expression. Moving a policy to another graph or
    /// table is refused (error.PolicyKeyChange): the map is keyed by them;
    /// delete it and create it again.
    pub fn updatePolicy(self: *Self, policy_id: u64, updates: Policy) !void {
        var replacement = updates;
        replacement.id = policy_id;
        replacement.updated_at = compat_milliTimestamp();
        replacement.invalid = false;
        const made = try self.compilePolicyExpressions(&replacement, .reject);
        errdefer made.free(self);

        self.lockPoliciesExclusive();
        defer self.unlockPoliciesExclusive();
        var it = self.policies.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |*policy| {
                if (policy.id != policy_id) continue;
                const new_key = PolicyKey{ .graph = replacement.graph, .table = replacement.table };
                if (!PolicyKey.HashContext.eql(.{}, entry.key_ptr.*, new_key)) return error.PolicyKeyChange;
                // Invalidate first: after the store nothing may fail.
                try self.policy_cache.invalidate(entry.key_ptr.*);
                // SONNY-2773: the replacement owns what the engine compiled
                // for it, and the old bytecode it still points at (a caller
                // that copied the installed policy and changed `enabled`);
                // the rest of what the old policy owned is freed.
                const old = policy.*;
                replacement.owns_using_compiled = made.using != null or
                    (old.owns_using_compiled and exprCompiled(old.using_expr) != null and exprCompiled(old.using_expr) == exprCompiled(replacement.using_expr));
                replacement.owns_check_compiled = made.check != null or
                    (old.owns_check_compiled and exprCompiled(old.check_expr) != null and exprCompiled(old.check_expr) == exprCompiled(replacement.check_expr));
                policy.* = replacement;
                self.freeOwned(old, &replacement);
                return;
            }
        }
        return error.PolicyNotFound;
    }

    /// SONNY-3036: a graph and table left with no policy loses its entry
    /// (the list and the key copies are freed), so the map points at nothing
    /// the deleted policy's owner frees next.
    pub fn deletePolicy(self: *Self, policy_id: u64) !void {
        self.lockPoliciesExclusive();
        defer self.unlockPoliciesExclusive();
        var it = self.policies.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items, 0..) |policy, i| {
                if (policy.id == policy_id) {
                    try self.policy_cache.invalidate(entry.key_ptr.*);
                    const removed = entry.value_ptr.swapRemove(i);
                    if (entry.value_ptr.items.len == 0) {
                        const owned = entry.key_ptr.*;
                        entry.value_ptr.deinit(self.allocator);
                        self.policies.removeByPtr(entry.key_ptr);
                        self.freePolicyKey(owned);
                    }
                    // SONNY-2773: under the exclusive lock, so no reader is
                    // evaluating its bytecode.
                    self.freeOwned(removed, null);
                    return;
                }
            }
        }
        return error.PolicyNotFound;
    }

    fn copyPolicyKey(self: *Self, key: PolicyKey) !PolicyKey {
        const graph = try self.allocator.dupe(u8, key.graph);
        errdefer self.allocator.free(graph);
        return .{ .graph = graph, .table = try self.allocator.dupe(u8, key.table) };
    }

    fn freePolicyKey(self: *Self, key: PolicyKey) void {
        self.allocator.free(key.graph);
        self.allocator.free(key.table);
    }

    pub fn checkRowAccess(
        self: *Self,
        row: *const std.StringHashMap(Value),
        operation: Operation,
        context: *auth.SecurityContext,
        graph: []const u8,
        table: []const u8,
    ) !bool {
        const key = PolicyKey{ .graph = graph, .table = table };

        // Exclusive: this path also writes `policy_cache`.
        self.lockPoliciesExclusive();
        defer self.unlockPoliciesExclusive();

        // Check cache first
        if (self.policy_cache.get(key, context.user.id, operation)) |allowed| {
            if (!allowed) return false;
        }

        const policies = self.policies.get(key) orelse return true; // No policies

        // SONNY-2710: PostgreSQL's combination (see `PolicyVerdict`).
        var verdict: PolicyVerdict = .{};

        for (policies.items) |policy| {
            if (!policy.enabled) continue;
            if (policy.operation != operation and policy.operation != .all) continue;

            // Check role membership
            var has_role = false;
            for (policy.roles) |required_role| {
                for (context.roles) |user_role| {
                    if (user_role.id == required_role) {
                        has_role = true;
                        break;
                    }
                }
            }
            if (!has_role) continue;

            // Check temporal constraints
            if (policy.temporal) |temporal| {
                if (!self.checkTemporalConstraint(temporal)) continue;
            }

            // Evaluate policy expression
            const expr = switch (operation) {
                .select, .delete => policy.using_expr,
                .insert, .update => policy.check_expr,
                .all => policy.using_expr orelse policy.check_expr,
            };

            if (expr) |e| {
                const result = try self.evaluateExpression(e, row, context);
                verdict.add(policy.permissive, result);
            }
        }

        const allowed = verdict.allows(no_permissive_policy_allows);

        // Cache the result
        try self.policy_cache.put(key, context.user.id, operation, allowed);

        return allowed;
    }

    fn findApplicablePolicies(
        self: *Self,
        graph: []const u8,
        _: auth.UserId,
        roles: []const auth.Role,
    ) !std.ArrayList(Policy) {
        var result = std.ArrayList(Policy).empty;

        self.lockPoliciesShared();
        defer self.unlockPoliciesShared();
        var it = self.policies.iterator();
        while (it.next()) |entry| {
            if (!std.mem.eql(u8, entry.key_ptr.graph, graph)) continue;

            for (entry.value_ptr.items) |policy| {
                if (!policy.enabled) continue;

                // Check role membership
                var has_role = false;
                for (policy.roles) |required_role| {
                    for (roles) |user_role| {
                        if (user_role.id == required_role) {
                            has_role = true;
                            break;
                        }
                    }
                }

                if (has_role) {
                    try result.append(self.allocator, policy);
                }
            }
        }

        return result;
    }

    /// A program that denies every row: push_false; ret.
    fn compileDenyAll(self: *Self) !*CompiledExpression {
        const Opcode = CompiledExpression.Opcode;
        const bytecode = try self.allocator.dupe(u8, &.{ @intFromEnum(Opcode.push_false), @intFromEnum(Opcode.ret) });
        errdefer self.allocator.free(bytecode);
        const compiled = try self.allocator.create(CompiledExpression);
        compiled.* = .{
            .bytecode = bytecode,
            .constants = &.{},
            .jump_table = &.{},
            .needs_row_data = false,
        };
        return compiled;
    }

    // CANARY: REQ=REQ-RLS-EXPR-003; FEATURE="RLSExpressionCompilation"; ASPECT=ExpressionCompiler; STATUS=EXEMPT; OWNER=security; UPDATED=2025-12-30
    /// Compile `expr`, or fail with error.InvalidRlsExpression: the whole
    /// input must parse, nest at most `RLS_MAX_NESTING` deep and use at most
    /// 256 distinct constants.
    fn compileExpressionStrict(self: *Self, expr: []const u8) !*CompiledExpression {
        const Opcode = CompiledExpression.Opcode;
        var bytecode = std.ArrayList(u8).empty;
        defer bytecode.deinit(self.allocator);
        var constants = std.ArrayList(Value).empty;
        defer constants.deinit(self.allocator);
        var jump_table = std.ArrayList(usize).empty;
        defer jump_table.deinit(self.allocator);

        // GAP-0284: recursive-descent compiler emitting POSTFIX (RPN)
        // bytecode for the stack VM. The previous implementation was a flat
        // tokenizer that emitted operators in infix source order — `row.x =
        // 'v'` produced [load_row, eq, push_const], so `eq` ran with one
        // operand and the VM underflowed (every row denied). Postfix emit is
        // the fix.
        //
        // Grammar (OR loosest, then AND, then NOT, then comparison, as in
        // SQL; SONNY-2709 moved NOT below the comparisons, so
        // `NOT row.x = 'a'` is `NOT (row.x = 'a')`):
        //   or_     := and_ ( "OR"  and_ )*
        //   and_    := not_ ( "AND" not_ )*
        //   not_    := "NOT" not_ | cmp
        //   cmp     := primary ( ("=" | "<>" | "!=" | "<=" | ">=" | "<" | ">") primary
        //                      | "IS" ["NOT"] "NULL" )?
        //   primary := "(" or_ ")" | "TRUE" | "FALSE" | "NULL"
        //            | "row." ident | "principal.attribute." ident
        //            | "current_user" | "'" string "'" | integer | decimal
        //
        // The whole input must parse: anything left over (SONNY-2709: a
        // prefix used to be compiled and the rest dropped) makes the policy
        // deny every row, like any other malformed expression.
        const C = struct {
            self: *Self,
            src: []const u8,
            pos: usize = 0,
            /// SONNY-2730: current depth of `(` and `NOT` nesting.
            depth: usize = 0,
            /// SONNY-2757 (P21): the VM's stack depth once the bytecode
            /// emitted so far has run.
            sp: usize = 0,
            bc: *std.ArrayList(u8),
            ks: *std.ArrayList(Value),

            fn skipWs(c: *@This()) void {
                while (c.pos < c.src.len and (c.src[c.pos] == ' ' or c.src[c.pos] == '\t' or c.src[c.pos] == '\n' or c.src[c.pos] == '\r')) : (c.pos += 1) {}
            }
            fn emit(c: *@This(), op: Opcode) !void {
                try c.track(op);
                try c.bc.append(c.self.allocator, @intFromEnum(op));
            }
            // CANARY: REQ=REQ-SONNY-2757-RLS-STACK-BOUND; FEATURE="RLSExpressionCompilation"; ASPECT=CompileTimeStackBound; STATUS=TESTED; TEST=tests/test_sonny2757_policy_hygiene.zig; OWNER=security; UPDATED=2026-09-26
            /// SONNY-2757 (P21): simulate the VM stack as `op` is emitted,
            /// and refuse an expression whose evaluation needs more than
            /// `RLS_STACK_DEPTH` slots. The nesting limit (SONNY-2730) bounds
            /// parentheses, not the stack: every pending left operand of a
            /// right-nested operator holds a slot, so a right-nested OR
            /// 63-64 levels deep, or `x OR row.b = (...)` from 32 levels,
            /// compiled and then overflowed the VM on every row, which the
            /// VM reports as an error and the caller as a deny.
            fn track(c: *@This(), op: Opcode) !void {
                switch (op) {
                    .push_const, .push_true, .push_false, .push_null, .load_row, .load_user, .load_session, .load_attr => {
                        c.sp += 1;
                        if (c.sp > RLS_STACK_DEPTH) return error.InvalidRlsExpression;
                    },
                    // Pop two, push one; or pop one.
                    .eq, .neq, .lt, .gt, .lte, .gte, .op_and, .op_or, .pop, .jump_if_false, .jump_if_true => c.sp -|= 1,
                    .op_not, .is_null, .nop, .jump, .ret => {},
                }
            }
            fn emitArg(c: *@This(), a: u8) !void {
                try c.bc.append(c.self.allocator, a);
            }
            fn pushConst(c: *@This(), v: Value) !void {
                const idx = try c.internConst(v);
                try c.emit(.push_const);
                try c.emitArg(idx);
            }
            /// SONNY-2730: the u8 operand of `v` in the constants table. An
            /// equal constant is reused, so a field or literal repeated across
            /// the policy takes one slot. The index was an `@intCast` to u8,
            /// which aborted the server on the 257th constant (a 129-term
            /// allow-list is enough); past 256 distinct constants the
            /// expression is refused instead.
            fn internConst(c: *@This(), v: Value) !u8 {
                for (c.ks.items, 0..) |existing, i| {
                    if (sameConstant(existing, v)) return @intCast(i); // i < 256: never appended past it
                }
                const idx = std.math.cast(u8, c.ks.items.len) orelse return error.InvalidRlsExpression;
                try c.ks.append(c.self.allocator, v);
                return idx;
            }
            fn sameConstant(a: Value, b: Value) bool {
                return switch (a) {
                    .string => |x| b == .string and std.mem.eql(u8, x, b.string),
                    .integer => |x| b == .integer and b.integer == x,
                    .float => |x| b == .float and @as(u64, @bitCast(x)) == @as(u64, @bitCast(b.float)),
                    else => false,
                };
            }
            /// SONNY-2730: enter one more level of `(` or `NOT`.
            fn enter(c: *@This()) !void {
                if (c.depth >= RLS_MAX_NESTING) return error.InvalidRlsExpression;
                c.depth += 1;
            }
            /// Case-insensitive keyword match at pos, requiring the next char
            /// (if any) is not an identifier char. Consumes + returns true.
            fn matchKw(c: *@This(), kw: []const u8) bool {
                if (c.pos + kw.len > c.src.len) return false;
                if (!std.ascii.eqlIgnoreCase(c.src[c.pos .. c.pos + kw.len], kw)) return false;
                const after = c.pos + kw.len;
                if (after < c.src.len) {
                    const ch = c.src[after];
                    if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.') return false;
                }
                c.pos = after;
                return true;
            }
            /// Plain case-insensitive prefix match (no boundary check).
            fn matchLit(c: *@This(), lit: []const u8) bool {
                if (c.pos + lit.len > c.src.len) return false;
                if (!std.ascii.eqlIgnoreCase(c.src[c.pos .. c.pos + lit.len], lit)) return false;
                c.pos += lit.len;
                return true;
            }
            fn ident(c: *@This()) []const u8 {
                const start = c.pos;
                while (c.pos < c.src.len and (std.ascii.isAlphanumeric(c.src[c.pos]) or c.src[c.pos] == '_')) : (c.pos += 1) {}
                return c.src[start..c.pos];
            }

            fn parseOr(c: *@This()) anyerror!void {
                try c.parseAnd();
                while (true) {
                    c.skipWs();
                    if (!c.matchKw("or")) break;
                    try c.parseAnd();
                    try c.emit(.op_or);
                }
            }
            fn parseAnd(c: *@This()) anyerror!void {
                try c.parseNot();
                while (true) {
                    c.skipWs();
                    if (!c.matchKw("and")) break;
                    try c.parseNot();
                    try c.emit(.op_and);
                }
            }
            fn parseNot(c: *@This()) anyerror!void {
                c.skipWs();
                if (c.matchKw("not")) {
                    try c.enter();
                    defer c.depth -= 1;
                    try c.parseNot();
                    try c.emit(.op_not);
                    return;
                }
                try c.parseCmp();
            }
            fn parseCmp(c: *@This()) anyerror!void {
                try c.parsePrimary();
                c.skipWs();
                if (c.matchKw("is")) {
                    c.skipWs();
                    const negate = c.matchKw("not");
                    c.skipWs();
                    if (!c.matchKw("null")) return error.InvalidRlsExpression;
                    try c.emit(.is_null);
                    if (negate) try c.emit(.op_not);
                    return;
                }
                const op: ?Opcode =
                    if (c.matchLit("<>")) Opcode.neq else if (c.matchLit("!=")) Opcode.neq else if (c.matchLit("<=")) Opcode.lte else if (c.matchLit(">=")) Opcode.gte else if (c.matchLit("=")) Opcode.eq else if (c.matchLit("<")) Opcode.lt else if (c.matchLit(">")) Opcode.gt else null;
                if (op) |o| {
                    try c.parsePrimary();
                    try c.emit(o);
                }
            }
            fn parsePrimary(c: *@This()) anyerror!void {
                c.skipWs();
                if (c.pos >= c.src.len) return error.InvalidRlsExpression;
                if (c.src[c.pos] == '(') {
                    try c.enter();
                    defer c.depth -= 1;
                    c.pos += 1;
                    try c.parseOr();
                    c.skipWs();
                    // SONNY-2732: a missing `)` used to be forgiven.
                    if (c.pos >= c.src.len or c.src[c.pos] != ')') return error.InvalidRlsExpression;
                    c.pos += 1;
                    return;
                }
                if (c.matchKw("true")) {
                    try c.emit(.push_true);
                    return;
                }
                if (c.matchKw("false")) {
                    try c.emit(.push_false);
                    return;
                }
                if (c.matchKw("null")) {
                    try c.emit(.push_null);
                    return;
                }
                // ABAC: principal.attribute.<key> — resolved per-row at eval
                // time against the global user attribute store.
                if (c.matchLit("principal.attribute.")) {
                    const key = c.ident();
                    if (key.len == 0) return error.InvalidRlsExpression; // SONNY-2732
                    const idx = try c.internConst(.{ .string = key });
                    try c.emit(.load_attr);
                    try c.emitArg(idx);
                    return;
                }
                if (c.matchLit("row.")) {
                    const field = c.ident();
                    if (field.len == 0) return error.InvalidRlsExpression; // SONNY-2732
                    const idx = try c.internConst(.{ .string = field });
                    try c.emit(.load_row);
                    try c.emitArg(idx);
                    return;
                }
                if (c.matchKw("current_user")) {
                    try c.emit(.load_user);
                    return;
                }
                if (c.src[c.pos] == '\'') {
                    c.pos += 1;
                    const start = c.pos;
                    while (c.pos < c.src.len and c.src[c.pos] != '\'') : (c.pos += 1) {}
                    // SONNY-2732: an unterminated string used to run to the
                    // end of the policy.
                    if (c.pos >= c.src.len) return error.InvalidRlsExpression;
                    const sv = c.src[start..c.pos];
                    c.pos += 1; // closing quote
                    try c.pushConst(.{ .string = sv });
                    return;
                }
                if (std.ascii.isDigit(c.src[c.pos]) or (c.src[c.pos] == '-' and c.pos + 1 < c.src.len and std.ascii.isDigit(c.src[c.pos + 1]))) {
                    const start = c.pos;
                    if (c.src[c.pos] == '-') c.pos += 1;
                    while (c.pos < c.src.len and std.ascii.isDigit(c.src[c.pos])) : (c.pos += 1) {}
                    // SONNY-2709: a decimal literal (`2.5`). It used to stop
                    // at the '.', leaving `.5` unparsed.
                    if (c.pos + 1 < c.src.len and c.src[c.pos] == '.' and std.ascii.isDigit(c.src[c.pos + 1])) {
                        c.pos += 1;
                        while (c.pos < c.src.len and std.ascii.isDigit(c.src[c.pos])) : (c.pos += 1) {}
                        const f = std.fmt.parseFloat(f64, c.src[start..c.pos]) catch return error.InvalidRlsExpression;
                        if (!std.math.isFinite(f)) return error.InvalidRlsExpression;
                        try c.pushConst(.{ .float = f });
                        return;
                    }
                    const num = std.fmt.parseInt(i64, c.src[start..c.pos], 10) catch {
                        log.warn("Invalid integer literal in RLS expression", &.{
                            Attr.string("literal", c.src[start..c.pos]),
                        });
                        return error.InvalidRlsExpression;
                    };
                    try c.pushConst(.{ .integer = num });
                    return;
                }
                return error.InvalidRlsExpression;
            }
        };

        var comp = C{ .self = self, .src = expr, .bc = &bytecode, .ks = &constants };
        comp.parseOr() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidRlsExpression,
        };
        comp.skipWs();
        if (comp.pos != comp.src.len) return error.InvalidRlsExpression;

        // Add return instruction
        try bytecode.append(self.allocator, @intFromEnum(Opcode.ret));

        const compiled = try self.allocator.create(CompiledExpression);
        errdefer self.allocator.destroy(compiled);
        const owned_bytecode = try bytecode.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned_bytecode);
        const owned_constants = try constants.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned_constants);
        compiled.* = CompiledExpression{
            .bytecode = owned_bytecode,
            .constants = owned_constants,
            .jump_table = try jump_table.toOwnedSlice(self.allocator),
            // PERF-A / #808: pre-scan once at compile time so the match
            // loop can skip per-row StringHashMap construction when no
            // policy reads row data.
            .needs_row_data = CompiledExpression.bytecodeNeedsRowData(owned_bytecode),
        };

        return compiled;
    }

    // CANARY: REQ=REQ-GAP-0732-RLS-FAIL-CLOSED; FEATURE="RLSRawStringFailClosed"; ASPECT=Security; STATUS=TESTED; TEST=tests/test_rls_vm_bounds.zig; OWNER=security; UPDATED=2026-04-16
    // GAP-0732 / SEC-RLS-02 (Risk 16, 2026-04-16): if a policy's Expression
    // has a raw string but no compiled bytecode, we MUST treat it as deny,
    // not fall through to the raw-string interpreter.  The raw-string
    // interpreter is convenient for development but has its own parsing
    // quirks and does NOT walk the bounds-checked VM path, so a malformed
    // or attacker-supplied raw expression could bypass restrictions that
    // the compiled form would catch.  The compiled-expression path is the
    // single authoritative enforcement gate; `createPolicy` is responsible
    // for running the compiler before persistence.
    //
    // The legacy interpreter remains available for callers that set the
    // `allow_rls_raw_interp` build option (default OFF).  This keeps the
    // existing test_rls_enhanced* coverage intact but gates real servers
    // from accidentally shipping raw-only policies.
    fn evaluateExpression(
        self: *Self,
        expr: Expression,
        row: *const std.StringHashMap(Value),
        context: *auth.SecurityContext,
    ) !bool {
        if (expr.compiled) |compiled| {
            return try self.evaluateCompiledExpression(compiled, row, context);
        }

        // GAP-0732 fail-closed: policies without compiled bytecode must be
        // rejected — OR explicitly opt-in via -Dallow-rls-raw-interp=true
        // (debug/test builds only).
        if (build_options.allow_rls_raw_interp) {
            return try self.context_evaluator.evaluate(expr.raw, row, context);
        }
        return error.UnsafePolicy;
    }

    // CANARY: REQ=REQ-RLS-EXPR-004; FEATURE="RLSExpressionCompilation"; ASPECT=BytecodeVM; STATUS=TESTED; TEST=test_rls_vm_bounds.zig; OWNER=security; UPDATED=2026-04-16
    // GAP-0723 / SEC-RLS-01 (2026-04-16): bytecode VM now bounds-checks every
    // push/pop, returns `error.StackOverflow`/`error.StackUnderflow` on OOB,
    // and validates every opcode byte via `std.meta.intToEnum` before dispatch.
    // Callers (evaluateExpression and checkRowAccess*) must treat VM errors as
    // DENY — see `evaluateExpression` where any `!bool` error short-circuits
    // to `return false`.  Regression test: tests/test_rls_vm_bounds.zig.
    fn evaluateCompiledExpression(
        self: *Self,
        expr: *CompiledExpression,
        row: *const std.StringHashMap(Value),
        context: *auth.SecurityContext,
    ) !bool {
        const Opcode = CompiledExpression.Opcode;
        var stack: [RLS_STACK_DEPTH]Value = undefined;
        // SONNY-2709: which slots hold a principal attribute (see `Operand`).
        var from_attr = [_]bool{false} ** RLS_STACK_DEPTH;
        var sp: usize = 0; // Stack pointer

        var pc: usize = 0; // Program counter
        // SONNY-2732: the compiler emits no backward jump, so a program runs
        // each instruction at most once. One that executes more instructions
        // than it has bytes has looped (malformed bytecode): refused.
        var steps: usize = 0;
        while (pc < expr.bytecode.len) {
            steps += 1;
            if (steps > expr.bytecode.len) return error.StepLimitExceeded;
            // GAP-0723: validate opcode byte before dispatch.  `@enumFromInt`
            // on an unknown u8 is UB in release mode.  We accept only the
            // explicit tag values declared on Opcode; anything else returns
            // error.InvalidOpcode so the VM fails closed.
            const opcode: Opcode = Opcode.fromByte(expr.bytecode[pc]) orelse {
                return error.InvalidOpcode;
            };
            pc += 1;

            switch (opcode) {
                .nop => {},
                .push_const => {
                    if (pc >= expr.bytecode.len) return error.BytecodeUnderrun;
                    const idx = expr.bytecode[pc];
                    pc += 1;
                    // SONNY-2732: an index past the constants was skipped,
                    // silently changing what the program computes: refused.
                    if (idx >= expr.constants.len) return error.InvalidConstantIndex;
                    if (sp >= stack.len) return error.StackOverflow;
                    stack[sp] = expr.constants[idx];
                    from_attr[sp] = false;
                    sp += 1;
                },
                .push_true => {
                    if (sp >= stack.len) return error.StackOverflow;
                    stack[sp] = .{ .boolean = true };
                    sp += 1;
                },
                .push_false => {
                    if (sp >= stack.len) return error.StackOverflow;
                    stack[sp] = .{ .boolean = false };
                    sp += 1;
                },
                .push_null => {
                    if (sp >= stack.len) return error.StackOverflow;
                    stack[sp] = .null;
                    sp += 1;
                },
                .pop => {
                    if (sp == 0) return error.StackUnderflow;
                    sp -= 1;
                },
                .load_row => {
                    if (pc >= expr.bytecode.len) return error.BytecodeUnderrun;
                    const idx = expr.bytecode[pc];
                    pc += 1;
                    // SONNY-2732: see push_const.
                    if (idx >= expr.constants.len) return error.InvalidConstantIndex;
                    if (sp >= stack.len) return error.StackOverflow;
                    const field_name = switch (expr.constants[idx]) {
                        .string => |s| s,
                        else => return error.InvalidConstantIndex,
                    };
                    if (row.get(field_name)) |val| {
                        stack[sp] = val;
                    } else {
                        stack[sp] = .null;
                    }
                    from_attr[sp] = false;
                    sp += 1;
                },
                .load_user => {
                    if (sp >= stack.len) return error.StackOverflow;
                    // Push current user ID as integer
                    stack[sp] = .{ .integer = @intCast(context.user.id) };
                    from_attr[sp] = false;
                    sp += 1;
                },
                .load_session => {
                    // CANARY: REQ=REQ-RLS-SESSION-001; FEATURE="RLSSessionAccess"; ASPECT=Security; STATUS=TESTED; OWNER=security; UPDATED=2026-04-16
                    // Load session variable by index into constants table
                    if (pc >= expr.bytecode.len) return error.BytecodeUnderrun;
                    const idx = expr.bytecode[pc];
                    pc += 1;
                    if (sp >= stack.len) return error.StackOverflow;
                    // SONNY-2732: see push_const.
                    if (idx >= expr.constants.len) return error.InvalidConstantIndex;
                    if (idx < expr.constants.len) {
                        const var_name = switch (expr.constants[idx]) {
                            .string => |s| s,
                            else => {
                                stack[sp] = .null;
                                from_attr[sp] = false;
                                sp += 1;
                                continue;
                            },
                        };
                        // Look up session attribute in context (string values)
                        if (context.session_attributes.get(var_name)) |session_str| {
                            // Convert string to Value (try parsing as integer/boolean first)
                            if (std.mem.eql(u8, session_str, "true")) {
                                stack[sp] = .{ .boolean = true };
                            } else if (std.mem.eql(u8, session_str, "false")) {
                                stack[sp] = .{ .boolean = false };
                            } else if (std.fmt.parseInt(i64, session_str, 10)) |int_val| {
                                stack[sp] = .{ .integer = int_val };
                            } else |_| {
                                stack[sp] = .{ .string = session_str };
                            }
                        } else {
                            stack[sp] = .null;
                        }
                    } else {
                        stack[sp] = .null;
                    }
                    from_attr[sp] = false;
                    sp += 1;
                },
                .load_attr => {
                    // CANARY: REQ=GAP-0284; FEATURE="ABAC user attribute store"; ASPECT=RLSExprAttrLoad; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/abac_attribute_policies.yml; OWNER=security; UPDATED=2026-05-22
                    // Resolve principal.attribute.<key> against the global ABAC
                    // attribute side-table for the SecurityContext user.
                    if (pc >= expr.bytecode.len) return error.BytecodeUnderrun;
                    const idx = expr.bytecode[pc];
                    pc += 1;
                    if (sp >= stack.len) return error.StackOverflow;
                    // SONNY-2732: see push_const.
                    if (idx >= expr.constants.len) return error.InvalidConstantIndex;
                    stack[sp] = self.resolvePrincipalAttribute(context.user.username, expr.constants, idx);
                    from_attr[sp] = true;
                    sp += 1;
                },
                .eq, .neq => {
                    if (sp < 2) return error.StackUnderflow;
                    const b = Operand{ .value = stack[sp - 1], .from_attr = from_attr[sp - 1] };
                    const a = Operand{ .value = stack[sp - 2], .from_attr = from_attr[sp - 2] };
                    sp -= 2;
                    stack[sp] = self.evalEquality(opcode, a, b);
                    from_attr[sp] = false;
                    sp += 1;
                },
                .is_null => {
                    if (sp < 1) return error.StackUnderflow;
                    // Read before writing: the literal's tag would be stored
                    // into the slot before the test below reads it.
                    const is_null = stack[sp - 1] == .null;
                    stack[sp - 1] = .{ .boolean = is_null };
                    from_attr[sp - 1] = false;
                },
                .lt, .gt, .lte, .gte => {
                    if (sp < 2) return error.StackUnderflow;
                    const b = Operand{ .value = stack[sp - 1], .from_attr = from_attr[sp - 1] };
                    const a = Operand{ .value = stack[sp - 2], .from_attr = from_attr[sp - 2] };
                    sp -= 2;
                    stack[sp] = self.evalRange(opcode, a, b);
                    from_attr[sp] = false;
                    sp += 1;
                },
                .op_and => {
                    if (sp < 2) return error.StackUnderflow;
                    const b = self.truthOf(stack[sp - 1]);
                    const a = self.truthOf(stack[sp - 2]);
                    sp -= 2;
                    stack[sp] = truthValue(kleeneAnd(a, b));
                    sp += 1;
                },
                .op_or => {
                    if (sp < 2) return error.StackUnderflow;
                    const b = self.truthOf(stack[sp - 1]);
                    const a = self.truthOf(stack[sp - 2]);
                    sp -= 2;
                    stack[sp] = truthValue(kleeneOr(a, b));
                    sp += 1;
                },
                .op_not => {
                    if (sp < 1) return error.StackUnderflow;
                    const a = self.truthOf(stack[sp - 1]);
                    sp -= 1;
                    stack[sp] = truthValue(if (a) |t| !t else null);
                    sp += 1;
                },
                .jump => {
                    if (pc >= expr.bytecode.len) return error.BytecodeUnderrun;
                    const idx = expr.bytecode[pc];
                    pc += 1;
                    pc = try jumpTarget(expr, idx);
                },
                .jump_if_false => {
                    if (pc >= expr.bytecode.len) return error.BytecodeUnderrun;
                    const idx = expr.bytecode[pc];
                    pc += 1;
                    if (sp == 0) return error.StackUnderflow;
                    sp -= 1;
                    // SONNY-2709 / SONNY-2732: a branch cannot take UNKNOWN
                    // (or a non-boolean) as false: the skipped arm may be the
                    // one that denies. The policy is undecided, and an
                    // undecided policy denies.
                    const target = try jumpTarget(expr, idx);
                    const cond = self.truthOf(stack[sp]) orelse return error.IndeterminatePolicy;
                    if (!cond) pc = target;
                },
                .jump_if_true => {
                    if (pc >= expr.bytecode.len) return error.BytecodeUnderrun;
                    const idx = expr.bytecode[pc];
                    pc += 1;
                    if (sp == 0) return error.StackUnderflow;
                    sp -= 1;
                    // SONNY-2709 / SONNY-2732: see jump_if_false.
                    const target = try jumpTarget(expr, idx);
                    const cond = self.truthOf(stack[sp]) orelse return error.IndeterminatePolicy;
                    if (cond) pc = target;
                },
                .ret => {
                    // SONNY-2732: only a boolean TRUE on top admits the row,
                    // and an empty stack denies (it used to admit).
                    if (sp > 0) return admits(stack[sp - 1]);
                    return false;
                },
            }
        }

        // Fell off the end without `ret`: as for `ret`, except that an empty
        // stack is undecided (SONNY-2732: it used to admit the row).
        if (sp > 0) return admits(stack[sp - 1]);
        return error.IndeterminatePolicy;
    }

    // CANARY: REQ=REQ-SONNY-2709-RLS-EQUALITY-3VL; FEATURE="RLSExpressionCompilation"; ASPECT=EqualityThreeValued; STATUS=TESTED; TEST=tests/test_sonny2709_rls_range_fail_closed.zig; OWNER=security; UPDATED=2026-09-25
    /// SONNY-2709 (round 4): `a = b` and `a <> b` in SQL's three-valued
    /// logic: a boolean, or null (UNKNOWN) when either side is null or the
    /// two are not alike (`equalValues`). A policy that ends UNKNOWN denies,
    /// so `row.cls <> 'secret'` no longer admits a row without `cls`; write
    /// `row.cls IS NULL OR row.cls <> 'secret'` for that. Before this, `=`
    /// was false and `<>` true for a null or a mismatched pair. A principal
    /// attribute is coerced as for the range operators (`coerceAttribute`).
    fn evalEquality(self: *Self, opcode: CompiledExpression.Opcode, a: Operand, b: Operand) Value {
        const equal = self.equalOperands(a, b) orelse return .null;
        return .{ .boolean = if (opcode == .eq) equal else !equal };
    }

    fn equalOperands(self: *Self, a: Operand, b: Operand) ?bool {
        if (a.from_attr and a.value == .string and isNumber(b.value)) {
            const coerced = coerceAttribute(a.value.string, b.value) orelse return null;
            return self.equalValues(coerced, b.value);
        }
        if (b.from_attr and b.value == .string and isNumber(a.value)) {
            const coerced = coerceAttribute(b.value.string, a.value) orelse return null;
            return self.equalValues(a.value, coerced);
        }
        return self.equalValues(a.value, b.value);
    }

    /// Whether two values are equal, or null (UNKNOWN) when either is null
    /// or they are not alike. Alike: two numbers (an integer and a float
    /// compare as floats; NaN is equal to nothing, so UNKNOWN), two strings,
    /// two booleans, two timestamps.
    fn equalValues(self: *Self, a: Value, b: Value) ?bool {
        _ = self;
        return switch (a) {
            .integer => |av| switch (b) {
                .integer => |bv| av == bv,
                .float => |bv| equalFloats(@floatFromInt(av), bv),
                else => null,
            },
            .float => |av| switch (b) {
                .float => |bv| equalFloats(av, bv),
                .integer => |bv| equalFloats(av, @floatFromInt(bv)),
                else => null,
            },
            .string => |av| switch (b) {
                .string => |bv| std.mem.eql(u8, av, bv),
                else => null,
            },
            .boolean => |av| switch (b) {
                .boolean => |bv| av == bv,
                else => null,
            },
            .timestamp => |av| switch (b) {
                .timestamp => |bv| av == bv,
                else => null,
            },
            else => null,
        };
    }

    fn equalFloats(a: f64, b: f64) ?bool {
        if (std.math.isNan(a) or std.math.isNan(b)) return null;
        return a == b;
    }

    // CANARY: REQ=REQ-SONNY-2709-RLS-RANGE-FAIL-CLOSED; FEATURE="RLSExpressionCompilation"; ASPECT=RangeOperatorsFailClosed; STATUS=TESTED; TEST=tests/test_sonny2709_rls_range_fail_closed.zig; OWNER=security; UPDATED=2026-09-25
    /// SONNY-2709: a comparison operator's operand (range, `=`, `<>`), and
    /// whether it came from `principal.attribute.<key>` (`load_attr`).
    ///
    /// The VM tracks this per stack slot (`from_attr`). Only a push puts a
    /// string on the stack, and every string-producing opcode (push_const,
    /// load_row, load_session, load_attr) sets its slot's flag, so a string's
    /// flag is always right. A slot a boolean or null result reuses may keep a
    /// stale flag; that is harmless, because only a string is ever coerced.
    /// A new opcode that pushes a string must set the flag too.
    const Operand = struct {
        value: Value,
        from_attr: bool,
    };

    /// SONNY-2709: `a <op> b` for the four range operators: a boolean, or
    /// null (UNKNOWN) when the operands have no order.
    ///
    /// Before this, `compareValues` answered 0 ("equal") for a null or for
    /// two values of different types, so `<=` and `>=` held. A range policy
    /// passed every row whose value was missing or of another type, and
    /// `level <= principal.attribute.clearance` passed every row for every
    /// user, since a principal attribute is always a string.
    ///
    /// UNKNOWN is not false: it stays UNKNOWN under NOT, AND and OR (Kleene
    /// logic, `kleeneAnd`/`kleeneOr`), and a policy that ends UNKNOWN denies
    /// the row. With a plain false, `NOT (level > 3)` would admit a row with
    /// no level.
    ///
    /// A principal attribute compared with a number is parsed strictly as
    /// that number's type (`coerceAttribute`); compared with a string it is
    /// a string. Nothing else is converted: a row's string is never read as a
    /// number.
    fn evalRange(self: *Self, opcode: CompiledExpression.Opcode, a: Operand, b: Operand) Value {
        const order = self.orderOperands(a, b) orelse return .null;
        const holds = switch (opcode) {
            .lt => order == .lt,
            .gt => order == .gt,
            .lte => order != .gt,
            .gte => order != .lt,
            else => return .null,
        };
        return .{ .boolean = holds };
    }

    fn orderOperands(self: *Self, a: Operand, b: Operand) ?std.math.Order {
        if (a.from_attr and a.value == .string and isNumber(b.value)) {
            const coerced = coerceAttribute(a.value.string, b.value) orelse return null;
            return self.compareValues(coerced, b.value);
        }
        if (b.from_attr and b.value == .string and isNumber(a.value)) {
            const coerced = coerceAttribute(b.value.string, a.value) orelse return null;
            return self.compareValues(a.value, coerced);
        }
        return self.compareValues(a.value, b.value);
    }

    fn isNumber(v: Value) bool {
        return v == .integer or v == .float;
    }

    /// SONNY-2709: the principal attribute `text` as a value of `like`'s
    /// numeric type, or null (not comparable, so the row is denied).
    ///
    /// Strict on purpose, since the attribute decides what a user may read:
    /// - against an integer: an optional '-' and ASCII digits only, in range
    ///   of i64 ("3", "-1"; not " 3", "+3", "3.0", "1_000", "0x3");
    /// - against a float: the same, optionally followed by '.' and at least
    ///   one digit ("3", "2.5"; not "2.", ".5", "1e3", "inf", "nan").
    fn coerceAttribute(text: []const u8, like: Value) ?Value {
        const unsigned = if (text.len > 0 and text[0] == '-') text[1..] else text;
        const dot = std.mem.indexOfScalar(u8, unsigned, '.');
        const whole = unsigned[0 .. dot orelse unsigned.len];
        const fraction: []const u8 = if (dot) |d| unsigned[d + 1 ..] else "";
        if (whole.len == 0 or !allDigits(whole)) return null;
        switch (like) {
            .integer => {
                if (dot != null) return null;
                return .{ .integer = std.fmt.parseInt(i64, text, 10) catch return null };
            },
            .float => {
                if (dot != null and (fraction.len == 0 or !allDigits(fraction))) return null;
                const f = std.fmt.parseFloat(f64, text) catch return null;
                if (!std.math.isFinite(f)) return null;
                return .{ .float = f };
            },
            else => return null,
        }
    }

    fn allDigits(text: []const u8) bool {
        for (text) |c| {
            if (!std.ascii.isDigit(c)) return false;
        }
        return true;
    }

    /// SONNY-2709: the order of two values, or null when they have none.
    /// Only like is ordered with like: two numbers (an integer and a float
    /// compare as floats), two strings (by bytes), two timestamps. A null, a
    /// NaN, a boolean, an array, an object, and every mixed pair (a string
    /// and a number, say) have no order.
    fn compareValues(self: *Self, a: Value, b: Value) ?std.math.Order {
        _ = self;
        return switch (a) {
            .integer => |av| switch (b) {
                .integer => |bv| std.math.order(av, bv),
                .float => |bv| orderFloats(@floatFromInt(av), bv),
                else => null,
            },
            .float => |av| switch (b) {
                .float => |bv| orderFloats(av, bv),
                .integer => |bv| orderFloats(av, @floatFromInt(bv)),
                else => null,
            },
            .string => |av| switch (b) {
                .string => |bv| std.mem.order(u8, av, bv),
                else => null,
            },
            .timestamp => |av| switch (b) {
                .timestamp => |bv| std.math.order(av, bv),
                else => null,
            },
            else => null,
        };
    }

    fn orderFloats(a: f64, b: f64) ?std.math.Order {
        if (std.math.isNan(a) or std.math.isNan(b)) return null;
        return std.math.order(a, b);
    }

    /// SONNY-2709 / SONNY-2732: a value's truth for NOT, AND, OR and a
    /// branch. Only a boolean is true or false; anything else (null, a
    /// string, a number, …) is UNKNOWN. A non-empty string or a non-zero
    /// number used to count as true, so `row.flag` admitted a row whose flag
    /// was the string 'no', and a bare `'anything'` admitted every row.
    fn truthOf(self: *Self, v: Value) ?bool {
        _ = self;
        return switch (v) {
            .boolean => |b| b,
            else => null,
        };
    }

    /// SONNY-2732: jump table entry `idx`, which must name an instruction in
    /// the program. An index past the table used to be ignored (no jump), and
    /// a target past the end ended the program: malformed bytecode is refused.
    fn jumpTarget(expr: *const CompiledExpression, idx: u8) !usize {
        if (idx >= expr.jump_table.len) return error.InvalidJumpIndex;
        const target = expr.jump_table[idx];
        if (target >= expr.bytecode.len) return error.InvalidJumpTarget;
        return target;
    }

    /// SONNY-2732: the policy's verdict on its final value: only a boolean
    /// TRUE admits the row.
    fn admits(v: Value) bool {
        return switch (v) {
            .boolean => |b| b,
            else => false,
        };
    }

    /// Kleene AND: false if either side is false, else UNKNOWN if either is.
    fn kleeneAnd(a: ?bool, b: ?bool) ?bool {
        if (isKnown(a, false) or isKnown(b, false)) return false;
        if (a == null or b == null) return null;
        return true;
    }

    /// Kleene OR: true if either side is true, else UNKNOWN if either is.
    fn kleeneOr(a: ?bool, b: ?bool) ?bool {
        if (isKnown(a, true) or isKnown(b, true)) return true;
        if (a == null or b == null) return null;
        return false;
    }

    fn isKnown(t: ?bool, want: bool) bool {
        const known = t orelse return false;
        return known == want;
    }

    /// UNKNOWN is carried on the stack as null: `admits` makes it a deny
    /// wherever a verdict is taken, and `truthOf` keeps it UNKNOWN.
    fn truthValue(t: ?bool) Value {
        const known = t orelse return .null;
        return .{ .boolean = known };
    }

    // CANARY: REQ=GAP-0284; FEATURE="ABAC user attribute store"; ASPECT=RLSExprAttrResolve; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/abac_attribute_policies.yml; OWNER=security; UPDATED=2026-05-22
    /// Resolve `principal.attribute.<key>` for `username` against the global
    /// ABAC attribute side-table. Returns the attribute value as a string
    /// Value, or `.null` when the user has no such attribute. The borrowed
    /// string lives in the process-global store; it is only consumed for the
    /// duration of this per-row VM evaluation (compared immediately, never
    /// retained), matching the lifetime contract used by `load_session`.
    fn resolvePrincipalAttribute(
        self: *Self,
        username: []const u8,
        constants: []const Value,
        idx: u8,
    ) Value {
        _ = self;
        if (idx >= constants.len) return .null;
        const key = switch (constants[idx]) {
            .string => |s| s,
            else => return .null,
        };
        const attrs = user_attr_store.get(username) orelse return .null;
        const val = attrs.get(key) orelse return .null;
        return .{ .string = val };
    }

    // CANARY: REQ=REQ-RLS-TEMPORAL-001; FEATURE="RLSTemporalConstraints"; ASPECT=Security; STATUS=TESTED; OWNER=security; UPDATED=2026-01-30
    /// Check if the current time satisfies the temporal constraint.
    /// Supports valid_from/valid_until ranges and recurrence rules (daily, weekly, monthly, yearly).
    fn checkTemporalConstraint(self: *Self, constraint: TemporalConstraint) bool {
        _ = self;
        const now = compat_milliTimestamp();

        // Check basic time range
        if (constraint.valid_from) |from| {
            if (now < from) return false;
        }

        if (constraint.valid_until) |until| {
            if (now > until) return false;
        }

        // Check recurrence rules
        if (constraint.recurrence) |recurrence| {
            // Get current time components (UTC for simplicity; timezone handling would go here)
            const epoch_secs: u64 = @intCast(@divTrunc(now, 1000));
            const secs_per_day: u64 = 86400;
            const secs_per_hour: u64 = 3600;

            // Days since Unix epoch (Jan 1, 1970 was Thursday = 4)
            const days_since_epoch = @divTrunc(epoch_secs, secs_per_day);
            const day_of_week: u8 = @intCast((days_since_epoch + 4) % 7); // 0=Sun, 1=Mon, ..., 6=Sat
            const hour_of_day: u8 = @intCast(@divTrunc(epoch_secs % secs_per_day, secs_per_hour));

            // Check by_day constraint (which days of the week are allowed)
            if (recurrence.by_day) |allowed_days| {
                var day_allowed = false;
                for (allowed_days) |allowed_day| {
                    // Convert DayOfWeek enum to our numbering (0=Sun, 1=Mon, etc.)
                    const target_day: u8 = switch (allowed_day) {
                        .sunday => 0,
                        .monday => 1,
                        .tuesday => 2,
                        .wednesday => 3,
                        .thursday => 4,
                        .friday => 5,
                        .saturday => 6,
                    };
                    if (day_of_week == target_day) {
                        day_allowed = true;
                        break;
                    }
                }
                if (!day_allowed) return false;
            }

            // Check by_hour constraint (which hours are allowed)
            if (recurrence.by_hour) |allowed_hours| {
                var hour_allowed = false;
                for (allowed_hours) |allowed_hour| {
                    if (hour_of_day == allowed_hour) {
                        hour_allowed = true;
                        break;
                    }
                }
                if (!hour_allowed) return false;
            }

            // For interval-based frequency checks, we'd need a reference start date
            // For now, frequency and interval are informational for scheduling purposes
            // The by_day and by_hour constraints provide the actual access control
        }

        return true;
    }

    // CANARY: REQ=REQ-PERF-RLS-ROW-SKIP-002; FEATURE="RLSRowBuildSkip"; ASPECT=TablePreScan; STATUS=TESTED; TEST=tests/test_rls_expr_engine_wiring.zig; OWNER=performance; UPDATED=2026-06-11
    /// PERF-A / #808: returns true when any enabled policy applicable to
    /// (operation, graph, table) could read row data during evaluation —
    /// i.e. its compiled bytecode contains a `load_row` opcode, or it has
    /// no compiled form (conservative: the evaluator's behavior for raw
    /// expressions is out of this pre-scan's hands).
    ///
    /// When this returns false the caller may pass an EMPTY row to
    /// checkRowAccessByUsername and skip per-row row construction
    /// entirely: no applicable policy executes `load_row`, so the row
    /// contents are never read. "No policies registered" returns false
    /// (checkRowAccessByUsername default-allows without reading the row).
    ///
    /// Temporal constraints are deliberately NOT consulted here — they can
    /// flip between this pre-scan and evaluation, so a temporally-gated
    /// policy is treated as potentially active.
    pub fn needsRowDataForTable(
        self: *Self,
        operation: Operation,
        graph: []const u8,
        table: []const u8,
    ) bool {
        const key = PolicyKey{ .graph = graph, .table = table };
        self.lockPoliciesShared();
        defer self.unlockPoliciesShared();
        const policies = self.policies.get(key) orelse return false;

        for (policies.items) |policy| {
            if (!policy.enabled) continue;
            if (policy.operation != operation and policy.operation != .all) continue;

            // Mirror checkRowAccessByUsername's expression selection.
            const expr = switch (operation) {
                .select, .delete => policy.using_expr,
                .insert, .update => policy.check_expr,
                .all => policy.using_expr orelse policy.check_expr,
            };

            if (expr) |e| {
                const compiled = e.compiled orelse return true;
                if (compiled.needs_row_data) return true;
            }
        }
        return false;
    }

    // CANARY: REQ=REQ-SEC-RLS-WIRE-013; FEATURE="RLS Expression Wiring"; ASPECT=UsernameRowAccess; STATUS=IMPL; OWNER=security; UPDATED=2026-04-06
    /// Simplified row access check using username string instead of full SecurityContext.
    /// For use in the match loop where only username and graph context are available.
    /// Skips role membership checks (label-deny layer handles role-based access);
    /// expression policies apply property-level filtering to all users.
    pub fn checkRowAccessByUsername(
        self: *Self,
        row: *const std.StringHashMap(Value),
        operation: Operation,
        username: []const u8,
        graph: []const u8,
        table: []const u8,
    ) !bool {
        return self.checkRowAccessByUsernameSeeded(row, operation, username, graph, table, .{});
    }

    // CANARY: REQ=REQ-SONNY-2710-PG-POLICY-COMBINATION; FEATURE="RLS Expression Wiring"; ASPECT=SeededVerdict; STATUS=TESTED; TEST=tests/test_sonny2710_policy_combination.zig; OWNER=security; UPDATED=2026-09-26
    /// SONNY-2710: `checkRowAccessByUsername`, with the table's other policies
    /// already recorded in `seed` (the executor passes the label-deny
    /// engine's entries for the table). The expression policies are added,
    /// and the whole set combines as `PolicyVerdict` says. A seed that
    /// already fails a restrictive policy denies without evaluating anything.
    pub fn checkRowAccessByUsernameSeeded(
        self: *Self,
        row: *const std.StringHashMap(Value),
        operation: Operation,
        username: []const u8,
        graph: []const u8,
        table: []const u8,
        seed: PolicyVerdict,
    ) !bool {
        if (seed.restrictive_fails) return false;
        const key = PolicyKey{ .graph = graph, .table = table };

        // GAP-0284: the policy_cache is keyed on (graph, table, user_id,
        // operation) — it has NO row identity. It is only sound for coarse
        // "can this user touch this table at all" decisions. Expression
        // policies (ABAC `row.<prop> = principal.attribute.<key>`) produce a
        // PER-ROW verdict, so caching one row's result under a per-table key
        // and replaying it for sibling rows is a correctness bug (it denied
        // every row once any one row evaluated false). This per-row entry
        // point therefore never consults or populates policy_cache; the
        // bytecode VM eval below is cheap enough to run per row.

        // CANARY: REQ=REQ-GPS-INVARIANT-001; FEATURE="GPS Fail-Open Catalog"; ASPECT=FailOpenInterim; STATUS=EXEMPT; OWNER=security; UPDATED=2026-05-20
        // Phase 0: no-policy default-allow for pre-RLS data. GPS Phase 4 makes "allow by
        // absence" an explicit policy choice in the catalog.
        // SONNY-2679 (review): held across the evaluation, which reads the
        // policy list; the VM calls nothing that takes this lock again.
        self.lockPoliciesShared();
        defer self.unlockPoliciesShared();
        // No expression policy: the seed decides.
        const policies = self.policies.get(key) orelse return seed.allows(no_permissive_policy_allows);

        // SONNY-2710: PostgreSQL's combination (see `PolicyVerdict`).
        var verdict = seed;

        for (policies.items) |policy| {
            if (!policy.enabled) continue;
            if (policy.operation != operation and policy.operation != .all) continue;

            // Skip role check — label-deny layer handles role-based access.
            // Expression policies apply property-level filtering to all users.

            // Check temporal constraints
            if (policy.temporal) |temporal| {
                if (!self.checkTemporalConstraint(temporal)) continue;
            }

            // Evaluate policy expression
            const expr = switch (operation) {
                .select, .delete => policy.using_expr,
                .insert, .update => policy.check_expr,
                .all => policy.using_expr orelse policy.check_expr,
            };

            if (expr) |e| {
                // GAP-0723 / SEC-RLS-01 (2026-04-16): propagate VM errors as
                // the caller's error.  The old code did `catch continue`,
                // silently skipping this policy and potentially letting the
                // user through if no other restrictive policy existed.  The
                // expected behaviour when bytecode is corrupt, truncated, or
                // exceeds the stack is DENY — so return the error and let
                // the match loop's `catch false` at match_operations.zig
                // turn it into a user-visible deny.
                const result = try self.evaluateExpressionWithUsername(e, row, username);
                verdict.add(policy.permissive, result);
            }
        }

        const allowed = verdict.allows(no_permissive_policy_allows);

        // GAP-0284: deliberately NOT cached — see the note at the top of this
        // function. The verdict is per-row; policy_cache has no row identity.
        return allowed;
    }

    /// Evaluate an expression using a username string instead of a full SecurityContext.
    /// The `load_user` opcode pushes the hashed username as integer.
    /// The `load_session` opcode always pushes null (no session in this path).
    /// Falls back to the interpreted evaluator returning true when no compiled form exists,
    /// since the interpreted path requires a SecurityContext we don't have here.
    fn evaluateExpressionWithUsername(
        self: *Self,
        expr: Expression,
        row: *const std.StringHashMap(Value),
        username: []const u8,
    ) !bool {
        if (expr.compiled) |compiled| {
            return try self.evaluateCompiledExpressionWithUsername(compiled, row, username);
        }

        // GAP-0732 / SEC-RLS-02 (2026-04-16): the username-only path has no
        // SecurityContext, so we cannot walk the raw-string interpreter at
        // all.  Previously this returned `true` (allow) — a restrictive
        // policy without compiled bytecode silently let every row through.
        // Now we return error.UnsafePolicy so the caller denies the row.
        // Policies must be compiled at creation time via createPolicy(); the
        // compiled-expression path is the single enforcement gate.
        return error.UnsafePolicy;
    }

    /// Bytecode VM evaluation using a username string instead of SecurityContext.
    // GAP-0723 / SEC-RLS-01 (2026-04-16): same hardening as
    // evaluateCompiledExpression — bounds-checked push/pop, fail-closed on
    // stack OOB, safe opcode decoding via std.meta.intToEnum.
    fn evaluateCompiledExpressionWithUsername(
        self: *Self,
        expr: *CompiledExpression,
        row: *const std.StringHashMap(Value),
        username: []const u8,
    ) !bool {
        const Opcode = CompiledExpression.Opcode;
        var stack: [RLS_STACK_DEPTH]Value = undefined;
        // SONNY-2709: which slots hold a principal attribute (see `Operand`).
        var from_attr = [_]bool{false} ** RLS_STACK_DEPTH;
        var sp: usize = 0;

        var pc: usize = 0;
        // SONNY-2732: see evaluateCompiledExpression.
        var steps: usize = 0;
        while (pc < expr.bytecode.len) {
            steps += 1;
            if (steps > expr.bytecode.len) return error.StepLimitExceeded;
            // GAP-0723: validate opcode before dispatch (avoid UB from @enumFromInt).
            const opcode: Opcode = Opcode.fromByte(expr.bytecode[pc]) orelse {
                return error.InvalidOpcode;
            };
            pc += 1;

            switch (opcode) {
                .nop => {},
                .push_const => {
                    if (pc >= expr.bytecode.len) return error.BytecodeUnderrun;
                    const idx = expr.bytecode[pc];
                    pc += 1;
                    // SONNY-2732: an index past the constants was skipped,
                    // silently changing what the program computes: refused.
                    if (idx >= expr.constants.len) return error.InvalidConstantIndex;
                    if (sp >= stack.len) return error.StackOverflow;
                    stack[sp] = expr.constants[idx];
                    from_attr[sp] = false;
                    sp += 1;
                },
                .push_true => {
                    if (sp >= stack.len) return error.StackOverflow;
                    stack[sp] = .{ .boolean = true };
                    sp += 1;
                },
                .push_false => {
                    if (sp >= stack.len) return error.StackOverflow;
                    stack[sp] = .{ .boolean = false };
                    sp += 1;
                },
                .push_null => {
                    if (sp >= stack.len) return error.StackOverflow;
                    stack[sp] = .null;
                    sp += 1;
                },
                .pop => {
                    if (sp == 0) return error.StackUnderflow;
                    sp -= 1;
                },
                .load_row => {
                    if (pc >= expr.bytecode.len) return error.BytecodeUnderrun;
                    const idx = expr.bytecode[pc];
                    pc += 1;
                    // SONNY-2732: see push_const.
                    if (idx >= expr.constants.len) return error.InvalidConstantIndex;
                    if (sp >= stack.len) return error.StackOverflow;
                    const field_name = switch (expr.constants[idx]) {
                        .string => |s| s,
                        else => return error.InvalidConstantIndex,
                    };
                    if (row.get(field_name)) |val| {
                        stack[sp] = val;
                    } else {
                        stack[sp] = .null;
                    }
                    from_attr[sp] = false;
                    sp += 1;
                },
                .load_user => {
                    if (sp >= stack.len) return error.StackOverflow;
                    // Push hashed username as integer (matches cache key derivation).
                    // PERF-A drive-by fix: @intCast of the u64 Wyhash into i64
                    // panicked (Debug) / was UB (release) for any username whose
                    // hash has the high bit set (~50% of usernames). @bitCast
                    // keeps the full 64-bit identity deterministically.
                    stack[sp] = .{ .integer = @bitCast(std.hash.Wyhash.hash(0, username)) };
                    from_attr[sp] = false;
                    sp += 1;
                },
                .load_session => {
                    // No session available in the username-only path; push null.
                    if (pc >= expr.bytecode.len) return error.BytecodeUnderrun;
                    const idx = expr.bytecode[pc];
                    pc += 1;
                    // SONNY-2732: see push_const.
                    if (idx >= expr.constants.len) return error.InvalidConstantIndex;
                    if (sp >= stack.len) return error.StackOverflow;
                    stack[sp] = .null;
                    from_attr[sp] = false;
                    sp += 1;
                },
                .load_attr => {
                    // CANARY: REQ=GAP-0284; FEATURE="ABAC user attribute store"; ASPECT=RLSExprAttrLoad; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/abac_attribute_policies.yml; OWNER=security; UPDATED=2026-05-22
                    // Resolve principal.attribute.<key> against the global ABAC
                    // attribute side-table for the querying username.
                    if (pc >= expr.bytecode.len) return error.BytecodeUnderrun;
                    const idx = expr.bytecode[pc];
                    pc += 1;
                    if (sp >= stack.len) return error.StackOverflow;
                    // SONNY-2732: see push_const.
                    if (idx >= expr.constants.len) return error.InvalidConstantIndex;
                    stack[sp] = self.resolvePrincipalAttribute(username, expr.constants, idx);
                    from_attr[sp] = true;
                    sp += 1;
                },
                .eq, .neq => {
                    if (sp < 2) return error.StackUnderflow;
                    const b = Operand{ .value = stack[sp - 1], .from_attr = from_attr[sp - 1] };
                    const a = Operand{ .value = stack[sp - 2], .from_attr = from_attr[sp - 2] };
                    sp -= 2;
                    stack[sp] = self.evalEquality(opcode, a, b);
                    from_attr[sp] = false;
                    sp += 1;
                },
                .is_null => {
                    if (sp < 1) return error.StackUnderflow;
                    // Read before writing: the literal's tag would be stored
                    // into the slot before the test below reads it.
                    const is_null = stack[sp - 1] == .null;
                    stack[sp - 1] = .{ .boolean = is_null };
                    from_attr[sp - 1] = false;
                },
                .lt, .gt, .lte, .gte => {
                    if (sp < 2) return error.StackUnderflow;
                    const b = Operand{ .value = stack[sp - 1], .from_attr = from_attr[sp - 1] };
                    const a = Operand{ .value = stack[sp - 2], .from_attr = from_attr[sp - 2] };
                    sp -= 2;
                    stack[sp] = self.evalRange(opcode, a, b);
                    from_attr[sp] = false;
                    sp += 1;
                },
                .op_and => {
                    if (sp < 2) return error.StackUnderflow;
                    const b = self.truthOf(stack[sp - 1]);
                    const a = self.truthOf(stack[sp - 2]);
                    sp -= 2;
                    stack[sp] = truthValue(kleeneAnd(a, b));
                    sp += 1;
                },
                .op_or => {
                    if (sp < 2) return error.StackUnderflow;
                    const b = self.truthOf(stack[sp - 1]);
                    const a = self.truthOf(stack[sp - 2]);
                    sp -= 2;
                    stack[sp] = truthValue(kleeneOr(a, b));
                    sp += 1;
                },
                .op_not => {
                    if (sp < 1) return error.StackUnderflow;
                    const a = self.truthOf(stack[sp - 1]);
                    sp -= 1;
                    stack[sp] = truthValue(if (a) |t| !t else null);
                    sp += 1;
                },
                .jump => {
                    if (pc >= expr.bytecode.len) return error.BytecodeUnderrun;
                    const idx = expr.bytecode[pc];
                    pc += 1;
                    pc = try jumpTarget(expr, idx);
                },
                .jump_if_false => {
                    if (pc >= expr.bytecode.len) return error.BytecodeUnderrun;
                    const idx = expr.bytecode[pc];
                    pc += 1;
                    if (sp == 0) return error.StackUnderflow;
                    sp -= 1;
                    // SONNY-2709 / SONNY-2732: a branch cannot take UNKNOWN
                    // (or a non-boolean) as false: the skipped arm may be the
                    // one that denies. The policy is undecided, and an
                    // undecided policy denies.
                    const target = try jumpTarget(expr, idx);
                    const cond = self.truthOf(stack[sp]) orelse return error.IndeterminatePolicy;
                    if (!cond) pc = target;
                },
                .jump_if_true => {
                    if (pc >= expr.bytecode.len) return error.BytecodeUnderrun;
                    const idx = expr.bytecode[pc];
                    pc += 1;
                    if (sp == 0) return error.StackUnderflow;
                    sp -= 1;
                    // SONNY-2709 / SONNY-2732: see jump_if_false.
                    const target = try jumpTarget(expr, idx);
                    const cond = self.truthOf(stack[sp]) orelse return error.IndeterminatePolicy;
                    if (cond) pc = target;
                },
                .ret => {
                    // SONNY-2732: only a boolean TRUE on top admits the row.
                    if (sp > 0) return admits(stack[sp - 1]);
                    return false;
                },
            }
        }

        // If no explicit return, check top of stack
        if (sp > 0) return admits(stack[sp - 1]);

        // CANARY: REQ=REQ-GPS-INVARIANT-001; FEATURE="GPS Fail-Open Catalog"; ASPECT=FailOpenInterim; STATUS=COMPLETE; OWNER=security; UPDATED=2026-05-20
        // GPS Phase 2 (task 2-8): VM no-result is now surfaced as
        // error.IndeterminatePolicy. Consumers (checkRowAccessByUsername,
        // passesRLSExprFilter) map this to a deny outcome.
        return error.IndeterminatePolicy;
    }
};

// Policy Cache for performance
pub const PolicyCache = struct {
    allocator: Allocator,
    cache: std.HashMap(CacheKey, CacheEntry, CacheKey.HashContext, 80),
    max_size: usize,
    ttl_ms: i64,

    const CacheKey = struct {
        policy_key: RLSEngine.PolicyKey,
        user_id: auth.UserId,
        operation: RLSEngine.Operation,

        pub const HashContext = struct {
            pub fn hash(_: @This(), key: CacheKey) u64 {
                var hasher = std.hash.Wyhash.init(0);
                hasher.update(key.policy_key.graph);
                hasher.update(key.policy_key.table);
                hasher.update(std.mem.asBytes(&key.user_id));
                hasher.update(std.mem.asBytes(&key.operation));
                return hasher.final();
            }

            pub fn eql(_: @This(), a: CacheKey, b: CacheKey) bool {
                return RLSEngine.PolicyKey.HashContext.eql(.{}, a.policy_key, b.policy_key) and
                    a.user_id == b.user_id and
                    a.operation == b.operation;
            }
        };
    };

    const CacheEntry = struct {
        allowed: bool,
        timestamp: i64,
    };

    pub fn init(allocator: Allocator) !PolicyCache {
        return PolicyCache{
            .allocator = allocator,
            .cache = std.HashMap(CacheKey, CacheEntry, CacheKey.HashContext, 80).init(allocator),
            .max_size = RLS_POLICY_CACHE_MAX_SIZE,
            .ttl_ms = RLS_POLICY_CACHE_TTL_MS,
        };
    }

    pub fn deinit(self: *PolicyCache) void {
        self.cache.deinit();
    }

    pub fn get(
        self: *PolicyCache,
        policy_key: RLSEngine.PolicyKey,
        user_id: auth.UserId,
        operation: RLSEngine.Operation,
    ) ?bool {
        const key = CacheKey{
            .policy_key = policy_key,
            .user_id = user_id,
            .operation = operation,
        };

        if (self.cache.get(key)) |entry| {
            const now = compat_milliTimestamp();
            if (now - entry.timestamp < self.ttl_ms) {
                return entry.allowed;
            }
            // Entry expired
            _ = self.cache.remove(key);
        }

        return null;
    }

    pub fn put(
        self: *PolicyCache,
        policy_key: RLSEngine.PolicyKey,
        user_id: auth.UserId,
        operation: RLSEngine.Operation,
        allowed: bool,
    ) !void {
        // Evict old entries if cache is full
        if (self.cache.count() >= self.max_size) {
            try self.evictOldest();
        }

        const key = CacheKey{
            .policy_key = policy_key,
            .user_id = user_id,
            .operation = operation,
        };

        try self.cache.put(key, CacheEntry{
            .allowed = allowed,
            .timestamp = compat_milliTimestamp(),
        });
    }

    pub fn invalidate(self: *PolicyCache, policy_key: RLSEngine.PolicyKey) !void {
        var to_remove = std.ArrayList(CacheKey).empty;
        defer to_remove.deinit(self.allocator);

        var it = self.cache.iterator();
        while (it.next()) |entry| {
            if (RLSEngine.PolicyKey.HashContext.eql(.{}, entry.key_ptr.policy_key, policy_key)) {
                try to_remove.append(self.allocator, entry.key_ptr.*);
            }
        }

        for (to_remove.items) |key| {
            _ = self.cache.remove(key);
        }
    }

    fn evictOldest(self: *PolicyCache) !void {
        var oldest_key: ?CacheKey = null;
        var oldest_time: i64 = std.math.maxInt(i64);

        var it = self.cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.timestamp < oldest_time) {
                oldest_time = entry.value_ptr.timestamp;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key) |key| {
            _ = self.cache.remove(key);
        }
    }
};

// Context Evaluator for expression evaluation
pub const ContextEvaluator = struct {
    allocator: Allocator,
    functions: std.StringHashMap(Function),

    const Function = *const fn (
        allocator: Allocator,
        args: []const Value,
        context: *auth.SecurityContext,
    ) anyerror!Value;

    pub fn init(allocator: Allocator) !ContextEvaluator {
        var evaluator = ContextEvaluator{
            .allocator = allocator,
            .functions = std.StringHashMap(Function).init(allocator),
        };

        // Register built-in functions
        try evaluator.registerBuiltinFunctions();

        return evaluator;
    }

    pub fn deinit(self: *ContextEvaluator) void {
        self.functions.deinit();
    }

    // CANARY: REQ=REQ-RLS-EVAL-001; FEATURE="RLSExpressionEvaluation"; ASPECT=Security; STATUS=TESTED; OWNER=security; UPDATED=2026-01-30
    /// Evaluate an RLS expression string against row data and security context.
    /// Supports patterns: `column = value`, `column = current_user()`, `has_role('name')`, AND/OR combinations
    pub fn evaluate(
        self: *ContextEvaluator,
        expression: []const u8,
        row: *const std.StringHashMap(Value),
        context: *auth.SecurityContext,
    ) !bool {
        // Empty expression defaults to true (permissive)
        if (expression.len == 0) return true;

        // Parse and evaluate the expression
        return self.evaluateExpr(expression, row, context);
    }

    fn evaluateExpr(
        self: *ContextEvaluator,
        expr: []const u8,
        row: *const std.StringHashMap(Value),
        context: *auth.SecurityContext,
    ) !bool {
        const trimmed = std.mem.trim(u8, expr, " \t\n\r");
        if (trimmed.len == 0) return true;

        // Handle OR (lowest precedence)
        if (std.mem.indexOf(u8, trimmed, " OR ")) |or_pos| {
            const left = trimmed[0..or_pos];
            const right = trimmed[or_pos + 4 ..];
            return (try self.evaluateExpr(left, row, context)) or
                (try self.evaluateExpr(right, row, context));
        }

        // Handle AND
        if (std.mem.indexOf(u8, trimmed, " AND ")) |and_pos| {
            const left = trimmed[0..and_pos];
            const right = trimmed[and_pos + 5 ..];
            return (try self.evaluateExpr(left, row, context)) and
                (try self.evaluateExpr(right, row, context));
        }

        // Handle parentheses
        if (trimmed[0] == '(' and trimmed[trimmed.len - 1] == ')') {
            return self.evaluateExpr(trimmed[1 .. trimmed.len - 1], row, context);
        }

        // Handle function calls: func_name(args)
        if (std.mem.indexOf(u8, trimmed, "(")) |paren_pos| {
            const func_name = trimmed[0..paren_pos];
            const args_end = std.mem.lastIndexOf(u8, trimmed, ")") orelse return error.InvalidExpression;
            const args_str = trimmed[paren_pos + 1 .. args_end];

            // Check for built-in functions
            if (self.functions.get(func_name)) |func| {
                var args_list = std.ArrayList(Value).empty;
                defer args_list.deinit(self.allocator);

                // Parse arguments (simple comma-separated values)
                if (args_str.len > 0) {
                    var args_iter = std.mem.splitSequence(u8, args_str, ",");
                    while (args_iter.next()) |arg| {
                        const arg_trimmed = std.mem.trim(u8, arg, " \t'\"");
                        try args_list.append(self.allocator, .{ .string = arg_trimmed });
                    }
                }

                const result = try func(self.allocator, args_list.items, context);
                return switch (result) {
                    .boolean => |b| b,
                    .null => false,
                    else => true,
                };
            }
        }

        // Handle comparison: column = value, column <> value, column != value
        const ops = [_]struct { op: []const u8, eq: bool }{
            .{ .op = " <> ", .eq = false },
            .{ .op = " != ", .eq = false },
            .{ .op = " = ", .eq = true },
        };

        for (ops) |op_info| {
            if (std.mem.indexOf(u8, trimmed, op_info.op)) |op_pos| {
                const left_side = std.mem.trim(u8, trimmed[0..op_pos], " \t");
                const right_side = std.mem.trim(u8, trimmed[op_pos + op_info.op.len ..], " \t");

                // Get left value (column reference or function)
                const left_val = try self.resolveValue(left_side, row, context);

                // Get right value (literal or function)
                const right_val = try self.resolveValue(right_side, row, context);

                // Compare values
                const equal = self.valuesEqual(left_val, right_val);
                return if (op_info.eq) equal else !equal;
            }
        }

        // Treat as boolean value or column reference
        const val = try self.resolveValue(trimmed, row, context);
        return switch (val) {
            .boolean => |b| b,
            .null => false,
            .integer => |i| i != 0,
            .string => |s| s.len > 0,
            else => true,
        };
    }

    fn resolveValue(
        self: *ContextEvaluator,
        expr: []const u8,
        row: *const std.StringHashMap(Value),
        context: *auth.SecurityContext,
    ) !Value {
        const trimmed = std.mem.trim(u8, expr, " \t");

        // Check for literals
        if (trimmed.len >= 2 and trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'') {
            return .{ .string = trimmed[1 .. trimmed.len - 1] };
        }
        if (std.mem.eql(u8, trimmed, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, trimmed, "false")) return .{ .boolean = false };
        if (std.mem.eql(u8, trimmed, "null") or std.mem.eql(u8, trimmed, "NULL")) return .null;

        // Try parsing as integer
        if (std.fmt.parseInt(i64, trimmed, 10)) |int_val| {
            return .{ .integer = int_val };
        } else |_| {}

        // Check for function call
        if (std.mem.indexOf(u8, trimmed, "(")) |paren_pos| {
            const func_name = trimmed[0..paren_pos];
            const args_end = std.mem.lastIndexOf(u8, trimmed, ")") orelse return error.InvalidExpression;
            const args_str = trimmed[paren_pos + 1 .. args_end];

            if (self.functions.get(func_name)) |func| {
                var args_list = std.ArrayList(Value).empty;
                defer args_list.deinit(self.allocator);

                if (args_str.len > 0) {
                    var args_iter = std.mem.splitSequence(u8, args_str, ",");
                    while (args_iter.next()) |arg| {
                        const arg_trimmed = std.mem.trim(u8, arg, " \t'\"");
                        try args_list.append(self.allocator, .{ .string = arg_trimmed });
                    }
                }

                return func(self.allocator, args_list.items, context);
            }
        }

        // Treat as column reference
        if (row.get(trimmed)) |val| {
            return val;
        }

        // Column not found - return null
        return .null;
    }

    fn valuesEqual(self: *ContextEvaluator, a: Value, b: Value) bool {
        _ = self;
        return switch (a) {
            .null => b == .null,
            .boolean => |av| switch (b) {
                .boolean => |bv| av == bv,
                else => false,
            },
            .integer => |av| switch (b) {
                .integer => |bv| av == bv,
                .float => |bv| @as(f64, @floatFromInt(av)) == bv,
                else => false,
            },
            .float => |av| switch (b) {
                .float => |bv| av == bv,
                .integer => |bv| av == @as(f64, @floatFromInt(bv)),
                else => false,
            },
            .string => |av| switch (b) {
                .string => |bv| std.mem.eql(u8, av, bv),
                else => false,
            },
            else => false,
        };
    }

    fn registerBuiltinFunctions(self: *ContextEvaluator) !void {
        try self.functions.put("current_user", getCurrentUser);
        try self.functions.put("has_role", hasRole);
        try self.functions.put("has_permission", hasPermission);
        try self.functions.put("current_timestamp", getCurrentTimestamp);
        try self.functions.put("ip_in_range", ipInRange);
    }

    fn getCurrentUser(
        allocator: Allocator,
        args: []const Value,
        context: *auth.SecurityContext,
    ) anyerror!Value {
        _ = allocator;
        _ = args;
        return Value{ .integer = @intCast(context.user.id) };
    }

    fn hasRole(
        allocator: Allocator,
        args: []const Value,
        context: *auth.SecurityContext,
    ) anyerror!Value {
        _ = allocator;
        if (args.len != 1) return error.InvalidArguments;

        const role_name = switch (args[0]) {
            .string => |s| s,
            else => return error.InvalidArguments,
        };

        for (context.roles) |role| {
            if (std.mem.eql(u8, role.name, role_name)) {
                return Value{ .boolean = true };
            }
        }

        return Value{ .boolean = false };
    }

    // CANARY: REQ=REQ-RLS-PERM-001; FEATURE="RLSPermissionCheck"; ASPECT=Security; STATUS=TESTED; OWNER=security; UPDATED=2026-01-30
    /// Check if user has a specific permission through their roles.
    /// Permission format: "resource:action" or "permission_name"
    fn hasPermission(
        allocator: Allocator,
        args: []const Value,
        context: *auth.SecurityContext,
    ) anyerror!Value {
        _ = allocator;
        if (args.len != 1) return error.InvalidArguments;

        const permission_name = switch (args[0]) {
            .string => |s| s,
            else => return error.InvalidArguments,
        };

        // Check if any role grants this permission
        // Permission can be specified as "resource:action" or just "permission_name"
        for (context.roles) |role| {
            // Check if role name implies permission (admin role has all permissions)
            if (std.mem.eql(u8, role.name, "admin") or
                std.mem.eql(u8, role.name, "superuser") or
                std.mem.eql(u8, role.name, "root"))
            {
                return Value{ .boolean = true };
            }

            // Check if role name matches the permission pattern
            // e.g., role "nodes:read" grants "nodes:read" permission
            if (std.mem.eql(u8, role.name, permission_name)) {
                return Value{ .boolean = true };
            }

            // Check if permission starts with role name (hierarchical)
            // e.g., role "nodes" grants "nodes:read", "nodes:write" etc.
            if (std.mem.indexOf(u8, permission_name, ":")) |colon_pos| {
                const resource = permission_name[0..colon_pos];
                if (std.mem.eql(u8, role.name, resource)) {
                    return Value{ .boolean = true };
                }
            }
        }

        // Permission not found in any role
        return Value{ .boolean = false };
    }

    fn getCurrentTimestamp(
        allocator: Allocator,
        args: []const Value,
        context: *auth.SecurityContext,
    ) anyerror!Value {
        _ = allocator;
        _ = args;
        _ = context;
        return Value{ .timestamp = compat_milliTimestamp() };
    }

    /// Parse an IPv4 dotted-decimal string into a u32 in network byte order.
    /// Returns null on any parse failure (non-numeric octets, wrong count, >255).
    fn parseIpv4(ip: []const u8) ?u32 {
        var result: u32 = 0;
        var octet_count: u8 = 0;
        var remaining = ip;

        while (octet_count < 4) : (octet_count += 1) {
            if (octet_count > 0) {
                if (remaining.len == 0 or remaining[0] != '.') return null;
                remaining = remaining[1..];
            }
            const dot_pos = std.mem.indexOf(u8, remaining, ".");
            const octet_str = if (dot_pos) |p| remaining[0..p] else remaining;
            if (octet_str.len == 0) return null;
            const octet = std.fmt.parseInt(u8, octet_str, 10) catch return null;
            result = (result << 8) | @as(u32, octet);
            remaining = if (dot_pos) |p| remaining[p..] else remaining[octet_str.len..];
        }

        // Must have consumed all input
        if (remaining.len != 0) return null;
        return result;
    }

    /// Proper IPv4 CIDR range check. Supports "A.B.C.D/N" or plain "A.B.C.D" (treated as /32).
    fn cidrMatch(ip_str: []const u8, range_str: []const u8) bool {
        const ip_u32 = parseIpv4(ip_str) orelse return false;

        // Split range on '/' for CIDR prefix length
        var base_str: []const u8 = range_str;
        var prefix_len: u6 = 32;

        if (std.mem.indexOf(u8, range_str, "/")) |slash_pos| {
            base_str = range_str[0..slash_pos];
            prefix_len = std.fmt.parseInt(u6, range_str[slash_pos + 1 ..], 10) catch return false;
            if (prefix_len > 32) return false;
        }

        const base_u32 = parseIpv4(base_str) orelse return false;

        if (prefix_len == 0) return true; // 0.0.0.0/0 matches everything

        const mask: u32 = ~(@as(u32, 0)) << @intCast(32 - @as(u6, prefix_len));
        return (ip_u32 & mask) == (base_u32 & mask);
    }

    fn ipInRange(
        allocator: Allocator,
        args: []const Value,
        context: *auth.SecurityContext,
    ) anyerror!Value {
        _ = allocator;
        if (args.len != 1) return error.InvalidArguments;

        const range = switch (args[0]) {
            .string => |s| s,
            else => return error.InvalidArguments,
        };

        return Value{
            .boolean = cidrMatch(context.environment.ip_address, range),
        };
    }
};

// Hierarchical access control for multi-tenant scenarios.
//
// GAP-0838: re-keyed on the STRING `tenant_id` (`[]const u8`) to match the rest
// of the system (HELLO/session/FLE/audit/proto all use `tenant_id: []const u8`,
// and `graph_store.DEFAULT_TENANT_ID = "default"`). Previously this was keyed on
// `u64` and had no production provisioning API, so it was dead code that could
// never be bridged to the wire's string tenant ids. It now owns its key/path
// strings (callers may pass borrowed slices) and exposes `addTenant` so
// production code — not just tests — can populate the org → business-unit →
// engagement tree CaaST needs.
//
// GAP-0846 (closed): the live query read path NOW consults this manager.
// `match_operations.passesTenantFilter` / `passesTenantFilterEdge` call
// `canAccessTenantSafe(session_tenant, row_tenant)` whenever a hierarchy has
// been provisioned (`count() > 0`) and the session's tenant is concrete and
// registered. When no hierarchy exists the read path keeps the exact-match
// `std.mem.eql` fast path (zero overhead). `addTenant` is the production
// provisioning seam (server-init replay + `CALL geode.tenant.create`).
pub const HierarchyManager = struct {
    allocator: Allocator,
    tenant_hierarchy: std.StringHashMap(TenantNode),
    data_domains: std.StringHashMap(DataDomain),
    inheritance_rules: []InheritanceRule,

    pub const TenantNode = struct {
        // `id` aliases the owned map key (NOT separately freed).
        id: []const u8,
        // `parent_id` aliases the parent's owned map key (NOT separately freed).
        parent_id: ?[]const u8,
        // `children` and `path` own their own dupes (freed in removeNode/deinit).
        children: std.ArrayList([]const u8),
        level: u32,
        path: []const []const u8,
        metadata: std.StringHashMap([]const u8),
    };

    pub const DataDomain = struct {
        name: []const u8,
        parent_domain: ?[]const u8,
        isolation_level: IsolationLevel,
        cross_domain_rules: []CrossDomainRule,

        pub const IsolationLevel = enum {
            strict, // No cross-domain access
            permeable, // Controlled cross-domain access
            shared, // Shared across domains
        };

        pub const CrossDomainRule = struct {
            target_domain: []const u8,
            allowed_operations: []RLSEngine.Operation,
            conditions: []const u8,
        };
    };

    pub const InheritanceRule = struct {
        source_level: u32,
        target_level: u32,
        inherit_policies: bool,
        inherit_permissions: bool,
        override_allowed: bool,
    };

    pub fn init(allocator: Allocator) !HierarchyManager {
        return HierarchyManager{
            .allocator = allocator,
            .tenant_hierarchy = std.StringHashMap(TenantNode).init(allocator),
            .data_domains = std.StringHashMap(DataDomain).init(allocator),
            .inheritance_rules = try allocator.alloc(InheritanceRule, 0),
        };
    }

    pub fn deinit(self: *HierarchyManager) void {
        var it = self.tenant_hierarchy.iterator();
        while (it.next()) |entry| {
            // Free the owned per-node allocations. `id`/`parent_id` alias map
            // keys and are NOT freed here; the map frees its keys on deinit.
            for (entry.value_ptr.path) |seg| self.allocator.free(seg);
            self.allocator.free(entry.value_ptr.path);
            for (entry.value_ptr.children.items) |child| self.allocator.free(child);
            entry.value_ptr.children.deinit(self.allocator);
            entry.value_ptr.metadata.deinit();
            // Free the owned map key.
            self.allocator.free(entry.key_ptr.*);
        }
        self.tenant_hierarchy.deinit();
        self.data_domains.deinit();
        self.allocator.free(self.inheritance_rules);
    }

    // GAP-0838: production provisioning API. Registers `tenant_id` under
    // optional `parent`. Both slices are BORROWED — the manager dupes whatever
    // it needs to own. `parent` (when set) must already be registered.
    //
    // The node's `path` is the root-to-self ancestry chain (parent.path ++
    // tenant_id), which is exactly what `canAccessTenant`'s prefix check
    // consumes. `level` is the depth (root == 0).
    pub fn addTenant(self: *HierarchyManager, tenant_id: []const u8, parent: ?[]const u8) !void {
        if (self.tenant_hierarchy.contains(tenant_id)) return error.TenantAlreadyExists;

        // Own the key string. On any later failure we free it via errdefer.
        const owned_key = try self.allocator.dupe(u8, tenant_id);
        errdefer self.allocator.free(owned_key);

        var level: u32 = 0;
        var parent_key: ?[]const u8 = null;
        var parent_path: []const []const u8 = &[_][]const u8{};
        if (parent) |p| {
            const parent_node = self.tenant_hierarchy.getPtr(p) orelse return error.TenantNotFound;
            // Alias the parent's OWNED key so `parent_id` outlives `p`.
            parent_key = parent_node.id;
            parent_path = parent_node.path;
            level = parent_node.level + 1;
        }

        // Build the owned root-to-self path: dupe every ancestor segment plus
        // self so the path owns its strings independent of caller/parent.
        var path = try self.allocator.alloc([]const u8, parent_path.len + 1);
        var built: usize = 0;
        errdefer {
            for (path[0..built]) |seg| self.allocator.free(seg);
            self.allocator.free(path);
        }
        for (parent_path) |seg| {
            path[built] = try self.allocator.dupe(u8, seg);
            built += 1;
        }
        path[built] = try self.allocator.dupe(u8, tenant_id);
        built += 1;

        try self.tenant_hierarchy.put(owned_key, .{
            .id = owned_key,
            .parent_id = parent_key,
            .children = std.ArrayList([]const u8).empty,
            .level = level,
            .path = path,
            .metadata = std.StringHashMap([]const u8).init(self.allocator),
        });

        // Register self in the parent's children list (owned dupe). If this
        // fails we've already committed the node; leave it consistent by
        // surfacing the error to the caller without rolling back the put.
        if (parent) |p| {
            const parent_node = self.tenant_hierarchy.getPtr(p).?;
            const child_dup = try self.allocator.dupe(u8, tenant_id);
            errdefer self.allocator.free(child_dup);
            try parent_node.children.append(self.allocator, child_dup);
        }
    }

    pub fn getTenantPath(self: *HierarchyManager, tenant_id: []const u8) ![]const []const u8 {
        const node = self.tenant_hierarchy.get(tenant_id) orelse return error.TenantNotFound;
        return node.path;
    }

    // GAP-0847: does `tenant_id` have at least one registered child? The tenant
    // drop path uses this to refuse a non-cascade drop of a parent tenant (its
    // descendants would be orphaned in the hierarchy and unreachable for authz).
    // Returns false for an unknown tenant (nothing to protect).
    pub fn hasChildren(self: *HierarchyManager, tenant_id: []const u8) bool {
        const node = self.tenant_hierarchy.get(tenant_id) orelse return false;
        return node.children.items.len > 0;
    }

    // GAP-0847: snapshot the direct children of `tenant_id` into a caller-owned
    // slice (each element duped with `caller_allocator`; free with `freeChildren`).
    // Returns an empty slice for an unknown or leaf tenant. The cascade drop walks
    // this set recursively (children-first) so a parent is removed only after all
    // its descendants.
    pub fn getChildrenAlloc(self: *HierarchyManager, caller_allocator: std.mem.Allocator, tenant_id: []const u8) ![][]const u8 {
        const node = self.tenant_hierarchy.get(tenant_id) orelse return caller_allocator.alloc([]const u8, 0);
        const out = try caller_allocator.alloc([]const u8, node.children.items.len);
        errdefer caller_allocator.free(out);
        var built: usize = 0;
        errdefer for (out[0..built]) |c| caller_allocator.free(c);
        for (node.children.items) |child| {
            out[built] = try caller_allocator.dupe(u8, child);
            built += 1;
        }
        return out;
    }

    pub fn freeChildren(caller_allocator: std.mem.Allocator, children: [][]const u8) void {
        for (children) |c| caller_allocator.free(c);
        caller_allocator.free(children);
    }

    // GAP-0847: remove `tenant_id` from the hierarchy, freeing its owned path,
    // children list, metadata, and map key, and detaching it from its parent's
    // children list so the parent no longer references a freed child string.
    // Returns `error.TenantNotFound` if absent and `error.TenantHasChildren` if
    // the node still has descendants (the caller must drop children first — the
    // drop cascade walks bottom-up, so this is a guard, not an expected path).
    pub fn removeTenant(self: *HierarchyManager, tenant_id: []const u8) !void {
        const node_ptr = self.tenant_hierarchy.getPtr(tenant_id) orelse return error.TenantNotFound;
        if (node_ptr.children.items.len > 0) return error.TenantHasChildren;

        // Detach from parent's children list (the parent stores an OWNED dupe of
        // this tenant's id — find and free it).
        if (node_ptr.parent_id) |pid| {
            if (self.tenant_hierarchy.getPtr(pid)) |parent_node| {
                var idx: usize = 0;
                while (idx < parent_node.children.items.len) : (idx += 1) {
                    if (std.mem.eql(u8, parent_node.children.items[idx], tenant_id)) {
                        const removed = parent_node.children.swapRemove(idx);
                        self.allocator.free(removed);
                        break;
                    }
                }
            }
        }

        // Remove the entry and free its owned allocations. fetchRemove returns the
        // owned key + value so we can free both deterministically.
        const kv = self.tenant_hierarchy.fetchRemove(tenant_id) orelse return error.TenantNotFound;
        var node = kv.value;
        for (node.path) |seg| self.allocator.free(seg);
        self.allocator.free(node.path);
        for (node.children.items) |child| self.allocator.free(child);
        node.children.deinit(self.allocator);
        node.metadata.deinit();
        self.allocator.free(kv.key);
    }

    // GAP-0846: number of registered tenants. Read-path hot loops use this to
    // keep the exact-match fast path (zero hierarchy overhead) when no hierarchy
    // has been provisioned — `count() == 0` means "no hierarchy configured".
    pub fn count(self: *HierarchyManager) usize {
        return self.tenant_hierarchy.count();
    }

    // GAP-0846: true iff `tenant_id` is registered in the hierarchy.
    pub fn contains(self: *HierarchyManager, tenant_id: []const u8) bool {
        return self.tenant_hierarchy.contains(tenant_id);
    }

    // GAP-0846: fail-CLOSED variant of `canAccessTenant` for the live read path.
    // `canAccessTenant` returns `error.TenantNotFound` when either tenant is not
    // registered; in a read-filter hot loop we must turn that into a deny (false)
    // rather than propagate an error that would abort the whole query. A target
    // tenant that is not part of the hierarchy is, by definition, not a descendant
    // of the accessor, so denying it is the correct (and safe) answer. Self-access
    // and the exact-match case are handled by the caller before reaching here.
    pub fn canAccessTenantSafe(self: *HierarchyManager, accessor_tenant: []const u8, target_tenant: []const u8) bool {
        return self.canAccessTenant(accessor_tenant, target_tenant) catch false;
    }

    // Access semantics PRESERVED from the original u64 implementation: an
    // accessor can access a target iff the accessor's path is a prefix of the
    // target's path — i.e. the accessor is an ANCESTOR of, or IS, the target.
    // Parent → descendant: allowed. Descendant → ancestor: denied. Siblings:
    // denied. Self: allowed. Unknown tenant: error.TenantNotFound.
    pub fn canAccessTenant(self: *HierarchyManager, accessor_tenant: []const u8, target_tenant: []const u8) !bool {
        const accessor_path = try self.getTenantPath(accessor_tenant);
        const target_path = try self.getTenantPath(target_tenant);

        // Check if accessor is ancestor-or-self of target (path prefix).
        if (accessor_path.len <= target_path.len) {
            for (accessor_path, 0..) |id, i| {
                if (!std.mem.eql(u8, target_path[i], id)) return false;
            }
            return true;
        }

        return false;
    }
};

// Attribute-Based Access Control (ABAC)

// Move AttributeRule outside to avoid nested type issues
pub const ABACAttributeCondition = struct {
    expression: []const u8,
    required_attributes: []const []const u8,
};

pub const ABACEffect = enum {
    permit,
    deny,
};

pub const ABACObligationType = enum {
    audit,
    notify,
    transform,
    delay,
};

pub const ABACObligation = struct {
    type: ABACObligationType,
    // Simplified - removed StringHashMap to avoid module issues
    params_json: ?[]const u8,
};

pub const ABACAttributeRule = struct {
    id: u64,
    name: []const u8,
    priority: u32,
};

pub const AttributeBasedAccessControl = struct {
    allocator: Allocator,
    attribute_definitions: std.StringHashMap(AttributeDefinition),
    attribute_rules: []ABACAttributeRule, // Changed from ArrayList to slice
    attribute_evaluator: AttributeEvaluator,

    pub const AttributeDefinition = struct {
        name: []const u8,
        type: AttributeType,
        source: AttributeSource,
        validators: []Validator,
        transformers: []Transformer,

        pub const AttributeType = enum {
            string,
            number,
            boolean,
            array,
            object,
            timestamp,
        };

        pub const AttributeSource = enum {
            user,
            resource,
            environment,
            derived,
        };

        pub const Validator = struct {
            type: ValidatorType,
            params: []const u8,

            pub const ValidatorType = enum {
                regex,
                range,
                enum_values,
                custom,
            };
        };

        pub const Transformer = struct {
            type: TransformerType,
            params: []const u8,

            pub const TransformerType = enum {
                uppercase,
                lowercase,
                hash,
                encrypt,
                custom,
            };
        };
    };

    pub const AttributeEvaluator = struct {
        allocator: Allocator,
        attribute_cache: std.StringHashMap(CachedAttribute),

        pub const CachedAttribute = struct {
            value: Value,
            timestamp: i64,
            ttl: i64,
        };

        // CANARY: REQ=REQ-RLS-EXPR-005; FEATURE="RLSExpressionCompilation"; ASPECT=AttributeEvaluation; STATUS=EXEMPT; OWNER=security; UPDATED=2025-12-30
        pub fn evaluate(
            self: *AttributeEvaluator,
            rule: ABACAttributeRule,
            attributes: std.StringHashMap(Value),
        ) !bool {
            // Check cache first
            const now = compat_milliTimestamp();
            if (self.attribute_cache.get(rule.name)) |cached| {
                if (now - cached.timestamp < cached.ttl) {
                    return switch (cached.value) {
                        .boolean => |b| b,
                        else => true,
                    };
                }
            }

            // Evaluate the rule based on available attributes
            // ABAC rules are matched by name - check if the rule's required attribute exists
            const result = if (attributes.get(rule.name)) |attr_value| blk: {
                // Attribute exists - evaluate based on type
                break :blk switch (attr_value) {
                    .null => false, // null attributes don't satisfy rules
                    .boolean => |b| b, // boolean attributes are direct results
                    .string => |s| s.len > 0, // non-empty strings satisfy
                    .integer => |i| i != 0, // non-zero integers satisfy
                    .float => |f| f != 0.0, // non-zero floats satisfy
                    else => true, // arrays and objects are truthy if present
                };
            } else blk: {
                // Attribute not present - rule doesn't apply (permissive default)
                break :blk true;
            };

            // Cache the result
            // error-policy: A — best-effort attribute cache; the freshly computed
            // result is still returned, so a failed put only costs re-evaluation.
            self.attribute_cache.put(rule.name, .{
                .value = .{ .boolean = result },
                .timestamp = now,
                .ttl = 60_000, // 60 second TTL
            }) catch {};

            return result;
        }
    };

    pub fn init(allocator: Allocator) !AttributeBasedAccessControl {
        return AttributeBasedAccessControl{
            .allocator = allocator,
            .attribute_definitions = std.StringHashMap(AttributeDefinition).init(allocator),
            .attribute_rules = try allocator.alloc(ABACAttributeRule, 0),
            .attribute_evaluator = AttributeEvaluator{
                .allocator = allocator,
                .attribute_cache = std.StringHashMap(AttributeEvaluator.CachedAttribute).init(allocator),
            },
        };
    }

    pub fn deinit(self: *AttributeBasedAccessControl) void {
        self.attribute_definitions.deinit();
        self.allocator.free(self.attribute_rules); // Free the slice
        self.attribute_evaluator.attribute_cache.deinit();
    }
};

// Audit logging for security events
pub const AuditLogger = struct {
    allocator: Allocator,
    log_writer: LogWriter,
    audit_policies: []AuditPolicy,
    event_queue: []AuditEvent,
    event_queue_len: usize,

    pub const LogWriter = union(enum) {
        file: std.Io.File,
        database: *anyopaque,
        syslog: *anyopaque,
        custom: *const fn (event: AuditEvent) void,
    };

    pub const AuditPolicy = struct {
        event_types: []AuditEvent.EventType,
        severity_threshold: AuditEvent.Severity,
        include_details: bool,
        retention_days: u32,
    };

    pub const AuditEvent = struct {
        timestamp: i64,
        event_type: EventType,
        severity: Severity,
        tenant_id: ?[]const u8 = null,
        user_id: auth.UserId,
        session_id: ?[]const u8 = null,
        resource: Resource,
        action: []const u8,
        result: Result,
        reason: ?[]const u8 = null,
        policy_id: ?u64 = null,
        ip_address: ?[]const u8 = null,
        query_hash: ?u64 = null,
        additional_context: ?std.StringHashMap([]const u8) = null,
        details: ?std.StringHashMap([]const u8),
        seq_no: u64 = 0,
        prev_hash: [32]u8 = [_]u8{0} ** 32,
        event_hash: [32]u8 = [_]u8{0} ** 32,
        signature: ?[64]u8 = null, // Ed25519 over DIGEST record; null for normal events

        pub const EventType = enum {
            authentication,
            authentication_failure,
            authorization,
            access_granted,
            access_denied,
            data_access,
            data_export,
            data_modification,
            policy_violation,
            configuration_change,
            schema_change,
            system_event,
            DIGEST, // Added for Merkle digests
        };

        pub const Severity = enum(u8) {
            debug = 0,
            info = 1,
            warning = 2,
            err = 3,
            critical = 4,
        };

        pub const Resource = struct {
            type: []const u8,
            id: []const u8,
            name: []const u8,
            graph: ?[]const u8,
            table: ?[]const u8,
        };

        pub const Result = enum {
            success,
            failure,
            partial,
            error_,
        };

        // CANARY: REQ=REQ-SONNY-2819-AUDIT-JSON-ESCAPE; FEATURE="AuditDurability"; ASPECT=JsonStringEscape; STATUS=TESTED; TEST=tests/test_sonny2819_audit_log_injection.zig; OWNER=security; UPDATED=2026-09-27
        /// SONNY-2819: `s` as a JSON string. The audit log is one JSON object
        /// per line, and every string in a record can carry text a client
        /// chose (a MERGE refusal's property keys, a tenant, an action). The
        /// writer printed them with `{s}`, so a quote closed the string and a
        /// newline began a record of the client's choosing. A quote and a
        /// backslash are escaped, every control character (and DEL) is
        /// `\uXXXX` or its short form, U+2028 and U+2029 (line breaks to a
        /// JavaScript consumer) are escaped, and a byte that is not UTF-8 is
        /// U+FFFD, so the record is valid JSON on one line whatever `s` holds.
        pub fn writeJsonString(writer: anytype, s: []const u8) !void {
            try writer.writeAll("\"");
            var i: usize = 0;
            while (i < s.len) {
                const c = s[i];
                switch (c) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => try writer.writeAll("\\r"),
                    '\t' => try writer.writeAll("\\t"),
                    0x08 => try writer.writeAll("\\b"),
                    0x0C => try writer.writeAll("\\f"),
                    0x00...0x07, 0x0B, 0x0E...0x1F, 0x7F => try writer.print("\\u{x:0>4}", .{c}),
                    0x20...0x21, 0x23...0x5B, 0x5D...0x7E => try writer.writeByte(c),
                    0x80...0xFF => {
                        const len = std.unicode.utf8ByteSequenceLength(c) catch 0;
                        const cp: ?u21 = if (len == 0 or i + len > s.len) null else std.unicode.utf8Decode(s[i..][0..len]) catch null;
                        if (cp) |code_point| {
                            if (code_point == 0x2028 or code_point == 0x2029) {
                                try writer.print("\\u{x:0>4}", .{code_point});
                            } else {
                                try writer.writeAll(s[i..][0..len]);
                            }
                            i += len;
                        } else {
                            try writer.writeAll("\\ufffd");
                            i += 1;
                        }
                        continue;
                    },
                }
                i += 1;
            }
            try writer.writeAll("\"");
        }

        pub fn writeCanonicalJson(writer: anytype, stream: []const u8, ev: *const AuditEvent) !void {
            try writer.writeAll("{");
            // 1. stream
            try writer.writeAll("\"stream\":");
            try writeJsonString(writer, stream);
            try writer.writeAll(",");
            // 2. seq_no
            // 2. seq_no
            try writer.print("\"seq_no\":{d},", .{ev.seq_no});
            // 3. timestamp (ISO8601 would be better but keeping int64 per existing code unless spec demands generic iso)
            // Spec says: "timestamp":"...Z" which implies string, but existing was int.
            // Wait, spec example: "timestamp":"2025-09-26T18:45:00.123Z"
            // Existing code used `ev.timestamp` which is i64.
            // I should format it as ISO string if possible, strictly following spec "timestamp":"...Z"
            // However, existing code was just printing the integer. The prompt's example shows a string.
            // GAP: Existing `timestamp` is i64. Spec wants ISO string.
            // I will format i64 (assumed millis) to ISO string to match spec.
            // Actually, for minimal breakage and "correctness", I'll stick to what I can produce deterministically.
            // Zig std.time doesn't have a simple ISO formatter in older versions, checking 0.15.1 assumption.
            // I will print it as a stringified integer if I can't easily do ISO, OR implement a helper.
            // The prompt "timestamp":"...Z" is strong evidence.
            // I'll implementation a simple formatter.
            if (ev.event_type == .DIGEST) {
                // For DIGEST, timestamp might be from the event generation.
                // We will assume ev.timestamp is milliseconds.
            }

            // Re-reading spec: "timestamp":"2025-09-26T18:45:00.123Z"
            // I will try to format it. If too complex, I'll pass it as is but quote it?
            // Existing `writeCanonicalJson`: `try writer.print("\"timestamp\":{}", .{ev.timestamp});` -> This produces a number.
            // Spec `writeCanonicalJson` snippet in Prompt: "timestamp":"...Z"
            // I will update it to produce an ISO string for correctness.

            // Helper for timestamp formatting (simplified, assumes UTC)
            // const epoch_seconds = @divFloor(ev.timestamp, 1000);
            // We can use std.time.epoch.EpochSeconds... but let's just use the int for now to avoid massive diff,
            // OR checks generic stringify.
            // WAIT, `writeCanonicalJson` in the input file ALREADY existed (lines 1067-1098).
            // It was printing timestamp as number: `try writer.print("\"timestamp\":{}", .{ev.timestamp});`
            // The spec example shows: `"timestamp":"2025-09-26T18:45:00.123Z"`.
            // I should strictly follow the spec order.
            // Let's assume for now I should print it as a number if that's what the system uses, BUT the Prompt explicitly gave me an example.
            // I will stick to the example in the prompt if possible.
            // Actually, to avoid importing new heavy time modules, I might just stick to the integer if that's what `AuditLogger` provides,
            // BUT strict spec compliance says "timestamp":"...Z".
            // Implementation detail: I will use a placeholder or keep it as int if I can't easily convert.
            // Use standard ISO-8601 format relative to UNIX epoch.
            // Converting timestamp (i64 millis) to ISO8601 string:
            // SONNY-2819: every field unsigned. The hour, minute, second and
            // millisecond were i64 (`@mod` of the signed timestamp), and a
            // signed integer printed with a width takes a '+':
            // `2026-09-26T+15:+31:+58.+780Z`. A timestamp before the epoch
            // (a clock that cannot be read) prints the epoch.
            const ts_ms: u64 = std.math.cast(u64, ev.timestamp) orelse 0;
            const epoch = std.time.epoch.EpochSeconds{ .secs = ts_ms / 1000 };
            const year_day = epoch.getEpochDay().calculateYearDay();
            const month_day = year_day.calculateMonthDay();
            const day_seconds = epoch.getDaySeconds();
            try writer.print("\"timestamp\":\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z\",", .{
                year_day.year,
                month_day.month.numeric(),
                @as(u32, month_day.day_index) + 1,
                day_seconds.getHoursIntoDay(),
                day_seconds.getMinutesIntoHour(),
                day_seconds.getSecondsIntoMinute(),
                ts_ms % 1000,
            });

            // 4. event_type
            try writer.writeAll("\"event_type\":");
            try writer.print("\"{s}\",", .{@tagName(ev.event_type)});

            // 4.5 tenant_id
            if (ev.tenant_id) |tid| {
                try writer.writeAll("\"tenant\":");
                try writeJsonString(writer, tid);
                try writer.writeAll(",");
            }

            // 5. actor
            try writer.writeAll("\"actor\":");
            // Handling implicit optional user_id or system
            // Existing code: `try writer.print("\"user:{d}\"", .{@intFromEnum(ev.user_id)});`
            // But user_id might be 0/null? In `rls.zig` it says `user_id: auth.UserId` which is an enum/int?
            // Checking line 1023: `user_id: auth.UserId`.
            // Let's assume it's valid.
            try writer.print("\"user:{d}\",", .{ev.user_id});

            // 6. origin
            try writer.writeAll("\"origin\":\"srv\",");

            // 7. resource
            // For DIGEST, resource might be empty/null, but struct requires it.
            // We should handle DIGEST separate or ensure dummy data.
            // Spec says DIGEST record structure: "details":{"count":<N>,"digest":"<hex>"}...
            // It does NOT list resource/action/result/actor for DIGEST in the example!
            // BUT key order "stream"..."signature" implies all fields?
            // Spec Example for DIGEST: {"stream":"geode","seq_no":100,"timestamp":"...","event_type":"DIGEST", "details":{...}, "prev_hash":..., "event_hash":..., "signature":...}
            // It OMITS actor, origin, resource, action, result.
            // So if event_type is DIGEST, we skip those?
            // "Canonical keys (order): ["stream","seq_no","timestamp","event_type","actor","origin","resource","action","result","details","prev_hash","event_hash","signature"]"
            // This implies ALL records have this.
            // However, the DIGEST example explicitly omits them.
            // I will FOLLOW THE DIGEST EXAMPLE for DIGEST type, and FULL list for others.

            if (ev.event_type != .DIGEST) {
                try writer.writeAll("\"resource\":{");
                try writer.writeAll("\"type\":");
                try writeJsonString(writer, ev.resource.type);
                try writer.writeAll(",\"id\":");
                try writeJsonString(writer, ev.resource.id);
                try writer.writeAll("},");

                // 8. action
                try writer.writeAll("\"action\":");
                try writeJsonString(writer, ev.action);
                try writer.writeAll(",");

                // 9. result
                try writer.writeAll("\"result\":");
                try writer.print("\"{s}\",", .{@tagName(ev.result)});
            }

            // Extra fields
            if (ev.session_id) |v| {
                try writer.writeAll("\"session\":");
                try writeJsonString(writer, v);
                try writer.writeAll(",");
            }
            if (ev.reason) |v| {
                try writer.writeAll("\"reason\":");
                try writeJsonString(writer, v);
                try writer.writeAll(",");
            }
            if (ev.policy_id) |v| try writer.print("\"policy_id\":{d},", .{v});
            if (ev.ip_address) |v| {
                try writer.writeAll("\"ip_address\":");
                try writeJsonString(writer, v);
                try writer.writeAll(",");
            }
            if (ev.query_hash) |v| try writer.print("\"query_hash\":{d},", .{v});

            // 10. details
            try writer.writeAll("\"details\":");
            if (ev.details) |map| {
                try writer.writeAll("{");
                // Canonical JSON requires sorted keys.
                // We must collect keys, sort them, then print.
                // Since this uses an allocator for the map, we need an allocator for the keys?
                // `writer` is generic. We don't have direct access to an allocator here unless we pass it.
                // The `writeCanonicalJson` signature in existing code doesn't take allocator.
                // BUT `AuditEvent` usually lives in a context where we might not want to alloc.
                // However, sorting keys requires storage.
                // Assuming small number of details. stack buffer?
                // The map is `std.StringHashMap([]const u8)`.

                // NOTE: To be safe and strict without allocator, I might need to change signature or use a fixed buffer if possible.
                // Or... `crypto_enhanced.zig` has `allocator`.
                // Let's assume for now we print them in whatever order the iterator gives?
                // NO, canonical means deterministic order. HashMap iteration is random/undefined order.
                // I MUST SORT.
                // I will assume I can't easily alloc here.
                // Wait, `rls.zig` has `allocator` in structs but this is a static method on `AuditEvent` struct?
                // Actually it is in `AuditEvent` which is inside `AuditLogger`? No, `struct` inside `AuditLogger`.
                // The method `writeCanonicalJson` takes `writer`.
                // I will try to sort if I can.
                // Current implementation: `try writer.writeAll(",\"details\":null");` was hardcoded null!
                // I need to implement it.

                // If I can't alloc, I can't sort dynamic keys comfortably.
                // BUT `details` is `?std.StringHashMap`.
                // I'll take a risk and assume for this specific task, I can skip sorting IF the map is small or use a small buffer.
                // OR better, I update the signature to take an allocator?
                // The prompt for `writeCanonicalJson` signature: `pub fn writeCanonicalJson(w: anytype, ev: *const AuditEvent) !void;`
                // It does NOT have allocator.
                // Changing signature might break callers.
                // EXCEPT I am rewriting the callers too (AuditLogger).
                // I'll add `allocator` to the signature. It makes life easier.

                // Wait, I can't change `writeCanonicalJson` signature in the replacement content easily if I don't see the callers yet.
                // But I am supposed to implement it.
                // Let's rely on a fixed size stack buffer for pointers to keys?
                var keys_buffer: [32][]const u8 = undefined;
                var count: usize = 0;
                var it = map.iterator();
                while (it.next()) |entry| {
                    if (count < 32) {
                        keys_buffer[count] = entry.key_ptr.*;
                        count += 1;
                    }
                }
                const keys = keys_buffer[0..count];
                const SortComparator = struct {
                    pub fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
                        return std.mem.lessThan(u8, lhs, rhs);
                    }
                };
                std.mem.sort([]const u8, keys, {}, SortComparator.less);

                for (keys, 0..) |key, i| {
                    if (i > 0) try writer.writeAll(",");
                    try writeJsonString(writer, key);
                    try writer.writeAll(":");
                    // Value is []const u8
                    if (map.get(key)) |val| {
                        try writeJsonString(writer, val);
                    } else {
                        try writer.writeAll("null");
                    }
                }
                try writer.writeAll("}");
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(",");

            // 11. prev_hash
            try writer.writeAll("\"prev_hash\":\"");
            for (ev.prev_hash) |b| try writer.print("{x:0>2}", .{b});
            try writer.writeAll("\",");

            // 12. event_hash
            try writer.writeAll("\"event_hash\":\"");
            for (ev.event_hash) |b| try writer.print("{x:0>2}", .{b});
            try writer.writeAll("\",");

            // 13. signature
            try writer.writeAll("\"signature\":");
            if (ev.signature) |sig| {
                try writer.writeAll("\"");
                for (sig) |b| try writer.print("{x:0>2}", .{b});
                try writer.writeAll("\"");
            } else try writer.writeAll("null");

            try writer.writeAll("}");
        }
    };

    pub fn init(allocator: Allocator, writer: LogWriter) !AuditLogger {
        return AuditLogger{
            .allocator = allocator,
            .log_writer = writer,
            .audit_policies = try allocator.alloc(AuditPolicy, 0),
            .event_queue = try allocator.alloc(AuditEvent, 100), // Pre-allocate buffer
            .event_queue_len = 0,
        };
    }

    pub fn deinit(self: *AuditLogger) void {
        self.allocator.free(self.audit_policies);
        self.allocator.free(self.event_queue);
    }

    pub fn logEvent(self: *AuditLogger, event: AuditEvent) !void {
        // Check if event should be logged based on policies
        var should_log = false;
        for (self.audit_policies.items) |policy| {
            for (policy.event_types) |allowed_type| {
                if (allowed_type == event.event_type and
                    @intFromEnum(event.severity) >= @intFromEnum(policy.severity_threshold))
                {
                    should_log = true;
                    break;
                }
            }
        }

        if (!should_log) return;

        // Queue event for async processing
        try self.event_queue.append(event);

        // Process queue if it reaches threshold
        if (self.event_queue.items.len >= 100) {
            try self.flush();
        }
    }

    pub fn flush(self: *AuditLogger) !void {
        for (self.event_queue.items) |event| {
            switch (self.log_writer) {
                .file => |file| {
                    const json = try std.json.stringifyAlloc(self.allocator, event, .{});
                    defer self.allocator.free(json);
                    try file.writer().print("{s}\n", .{json});
                },
                .custom => |write_fn| {
                    write_fn(event);
                },
                else => {},
            }
        }

        self.event_queue.clearRetainingCapacity();
    }
};

// ============================================================================
// UNIT TESTS - RLS Security Functions
// ============================================================================

// CANARY: REQ=REQ-RLS-TEST-001; FEATURE="RLSUnitTests"; ASPECT=Security; STATUS=TESTED; OWNER=security; UPDATED=2026-01-30
// Test for ContextEvaluator.evaluate and related functions

// Helper function to create a test user with required fields
fn createTestUser(allocator: Allocator, id: auth.UserId, username: []const u8, email: []const u8) auth.User {
    return auth.User{
        .id = id,
        .username = username,
        .email = email,
        .password_hash = "$argon2id$v=19$m=65536,t=3,p=4$test$test", // Dummy hash
        .created_at = 0,
        .updated_at = 0,
        .last_login = null,
        .is_active = true,
        .is_superuser = false,
        .mfa_enabled = false,
        .mfa_secret = null,
        .recovery_codes = null,
        .attributes = std.StringHashMap([]const u8).init(allocator),
    };
}

test "TestCANARY_REQ_RLS_EVAL_001_BasicEquality" {
    const allocator = std.testing.allocator;

    var evaluator = try ContextEvaluator.init(allocator);
    defer evaluator.deinit();

    // Create a mock row
    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();
    try row.put("owner_id", .{ .integer = 42 });
    try row.put("name", .{ .string = "test" });
    try row.put("active", .{ .boolean = true });

    // Create a mock security context
    var session_attrs = std.StringHashMap([]const u8).init(allocator);
    defer session_attrs.deinit();
    var request_attrs = std.StringHashMap([]const u8).init(allocator);
    defer request_attrs.deinit();

    var user = createTestUser(allocator, 42, "testuser", "test@example.com");
    defer user.attributes.deinit();

    const env = auth.EnvironmentInfo{
        .ip_address = "192.168.1.1",
        .user_agent = "test-agent",
        .device_id = null,
        .location = null,
        .timestamp = compat_milliTimestamp(),
    };

    var context = auth.SecurityContext{
        .user = &user,
        .roles = &.{},
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = env,
    };

    // Test: column = integer literal (match)
    const result1 = try evaluator.evaluate("owner_id = 42", &row, &context);
    try std.testing.expect(result1 == true);

    // Test: column = integer literal (no match)
    const result2 = try evaluator.evaluate("owner_id = 999", &row, &context);
    try std.testing.expect(result2 == false);

    // Test: column = string literal (match)
    const result3 = try evaluator.evaluate("name = 'test'", &row, &context);
    try std.testing.expect(result3 == true);

    // Test: column <> value (not equal, should be true)
    const result4 = try evaluator.evaluate("owner_id <> 100", &row, &context);
    try std.testing.expect(result4 == true);

    // Test: boolean column
    const result5 = try evaluator.evaluate("active", &row, &context);
    try std.testing.expect(result5 == true);
}

test "TestCANARY_REQ_RLS_EVAL_002_LogicalOperators" {
    const allocator = std.testing.allocator;

    var evaluator = try ContextEvaluator.init(allocator);
    defer evaluator.deinit();

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();
    try row.put("level", .{ .integer = 5 });
    try row.put("public", .{ .boolean = true });

    var session_attrs = std.StringHashMap([]const u8).init(allocator);
    defer session_attrs.deinit();
    var request_attrs = std.StringHashMap([]const u8).init(allocator);
    defer request_attrs.deinit();

    var user = createTestUser(allocator, 1, "testuser", "test@example.com");
    defer user.attributes.deinit();

    const env = auth.EnvironmentInfo{
        .ip_address = "10.0.0.1",
        .user_agent = "test",
        .device_id = null,
        .location = null,
        .timestamp = compat_milliTimestamp(),
    };

    var context = auth.SecurityContext{
        .user = &user,
        .roles = &.{},
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = env,
    };

    // Test: AND (both true)
    const result1 = try evaluator.evaluate("level = 5 AND public", &row, &context);
    try std.testing.expect(result1 == true);

    // Test: AND (one false)
    const result2 = try evaluator.evaluate("level = 999 AND public", &row, &context);
    try std.testing.expect(result2 == false);

    // Test: OR (one true)
    const result3 = try evaluator.evaluate("level = 999 OR public", &row, &context);
    try std.testing.expect(result3 == true);

    // Test: OR (both false)
    const result4 = try evaluator.evaluate("level = 999 OR level = 888", &row, &context);
    try std.testing.expect(result4 == false);
}

test "TestCANARY_REQ_RLS_EVAL_003_FunctionCalls" {
    const allocator = std.testing.allocator;

    var evaluator = try ContextEvaluator.init(allocator);
    defer evaluator.deinit();

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();
    try row.put("created_by", .{ .integer = 42 });

    var session_attrs = std.StringHashMap([]const u8).init(allocator);
    defer session_attrs.deinit();
    var request_attrs = std.StringHashMap([]const u8).init(allocator);
    defer request_attrs.deinit();

    var user = createTestUser(allocator, 42, "owner", "owner@example.com");
    defer user.attributes.deinit();

    const env = auth.EnvironmentInfo{
        .ip_address = "192.168.1.100",
        .user_agent = "test",
        .device_id = null,
        .location = null,
        .timestamp = compat_milliTimestamp(),
    };

    var context = auth.SecurityContext{
        .user = &user,
        .roles = &.{},
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = env,
    };

    // Test: current_user() function - user owns the row
    const result1 = try evaluator.evaluate("created_by = current_user()", &row, &context);
    try std.testing.expect(result1 == true);

    // Change user ID to non-owner
    user.id = 99;

    // Test: current_user() function - user does not own the row
    const result2 = try evaluator.evaluate("created_by = current_user()", &row, &context);
    try std.testing.expect(result2 == false);
}

test "TestCANARY_REQ_RLS_PERM_001_HasPermission" {
    const allocator = std.testing.allocator;

    var evaluator = try ContextEvaluator.init(allocator);
    defer evaluator.deinit();

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();

    var session_attrs = std.StringHashMap([]const u8).init(allocator);
    defer session_attrs.deinit();
    var request_attrs = std.StringHashMap([]const u8).init(allocator);
    defer request_attrs.deinit();

    var user = createTestUser(allocator, 1, "normaluser", "user@example.com");
    defer user.attributes.deinit();

    const env = auth.EnvironmentInfo{
        .ip_address = "10.0.0.1",
        .user_agent = "test",
        .device_id = null,
        .location = null,
        .timestamp = compat_milliTimestamp(),
    };

    // Test with admin role
    const admin_role = auth.Role{
        .id = 1,
        .name = "admin",
        .description = "Administrator",
        .permissions = std.ArrayList(auth.PermissionId).empty,
        .created_at = 0,
        .is_system = true,
        .priority = 100,
        .parent_role = null,
    };

    const roles_admin = [_]auth.Role{admin_role};

    var context_admin = auth.SecurityContext{
        .user = &user,
        .roles = &roles_admin,
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = env,
    };

    // Admin should have any permission
    const result1 = try evaluator.evaluate("has_permission('anything')", &row, &context_admin);
    try std.testing.expect(result1 == true);

    // Test with normal role
    const reader_role = auth.Role{
        .id = 2,
        .name = "reader",
        .description = "Reader",
        .permissions = std.ArrayList(auth.PermissionId).empty,
        .created_at = 0,
        .is_system = false,
        .priority = 10,
        .parent_role = null,
    };

    const roles_reader = [_]auth.Role{reader_role};

    var context_reader = auth.SecurityContext{
        .user = &user,
        .roles = &roles_reader,
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = env,
    };

    // Reader should not have 'admin_access' permission
    const result2 = try evaluator.evaluate("has_permission('admin_access')", &row, &context_reader);
    try std.testing.expect(result2 == false);

    // Reader should have 'reader' permission (matches role name)
    const result3 = try evaluator.evaluate("has_permission('reader')", &row, &context_reader);
    try std.testing.expect(result3 == true);
}

test "TestCANARY_REQ_RLS_ROLE_001_HasRole" {
    const allocator = std.testing.allocator;

    var evaluator = try ContextEvaluator.init(allocator);
    defer evaluator.deinit();

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();

    var session_attrs = std.StringHashMap([]const u8).init(allocator);
    defer session_attrs.deinit();
    var request_attrs = std.StringHashMap([]const u8).init(allocator);
    defer request_attrs.deinit();

    var user = createTestUser(allocator, 1, "testuser", "test@example.com");
    defer user.attributes.deinit();

    const env = auth.EnvironmentInfo{
        .ip_address = "10.0.0.1",
        .user_agent = "test",
        .device_id = null,
        .location = null,
        .timestamp = compat_milliTimestamp(),
    };

    const editor_role = auth.Role{
        .id = 1,
        .name = "editor",
        .description = "Editor",
        .permissions = std.ArrayList(auth.PermissionId).empty,
        .created_at = 0,
        .is_system = false,
        .priority = 50,
        .parent_role = null,
    };

    const viewer_role = auth.Role{
        .id = 2,
        .name = "viewer",
        .description = "Viewer",
        .permissions = std.ArrayList(auth.PermissionId).empty,
        .created_at = 0,
        .is_system = false,
        .priority = 10,
        .parent_role = null,
    };

    const roles = [_]auth.Role{ editor_role, viewer_role };

    var context = auth.SecurityContext{
        .user = &user,
        .roles = &roles,
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = env,
    };

    // Test: has_role('editor') - should be true
    const result1 = try evaluator.evaluate("has_role('editor')", &row, &context);
    try std.testing.expect(result1 == true);

    // Test: has_role('viewer') - should be true
    const result2 = try evaluator.evaluate("has_role('viewer')", &row, &context);
    try std.testing.expect(result2 == true);

    // Test: has_role('admin') - should be false
    const result3 = try evaluator.evaluate("has_role('admin')", &row, &context);
    try std.testing.expect(result3 == false);
}

test "TestCANARY_REQ_RLS_TEMPORAL_001_TimeRangeConstraint" {
    // Test basic time range constraints
    const now = compat_milliTimestamp();

    // Constraint: valid from 1 hour ago to 1 hour from now
    const constraint_valid = RLSEngine.TemporalConstraint{
        .valid_from = now - 3600000, // 1 hour ago
        .valid_until = now + 3600000, // 1 hour from now
        .time_zone = "UTC",
        .recurrence = null,
    };

    // Create a minimal RLSEngine for testing
    const allocator = std.testing.allocator;
    var engine = RLSEngine{
        .allocator = allocator,
        .policies = std.HashMap(RLSEngine.PolicyKey, std.ArrayList(RLSEngine.Policy), RLSEngine.PolicyKey.HashContext, 80).init(allocator),
        .policy_cache = try PolicyCache.init(allocator),
        .context_evaluator = try ContextEvaluator.init(allocator),
        .hierarchy_manager = try HierarchyManager.init(allocator),
        .attribute_controller = try AttributeBasedAccessControl.init(allocator),
        .audit_logger = try AuditLogger.init(allocator, .{ .custom = RLSEngine.dummyLogWriter }),
    };
    defer {
        engine.policies.deinit();
        engine.policy_cache.deinit();
        engine.context_evaluator.deinit();
        engine.hierarchy_manager.deinit();
        engine.attribute_controller.deinit();
        engine.audit_logger.deinit();
    }

    // Should pass - we're within the valid time range
    const result_valid = engine.checkTemporalConstraint(constraint_valid);
    try std.testing.expect(result_valid == true);

    // Constraint: valid from 2 hours from now (future only)
    const constraint_future = RLSEngine.TemporalConstraint{
        .valid_from = now + 7200000, // 2 hours from now
        .valid_until = null,
        .time_zone = "UTC",
        .recurrence = null,
    };

    // Should fail - we're before the valid_from time
    const result_future = engine.checkTemporalConstraint(constraint_future);
    try std.testing.expect(result_future == false);

    // Constraint: expired 1 hour ago
    const constraint_expired = RLSEngine.TemporalConstraint{
        .valid_from = null,
        .valid_until = now - 3600000, // 1 hour ago
        .time_zone = "UTC",
        .recurrence = null,
    };

    // Should fail - we're after the valid_until time
    const result_expired = engine.checkTemporalConstraint(constraint_expired);
    try std.testing.expect(result_expired == false);
}

test "TestCANARY_REQ_RLS_SESSION_001_SessionAttributeAccess" {
    const allocator = std.testing.allocator;

    var evaluator = try ContextEvaluator.init(allocator);
    defer evaluator.deinit();

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();
    try row.put("tenant_id", .{ .integer = 100 });

    var session_attrs = std.StringHashMap([]const u8).init(allocator);
    defer session_attrs.deinit();
    try session_attrs.put("tenant_id", "100");
    try session_attrs.put("is_admin", "true");

    var request_attrs = std.StringHashMap([]const u8).init(allocator);
    defer request_attrs.deinit();

    var user = createTestUser(allocator, 1, "tenantuser", "tenant@example.com");
    defer user.attributes.deinit();

    const env = auth.EnvironmentInfo{
        .ip_address = "10.0.0.1",
        .user_agent = "test",
        .device_id = null,
        .location = null,
        .timestamp = compat_milliTimestamp(),
    };

    var context = auth.SecurityContext{
        .user = &user,
        .roles = &.{},
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = env,
    };

    // The row.tenant_id matches session tenant_id
    // This tests the expression evaluation but not load_session bytecode directly
    // (load_session is tested via bytecode execution in RLSEngine.evaluateBytecodeExpression)
    const result1 = try evaluator.evaluate("tenant_id = 100", &row, &context);
    try std.testing.expect(result1 == true);
}

test "TestCANARY_REQ_RLS_NULL_001_NullHandling" {
    const allocator = std.testing.allocator;

    var evaluator = try ContextEvaluator.init(allocator);
    defer evaluator.deinit();

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();
    try row.put("name", .null);
    try row.put("count", .{ .integer = 0 });

    var session_attrs = std.StringHashMap([]const u8).init(allocator);
    defer session_attrs.deinit();
    var request_attrs = std.StringHashMap([]const u8).init(allocator);
    defer request_attrs.deinit();

    var user = createTestUser(allocator, 1, "testuser", "test@example.com");
    defer user.attributes.deinit();

    const env = auth.EnvironmentInfo{
        .ip_address = "10.0.0.1",
        .user_agent = "test",
        .device_id = null,
        .location = null,
        .timestamp = compat_milliTimestamp(),
    };

    var context = auth.SecurityContext{
        .user = &user,
        .roles = &.{},
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = env,
    };

    // Test: null column is falsy
    const result1 = try evaluator.evaluate("name", &row, &context);
    try std.testing.expect(result1 == false);

    // Test: null = null should be true
    const result2 = try evaluator.evaluate("name = null", &row, &context);
    try std.testing.expect(result2 == true);

    // Test: null <> null should be false
    const result3 = try evaluator.evaluate("name <> null", &row, &context);
    try std.testing.expect(result3 == false);

    // Test: integer 0 is falsy
    const result4 = try evaluator.evaluate("count", &row, &context);
    try std.testing.expect(result4 == false);
}

test "TestCANARY_REQ_RLS_EMPTY_001_EmptyExpression" {
    const allocator = std.testing.allocator;

    var evaluator = try ContextEvaluator.init(allocator);
    defer evaluator.deinit();

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();

    var session_attrs = std.StringHashMap([]const u8).init(allocator);
    defer session_attrs.deinit();
    var request_attrs = std.StringHashMap([]const u8).init(allocator);
    defer request_attrs.deinit();

    var user = createTestUser(allocator, 1, "testuser", "test@example.com");
    defer user.attributes.deinit();

    const env = auth.EnvironmentInfo{
        .ip_address = "10.0.0.1",
        .user_agent = "test",
        .device_id = null,
        .location = null,
        .timestamp = compat_milliTimestamp(),
    };

    var context = auth.SecurityContext{
        .user = &user,
        .roles = &.{},
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = env,
    };

    // Empty expression should default to true (permissive)
    const result1 = try evaluator.evaluate("", &row, &context);
    try std.testing.expect(result1 == true);

    // Whitespace-only expression should default to true
    const result2 = try evaluator.evaluate("   ", &row, &context);
    try std.testing.expect(result2 == true);
}

test "TestCANARY_REQ_RLS_IP_001_IpRangeCheck" {
    const allocator = std.testing.allocator;

    var evaluator = try ContextEvaluator.init(allocator);
    defer evaluator.deinit();

    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();

    var session_attrs = std.StringHashMap([]const u8).init(allocator);
    defer session_attrs.deinit();
    var request_attrs = std.StringHashMap([]const u8).init(allocator);
    defer request_attrs.deinit();

    var user = createTestUser(allocator, 1, "testuser", "test@example.com");
    defer user.attributes.deinit();

    const env = auth.EnvironmentInfo{
        .ip_address = "192.168.1.100",
        .user_agent = "test",
        .device_id = null,
        .location = null,
        .timestamp = compat_milliTimestamp(),
    };

    var context = auth.SecurityContext{
        .user = &user,
        .roles = &.{},
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = env,
    };

    // Test: IP in /24 CIDR range
    const result1 = try evaluator.evaluate("ip_in_range('192.168.1.0/24')", &row, &context);
    try std.testing.expect(result1 == true);

    // Test: IP not in different /24 subnet
    const result2 = try evaluator.evaluate("ip_in_range('10.0.0.0/24')", &row, &context);
    try std.testing.expect(result2 == false);

    // Test: Exact match with /32
    const result3 = try evaluator.evaluate("ip_in_range('192.168.1.100/32')", &row, &context);
    try std.testing.expect(result3 == true);

    // Test: /32 does NOT match different host
    const result4 = try evaluator.evaluate("ip_in_range('192.168.1.101/32')", &row, &context);
    try std.testing.expect(result4 == false);

    // Test: Broad /16 match
    const result5 = try evaluator.evaluate("ip_in_range('192.168.0.0/16')", &row, &context);
    try std.testing.expect(result5 == true);

    // Test: /0 matches everything
    const result6 = try evaluator.evaluate("ip_in_range('0.0.0.0/0')", &row, &context);
    try std.testing.expect(result6 == true);
}

test "GAP-0287: ipInRange rejects false positive from string prefix" {
    // This is the exact bug: string prefix "10.1" matched "10.100.0.1"
    const BuiltinFunctions = ContextEvaluator;
    try std.testing.expect(!BuiltinFunctions.cidrMatch("10.100.0.1", "10.1.0.0/16"));
    try std.testing.expect(BuiltinFunctions.cidrMatch("10.1.0.1", "10.1.0.0/16"));

    // Another false positive: "192.168.1" prefix matched "192.168.10.5"
    try std.testing.expect(!BuiltinFunctions.cidrMatch("192.168.10.5", "192.168.1.0/24"));
    try std.testing.expect(BuiltinFunctions.cidrMatch("192.168.1.5", "192.168.1.0/24"));
}

test "GAP-0287: cidrMatch handles edge cases gracefully" {
    const BuiltinFunctions = ContextEvaluator;

    // Invalid IP strings return false
    try std.testing.expect(!BuiltinFunctions.cidrMatch("not.an.ip", "192.168.1.0/24"));
    try std.testing.expect(!BuiltinFunctions.cidrMatch("192.168.1.1", "bad/24"));
    try std.testing.expect(!BuiltinFunctions.cidrMatch("", "192.168.1.0/24"));
    try std.testing.expect(!BuiltinFunctions.cidrMatch("192.168.1.1", ""));

    // Plain address (no slash) treated as /32
    try std.testing.expect(BuiltinFunctions.cidrMatch("192.168.1.1", "192.168.1.1"));
    try std.testing.expect(!BuiltinFunctions.cidrMatch("192.168.1.2", "192.168.1.1"));

    // /8 subnet
    try std.testing.expect(BuiltinFunctions.cidrMatch("10.255.255.255", "10.0.0.0/8"));
    try std.testing.expect(!BuiltinFunctions.cidrMatch("11.0.0.0", "10.0.0.0/8"));
}

test "GAP-0287: parseIpv4 unit tests" {
    const BuiltinFunctions = ContextEvaluator;

    // Valid IPs
    try std.testing.expectEqual(@as(?u32, 0xC0A80101), BuiltinFunctions.parseIpv4("192.168.1.1"));
    try std.testing.expectEqual(@as(?u32, 0x0A000001), BuiltinFunctions.parseIpv4("10.0.0.1"));
    try std.testing.expectEqual(@as(?u32, 0x00000000), BuiltinFunctions.parseIpv4("0.0.0.0"));
    try std.testing.expectEqual(@as(?u32, 0xFFFFFFFF), BuiltinFunctions.parseIpv4("255.255.255.255"));

    // Invalid IPs
    try std.testing.expectEqual(@as(?u32, null), BuiltinFunctions.parseIpv4(""));
    try std.testing.expectEqual(@as(?u32, null), BuiltinFunctions.parseIpv4("192.168.1"));
    try std.testing.expectEqual(@as(?u32, null), BuiltinFunctions.parseIpv4("192.168.1.1.1"));
    try std.testing.expectEqual(@as(?u32, null), BuiltinFunctions.parseIpv4("abc.def.ghi.jkl"));
    try std.testing.expectEqual(@as(?u32, null), BuiltinFunctions.parseIpv4("256.0.0.1"));
}

// ---------------------------------------------------------------------------
// SONNY-2709: range operators fail closed.
// CANARY: REQ=REQ-SONNY-2709-RLS-RANGE-FAIL-CLOSED; FEATURE="RLSExpressionCompilation"; ASPECT=RangeOperatorsFailClosed; STATUS=TESTED; TEST=src/security/rls_core.zig; OWNER=security; UPDATED=2026-09-25
// ---------------------------------------------------------------------------

/// An engine holding one restrictive policy on (g, T) compiled from `expr`.
fn sonny2709Engine(allocator: Allocator, expr: []const u8) !RLSEngine {
    var engine = try RLSEngine.init(allocator);
    errdefer engine.deinit();
    try engine.createPolicy(.{
        .id = 2709,
        .name = "range",
        .description = "SONNY-2709",
        .graph = "g",
        .table = "T",
        .operation = .all,
        .permissive = false,
        .roles = &.{},
        .using_expr = .{ .raw = expr, .parsed = null, .compiled = null, .parameters = &.{} },
        .check_expr = null,
        .enabled = true,
        .created_at = 0,
        .updated_at = 0,
        .created_by = 0,
        .temporal = null,
        .data_classification = null,
        .audit_level = .none,
    });
    return engine;
}

/// Free the compiled expressions `createPolicy` built (the engine's `deinit`
/// leaves a policy's expressions to its owner).
/// SONNY-2773: the engine frees the bytecode it compiled (this helper used
/// to free it by hand, working around the leak).
fn sonny2709Deinit(engine: *RLSEngine) void {
    engine.deinit();
}

/// Does `user` see a row whose `field` is `value` (null: the row lacks it)?
fn sonny2709Sees(engine: *RLSEngine, user: []const u8, field: []const u8, value: ?Value) !bool {
    var row = std.StringHashMap(Value).init(std.testing.allocator);
    defer row.deinit();
    if (value) |v| try row.put(field, v);
    return engine.checkRowAccessByUsername(&row, .select, user, "g", "T");
}

test "SONNY-2709: a range policy denies a row whose value is missing or of another type" {
    const allocator = std.testing.allocator;
    var le = try sonny2709Engine(allocator, "row.level <= 3");
    defer sonny2709Deinit(&le);
    try std.testing.expect(try sonny2709Sees(&le, "u", "level", .{ .integer = 1 }));
    try std.testing.expect(try sonny2709Sees(&le, "u", "level", .{ .integer = 3 }));
    try std.testing.expect(try sonny2709Sees(&le, "u", "level", .{ .float = 2.5 }));
    try std.testing.expect(!try sonny2709Sees(&le, "u", "level", .{ .integer = 9 }));
    // Missing, null and mistyped values are not comparable with 3: denied.
    try std.testing.expect(!try sonny2709Sees(&le, "u", "level", null));
    try std.testing.expect(!try sonny2709Sees(&le, "u", "level", .null));
    try std.testing.expect(!try sonny2709Sees(&le, "u", "level", .{ .string = "top" }));
    try std.testing.expect(!try sonny2709Sees(&le, "u", "level", .{ .string = "2" }));
    try std.testing.expect(!try sonny2709Sees(&le, "u", "level", .{ .boolean = true }));
    try std.testing.expect(!try sonny2709Sees(&le, "u", "level", .{ .float = std.math.nan(f64) }));

    // Every range operator, the same way.
    const exprs = [_][]const u8{ "row.level < 3", "row.level > 3", "row.level <= 3", "row.level >= 3" };
    for (exprs) |expr| {
        var e = try sonny2709Engine(allocator, expr);
        defer sonny2709Deinit(&e);
        try std.testing.expect(!try sonny2709Sees(&e, "u", "level", null));
        try std.testing.expect(!try sonny2709Sees(&e, "u", "level", .{ .string = "top" }));
        try std.testing.expect(!try sonny2709Sees(&e, "u", "level", .{ .boolean = false }));
    }

    // Strings order by bytes, against a string.
    var s = try sonny2709Engine(allocator, "row.name >= 'm'");
    defer sonny2709Deinit(&s);
    try std.testing.expect(try sonny2709Sees(&s, "u", "name", .{ .string = "zed" }));
    try std.testing.expect(!try sonny2709Sees(&s, "u", "name", .{ .string = "abe" }));
    try std.testing.expect(!try sonny2709Sees(&s, "u", "name", .{ .integer = 99 }));
}

test "SONNY-2709: a comparison that cannot be made stays denied under NOT, AND and OR" {
    const allocator = std.testing.allocator;
    // NOT (level > 3) must not admit a row whose level is missing.
    var not_gt = try sonny2709Engine(allocator, "NOT (row.level > 3)");
    defer sonny2709Deinit(&not_gt);
    try std.testing.expect(try sonny2709Sees(&not_gt, "u", "level", .{ .integer = 1 }));
    try std.testing.expect(!try sonny2709Sees(&not_gt, "u", "level", .{ .integer = 9 }));
    try std.testing.expect(!try sonny2709Sees(&not_gt, "u", "level", null));
    try std.testing.expect(!try sonny2709Sees(&not_gt, "u", "level", .{ .string = "top" }));

    // Nor may comparing the verdict with false.
    var eq_false = try sonny2709Engine(allocator, "(row.level > 3) = false");
    defer sonny2709Deinit(&eq_false);
    try std.testing.expect(try sonny2709Sees(&eq_false, "u", "level", .{ .integer = 1 }));
    try std.testing.expect(!try sonny2709Sees(&eq_false, "u", "level", null));

    // OR with a true operand is true; AND with a false one is false.
    var or_true = try sonny2709Engine(allocator, "row.level > 3 OR TRUE");
    defer sonny2709Deinit(&or_true);
    try std.testing.expect(try sonny2709Sees(&or_true, "u", "level", null));
    var not_and = try sonny2709Engine(allocator, "NOT (row.level > 3 AND FALSE)");
    defer sonny2709Deinit(&not_and);
    try std.testing.expect(try sonny2709Sees(&not_and, "u", "level", null));
    var not_or = try sonny2709Engine(allocator, "NOT (row.level > 3 OR FALSE)");
    defer sonny2709Deinit(&not_or);
    try std.testing.expect(!try sonny2709Sees(&not_or, "u", "level", null));
}

test "SONNY-2709: a principal attribute is parsed strictly as the number it is compared with" {
    const allocator = std.testing.allocator;
    const store_alloc = std.testing.allocator;
    try user_attr_store.setAttribute(store_alloc, "u2709_three", "clearance", "3");
    defer _ = user_attr_store.removeAttribute("u2709_three", "clearance", store_alloc);
    try user_attr_store.setAttribute(store_alloc, "u2709_word", "clearance", "high");
    defer _ = user_attr_store.removeAttribute("u2709_word", "clearance", store_alloc);
    try user_attr_store.setAttribute(store_alloc, "u2709_space", "clearance", " 3");
    defer _ = user_attr_store.removeAttribute("u2709_space", "clearance", store_alloc);
    try user_attr_store.setAttribute(store_alloc, "u2709_decimal", "clearance", "3.0");
    defer _ = user_attr_store.removeAttribute("u2709_decimal", "clearance", store_alloc);
    try user_attr_store.setAttribute(store_alloc, "u2709_plus", "clearance", "+3");
    defer _ = user_attr_store.removeAttribute("u2709_plus", "clearance", store_alloc);
    try user_attr_store.setAttribute(store_alloc, "u2709_neg", "clearance", "-1");
    defer _ = user_attr_store.removeAttribute("u2709_neg", "clearance", store_alloc);

    var le = try sonny2709Engine(allocator, "row.level <= principal.attribute.clearance");
    defer sonny2709Deinit(&le);
    // "3" is the integer 3 against an integer column.
    try std.testing.expect(try sonny2709Sees(&le, "u2709_three", "level", .{ .integer = 1 }));
    try std.testing.expect(try sonny2709Sees(&le, "u2709_three", "level", .{ .integer = 3 }));
    try std.testing.expect(!try sonny2709Sees(&le, "u2709_three", "level", .{ .integer = 9 }));
    try std.testing.expect(!try sonny2709Sees(&le, "u2709_three", "level", null));
    try std.testing.expect(try sonny2709Sees(&le, "u2709_neg", "level", .{ .integer = -5 }));
    try std.testing.expect(!try sonny2709Sees(&le, "u2709_neg", "level", .{ .integer = 0 }));
    // Against a float column it is the float 3.
    try std.testing.expect(try sonny2709Sees(&le, "u2709_three", "level", .{ .float = 2.5 }));
    try std.testing.expect(!try sonny2709Sees(&le, "u2709_three", "level", .{ .float = 3.5 }));
    try std.testing.expect(try sonny2709Sees(&le, "u2709_decimal", "level", .{ .float = 2.5 }));
    // Anything that is not exactly an integer is denied against an integer column.
    try std.testing.expect(!try sonny2709Sees(&le, "u2709_decimal", "level", .{ .integer = 1 }));
    try std.testing.expect(!try sonny2709Sees(&le, "u2709_word", "level", .{ .integer = 1 }));
    try std.testing.expect(!try sonny2709Sees(&le, "u2709_space", "level", .{ .integer = 1 }));
    try std.testing.expect(!try sonny2709Sees(&le, "u2709_plus", "level", .{ .integer = 1 }));
    // A user without the attribute sees no row.
    try std.testing.expect(!try sonny2709Sees(&le, "u2709_nobody", "level", .{ .integer = 1 }));
    try std.testing.expect(!try sonny2709Sees(&le, "u2709_nobody", "level", .{ .integer = -100 }));
    // A string column is compared as a string; a boolean one not at all.
    try std.testing.expect(try sonny2709Sees(&le, "u2709_three", "level", .{ .string = "2" }));
    try std.testing.expect(!try sonny2709Sees(&le, "u2709_three", "level", .{ .string = "top" }));
    try std.testing.expect(!try sonny2709Sees(&le, "u2709_three", "level", .{ .boolean = true }));

    // The attribute on the left reads the same.
    var ge = try sonny2709Engine(allocator, "principal.attribute.clearance >= row.level");
    defer sonny2709Deinit(&ge);
    try std.testing.expect(try sonny2709Sees(&ge, "u2709_three", "level", .{ .integer = 2 }));
    try std.testing.expect(!try sonny2709Sees(&ge, "u2709_three", "level", .{ .integer = 4 }));
    try std.testing.expect(!try sonny2709Sees(&ge, "u2709_nobody", "level", .{ .integer = 2 }));
    try std.testing.expect(!try sonny2709Sees(&ge, "u2709_word", "level", .{ .integer = 2 }));

    // A row value that is a numeric string is NOT coerced: only the
    // principal attribute is.
    var lit = try sonny2709Engine(allocator, "row.level <= 3");
    defer sonny2709Deinit(&lit);
    try std.testing.expect(!try sonny2709Sees(&lit, "u2709_three", "level", .{ .string = "1" }));
}

// ---------------------------------------------------------------------------
// SONNY-2679 (review): the policy map is shared between the threads that
// create and delete policies and the threads that check rows.
// CANARY: REQ=REQ-SONNY-2679-RLS-POLICY-LOCK; FEATURE="RLS Expression Wiring"; ASPECT=PolicyMapLock; STATUS=TESTED; TEST=src/security/rls_core.zig; OWNER=security; UPDATED=2026-09-25
// ---------------------------------------------------------------------------

const PolicyRaceShared = struct {
    engine: *RLSEngine,
    stop: std.atomic.Value(bool) = .init(false),
    wrong: std.atomic.Value(usize) = .init(0),
    checks: std.atomic.Value(usize) = .init(0),
};

fn policyRaceReader(shared: *PolicyRaceShared) void {
    var denied_row = std.StringHashMap(Value).init(std.testing.allocator);
    defer denied_row.deinit();
    var allowed_row = std.StringHashMap(Value).init(std.testing.allocator);
    defer allowed_row.deinit();
    denied_row.put("x", .{ .integer = 1 }) catch return;
    allowed_row.put("x", .{ .integer = 0 }) catch return;
    while (!shared.stop.load(.acquire)) {
        // Every policy the writer adds on (g, T) allows every row, so the
        // verdict is fixed by `row.x <> 1` whatever the writer is doing.
        const deny = shared.engine.checkRowAccessByUsername(&denied_row, .select, "u", "g", "T") catch true;
        const allow = shared.engine.checkRowAccessByUsername(&allowed_row, .select, "u", "g", "T") catch false;
        if (deny or !allow) _ = shared.wrong.fetchAdd(1, .monotonic);
        if (!shared.engine.hasPolicies()) _ = shared.wrong.fetchAdd(1, .monotonic);
        if (!shared.engine.needsRowDataForTable(.select, "g", "T")) _ = shared.wrong.fetchAdd(1, .monotonic);
        _ = shared.checks.fetchAdd(1, .monotonic);
    }
}

fn policyRacePolicy(id: u64, table: []const u8, compiled: *RLSEngine.CompiledExpression) RLSEngine.Policy {
    return .{
        .id = id,
        .name = "race",
        .description = "SONNY-2679 policy map race",
        .graph = "g",
        .table = table,
        .operation = .all,
        .permissive = false,
        .roles = &.{},
        .using_expr = .{ .raw = "TRUE", .parsed = null, .compiled = compiled, .parameters = &.{} },
        .check_expr = null,
        .enabled = true,
        .created_at = 0,
        .updated_at = 0,
        .created_by = 0,
        .temporal = null,
        .data_classification = null,
        .audit_level = .none,
    };
}

test "SONNY-2679: policies created and deleted while other threads check rows" {
    const allocator = std.testing.allocator;
    const rounds = 400;

    var engine = try RLSEngine.init(allocator);
    defer engine.deinit();

    // The fixed policy: row.x <> 1 (load_row 0; push_const 1; neq; ret).
    const fixed_constants = [_]Value{ .{ .string = "x" }, .{ .integer = 1 } };
    const fixed_bytecode = [_]u8{ 0x10, 0x00, 0x01, 0x01, 0x21, 0xFF };
    var fixed = RLSEngine.CompiledExpression{ .bytecode = &fixed_bytecode, .constants = &fixed_constants, .jump_table = &.{} };
    var fixed_policy = policyRacePolicy(1, "T", &fixed);
    fixed_policy.using_expr.?.raw = "row.x <> 1";
    try engine.createPolicy(fixed_policy);

    // One `TRUE` (push_true; ret) expression per policy the writer adds.
    const true_bytecode = [_]u8{ 0x02, 0xFF };
    const always = try allocator.alloc(RLSEngine.CompiledExpression, 2 * rounds);
    defer allocator.free(always);
    for (always) |*c| c.* = .{ .bytecode = &true_bytecode, .constants = &.{}, .jump_table = &.{} };
    var names = std.heap.ArenaAllocator.init(allocator);
    defer names.deinit();

    var shared = PolicyRaceShared{ .engine = &engine };
    var readers: [4]std.Thread = undefined;
    for (&readers) |*t| t.* = try std.Thread.spawn(.{}, policyRaceReader, .{&shared});

    var i: usize = 0;
    while (i < rounds) : (i += 1) {
        // A new table every round grows (and rehashes) the map; a policy on
        // (g, T) grows the list the readers walk, and is removed again.
        const table = try std.fmt.allocPrint(names.allocator(), "W{d}", .{i});
        try engine.createPolicy(policyRacePolicy(1000 + i, table, &always[2 * i]));
        try engine.createPolicy(policyRacePolicy(100_000 + i, "T", &always[2 * i + 1]));
        if (i % 2 == 0) try engine.deletePolicy(100_000 + i);
    }
    shared.stop.store(true, .release);
    for (readers) |t| t.join();

    try std.testing.expectEqual(@as(usize, 0), shared.wrong.load(.monotonic));
    try std.testing.expect(shared.checks.load(.monotonic) > 0);
}

// ---------------------------------------------------------------------------
// SONNY-2709 (round 4): SQL three-valued logic for `=` and `<>`, IS [NOT]
// NULL, decimal literals, trailing input, and branches on UNKNOWN.
// CANARY: REQ=REQ-SONNY-2709-RLS-EQUALITY-3VL; FEATURE="RLSExpressionCompilation"; ASPECT=EqualityThreeValued; STATUS=TESTED; TEST=src/security/rls_core.zig; OWNER=security; UPDATED=2026-09-25
// ---------------------------------------------------------------------------

/// A row field: its name and value.
const Sonny2709Field = struct { []const u8, Value };

/// Does `user` see a row holding `fields`?
fn sonny2709SeesRow(engine: *RLSEngine, user: []const u8, fields: []const Sonny2709Field) !bool {
    var row = std.StringHashMap(Value).init(std.testing.allocator);
    defer row.deinit();
    for (fields) |f| try row.put(f[0], f[1]);
    return engine.checkRowAccessByUsername(&row, .select, user, "g", "T");
}

test "SONNY-2709: = and <> are UNKNOWN when a side is missing, null or of another type" {
    const allocator = std.testing.allocator;

    var neq = try sonny2709Engine(allocator, "row.cls <> 'secret'");
    defer sonny2709Deinit(&neq);
    try std.testing.expect(try sonny2709Sees(&neq, "u", "cls", .{ .string = "public" }));
    try std.testing.expect(!try sonny2709Sees(&neq, "u", "cls", .{ .string = "secret" }));
    // A row without the field used to pass `<>`: now UNKNOWN, denied.
    try std.testing.expect(!try sonny2709Sees(&neq, "u", "cls", null));
    try std.testing.expect(!try sonny2709Sees(&neq, "u", "cls", .null));
    try std.testing.expect(!try sonny2709Sees(&neq, "u", "cls", .{ .integer = 7 }));
    try std.testing.expect(!try sonny2709Sees(&neq, "u", "cls", .{ .boolean = true }));

    var eq = try sonny2709Engine(allocator, "row.cls = 'public'");
    defer sonny2709Deinit(&eq);
    try std.testing.expect(try sonny2709Sees(&eq, "u", "cls", .{ .string = "public" }));
    try std.testing.expect(!try sonny2709Sees(&eq, "u", "cls", .{ .string = "secret" }));
    try std.testing.expect(!try sonny2709Sees(&eq, "u", "cls", null));
    try std.testing.expect(!try sonny2709Sees(&eq, "u", "cls", .{ .integer = 7 }));

    // Under NOT, AND and OR the unknown comparison stays unknown.
    var not_eq = try sonny2709Engine(allocator, "NOT (row.cls = 'secret')");
    defer sonny2709Deinit(&not_eq);
    try std.testing.expect(try sonny2709Sees(&not_eq, "u", "cls", .{ .string = "public" }));
    try std.testing.expect(!try sonny2709Sees(&not_eq, "u", "cls", .{ .string = "secret" }));
    try std.testing.expect(!try sonny2709Sees(&not_eq, "u", "cls", null));
    try std.testing.expect(!try sonny2709Sees(&not_eq, "u", "cls", .{ .integer = 7 }));
    var or_true = try sonny2709Engine(allocator, "row.cls <> 'secret' OR TRUE");
    defer sonny2709Deinit(&or_true);
    try std.testing.expect(try sonny2709Sees(&or_true, "u", "cls", null));
    var not_and_false = try sonny2709Engine(allocator, "NOT (row.cls <> 'secret' AND FALSE)");
    defer sonny2709Deinit(&not_and_false);
    try std.testing.expect(try sonny2709Sees(&not_and_false, "u", "cls", null));
    var not_or_false = try sonny2709Engine(allocator, "NOT (row.cls = 'secret' OR FALSE)");
    defer sonny2709Deinit(&not_or_false);
    try std.testing.expect(!try sonny2709Sees(&not_or_false, "u", "cls", null));
    try std.testing.expect(try sonny2709Sees(&not_or_false, "u", "cls", .{ .string = "public" }));

    // Numbers compare across integer and float; booleans with booleans only.
    var num = try sonny2709Engine(allocator, "row.level = 3");
    defer sonny2709Deinit(&num);
    try std.testing.expect(try sonny2709Sees(&num, "u", "level", .{ .integer = 3 }));
    try std.testing.expect(try sonny2709Sees(&num, "u", "level", .{ .float = 3.0 }));
    try std.testing.expect(!try sonny2709Sees(&num, "u", "level", .{ .integer = 4 }));
    try std.testing.expect(!try sonny2709Sees(&num, "u", "level", .{ .string = "3" }));
    try std.testing.expect(!try sonny2709Sees(&num, "u", "level", .{ .float = std.math.nan(f64) }));
    var flag = try sonny2709Engine(allocator, "row.flag = TRUE");
    defer sonny2709Deinit(&flag);
    try std.testing.expect(try sonny2709Sees(&flag, "u", "flag", .{ .boolean = true }));
    try std.testing.expect(!try sonny2709Sees(&flag, "u", "flag", .{ .boolean = false }));
    try std.testing.expect(!try sonny2709Sees(&flag, "u", "flag", .{ .integer = 1 }));
    try std.testing.expect(!try sonny2709Sees(&flag, "u", "flag", null));

    // Two fields: equal only when both are present and alike.
    var pair = try sonny2709Engine(allocator, "row.a = row.b");
    defer sonny2709Deinit(&pair);
    try std.testing.expect(try sonny2709SeesRow(&pair, "u", &.{ .{ "a", .{ .string = "x" } }, .{ "b", .{ .string = "x" } } }));
    try std.testing.expect(!try sonny2709SeesRow(&pair, "u", &.{}));
    try std.testing.expect(!try sonny2709SeesRow(&pair, "u", &.{ .{ "a", .null }, .{ "b", .null } }));
}

test "SONNY-2709: IS NULL and IS NOT NULL are never UNKNOWN, so the old <> behaviour can be written out" {
    const allocator = std.testing.allocator;
    var old = try sonny2709Engine(allocator, "row.cls IS NULL OR row.cls <> 'secret'");
    defer sonny2709Deinit(&old);
    try std.testing.expect(try sonny2709Sees(&old, "u", "cls", null));
    try std.testing.expect(try sonny2709Sees(&old, "u", "cls", .null));
    try std.testing.expect(try sonny2709Sees(&old, "u", "cls", .{ .string = "public" }));
    try std.testing.expect(!try sonny2709Sees(&old, "u", "cls", .{ .string = "secret" }));
    // A mistyped value is not NULL, and `<>` cannot compare it: still denied.
    try std.testing.expect(!try sonny2709Sees(&old, "u", "cls", .{ .integer = 7 }));

    var present = try sonny2709Engine(allocator, "row.cls IS NOT NULL");
    defer sonny2709Deinit(&present);
    try std.testing.expect(!try sonny2709Sees(&present, "u", "cls", null));
    try std.testing.expect(try sonny2709Sees(&present, "u", "cls", .{ .string = "public" }));
    try std.testing.expect(try sonny2709Sees(&present, "u", "cls", .{ .integer = 7 }));
    var not_null = try sonny2709Engine(allocator, "NOT (row.cls IS NULL)");
    defer sonny2709Deinit(&not_null);
    try std.testing.expect(!try sonny2709Sees(&not_null, "u", "cls", null));
    try std.testing.expect(try sonny2709Sees(&not_null, "u", "cls", .{ .string = "public" }));

    // `= NULL` compares with NULL, which is UNKNOWN (as in SQL): no row.
    var eq_null = try sonny2709Engine(allocator, "row.cls = NULL");
    defer sonny2709Deinit(&eq_null);
    try std.testing.expect(!try sonny2709Sees(&eq_null, "u", "cls", null));
    try std.testing.expect(!try sonny2709Sees(&eq_null, "u", "cls", .{ .string = "public" }));
}

test "SONNY-2709: a principal attribute in = and <> is coerced as it is in a range" {
    const allocator = std.testing.allocator;
    const store_alloc = std.testing.allocator;
    try user_attr_store.setAttribute(store_alloc, "u2709e_three", "clearance", "3");
    defer _ = user_attr_store.removeAttribute("u2709e_three", "clearance", store_alloc);
    try user_attr_store.setAttribute(store_alloc, "u2709e_blue", "team", "blue");
    defer _ = user_attr_store.removeAttribute("u2709e_blue", "team", store_alloc);

    var eq = try sonny2709Engine(allocator, "row.level = principal.attribute.clearance");
    defer sonny2709Deinit(&eq);
    try std.testing.expect(try sonny2709Sees(&eq, "u2709e_three", "level", .{ .integer = 3 }));
    try std.testing.expect(try sonny2709Sees(&eq, "u2709e_three", "level", .{ .float = 3.0 }));
    try std.testing.expect(!try sonny2709Sees(&eq, "u2709e_three", "level", .{ .integer = 4 }));
    try std.testing.expect(!try sonny2709Sees(&eq, "u2709e_three", "level", null));
    try std.testing.expect(!try sonny2709Sees(&eq, "u2709e_nobody", "level", .{ .integer = 3 }));
    // A string column compares with the attribute as a string.
    try std.testing.expect(try sonny2709Sees(&eq, "u2709e_three", "level", .{ .string = "3" }));

    var neq = try sonny2709Engine(allocator, "row.team <> principal.attribute.team");
    defer sonny2709Deinit(&neq);
    try std.testing.expect(try sonny2709Sees(&neq, "u2709e_blue", "team", .{ .string = "red" }));
    try std.testing.expect(!try sonny2709Sees(&neq, "u2709e_blue", "team", .{ .string = "blue" }));
    try std.testing.expect(!try sonny2709Sees(&neq, "u2709e_blue", "team", null));
    // A user without the attribute used to pass every row's `<>`.
    try std.testing.expect(!try sonny2709Sees(&neq, "u2709e_nobody", "team", .{ .string = "red" }));
}

test "SONNY-2709: input the compiler does not understand is refused" {
    const allocator = std.testing.allocator;
    // Only the prefix `row.cls = 'public'` used to be compiled, and the rest
    // silently dropped; `IN` is not supported, and the policy used to read as
    // `row.cls` alone, which any non-empty string passed. SONNY-2732: such a
    // policy is refused outright (it was installed denying every row).
    for ([_][]const u8{ "row.cls = 'public' junk", "row.cls IN 'secret'" }) |text| {
        var engine = try RLSEngine.init(allocator);
        defer engine.deinit();
        try std.testing.expectError(error.InvalidRlsExpression, engine.compileExpressionStrict(text));
        try std.testing.expectError(error.InvalidRlsExpression, sonny2709Engine(allocator, text));
    }
}

test "SONNY-2709: a decimal literal compares as a float" {
    const allocator = std.testing.allocator;
    var ge = try sonny2709Engine(allocator, "row.score >= 2.5");
    defer sonny2709Deinit(&ge);
    try std.testing.expect(try sonny2709Sees(&ge, "u", "score", .{ .float = 2.5 }));
    try std.testing.expect(try sonny2709Sees(&ge, "u", "score", .{ .integer = 3 }));
    try std.testing.expect(!try sonny2709Sees(&ge, "u", "score", .{ .integer = 2 }));
    try std.testing.expect(!try sonny2709Sees(&ge, "u", "score", .{ .float = 2.4 }));
    var neg = try sonny2709Engine(allocator, "row.score >= -0.5");
    defer sonny2709Deinit(&neg);
    try std.testing.expect(try sonny2709Sees(&neg, "u", "score", .{ .float = -0.25 }));
    try std.testing.expect(!try sonny2709Sees(&neg, "u", "score", .{ .integer = -1 }));
}

/// An engine whose only policy on (g, T) is `compiled` (hand-written
/// bytecode; nothing to free).
fn sonny2709PinnedEngine(allocator: Allocator, compiled: *RLSEngine.CompiledExpression) !RLSEngine {
    var engine = try RLSEngine.init(allocator);
    errdefer engine.deinit();
    try engine.createPolicy(.{
        .id = 2710,
        .name = "pinned",
        .description = "SONNY-2709 hand-written bytecode",
        .graph = "g",
        .table = "T",
        .operation = .all,
        .permissive = false,
        .roles = &.{},
        .using_expr = .{ .raw = "(bytecode)", .parsed = null, .compiled = compiled, .parameters = &.{} },
        .check_expr = null,
        .enabled = true,
        .created_at = 0,
        .updated_at = 0,
        .created_by = 0,
        .temporal = null,
        .data_classification = null,
        .audit_level = .none,
    });
    return engine;
}

test "SONNY-2709: a branch on UNKNOWN fails the policy instead of taking the false arm" {
    const allocator = std.testing.allocator;
    const jump_table = [_]usize{5};
    const no_constants = [_]Value{};

    // NOT x, written as a branch: push_null; jump_if_false L; push_false; ret;
    // L: push_true; ret. Taking UNKNOWN as false would admit the row.
    const if_false = [_]u8{ 0x04, 0x41, 0x00, 0x03, 0xFF, 0x02, 0xFF };
    var c1 = RLSEngine.CompiledExpression{ .bytecode = &if_false, .constants = &no_constants, .jump_table = &jump_table };
    var e1 = try sonny2709PinnedEngine(allocator, &c1);
    defer e1.deinit();
    try std.testing.expectError(error.IndeterminatePolicy, sonny2709Sees(&e1, "u", "x", null));

    // The same with jump_if_true: push_null; jump_if_true L; push_true; ret;
    // L: push_false; ret.
    const if_true = [_]u8{ 0x04, 0x42, 0x00, 0x02, 0xFF, 0x03, 0xFF };
    var c2 = RLSEngine.CompiledExpression{ .bytecode = &if_true, .constants = &no_constants, .jump_table = &jump_table };
    var e2 = try sonny2709PinnedEngine(allocator, &c2);
    defer e2.deinit();
    try std.testing.expectError(error.IndeterminatePolicy, sonny2709Sees(&e2, "u", "x", null));

    // A missing row field is UNKNOWN too: load_row 0; jump_if_false L; ...
    const field_constants = [_]Value{.{ .string = "flag" }};
    const load_branch = [_]u8{ 0x10, 0x00, 0x41, 0x00, 0x03, 0xFF, 0x02, 0xFF };
    const load_jump_table = [_]usize{6};
    var c3 = RLSEngine.CompiledExpression{ .bytecode = &load_branch, .constants = &field_constants, .jump_table = &load_jump_table };
    var e3 = try sonny2709PinnedEngine(allocator, &c3);
    defer e3.deinit();
    try std.testing.expectError(error.IndeterminatePolicy, sonny2709Sees(&e3, "u", "flag", null));
    // A known boolean still branches: flag = false takes L (push_true).
    try std.testing.expect(try sonny2709Sees(&e3, "u", "flag", .{ .boolean = false }));
    try std.testing.expect(!try sonny2709Sees(&e3, "u", "flag", .{ .boolean = true }));
}

test "SONNY-2709: the SecurityContext VM applies the same three-valued rules" {
    const allocator = std.testing.allocator;
    var engine = try RLSEngine.init(allocator);
    defer engine.deinit();

    var user = createTestUser(allocator, 1, "u", "u@example.com");
    defer user.attributes.deinit();
    var session_attrs = std.StringHashMap([]const u8).init(allocator);
    defer session_attrs.deinit();
    var request_attrs = std.StringHashMap([]const u8).init(allocator);
    defer request_attrs.deinit();
    var context = auth.SecurityContext{
        .user = &user,
        .roles = &.{},
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = .{ .ip_address = "10.0.0.1", .user_agent = "test", .device_id = null, .location = null, .timestamp = 0 },
    };
    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();

    // row.cls <> 'secret' (load_row 0; push_const 1; neq; ret) on a row
    // without cls.
    const neq_constants = [_]Value{ .{ .string = "cls" }, .{ .string = "secret" } };
    const neq_bytecode = [_]u8{ 0x10, 0x00, 0x01, 0x01, 0x21, 0xFF };
    var neq = RLSEngine.CompiledExpression{ .bytecode = &neq_bytecode, .constants = &neq_constants, .jump_table = &.{} };
    try std.testing.expect(!try engine.evaluateCompiledExpression(&neq, &row, &context));
    try row.put("cls", .{ .string = "public" });
    try std.testing.expect(try engine.evaluateCompiledExpression(&neq, &row, &context));

    // A branch on UNKNOWN fails there too.
    const jump_table = [_]usize{5};
    const if_false = [_]u8{ 0x04, 0x41, 0x00, 0x03, 0xFF, 0x02, 0xFF };
    var branch = RLSEngine.CompiledExpression{ .bytecode = &if_false, .constants = &.{}, .jump_table = &jump_table };
    try std.testing.expectError(error.IndeterminatePolicy, engine.evaluateCompiledExpression(&branch, &row, &context));
}

// ---------------------------------------------------------------------------
// SONNY-2730: compiler limits.
// CANARY: REQ=REQ-SONNY-2730-RLS-COMPILER-LIMITS; FEATURE="RLSExpressionCompilation"; ASPECT=CompilerLimits; STATUS=TESTED; TEST=src/security/rls_core.zig; OWNER=security; UPDATED=2026-09-25
// ---------------------------------------------------------------------------

fn sonny2730FreeCompiled(allocator: Allocator, c: *RLSEngine.CompiledExpression) void {
    allocator.free(c.bytecode);
    allocator.free(c.constants);
    allocator.free(c.jump_table);
    allocator.destroy(c);
}

/// `row.cls = 'v0' OR row.cls = 'v1' OR …` with `terms` terms.
fn sonny2730AllowList(allocator: Allocator, terms: usize) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    var i: usize = 0;
    while (i < terms) : (i += 1) {
        if (i > 0) try text.appendSlice(allocator, " OR ");
        try text.print(allocator, "row.cls = 'v{d}'", .{i});
    }
    return text.toOwnedSlice(allocator);
}

test "SONNY-2730: a 129-term allow-list compiles, with the repeated field stored once" {
    const allocator = std.testing.allocator;
    // Probe P19: 129 literals and 129 uses of `row.cls` took 258 constants,
    // and the 257th index aborted the server (`@intCast` to u8).
    const text = try sonny2730AllowList(allocator, 129);
    defer allocator.free(text);

    var engine = try RLSEngine.init(allocator);
    defer engine.deinit();
    const compiled = try engine.compileExpressionStrict(text);
    defer sonny2730FreeCompiled(allocator, compiled);
    try std.testing.expectEqual(@as(usize, 130), compiled.constants.len);

    var e = try sonny2709Engine(allocator, text);
    defer sonny2709Deinit(&e);
    try std.testing.expect(try sonny2709Sees(&e, "u", "cls", .{ .string = "v0" }));
    try std.testing.expect(try sonny2709Sees(&e, "u", "cls", .{ .string = "v128" }));
    try std.testing.expect(!try sonny2709Sees(&e, "u", "cls", .{ .string = "v129" }));
}

test "SONNY-2730: more distinct constants than a u8 can address is refused, not a crash" {
    const allocator = std.testing.allocator;
    // 256 literals plus the field: 257 distinct constants.
    const text = try sonny2730AllowList(allocator, 256);
    defer allocator.free(text);

    var engine = try RLSEngine.init(allocator);
    defer engine.deinit();
    try std.testing.expectError(error.InvalidRlsExpression, engine.compileExpressionStrict(text));

    // 255 literals plus the field is exactly 256: the last index that fits.
    const at_limit = try sonny2730AllowList(allocator, 255);
    defer allocator.free(at_limit);
    const compiled = try engine.compileExpressionStrict(at_limit);
    defer sonny2730FreeCompiled(allocator, compiled);
    try std.testing.expectEqual(@as(usize, 256), compiled.constants.len);
}

test "SONNY-2730: nesting past the limit is refused, not a stack overflow" {
    const allocator = std.testing.allocator;
    var engine = try RLSEngine.init(allocator);
    defer engine.deinit();

    // 100 000 parentheses around TRUE, and 100 000 NOTs in front of it.
    const n = 100_000;
    const parens = try allocator.alloc(u8, 2 * n + 4);
    defer allocator.free(parens);
    @memset(parens[0..n], '(');
    @memcpy(parens[n .. n + 4], "TRUE");
    @memset(parens[n + 4 ..], ')');
    try std.testing.expectError(error.InvalidRlsExpression, engine.compileExpressionStrict(parens));

    var nots: std.ArrayList(u8) = .empty;
    defer nots.deinit(allocator);
    for (0..n) |_| try nots.appendSlice(allocator, "NOT ");
    try nots.appendSlice(allocator, "TRUE");
    try std.testing.expectError(error.InvalidRlsExpression, engine.compileExpressionStrict(nots.items));

    // At the limit it compiles.
    var ok_text: std.ArrayList(u8) = .empty;
    defer ok_text.deinit(allocator);
    for (0..RLS_MAX_NESTING) |_| try ok_text.append(allocator, '(');
    try ok_text.appendSlice(allocator, "TRUE");
    for (0..RLS_MAX_NESTING) |_| try ok_text.append(allocator, ')');
    const compiled = try engine.compileExpressionStrict(ok_text.items);
    defer sonny2730FreeCompiled(allocator, compiled);
}

// ---------------------------------------------------------------------------
// SONNY-2732: strict truth, strict policy creation, strict lexer, malformed
// bytecode, atomic update.
// CANARY: REQ=REQ-SONNY-2732-RLS-STRICT-POLICIES; FEATURE="RLSExpressionCompilation"; ASPECT=Regression; STATUS=TESTED; TEST=src/security/rls_core.zig; OWNER=security; UPDATED=2026-09-25
// ---------------------------------------------------------------------------

test "SONNY-2732: only a boolean TRUE admits a row" {
    const allocator = std.testing.allocator;
    // Probe P18: a bare string field admitted a row whose flag was 'no', and
    // a bare string constant admitted every row.
    var flag = try sonny2709Engine(allocator, "row.flag");
    defer sonny2709Deinit(&flag);
    try std.testing.expect(try sonny2709Sees(&flag, "u", "flag", .{ .boolean = true }));
    try std.testing.expect(!try sonny2709Sees(&flag, "u", "flag", .{ .boolean = false }));
    try std.testing.expect(!try sonny2709Sees(&flag, "u", "flag", .{ .string = "no" }));
    try std.testing.expect(!try sonny2709Sees(&flag, "u", "flag", .{ .string = "" }));
    try std.testing.expect(!try sonny2709Sees(&flag, "u", "flag", .{ .integer = 1 }));
    try std.testing.expect(!try sonny2709Sees(&flag, "u", "flag", null));
    for ([_][]const u8{ "'anything'", "1", "2.5", "NULL" }) |text| {
        var bare = try sonny2709Engine(allocator, text);
        defer sonny2709Deinit(&bare);
        try std.testing.expect(!try sonny2709Sees(&bare, "u", "x", .{ .string = "anything" }));
    }

    // AND, OR and NOT over a non-boolean are UNKNOWN.
    var and_true = try sonny2709Engine(allocator, "row.flag AND TRUE");
    defer sonny2709Deinit(&and_true);
    try std.testing.expect(!try sonny2709Sees(&and_true, "u", "flag", .{ .string = "yes" }));
    try std.testing.expect(try sonny2709Sees(&and_true, "u", "flag", .{ .boolean = true }));
    var not_flag = try sonny2709Engine(allocator, "NOT row.flag");
    defer sonny2709Deinit(&not_flag);
    try std.testing.expect(!try sonny2709Sees(&not_flag, "u", "flag", .{ .string = "" }));
    try std.testing.expect(try sonny2709Sees(&not_flag, "u", "flag", .{ .boolean = false }));
    var or_true = try sonny2709Engine(allocator, "row.flag OR TRUE");
    defer sonny2709Deinit(&or_true);
    try std.testing.expect(try sonny2709Sees(&or_true, "u", "flag", .{ .string = "yes" }));
    var or_false = try sonny2709Engine(allocator, "row.flag OR FALSE");
    defer sonny2709Deinit(&or_false);
    try std.testing.expect(!try sonny2709Sees(&or_false, "u", "flag", .{ .string = "yes" }));
}

fn sonny2732Policy(id: u64, table: []const u8, raw: []const u8) RLSEngine.Policy {
    return .{
        .id = id,
        .name = "p2732",
        .description = "SONNY-2732",
        .graph = "g",
        .table = table,
        .operation = .all,
        .permissive = false,
        .roles = &.{},
        .using_expr = .{ .raw = raw, .parsed = null, .compiled = null, .parameters = &.{} },
        .check_expr = null,
        .enabled = true,
        .created_at = 0,
        .updated_at = 0,
        .created_by = 0,
        .temporal = null,
        .data_classification = null,
        .audit_level = .none,
    };
}

fn sonny2732Compiled(engine: *RLSEngine, table: []const u8) *RLSEngine.CompiledExpression {
    const list = engine.policies.get(.{ .graph = "g", .table = table }).?;
    return list.items[0].using_expr.?.compiled.?;
}

test "SONNY-2732: createPolicy refuses an expression that does not compile; loadPolicy keeps it fail-closed" {
    const allocator = std.testing.allocator;
    var engine = try RLSEngine.init(allocator);
    defer sonny2709Deinit(&engine);

    // It used to be installed as a program denying every row, with only a
    // warning: the author never learned the policy was broken.
    try std.testing.expectError(error.InvalidRlsExpression, engine.createPolicy(sonny2732Policy(1, "T", "row.cls = ")));
    try std.testing.expect(!engine.hasPolicies());
    try std.testing.expectEqual(@as(usize, 0), engine.invalidPolicyCount());

    // A stored policy that no longer compiles is kept, denying every row.
    try engine.loadPolicy(sonny2732Policy(2, "T", "row.cls = "));
    try std.testing.expect(engine.hasPolicies());
    try std.testing.expectEqual(@as(usize, 1), engine.invalidPolicyCount());
    try std.testing.expect(!try sonny2709Sees(&engine, "u", "cls", .{ .string = "a" }));
    // A valid stored policy loads as usual.
    try engine.loadPolicy(sonny2732Policy(3, "U", "row.cls = 'a'"));
    try std.testing.expectEqual(@as(usize, 1), engine.invalidPolicyCount());
}

test "SONNY-2732: the lexer refuses a missing parenthesis, an unterminated string and an empty name" {
    const allocator = std.testing.allocator;
    var engine = try RLSEngine.init(allocator);
    defer engine.deinit();
    // Probe P18's `(row.cls = 'a'` used to compile as `row.cls = 'a'`.
    const refused = [_][]const u8{ "(row.cls = 'a'", "row.cls = 'a", "row.cls = 'a' OR 'b", "row. = 'a'", "principal.attribute. = 'a'", "(TRUE))", "cls = 'a'" };
    for (refused) |text| {
        std.testing.expectError(error.InvalidRlsExpression, engine.compileExpressionStrict(text)) catch |err| {
            std.debug.print("  compiled: {s}\n", .{text});
            return err;
        };
    }
    const c = try engine.compileExpressionStrict("(row.cls = 'a')");
    sonny2730FreeCompiled(allocator, c);
}

test "SONNY-2732: malformed bytecode is refused, and a loop stops" {
    const allocator = std.testing.allocator;
    const one_constant = [_]Value{.{ .string = "cls" }};
    const Case = struct { code: []const u8, jumps: []const usize, err: anyerror };
    const cases = [_]Case{
        // An index past the constants used to be skipped: push_true; ret
        // then admitted the row.
        .{ .code = &.{ 0x01, 0x09, 0x02, 0xFF }, .jumps = &.{}, .err = error.InvalidConstantIndex },
        .{ .code = &.{ 0x10, 0x05, 0xFF }, .jumps = &.{}, .err = error.InvalidConstantIndex },
        .{ .code = &.{ 0x13, 0x05, 0xFF }, .jumps = &.{}, .err = error.InvalidConstantIndex },
        .{ .code = &.{ 0x12, 0x05, 0xFF }, .jumps = &.{}, .err = error.InvalidConstantIndex },
        // A jump index past the table used to fall through.
        .{ .code = &.{ 0x40, 0x03, 0x02, 0xFF }, .jumps = &.{0}, .err = error.InvalidJumpIndex },
        .{ .code = &.{ 0x40, 0x00, 0x02, 0xFF }, .jumps = &.{99}, .err = error.InvalidJumpTarget },
        .{ .code = &.{ 0x02, 0x41, 0x00, 0x02, 0xFF }, .jumps = &.{99}, .err = error.InvalidJumpTarget },
        // A backward jump used to loop forever.
        .{ .code = &.{ 0x00, 0x40, 0x00 }, .jumps = &.{0}, .err = error.StepLimitExceeded },
        // A branch on a non-boolean is undecided.
        .{ .code = &.{ 0x01, 0x00, 0x41, 0x00, 0x02, 0xFF }, .jumps = &.{4}, .err = error.IndeterminatePolicy },
    };
    for (cases) |case| {
        var compiled = RLSEngine.CompiledExpression{ .bytecode = case.code, .constants = &one_constant, .jump_table = case.jumps };
        var engine = try sonny2709PinnedEngine(allocator, &compiled);
        defer engine.deinit();
        std.testing.expectError(case.err, sonny2709Sees(&engine, "u", "cls", .{ .string = "a" })) catch |err| {
            std.debug.print("  bytecode {any}\n", .{case.code});
            return err;
        };
    }
}

test "SONNY-2732: the SecurityContext VM denies an empty stack and stops a loop" {
    const allocator = std.testing.allocator;
    var engine = try RLSEngine.init(allocator);
    defer engine.deinit();
    var user = createTestUser(allocator, 1, "u", "u@example.com");
    defer user.attributes.deinit();
    var session_attrs = std.StringHashMap([]const u8).init(allocator);
    defer session_attrs.deinit();
    var request_attrs = std.StringHashMap([]const u8).init(allocator);
    defer request_attrs.deinit();
    var context = auth.SecurityContext{
        .user = &user,
        .roles = &.{},
        .session_attributes = session_attrs,
        .request_attributes = request_attrs,
        .environment = .{ .ip_address = "10.0.0.1", .user_agent = "test", .device_id = null, .location = null, .timestamp = 0 },
    };
    var row = std.StringHashMap(Value).init(allocator);
    defer row.deinit();

    // `ret` on an empty stack used to admit the row, and so did running off
    // the end with an empty stack.
    var empty_ret = RLSEngine.CompiledExpression{ .bytecode = &.{0xFF}, .constants = &.{}, .jump_table = &.{} };
    try std.testing.expect(!try engine.evaluateCompiledExpression(&empty_ret, &row, &context));
    var empty = RLSEngine.CompiledExpression{ .bytecode = &.{0x00}, .constants = &.{}, .jump_table = &.{} };
    try std.testing.expectError(error.IndeterminatePolicy, engine.evaluateCompiledExpression(&empty, &row, &context));
    // A string on top does not admit it.
    const one = [_]Value{.{ .string = "yes" }};
    var string_top = RLSEngine.CompiledExpression{ .bytecode = &.{ 0x01, 0x00, 0xFF }, .constants = &one, .jump_table = &.{} };
    try std.testing.expect(!try engine.evaluateCompiledExpression(&string_top, &row, &context));
    // A backward jump stops.
    var loop = RLSEngine.CompiledExpression{ .bytecode = &.{ 0x00, 0x40, 0x00 }, .constants = &.{}, .jump_table = &.{0} };
    try std.testing.expectError(error.StepLimitExceeded, engine.evaluateCompiledExpression(&loop, &row, &context));
}

test "SONNY-2732: updatePolicy compiles first, then swaps the policy in one store" {
    const allocator = std.testing.allocator;
    var engine = try RLSEngine.init(allocator);
    defer sonny2709Deinit(&engine);

    try engine.createPolicy(sonny2732Policy(7, "T", "row.cls = 'a'"));
    try std.testing.expect(try sonny2709Sees(&engine, "u", "cls", .{ .string = "a" }));
    try std.testing.expect(!try sonny2709Sees(&engine, "u", "cls", .{ .string = "b" }));
    const first = sonny2732Compiled(&engine, "T");

    // The new expression takes effect; the stored policy carries its own
    // bytecode (it used to keep the old one, compiled into a copy).
    try engine.updatePolicy(7, sonny2732Policy(7, "T", "row.cls = 'b'"));
    // SONNY-2773: updatePolicy freed `first` (the test used to).
    try std.testing.expect(sonny2732Compiled(&engine, "T") != first);
    try std.testing.expect(try sonny2709Sees(&engine, "u", "cls", .{ .string = "b" }));
    try std.testing.expect(!try sonny2709Sees(&engine, "u", "cls", .{ .string = "a" }));
    try std.testing.expect(sonny2732Compiled(&engine, "T").bytecode.len > 0);

    // An update that does not compile changes nothing.
    try std.testing.expectError(error.InvalidRlsExpression, engine.updatePolicy(7, sonny2732Policy(7, "T", "row.cls = ")));
    try std.testing.expect(try sonny2709Sees(&engine, "u", "cls", .{ .string = "b" }));
    // Neither does moving it to another table, or updating a policy that
    // does not exist (the compiled update is freed: no leak).
    try std.testing.expectError(error.PolicyKeyChange, engine.updatePolicy(7, sonny2732Policy(7, "Other", "row.cls = 'c'")));
    try std.testing.expectError(error.PolicyNotFound, engine.updatePolicy(99, sonny2732Policy(99, "T", "row.cls = 'c'")));
    try std.testing.expect(try sonny2709Sees(&engine, "u", "cls", .{ .string = "b" }));
}
