// GPS Phase 4 (Task 4-1) — Isolated unit tests for role_resolver.zig
//
// Verifies that resolveRoleFromGraph correctly traverses the __geode_security
// graph (User node → HAS_ROLE edge → Role node) and maps the role name to the
// correct built-in Role enum value, and that authRoleFromRecord handles the
// is_superuser fast-path.
//
// Strategy: spin up an in-memory GraphStore (no server, no QUIC, no auth
// subsystem) via graph_store.getGlobalStore, build a minimal security graph,
// construct a UserRecord with std.mem.zeroes, and call the public functions
// from role_resolver directly.

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const role_resolver = geode.security.role_resolver;
const user_storage = @import("user_storage");

// ---------------------------------------------------------------------------
// Minimal harness: isolated GraphStore with no catalog, no WAL, no auth mgr
// ---------------------------------------------------------------------------

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        return .{
            .allocator = allocator,
            .tmp = tmp,
            .data_dir = data_dir,
        };
    }

    pub fn deinit(self: *Harness) void {
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }
};

// Build a zeroed UserRecord with the given username and is_superuser flag.
fn makeRecord(username: []const u8, is_superuser: bool) user_storage.UserStorageBackend.UserRecord {
    var rec = std.mem.zeroes(user_storage.UserStorageBackend.UserRecord);
    rec.id = 1;
    rec.is_superuser = is_superuser;
    rec.is_active = true;
    const copy_len = @min(username.len, rec.username.len);
    @memcpy(rec.username[0..copy_len], username[0..copy_len]);
    rec.username_len = @intCast(copy_len);
    return rec;
}

// Insert a User node + Role node + HAS_ROLE edge into __geode_security.
fn plantHasRoleEdge(
    store: *graph_store.GraphStore,
    username: []const u8,
    role_name: []const u8,
) !void {
    const SECURITY_GRAPH = "__geode_security";

    const user_labels = [_][]const u8{"User"};
    const uid = try store.createNodeWithGraph(&user_labels, SECURITY_GRAPH);
    try store.setNodeProperty(uid, "username", .{ .String = username });

    const role_labels = [_][]const u8{"Role"};
    const rid = try store.createNodeWithGraph(&role_labels, SECURITY_GRAPH);
    try store.setNodeProperty(rid, "name", .{ .String = role_name });

    _ = try store.createEdgeWithGraph(uid, rid, "HAS_ROLE", SECURITY_GRAPH);
}

// ===========================================================================
// CANARY: REQ=REQ-GPS-PDP-008; FEATURE="GPS Canonical Principal"; ASPECT=AuthRoleGraphLookupIsolated; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ===========================================================================

test "authRoleFromRecord: is_superuser=true → Admin" {
    const rec = makeRecord("alice", true);
    try std.testing.expectEqual(geode.user_management.Role.Admin, role_resolver.authRoleFromRecord(rec));
}

test "authRoleFromRecord: is_superuser=false → ReadWrite" {
    const rec = makeRecord("bob", false);
    try std.testing.expectEqual(geode.user_management.Role.ReadWrite, role_resolver.authRoleFromRecord(rec));
}

test "resolveRoleFromGraph: is_superuser=true fast-path, no graph needed" {
    // Superuser must short-circuit without touching the store at all.
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    const rec = makeRecord("root", true);
    try std.testing.expectEqual(geode.user_management.Role.Admin, role_resolver.resolveRoleFromGraph(store, rec));
}

test "resolveRoleFromGraph: HAS_ROLE edge → ReadOnly" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    try plantHasRoleEdge(store, "charlie", "readonly");

    const rec = makeRecord("charlie", false);
    try std.testing.expectEqual(geode.user_management.Role.ReadOnly, role_resolver.resolveRoleFromGraph(store, rec));
}

test "resolveRoleFromGraph: HAS_ROLE edge → Admin" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    try plantHasRoleEdge(store, "dana", "admin");

    const rec = makeRecord("dana", false);
    try std.testing.expectEqual(geode.user_management.Role.Admin, role_resolver.resolveRoleFromGraph(store, rec));
}

test "resolveRoleFromGraph: no User node → fallback ReadWrite" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    // No nodes inserted — user not found in security graph, fallback applies.
    const rec = makeRecord("unknown", false);
    try std.testing.expectEqual(geode.user_management.Role.ReadWrite, role_resolver.resolveRoleFromGraph(store, rec));
}

test "resolveRoleFromGraph: wrong username in graph → fallback ReadWrite" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    // Plant edge for "eve", but look up "frank".
    try plantHasRoleEdge(store, "eve", "admin");

    const rec = makeRecord("frank", false);
    try std.testing.expectEqual(geode.user_management.Role.ReadWrite, role_resolver.resolveRoleFromGraph(store, rec));
}

test "resolveRoleFromGraph: unrecognised role name → fallback ReadWrite" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    // "supervigilante" is not a valid Role.fromString value.
    try plantHasRoleEdge(store, "grace", "supervigilante");

    const rec = makeRecord("grace", false);
    try std.testing.expectEqual(geode.user_management.Role.ReadWrite, role_resolver.resolveRoleFromGraph(store, rec));
}
