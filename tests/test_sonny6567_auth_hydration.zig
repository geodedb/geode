// SONNY-6567 (5): the server's startup hydration of the auth state either
// loads every stored record or fails; it never runs with part of it.
//
// At startup the server loads the custom roles
// (`auth_dispatch.hydrateCustomRolesFromGraph`), the per-graph grants (into
// the live `GraphRBACPolicy`), the FLE role grants and the GPS policy catalog
// from `__geode_security` (`server_init.wireAuthDDLCallbacks` /
// `wireGpsPolicyHooks`). Each step logged a failure and went on: a role whose
// copy could not be made was dropped (`catch continue`), a failed listing
// loaded nothing, a grant or policy listing that failed left the live
// tables empty. A missing grant or role changes authorization outcomes, and
// a missing policy (an RLS deny) hides nothing: the server must not start
// that way.
//
// A real `AuthGraphManager` over a real store holds three custom roles, two
// per-graph grants and two FLE role grants. Each hydration runs with its
// allocations failing from the k-th one on, for every k up to the first run
// that needs none (the listing's allocator, and the role store's own). Each
// run must fail or load everything.
//
// CANARY: REQ=REQ-SONNY-6567-AUTH-HYDRATION; FEATURE="AuthDDLPersistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6567_auth_hydration.zig; OWNER=security; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const auth_graph_manager = @import("auth_graph_manager");
const auth_startup_hydration = @import("auth_startup_hydration");

const graph_store = geode.graph_store;
const execution = geode.execution;
const user_mgmt = geode.user_management;
const auth_dispatch = geode.auth_dispatch;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;
const mgs = geode.multi_graph_security;
const fle_role_grants = geode.security.fle_role_grants;

const HMAC_KEY = [_]u8{0x67} ** 32;
const ROLES = [_][]const u8{ "auditor6567", "operator6567", "viewer6567" };
const MAX_SWEEP: usize = 2_000;

/// The role-list persistence callback, as `server_init.roleList` is.
fn roleList(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]auth_dispatch.RoleEntry {
    const agm: *AuthGraphManager = @ptrCast(@alignCast(ctx.?));
    const entries = try agm.listRoles(allocator);
    defer allocator.free(entries);
    const out = try allocator.alloc(auth_dispatch.RoleEntry, entries.len);
    for (entries, 0..) |e, i| out[i] = .{ .id = e.id, .name = e.name, .description = e.description };
    return out;
}

/// `hydrateCustomRolesFromGraph`, whether it reports an error or not.
fn hydrateRoles(allocator: std.mem.Allocator) !void {
    const f = auth_dispatch.hydrateCustomRolesFromGraph;
    const R = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    if (@typeInfo(R) == .error_union) try f(allocator) else f(allocator);
}

/// The custom roles the live store holds (`geode.auth.role_list`).
fn customRolesLoaded(ctx: execution.ExecutionContext) !usize {
    var r = try auth_dispatch.callAuthProcedure(testing.allocator, ctx, "geode.auth.role_list", &.{});
    defer r.deinit(testing.allocator);
    var n: usize = 0;
    for (r.rows) |row| {
        if (row.len == 0 or row[0] != .Str) continue;
        if (!auth_dispatch.isBuiltinRoleName(row[0].Str)) n += 1;
    }
    return n;
}

const Which = enum { listing, role_store };

fn sweepRoles(ctx: execution.ExecutionContext, which: Which) !usize {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var partial: usize = 0;
    var failed: usize = 0;
    var runs: usize = 0;
    var k: usize = 0;
    defer {
        auth_dispatch.deinitCustomRoleStore();
        auth_dispatch.setCustomRoleStoreAllocatorForTesting(std.heap.c_allocator);
    }
    while (k < MAX_SWEEP) : (k += 1) {
        auth_dispatch.deinitCustomRoleStore();
        auth_dispatch.setCustomRoleStoreAllocatorForTesting(if (which == .role_store) failing.allocator() else testing.allocator);
        failing.has_induced_failure = false;
        failing.fail_index = failing.alloc_index + k;
        const outcome = hydrateRoles(if (which == .listing) failing.allocator() else testing.allocator);
        failing.fail_index = std.math.maxInt(usize);
        const induced = failing.has_induced_failure;
        runs += 1;
        const loaded = try customRolesLoaded(ctx);
        if (outcome) |_| {
            if (loaded != ROLES.len) {
                partial += 1;
                std.debug.print("SONNY-6567 (5) roles, {t} allocation {d} failing: hydration succeeded with {d} of {d} roles\n", .{ which, k, loaded, ROLES.len });
            }
        } else |_| failed += 1;
        if (!induced) break;
    }
    std.debug.print("SONNY-6567 (5) roles, {t} allocations failing: {d} runs, {d} failed, {d} partial\n", .{ which, runs, failed, partial });
    return partial;
}

const World = struct {
    store: graph_store.GraphStore,
    agm: AuthGraphManager,
    ctx: execution.ExecutionContext,
    auth_was: bool,
    ida: u64 = 0,
    jon: u64 = 0,

    fn init(self: *World) !void {
        self.auth_was = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(false);
        self.store = try graph_store.GraphStore.init(testing.allocator);
        self.agm = try AuthGraphManager.init(testing.allocator, &self.store);
        for (ROLES) |r| _ = try self.agm.createRole(&HMAC_KEY, r, "SONNY-6567");
        self.ida = try self.agm.createUser(&HMAC_KEY, "ida6567", "ida@example.com", "not_a_real_hash", false);
        self.jon = try self.agm.createUser(&HMAC_KEY, "jon6567", "jon@example.com", "not_a_real_hash", false);
        try self.agm.grantUserGraphPermission(&HMAC_KEY, self.ida, "g1", 1);
        try self.agm.grantUserGraphPermission(&HMAC_KEY, self.jon, "g2", 2);
        try self.agm.grantUserFleRole(&HMAC_KEY, self.ida, "pii_reader");
        try self.agm.grantUserFleRole(&HMAC_KEY, self.jon, "pii_writer");
        auth_dispatch.setRolePersistCallbacks(.{ .ctx = @ptrCast(&self.agm), .list_fn = &roleList });
        self.ctx = .{ .catalog = try execution.ensureCatalogInstance(testing.allocator) };
        self.ctx.role = .Admin;
        self.ctx.user = "root6567";
    }

    fn deinit(self: *World) void {
        auth_dispatch.setRolePersistCallbacks(.{});
        execution.cleanupCatalogInstance();
        self.agm.deinit();
        self.store.deinit();
        user_mgmt.setAuthEnabled(self.auth_was);
    }
};

test "SONNY-6567 (5): custom-role hydration loads every stored role or fails" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    var partial: usize = 0;
    partial += try sweepRoles(w.ctx, .listing);
    partial += try sweepRoles(w.ctx, .role_store);
    try testing.expectEqual(@as(usize, 0), partial);
}

/// A sweep of `load` (one hydration, returning error or the count) over the
/// listing allocator; `complete` says whether everything stored is live.
fn sweep(what: []const u8, w: *World, comptime load: fn (*World, std.mem.Allocator) anyerror!usize, comptime complete: fn (*World) bool, comptime reset: fn (*World) void) !usize {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var partial: usize = 0;
    var failed: usize = 0;
    var runs: usize = 0;
    var k: usize = 0;
    while (k < MAX_SWEEP) : (k += 1) {
        reset(w);
        failing.has_induced_failure = false;
        failing.fail_index = failing.alloc_index + k;
        const outcome = load(w, failing.allocator());
        failing.fail_index = std.math.maxInt(usize);
        const induced = failing.has_induced_failure;
        runs += 1;
        if (outcome) |_| {
            if (!complete(w)) {
                partial += 1;
                std.debug.print("SONNY-6567 (5) {s}, allocation {d} failing: hydration succeeded with part of the stored records\n", .{ what, k });
            }
        } else |_| failed += 1;
        if (!induced) break;
    }
    std.debug.print("SONNY-6567 (5) {s}: {d} runs, {d} failed, {d} partial\n", .{ what, runs, failed, partial });
    return partial;
}

var g_policy: mgs.GraphRBACPolicy = undefined;

fn loadGrants(w: *World, a: std.mem.Allocator) anyerror!usize {
    return auth_startup_hydration.hydrateGraphGrants(a, &w.agm, &g_policy);
}
fn grantsComplete(w: *World) bool {
    return g_policy.hasGraphGrant(w.ida, "g1", 1) and g_policy.hasGraphGrant(w.jon, "g2", 2);
}
fn resetGrants(_: *World) void {
    g_policy.deinit();
    g_policy = mgs.GraphRBACPolicy.init(testing.allocator);
}

fn loadFle(w: *World, a: std.mem.Allocator) anyerror!usize {
    return auth_startup_hydration.hydrateFleRoleGrants(a, &w.agm);
}
fn fleComplete(_: *World) bool {
    return fle_role_grants.holds("ida6567", "pii_reader") and fle_role_grants.holds("jon6567", "pii_writer");
}
fn resetFle(_: *World) void {
    fle_role_grants.resetForTesting();
}

test "SONNY-6567 (5): per-graph grant and FLE role grant hydration load every stored grant or fail" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    g_policy = mgs.GraphRBACPolicy.init(testing.allocator);
    defer g_policy.deinit();
    defer fle_role_grants.resetForTesting();
    var partial: usize = 0;
    partial += try sweep("per-graph grants", &w, loadGrants, grantsComplete, resetGrants);
    partial += try sweep("FLE role grants", &w, loadFle, fleComplete, resetFle);
    try testing.expectEqual(@as(usize, 0), partial);
}
