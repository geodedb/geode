// INTENTIONAL MIRROR of src/server/quic_connection_handler.zig:2317-2325
// and src/transport/grpc_server.zig:2012-2020.
//
// Both transport handlers inline the same lock-acquisition decision:
//
//     const needs_store_lock = analysis.kind != .explain;
//     const is_mutation = needs_store_lock and isMutatingProgram(&program);
//     if (needs_store_lock) {
//         graph_lock_handle = graph_store.acquireGraphWriteLock(query_graph_name);
//     }
//
// Notice that `is_mutation` is computed but never used to select the lock
// kind — every non-EXPLAIN query takes the exclusive writer lock, which
// serializes read-only MATCH traffic behind any other running query.
// That's the bug this seam exists to catch.
//
// This file is a *test-only* mirror — it exists so reproduction tests in
// tests/test_match_property_read_serialization.zig can exercise the exact
// same lock sequence the handler uses without spinning up a full QUIC
// stack. DO NOT add production callers.
//
// When the fix for the MATCH-by-property write-lock regression lands, the
// handler code in both transports AND the mirror below must be updated at
// the same time. The intended fix is something like:
//
//     return if (is_mutation)
//         .{ .choice = .write, .handle = graph_store.acquireGraphWriteLock(name) }
//     else
//         .{ .choice = .read,  .handle = graph_store.acquireGraphReadLock(name) };
//
// Once that's in place, every concurrent-read test below should flip from
// FAIL to PASS without any further changes.

const std = @import("std");
const geode = @import("geode");
const graph_store = geode.graph_store;
const query_traits = geode.query_traits;
const ast = geode.ast;

/// Which store lock the transport handler chose for a given query.
pub const LockChoice = enum { none, read, write };

pub const AcquiredLock = struct {
    choice: LockChoice,
    handle: ?graph_store.GraphLockHandle,
};

/// Mirror of the inlined handler decision at
/// src/server/quic_connection_handler.zig:2302-2303.
///
/// `needs_store_lock` is `analysis.kind != .explain` in the handler.
/// `program`         is the parsed AST Program.
pub fn decideLockChoice(
    program: *const ast.Program,
    needs_store_lock: bool,
) LockChoice {
    if (!needs_store_lock) return .none;
    const is_mutation = query_traits.isMutatingProgram(program);
    // BUG (as of commit 0704009b):
    //   The handler *always* takes the write lock here regardless of
    //   `is_mutation`.  After the fix, this must become:
    //
    //       return if (is_mutation) .write else .read;
    //
    _ = is_mutation; // classifier is computed but unused — that's the bug
    return .write;
}

/// Acquire the same lock the transport handler would acquire for this
/// program.  Callers must release via `releaseHandlerLock`.
pub fn acquireHandlerLock(
    program: *const ast.Program,
    needs_store_lock: bool,
    graph_name: []const u8,
) AcquiredLock {
    const choice = decideLockChoice(program, needs_store_lock);
    return switch (choice) {
        .none => .{ .choice = .none, .handle = null },
        .read => .{ .choice = .read, .handle = graph_store.acquireGraphReadLock(graph_name) },
        .write => .{ .choice = .write, .handle = graph_store.acquireGraphWriteLock(graph_name) },
    };
}

pub fn releaseHandlerLock(acquired: AcquiredLock) void {
    if (acquired.handle) |h| graph_store.releaseGraphLock(h);
}
