// Task 26: TcpTransport roundtrip test.
//
// Zig 0.16's std lib reworked the net API into `std.Io.net.*`, so the
// plan's verbatim `std.net.tcpConnectToHost` / `addr.listen()` /
// `Server.accept()` sketch does not apply 1:1. The shape is the same
// though: bind a `std.Io.net.Server` on 127.0.0.1:0, read the kernel-
// assigned port back from `server.socket.address.getPort()`, connect
// in from a worker thread, and round-trip an LSP frame through the
// transport. `socketpair` is not an option on Linux because the kernel
// only supports it for `AF_UNIX`, not `AF_INET` — `createPair(.ip4)`
// returns `error.Unexpected` (ENOPROTOOPT / EAFNOSUPPORT depending on
// kernel version), so we use a real ephemeral-port listener.

const std = @import("std");
const testing = std.testing;
const transport_mod = @import("transport.zig");

const Roles = struct {
    server_tx: *transport_mod.Transport,
    payload: []const u8,
    write_result: ?anyerror = null,

    fn run(self: *Roles) void {
        self.server_tx.writeMessage(self.payload) catch |err| {
            self.write_result = err;
        };
    }
};

test "TcpTransport roundtrips an LSP frame over a real TCP listener" {
    // Threaded Io dispatcher — same backend StdioTransport reaches for
    // via `std.Io.Threaded.global_single_threaded.io()`. Local instance
    // keeps the test self-contained.
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Bind 127.0.0.1:0 → kernel picks an ephemeral port.
    const bind_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try std.Io.net.IpAddress.listen(&bind_addr, io, .{ .reuse_address = true });
    defer server.deinit(io);

    const port = server.socket.address.getPort();
    const connect_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);

    // Connect first, then accept, so this test stays single-threaded
    // for the listener side. The kernel buffers the SYN until accept
    // runs; both sides converge with no blocking.
    //
    // Actually we accept on a worker thread because `listen` is
    // blocking on POSIX and we need the connect() call to drive it
    // forward. Same pattern raft_consensus / metrics_server use.
    var accepted: ?std.Io.net.Stream = null;
    var accept_err: ?anyerror = null;
    const AcceptCtx = struct {
        s: *std.Io.net.Server,
        io: std.Io,
        out: *?std.Io.net.Stream,
        err: *?anyerror,
        fn run(ctx: *@This()) void {
            ctx.out.* = ctx.s.accept(ctx.io) catch |e| {
                ctx.err.* = e;
                return;
            };
        }
    };
    var accept_ctx = AcceptCtx{ .s = &server, .io = io, .out = &accepted, .err = &accept_err };
    const accept_thread = try std.Thread.spawn(.{}, AcceptCtx.run, .{&accept_ctx});

    const client_stream = try std.Io.net.IpAddress.connect(&connect_addr, io, .{ .mode = .stream });
    accept_thread.join();

    if (accept_err) |e| return e;
    const server_stream = accepted.?;

    var server_tx = try transport_mod.Transport.initTcp(testing.allocator, io, server_stream);
    defer server_tx.deinit();
    var client_rx = try transport_mod.Transport.initTcp(testing.allocator, io, client_stream);
    defer client_rx.deinit();

    // Send one LSP frame from the server side; read it from the
    // client side. Kernel socket buffer comfortably holds a 10-byte
    // payload + ~22-byte header, so a single synchronous write into
    // the kernel buffer suffices — no worker thread needed for the
    // write half.
    const payload = "{\"echo\":1}";
    try server_tx.writeMessage(payload);

    const msg = try client_rx.readMessage();
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings(payload, msg);
}
