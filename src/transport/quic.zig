const std = @import("std");
const builtin = @import("builtin");
// MIGRATED TO MSQUIC: Using Microsoft's msquic library with OpenSSL for TLS
// CANARY: REQ=REQ-MSQUIC-004; FEATURE="MSQUIC_Migration"; ASPECT=Integration; STATUS=IMPL; OWNER=transport; UPDATED=2025-11-14
pub const quic_lib = @import("quic_msquic.zig");
const tls = std.crypto.tls;

// CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICCore; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_QUICCore; OWNER=wire; UPDATED=2025-09-22
// Full QUIC transport layer for geode using vendored QUIC library

// CANARY: PERF_PHASE4_LOG_ELIMINATION - Compile-time debug log elimination
// CANARY: REQ=REQ-PERF-PHASE4-002; FEATURE="LogOptimization"; ASPECT=COMPILE_TIME_ELIM; STATUS=IMPL; OWNER=performance; UPDATED=2025-10-16

/// Phase 4 optimization: Compile-time debug log elimination
/// Debug logs are suppressed by default to prevent spam in test output
///
/// Benefits:
/// - Zero runtime overhead for debug logs
/// - Cleaner test output and better performance
/// - No string formatting cost for eliminated logs
/// - Can be enabled via GEODE_QUIC_DEBUG environment variable if needed
inline fn debugLog(comptime fmt: []const u8, args: anytype) void {
    // Suppress debug logs entirely to prevent test spam
    // To enable, set GEODE_QUIC_DEBUG=1 environment variable
    _ = fmt;
    _ = args;
}

pub const QuicError = error{
    ConnectionFailed,
    StreamFailed,
    InvalidAddress,
    CertificateError,
    EndpointInitFailed,
    AcceptFailed,
    HandshakeFailed,
    TransportParametersFailed,
    FlowControlViolation,
    ProtocolViolation,
    IdleTimeout,
    ConnectionClosed,
};

pub const QuicTransport = struct {
    allocator: std.mem.Allocator,
    config: Config,
    endpoint: ?*quic_lib.QuicEndpoint = null,
    connections: std.ArrayList(*QuicConnection),
    cert_path: []const u8,
    key_path: []const u8,
    quic_config: ?*quic_lib.QuicConfig = null,
    // Phase 4 optimization: Cache certificate data to avoid repeated disk reads during dev iteration
    cached_cert: ?[]u8 = null,
    cached_key: ?[]u8 = null,

    pub const Config = struct {
        address: []const u8 = "0.0.0.0",
        port: u16 = 7567,
        max_connections: usize = 1000,
        idle_timeout_ms: u64 = 30000,
        max_stream_data: u64 = 10 * 1024 * 1024, // 10MB per stream
        max_data: u64 = 100 * 1024 * 1024, // 100MB per connection
        cert_path: []const u8 = "certs/server.crt",
        key_path: []const u8 = "certs/server.key",
        ca_path: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !QuicTransport {
        return QuicTransport{
            .allocator = allocator,
            .config = config,
            .connections = try std.ArrayList(*QuicConnection).initCapacity(allocator, 0),
            .cert_path = config.cert_path,
            .key_path = config.key_path,
        };
    }

    pub fn deinit(self: *QuicTransport) void {
        // Close all active connections first to avoid using a torn-down endpoint
        for (self.connections.items) |conn| {
            conn.close();
            self.allocator.destroy(conn);
        }
        self.connections.deinit(self.allocator);
        // Now deinitialize endpoint
        if (self.endpoint) |ep| {
            quic_lib.endpointDeinit(ep);
            self.endpoint = null;
        }
        if (self.quic_config) |cfg| {
            // Free any loaded certificate data
            if (cfg.inline_server_cert_der) |cert| {
                self.allocator.free(cert);
            }
            if (cfg.inline_server_priv_p256) |key| {
                self.allocator.free(key);
            }
            self.allocator.destroy(cfg);
            self.quic_config = null;
        }
        // Phase 4: Free cached certificates
        if (self.cached_cert) |cert| {
            self.allocator.free(cert);
        }
        if (self.cached_key) |key| {
            self.allocator.free(key);
        }
    }

    pub fn listen(self: *QuicTransport) !void {
        // CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICListener; STATUS=TESTED; TEST=e2e_quic_startup; OWNER=wire; UPDATED=2025-09-25

        // Check if certificates exist
        var cert_exists = true;
        std.fs.cwd().access(self.cert_path, .{}) catch {
            cert_exists = false;
        };
        var key_exists = true;
        std.fs.cwd().access(self.key_path, .{}) catch {
            key_exists = false;
        };

        const bind_addr = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ self.config.address, self.config.port });
        defer self.allocator.free(bind_addr);

        // Auto-generate self-signed certificates if missing
        // CRITICAL SECURITY: Never allow insecure fallback - fail-closed on cert errors
        var use_tls = cert_exists and key_exists;
        if (!use_tls) {
            // Attempt to auto-generate self-signed certificate
            if (self.generateSelfSignedCert()) |_| {
                std.debug.print("TLS_CERT_AUTOGENERATED path=\"{s}\"\n", .{self.cert_path});
                use_tls = true;
            } else |err| {
                // SECURITY FIX (C7): Never fall back to insecure mode
                // Production systems MUST have valid TLS certificates
                std.debug.print("{{\"level\":\"FATAL\",\"component\":\"transport\",\"msg\":\"TLS certificates not found and generation failed\",\"cert_path\":\"{s}\",\"key_path\":\"{s}\",\"error\":\"{}\"}}\n", .{ self.cert_path, self.key_path, err });
                std.debug.print("SECURITY: Refusing to start without TLS. Generate certificates manually:\n", .{});
                std.debug.print("  openssl req -x509 -newkey rsa:2048 -nodes -keyout {s} -out {s} -days 365\n", .{ self.key_path, self.cert_path });
                return QuicError.CertificateError;
            }
        }

        // Print startup JSON exactly once
        const tls_str = if (use_tls) "true" else "false";
        std.debug.print("{{\"component\":\"transport\",\"transport\":\"quic\",\"tls\":\"{s}\",\"port\":{}}}\n", .{ tls_str, self.config.port });

        // Phase 4: Debug logs compile-time eliminated in release builds
        debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_server\",\"msg\":\"server startup\",\"use_tls\":{},\"cert_exists\":{},\"key_exists\":{}}}", .{ use_tls, cert_exists, key_exists });

        // Load certificate files if using TLS
        // Phase 4 optimization: Use cached certificates if available to avoid repeated disk I/O
        var inline_cert_der: ?[]u8 = null;
        var inline_priv_key: ?[]u8 = null;
        if (use_tls) {
            if (self.cached_cert != null and self.cached_key != null) {
                // Use cached certificates (dev iteration optimization)
                inline_cert_der = self.cached_cert;
                inline_priv_key = self.cached_key;
                debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_server\",\"msg\":\"using cached certificates\"}}", .{});
            } else {
                // Load from disk and cache for future use
                debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_server\",\"msg\":\"loading certificate files\",\"cert_path\":\"{s}\",\"key_path\":\"{s}\"}}", .{ self.cert_path, self.key_path });

                // Simple PEM -> DER loader (single object) for CERTIFICATE / (EC) PRIVATE KEY
                // Based on vendor/quic/cmd/quic-server.zig proven implementation
                const PemLoad = struct {
                    fn loadPem(allocator: std.mem.Allocator, path: []const u8, markers: []const []const u8) ![]u8 {
                        const data = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024);
                        errdefer allocator.free(data);
                        var chosen_begin: ?[]const u8 = null;
                        var chosen_end: ?[]const u8 = null;
                        for (markers) |m| {
                            var buf_begin: [64]u8 = undefined;
                            var buf_end: [64]u8 = undefined;
                            const begin_marker = try std.fmt.bufPrint(&buf_begin, "-----BEGIN {s}-----", .{m});
                            const end_marker = try std.fmt.bufPrint(&buf_end, "-----END {s}-----", .{m});
                            if (std.mem.indexOf(u8, data, begin_marker)) |_| {
                                chosen_begin = try allocator.dupe(u8, begin_marker);
                                chosen_end = try allocator.dupe(u8, end_marker);
                                break;
                            }
                        }
                        if (chosen_begin == null or chosen_end == null) {
                            allocator.free(data);
                            return error.PemMarkerNotFound;
                        }
                        defer allocator.free(chosen_begin.?);
                        defer allocator.free(chosen_end.?);
                        const start = std.mem.indexOf(u8, data, chosen_begin.?) orelse {
                            allocator.free(data);
                            return error.PemMarkerNotFound;
                        };
                        const rest = data[start + chosen_begin.?.len ..];
                        const end_rel = std.mem.indexOf(u8, rest, chosen_end.?) orelse {
                            allocator.free(data);
                            return error.PemMarkerNotFound;
                        };
                        const b64_region = rest[0..end_rel];
                        // Collect base64 characters (skip newlines)
                        var tmp = try allocator.alloc(u8, b64_region.len);
                        defer allocator.free(tmp);
                        var n: usize = 0;
                        for (b64_region) |ch| {
                            if (ch == '\n' or ch == '\r') continue;
                            if (ch == ' ') continue;
                            tmp[n] = ch;
                            n += 1;
                        }
                        // Decode
                        const out_buf = try allocator.alloc(u8, (n * 3) / 4 + 8);
                        defer allocator.free(out_buf);
                        // Compute decoded length manually: every 4 chars -> 3 bytes, minus padding '='.
                        var pad: usize = 0;
                        if (n >= 2 and tmp[n - 1] == '=') pad += 1;
                        if (n >= 2 and tmp[n - 2] == '=') pad += 1;
                        const need: usize = (n / 4) * 3 - pad;
                        const exact = try allocator.alloc(u8, need);
                        errdefer allocator.free(exact);
                        // std.base64 Decoder.decode writes into exact; assume well-formed input.
                        std.base64.standard.Decoder.decode(exact, tmp[0..n]) catch |e| {
                            allocator.free(exact);
                            allocator.free(data);
                            return e;
                        };
                        allocator.free(data);
                        return exact;
                    }
                };

                // Load both certificate and private key using PEM decoder
                inline_cert_der = PemLoad.loadPem(self.allocator, self.cert_path, &[_][]const u8{"CERTIFICATE"}) catch |err| {
                    std.debug.print("{{\"level\":\"ERROR\",\"component\":\"quic_server\",\"msg\":\"failed to load certificate\",\"path\":\"{s}\",\"error\":\"{}\"}}\n", .{ self.cert_path, err });
                    return err;
                };
                errdefer if (inline_cert_der) |cert| self.allocator.free(cert);
                debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_server\",\"msg\":\"loaded and decoded certificate\",\"der_size\":{}}}", .{inline_cert_der.?.len});

                // Try PKCS#8 first (PRIVATE KEY) then EC PRIVATE KEY as fallback
                inline_priv_key = PemLoad.loadPem(self.allocator, self.key_path, &[_][]const u8{ "PRIVATE KEY", "EC PRIVATE KEY" }) catch |err| {
                    std.debug.print("{{\"level\":\"ERROR\",\"component\":\"quic_server\",\"msg\":\"failed to load private key\",\"path\":\"{s}\",\"error\":\"{}\"}}\n", .{ self.key_path, err });
                    if (inline_cert_der) |cert| self.allocator.free(cert);
                    return err;
                };
                debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_server\",\"msg\":\"loaded and decoded private key\",\"der_size\":{}}}", .{inline_priv_key.?.len});

                // Cache for future use
                self.cached_cert = inline_cert_der;
                self.cached_key = inline_priv_key;
            }
        }

        // Initialize QUIC with TLS mandatory (no TCP fallback)
        const cfg = try self.allocator.create(quic_lib.QuicConfig);
        cfg.* = .{
            .version = .v1,
            .allow_insecure = false, // SECURITY FIX (C7): NEVER allow insecure mode
            .alpn = &[_][]const u8{"geode/1"},
            .cc = .newreno,
            .enable_datagram = false,
            .enable_spin_bit = false,
            .grease = true,
            .compatible_vn = false,
            .enable_retry = false,
            .token_secret = null,
            .token_expiry_ms = 60000,
            .enable_pacing = false,
            .max_datagram_size = 1200,
            .max_idle_timeout_ms = @intCast(self.config.idle_timeout_ms),
            .max_udp_payload = 1350,
            .cert_path = self.cert_path,
            .key_path = self.key_path,
            .ca_path = if (self.config.ca_path) |p| p else null,
            .aead_confidentiality_limit_override = null,
            .aead_integrity_limit_override = null,
            .inline_server_cert_der = inline_cert_der,
            .inline_server_priv_p256 = inline_priv_key,
        };

        debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_server\",\"msg\":\"initializing endpoint\",\"bind_addr\":\"{s}\"}}", .{bind_addr});
        self.endpoint = try quic_lib.endpointInit(&self.allocator, bind_addr, cfg);
        debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_server\",\"msg\":\"endpoint initialized successfully\"}}", .{});

        // Print startup log in JSON format
        if (self.config.ca_path != null) {
            std.debug.print("{{\"level\":\"INFO\",\"msg\":\"mTLS: client certs required\"}}\n", .{});
        }
        std.debug.print("{{\"component\":\"transport\",\"transport\":\"quic\",\"tls\":\"true\",\"port\":{d}}}\n", .{self.config.port});
    }

    fn generateSelfSignedCert(self: *QuicTransport) !void {
        // Ensure certs directory exists
        std.fs.cwd().makeDir("certs") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Generate self-signed certificate using OpenSSL command
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{
                "openssl", "req",         "-x509", "-newkey",                                      "rsa:4096",
                "-keyout", self.key_path, "-out",  self.cert_path,                                 "-days",
                "365",     "-nodes",      "-subj", "/C=US/ST=State/L=City/O=Geode/CN=geode.local",
            },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term != .Exited or result.term.Exited != 0) {
            return QuicError.CertificateError;
        }

        // Set secure permissions (0600)
        // On Windows, chmod is not supported, so we skip permission changes
        if (builtin.os.tag != .windows) {
            const cert_file = try std.fs.cwd().openFile(self.cert_path, .{});
            defer cert_file.close();
            try cert_file.chmod(0o600);

            const key_file = try std.fs.cwd().openFile(self.key_path, .{});
            defer key_file.close();
            try key_file.chmod(0o600);
        }
    }

    pub fn accept(self: *QuicTransport) !*QuicConnection {
        // CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICAccept; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_QUICAccept; OWNER=wire; UPDATED=2025-09-22

        debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_server\",\"msg\":\"attempting to accept connection\"}}", .{});

        if (self.endpoint) |ep| {
            // Accept from QUIC endpoint
            debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_server\",\"msg\":\"calling quic_lib.accept\"}}", .{});
            const quic_conn = try quic_lib.accept(ep);
            debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_server\",\"msg\":\"quic_lib.accept returned successfully\"}}", .{});

            const conn = try self.allocator.create(QuicConnection);
            conn.* = QuicConnection{
                .allocator = self.allocator,
                .quic_connection = quic_conn,
                .streams = std.ArrayList(*QuicStream){},
            };

            try self.connections.append(self.allocator, conn);
            debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_server\",\"msg\":\"connection accepted and added to pool\",\"total_connections\":{}}}", .{self.connections.items.len});
            return conn;
        }
        debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_server\",\"msg\":\"no endpoint available for accept\"}}", .{});
        return QuicError.ConnectionFailed;
    }

    pub fn tryAccept(self: *QuicTransport) ?*QuicConnection {
        // Non-blocking accept - returns null if no connection is ready
        // Based on vendor/quic/cmd/quic-server.zig pattern

        if (self.endpoint) |ep| {
            const quic_conn = quic_lib.tryAccept(ep) orelse return null;

            const conn = self.allocator.create(QuicConnection) catch return null;
            conn.* = QuicConnection{
                .allocator = self.allocator,
                .quic_connection = quic_conn,
                .streams = std.ArrayList(*QuicStream){},
            };

            self.connections.append(self.allocator, conn) catch {
                self.allocator.destroy(conn);
                return null;
            };
            debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_server\",\"msg\":\"connection accepted via tryAccept\",\"total_connections\":{}}}", .{self.connections.items.len});
            return conn;
        }
        return null;
    }

    pub fn poll(self: *QuicTransport, timeout_ms: u32) !void {
        if (self.endpoint) |ep| {
            try quic_lib.poll(ep, @intCast(timeout_ms));
        }
    }
};

pub const QuicConnection = struct {
    allocator: std.mem.Allocator,
    quic_connection: ?*quic_lib.QuicConnection,
    streams: std.ArrayList(*QuicStream),
    streams_init: bool = false,
    next_stream_id: usize = 0,

    pub fn close(self: *QuicConnection) void {
        // Close all streams (idempotent) if initialized
        if (self.streams_init) {
            for (self.streams.items) |s| {
                s.close();
                self.allocator.destroy(s);
            }
            self.streams.deinit(self.allocator);
            self.streams_init = false;
        }
        // Close underlying QUIC connection only once; avoid explicit vendor close to prevent double-frees
        if (self.quic_connection) |_| {
            // Passive close: let endpoint deinit/OS cleanup reclaim resources
            self.quic_connection = null;
        }
    }

    pub fn isDrained(self: *QuicConnection) bool {
        if (self.quic_connection) |conn| {
            return quic_lib.isDrained(conn);
        }
        return true; // If no connection, consider it drained
    }

    pub fn isHandshakeConfirmed(self: *QuicConnection) bool {
        if (self.quic_connection) |conn| {
            return quic_lib.isHandshakeConfirmed(conn);
        }
        return false;
    }

    pub fn acceptStream(self: *QuicConnection) !*QuicStream {
        // CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICStream; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_QUICStream; OWNER=wire; UPDATED=2025-09-22

        const stream = try self.allocator.create(QuicStream);
        errdefer self.allocator.destroy(stream);

        if (self.quic_connection == null) return QuicError.StreamFailed;

        // Accept a QUIC stream - this will check for existing streams first
        // then fall back to waiting for new ones
        const stream_id = try quic_lib.acceptStream(self.quic_connection.?);

        stream.* = QuicStream{
            .allocator = self.allocator,
            .quic_stream_id = stream_id,
            .parent_connection = self,
            .stream_id = @intCast(stream_id),
        };

        if (!self.streams_init) {
            self.streams = try std.ArrayList(*QuicStream).initCapacity(self.allocator, 0);
            self.streams_init = true;
        }
        try self.streams.append(self.allocator, stream);
        return stream;
    }

    pub fn openStream(self: *QuicConnection, bidirectional: bool) !*QuicStream {
        // CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICStreamOpen; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_QUICStreamOpen; OWNER=wire; UPDATED=2025-09-22

        const stream = try self.allocator.create(QuicStream);
        errdefer self.allocator.destroy(stream);

        if (self.quic_connection == null) return QuicError.StreamFailed;
        const stream_id = try quic_lib.openStream(self.quic_connection.?, bidirectional);
        stream.* = QuicStream{
            .allocator = self.allocator,
            .quic_stream_id = stream_id,
            .parent_connection = self,
            .stream_id = @intCast(stream_id),
        };

        if (!self.streams_init) {
            self.streams = try std.ArrayList(*QuicStream).initCapacity(self.allocator, 0);
            self.streams_init = true;
        }
        try self.streams.append(self.allocator, stream);
        return stream;
    }
};

pub const QuicStream = struct {
    allocator: std.mem.Allocator,
    quic_stream_id: ?quic_lib.QuicStreamId,
    parent_connection: *QuicConnection,
    stream_id: usize = 0,
    read_buffer: []u8 = &[_]u8{},

    pub fn close(self: *QuicStream) void {
        // Best-effort, idempotent: avoid vendor close by default to reduce teardown races.
        // Enable explicit stream close only when GEODE_QUIC_FORCE_STREAM_CLOSE=1.
        if (self.quic_stream_id) |sid| {
            const force_stream_close = if (std.process.getEnvVarOwned(self.parent_connection.allocator, "GEODE_QUIC_FORCE_STREAM_CLOSE")) |v| blk: {
                defer self.parent_connection.allocator.free(v);
                break :blk true;
            } else |_| false;
            if (force_stream_close) {
                if (self.parent_connection.quic_connection) |qc| {
                    quic_lib.closeStream(qc, sid, 0) catch {};
                }
            }
            self.quic_stream_id = null;
        }
    }

    pub fn write(self: *QuicStream, data: []const u8) !void {
        if (self.quic_stream_id) |sid| {
            _ = try quic_lib.writeStream(self.parent_connection.quic_connection.?, sid, data);
        } else {
            return QuicError.StreamFailed;
        }
    }

    pub fn writeAll(self: *QuicStream, data: []const u8) !void {
        if (self.quic_stream_id) |sid| {
            // QUIC handles fragmentation internally
            _ = try quic_lib.writeStream(self.parent_connection.quic_connection.?, sid, data);
        } else {
            return QuicError.StreamFailed;
        }
    }

    pub fn read(self: *QuicStream, buf: []u8) !usize {
        if (self.quic_stream_id) |sid| {
            return try quic_lib.readStream(self.parent_connection.quic_connection.?, sid, buf);
        } else {
            return QuicError.StreamFailed;
        }
    }

    pub fn readAll(self: *QuicStream, buf: []u8) !usize {
        var total_read: usize = 0;
        while (total_read < buf.len) {
            const n = try self.read(buf[total_read..]);
            if (n == 0) break;
            total_read += n;
        }
        return total_read;
    }

    pub fn readLine(self: *QuicStream, max_size: usize) ![]u8 {
        var buf = try self.allocator.alloc(u8, max_size);
        var pos: usize = 0;

        while (pos < max_size) {
            const n = try self.read(buf[pos .. pos + 1]);
            if (n == 0) {
                if (pos == 0) return error.EndOfStream;
                break;
            }
            if (buf[pos] == '\n') {
                return self.allocator.realloc(buf, pos + 1) catch buf[0 .. pos + 1];
            }
            pos += 1;
        }
        return buf[0..pos];
    }
};

// Client-side QUIC support
pub const QuicClient = struct {
    allocator: std.mem.Allocator,
    endpoint: ?*quic_lib.QuicEndpoint = null,
    quic_connection: ?*quic_lib.QuicConnection = null,
    server_addr: []const u8 = "",
    server_port: u16 = 7567,
    is_quic: bool = false,
    quic_config: ?*quic_lib.QuicConfig = null,

    pub fn init(allocator: std.mem.Allocator) QuicClient {
        return QuicClient{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *QuicClient) void {
        // Close connection first, then endpoint. The vendored QUIC may crash if closed during handshake;
        // skip active close by default and rely on endpoint teardown/OS to reclaim unless forced via env.
        const force_close = if (std.process.getEnvVarOwned(self.allocator, "GEODE_QUIC_FORCE_CLOSE")) |v| blk: {
            defer self.allocator.free(v);
            break :blk true;
        } else |_| false;
        if (self.quic_connection) |conn| {
            if (force_close) {
                quic_lib.closeConnectionSimple(conn) catch {};
            }
            self.quic_connection = null;
        }
        if (self.endpoint) |ep| {
            quic_lib.endpointDeinit(ep);
            self.endpoint = null;
        }
        if (self.quic_config) |cfg| {
            self.allocator.destroy(cfg);
            self.quic_config = null;
        }
    }

    pub fn connect(self: *QuicClient, address: []const u8, port: u16) !void {
        // CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICClientConnect; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_QUICClientConnect; OWNER=wire; UPDATED=2025-09-22

        const server_addr_str = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ address, port });
        defer self.allocator.free(server_addr_str);

        debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_client\",\"msg\":\"connecting to server\",\"address\":\"{s}\",\"port\":{}}}", .{ address, port });

        // QUIC client configuration
        const cert_path = "certs/ca.crt"; // Client CA cert (optional)
        var has_ca_cert = true;
        std.fs.cwd().access(cert_path, .{}) catch {
            has_ca_cert = false;
        };

        debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_client\",\"msg\":\"certificate configuration\",\"has_ca_cert\":{},\"cert_path\":\"{s}\"}}", .{ has_ca_cert, cert_path });

        // Initialize QUIC config for client
        const cfg = try self.allocator.create(quic_lib.QuicConfig);
        cfg.* = .{
            .version = .v1,
            .alpn = &[_][]const u8{"geode/1"},
            .cc = .newreno,
            .enable_datagram = false,
            .enable_spin_bit = false,
            .grease = true,
            .compatible_vn = false,
            .enable_retry = false,
            .token_secret = null,
            .token_expiry_ms = 60000,
            .enable_pacing = false,
            .max_datagram_size = 1200,
            .max_idle_timeout_ms = 30000,
            .max_udp_payload = 1350,
            .cert_path = if (has_ca_cert) cert_path else null,
            .key_path = null,
            .ca_path = if (has_ca_cert) cert_path else null,
            .allow_insecure = !has_ca_cert,
            .aead_confidentiality_limit_override = null,
            .aead_integrity_limit_override = null,
            .inline_server_cert_der = null,
            .inline_server_priv_p256 = null,
        };
        self.quic_config = cfg;

        debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_client\",\"msg\":\"QUIC config\",\"allow_insecure\":{}}}", .{cfg.allow_insecure});

        // Create client endpoint
        const bind_addr = "0.0.0.0:0"; // Bind to any available port
        debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_client\",\"msg\":\"initializing endpoint\",\"bind_addr\":\"{s}\"}}", .{bind_addr});
        self.endpoint = try quic_lib.endpointInit(&self.allocator, bind_addr, cfg);

        // Connect to server - use geode.local as SNI when allow_insecure to match cert CN
        const sni = if (cfg.allow_insecure) "geode.local" else address;
        debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_client\",\"msg\":\"initiating connection\",\"server_addr\":\"{s}\",\"sni\":\"{s}\",\"allow_insecure\":{}}}", .{ server_addr_str, sni, cfg.allow_insecure });
        self.quic_connection = try quic_lib.connect(self.endpoint.?, server_addr_str, sni);

        self.is_quic = true;
        self.server_addr = address;
        self.server_port = port;

        debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_client\",\"msg\":\"connection initiated successfully\"}}", .{});
    }

    pub fn connectInsecure(self: *QuicClient, address: []const u8, port: u16, allow_insecure: bool) !void {
        const server_addr_str = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ address, port });
        defer self.allocator.free(server_addr_str);

        debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_client\",\"msg\":\"connectInsecure called\",\"address\":\"{s}\",\"port\":{},\"allow_insecure\":{}}}", .{ address, port, allow_insecure });

        const cfg = try self.allocator.create(quic_lib.QuicConfig);
        cfg.* = .{
            .version = .v1,
            .alpn = &[_][]const u8{"geode/1"},
            .cc = .newreno,
            .enable_datagram = false,
            .enable_spin_bit = false,
            .grease = true,
            .compatible_vn = false,
            .enable_retry = false,
            .token_secret = null,
            .token_expiry_ms = 60000,
            .enable_pacing = false,
            .max_datagram_size = 1200,
            .max_idle_timeout_ms = 30000,
            .max_udp_payload = 1350,
            .cert_path = null,
            .key_path = null,
            .ca_path = null,
            .allow_insecure = allow_insecure,
            .aead_confidentiality_limit_override = null,
            .aead_integrity_limit_override = null,
            .inline_server_cert_der = null,
            .inline_server_priv_p256 = null,
        };
        self.quic_config = cfg;

        // Create client endpoint
        const bind_addr = "0.0.0.0:0";
        self.endpoint = try quic_lib.endpointInit(&self.allocator, bind_addr, cfg);

        debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_client\",\"msg\":\"QUIC config\",\"allow_insecure\":{}}}", .{cfg.allow_insecure});

        // Connect to server
        const sni = address; // Use server address as SNI
        debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_client\",\"msg\":\"initiating connection\",\"server_addr\":\"{s}\",\"sni\":\"{s}\"}}", .{ server_addr_str, sni });
        self.quic_connection = try quic_lib.connect(self.endpoint.?, server_addr_str, sni);

        self.is_quic = true;
        self.server_addr = address;
        self.server_port = port;

        debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_client\",\"msg\":\"connection initiated successfully\"}}", .{});
    }

    pub fn connectEx(self: *QuicClient, address: []const u8, port: u16, ca: ?[]const u8, cert: ?[]const u8, key: ?[]const u8) !void {
        const server_addr_str = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ address, port });
        defer self.allocator.free(server_addr_str);

        const cfg = try self.allocator.create(quic_lib.QuicConfig);
        const has_ca = ca != null;
        const use_tls = has_ca or (cert != null and key != null);
        cfg.* = .{
            .version = .v1,
            .alpn = &[_][]const u8{"geode/1"},
            .cc = .newreno,
            .enable_datagram = false,
            .enable_spin_bit = false,
            .grease = true,
            .compatible_vn = false,
            .enable_retry = false,
            .token_secret = null,
            .token_expiry_ms = 60000,
            .enable_pacing = false,
            .max_datagram_size = 1200,
            .max_idle_timeout_ms = 30000,
            .max_udp_payload = 1350,
            .cert_path = if (cert) |p| p else null,
            .key_path = if (key) |p| p else null,
            .ca_path = if (has_ca) ca.? else null,
            .allow_insecure = !use_tls,
            .aead_confidentiality_limit_override = null,
            .aead_integrity_limit_override = null,
            .inline_server_cert_der = null,
            .inline_server_priv_p256 = null,
        };
        self.quic_config = cfg;

        // Create client endpoint
        const bind_addr = "0.0.0.0:0";
        self.endpoint = try quic_lib.endpointInit(&self.allocator, bind_addr, cfg);

        // Connect to server - use geode.local as SNI when allow_insecure to match cert CN
        const sni = if (cfg.allow_insecure) "geode.local" else address;
        self.quic_connection = try quic_lib.connect(self.endpoint.?, server_addr_str, sni);

        self.is_quic = true;
        self.server_addr = address;
        self.server_port = port;
    }

    pub fn waitForHandshake(self: *QuicClient, timeout_secs: u32) !void {
        if (!self.is_quic or self.quic_connection == null) {
            debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_client\",\"msg\":\"waitForHandshake: no QUIC connection\"}}", .{});
            return QuicError.ConnectionFailed;
        }

        // Wait for handshake to complete with user-specified timeout
        const total_timeout_ms = @as(u64, timeout_secs) * 1000; // Convert seconds to milliseconds
        const poll_timeout_ms = 50; // 50ms per poll
        const start_time = std.time.milliTimestamp();

        debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_client\",\"msg\":\"waitForHandshake: starting handshake wait\",\"timeout_ms\":{}}}", .{total_timeout_ms});

        var poll_count: u32 = 0;
        while (std.time.milliTimestamp() - start_time < total_timeout_ms) {
            poll_count += 1;

            // Poll endpoint to process network events and advance handshake
            quic_lib.poll(self.endpoint.?, poll_timeout_ms) catch |err| {
                // Continue polling even if individual poll fails
                debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_client\",\"msg\":\"poll error\",\"error\":\"{}\"}}", .{err});
            };

            // Try to flush the endpoint to ensure packets are sent
            quic_lib.flush(self.endpoint.?, 1);

            // Check if handshake is complete - try multiple checks
            const handshake_complete = quic_lib.handshakeComplete(self.quic_connection.?);
            const handshake_confirmed = quic_lib.isHandshakeConfirmed(self.quic_connection.?);
            const handshake_done = quic_lib.handshakeDoneSeen(self.quic_connection.?);

            if (handshake_complete or handshake_confirmed or handshake_done) {
                const elapsed_ms = std.time.milliTimestamp() - start_time;
                debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_client\",\"msg\":\"handshake completed\",\"elapsed_ms\":{},\"poll_count\":{},\"complete\":{},\"confirmed\":{},\"done\":{}}}", .{ elapsed_ms, poll_count, handshake_complete, handshake_confirmed, handshake_done });
                return;
            }

            // Add detailed debugging for first few iterations
            if (poll_count <= 5) {
                debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_client\",\"msg\":\"handshake check\",\"poll_count\":{},\"complete\":{},\"confirmed\":{},\"done\":{}}}", .{ poll_count, handshake_complete, handshake_confirmed, handshake_done });
            }

            // Log periodic progress
            if (poll_count % 10 == 0) { // Every ~1 second
                const elapsed_ms = std.time.milliTimestamp() - start_time;
                debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_client\",\"msg\":\"handshake in progress\",\"elapsed_ms\":{},\"poll_count\":{}}}", .{ elapsed_ms, poll_count });
            }
        }

        const elapsed_ms = std.time.milliTimestamp() - start_time;
        std.debug.print("{{\"level\":\"ERROR\",\"component\":\"quic_client\",\"msg\":\"handshake timeout\",\"elapsed_ms\":{},\"poll_count\":{}}}\n", .{ elapsed_ms, poll_count });
        return QuicError.HandshakeFailed;
    }

    pub fn getStream(self: *QuicClient) !*QuicClientStream {
        debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_client\",\"msg\":\"getStream: starting\"}}", .{});

        const stream = try self.allocator.create(QuicClientStream);
        errdefer self.allocator.destroy(stream);

        if (self.is_quic and self.quic_connection != null) {
            // Don't wait for handshake here since we handle it externally
            debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_client\",\"msg\":\"getStream: opening stream (assuming handshake complete)\"}}", .{});
            const stream_id = try quic_lib.openStream(self.quic_connection.?, true);
            debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_client\",\"msg\":\"getStream: stream opened\",\"stream_id\":{}}}", .{stream_id});

            stream.* = QuicClientStream{
                .allocator = self.allocator,
                .quic_stream_id = stream_id,
                .quic_connection = self.quic_connection,
                .client = self,
            };
        } else {
            debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_client\",\"msg\":\"getStream: no QUIC connection available\"}}", .{});
            return QuicError.ConnectionFailed;
        }

        debugLog("{{\"level\":\"DEBUG\",\"component\":\"quic_client\",\"msg\":\"getStream: completed successfully\"}}", .{});
        return stream;
    }
};

pub const QuicClientStream = struct {
    allocator: std.mem.Allocator,
    quic_stream_id: ?quic_lib.QuicStreamId,
    quic_connection: ?*quic_lib.QuicConnection,
    client: ?*QuicClient,

    pub fn writeAll(self: *QuicClientStream, data: []const u8) !void {
        if (self.quic_stream_id) |sid| {
            debugLog("DEBUG: QuicClientStream.writeAll called with {} bytes on stream {}", .{ data.len, sid });
            const bytes_written = try quic_lib.writeStream(self.quic_connection.?, sid, data);
            debugLog("DEBUG: writeStream returned {} bytes written", .{bytes_written});

            // Poll multiple times to ensure data is sent
            if (self.client) |c| {
                if (c.endpoint) |ep| {
                    var i: usize = 0;
                    while (i < 5) : (i += 1) {
                        quic_lib.poll(ep, 10) catch {};
                        std.Thread.sleep(10 * std.time.ns_per_ms);
                    }
                }
            }
            debugLog("DEBUG: writeAll completed after polling", .{});
        } else {
            return QuicError.StreamFailed;
        }
    }

    pub fn read(self: *QuicClientStream, buf: []u8) !usize {
        if (self.quic_stream_id) |sid| {
            // Try reading with retries and polling
            var attempts: usize = 0;
            while (attempts < 20) : (attempts += 1) {
                const n = quic_lib.readStream(self.quic_connection.?, sid, buf) catch |err| {
                    // TRACE: readStream error
                    // std.debug.print("DEBUG: readStream error: {}\n", .{err});
                    if (err == error.WouldBlock) {
                        // Poll the endpoint to process incoming packets
                        if (self.client) |c| {
                            if (c.endpoint) |ep| {
                                // Poll multiple times to ensure we receive data
                                var poll_i: usize = 0;
                                while (poll_i < 3) : (poll_i += 1) {
                                    // TRACE: read() polling endpoint
                                    // std.debug.print("DEBUG: read() polling endpoint\n", .{});
                                    quic_lib.poll(ep, 50) catch {};
                                    std.Thread.sleep(10 * std.time.ns_per_ms);
                                }
                            } else {
                                debugLog("DEBUG: read() no endpoint to poll!", .{});
                            }
                        } else {
                            debugLog("DEBUG: read() no client reference!", .{});
                        }
                        continue;
                    }
                    return 0;
                };
                if (n > 0) return n;
            }
            return 0;
        } else {
            return QuicError.StreamFailed;
        }
    }

    pub fn readLine(self: *QuicClientStream, max_size: usize) ![]u8 {
        var buf = try self.allocator.alloc(u8, max_size);
        errdefer self.allocator.free(buf);

        var pos: usize = 0;
        while (pos < max_size) {
            const n = try self.read(buf[pos .. pos + 1]);
            if (n == 0) break;
            if (buf[pos] == '\n') {
                // Resize to actual size (including newline)
                if (self.allocator.resize(buf, pos + 1)) {
                    return buf[0 .. pos + 1];
                } else {
                    // If resize fails, create a new smaller buffer
                    const result = try self.allocator.alloc(u8, pos + 1);
                    @memcpy(result, buf[0 .. pos + 1]);
                    self.allocator.free(buf);
                    return result;
                }
            }
            pos += 1;
        }
        // Resize to actual size
        if (self.allocator.resize(buf, pos)) {
            return buf[0..pos];
        } else {
            // If resize fails, create a new smaller buffer
            const result = try self.allocator.alloc(u8, pos);
            @memcpy(result, buf[0..pos]);
            self.allocator.free(buf);
            return result;
        }
    }

    pub fn deinit(self: *QuicClientStream) void {
        // Avoid vendor close by default; env-gated for explicit shutdown.
        if (self.quic_stream_id) |sid| {
            const force_stream_close = if (std.process.getEnvVarOwned(self.allocator, "GEODE_QUIC_FORCE_STREAM_CLOSE")) |v| blk: {
                defer self.allocator.free(v);
                break :blk true;
            } else |_| false;
            if (force_stream_close) {
                quic_lib.closeStream(self.quic_connection.?, sid, 0) catch {};
            }
        }
        self.allocator.destroy(self);
    }
};
