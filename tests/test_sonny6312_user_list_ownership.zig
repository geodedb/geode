// SONNY-6312: SHOW USERS / `CALL geode.auth.user_list` (and the sibling
// readers of the user and role stores) must answer rows the request owns.
//
// Before the fix `user_management.listUsers` returned an array allocated with
// the user store's allocator that `handleUserList` never freed, so every
// SHOW USERS leaked for the life of the server; and its rows borrowed the
// cached users' `username` / `email` slices after the store lock was
// released, so a DROP USER on another connection freed them while the
// response was still being built (a use-after-free). `geode.auth.user_show`
// (`user_management.getUser`) and SHOW ROLES (`g_custom_roles` keys) borrowed
// the same way.
//
// Every statement runs through the real executor (authorization on, an Admin
// caller). The user store runs under a counting allocator over
// std.testing.allocator, so a leak shows as live allocations that do not go
// back down, and memory the store frees is poisoned by the testing allocator,
// so a row still pointing at it no longer reads as the user it named.
//
// CANARY: REQ=REQ-SONNY-6312-USER-LIST-OWNERSHIP; FEATURE="GQL Auth DDL"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6312_user_list_ownership.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const user_mgmt = geode.user_management;
const execution = geode.execution;
const auth_dispatch = geode.auth_dispatch;

/// Counts the allocations it holds (thread-safe; the testing allocator under
/// it is).
const Counting = struct {
    inner: std.mem.Allocator,
    live: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.inner.rawAlloc(len, alignment, ra) orelse return null;
        _ = self.live.fetchAdd(1, .monotonic);
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
        _ = self.live.fetchSub(1, .monotonic);
        self.inner.rawFree(memory, alignment, ra);
    }
};

const World = struct {
    h: harness.Harness,
    store_mem: Counting,
    auth_was: bool,

    fn init(self: *World) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        self.auth_was = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(true);
        self.store_mem = .{ .inner = testing.allocator };
        user_mgmt.deinitUserStore();
        const a = self.store_mem.allocator();
        try user_mgmt.initUserStore(a);
        try user_mgmt.createUserWithHash(a, "alice", "not_a_real_hash", "alice@example.com", .ReadOnly, false);
        try user_mgmt.createUserWithHash(a, "bob", "not_a_real_hash", "bob@example.com", .ReadWrite, false);
        self.h.ctx.role = .Admin;
        self.h.ctx.user = "root6312";
    }

    fn deinit(self: *World) void {
        auth_dispatch.deinitCustomRoleStore();
        user_mgmt.deinitUserStore();
        user_mgmt.setAuthEnabled(self.auth_was);
        self.h.deinit();
    }

    /// Run `query` through the executor with the testing allocator; the
    /// caller deinits the result.
    fn run(self: *World, query: []const u8) !execution.ExecutionResult {
        var parsed = try geode.parseGqlOptions(query, testing.allocator, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(testing.allocator, parsed.program.statements[0], self.h.ctx);
    }
};

fn str(v: geode.value_types.Value) []const u8 {
    return if (v == .Str) v.Str else "";
}

/// The row of `result` whose column 0 is `name`, if any.
fn rowNamed(result: execution.ExecutionResult, name: []const u8) ?[]geode.value_types.Value {
    for (result.rows) |row| {
        if (row.len > 0 and std.mem.eql(u8, str(row[0]), name)) return row;
    }
    return null;
}

test "SONNY-6312: SHOW USERS and geode.auth.user_list leave nothing behind in the user store, call after call" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();

    // One call first: anything loaded once (a resolver, a lazy table) is
    // not growth.
    {
        var r = try w.run("SHOW USERS");
        r.deinit(testing.allocator);
    }
    const before = w.store_mem.live.load(.monotonic);
    var i: usize = 0;
    while (i < 25) : (i += 1) {
        for ([_][]const u8{ "SHOW USERS", "CALL geode.auth.user_list()" }) |q| {
            var r = try w.run(q);
            defer r.deinit(testing.allocator);
            try testing.expect(rowNamed(r, "alice") != null);
            try testing.expect(rowNamed(r, "bob") != null);
        }
    }
    const after = w.store_mem.live.load(.monotonic);
    if (after != before) {
        std.debug.print("user store allocations: {d} before 50 listings, {d} after\n", .{ before, after });
        return error.UserListLeaks;
    }
}

test "SHOW USERS rows stay valid after DROP USER frees the user (SONNY-6312)" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();

    var listing = try w.run("SHOW USERS");
    defer listing.deinit(testing.allocator);
    var shown = try w.run("CALL geode.auth.user_show('bob')");
    defer shown.deinit(testing.allocator);

    // Another connection drops bob: the store frees its strings.
    try user_mgmt.deleteUser("bob");
    try testing.expect(user_mgmt.getUser("bob") == null);

    const row = rowNamed(listing, "bob") orelse {
        std.debug.print("SHOW USERS row for bob no longer reads as bob after DROP USER\n", .{});
        return error.RowBorrowedFreedMemory;
    };
    try testing.expectEqualStrings("bob@example.com", str(row[1]));
    try testing.expectEqualStrings("readwrite", str(row[2]));

    try testing.expectEqual(@as(usize, 1), shown.rows.len);
    try testing.expectEqualStrings("bob", str(shown.rows[0][0]));
    try testing.expectEqualStrings("bob@example.com", str(shown.rows[0][1]));
}

test "SHOW ROLES rows stay valid after DROP ROLE frees the role (SONNY-6312)" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();

    var created = try w.run("CREATE ROLE auditor6312");
    created.deinit(testing.allocator);
    var listing = try w.run("SHOW ROLES");
    defer listing.deinit(testing.allocator);
    var dropped = try w.run("DROP ROLE auditor6312");
    dropped.deinit(testing.allocator);

    if (rowNamed(listing, "auditor6312") == null) {
        std.debug.print("SHOW ROLES row for auditor6312 no longer reads as it after DROP ROLE\n", .{});
        return error.RowBorrowedFreedMemory;
    }
}

const Stress = struct {
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    bad: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    lists: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    ctx: execution.ExecutionContext,
    store_alloc: std.mem.Allocator,

    fn reader(self: *Stress) void {
        while (!self.stop.load(.acquire)) {
            var r = auth_dispatch.callAuthProcedure(testing.allocator, self.ctx, "geode.auth.user_list", &.{}) catch {
                _ = self.bad.fetchAdd(1, .monotonic);
                continue;
            };
            defer r.deinit(testing.allocator);
            for (r.rows) |row| {
                const name = str(row[0]);
                const email = str(row[1]);
                // Every user is alice, bob or churnN, each with its address.
                const ok = (std.mem.eql(u8, name, "alice") or std.mem.eql(u8, name, "bob") or std.mem.startsWith(u8, name, "churn")) and
                    std.mem.startsWith(u8, email, name) and std.mem.endsWith(u8, email, "@example.com");
                if (!ok) _ = self.bad.fetchAdd(1, .monotonic);
            }
            _ = self.lists.fetchAdd(1, .monotonic);
        }
    }

    fn churn(self: *Stress) void {
        var i: usize = 0;
        while (i < 400) : (i += 1) {
            var name_buf: [32]u8 = undefined;
            var mail_buf: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "churn{d}", .{i % 7}) catch unreachable;
            const mail = std.fmt.bufPrint(&mail_buf, "{s}@example.com", .{name}) catch unreachable;
            user_mgmt.createUserWithHash(self.store_alloc, name, "not_a_real_hash", mail, .ReadOnly, false) catch {};
            user_mgmt.deleteUser(name) catch {};
        }
        self.stop.store(true, .release);
    }
};

test "SONNY-6312: concurrent SHOW USERS and CREATE/DROP USER: every row read is a whole user, nothing leaks (stress)" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();

    var s: Stress = .{ .ctx = w.h.ctx, .store_alloc = w.store_mem.allocator() };
    var readers: [3]std.Thread = undefined;
    for (&readers) |*t| t.* = try std.Thread.spawn(.{}, Stress.reader, .{&s});
    const writer = try std.Thread.spawn(.{}, Stress.churn, .{&s});
    writer.join();
    for (readers) |t| t.join();

    if (s.bad.load(.monotonic) != 0) {
        std.debug.print("{d} torn or failed listings out of {d}\n", .{ s.bad.load(.monotonic), s.lists.load(.monotonic) });
        return error.TornUserRows;
    }
    try testing.expect(s.lists.load(.monotonic) > 0);
}
