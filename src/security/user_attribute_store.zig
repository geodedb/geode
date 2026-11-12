// CANARY: REQ=GAP-0284; FEATURE="ABAC user attribute store"; ASPECT=GlobalStore; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/abac_attribute_policies.yml; OWNER=security; UPDATED=2026-05-22
//
// Process-global ABAC attribute side-table. Lives in security/ so that
// principal_derive.zig (also in security/) can populate Principal.attributes
// without depending on the execution layer.
//
// Writer: src/execution/auth_dispatch.zig (ALTER USER ... SET/REMOVE ATTRIBUTE).
// Readers: src/security/principal_derive.zig (derivePrincipal()) and
//          src/security/rls_core.zig (RLS expression VM `load_attr` opcode).
//
// GAP-0284 lifetime fix: the store MUST own its memory with a process-stable
// allocator, never a request-scoped one. The previous design dup'd keys and
// values with whatever allocator the caller (an auth-dispatch request) handed
// in and initialized the global map with it; once that request's arena was
// freed the entire ABAC side-table was freed/corrupted, so a later query by a
// different connection saw zero attributes and every restrictive ABAC RLS
// policy denied all rows. The store now ignores the caller-supplied allocator
// for storage and uses `std.heap.c_allocator`, which is valid for the whole
// process lifetime.
const std = @import("std");

// Process-stable allocator. `std.heap.c_allocator` is backed by libc malloc and
// is valid for the entire process lifetime — exactly the contract a global
// side-table needs.
var store_alloc: std.mem.Allocator = std.heap.c_allocator;

var g_attrs: std.StringHashMap(std.StringHashMap([]const u8)) = undefined;
var g_attrs_init: bool = false;
var g_attrs_mu: std.Io.Mutex = std.Io.Mutex.init;

fn ensureInit() void {
    if (!g_attrs_init) {
        g_attrs = std.StringHashMap(std.StringHashMap([]const u8)).init(store_alloc);
        g_attrs_init = true;
    }
}

/// Set attribute key=value for username. Replaces existing value if present.
/// The `allocator` parameter is accepted for source-compatibility but ignored;
/// storage uses a process-stable allocator (see file header).
pub fn setAttribute(
    allocator: std.mem.Allocator,
    username: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    _ = allocator;
    g_attrs_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_attrs_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    ensureInit();
    const entry = try g_attrs.getOrPut(username);
    if (!entry.found_existing) {
        entry.key_ptr.* = try store_alloc.dupe(u8, username);
        entry.value_ptr.* = std.StringHashMap([]const u8).init(store_alloc);
    }
    if (entry.value_ptr.fetchRemove(key)) |old| {
        store_alloc.free(old.key);
        store_alloc.free(old.value);
    }
    try entry.value_ptr.put(try store_alloc.dupe(u8, key), try store_alloc.dupe(u8, value));
}

/// Remove attribute key from username. Returns true if removed.
/// The `allocator` parameter is accepted for source-compatibility but ignored.
pub fn removeAttribute(username: []const u8, key: []const u8, allocator: std.mem.Allocator) bool {
    _ = allocator;
    g_attrs_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_attrs_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    if (!g_attrs_init) return false;
    if (g_attrs.getPtr(username)) |attrs| {
        if (attrs.fetchRemove(key)) |old| {
            store_alloc.free(old.key);
            store_alloc.free(old.value);
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

/// Tests only (SONNY-6377): route the store's allocations through `a`, e.g.
/// a `std.testing.FailingAllocator`. Production never calls this.
pub fn setAllocatorForTesting(a: std.mem.Allocator) void {
    g_attrs_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_attrs_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    store_alloc = a;
}

/// Tests only (SONNY-6377): free every entry with `a` (the allocator the
/// entries came from, or the one under it) and empty the store; `a` stays
/// the store's allocator.
pub fn resetForTesting(a: std.mem.Allocator) void {
    g_attrs_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_attrs_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    store_alloc = a;
    if (!g_attrs_init) return;
    var it = g_attrs.iterator();
    while (it.next()) |entry| {
        var attr_it = entry.value_ptr.iterator();
        while (attr_it.next()) |kv| {
            a.free(kv.key_ptr.*);
            a.free(kv.value_ptr.*);
        }
        entry.value_ptr.deinit();
        a.free(entry.key_ptr.*);
    }
    g_attrs.deinit();
    g_attrs_init = false;
}
