// CANARY: REQ=REQ-SONNY-6329-AUTH-DDL-SERIALIZED; FEATURE="GQL Auth DDL Persistence"; ASPECT=AuthDdlMutex; STATUS=TESTED; TEST=tests/test_sonny6329_user_cache_and_ddl_serialization.zig; OWNER=security; UPDATED=2026-11-12
//
// SONNY-6329: one auth / policy DDL operation at a time, across connections.
//
// Each auth change is compound: a change in memory (the user store, the
// custom-role store, the GPS policy catalog, the per-graph RBAC table), a
// write-through to `__geode_security` (records, HMACs, the chain seal), and an
// undo of the memory change when the write-through fails (SONNY-1333,
// SONNY-3038, SONNY-6273). Each step was atomic on its own, the sequence was
// not: a `CREATE POLICY x` and a `DROP POLICY x` on two connections could
// interleave (the drop finding nothing stored yet, then removing the catalog
// entry the create then stored), leaving the catalog and the security graph
// disagreeing until the next start, and two write-throughs ran in the auth
// manager's unlocked record maps at once.
//
// `acquire` is taken at the start of every operation that changes security
// state: `auth_dispatch.execute` for each `geode.auth.*` procedure that is not
// read-only (CREATE / ALTER / DROP USER, CREATE / DROP ROLE, GRANT, REVOKE and
// their procedures), and `policy_ddl.create` / `drop` / `alter` (CREATE / ALTER
// / DROP POLICY and `geode.auth.policy_create` / `policy_delete`). It is held
// to the end of the operation, the write-through and any undo included.
//
// Lock order (CLAUDE.md, tier 1.7): the security DDL runs with at most its
// session graph's lock held (tier 1), and that graph is never
// `__geode_security` (SONNY-2791: no session binds an internal graph). While
// it is held the operation takes the user store's mutex, the custom-role
// mutexes, `PolicyCatalog.rwlock`, the auth manager's `seal_mutex`, the user
// cache's lock and the `__geode_security` graph's own locks. No thread takes
// this mutex while holding any of those, and no thread holding a
// `__geode_security` lock waits for it, so no cycle can form; it is never
// taken while holding any lock but the session graph's.
//
// Re-entrant on one thread (`geode.auth.policy_create` reaches
// `policy_ddl.create` through `auth_dispatch.execute`): a nested acquire on
// the owning thread only counts.

const std = @import("std");

const lock_io = std.Io.Threaded.global_single_threaded.io();

var mutex: std.Io.Mutex = .init;
threadlocal var depth: u32 = 0;

/// Hold the auth DDL lock until the returned guard's `release`.
pub fn acquire() Guard {
    if (depth == 0) mutex.lockUncancelable(lock_io);
    depth += 1;
    return .{};
}

pub const Guard = struct {
    pub fn release(_: Guard) void {
        std.debug.assert(depth > 0);
        depth -= 1;
        if (depth == 0) mutex.unlock(lock_io);
    }
};

/// Whether the calling thread holds the lock (tests, assertions).
pub fn heldByThisThread() bool {
    return depth > 0;
}
