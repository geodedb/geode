const std = @import("std");
const grpc_zig = @import("grpc_server");
const TlsIo = grpc_zig.TlsIo;

const logging = @import("logging");
const log = logging.scoped("grpc-tls");
const Attr = logging.Attr;

/// OpenSSL is only available on native non-Windows builds where the system
/// library is linked. For cross-compilation targets we provide stub
/// implementations so the code compiles but TLS is not functional.
pub const has_openssl = @import("openssl_config").enable_openssl;

/// Initialize the global TLS context with the given certificate and key files.
pub const initTlsContext = if (has_openssl) ssl_impl.initTlsContext else stubInitTlsContext;

/// Returns true if a TLS context has been successfully initialized.
pub const hasTlsContext = if (has_openssl) ssl_impl.hasTlsContext else stubHasTlsContext;

/// Free the global TLS context.
pub const deinitTlsContext = if (has_openssl) ssl_impl.deinitTlsContext else stubDeinitTlsContext;

/// Accept a TLS connection on the given stream.
pub const tlsAccept = if (has_openssl) ssl_impl.tlsAccept else stubTlsAccept;

/// Accept a plaintext connection and wrap it with write-all semantics.
/// Issue #479: grpc-zig's writeFrame ignores partial write return values from
/// ioWrite, which on aarch64 under load corrupts HTTP/2 framing. This wrapper
/// ensures all bytes are written before returning, preventing frame corruption.
pub fn rawAccept(stream: std.Io.net.Stream) anyerror!TlsIo {
    const conn = std.heap.c_allocator.create(RawConn) catch return error.OutOfMemory;
    conn.* = .{ .stream = stream };
    return TlsIo{
        .ctx = @ptrCast(conn),
        .read_fn = rawRead,
        .write_fn = rawWriteAll,
        .close_fn = rawClose,
    };
}

const RawConn = struct {
    stream: std.Io.net.Stream,
};

/// Unbuffered read honouring the read(2)-shaped `TlsIo.read_fn` contract:
/// consume at most `buf.len` bytes from the socket and return how many were
/// actually stored, or 0 on peer FIN (grpc-zig's `readExact` maps that to
/// `ConnectionClosed`).
///
/// This must NOT go through a buffered `std.Io.Reader`: `Reader.readVec`
/// hands readv(2) both the caller's buffer *and* its own internal buffer, so
/// any bytes past `buf.len` land in the internal buffer. A per-call reader
/// puts that buffer on the stack, silently discarding those bytes on return.
/// HTTP/2 peers routinely coalesce writes (preface+SETTINGS, HEADERS+DATA),
/// so the discarded tail desynchronises framing and `readFrame` blocks
/// forever. Mirror grpc-zig's own non-TLS `Transport.ioRead`: a single-iovec
/// `netRead` straight through the Io vtable.
fn rawRead(ctx_ptr: *anyopaque, buf: []u8) anyerror!usize {
    const conn: *RawConn = @ptrCast(@alignCast(ctx_ptr));
    const io_r = std.Io.Threaded.global_single_threaded.io();
    var bufs = [_][]u8{buf};
    return try io_r.vtable.netRead(io_r.userdata, conn.stream.socket.handle, &bufs);
}

/// Write all bytes to the stream, looping on partial writes.
///
/// Like `rawRead` this bypasses the buffered `std.Io.Writer` so no state has
/// to survive between calls; the loop provides the write-all semantics that
/// grpc-zig's `writeFrame` depends on (issue #479).
fn rawWriteAll(ctx_ptr: *anyopaque, data: []const u8) anyerror!usize {
    const conn: *RawConn = @ptrCast(@alignCast(ctx_ptr));
    const io_w = std.Io.Threaded.global_single_threaded.io();
    var total: usize = 0;
    while (total < data.len) {
        // `std.Io.Threaded.netWritePosix` indexes `data[data.len - 1]`
        // unconditionally, so the trailing-buffers slice must be non-empty.
        // Pass the remaining chunk as the sole trailing buffer with splat=1
        // and an empty header: it is written exactly once.
        const trailing = [_][]const u8{data[total..]};
        const n = try io_w.vtable.netWrite(io_w.userdata, conn.stream.socket.handle, "", &trailing, 1);
        if (n == 0) return error.ConnectionResetByPeer;
        total += n;
    }
    return total;
}

fn rawClose(ctx_ptr: *anyopaque) void {
    const conn: *RawConn = @ptrCast(@alignCast(ctx_ptr));
    // Don't close the stream fd here — Transport.ioClose() calls
    // stream.close() separately after calling our close_fn.
    std.heap.c_allocator.destroy(conn);
}

// --- Stub implementations for non-OpenSSL builds ---

fn stubInitTlsContext(_: [:0]const u8, _: [:0]const u8) !void {
    log.warn("gRPC TLS not available (OpenSSL not linked)", &.{});
    return error.TlsNotAvailable;
}

fn stubHasTlsContext() bool {
    return false;
}

fn stubDeinitTlsContext() void {}

fn stubTlsAccept(_: std.Io.net.Stream) anyerror!TlsIo {
    return error.TlsNotAvailable;
}

// --- Real OpenSSL implementation (only compiled on native non-Windows) ---

const ssl_impl = if (has_openssl) struct {
    const c = @cImport({
        @cInclude("openssl/ssl.h");
        @cInclude("openssl/err.h");
    });

    var g_ssl_ctx: ?*c.SSL_CTX = null;

    /// Server-side ALPN selection callback. Selects "h2" if the client offers it.
    fn alpnSelectCb(
        _: ?*c.SSL,
        out: [*c][*c]const u8,
        outlen: [*c]u8,
        in_buf: [*c]const u8,
        inlen: c_uint,
        _: ?*anyopaque,
    ) callconv(.c) c_int {
        const client_protos: [*]const u8 = @ptrCast(in_buf);
        var pos: usize = 0;
        while (pos < inlen) {
            const proto_len = client_protos[pos];
            pos += 1;
            if (pos + proto_len > inlen) break;
            if (proto_len == 2 and client_protos[pos] == 'h' and client_protos[pos + 1] == '2') {
                out.* = @ptrCast(client_protos + pos);
                outlen.* = 2;
                return c.SSL_TLSEXT_ERR_OK;
            }
            pos += proto_len;
        }
        return c.SSL_TLSEXT_ERR_NOACK;
    }

    pub fn initTlsContext(cert_path: [:0]const u8, key_path: [:0]const u8) !void {
        const method = c.TLS_server_method() orelse return error.TlsMethodFailed;
        const ctx = c.SSL_CTX_new(method) orelse return error.TlsCtxFailed;
        errdefer c.SSL_CTX_free(ctx);

        if (c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_3_VERSION) != 1) {
            return error.TlsVersionFailed;
        }

        if (c.SSL_CTX_use_certificate_file(ctx, cert_path.ptr, c.SSL_FILETYPE_PEM) != 1) {
            log.err("Failed to load TLS certificate", &.{Attr.string("path", cert_path)});
            return error.TlsCertFailed;
        }

        if (c.SSL_CTX_use_PrivateKey_file(ctx, key_path.ptr, c.SSL_FILETYPE_PEM) != 1) {
            log.err("Failed to load TLS private key", &.{Attr.string("path", key_path)});
            return error.TlsKeyFailed;
        }

        if (c.SSL_CTX_check_private_key(ctx) != 1) {
            return error.TlsKeyMismatch;
        }

        c.SSL_CTX_set_alpn_select_cb(ctx, alpnSelectCb, null);

        g_ssl_ctx = ctx;
        log.info("gRPC TLS context initialized", &.{
            Attr.string("cert", cert_path),
        });
    }

    pub fn hasTlsContext() bool {
        return g_ssl_ctx != null;
    }

    pub fn deinitTlsContext() void {
        if (g_ssl_ctx) |ctx| {
            c.SSL_CTX_free(ctx);
            g_ssl_ctx = null;
        }
    }

    const SslConn = struct {
        ssl: *c.SSL,
        fd: c_int,
        closed: bool = false,
    };

    pub fn tlsAccept(stream: std.Io.net.Stream) anyerror!TlsIo {
        const ctx = g_ssl_ctx orelse return error.TlsNotInitialized;

        const ssl_ptr = c.SSL_new(ctx) orelse return error.TlsSslNewFailed;
        errdefer c.SSL_free(ssl_ptr);

        const fd: c_int = stream.socket.handle;
        if (c.SSL_set_fd(ssl_ptr, fd) != 1) {
            return error.TlsSetFdFailed;
        }

        const ret = c.SSL_accept(ssl_ptr);
        if (ret != 1) {
            const err_code = c.SSL_get_error(ssl_ptr, ret);
            log.err("TLS handshake failed", &.{Attr.int("ssl_error", err_code)});
            return error.TlsHandshakeFailed;
        }

        const conn = std.heap.c_allocator.create(SslConn) catch return error.OutOfMemory;
        conn.* = .{ .ssl = ssl_ptr, .fd = fd };

        return TlsIo{
            .ctx = @ptrCast(conn),
            .read_fn = sslRead,
            .write_fn = sslWrite,
            .close_fn = sslClose,
        };
    }

    fn sslRead(ctx_ptr: *anyopaque, buf: []u8) anyerror!usize {
        const conn: *SslConn = @ptrCast(@alignCast(ctx_ptr));
        const ret = c.SSL_read(conn.ssl, buf.ptr, @intCast(buf.len));
        if (ret <= 0) {
            const err_code = c.SSL_get_error(conn.ssl, ret);
            if (err_code == c.SSL_ERROR_ZERO_RETURN) {
                return 0;
            }
            return error.TlsReadFailed;
        }
        return @intCast(ret);
    }

    /// Write all bytes through TLS, looping on partial writes.
    /// Issue #479: SSL_write can return fewer bytes than requested on aarch64
    /// under load. Without looping, writeFrame sends partial HTTP/2 frames,
    /// corrupting the connection and causing segfaults.
    fn sslWrite(ctx_ptr: *anyopaque, data: []const u8) anyerror!usize {
        const conn: *SslConn = @ptrCast(@alignCast(ctx_ptr));
        var total: usize = 0;
        while (total < data.len) {
            const remaining = data.len - total;
            const ret = c.SSL_write(conn.ssl, data[total..].ptr, @intCast(remaining));
            if (ret <= 0) {
                return error.TlsWriteFailed;
            }
            total += @as(usize, @intCast(ret));
        }
        return total;
    }

    fn sslClose(ctx_ptr: *anyopaque) void {
        const conn: *SslConn = @ptrCast(@alignCast(ctx_ptr));
        if (conn.closed) return;
        conn.closed = true;
        // Skip SSL_shutdown — on aarch64, calling it when the peer has
        // disconnected abruptly (e.g. TLS cert probe) causes a segfault
        // in OpenSSL. SSL_shutdown only sends a courtesy close_notify
        // alert; SSL_free handles all resource cleanup and is always safe.
        c.SSL_free(conn.ssl);
        std.heap.c_allocator.destroy(conn);
    }
} else struct {};

// =============================================================================
// Tests for writeAll behavior (#479)
// =============================================================================

/// Mock stream that simulates partial writes, returning at most `chunk_size`
/// bytes per write call. Used to verify the writeAll loop logic.
const MockPartialStream = struct {
    allocator: std.mem.Allocator,
    written: std.ArrayList(u8),
    chunk_size: usize,
    write_count: usize = 0,
    fail_after: ?usize = null, // Fail after N writes

    fn init(allocator: std.mem.Allocator, chunk_size: usize) MockPartialStream {
        return .{
            .allocator = allocator,
            .written = .empty,
            .chunk_size = chunk_size,
        };
    }

    fn initFailAfter(allocator: std.mem.Allocator, chunk_size: usize, fail_after: usize) MockPartialStream {
        return .{
            .allocator = allocator,
            .written = .empty,
            .chunk_size = chunk_size,
            .fail_after = fail_after,
        };
    }

    fn deinit(self: *MockPartialStream) void {
        self.written.deinit(self.allocator);
    }

    fn write(self: *MockPartialStream, data: []const u8) !usize {
        if (self.fail_after) |limit| {
            if (self.write_count >= limit) return error.BrokenPipe;
        }
        self.write_count += 1;
        const to_write = @min(data.len, self.chunk_size);
        try self.written.appendSlice(self.allocator, data[0..to_write]);
        return to_write;
    }
};

/// Standalone writeAll implementation matching rawWriteAll's logic,
/// operating on a MockPartialStream for testability.
fn testWriteAll(mock: *MockPartialStream, data: []const u8) !usize {
    var total: usize = 0;
    while (total < data.len) {
        const n = mock.write(data[total..]) catch |err| return err;
        if (n == 0) return error.ConnectionClosed;
        total += n;
    }
    return total;
}

test "writeAll: complete write in single call" {
    var mock = MockPartialStream.init(std.testing.allocator, 1024);
    defer mock.deinit();
    const data = "Hello, world!";
    const n = try testWriteAll(&mock, data);
    try std.testing.expectEqual(data.len, n);
    try std.testing.expectEqualStrings(data, mock.written.items);
    try std.testing.expectEqual(@as(usize, 1), mock.write_count);
}

test "writeAll: partial writes are retried" {
    var mock = MockPartialStream.init(std.testing.allocator, 3);
    defer mock.deinit();
    const data = "Hello, world!";
    const n = try testWriteAll(&mock, data);
    try std.testing.expectEqual(data.len, n);
    try std.testing.expectEqualStrings(data, mock.written.items);
    // 13 bytes / 3 bytes per write = 5 writes (3+3+3+3+1)
    try std.testing.expectEqual(@as(usize, 5), mock.write_count);
}

test "writeAll: single byte chunks" {
    var mock = MockPartialStream.init(std.testing.allocator, 1);
    defer mock.deinit();
    const data = "ABCDEF";
    const n = try testWriteAll(&mock, data);
    try std.testing.expectEqual(data.len, n);
    try std.testing.expectEqualStrings(data, mock.written.items);
    try std.testing.expectEqual(@as(usize, 6), mock.write_count);
}

test "writeAll: empty data is no-op" {
    var mock = MockPartialStream.init(std.testing.allocator, 1024);
    defer mock.deinit();
    const n = try testWriteAll(&mock, "");
    try std.testing.expectEqual(@as(usize, 0), n);
    try std.testing.expectEqual(@as(usize, 0), mock.write_count);
}

test "writeAll: write error propagated" {
    var mock = MockPartialStream.initFailAfter(std.testing.allocator, 3, 0);
    defer mock.deinit();
    const result = testWriteAll(&mock, "Hello");
    try std.testing.expectError(error.BrokenPipe, result);
}

test "writeAll: error after partial progress" {
    var mock = MockPartialStream.initFailAfter(std.testing.allocator, 3, 2);
    defer mock.deinit();
    // Writes 3 + 3 = 6 bytes, then fails on the 3rd write
    const result = testWriteAll(&mock, "Hello, world!");
    try std.testing.expectError(error.BrokenPipe, result);
    // First 6 bytes were written before the error
    try std.testing.expectEqualStrings("Hello,", mock.written.items);
}

test "writeAll: large buffer with small chunks" {
    var mock = MockPartialStream.init(std.testing.allocator, 7);
    defer mock.deinit();
    // Simulate a 9-byte HTTP/2 frame header being written in partial chunks
    const frame_header = [_]u8{ 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01 };
    const n = try testWriteAll(&mock, &frame_header);
    try std.testing.expectEqual(@as(usize, 9), n);
    try std.testing.expectEqualSlices(u8, &frame_header, mock.written.items);
    // 9 bytes / 7 bytes per write = 2 writes (7+2)
    try std.testing.expectEqual(@as(usize, 2), mock.write_count);
}

test "writeAll: simulated rapid sequential writes" {
    // Simulates the #479 scenario: many rapid sequential writes with partial completions
    var mock = MockPartialStream.init(std.testing.allocator, 5);
    defer mock.deinit();
    const messages = [_][]const u8{
        "MERGE (a:Node {id: 1})",
        "MERGE (b:Node {id: 2})",
        "CREATE (a)-[:REL]->(b)",
        "MERGE (c:Node {id: 3})",
        "MERGE (d:Node {id: 4})",
        "CREATE (c)-[:REL]->(d)",
    };
    var total_written: usize = 0;
    for (messages) |msg| {
        const n = try testWriteAll(&mock, msg);
        try std.testing.expectEqual(msg.len, n);
        total_written += n;
    }
    try std.testing.expectEqual(total_written, mock.written.items.len);
}

/// Connected AF_UNIX stream pair for the raw-I/O regressions below. Zig 0.16's
/// `std.posix` no longer re-exports `socketpair`, so go through libc directly
/// (`link_libc` is already required by this module for OpenSSL).
fn testSocketPair() ![2]std.posix.socket_t {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
    // A regression in `rawRead` shows up as a read that never completes: the
    // swallowed tail is simply gone and the socket has nothing left to give.
    // Bound the receive side so the suite fails fast instead of wedging CI.
    const timeout = std.posix.timeval{ .sec = 5, .usec = 0 };
    try std.posix.setsockopt(fds[0], std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
    return fds;
}

/// Zig 0.16's `std.posix` dropped `write`/`close` too; keep the test-only libc
/// shims next to `testSocketPair` rather than sprinkling `std.c` calls around.
fn testClose(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

fn testWrite(fd: std.posix.fd_t, data: []const u8) !usize {
    const rc = std.c.write(fd, data.ptr, data.len);
    switch (std.posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

/// Build a `Stream` around an existing fd. Only `socket.handle` is read by the
/// `netRead`/`netWrite` vtable entries these tests exercise; the address is
/// never inspected, so a zeroed loopback placeholder is sufficient (a
/// `socketpair` has no IP address to report).
fn testStreamFromFd(fd: std.posix.socket_t) std.Io.net.Stream {
    return .{ .socket = .{
        .handle = fd,
        .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } },
    } };
}

test "rawAccept: creates valid TlsIo" {
    // We can't test with a real stream in unit tests, but we can verify the
    // function constructs a valid TlsIo with non-null function pointers.
    // Use a dummy fd that won't be used (we'll destroy immediately).
    const dummy_stream = testStreamFromFd(-1);
    const tls_io = try rawAccept(dummy_stream);
    try std.testing.expect(tls_io.read_fn == rawRead);
    try std.testing.expect(tls_io.write_fn == rawWriteAll);
    try std.testing.expect(tls_io.close_fn == rawClose);
    // Clean up the allocated RawConn
    tls_io.close_fn(tls_io.ctx);
}

// CANARY: REQ=REQ-ENG-3907-GRPC-TRANSPORT; FEATURE="GrpcTransport"; ASPECT=RawReadCoalescedFrames; STATUS=TESTED; TEST=test-grpc-raw-io; OWNER=transport; UPDATED=2026-08-25
//
// Regression for the gRPC plaintext frame-loss hang. `rawRead` used to build a
// fresh `[4096]u8` stack buffer + fresh `Stream.Reader` on every call;
// `Reader.readVec` hands readv(2) BOTH the caller's buffer and that internal
// buffer, so everything past `buf.len` landed in the stack-local and died with
// the frame. HTTP/2 peers coalesce writes (preface+SETTINGS, HEADERS+DATA), so
// the server silently dropped the tail of every coalesced write and `readFrame`
// blocked forever.
//
// A `socketpair` reproduces the shape exactly and deterministically: one write
// far larger than the first read buffer, then drain in small reads. Every byte
// must survive.
test "rawRead: coalesced peer write survives small reads (no buffered-reader tail loss)" {
    const fds = try testSocketPair();
    defer testClose(fds[1]);

    const tls_io = try rawAccept(testStreamFromFd(fds[0]));
    defer {
        tls_io.close_fn(tls_io.ctx);
        testClose(fds[0]);
    }

    // One coalesced write, far larger than the first read buffer below.
    var payload: [512]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i);
    try std.testing.expectEqual(payload.len, try testWrite(fds[1], &payload));

    // First read takes only a 9-byte HTTP/2 frame header's worth. The old
    // implementation swallowed the other 503 bytes into a stack buffer here.
    var head: [9]u8 = undefined;
    try std.testing.expectEqual(@as(usize, head.len), try tls_io.read_fn(tls_io.ctx, &head));
    try std.testing.expectEqualSlices(u8, payload[0..9], &head);

    // The remainder must still be readable from the socket.
    var rest: [payload.len - 9]u8 = undefined;
    var total: usize = 0;
    while (total < rest.len) {
        const n = try tls_io.read_fn(tls_io.ctx, rest[total..]);
        try std.testing.expect(n != 0); // 0 would mean the tail was lost to FIN
        total += n;
    }
    try std.testing.expectEqualSlices(u8, payload[9..], &rest);
}

test "rawRead: peer FIN reports 0 so readExact maps to ConnectionClosed" {
    const fds = try testSocketPair();

    const tls_io = try rawAccept(testStreamFromFd(fds[0]));
    defer {
        tls_io.close_fn(tls_io.ctx);
        testClose(fds[0]);
    }

    testClose(fds[1]);

    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try tls_io.read_fn(tls_io.ctx, &buf));
}

test "rawWriteAll: round-trips a full buffer through the socket" {
    const fds = try testSocketPair();
    defer testClose(fds[1]);

    const tls_io = try rawAccept(testStreamFromFd(fds[0]));
    defer {
        tls_io.close_fn(tls_io.ctx);
        testClose(fds[0]);
    }

    var payload: [1024]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i *% 7);

    try std.testing.expectEqual(payload.len, try tls_io.write_fn(tls_io.ctx, &payload));

    var got: [payload.len]u8 = undefined;
    var total: usize = 0;
    while (total < got.len) {
        const n = try std.posix.read(fds[1], got[total..]);
        try std.testing.expect(n != 0);
        total += n;
    }
    try std.testing.expectEqualSlices(u8, &payload, &got);
}
