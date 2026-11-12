// SONNY-2756 (P23): the GPS policy catalog is read on every request while a
// policy change on another connection changes it.
//
// `gps.decide` walks the catalog on every read and write a handler gates (a
// deny scan, then an allow scan), and so do `denyOnAnyGraph` / `denyOnGraph`,
// SHOW POLICIES, `geode.auth.policy_list`, SHOW GRANTS FOR and the policy DDL
// itself. CREATE / ALTER (RENAME, SET ENABLED) / DROP POLICY, the CREATE
// POLICY rollback, hydration, grant retirement and
// `disableAllowPoliciesWithPrefix` append to, rename in and remove-and-free
// from the same list. The catalog had no lock: a reader could walk a list
// being reallocated, read a policy's strings after they were freed, or see
// the deny scan and the allow scan of one decision run against two different
// catalogs, so a decision matched no catalog that ever existed.
//
// Deterministic proofs pause a decision inside `decide` (the per-graph grant
// lookup, `execution.graph_grant_check_fn`, runs between the deny scan and the
// allow scan) or hold the catalog's lock from the test, and check the other
// side cannot finish within a bound and finishes after the release. The
// stress test runs real decisions, helpers and SHOW POLICIES against rounds of
// real policy DDL under `std.testing.allocator`, which catches leaks and
// double frees and makes most reads of freed memory visible (the freed bytes
// are overwritten), but is not a sanitizer: a clean run is evidence, not
// proof. (ThreadSanitizer is not usable with this toolchain: `zig test
// -fsanitize-thread` links no TSan runtime and reports no race, even a
// trivial one.)
//
// CANARY: REQ=REQ-SONNY-2756-POLICY-CATALOG-LOCK; FEATURE="GPS Policy Evaluation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2756_policy_catalog_concurrency.zig; OWNER=security; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const gps = geode.security.gps;
const principal_mod = geode.security.principal;
const policy_catalog = geode.security.policy_catalog;
const decision_cache = geode.security.decision_cache;
const PolicyCatalog = policy_catalog.PolicyCatalog;
const Kind = gps.PolicyDecisionKind;

const io = std.Io.Threaded.global_single_threaded.io();

// The catalog, the grant hook and the decision cache are process globals.
var test_mutex: std.Io.Mutex = .init;

fn sleepMs(ms: u64) void {
    io.sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

/// Wait up to `ms` for `flag`; true when it was set.
fn waitFor(flag: *const std.atomic.Value(bool), ms: u64) bool {
    var waited: u64 = 0;
    while (waited < ms) : (waited += 1) {
        if (flag.load(.acquire)) return true;
        sleepMs(1);
    }
    return flag.load(.acquire);
}

fn principal(username: []const u8, roles: []const []const u8, auth_version: u64) principal_mod.Principal {
    return .{
        .user_id = null,
        .username = username,
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = roles,
        .custom_roles = &.{},
        .auth_method = .password,
        .auth_version = auth_version,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .test_harness,
    };
}

const no_role = [_][]const u8{"None"};
const admin_role = [_][]const u8{"Admin"};
const rw_role = [_][]const u8{"ReadWrite"};
const read_action = [_]policy_catalog.Action{.read};

fn decideKind(p: *const principal_mod.Principal, action: gps.Action, resource: gps.ResourceRef) !Kind {
    const req = gps.DecisionRequest{ .principal = p, .action = action, .resource = resource };
    return (try gps.decide(testing.allocator, &req)).kind;
}

fn spec(name: []const u8, effect: policy_catalog.Effect) policy_catalog.PolicySpec {
    return .{ .name = name, .scope_graph = "g", .actions = &read_action, .effect = effect, .expression_source = "true", .enabled = true };
}

// ---------------------------------------------------------------------------
// A decision paused between its deny scan and its allow scan.
// ---------------------------------------------------------------------------

const Pause = struct {
    var entered: std.atomic.Value(bool) = .init(false);
    var go: std.atomic.Value(bool) = .init(false);

    fn reset() void {
        entered.store(false, .release);
        go.store(false, .release);
    }

    /// `execution.graph_grant_check_fn`: decide calls it after the deny scan
    /// and before the allow scan. Grants nothing.
    fn grantCheck(username: []const u8, graph_name: []const u8, action: u8) bool {
        _ = graph_name;
        _ = action;
        if (!std.mem.eql(u8, username, "nora")) return false;
        entered.store(true, .release);
        _ = waitFor(&go, 10_000);
        return false;
    }
};

const PausedReader = struct {
    kind: Kind = .indeterminate,
    failed: bool = false,

    fn run(self: *PausedReader) void {
        const p = principal("nora", &no_role, 0);
        self.kind = decideKind(&p, .match_, .{ .graph = "g" }) catch {
            self.failed = true;
            return;
        };
    }
};

const DenyThenAllow = struct {
    cat: *PolicyCatalog,
    done: std.atomic.Value(bool) = .init(false),
    failed: bool = false,

    fn run(self: *DenyThenAllow) void {
        self.cat.addPolicyStrict(spec("d", .deny)) catch {
            self.failed = true;
        };
        self.cat.addPolicyStrict(spec("a", .allow)) catch {
            self.failed = true;
        };
        self.done.store(true, .release);
    }
};

test "SONNY-2756: a policy change waits for a decision in progress, and the decision matches one catalog" {
    test_mutex.lockUncancelable(io);
    defer test_mutex.unlock(io);

    var cat = PolicyCatalog.init(testing.allocator);
    defer cat.deinit();
    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();
    const saved_grant = execution.graph_grant_check_fn;
    execution.graph_grant_check_fn = &Pause.grantCheck;
    defer execution.graph_grant_check_fn = saved_grant;
    Pause.reset();

    // nora (no stored role) asks to read g: no deny (the catalog is empty),
    // and decide pauses in the grant lookup before its allow scan.
    var reader: PausedReader = .{};
    const rt = try std.Thread.spawn(.{}, PausedReader.run, .{&reader});
    try testing.expect(waitFor(&Pause.entered, 5_000));

    // Meanwhile another connection adds a deny on g, then an allow on g. In
    // every catalog that ever exists, an allow on g comes with the deny.
    var writer: DenyThenAllow = .{ .cat = &cat };
    const wt = try std.Thread.spawn(.{}, DenyThenAllow.run, .{&writer});
    sleepMs(200);
    const changed_under_decision = writer.done.load(.acquire);

    Pause.go.store(true, .release);
    rt.join();
    wt.join();

    try testing.expect(!reader.failed);
    try testing.expect(!writer.failed);
    if (changed_under_decision) {
        std.debug.print("the policy changes completed while a decision was walking the catalog\n", .{});
    }
    if (reader.kind == .allow) {
        std.debug.print("decide allowed: its deny scan saw the catalog before the deny, its allow scan the one after the allow\n", .{});
    }
    // The catalog states were {}, {d} and {d, a}: unauthorized, deny, deny.
    try testing.expect(!changed_under_decision);
    try testing.expect(reader.kind == .unauthorized or reader.kind == .deny);
    // After both, nora is denied.
    const p = principal("nora", &no_role, 0);
    try testing.expectEqual(Kind.deny, try decideKind(&p, .match_, .{ .graph = "g" }));
}

// ---------------------------------------------------------------------------
// No cached decision outlives the policy change that changed it.
// ---------------------------------------------------------------------------

const CacheHammer = struct {
    stop: std.atomic.Value(bool) = .init(false),
    failed: bool = false,
    decisions: u64 = 0,

    fn run(self: *CacheHammer) void {
        const p = principal("rita", &rw_role, 7);
        while (!self.stop.load(.acquire)) {
            _ = decideKind(&p, .match_, .{ .graph = "g" }) catch {
                self.failed = true;
                return;
            };
            self.decisions += 1;
        }
    }
};

test "SONNY-2756: once a deny is added no decision returns the old allow from the cache, and once it is dropped none returns the deny" {
    test_mutex.lockUncancelable(io);
    defer test_mutex.unlock(io);

    var cat = PolicyCatalog.init(testing.allocator);
    defer cat.deinit();
    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();
    var cache = decision_cache.DecisionCache.init(testing.allocator, 1024);
    defer cache.deinit();
    decision_cache.setGlobalCache(&cache);
    defer decision_cache.clearGlobalCache();

    // Other threads keep computing and caching rita's decision on g.
    var hammers: [3]CacheHammer = .{ .{}, .{}, .{} };
    var threads: [3]std.Thread = undefined;
    for (&hammers, 0..) |*h, i| threads[i] = try std.Thread.spawn(.{}, CacheHammer.run, .{h});
    defer {
        for (&hammers) |*h| h.stop.store(true, .release);
        for (threads) |t| t.join();
    }

    const p = principal("rita", &rw_role, 7);
    var round: usize = 0;
    while (round < 300) : (round += 1) {
        try testing.expectEqual(Kind.allow, try decideKind(&p, .match_, .{ .graph = "g" }));
        try cat.addPolicyStrict(spec("no_reads_g", .deny));
        try testing.expectEqual(Kind.deny, try decideKind(&p, .match_, .{ .graph = "g" }));
        try cat.removePolicy("no_reads_g");
        try testing.expectEqual(Kind.allow, try decideKind(&p, .match_, .{ .graph = "g" }));
        try cat.addPolicyStrict(spec("no_reads_g2", .deny));
        try cat.alterPolicy("no_reads_g2", false, null);
        try testing.expectEqual(Kind.allow, try decideKind(&p, .match_, .{ .graph = "g" }));
        try cat.alterPolicy("no_reads_g2", true, "no_reads_g3");
        try testing.expectEqual(Kind.deny, try decideKind(&p, .match_, .{ .graph = "g" }));
        try cat.removePolicy("no_reads_g3");
    }
    for (&hammers) |*h| try testing.expect(!h.failed);
}

// ---------------------------------------------------------------------------
// Stress: decisions, helpers and SHOW POLICIES against rounds of policy DDL.
// ---------------------------------------------------------------------------

// Zig 0.16 compat: build an absolute tmp path without realpathAlloc.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// An executor with a store and an Admin context, as
/// tests/test_gps_policy_ddl_integration.zig.
const Harness = struct {
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    fn init(self: *Harness) !void {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.data_dir = try tmpDirRealpathAlloc(testing.allocator, &self.tmp.sub_path);
        errdefer testing.allocator.free(self.data_dir);
        graph_store.setDataDirOverride(testing.allocator, self.data_dir);
        _ = graph_store.getGlobalStore(testing.allocator);
        const exec_catalog = try execution.ensureCatalogInstance(testing.allocator);
        self.ctx = .{ .catalog = exec_catalog, .role = .Admin, .user = "admin" };
    }

    fn deinit(self: *Harness) void {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        var parsed = try geode.parseGql(query, testing.allocator);
        defer parsed.deinit();
        return execution.executeStatementWithContext(testing.allocator, parsed.program.statements[0], self.ctx);
    }

    fn run(self: *Harness, query: []const u8) !void {
        var res = try self.exec(query);
        res.deinit(testing.allocator);
    }
};

const Stress = struct {
    h: *Harness,
    cat: *PolicyCatalog,
    stop: std.atomic.Value(bool) = .init(false),
    bad: std.atomic.Value(u32) = .init(0),
    decisions: std.atomic.Value(u64) = .init(0),
    listings: std.atomic.Value(u64) = .init(0),

    fn fail(self: *Stress, comptime fmt: []const u8, args: anytype) void {
        if (self.bad.fetchAdd(1, .acq_rel) < 5) std.debug.print(fmt ++ "\n", args);
    }

    /// The writer keeps one invariant between its changes: an enabled allow
    /// on g exists only while an enabled deny on g does. So nora (no stored
    /// role) reading g is denied or unauthorized in every catalog, never
    /// allowed.
    fn writer(self: *Stress, rounds: usize) void {
        defer self.stop.store(true, .release);
        var buf: [256]u8 = undefined;
        var i: usize = 0;
        while (i < rounds) : (i += 1) {
            self.writerRound(&buf, i) catch |err| {
                self.fail("policy change round {d} failed: {s}", .{ i, @errorName(err) });
                return;
            };
        }
    }

    fn writerRound(self: *Stress, buf: []u8, i: usize) !void {
        const h = self.h;
        const d = try std.fmt.bufPrint(buf[0..32], "D_{d}", .{i});
        try self.cat.addPolicyStrict(spec(d, .deny));
        try h.run(try std.fmt.bufPrint(buf[64..], "CREATE POLICY A_{d} ON GRAPH g FOR READ;", .{i}));
        try h.run(try std.fmt.bufPrint(buf[64..], "ALTER POLICY A_{d} RENAME TO A_{d}_renamed;", .{ i, i }));
        try h.run(try std.fmt.bufPrint(buf[64..], "ALTER POLICY D_{d} RENAME TO D_{d}_renamed;", .{ i, i }));
        try h.run(try std.fmt.bufPrint(buf[64..], "ALTER POLICY A_{d}_renamed SET ENABLED false;", .{i}));
        try h.run(try std.fmt.bufPrint(buf[64..], "ALTER POLICY A_{d}_renamed SET ENABLED true;", .{i}));
        _ = self.cat.disableAllowPoliciesWithPrefix("A_");
        try h.run(try std.fmt.bufPrint(buf[64..], "DROP POLICY A_{d}_renamed;", .{i}));
        try h.run(try std.fmt.bufPrint(buf[64..], "ALTER POLICY D_{d}_renamed SET ENABLED false;", .{i}));
        try h.run(try std.fmt.bufPrint(buf[64..], "DROP POLICY D_{d}_renamed;", .{i}));
    }

    fn decider(self: *Stress) void {
        const nora = principal("nora", &no_role, 0);
        const ada = principal("ada", &admin_role, 0);
        while (!self.stop.load(.acquire)) {
            const k = decideKind(&nora, .match_, .{ .graph = "g" }) catch |err| {
                self.fail("decide failed: {s}", .{@errorName(err)});
                return;
            };
            if (k != .deny and k != .unauthorized) self.fail("nora reading g: {s}, which no catalog state gives", .{@tagName(k)});
            if (gps.graphReadPermitted(testing.allocator, &nora, "g")) self.fail("graphReadPermitted allowed nora on g", .{});
            // Admin: allowed or denied, either is some catalog's answer; these
            // walk the catalog through every helper.
            _ = gps.graphReadPermitted(testing.allocator, &ada, "g");
            _ = gps.writePermitted(testing.allocator, &ada);
            _ = gps.schemaPermittedEverywhere(testing.allocator, &ada);
            _ = gps.procedurePermitted(testing.allocator, &ada, .read, "db.labels", "g") catch {};
            _ = self.decisions.fetchAdd(1, .monotonic);
        }
    }

    fn lister(self: *Stress) void {
        while (!self.stop.load(.acquire)) {
            var res = self.h.exec("SHOW POLICIES;") catch |err| {
                self.fail("SHOW POLICIES failed: {s}", .{@errorName(err)});
                return;
            };
            defer res.deinit(testing.allocator);
            for (res.rows) |row| {
                if (row.len != 5 or row[0] != .Str or row[1] != .Str or row[2] != .Str or row[3] != .Bool or row[4] != .Bool) {
                    self.fail("SHOW POLICIES row is malformed", .{});
                    continue;
                }
                const name = row[0].Str;
                const named_ok = (std.mem.startsWith(u8, name, "A_") or std.mem.startsWith(u8, name, "D_")) and name.len < 32;
                if (!named_ok or !std.mem.eql(u8, row[1].Str, "g") or !std.mem.eql(u8, row[2].Str, "read")) {
                    self.fail("SHOW POLICIES row is not a policy the writer made: name '{s}' graph '{s}' actions '{s}'", .{ name[0..@min(name.len, 40)], row[1].Str[0..@min(row[1].Str.len, 40)], row[2].Str[0..@min(row[2].Str.len, 40)] });
                }
            }
            _ = self.listings.fetchAdd(1, .monotonic);
        }
    }
};

test "SONNY-2756: decisions, the GPS helpers and SHOW POLICIES stay well-formed and consistent during rounds of policy DDL" {
    test_mutex.lockUncancelable(io);
    defer test_mutex.unlock(io);

    var cat = PolicyCatalog.init(testing.allocator);
    defer cat.deinit();
    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    var s: Stress = .{ .h = &h, .cat = &cat };
    var readers: [4]std.Thread = undefined;
    for (readers[0..2]) |*t| t.* = try std.Thread.spawn(.{}, Stress.decider, .{&s});
    for (readers[2..4]) |*t| t.* = try std.Thread.spawn(.{}, Stress.lister, .{&s});
    const wt = try std.Thread.spawn(.{}, Stress.writer, .{ &s, 300 });
    wt.join();
    for (readers) |t| t.join();

    try testing.expectEqual(@as(u32, 0), s.bad.load(.acquire));
    try testing.expect(s.decisions.load(.acquire) > 0);
    try testing.expect(s.listings.load(.acquire) > 0);
    try testing.expectEqual(@as(usize, 0), cat.listPolicies().len);
}

// ---------------------------------------------------------------------------
// The lock, held from the test.
// ---------------------------------------------------------------------------

const Decider = struct {
    done: std.atomic.Value(bool) = .init(false),
    kind: Kind = .indeterminate,

    fn run(self: *Decider) void {
        const p = principal("nora", &no_role, 0);
        self.kind = decideKind(&p, .match_, .{ .graph = "g" }) catch .indeterminate;
        self.done.store(true, .release);
    }
};

const Changer = struct {
    cat: *PolicyCatalog,
    done: std.atomic.Value(bool) = .init(false),
    failed: bool = false,

    fn run(self: *Changer) void {
        self.cat.removePolicy("d") catch {
            self.failed = true;
        };
        self.done.store(true, .release);
    }
};

test "SONNY-2756: a decision waits while a change holds the catalog exclusively, and runs after it" {
    test_mutex.lockUncancelable(io);
    defer test_mutex.unlock(io);

    var cat = PolicyCatalog.init(testing.allocator);
    defer cat.deinit();
    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();
    try cat.addPolicyStrict(spec("d", .deny));

    cat.rwlock.lockUncancelable(io);
    var d: Decider = .{};
    const t = try std.Thread.spawn(.{}, Decider.run, .{&d});
    sleepMs(200);
    const finished_under_change = d.done.load(.acquire);
    cat.rwlock.unlock(io);
    t.join();

    try testing.expect(!finished_under_change);
    try testing.expect(d.done.load(.acquire));
    try testing.expectEqual(Kind.deny, d.kind);
}

test "SONNY-2756: a policy change waits while a reader holds the catalog, and runs after it" {
    test_mutex.lockUncancelable(io);
    defer test_mutex.unlock(io);

    var cat = PolicyCatalog.init(testing.allocator);
    defer cat.deinit();
    try cat.addPolicyStrict(spec("d", .deny));

    const view = cat.acquireRead();
    var c: Changer = .{ .cat = &cat };
    const t = try std.Thread.spawn(.{}, Changer.run, .{&c});
    sleepMs(200);
    const finished_under_reader = c.done.load(.acquire);
    // What the reader holds is still the policy it saw.
    try testing.expectEqual(@as(usize, 1), view.policies().len);
    try testing.expectEqualStrings("d", view.policies()[0].name);
    view.release();
    t.join();

    try testing.expect(!finished_under_reader);
    try testing.expect(!c.failed);
    try testing.expectEqual(@as(usize, 0), cat.count());
}

test "SONNY-2756: no code in src/ walks the catalog without its lock (listPolicies is for a catalog no other thread reaches)" {
    const a = testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var offenders: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, "security/policy_catalog.zig")) continue;
        const text = try entry.dir.readFileAlloc(io, entry.basename, a, .unlimited);
        defer a.free(text);
        if (std.mem.indexOf(u8, text, ".listPolicies(") != null) {
            std.debug.print("src/{s} calls listPolicies (unlocked); use acquireRead\n", .{entry.path});
            offenders += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), offenders);
}
