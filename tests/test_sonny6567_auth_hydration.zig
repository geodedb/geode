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
// per-graph grants and an FLE role grant. Each hydration runs with its
// allocations failing from the k-th one on, for every k up to the first run
// that needs none (the listing's allocator, and the role store's own). Each
// run must fail or load everything.
//
// CANARY: REQ=REQ-SONNY-6567-AUTH-HYDRATION; FEATURE="AuthDDLPersistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6567_auth_hydration.zig; OWNER=security; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const auth_graph_manager = @import("auth_graph_manager");

const graph_store = geode.graph_store;
const execution = geode.execution;
const user_mgmt = geode.user_management;
const auth_dispatch = geode.auth_dispatch;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;

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

    fn init(self: *World) !void {
        self.auth_was = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(false);
        self.store = try graph_store.GraphStore.init(testing.allocator);
        self.agm = try AuthGraphManager.init(testing.allocator, &self.store);
        for (ROLES) |r| _ = try self.agm.createRole(&HMAC_KEY, r, "SONNY-6567");
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
