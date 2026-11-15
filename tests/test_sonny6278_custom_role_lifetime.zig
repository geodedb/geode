// SONNY-6278: the custom-role store (`auth_dispatch.g_custom_roles`) is
// process-global and outlives every request, so it must own its keys and
// values.
//
// Before the fix, CREATE ROLE (`handleRoleCreate`) and the startup hydration
// (`hydrateCustomRolesFromGraph`) copied the role name and description with
// the allocator they were handed: for a statement, the request's arena. Once
// the request ended the store held freed memory, and a later SHOW ROLES,
// lookup, GRANT ROLE or DROP ROLE read it. DROP ROLE freed nothing. (The
// membership side-table `GRANT ROLE <custom>` filled had the same defect;
// SONNY-6292 removed it: that statement is refused now.)
//
// Each request below runs through the real executor
// (`executeStatementWithContext`, authorization on, an Admin caller) with an
// allocator of its own. When the request ends, whatever it still holds is
// overwritten, as a reused arena page would be (and freed when the test
// ends), so memory the store kept from it shows as garbage instead of
// crashing the run.
//
// CANARY: REQ=REQ-SONNY-6278-CUSTOM-ROLE-LIFETIME; FEATURE="GQL Auth DDL"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6278_custom_role_lifetime.zig; OWNER=security; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const user_mgmt = geode.user_management;
const execution = geode.execution;
const auth_dispatch = geode.auth_dispatch;

/// One request's memory. `end` overwrites what the request still holds;
/// `release` frees it.
const RequestMemory = struct {
    inner: std.mem.Allocator,
    live: std.ArrayList([]u8) = .empty,
    alignments: std.ArrayList(std.mem.Alignment) = .empty,

    fn allocator(self: *RequestMemory) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn find(self: *RequestMemory, memory: []u8) ?usize {
        for (self.live.items, 0..) |m, i| {
            if (m.ptr == memory.ptr) return i;
        }
        return null;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *RequestMemory = @ptrCast(@alignCast(ctx));
        const p = self.inner.rawAlloc(len, alignment, ra) orelse return null;
        self.live.append(testing.allocator, p[0..len]) catch {
            self.inner.rawFree(p[0..len], alignment, ra);
            return null;
        };
        self.alignments.append(testing.allocator, alignment) catch {
            _ = self.live.pop();
            self.inner.rawFree(p[0..len], alignment, ra);
            return null;
        };
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *RequestMemory = @ptrCast(@alignCast(ctx));
        const i = self.find(memory) orelse return false;
        if (!self.inner.rawResize(memory, alignment, new_len, ra)) return false;
        self.live.items[i] = memory.ptr[0..new_len];
        return true;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *RequestMemory = @ptrCast(@alignCast(ctx));
        const i = self.find(memory) orelse return;
        _ = self.live.swapRemove(i);
        _ = self.alignments.swapRemove(i);
        self.inner.rawFree(memory, alignment, ra);
    }

    /// The request is over: what it still holds is reused by someone else.
    fn end(self: *RequestMemory) void {
        for (self.live.items) |m| @memset(m, 0xaa);
    }

    fn release(self: *RequestMemory) void {
        for (self.live.items, self.alignments.items) |m, a| self.inner.rawFree(m, a, @returnAddress());
        self.live.deinit(testing.allocator);
        self.alignments.deinit(testing.allocator);
    }
};

/// Requests run as an Admin with authorization on; each gets its own
/// RequestMemory, ended after the statement and released at the end.
const World = struct {
    h: harness.Harness,
    requests: std.ArrayList(*RequestMemory) = .empty,
    auth_was: bool,

    fn init(self: *World) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        self.requests = .empty;
        self.auth_was = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(true);
        user_mgmt.deinitUserStore();
        try user_mgmt.initUserStore(testing.allocator);
        try user_mgmt.createUserWithHash(testing.allocator, "dave", "not_a_real_hash", "dave@example.com", .ReadOnly, false);
        self.h.ctx.role = .Admin;
        self.h.ctx.user = "root6278";
    }

    fn deinit(self: *World) void {
        for (self.requests.items) |r| {
            r.release();
            testing.allocator.destroy(r);
        }
        self.requests.deinit(testing.allocator);
        auth_dispatch.setRolePersistCallbacks(.{});
        user_mgmt.deinitUserStore();
        user_mgmt.setAuthEnabled(self.auth_was);
        self.h.deinit();
    }

    fn newRequest(self: *World) !*RequestMemory {
        const r = try testing.allocator.create(RequestMemory);
        r.* = .{ .inner = testing.allocator };
        try self.requests.append(testing.allocator, r);
        return r;
    }

    /// Run `query` as one request; returns column 0 of each row, copied
    /// (testing.allocator; free with freeNames).
    fn request(self: *World, query: []const u8) ![][]u8 {
        const r = try self.newRequest();
        defer r.end();
        const a = r.allocator();
        var parsed = try geode.parseGqlOptions(query, a, .{});
        defer parsed.deinit();
        var result = try execution.executeStatementWithContext(a, parsed.program.statements[0], self.h.ctx);
        defer result.deinit(a);
        var out = std.ArrayList([]u8).empty;
        errdefer freeNames(out.items);
        for (result.rows) |row| {
            const s: []const u8 = if (row.len > 0 and row[0] == .Str) row[0].Str else "";
            try out.append(testing.allocator, try testing.allocator.dupe(u8, s));
        }
        return out.toOwnedSlice(testing.allocator);
    }
};

fn freeNames(names: [][]u8) void {
    for (names) |n| testing.allocator.free(n);
    testing.allocator.free(names);
}

fn listed(names: []const []const u8, want: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, want)) return true;
    }
    return false;
}

/// SHOW ROLES' custom roles (the built-ins left out), as one request.
fn customRolesListed(w: *World) ![][]u8 {
    const names = try w.request("SHOW ROLES");
    var out = std.ArrayList([]u8).empty;
    for (names) |n| {
        if (auth_dispatch.isBuiltinRoleName(n)) {
            testing.allocator.free(n);
            continue;
        }
        try out.append(testing.allocator, n);
    }
    testing.allocator.free(names);
    return out.toOwnedSlice(testing.allocator);
}

/// The role list the persistence callback returns (what is stored).
var g_stored_roles: []const auth_dispatch.RoleEntry = &.{};

fn roleList(_: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]auth_dispatch.RoleEntry {
    return allocator.dupe(auth_dispatch.RoleEntry, g_stored_roles);
}

test "SONNY-6278: a custom role created, assigned and hydrated in one request is intact for later requests, and DROP ROLE removes it" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();

    // Startup: the store is hydrated from __geode_security (nothing stored
    // yet), with the server's allocator, as server_init does.
    auth_dispatch.setRolePersistCallbacks(.{ .list_fn = &roleList });
    g_stored_roles = &.{};
    try auth_dispatch.hydrateCustomRolesFromGraph(testing.allocator);

    // CREATE ROLE in one request; the request ends.
    freeNames(try w.request("CREATE ROLE auditors6278 SET DESCRIPTION 'reads the audit log'"));
    {
        const roles = try customRolesListed(&w);
        defer freeNames(roles);
        if (roles.len != 1 or !std.mem.eql(u8, roles[0], "auditors6278")) {
            for (roles) |r| std.debug.print("SHOW ROLES after the creating request ended: '{s}' ({any})\n", .{ r, r });
            return error.CustomRoleNotIntact;
        }
    }
    try testing.expect(auth_dispatch.g_custom_roles.contains("auditors6278"));
    try testing.expectEqualStrings("reads the audit log", auth_dispatch.g_custom_roles.get("auditors6278").?);

    // Looked up in another request (SONNY-6292: a grant of it is refused,
    // after finding the intact role).
    try testing.expectError(error.CustomRoleMembershipNotSupported, w.request("GRANT ROLE auditors6278 TO dave"));

    // A role hydrated with a request's allocator is owned by the store too.
    g_stored_roles = &.{.{ .id = 7, .name = "ops6278", .description = "operators" }};
    {
        const r = try w.newRequest();
        try auth_dispatch.hydrateCustomRolesFromGraph(r.allocator());
        r.end();
    }
    {
        const roles = try customRolesListed(&w);
        defer freeNames(roles);
        try testing.expectEqual(@as(usize, 2), roles.len);
        try testing.expect(listed(roles, "auditors6278"));
        try testing.expect(listed(roles, "ops6278"));
    }

    // DROP ROLE, in further requests, finds and removes each.
    freeNames(try w.request("DROP ROLE auditors6278"));
    freeNames(try w.request("DROP ROLE ops6278"));
    {
        const roles = try customRolesListed(&w);
        defer freeNames(roles);
        try testing.expectEqual(@as(usize, 0), roles.len);
    }
    try testing.expectEqual(@as(u32, 0), auth_dispatch.g_custom_roles.count());
}

/// Counts the allocations the custom-role store holds (over
/// testing.allocator, which also reports anything never freed).
const Counting = struct {
    inner: std.mem.Allocator,
    live: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.inner.rawAlloc(len, alignment, ra) orelse return null;
        self.live += 1;
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(memory, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.inner.rawRemap(memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.live -= 1;
        self.inner.rawFree(memory, alignment, ra);
    }
};

test "SONNY-6278: DROP ROLE frees the role's copies, re-creating a role leaks nothing, and the store frees the rest at deinit" {
    // The store under a counting allocator for this test.
    auth_dispatch.deinitCustomRoleStore();
    var counting = Counting{ .inner = testing.allocator };
    auth_dispatch.setCustomRoleStoreAllocatorForTesting(counting.allocator());
    defer auth_dispatch.setCustomRoleStoreAllocatorForTesting(std.heap.c_allocator);
    defer auth_dispatch.deinitCustomRoleStore();

    var w: World = undefined;
    try w.init();
    defer w.deinit();

    // (A non-empty description: an empty one takes no allocation.)
    freeNames(try w.request("CREATE ROLE keep6278 SET DESCRIPTION 'first'"));
    const base = counting.live;
    try testing.expect(base > 0);

    freeNames(try w.request("CREATE ROLE gone6278 SET DESCRIPTION 'temporary'"));
    try testing.expect(counting.live > base);
    freeNames(try w.request("DROP ROLE gone6278"));
    try testing.expectEqual(base, counting.live);

    // Re-creating a role replaces its description, and frees the old one.
    freeNames(try w.request("CREATE ROLE keep6278 SET DESCRIPTION 'second'"));
    try testing.expectEqual(base, counting.live);
    try testing.expectEqualStrings("second", auth_dispatch.g_custom_roles.get("keep6278").?);

    // SONNY-6292: a refused grant of it allocates nothing in the store.
    try testing.expectError(error.CustomRoleMembershipNotSupported, w.request("GRANT ROLE keep6278 TO dave"));
    try testing.expectEqual(base, counting.live);

    auth_dispatch.deinitCustomRoleStore();
    try testing.expectEqual(@as(usize, 0), counting.live);
}
