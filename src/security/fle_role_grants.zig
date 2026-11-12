//! SONNY-6341: which FLE roles each user may act under.
//!
//! The FLE role a session reads encrypted fields with is named by its client
//! (HELLO `role`). It was checked for shape only, so any principal that GPS
//! lets decrypt (every Admin, any ALLOW DECRYPT_FIELD) could name any FLE role
//! and read every field listed for it. A named role now counts only when the
//! authenticated user holds it: an explicit, audited grant made by an Admin
//! (`CALL geode.fle.grantRole(user, role)` / `revokeRole`), stored durably in
//! the HMAC-chained `__geode_security` graph (`FleRoleGrant` records) through
//! the persistence the server installs, and loaded at startup.
//!
//! The transports ask `holds` for every request (`ServerState.effectiveFleRole`),
//! so a grant or revoke counts from the next request of every live session.
//!
//! Locking: `map_mutex` is a leaf (it guards the map only and nothing is
//! acquired under it). `change_mutex` serializes grant/revoke so memory and
//! the store agree; it is held while the persistence writes the security
//! graph, and nothing that holds a graph or catalog lock ever takes it.

const std = @import("std");

const alloc: std.mem.Allocator = std.heap.c_allocator;

const RoleSet = std.StringHashMapUnmanaged(void);
var grants: std.StringHashMapUnmanaged(RoleSet) = .empty;
var map_mutex: std.Io.Mutex = std.Io.Mutex.init;
var change_mutex: std.Io.Mutex = std.Io.Mutex.init;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// The durable side, installed by the server once the security graph is
/// open (server_init). `grant_fn` stores and reseals or fails with nothing
/// stored; `revoke_fn` reports whether a stored grant went, an error when
/// the revoke may not be saved; `forget_user_fn` drops a user's grants.
pub const Persistence = struct {
    ctx: ?*anyopaque,
    grant_fn: *const fn (ctx: ?*anyopaque, username: []const u8, role: []const u8) anyerror!void,
    revoke_fn: *const fn (ctx: ?*anyopaque, username: []const u8, role: []const u8) anyerror!bool,
};

var persistence: ?Persistence = null;

pub fn setPersistence(p: ?Persistence) void {
    change_mutex.lockUncancelable(io());
    defer change_mutex.unlock(io());
    persistence = p;
}

/// Whether `username` may act under FLE role `role`.
pub fn holds(username: []const u8, role: []const u8) bool {
    map_mutex.lockUncancelable(io());
    defer map_mutex.unlock(io());
    const set = grants.getPtr(username) orelse return false;
    return set.contains(role);
}

/// Record a grant in memory only (startup load, after persistence).
pub fn load(username: []const u8, role: []const u8) !void {
    map_mutex.lockUncancelable(io());
    defer map_mutex.unlock(io());
    const entry = try grants.getOrPut(alloc, username);
    if (!entry.found_existing) {
        entry.key_ptr.* = alloc.dupe(u8, username) catch |err| {
            grants.removeByPtr(entry.key_ptr);
            return err;
        };
        entry.value_ptr.* = .empty;
    }
    const r = try entry.value_ptr.getOrPut(alloc, role);
    if (!r.found_existing) {
        r.key_ptr.* = alloc.dupe(u8, role) catch |err| {
            entry.value_ptr.removeByPtr(r.key_ptr);
            return err;
        };
    }
}

fn unload(username: []const u8, role: []const u8) bool {
    map_mutex.lockUncancelable(io());
    defer map_mutex.unlock(io());
    const set = grants.getPtr(username) orelse return false;
    const kv = set.fetchRemove(role) orelse return false;
    alloc.free(kv.key);
    return true;
}

/// Grant: stored first (when the server installed persistence), then in
/// memory; a store failure is the caller's error and nothing changes.
pub fn grant(username: []const u8, role: []const u8) !void {
    change_mutex.lockUncancelable(io());
    defer change_mutex.unlock(io());
    if (persistence) |p| try p.grant_fn(p.ctx, username, role);
    try load(username, role);
}

/// Revoke: out of memory first (no session acts under it from its next
/// request), then from the store. Returns whether the user held it. A store
/// failure leaves the revoke in force in this process and is returned
/// (`FleRoleRevokeNotPersisted`): the caller must report it.
pub fn revoke(username: []const u8, role: []const u8) !bool {
    change_mutex.lockUncancelable(io());
    defer change_mutex.unlock(io());
    const in_memory = unload(username, role);
    var stored = false;
    if (persistence) |p| {
        stored = p.revoke_fn(p.ctx, username, role) catch return error.FleRoleRevokeNotPersisted;
    }
    return in_memory or stored;
}

/// A dropped user holds nothing (memory; the store's records go with the
/// user's: server_init's delete writer).
pub fn forgetUser(username: []const u8) void {
    map_mutex.lockUncancelable(io());
    defer map_mutex.unlock(io());
    var kv = grants.fetchRemove(username) orelse return;
    freeSet(&kv.value);
    alloc.free(kv.key);
}

fn freeSet(set: *RoleSet) void {
    var it = set.keyIterator();
    while (it.next()) |k| alloc.free(k.*);
    set.deinit(alloc);
}

/// Forget every grant and the persistence (tests).
pub fn resetForTesting() void {
    change_mutex.lockUncancelable(io());
    defer change_mutex.unlock(io());
    persistence = null;
    map_mutex.lockUncancelable(io());
    defer map_mutex.unlock(io());
    var it = grants.iterator();
    while (it.next()) |e| {
        freeSet(e.value_ptr);
        alloc.free(e.key_ptr.*);
    }
    grants.deinit(alloc);
    grants = .empty;
}
