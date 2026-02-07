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

// --- Stub implementations for non-OpenSSL builds ---

fn stubInitTlsContext(_: [:0]const u8, _: [:0]const u8) !void {
    log.warn("gRPC TLS not available (OpenSSL not linked)", &.{});
    return error.TlsNotAvailable;
}

fn stubHasTlsContext() bool {
    return false;
}

fn stubDeinitTlsContext() void {}

fn stubTlsAccept(_: std.net.Stream) anyerror!TlsIo {
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
    };

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
                return 0;
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
} else struct {};
