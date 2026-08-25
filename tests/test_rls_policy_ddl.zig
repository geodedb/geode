// RLS-POLICY-DDL — an RLS/GPS policy whose USING expression does not compile was
// ACCEPTED at DDL time and then denied everything, silently.
//
// VERIFIED READ-ONLY AGAINST v0.8.5 / 13836738 BEFORE THE FIX:
//
//   src/security/policy_catalog.zig:127-130
//       compiled = policy_expression.compileExpression(...) catch null;
//
//   `decide()` treats a null-compiled, non-"true" policy as fail-closed — it
//   never contributes an ALLOW. So a policy the compiler could not parse was
//   stored, reported "Policy created", listed by SHOW POLICIES with its
//   original USING text, and denied every request it was written to permit.
//   The author's only symptom is "my users cannot see anything", with a policy
//   sitting in the catalog that reads exactly like it should work.
//
// WHY THE PREVIOUS "INTENTIONALLY RETAINED" NOTE NO LONGER HOLDS
//
//   The comment removed by this change argued that rejecting compile failures
//   "would break those real policies". It would not: a policy stored with
//   compiled=null already grants nothing. Refusing it at DDL time removes no
//   working behaviour — it only moves the failure from an invisible runtime
//   deny to a visible, actionable authoring error, at the one moment the author
//   can fix it. GAP-0923(a)'s compensating control (fail-closed at decide time)
//   is unchanged and still the backstop.
//
// WHAT THE `catch null` WAS HIDING (found by making the failure loud)
//
//   The USING source capture in src/gql/parser.zig included the TERMINATING
//   SEMICOLON:
//
//     CREATE POLICY p ON GRAPH * FOR READ USING current_user() = 'alice';
//        captured -> "current_user() = 'alice';"   compiles -> NO
//     CREATE POLICY p ON GRAPH * FOR READ USING current_user() = 'alice'
//        captured -> "current_user() = 'alice'"    compiles -> YES
//
//   So EVERY semicolon-terminated CREATE POLICY … USING … — the spelling every
//   script, client and doc example uses — stored compiled=null and silently
//   denied everything, even for a predicate squarely inside the supported
//   subset. Nobody could see it because the compile error was swallowed. Both
//   halves are fixed together, and the semicolon spelling is pinned below.
//
// THE ONE PLACE TOLERANCE IS STILL CORRECT
//
//   Startup hydration from __geode_security. A record persisted before a
//   grammar change must never brick startup, so `hydrateCatalog` keeps the
//   tolerant `addPolicy`: the record is retained fail-closed (compiled=null)
//   and logged loudly. Only DDL gets the hard error. Both halves are pinned
//   below.
//
// WHAT THESE TESTS PIN (contract, not implementation):
//
//   1. addPolicyStrict REFUSES an uncompilable USING expression and leaves the
//      catalog completely untouched (no half-inserted row, no leak).
//   2. The documented literal-comparison subset still compiles and is accepted
//      — current_user()/current_tenant()/current_graph()/resource.label/
//      principal.attributes.<key> = '<literal>', AND / OR / parentheses, and the
//      bare `true` fast path. This is the guard against "fix it by rejecting
//      everything".
//   3. CREATE POLICY … USING <bad> fails end-to-end through the real parser and
//      executor, and CREATE POLICY … USING <good> still succeeds and produces a
//      COMPILED predicate.
//   4. Hydration tolerance: the tolerant path retains the record fail-closed
//      rather than erroring.
//
// CANARY: REQ=REQ-RLS-POLICY-COMPILE-ERROR-AT-DDL; FEATURE="GPS Policy DDL"; ASPECT=CompileErrorSurfaced; STATUS=TESTED; TEST=tests/test_rls_policy_ddl.zig; OWNER=security; UPDATED=2026-08-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const policy_catalog = geode.security.policy_catalog;

fn spec(name: []const u8, expr: []const u8) policy_catalog.PolicySpec {
    const actions = [_]policy_catalog.Action{.read};
    return .{
        .name = name,
        .scope_graph = "*",
        .actions = &actions,
        .effect = .allow,
        .expression_source = expr,
        .enabled = true,
    };
}

/// Expressions the policy predicate compiler cannot compile. Each one used to
/// be ACCEPTED and stored compiled=null.
const uncompilable = [_][]const u8{
    "current_user() = 'x' AND (", // dangling open paren
    "false", // valid GQL, outside the compiled subset
    "user.role == 'admin'", // wrong operator + unsupported operand
    "current_user() != 'x'", // inequality is not in the subset
    "n.owner = current_user()", // row-property comparison is not in the subset
    "current_user() = \"x\"", // double quotes are not a string literal here
    "current_user()", // no comparison at all
    "banana() = 'x'", // unknown builtin
    "current_user() = 'x' OR", // trailing operator
    "1 = 1", // numeric literals are not in the subset
};

/// The documented literal-comparison subset — every one of these MUST keep
/// compiling. This is the anti-"reject everything" guard.
const compilable = [_][]const u8{
    "current_user() = 'alice'",
    "current_tenant() = 'acme'",
    "current_graph() = 'sales'",
    "resource.label = 'Customer'",
    "principal.attributes.department = 'eng'",
    "current_user() = 'alice' AND current_tenant() = 'acme'",
    "current_user() = 'alice' OR current_user() = 'bob'",
    "(current_user() = 'alice' OR current_user() = 'bob') AND current_graph() = 'sales'",
    "true", // the literal-true fast path (stored uncompiled BY DESIGN)
};

test "RLS-POLICY-DDL: addPolicyStrict refuses an uncompilable USING expression and leaves the catalog untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var failures: std.ArrayListUnmanaged([]const u8) = .empty;

    for (uncompilable, 0..) |expr, i| {
        var cat = policy_catalog.PolicyCatalog.init(testing.allocator);
        defer cat.deinit();

        const name = try std.fmt.allocPrint(gpa, "p_bad_{d}", .{i});

        // KEY ASSERTION (RED): every one of these returned success and stored a
        // fail-closed policy.
        if (cat.addPolicyStrict(spec(name, expr))) |_| {
            const stored = cat.listPolicies();
            try failures.append(gpa, try std.fmt.allocPrint(
                gpa,
                "ACCEPTED (expected refusal), catalog now holds {d} policy/policies with compiled={s}: USING {s}",
                .{
                    stored.len,
                    if (stored.len > 0 and stored[0].compiled != null) "SET" else "null(fail-closed)",
                    expr,
                },
            ));
        } else |err| {
            if (err != error.UnsupportedPolicyExpression) {
                try failures.append(gpa, try std.fmt.allocPrint(
                    gpa,
                    "REFUSED with {s} (expected UnsupportedPolicyExpression): USING {s}",
                    .{ @errorName(err), expr },
                ));
            }
            // A refused DDL statement must not leave a partial row behind.
            if (cat.listPolicies().len != 0) {
                try failures.append(gpa, try std.fmt.allocPrint(
                    gpa,
                    "catalog holds {d} policy/policies after a REFUSED add: USING {s}",
                    .{ cat.listPolicies().len, expr },
                ));
            }
        }
    }

    if (failures.items.len != 0) {
        std.debug.print("\n[RLS-POLICY-DDL] {d} policy-DDL contract violation(s):\n", .{failures.items.len});
        for (failures.items) |f| std.debug.print("  - {s}\n", .{f});
        return error.UncompilablePolicyAccepted;
    }
}

test "RLS-POLICY-DDL: the documented literal-comparison subset still compiles and is accepted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var failures: std.ArrayListUnmanaged([]const u8) = .empty;

    for (compilable, 0..) |expr, i| {
        var cat = policy_catalog.PolicyCatalog.init(testing.allocator);
        defer cat.deinit();

        const name = try std.fmt.allocPrint(gpa, "p_ok_{d}", .{i});
        if (cat.addPolicyStrict(spec(name, expr))) |_| {
            const stored = cat.listPolicies();
            if (stored.len != 1) {
                try failures.append(gpa, try std.fmt.allocPrint(
                    gpa,
                    "accepted but catalog holds {d} rows: USING {s}",
                    .{ stored.len, expr },
                ));
                continue;
            }
            // `true` is the literal-true fast path and is stored uncompiled BY
            // DESIGN (decide() short-circuits it); everything else must yield a
            // real compiled predicate, otherwise it is silently fail-closed —
            // exactly the defect this fix exists to prevent.
            const expects_compiled = !std.mem.eql(u8, expr, "true");
            if (expects_compiled and stored[0].compiled == null) {
                try failures.append(gpa, try std.fmt.allocPrint(
                    gpa,
                    "accepted but stored compiled=null (silently fail-closed): USING {s}",
                    .{expr},
                ));
            }
        } else |err| {
            try failures.append(gpa, try std.fmt.allocPrint(
                gpa,
                "REFUSED with {s} (expected acceptance — this is a documented, supported predicate): USING {s}",
                .{ @errorName(err), expr },
            ));
        }
    }

    if (failures.items.len != 0) {
        std.debug.print("\n[RLS-POLICY-DDL] {d} supported-predicate regression(s):\n", .{failures.items.len});
        for (failures.items) |f| std.debug.print("  - {s}\n", .{f});
        return error.SupportedPolicyRefused;
    }
}

test "RLS-POLICY-DDL: hydration stays tolerant — a persisted uncompilable policy is retained fail-closed, not fatal" {
    var cat = policy_catalog.PolicyCatalog.init(testing.allocator);
    defer cat.deinit();

    // The tolerant entry point is what src/security/policy_persistence.zig's
    // hydrateCatalog calls. A record written before a grammar change must NOT
    // abort startup...
    try cat.addPolicy(spec("p_persisted_bad", "current_user() = 'x' AND ("));
    const stored = cat.listPolicies();
    try testing.expectEqual(@as(usize, 1), stored.len);

    // ...and must be kept FAIL-CLOSED: a null-compiled, non-"true" policy never
    // contributes an ALLOW. Retaining it must never be a way to smuggle an
    // uncompilable predicate into an ALLOW.
    try testing.expect(stored[0].compiled == null);
    try testing.expectEqualStrings("current_user() = 'x' AND (", stored[0].expression_source);

    // A compilable record hydrates with a real predicate, so tolerance did not
    // degrade the good path.
    try cat.addPolicy(spec("p_persisted_ok", "current_user() = 'alice'"));
    try testing.expect(cat.listPolicies()[1].compiled != null);
}

// ---------------------------------------------------------------------------
// End-to-end through the real parser and executor.
// ---------------------------------------------------------------------------

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// Serialise against the global PolicyCatalog singleton, exactly as
// tests/test_gps_policy_ddl_integration.zig does.
var test_mutex: std.Io.Mutex = .init;

const DdlHarness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator, cat: *policy_catalog.PolicyCatalog) !DdlHarness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        const exec_catalog = try execution.ensureCatalogInstance(allocator);
        policy_catalog.setGlobalCatalog(cat);

        return .{
            .allocator = allocator,
            .tmp = tmp,
            .data_dir = data_dir,
            // GAP-0911: policy DDL is admin-only. These tests exercise the
            // compile-failure contract, not authorization.
            .ctx = execution.ExecutionContext{ .catalog = exec_catalog, .role = .Admin, .user = "admin" },
        };
    }

    pub fn deinit(self: *DdlHarness) void {
        policy_catalog.setGlobalCatalog(undefined);
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn exec(self: *DdlHarness, query: []const u8) !execution.ExecutionResult {
        var parsed = try geode.parseGql(query, self.allocator);
        defer parsed.deinit();
        return execution.executeStatementWithContext(self.allocator, parsed.program.statements[0], self.ctx);
    }
};

test "RLS-POLICY-DDL: CREATE POLICY … USING <uncompilable> fails end-to-end; a supported one still works" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = testing.allocator;
    var cat = policy_catalog.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try DdlHarness.init(allocator, &cat);
    defer h.deinit();

    // KEY ASSERTION (RED): this returned "Policy created" and installed a
    // policy that denies everything.
    try testing.expectError(
        error.UnsupportedPolicyExpression,
        h.exec("CREATE POLICY p_bad_e2e ON GRAPH * FOR READ USING user.role == 'admin';"),
    );
    try testing.expectEqual(@as(usize, 0), cat.listPolicies().len);

    // A supported predicate is still accepted AND actually compiled.
    //
    // KEY ASSERTION: the trailing SEMICOLON. The USING capture used to include
    // it, so this exact statement — the spelling every script and doc example
    // uses — stored compiled=null and silently denied everything. The
    // `expression_source` assertion below pins that the terminator is not part
    // of the captured predicate.
    var ok = try h.exec("CREATE POLICY p_ok_e2e ON GRAPH * FOR READ USING current_user() = 'alice';");
    defer ok.deinit(allocator);
    try testing.expectEqualStrings("Policy created", ok.rows[0][0].Str);
    try testing.expectEqual(@as(usize, 1), cat.listPolicies().len);
    try testing.expectEqualStrings("current_user() = 'alice'", cat.listPolicies()[0].expression_source);
    try testing.expect(cat.listPolicies()[0].compiled != null);

    // Whitespace before the terminator must be trimmed too.
    var ok_ws = try h.exec("CREATE POLICY p_ok_ws ON GRAPH * FOR READ USING current_tenant() = 'acme' ;");
    defer ok_ws.deinit(allocator);
    try testing.expectEqualStrings("current_tenant() = 'acme'", cat.listPolicies()[1].expression_source);
    try testing.expect(cat.listPolicies()[1].compiled != null);

    // …and the no-terminator spelling, which was the only one that ever worked,
    // must keep working.
    var ok_noterm = try h.exec("CREATE POLICY p_ok_noterm ON GRAPH * FOR READ USING current_graph() = 'sales'");
    defer ok_noterm.deinit(allocator);
    try testing.expectEqualStrings("current_graph() = 'sales'", cat.listPolicies()[2].expression_source);
    try testing.expect(cat.listPolicies()[2].compiled != null);

    // A policy with no USING clause at all is the unconditional "true"
    // predicate and must keep working — the fix must not have made the USING
    // clause mandatory.
    var bare = try h.exec("CREATE POLICY p_bare_e2e ON GRAPH * FOR READ;");
    defer bare.deinit(allocator);
    try testing.expectEqualStrings("Policy created", bare.rows[0][0].Str);
    try testing.expectEqual(@as(usize, 4), cat.listPolicies().len);
    try testing.expectEqualStrings("true", cat.listPolicies()[3].expression_source);
}
