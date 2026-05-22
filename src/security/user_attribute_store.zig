// CANARY: REQ=GAP-0284; FEATURE="ABAC user attribute store"; ASPECT=GlobalStore; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/abac_attribute_policies.yml; OWNER=security; UPDATED=2026-05-22
//
// Process-global ABAC attribute side-table. Lives in security/ so that
// principal_derive.zig (also in security/) can populate Principal.attributes
// without depending on the execution layer.
//
// Writer: src/execution/auth_dispatch.zig (ALTER USER ... SET/REMOVE ATTRIBUTE).
// Reader: src/security/principal_derive.zig (derivePrincipal()).
const std = @import("std");

var g_attrs: std.StringHashMap(std.StringHashMap([]const u8)) = undefined;
var g_attrs_init: bool = false;
var g_attrs_mu: std.Io.Mutex = std.Io.Mutex.init;

fn ensureInit(allocator: std.mem.Allocator) void {
    if (!g_attrs_init) {
        g_attrs = std.StringHashMap(std.StringHashMap([]const u8)).init(allocator);
        g_attrs_init = true;
    }
}

/// Set attribute key=value for username. Replaces existing value if present.
pub fn setAttribute(
    allocator: std.mem.Allocator,
    username: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    g_attrs_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_attrs_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    ensureInit(allocator);
    const entry = try g_attrs.getOrPut(username);
    if (!entry.found_existing) {
        entry.key_ptr.* = try allocator.dupe(u8, username);
        entry.value_ptr.* = std.StringHashMap([]const u8).init(allocator);
    }
    if (entry.value_ptr.fetchRemove(key)) |old| {
        allocator.free(old.key);
        allocator.free(old.value);
    }
    try entry.value_ptr.put(try allocator.dupe(u8, key), try allocator.dupe(u8, value));
}

/// Remove attribute key from username. Returns true if removed.
pub fn removeAttribute(username: []const u8, key: []const u8, allocator: std.mem.Allocator) bool {
    g_attrs_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_attrs_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    if (!g_attrs_init) return false;
    if (g_attrs.getPtr(username)) |attrs| {
        if (attrs.fetchRemove(key)) |old| {
            allocator.free(old.key);
            allocator.free(old.value);
            return true;
        }
    }
    return false;
}

/// Lookup all attributes for a username. Returns null if none set.
pub fn get(username: []const u8) ?*const std.StringHashMap([]const u8) {
    g_attrs_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_attrs_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    if (!g_attrs_init) return null;
    return g_attrs.getPtr(username);
}

/// Snapshot the current attribute set for `username` into an allocator-owned
/// slice that can live as long as a Principal does (one request). Returns
/// an empty slice if no attributes are set. The returned slice and its
/// element strings are all heap-allocated; callers free them.
pub fn snapshotEntries(
    allocator: std.mem.Allocator,
    username: []const u8,
    Entry: type,
) ![]Entry {
    g_attrs_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_attrs_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    if (!g_attrs_init) return try allocator.alloc(Entry, 0);
    const attrs = g_attrs.getPtr(username) orelse return try allocator.alloc(Entry, 0);
    const n = attrs.count();
    if (n == 0) return try allocator.alloc(Entry, 0);
    const out = try allocator.alloc(Entry, n);
    var it = attrs.iterator();
    var i: usize = 0;
    while (it.next()) |kv| : (i += 1) {
        out[i] = .{
            .key = try allocator.dupe(u8, kv.key_ptr.*),
            .value = try allocator.dupe(u8, kv.value_ptr.*),
        };
    }
    return out;
}
