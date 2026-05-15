// CANARY: REQ=REQ-LSP-EMBEDDED-E2E-001; FEATURE="LspPermissionAwareCompletion"; ASPECT=EmbeddedTcpAuthGate; STATUS=TESTED; TEST=tests/test_lsp_embedded_e2e.zig; OWNER=lsp; UPDATED=2026-05-14
//
// Task 29 of the LSP permission-aware completion plan.
//
// End-to-end smoke test for the embedded `geode serve` LSP TCP listener.
// The full schema-completion path that this plan ultimately targets is
// blocked behind Task 28's intentionally null `Verifier` — embedded
// sessions are spun up with `verifier=null` + `allow_unauth=false` until
// the AuthProvider→Verifier adapter (a follow-up plan task) lands. So we
// exercise the smallest end-to-end slice that is currently testable:
//
//   1. Bind a real ephemeral-port `std.Io.net.Server` on 127.0.0.1.
//   2. Spawn a worker thread that accepts one connection, wraps it in a
//      `TcpTransport`, and drives a `Server.initWithTransport(.., null,
//      false)` session — byte-for-byte the same construction
//      `runLspSession` uses in `src/server/main.zig`.
//   3. Connect a client `TcpTransport` from the test thread.
//   4. Send a JSON-RPC `initialize` request with NO `geode.authToken`.
//   5. Read the response. Assert it's a JSON-RPC error with code
//      `-32002` ("ServerNotInitialized") and a `message` mentioning the
//      missing token — i.e. the fail-closed auth gate works end-to-end
//      over the LSP TCP transport.
//   6. Close the client socket. The server's `readMessage` returns
//      `EndOfStream`, `run()` exits, the worker thread joins.
//
// This proves: TCP listen + accept + per-session Transport + Server
// construction + handleInitialize + bindSession + respondInitializeError
// + writeMessage framing all hang together over a real socket. The test
// is deterministic, completes in < 1 s on a developer laptop, and leaks
// neither sockets nor threads.
//
// Why this file lives under `tests/` instead of `src/cli/lsp/`:
//   The other LSP unit tests are pure (no real networking) and run under
//   the `lsp_tests` runner. This test spins up a server thread + binds a
//   real TCP socket, so it gets its own build module + standalone
//   `test-lsp-embedded-e2e` step in `build.zig` — same pattern the Task
//   26 `tcp_transport_test` block already uses. Keeping it out of the
//   main runner avoids dragging a multi-threaded network harness into
//   what is otherwise a deterministic single-threaded suite.

const std = @import("std");
const testing = std.testing;

// Zig 0.16 forbids relative `@import("../src/...")` from a `tests/`-
// rooted build module ("file outside module path"), so build.zig
// surfaces server.zig as a named `lsp_server` import. We deliberately
// do NOT also create a separate `lsp_transport` named module — that
// would put `transport.zig` in two distinct modules (Zig rejects with
// "file exists in modules X and X0"). Instead we reach `Transport`
// through the public `Server.transport` field via `@TypeOf` on an
// undefined value; that's a comptime-only access so no real Server is
// constructed.
//
// `lsp_server` carries its own `geode` + `schema_introspection` named
// imports because server.zig (transitively schema_provider.zig,
// auth.zig, features.zig) reach into those modules.
//
// No file-diamond: this test file is its own root and is NOT included
// in the `lsp_tests` runner (see src/cli/lsp/test_runner.zig).
const server_mod = @import("lsp_server");
const Server = server_mod.Server;
/// `Transport` is the type of `Server.transport`. Recovered via
/// `@TypeOf` because the type alias `const Transport` inside server.zig
/// is private; the field itself is `pub` through the `pub const Server`
/// struct declaration.
const Transport = @TypeOf(@as(Server, undefined).transport);

/// Args struct for the server-side worker thread. The listener has
/// already been bound on the test thread; the worker takes ownership of
/// the listener (for the single accept) but does NOT deinit it — the
/// test thread owns that lifetime.
const ServerArgs = struct {
    listener: *std.Io.net.Server,
    io: std.Io,
    allocator: std.mem.Allocator,
    /// Set to a non-null error if any step of the server-side bring-up
    /// fails. The test thread checks this after joining the worker.
    err: ?anyerror = null,
};

fn runServerThread(args: *ServerArgs) void {
    // One accept — same shape `runLspListener` uses, just without the
    // outer `while (true)` so this thread terminates after the test's
    // single client disconnects.
    const accepted = args.listener.accept(args.io) catch |e| {
        args.err = e;
        return;
    };

    var tx = Transport.initTcp(args.allocator, args.io, accepted) catch |e| {
        // initTcp failed → close the FD ourselves, then surface.
        accepted.close(args.io);
        args.err = e;
        return;
    };
    // Server.initWithTransport takes ownership of `tx`; its deinit tears
    // the transport down (and therefore closes the socket).
    var srv = Server.initWithTransport(args.allocator, tx, null, false) catch |e| {
        tx.deinit();
        args.err = e;
        return;
    };
    defer srv.deinit();

    // Drive one full request → reject → EndOfStream cycle. `run()` does
    // not return until the client closes (or shutdown is requested).
    // EndOfStream is the EXPECTED termination — `run()` itself swallows
    // it and exits the loop without surfacing the error to its caller.
    srv.run() catch |e| {
        args.err = e;
    };
}

test "embedded LSP listener rejects initialize without auth (JSON-RPC -32002)" {
    const alloc = testing.allocator;

    // Dedicated `Io.Threaded` for the test lifetime — same pattern Task
    // 26's `tcp_transport_test` and Task 28's `runLspListener` use.
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 127.0.0.1:0 — kernel picks an ephemeral port. Identical to the
    // Task 26 bring-up.
    const bind_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try std.Io.net.IpAddress.listen(&bind_addr, io, .{ .reuse_address = true });
    defer listener.deinit(io);

    const port = listener.socket.address.getPort();
    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

    // Spawn the server worker BEFORE we connect — accept() on Zig
    // 0.16's `Io.Threaded` blocks the worker until a SYN arrives, and
    // the kernel queues the connect until the listener is in accept().
    var server_args = ServerArgs{
        .listener = &listener,
        .io = io,
        .allocator = alloc,
    };
    const server_thread = try std.Thread.spawn(.{}, runServerThread, .{&server_args});

    // Client side: build a TcpTransport on the connected socket so we
    // reuse the same Content-Length framing the server's response uses.
    const client_stream = try std.Io.net.IpAddress.connect(&connect_addr, io, .{ .mode = .stream });
    var client_tx = Transport.initTcp(alloc, io, client_stream) catch |e| {
        client_stream.close(io);
        server_thread.join();
        return e;
    };
    // client_tx owns the socket from here. We do NOT `defer client_tx.deinit()`
    // because we deliberately close it mid-test (before joining the worker)
    // so the server's readMessage loop sees EndOfStream and run() returns —
    // otherwise we would deadlock on `server_thread.join()`. Manually
    // tearing it down before the join is the cleanest lifetime path.
    errdefer client_tx.deinit();

    // JSON-RPC `initialize` with NO `initializationOptions.geode`. This
    // is the exact shape `bindSession` rejects with
    // `AuthError.MissingToken` → "missing auth token" → -32002.
    const initialize_body =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":null}}
    ;
    try client_tx.writeMessage(initialize_body);

    // Read the response. TcpTransport.readMessage() blocks until a full
    // Content-Length-framed JSON-RPC frame arrives.
    const response_body = try client_tx.readMessage();
    defer alloc.free(response_body);

    // Parse + assert the shape. The response MUST be:
    //   {"jsonrpc":"2.0","id":1,"error":{"code":-32002,"message":"missing auth token"}}
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response_body, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);

    const root = parsed.value.object;
    try testing.expectEqualStrings("2.0", root.get("jsonrpc").?.string);
    // id round-trips as an integer because we sent `"id":1`.
    try testing.expectEqual(@as(i64, 1), root.get("id").?.integer);

    const err_val = root.get("error") orelse return error.MissingErrorField;
    try testing.expect(err_val == .object);
    const err_obj = err_val.object;
    try testing.expectEqual(@as(i64, -32002), err_obj.get("code").?.integer);

    // The message is one of the AuthError → string mappings in
    // `respondInitializeError`. For a missing `geode` block we expect
    // "missing auth token"; we assert the substring rather than the
    // full string so a future tweak to the wording does not break the
    // test as long as the semantic remains.
    const msg = err_obj.get("message").?.string;
    try testing.expect(std.mem.indexOf(u8, msg, "missing auth token") != null);

    // Close the client side first → server's next readMessage returns
    // EndOfStream → `run()` exits → worker thread joinable.
    client_tx.deinit();
    server_thread.join();

    // Any non-EndOfStream error from the worker is a real test failure.
    // run() swallows EndOfStream into a clean exit (server.zig:262), so
    // the common-case `args.err` should be null.
    if (server_args.err) |e| {
        if (e != error.EndOfStream) return e;
    }
}
