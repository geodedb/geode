const std = @import("std");

// VENDOR QUIC MIGRATION COMPLETE - 2025-11-20
// This module now uses the vendor/quic library's native Endpoint API
// Following the pattern from vendor/quic/echo_quic_server.zig

// CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICCore; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_QUICCore; OWNER=wire; UPDATED=2025-11-21

const logging = @import("logging");
const tlog = logging.scoped("transport");
const Attr = logging.Attr;

// Import the QUIC modules through the vendor API which re-exports them
const api = @import("vendor_quic");
const Endpoint = api.QuicEndpoint;
const Connection = api.QuicConnection;
const VendorQuicConfig = api.QuicConfig;

// Re-export core types
pub const QuicError = error{
    InitFailed,
    ConnectionFailed,
    StreamFailed,
    WriteError,
    ReadError,
    CertificateError,
    HandshakeError,
    Timeout,
    WouldBlock,
    Closed,
    InvalidState,
};

inline fn debugLog(comptime fmt: []const u8, args: anytype) void {
    _ = fmt;
    _ = args;
}

/// Readers-writer synchronization for QUIC endpoint poll() vs handler I/O.
///
/// The vendored QUIC library's `ep.poll()` processes frames for ALL connections,
/// updating their internal HashMaps (`stream_txs`, etc.). Handler threads
/// concurrently call `readStream()`/`writeStream()` on the same connections.
/// Without synchronization, concurrent HashMap access causes SIGABRT.
///
/// This implements a readers-writer pattern:
/// - Handler threads are "readers" (can do I/O concurrently with each other)
/// - The main thread is the "writer" (needs exclusive access for poll())
///
/// Uses SeqCst ordering to ensure a total order and eliminate TOCTOU races.
pub const PollSync = struct {
    /// Set to true by the main thread when it wants to poll.
    /// Handler threads check this before starting I/O and back off if set.
    poll_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Count of handler threads currently performing connection I/O.
    active_io_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Called by handler threads before I/O. Blocks until safe to proceed.
    pub fn enterIo(self: *PollSync) void {
        while (true) {
            // Increment count first, then check flag — this ordering with SeqCst
            // guarantees that either we see poll_requested=true (and back off),
            // or the main thread sees our incremented count (and waits for us).
            _ = self.active_io_count.fetchAdd(1, .seq_cst);
            if (!self.poll_requested.load(.seq_cst)) return; // Safe to proceed
            // Poll was requested — back off and wait
            _ = self.active_io_count.fetchSub(1, .seq_cst);
            while (self.poll_requested.load(.seq_cst)) {
                std.Thread.sleep(50 * std.time.ns_per_us);
            }
        }
    }

    /// Called by handler threads after I/O.
    pub fn leaveIo(self: *PollSync) void {
        _ = self.active_io_count.fetchSub(1, .seq_cst);
    }

    /// Called by the main thread before poll(). Blocks until all I/O finishes.
    pub fn enterPoll(self: *PollSync) void {
        self.poll_requested.store(true, .seq_cst);
        while (self.active_io_count.load(.seq_cst) > 0) {
            std.Thread.sleep(50 * std.time.ns_per_us);
        }
    }

    /// Called by the main thread after poll().
    pub fn leavePoll(self: *PollSync) void {
        self.poll_requested.store(false, .seq_cst);
    }
};

pub const QuicTransport = struct {
    allocator: std.mem.Allocator,
    config: Config,
    endpoint: ?Endpoint = null,
    connections: std.ArrayList(*QuicConnection),
    // GAP-0202: Mutex for thread-safe connection list access in async mode
    connections_mutex: std.Thread.Mutex = .{},
    // GAP-0203: Deferred connection destruction to prevent use-after-free.
    // Handler threads add inner connections here after sending CONNECTION_CLOSE;
    // the main accept loop thread processes them via drainPendingDestroy()
    // where endpoint bookkeeping can be safely updated without racing with poll().
    pending_destroy: std.ArrayList(*Connection) = .empty,
    pending_destroy_mutex: std.Thread.Mutex = .{},
    /// Readers-writer sync: handler threads are "readers" (concurrent I/O),
    /// main thread is the "writer" (exclusive poll). See PollSync docs.
    poll_sync: PollSync = .{},
    cert_der: ?[]u8 = null,
    key_der: ?[]u8 = null,

    pub const Config = struct {
        address: []const u8 = "0.0.0.0",
        port: u16 = 7567,
        max_connections: usize = 1000,
        idle_timeout_ms: u64 = 300000,
        max_stream_data: u64 = 10 * 1024 * 1024,
        max_data: u64 = 100 * 1024 * 1024,
        cert_path: []const u8 = "certs/server.crt",
        key_path: []const u8 = "certs/server.key",
        ca_path: ?[]const u8 = null,
        /// Allow insecure TLS connections (skip certificate validation)
        /// SECURITY: Default is false. Only set to true for testing with self-signed certificates.
        /// GAP-0105 FIX: Changed default from true to false for secure-by-default behavior.
        allow_insecure: bool = false,
        /// Require client certificates for mTLS authentication over QUIC.
        /// When true, connections without a valid client certificate will be rejected.
        /// CANARY: REQ=REQ-AUTH-MTLS-QUIC-002; FEATURE="mTLS over QUIC"; ASPECT=Config; STATUS=IMPL; OWNER=transport; UPDATED=2026-02-13
        require_client_cert: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !QuicTransport {
        return QuicTransport{
            .allocator = allocator,
            .config = config,
            .connections = try std.ArrayList(*QuicConnection).initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *QuicTransport) void {
        // GAP-0203: Process any deferred connection cleanups first.
        // These are inner connections queued by handler threads via destroyConnection().
        self.drainPendingDestroy();

        for (self.connections.items) |conn| {
            conn.close();
            self.allocator.destroy(conn);
        }
        self.connections.deinit(self.allocator);
        self.pending_destroy.deinit(self.allocator);

        if (self.endpoint) |*ep| {
            ep.deinit();
            self.endpoint = null;
        }

        if (self.cert_der) |cert| {
            self.allocator.free(cert);
        }
        if (self.key_der) |key| {
            self.allocator.free(key);
        }
    }

    /// Process deferred connection destructions queued by handler threads.
    /// MUST be called from the main accept loop thread (the same thread that
    /// calls poll()/accept()) to avoid racing with endpoint packet processing.
    /// GAP-0203: Fix use-after-free race condition between handler threads
    /// calling deinit() and the main thread's poll() accessing freed memory.
    pub fn drainPendingDestroy(self: *QuicTransport) void {
        self.pending_destroy_mutex.lock();
        defer self.pending_destroy_mutex.unlock();
        if (self.pending_destroy.items.len == 0) return;

        // Wait for handler threads to finish I/O before destroying connections
        self.poll_sync.enterPoll();
        defer self.poll_sync.leavePoll();

        for (self.pending_destroy.items) |inner_conn| {
            if (self.endpoint) |*ep| {
                // Use vendor API to properly remove from all endpoint tracking
                // tables (conns, accepted, retired, timers) before freeing.
                api.destroy(ep, inner_conn);
            } else {
                // No endpoint (already shut down) - just deinit internal state.
                // The Connection struct was allocated by the endpoint so we
                // cannot free it here without the endpoint's allocator.
                inner_conn.deinit();
            }
        }
        self.pending_destroy.clearRetainingCapacity();
    }

    pub fn listen(self: *QuicTransport) !void {
        // Verify certificates exist or generate them
        std.fs.cwd().access(self.config.cert_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // Try to generate self-signed certificates
                if (self.generateSelfSignedCert()) {
                    tlog.info("auto-generated self-signed TLS certificate", &.{
                        Attr.string("path", self.config.cert_path),
                    });
                } else |gen_err| {
                    tlog.fatal("TLS certificates not found and generation failed", &.{
                        Attr.string("cert_path", self.config.cert_path),
                        Attr.string("key_path", self.config.key_path),
                        Attr.string("error", @errorName(gen_err)),
                    });
                    std.debug.print("SECURITY: Refusing to start without TLS. Generate certificates manually:\n", .{});
                    std.debug.print("  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout {s} -out {s} -days 365\n", .{ self.config.key_path, self.config.cert_path });
                    return QuicError.CertificateError;
                }
            } else {
                return err;
            }
        };

        // Load and parse certificate file (convert to DER for inline TLS material)
        const cert_file = try std.fs.cwd().openFile(self.config.cert_path, .{});
        defer cert_file.close();
        const cert_pem = try cert_file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(cert_pem);
        self.cert_der = api.pem.parseCertificate(self.allocator, cert_pem) catch |err| {
            tlog.err("failed to parse certificate", &.{
                Attr.string("path", self.config.cert_path),
                Attr.string("error", @errorName(err)),
            });
            return QuicError.CertificateError;
        };

        // Load and parse private key (DER inline for TLS)
        const key_file = try std.fs.cwd().openFile(self.config.key_path, .{});
        defer key_file.close();
        const key_pem = try key_file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(key_pem);
        self.key_der = api.pem.parsePrivateKey(self.allocator, key_pem) catch |err| {
            tlog.err("failed to parse private key", &.{
                Attr.string("path", self.config.key_path),
                Attr.string("error", @errorName(err)),
            });
            return QuicError.CertificateError;
        };

        // Create QUIC configuration using simplified public API
        // Note: Detailed RFC 9000 parameters (max_streams_bidi, max_stream_data_*, etc.)
        // are not exposed in the public QuicConfig and use library defaults
        var quic_config = VendorQuicConfig{
            .version = .v1,
            .alpn = &[_][]const u8{"geode/1"},
            .cc = .cubic,
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
            .cert_path = self.config.cert_path,
            .key_path = self.config.key_path,
            .ca_path = self.config.ca_path,
            .allow_insecure = self.config.allow_insecure,
            .aead_confidentiality_limit_override = null,
            .aead_integrity_limit_override = null,
            .inline_server_cert_der = self.cert_der,
            .inline_server_priv_p256 = self.key_der,
        };

        // Normalize "localhost" to "127.0.0.1"
        const bind_address = if (std.mem.eql(u8, self.config.address, "localhost"))
            "127.0.0.1"
        else
            self.config.address;

        // Create bind address string
        const bind_addr = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ bind_address, self.config.port });
        defer self.allocator.free(bind_addr);

        // Initialize endpoint using native API (stores by value)
        self.endpoint = try Endpoint.init(self.allocator, bind_addr, &quic_config);

        tlog.info("QUIC transport listening", &.{
            Attr.int("port", @intCast(self.config.port)),
            Attr.string("tls", "true"),
            Attr.string("status", "listening"),
        });
        // Startup banner for operational tooling (JSON on stderr)
        std.debug.print("{{\"component\":\"transport\",\"transport\":\"quic\",\"tls\":\"true\",\"port\":{d},\"library\":\"vendor/quic\",\"api\":\"native-endpoint\",\"status\":\"listening\"}}\n", .{self.config.port});
    }

    pub fn poll(self: *QuicTransport, timeout_ms: u32) !void {
        if (self.endpoint) |*ep| {
            try ep.poll(@intCast(timeout_ms));
        }
    }

    pub fn accept(self: *QuicTransport) !*QuicConnection {
        if (self.endpoint) |*ep| {
            // Poll the endpoint to process incoming UDP packets and complete handshakes
            // This is required before connections can be accepted
            // Keep polling until a connection is ready with available streams
            // GAP-0200-FIX: Increased poll count and wait for streams to be ready
            // to prevent race condition where connection is returned before client
            // sends its first STREAM frame (containing HELLO message)
            var poll_count: usize = 0;
            var pending_conn: ?*Connection = null;

            // First, try to get a connection (if we don't have one pending)
            while (poll_count < 300) : (poll_count += 1) {
                // GAP-0203: Drain deferred connection cleanups before polling.
                // This ensures connections marked for destruction are removed from
                // the endpoint's tracking tables before poll() processes packets.
                self.drainPendingDestroy();
                // Acquire exclusive poll access — blocks new handler I/O and
                // waits for in-flight I/O to complete. This prevents concurrent
                // HashMap access in the QUIC library (stream_txs corruption).
                self.poll_sync.enterPoll();
                ep.poll(10) catch |err| {
                    self.poll_sync.leavePoll();
                    return err;
                };
                self.poll_sync.leavePoll();

                // Get a connection if we don't have one yet
                if (pending_conn == null) {
                    pending_conn = api.tryAccept(ep);
                }

                // If we have a connection, check for streams
                if (pending_conn) |conn| {
                    if (conn.hasIncomingStreams()) {
                        const wrapper = try self.allocator.create(QuicConnection);
                        wrapper.* = QuicConnection{
                            .allocator = self.allocator,
                            .inner = conn,
                            .streams = try std.ArrayList(*QuicStream).initCapacity(self.allocator, 0),
                            .poll_sync = &self.poll_sync,
                        };
                        // GAP-0202: Thread-safe connection list append
                        self.connections_mutex.lock();
                        defer self.connections_mutex.unlock();
                        try self.connections.append(self.allocator, wrapper);
                        return wrapper;
                    }
                    // Connection exists but no streams yet - continue polling
                    // This ensures we process incoming STREAM frames before returning
                }
            }

            // Timeout waiting for streams - return connection anyway but with warning
            // The handler will wait for streams with its own timeout
            if (pending_conn) |conn| {
                const wrapper = try self.allocator.create(QuicConnection);
                wrapper.* = QuicConnection{
                    .allocator = self.allocator,
                    .inner = conn,
                    .streams = try std.ArrayList(*QuicStream).initCapacity(self.allocator, 0),
                    .poll_sync = &self.poll_sync,
                };
                self.connections_mutex.lock();
                defer self.connections_mutex.unlock();
                try self.connections.append(self.allocator, wrapper);
                return wrapper;
            }

            // No connections ready after polling
            return QuicError.WouldBlock;
        }
        return QuicError.InvalidState;
    }

    pub fn tryAccept(self: *QuicTransport) ?*QuicConnection {
        if (self.endpoint) |*ep| {
            // Wait for handler threads then poll
            self.poll_sync.enterPoll();
            ep.poll(10) catch {
                self.poll_sync.leavePoll();
                return null;
            };
            self.poll_sync.leavePoll();
            const conn = api.tryAccept(ep) orelse return null;
            const wrapper = self.allocator.create(QuicConnection) catch return null;
            wrapper.* = QuicConnection{
                .allocator = self.allocator,
                .inner = conn,
                .streams = std.ArrayList(*QuicStream).initCapacity(self.allocator, 0) catch return null,
                .poll_sync = &self.poll_sync,
            };
            // GAP-0202: Thread-safe connection list append
            self.connections_mutex.lock();
            defer self.connections_mutex.unlock();
            self.connections.append(self.allocator, wrapper) catch {
                self.allocator.destroy(wrapper);
                return null;
            };
            return wrapper;
        }
        return null;
    }

    /// CANARY: REQ=REQ-QUIC-CONN-CLEANUP-002; FEATURE="ConnectionMemoryManagement"; ASPECT=ConnectionListCleanup; STATUS=EXEMPT; OWNER=transport; UPDATED=2025-12-27
    /// Remove a connection from tracking, close it, and destroy it.
    /// This should be called after a connection handler completes to prevent resource leaks.
    /// GAP-0201: Use swapRemove for O(1) removal instead of O(n) orderedRemove
    /// CANARY: REQ=REQ-PERF-CONN-REMOVE-001; FEATURE="ConnectionRemovalOptimization"; ASPECT=O1Removal; STATUS=TESTED; TEST=test_performance_optimizations.zig; OWNER=transport; UPDATED=2026-01-30
    /// GAP-0202: Thread-safe connection removal for async connection handling
    /// GAP-0203: Defer inner connection deinit to main thread to prevent use-after-free
    pub fn destroyConnection(self: *QuicTransport, conn: *QuicConnection) void {
        // GAP-0202: Lock mutex for thread-safe list modification
        self.connections_mutex.lock();
        // Remove connection from the tracked list using O(1) swapRemove
        var idx: usize = 0;
        while (idx < self.connections.items.len) {
            if (self.connections.items[idx] == conn) {
                _ = self.connections.swapRemove(idx);
                break;
            }
            idx += 1;
        }
        self.connections_mutex.unlock();

        // Close streams and send CONNECTION_CLOSE frame, but DO NOT call
        // inner.deinit() here. The inner connection is still referenced by
        // the endpoint's tracking tables and the main thread's poll() loop
        // may still deliver packets to it. Freeing it here causes a
        // use-after-free crash (GAP-0203).
        // Use poll_sync to ensure poll() doesn't race with connection teardown.
        self.poll_sync.enterIo();
        for (conn.streams.items) |stream| {
            conn.inner.closeStream(stream.stream_id, 0) catch {};
            conn.allocator.destroy(stream);
        }
        conn.streams.deinit(conn.allocator);
        api.closeConnection(conn.inner, 0) catch {};
        self.poll_sync.leaveIo();

        // Queue the inner connection for deferred destruction on the main thread.
        // drainPendingDestroy() will use api.destroy() to properly remove it
        // from all endpoint bookkeeping before freeing.
        self.pending_destroy_mutex.lock();
        self.pending_destroy.append(self.allocator, conn.inner) catch {
            // If append fails (OOM), fall back to direct deinit.
            // This risks a crash but avoids a resource leak.
            conn.inner.deinit();
        };
        self.pending_destroy_mutex.unlock();

        // Destroy the wrapper struct (safe - no other thread references it)
        self.allocator.destroy(conn);
    }

    fn generateSelfSignedCert(self: *QuicTransport) !void {
        // Ensure cert directory exists
        std.fs.cwd().makePath("certs") catch {};

        // Generate self-signed ECDSA P-256 certificate using openssl
        // Using ECDSA P-256 for compatibility with TLS 1.3 signature schemes
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "ec",
                "-pkeyopt",
                "ec_paramgen_curve:prime256v1",
                "-nodes",
                "-keyout",
                self.config.key_path,
                "-out",
                self.config.cert_path,
                "-days",
                "365",
                "-subj",
                "/CN=localhost",
            },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| {
                if (code != 0) return QuicError.CertificateError;
            },
            else => return QuicError.CertificateError,
        }
    }
};

pub const QuicConnection = struct {
    allocator: std.mem.Allocator,
    inner: *Connection,
    streams: std.ArrayList(*QuicStream),
    /// Shared poll synchronization — see PollSync docs.
    poll_sync: ?*PollSync = null,

    pub fn openStream(self: *QuicConnection, bidirectional: bool) !*QuicStream {
        if (self.poll_sync) |ps| ps.enterIo();
        defer {
            if (self.poll_sync) |ps| ps.leaveIo();
        }
        const stream_id = try self.inner.openStream(bidirectional);

        const stream = try self.allocator.create(QuicStream);
        stream.* = QuicStream{
            .allocator = self.allocator,
            .connection = self.inner,
            .stream_id = stream_id,
            .poll_sync = self.poll_sync,
            .tracking_index = self.streams.items.len,
        };
        try self.streams.append(self.allocator, stream);
        return stream;
    }

    pub fn acceptStream(self: *QuicConnection) !*QuicStream {
        if (self.poll_sync) |ps| ps.enterIo();
        defer {
            if (self.poll_sync) |ps| ps.leaveIo();
        }
        const stream_id = try self.inner.acceptStream();
        // GAP-0200: Debug print removed from hot path for performance
        const stream = try self.allocator.create(QuicStream);
        stream.* = QuicStream{
            .allocator = self.allocator,
            .connection = self.inner,
            .stream_id = stream_id,
            .poll_sync = self.poll_sync,
            .tracking_index = self.streams.items.len,
        };
        try self.streams.append(self.allocator, stream);
        return stream;
    }

    pub fn isDrained(self: *QuicConnection) bool {
        return api.isDrained(self.inner);
    }

    pub fn isHandshakeConfirmed(self: *QuicConnection) bool {
        return api.isHandshakeConfirmed(self.inner);
    }

    /// Retrieve the peer's leaf certificate in DER format from the TLS handshake.
    /// Returns null if no client certificate was presented or the TLS context is unavailable.
    /// CANARY: REQ=REQ-AUTH-MTLS-QUIC-001; FEATURE="mTLS over QUIC"; ASPECT=PeerCertExtraction; STATUS=IMPL; OWNER=transport; UPDATED=2026-02-13
    pub fn getPeerCertificateDer(self: *QuicConnection) ?[]const u8 {
        const tls_ctx = self.inner.tls_context orelse return null;
        const chain = tls_ctx.peer_cert_chain orelse return null;
        if (chain.len == 0) return null;
        return chain[0];
    }

    /// Remove a stream from tracking and destroy it
    /// CANARY: REQ=REQ-QUIC-STREAM-CLEANUP-001; FEATURE="StreamMemoryManagement"; ASPECT=DoubleFreePrevention; STATUS=EXEMPT; OWNER=transport; UPDATED=2025-12-27
    /// GAP-0201: Use swapRemove for O(1) removal instead of O(n) orderedRemove
    /// CANARY: REQ=REQ-PERF-STREAM-REMOVE-001; FEATURE="StreamRemovalOptimization"; ASPECT=O1Removal; STATUS=TESTED; TEST=test_performance_optimizations.zig; OWNER=transport; UPDATED=2026-01-30
    pub fn destroyStream(self: *QuicConnection, stream: *QuicStream) void {
        // Prefer O(1) removal using stream-tracked index.
        var idx = stream.tracking_index;
        if (idx >= self.streams.items.len or self.streams.items[idx] != stream) {
            // Fallback for defensive consistency if index drifted.
            idx = 0;
            while (idx < self.streams.items.len and self.streams.items[idx] != stream) : (idx += 1) {}
            if (idx >= self.streams.items.len) {
                self.allocator.destroy(stream);
                return;
            }
        }

        _ = self.streams.swapRemove(idx);
        if (idx < self.streams.items.len) {
            self.streams.items[idx].tracking_index = idx;
        }
        // Now destroy the stream
        self.allocator.destroy(stream);
    }

    pub fn close(self: *QuicConnection) void {
        if (self.poll_sync) |ps| ps.enterIo();
        defer {
            if (self.poll_sync) |ps| ps.leaveIo();
        }
        for (self.streams.items) |stream| {
            self.inner.closeStream(stream.stream_id, 0) catch {};
            self.allocator.destroy(stream);
        }
        self.streams.deinit(self.allocator);
        api.closeConnection(self.inner, 0) catch {};
        // CANARY: REQ=REQ-QUIC-CONN-CLEANUP-001; FEATURE="ConnectionMemoryManagement"; ASPECT=ResourceLeak; STATUS=EXEMPT; OWNER=transport; UPDATED=2025-12-27
        // Call deinit() on the inner connection to free TLS state, streams, crypto buffers, etc.
        self.inner.deinit();
    }
};

pub const QuicStream = struct {
    allocator: std.mem.Allocator,
    connection: *Connection,
    stream_id: u64,
    /// Shared poll synchronization — see PollSync docs.
    poll_sync: ?*PollSync = null,
    tracking_index: usize = 0,

    pub fn write(self: *QuicStream, data: []const u8) !usize {
        if (self.poll_sync) |ps| ps.enterIo();
        defer {
            if (self.poll_sync) |ps| ps.leaveIo();
        }
        return self.connection.writeStream(self.stream_id, data, false);
    }

    pub fn writeAll(self: *QuicStream, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const n = try self.write(data[written..]);
            if (n == 0) return QuicError.WriteError;
            written += n;
        }
    }

    pub fn read(self: *QuicStream, buffer: []u8) !usize {
        // GAP-0200: Debug print removed from hot path for performance
        if (self.poll_sync) |ps| ps.enterIo();
        defer {
            if (self.poll_sync) |ps| ps.leaveIo();
        }
        return self.connection.readStream(self.stream_id, buffer);
    }

    pub fn readLine(self: *QuicStream, max_size: usize) ![]u8 {
        var temp_buf = try self.allocator.alloc(u8, max_size);
        defer self.allocator.free(temp_buf);
        var pos: usize = 0;
        var retry_count: usize = 0;
        const max_retries: usize = 100; // Max 100 retries = 500ms wait time

        while (pos < max_size) {
            var byte: [1]u8 = undefined;
            const n = self.read(&byte) catch |err| {
                // If we haven't read anything yet, propagate WouldBlock
                if (err == error.WouldBlock and pos == 0) return error.WouldBlock;
                // If we've read some bytes but haven't found '\n' yet, keep trying
                // This implements polling behavior for complete lines
                if (err == error.WouldBlock) {
                    retry_count += 1;
                    if (retry_count > max_retries) {
                        // GAP-0200: Debug print removed from hot path for performance
                        return error.UnexpectedEndOfStream;
                    }
                    // GAP-0200: Reduced sleep from 5ms to 500μs for high throughput
                    std.Thread.sleep(500 * std.time.ns_per_us);
                    continue;
                }
                return err;
            };

            if (n == 0) {
                // Stream ended - only return if we haven't read anything
                if (pos == 0) return error.EndOfStream;
                // If we've read partial data but no '\n', this is an error
                // (client sent incomplete line before FIN)
                // GAP-0200: Debug print removed from hot path for performance
                return error.UnexpectedEndOfStream;
            }

            temp_buf[pos] = byte[0];
            pos += 1;
            retry_count = 0; // Reset retry count when we successfully read a byte

            if (byte[0] == '\n') break;
        }

        if (pos == 0) return error.EndOfStream;

        const result = try self.allocator.alloc(u8, pos);
        @memcpy(result, temp_buf[0..pos]);

        // GAP-0200: Debug prints removed from hot path for performance
        return result;
    }

    pub fn close(self: *QuicStream) void {
        if (self.poll_sync) |ps| ps.enterIo();
        defer {
            if (self.poll_sync) |ps| ps.leaveIo();
        }
        self.connection.closeStream(self.stream_id, 0) catch {};
    }

    pub fn finish(self: *QuicStream) !void {
        if (self.poll_sync) |ps| ps.enterIo();
        defer {
            if (self.poll_sync) |ps| ps.leaveIo();
        }
        _ = try self.connection.writeStream(self.stream_id, &.{}, true);
    }
};

pub const QuicClient = struct {
    allocator: std.mem.Allocator,
    endpoint: ?Endpoint = null,
    connection: ?*Connection = null,
    alpn_storage: [1][]const u8 = undefined,

    pub fn init(allocator: std.mem.Allocator) QuicClient {
        return QuicClient{
            .allocator = allocator,
            .alpn_storage = [_][]const u8{"geode/1"},
        };
    }

    pub fn deinit(self: *QuicClient) void {
        if (self.connection) |conn| {
            // Connection may be in a bad state after handshake failure;
            // null out first to avoid double-cleanup
            self.connection = null;
            api.closeConnection(conn, 0) catch {};
        }
        if (self.endpoint) |*ep| {
            ep.deinit();
        }
        self.endpoint = null;
    }

    pub fn connect(self: *QuicClient, host: []const u8, port: u16) !void {
        return self.connectInsecure(host, port, false);
    }

    pub fn connectInsecure(self: *QuicClient, address: []const u8, port: u16, allow_insecure: bool) !void {
        // CANARY: REQ=REQ-QUIC-LOCALHOST-001; FEATURE="LocalhostNormalization"; ASPECT=ClientConnect; STATUS=IMPL; OWNER=transport; UPDATED=2026-01-28
        // Issue #382: Normalize "localhost" to "127.0.0.1" for consistent DNS/TLS handling
        const normalized_address = if (std.mem.eql(u8, address, "localhost"))
            "127.0.0.1"
        else
            address;

        // ALPN is stored in struct field to persist beyond this function call
        // Create QUIC configuration for client using simplified public API
        // Note: Detailed RFC 9000 parameters use library defaults
        var quic_config = VendorQuicConfig{
            .version = .v1,
            .alpn = &self.alpn_storage,
            .cc = .cubic,
            .enable_datagram = false,
            .enable_spin_bit = false,
            .grease = true,
            .compatible_vn = false,
            .enable_retry = false,
            .token_secret = null,
            .token_expiry_ms = 60000,
            .enable_pacing = false,
            .max_datagram_size = 1200,
            // GAP-0259: Match server idle timeout (300s) to prevent premature disconnect during bulk writes
            .max_idle_timeout_ms = 300000,
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

        // Initialize client endpoint (bind to any port)
        self.endpoint = try Endpoint.init(self.allocator, "0.0.0.0:0", &quic_config);

        // Create server address string
        const server_addr = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ normalized_address, port });
        defer self.allocator.free(server_addr);

        // Connect to server using public API
        // When allow_insecure is true, use "localhost" as SNI to match self-signed cert CN
        const sni = if (allow_insecure) "localhost" else normalized_address;
        self.connection = try api.connect(&self.endpoint.?, server_addr, sni);
    }

    pub fn connectEx(self: *QuicClient, address: []const u8, port: u16, ca_cert_path: ?[]const u8, client_cert_path: ?[]const u8, client_key_path: ?[]const u8) !void {
        // CANARY: REQ=REQ-QUIC-LOCALHOST-002; FEATURE="LocalhostNormalization"; ASPECT=ClientConnectEx; STATUS=IMPL; OWNER=transport; UPDATED=2026-01-28
        // Issue #382: Normalize "localhost" to "127.0.0.1" for consistent DNS/TLS handling
        const normalized_address = if (std.mem.eql(u8, address, "localhost"))
            "127.0.0.1"
        else
            address;

        // Create QUIC configuration for client with custom certificates using simplified public API
        var quic_config = VendorQuicConfig{
            .version = .v1,
            .alpn = &self.alpn_storage,
            .cc = .cubic,
            .enable_datagram = false,
            .enable_spin_bit = false,
            .grease = true,
            .compatible_vn = false,
            .enable_retry = false,
            .token_secret = null,
            .token_expiry_ms = 60000,
            .enable_pacing = false,
            .max_datagram_size = 1200,
            // GAP-0259: Match server idle timeout (300s) to prevent premature disconnect during bulk writes
            .max_idle_timeout_ms = 300000,
            .max_udp_payload = 1350,
            .cert_path = client_cert_path,
            .key_path = client_key_path,
            .ca_path = ca_cert_path,
            .allow_insecure = false,
            .aead_confidentiality_limit_override = null,
            .aead_integrity_limit_override = null,
            .inline_server_cert_der = null,
            .inline_server_priv_p256 = null,
        };

        // Initialize client endpoint (bind to any port)
        self.endpoint = try Endpoint.init(self.allocator, "0.0.0.0:0", &quic_config);

        // Create server address string
        const server_addr = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ normalized_address, port });
        defer self.allocator.free(server_addr);

        // Connect to server using public API
        self.connection = try api.connect(&self.endpoint.?, server_addr, normalized_address);
    }

    pub fn waitForHandshake(self: *QuicClient, timeout_secs: u32) !void {
        if (self.endpoint == null or self.connection == null) {
            return QuicError.InvalidState;
        }

        const timeout_ns = @as(u64, timeout_secs) * std.time.ns_per_s;
        const start = std.time.nanoTimestamp();

        while (std.time.nanoTimestamp() - start < timeout_ns) {
            try self.endpoint.?.poll(10);
            if (api.isHandshakeConfirmed(self.connection.?)) {
                return;
            }
            // GAP-0200: Reduced sleep from 10ms to 1ms for faster handshake completion
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }

        return QuicError.HandshakeError;
    }

    pub fn openStream(self: *QuicClient, bidirectional: bool) !*QuicClientStream {
        if (self.connection == null) return QuicError.InvalidState;

        const stream_id = try self.connection.?.openStream(bidirectional);

        const stream = try self.allocator.create(QuicClientStream);
        stream.* = QuicClientStream{
            .allocator = self.allocator,
            .connection = self.connection.?,
            .stream_id = stream_id,
            .endpoint = &self.endpoint.?,
        };
        return stream;
    }

    pub fn getStream(self: *QuicClient) !*QuicClientStream {
        return self.openStream(true);
    }

    pub fn poll(self: *QuicClient, timeout_ms: u32) !void {
        if (self.endpoint) |*ep| {
            try ep.poll(@intCast(timeout_ms));
        }
    }
};

pub const QuicClientStream = struct {
    allocator: std.mem.Allocator,
    connection: *Connection,
    stream_id: u64,
    endpoint: *Endpoint,

    pub fn write(self: *QuicClientStream, data: []const u8) !usize {
        return self.connection.writeStream(self.stream_id, data, false);
    }

    pub fn writeAll(self: *QuicClientStream, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const n = try self.write(data[written..]);
            if (n == 0) return QuicError.WriteError;
            written += n;
        }
    }

    pub fn read(self: *QuicClientStream, buffer: []u8) !usize {
        // DEBUG: Track read attempts
        const debug_read = false; // Set to true to enable verbose read debugging
        if (debug_read) std.debug.print("[QUIC] read: calling readStream\n", .{});

        const result = self.connection.readStream(self.stream_id, buffer) catch |err| {
            if (err == error.WouldBlock) {
                if (debug_read) std.debug.print("[QUIC] read: WouldBlock, polling\n", .{});
                // Drive the endpoint to allow incoming packets
                self.endpoint.poll(10) catch {};
                return error.WouldBlock;
            }
            if (debug_read) std.debug.print("[QUIC] read: error {}\n", .{err});
            return err;
        };
        if (debug_read) std.debug.print("[QUIC] read: got {} bytes\n", .{result});
        if (result == 0) {
            self.endpoint.poll(10) catch {};
        }
        return result;
    }

    // CANARY: REQ=REQ-QUIC-CLIENT-READLINE-001; FEATURE="QuicClientReadLine"; ASPECT=RetryLogic; STATUS=IMPL; OWNER=transport; UPDATED=2026-01-30
    // Issue #413: Add retry logic for WouldBlock when partial data has been read
    // This matches the server-side QuicStream.readLine() behavior for consistency
    // CANARY: REQ=REQ-SHELL-INTERRUPT-034; FEATURE="SourceInterrupt"; ASPECT=QuicReadLineTimeout; STATUS=IMPL; OWNER=transport; UPDATED=2026-01-30
    // CANARY: REQ=REQ-SHELL-INTERRUPT-038; FEATURE="SourceInterrupt"; ASPECT=QuicReadLineInterrupt; STATUS=IMPL; OWNER=transport; UPDATED=2026-01-30
    // Added interrupt callback to allow Ctrl+C detection during long server operations
    pub fn readLine(self: *QuicClientStream, max_size: usize) ![]u8 {
        return self.readLineWithInterrupt(max_size, null);
    }

    /// readLine with optional interrupt checking callback
    /// If interrupt_check returns true, returns error.Interrupted
    pub fn readLineWithInterrupt(self: *QuicClientStream, max_size: usize, interrupt_check: ?*const fn () bool) ![]u8 {
        var temp_buf = try self.allocator.alloc(u8, max_size);
        defer self.allocator.free(temp_buf);
        var pos: usize = 0;
        var retry_count: usize = 0;
        const max_retries: usize = 20; // Max 20 retries = ~100ms, allows frequent interrupt checks

        while (pos < max_size) {
            // Check for interrupt before each read attempt
            if (interrupt_check) |check_fn| {
                if (check_fn()) {
                    return error.Interrupted;
                }
            }

            var byte: [1]u8 = undefined;
            const n = self.read(&byte) catch |err| {
                // If we haven't read anything yet, propagate WouldBlock
                if (err == error.WouldBlock and pos == 0) return error.WouldBlock;
                // If we've read some bytes but haven't found '\n' yet, keep trying
                // This implements polling behavior for complete lines
                if (err == error.WouldBlock) {
                    retry_count += 1;
                    if (retry_count > max_retries) {
                        // Timeout waiting for complete line - return WouldBlock so caller can check interrupts
                        if (pos == 0) return error.WouldBlock;
                        return error.UnexpectedEndOfStream;
                    }
                    // Poll for incoming data and wait before retrying
                    self.endpoint.poll(10) catch {};
                    std.Thread.sleep(5 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };

            if (n == 0) {
                // No data available yet - poll and retry
                if (pos == 0) return error.WouldBlock;
                // If we've read partial data, retry a few times for complete line
                retry_count += 1;
                if (retry_count > max_retries) {
                    return error.UnexpectedEndOfStream;
                }
                self.endpoint.poll(10) catch {};
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            }

            temp_buf[pos] = byte[0];
            pos += 1;
            retry_count = 0; // Reset retry count when we successfully read a byte

            if (byte[0] == '\n') break;
        }

        if (pos == 0) return error.EndOfStream;

        const result = try self.allocator.alloc(u8, pos);
        @memcpy(result, temp_buf[0..pos]);
        return result;
    }

    pub fn close(self: *QuicClientStream) void {
        self.connection.closeStream(self.stream_id, 0) catch {};
        self.allocator.destroy(self);
    }

    pub fn deinit(self: *QuicClientStream) void {
        self.close();
    }

    pub fn finish(self: *QuicClientStream) !void {
        _ = try self.connection.writeStream(self.stream_id, &.{}, true);
    }
};
