// Regression test for the REPL `:use <graph>` leak observed at shell exit.
//
// User-reported crash on May 01 2026:
//
//   geode> ^C
//   error(DebugAllocator): memory address 0x7f6285ec0010 leaked:
//   src/client/repl/repl_dispatch.zig:2361:59: handleMetaCommand
//       state.session.graph = try state.allocator.dupe(u8, graph_name);
//   src/client/repl/repl_loop.zig:878:52: processInput
//   src/cli/main.zig:3030:27: cmdShell
//
// Root cause: `ClientSession.deinit` (src/client/repl/repl_dispatch.zig:784)
// frees seven owned fields (`server_addr`, `last_response`, `session_id`,
// `cached_username`, `cached_password`, `last_reconnect_error`,
// `last_txn_error`) but never `self.graph` (declared at line 736 with
// type `?[]const u8`). When `:use mygraph` populates `session.graph`
// via `state.allocator.dupe(u8, graph_name)` at line 2361, that
// allocation persists for the rest of the process — DebugAllocator
// catches it on shutdown.
//
// The fix adds a single `if (self.graph) |g| { self.allocator.free(g);
// self.graph = null; }` block to `ClientSession.deinit`. This test
// exercises the same lifecycle the REPL meta-command does:
//   1. init the session (no connect — we pass a dummy transport)
//   2. assign session.graph = allocator.dupe(...) (the production line)
//   3. defer session.deinit()
//   4. testing.allocator (DebugAllocator) fails the test on leak.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const repl_dispatch = geode.repl.repl_dispatch;

// A dummy transport whose `connectFn` is never invoked: the session is
// not connected during the test. Using a dummy avoids spinning up a
// QUIC server just to verify the deinit lifecycle.
fn dummyConnect(_: std.mem.Allocator, _: []const u8) anyerror!*repl_dispatch.TransportConnection {
    return error.NotImplemented;
}

const dummy_transport: repl_dispatch.Transport = .{ .connectFn = dummyConnect };

test "ClientSession.deinit frees the `graph` field set via :use" {
    const allocator = testing.allocator;

    var session = try repl_dispatch.ClientSession.init(
        allocator,
        "127.0.0.1:0",
        &dummy_transport,
    );
    defer session.deinit();

    // Mirror exactly what `:use mygraph` does at
    // src/client/repl/repl_dispatch.zig:2361:
    session.graph = try allocator.dupe(u8, "mygraph");
}

// Latent bug companion: `repl_loop.zig:86` and `:176` set
// `session.graph = opts.graph` (a borrowed string from CLI argv). If the
// user then runs `:use <other>`, the meta-command's
// `if (state.session.graph) |old_graph| state.allocator.free(old_graph);`
// at line 2360 would attempt to free that borrowed slice — undefined
// behaviour at best, allocator panic at worst. The matching fix dup's
// `opts.graph` at the assignment site so `session.graph` is always
// allocator-owned. This test verifies the documented invariant: any
// `session.graph` value in the production code path must be freeable
// by `session.deinit` and `:use`'s rebind block.
test "ClientSession.graph rebind path matches the post-fix owned-only invariant" {
    const allocator = testing.allocator;

    var session = try repl_dispatch.ClientSession.init(
        allocator,
        "127.0.0.1:0",
        &dummy_transport,
    );
    defer session.deinit();

    // 1. Initial assignment — post-fix `repl_loop.zig` dup's `opts.graph`.
    session.graph = try allocator.dupe(u8, "from-cli");

    // 2. Simulate `:use other` (repl_dispatch.zig:2360-2361):
    //    free old, dup new. After the fix this is sound regardless of
    //    whether the original came from CLI args or a previous :use.
    if (session.graph) |old_graph| allocator.free(old_graph);
    session.graph = try allocator.dupe(u8, "other");

    // 3. Second :use to verify the loop is stable.
    if (session.graph) |old_graph| allocator.free(old_graph);
    session.graph = try allocator.dupe(u8, "third");

    // deinit (via defer above) must free the final value.
}
