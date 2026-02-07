const std = @import("std");
const grpc_zig = @import("grpc_server");
const TlsIo = grpc_zig.TlsIo;

const logging = @import("logging");
const log = logging.scoped("grpc-tls");
const Attr = logging.Attr;

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
    // Walk the client's ALPN protocol list (length-prefixed format)
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

/// Initialize the global TLS context with the given certificate and key files.
/// Must be called before any TLS connections are accepted.
pub fn initTlsContext(cert_path: [:0]const u8, key_path: [:0]const u8) !void {
    const method = c.TLS_server_method() orelse return error.TlsMethodFailed;
    const ctx = c.SSL_CTX_new(method) orelse return error.TlsCtxFailed;
    errdefer c.SSL_CTX_free(ctx);

    // Set minimum TLS version to 1.3
    if (c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_3_VERSION) != 1) {
        return error.TlsVersionFailed;
    }

    // Load certificate
    if (c.SSL_CTX_use_certificate_file(ctx, cert_path.ptr, c.SSL_FILETYPE_PEM) != 1) {
        log.err("Failed to load TLS certificate", &.{Attr.string("path", cert_path)});
        return error.TlsCertFailed;
    }

    // Load private key
    if (c.SSL_CTX_use_PrivateKey_file(ctx, key_path.ptr, c.SSL_FILETYPE_PEM) != 1) {
        log.err("Failed to load TLS private key", &.{Attr.string("path", key_path)});
        return error.TlsKeyFailed;
    }

    // Verify key matches certificate
    if (c.SSL_CTX_check_private_key(ctx) != 1) {
        return error.TlsKeyMismatch;
    }

    // Set server-side ALPN selection callback for HTTP/2 (required for gRPC)
    c.SSL_CTX_set_alpn_select_cb(ctx, alpnSelectCb, null);

    g_ssl_ctx = ctx;
    log.info("gRPC TLS context initialized", &.{
        Attr.string("cert", cert_path),
    });
}

/// Returns true if a TLS context has been successfully initialized.
pub fn hasTlsContext() bool {
    return g_ssl_ctx != null;
}

/// Free the global TLS context.
pub fn deinitTlsContext() void {
    if (g_ssl_ctx) |ctx| {
        c.SSL_CTX_free(ctx);
        g_ssl_ctx = null;
    }
}

/// Per-connection TLS state. Allocated on the heap so the pointer is stable.
const SslConn = struct {
    ssl: *c.SSL,
    fd: c_int,
};

/// Accept a TLS connection on the given stream.
/// Returns a TlsIo that wraps SSL_read/SSL_write/SSL_shutdown.
pub fn tlsAccept(stream: std.net.Stream) anyerror!TlsIo {
    const ctx = g_ssl_ctx orelse return error.TlsNotInitialized;

    const ssl_ptr = c.SSL_new(ctx) orelse return error.TlsSslNewFailed;
    errdefer c.SSL_free(ssl_ptr);

    const fd: c_int = stream.handle;
    if (c.SSL_set_fd(ssl_ptr, fd) != 1) {
        return error.TlsSetFdFailed;
    }

    const ret = c.SSL_accept(ssl_ptr);
    if (ret != 1) {
        const err_code = c.SSL_get_error(ssl_ptr, ret);
        log.err("TLS handshake failed", &.{Attr.int("ssl_error", err_code)});
        return error.TlsHandshakeFailed;
    }

    // Allocate stable SslConn on the heap
    const conn = std.heap.page_allocator.create(SslConn) catch return error.OutOfMemory;
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
            return 0; // Clean shutdown
        }
        return error.TlsReadFailed;
    }
    return @intCast(ret);
}

fn sslWrite(ctx_ptr: *anyopaque, data: []const u8) anyerror!usize {
    const conn: *SslConn = @ptrCast(@alignCast(ctx_ptr));
    const ret = c.SSL_write(conn.ssl, data.ptr, @intCast(data.len));
    if (ret <= 0) {
        return error.TlsWriteFailed;
    }
    return @intCast(ret);
}

fn sslClose(ctx_ptr: *anyopaque) void {
    const conn: *SslConn = @ptrCast(@alignCast(ctx_ptr));
    _ = c.SSL_shutdown(conn.ssl);
    c.SSL_free(conn.ssl);
    std.heap.page_allocator.destroy(conn);
}
