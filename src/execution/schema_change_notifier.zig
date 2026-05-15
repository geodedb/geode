// CANARY: REQ=REQ-LSP-SCHEMA-PROVIDER-001; FEATURE="LspPermissionAwareCompletion"; ASPECT=SchemaChangeNotifier; STATUS=TESTED; TEST=src/cli/lsp/schema_provider_test.zig; OWNER=lsp; UPDATED=2026-05-14
//
// Cross-package fan-out registry for "the user-visible schema may have
// changed" events. DDL completion points (CREATE GRAPH, DROP GRAPH,
// GRANT/REVOKE) call `notify()`; LSP SchemaProvider instances register
// callbacks at session bind and drop their caches when fired.
//
// Scope (Task 9): graph DDL + grant DDL only. Node/edge CREATE/MERGE are
// HOT paths — firing notify() per write would dominate ingest. The
// SchemaProvider's 5-second TTL handles label-set freshness within that
// window without a hook.
//
// Thread-safety: a single `std.Io.Mutex` protects the callback list.
// The `notify()` fast path snapshots `items` under the lock and then
// invokes callbacks without holding it, so callback implementations
// may take their own locks (e.g. SchemaProvider.mu) without risking
// re-entrant lock ordering inversions. The snapshot is a `[]Callback`
// pointing into the live ArrayList backing store — safe as long as no
// register/unregister mutates the list across the iteration. Callers
// that genuinely interleave register+notify from concurrent threads
// should serialise externally.
//
// Lifetime: the registry is a package-level global. Multiple
// SchemaProvider instances (one per LSP session) share the same list —
// intentional. unregister() MUST run before SchemaProvider.deinit();
// otherwise a stale `ctx` pointer will be dispatched on the next DDL.

const std = @import("std");

pub const Callback = struct {
    ctx: *anyopaque,
    invoke: *const fn (*anyopaque) void,
};

var g_mu: std.Io.Mutex = std.Io.Mutex.init;
var g_callbacks: std.ArrayList(Callback) = std.ArrayList(Callback).empty;

fn lockHere() void {
    g_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
}

fn unlockHere() void {
    g_mu.unlock(std.Io.Threaded.global_single_threaded.io());
}

pub fn register(cb: Callback) !void {
    lockHere();
    defer unlockHere();
    // smp_allocator is the governance-approved global allocator for
    // process-lifetime registries — page_allocator is forbidden in
    // production src/ (see .gitlab-ci.yml governance-no-page-allocator
    // check, and the documented precedent at
    // src/monitoring/metrics_server.zig:75-77).
    try g_callbacks.append(std.heap.smp_allocator, cb);
}

pub fn unregister(ctx: *anyopaque) void {
    lockHere();
    defer unlockHere();
    var i: usize = 0;
    while (i < g_callbacks.items.len) {
        if (g_callbacks.items[i].ctx == ctx) {
            _ = g_callbacks.swapRemove(i);
        } else i += 1;
    }
}

pub fn notify() void {
    lockHere();
    const snapshot = g_callbacks.items;
    unlockHere();
    for (snapshot) |cb| cb.invoke(cb.ctx);
}
