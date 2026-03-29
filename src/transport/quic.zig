const std = @import("std");

// VENDOR QUIC MIGRATION COMPLETE - 2025-11-20
// This module now uses the vendor/quic library's native Endpoint API
// Following the pattern from vendor/quic/echo_quic_server.zig
//
// Updated 2026-02: Endpoint stored as heap pointer (api.endpointInit/endpointDeinit),
// PollSync uses mutex+condvar instead of atomic spin-loops, QuicConfig heap-allocated
// to ensure cert/key DER lifetime, quic_connection nullable field on QuicConnection.

// CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICCore; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_QUICCore; OWNER=wire; UPDATED=2025-11-21

const logging = @import("logging");
const tlog = logging.scoped("transport");
const Attr = logging.Attr;

// DNS resolution for hostnames that the vendor QUIC library cannot resolve.
const dns = @import("dns");

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
/// Uses mutex+condvar for correct and efficient blocking without spin-loops.
pub const PollSync = struct {
    mu: std.Thread.Mutex = .{},
    cv: std.Thread.Condition = .{},
    /// Signaled after every leavePoll() so handler threads waiting for data
    /// can wake up promptly instead of blind-sleeping. Separate from `cv`
    /// to avoid spurious wakeups between handler data-wait and protocol-wait.
    poll_cv: std.Thread.Condition = .{},
    poll_requested: bool = false,
    active_io_count: u32 = 0,

    /// Called by handler threads before I/O. Blocks until safe to proceed.
    pub fn enterIo(self: *PollSync) void {
        self.mu.lock();
        defer self.mu.unlock();
        while (self.poll_requested) {
            self.cv.wait(&self.mu);
        }
        self.active_io_count += 1;
    }

    /// Called by handler threads after I/O.
    pub fn leaveIo(self: *PollSync) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.active_io_count > 0) self.active_io_count -= 1;
        // broadcast, not signal: both enterIo and enterPoll wait on the same cv.
        // signal() could wake a handler blocked in enterIo (poll_requested=true)
        // instead of the main thread blocked in enterPoll, causing permanent stall.
        if (self.active_io_count == 0) self.cv.broadcast();
    }

    /// Called by the main thread before poll(). Blocks until all I/O finishes.
    pub fn enterPoll(self: *PollSync) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.poll_requested = true;
        while (self.active_io_count > 0) {
            self.cv.wait(&self.mu);
        }
    }

    /// Called by the main thread after poll().
    pub fn leavePoll(self: *PollSync) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.poll_requested = false;
        self.cv.broadcast();
        self.poll_cv.broadcast(); // Wake handlers waiting for data after poll
    }

    /// Handler threads call this instead of blind Thread.sleep().
    /// Blocks until the next poll cycle completes or timeout expires.
    pub fn waitForPoll(self: *PollSync, timeout_ns: u64) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.poll_cv.timedWait(&self.mu, timeout_ns) catch {}; // timeout is expected
    }
};

/// The canonical default QUIC server port for Geode.
/// All server and client code should reference this constant rather than hard-coding 3141 or 7567.
pub const DEFAULT_PORT: u16 = 3141;

pub const QuicTransport = struct {
    allocator: std.mem.Allocator,
    config: Config,
    /// Heap-allocated endpoint (via api.endpointInit / api.endpointDeinit).
    endpoint: ?*Endpoint = null,
    connections: std.ArrayList(*QuicConnection),
    // GAP-0202: Mutex for thread-safe connection list access in async mode
    connections_mutex: std.Thread.Mutex = .{},
    // GAP-0203: Deferred connection destruction to prevent use-after-free.
    // Handler threads add inner connections here after sending CONNECTION_CLOSE;
    // the main accept loop thread processes them via drainPendingDestroy()
    // where endpoint bookkeeping can be safely updated without racing with poll().
    pending_destroy: std.ArrayList(*Connection),
    pending_destroy_mutex: std.Thread.Mutex = .{},
    /// Readers-writer sync: handler threads are "readers" (concurrent I/O),
    /// main thread is the "writer" (exclusive poll). See PollSync docs.
    poll_sync: PollSync = .{},
    /// Heap-allocated QUIC config; owns the inline cert/key DER byte slices.
    quic_config: ?*VendorQuicConfig = null,

    pub const Config = struct {
        address: []const u8 = "0.0.0.0",
        port: u16 = DEFAULT_PORT,
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
            .pending_destroy = try std.ArrayList(*Connection).initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *QuicTransport) void {
        // GAP-0203: Process any deferred connection cleanups first.
        // These are inner connections queued by handler threads via destroyConnection().
        self.drainPendingDestroy();

        self.connections_mutex.lock();
        var conns = self.connections;
        self.connections = .empty;
        self.connections_mutex.unlock();

        for (conns.items) |conn| {
            conn.close();
            self.allocator.destroy(conn);
        }
        conns.deinit(self.allocator);

        self.drainPendingDestroy();
        self.pending_destroy.deinit(self.allocator);

        if (self.endpoint) |ep| {
            api.endpointDeinit(ep);
            self.endpoint = null;
        }

        // Free the heap-allocated config and its owned cert/key DER bytes.
        if (self.quic_config) |cfg| {
            if (cfg.inline_server_cert_der) |cert| {
                self.allocator.free(cert);
            }
            if (cfg.inline_server_priv_p256) |key| {
                self.allocator.free(key);
            }
            self.allocator.destroy(cfg);
            self.quic_config = null;
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

        // api.destroy() modifies endpoint internal maps (conns, accepted, retired)
        // without acquiring ep.mu. Acquire it here to prevent racing with poll().
        if (self.endpoint) |ep| {
            ep.mu.lock();
            defer ep.mu.unlock();
            for (self.pending_destroy.items) |inner_conn| {
                api.destroy(ep, inner_conn);
            }
        } else {
            for (self.pending_destroy.items) |inner_conn| {
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
        const inline_cert_der = api.pem.parseCertificate(self.allocator, cert_pem) catch |err| {
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
        const inline_priv_key = api.pem.parsePrivateKey(self.allocator, key_pem) catch |err| {
            tlog.err("failed to parse private key", &.{
                Attr.string("path", self.config.key_path),
                Attr.string("error", @errorName(err)),
            });
            self.allocator.free(inline_cert_der);
            return QuicError.CertificateError;
        };

        // Allocate QuicConfig on the heap so cert/key DER slices remain valid
        // for the lifetime of the endpoint (endpointInit stores references).
        const cfg = try self.allocator.create(VendorQuicConfig);
        errdefer {
            self.allocator.free(inline_cert_der);
            self.allocator.free(inline_priv_key);
            self.allocator.destroy(cfg);
        }
        cfg.* = VendorQuicConfig{
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
            .max_connections = self.config.max_connections,
            .require_client_cert = self.config.require_client_cert,
            .inline_server_cert_der = inline_cert_der,
            .inline_server_priv_p256 = inline_priv_key,
        };
        self.quic_config = cfg;

        // Normalize "localhost" to "127.0.0.1"
        const bind_address = if (std.mem.eql(u8, self.config.address, "localhost"))
            "127.0.0.1"
        else
            self.config.address;

        // Create bind address string
        const bind_addr = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ bind_address, self.config.port });
        defer self.allocator.free(bind_addr);

        // Initialize endpoint using api.endpointInit (heap-allocates the Endpoint struct).
        self.endpoint = try api.endpointInit(&self.allocator, bind_addr, cfg);

        tlog.info("QUIC transport listening", &.{
            Attr.int("port", @intCast(self.config.port)),
            Attr.string("tls", "true"),
            Attr.string("status", "listening"),
        });
        // Startup banner for operational tooling (JSON on stderr)
        std.debug.print("{{\"component\":\"transport\",\"transport\":\"quic\",\"tls\":\"true\",\"port\":{d},\"library\":\"vendor/quic\",\"api\":\"native-endpoint\",\"status\":\"listening\"}}\n", .{self.config.port});
    }

    pub fn poll(self: *QuicTransport, timeout_ms: u32) !void {
        if (self.endpoint) |ep| {
            const timeout_i32: i32 = if (timeout_ms > std.math.maxInt(i32))
                std.math.maxInt(i32)
            else
                @intCast(timeout_ms);
            // QUIC library v0.1.10: poll() is internally thread-safe with
            // fine-grained per-phase locking. No external PollSync needed
            // for the poll call itself. We still signal poll_cv so handlers
            // waiting for data delivery wake up promptly.
            try api.poll(ep, timeout_i32);
            self.poll_sync.poll_cv.broadcast();
        }
    }

    /// Dedicated poll loop — run on a separate thread to decouple packet delivery
    /// from the accept loop. This eliminates the c=8+ contention bottleneck where
    /// handler threads starve waiting for data that only arrives when the main
    /// thread calls poll() between accept attempts (#540).
    ///
    /// The poll thread continuously processes incoming UDP datagrams into connection
    /// RX buffers and signals waiting handler threads via poll_cv.broadcast().
    pub fn pollLoop(self: *QuicTransport, shutdown: *std.atomic.Value(bool)) void {
        while (!shutdown.load(.acquire)) {
            // Non-blocking poll — process any pending UDP datagrams without
            // blocking on the socket. poll(0) returns immediately if no data
            // is available. 1ms sleep keeps idle CPU <5% while maintaining
            // acceptable latency for incoming packets (was 50μs which caused
            // 55%+ idle CPU from 20k syscalls/sec overhead).
            // drainPendingDestroy is handled by the main accept loop thread only
            // (it acquires ep.mu which would contend with poll's internal locking).
            self.poll(0) catch {};
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
        // Final poll to flush any remaining packets on shutdown
        self.poll(0) catch {};
    }

    pub fn accept(self: *QuicTransport) !*QuicConnection {
        if (self.endpoint) |ep| {
            // GAP-0203: Drain deferred connection cleanups.
            self.drainPendingDestroy();

            // CV-based blocking accept: waits up to 50ms for a new
            // connection via the endpoint's accept_cv, using near-zero
            // CPU when idle. Falls back to WouldBlock if no connection
            // arrives within the timeout.
            const conn = api.waitForAccepted(ep, 50) orelse return QuicError.WouldBlock;

            // Return immediately — handler waits for streams via poll_cv
            const wrapper = try self.allocator.create(QuicConnection);
            wrapper.* = QuicConnection{
                .allocator = self.allocator,
                .quic_connection = conn,
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
        return QuicError.InvalidState;
    }

    /// #49: Returns the current number of tracked connections for admission control.
    pub fn getConnectionCount(self: *QuicTransport) usize {
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();
        return self.connections.items.len;
    }

    pub fn tryAccept(self: *QuicTransport) ?*QuicConnection {
        if (self.endpoint) |ep| {
            // QUIC library v0.1.10: poll() is internally thread-safe
            ep.poll(0) catch {
                return null;
            };
            self.poll_sync.poll_cv.broadcast();
            const conn = api.tryAccept(ep) orelse return null;
            const wrapper = self.allocator.create(QuicConnection) catch return null;
            wrapper.* = QuicConnection{
                .allocator = self.allocator,
                .quic_connection = conn,
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
        // Close streams and connection. The QUIC library's closeStream/
        // closeConnection are thread-safe (per-connection mutex).
        for (conn.streams.items) |stream| {
            conn.inner.closeStream(stream.stream_id, 0) catch {};
            conn.allocator.destroy(stream);
        }
        conn.streams.deinit(conn.allocator);
        api.closeConnection(conn.inner, 0) catch {};

        // Queue the inner connection for deferred destruction on the main thread.
        // drainPendingDestroy() will use api.destroy() to properly remove it
        // from all endpoint bookkeeping before freeing.
        // Use quic_connection (nullable, nulled by close()) with inner as fallback.
        const inner_conn = conn.quic_connection orelse conn.inner;
        self.pending_destroy_mutex.lock();
        self.pending_destroy.append(self.allocator, inner_conn) catch {
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
    /// Nullable; nulled in close() to prevent double-close.
    quic_connection: ?*Connection = null,
    /// Non-nullable alias for the underlying connection (stays set after close).
    inner: *Connection,
    streams: std.ArrayList(*QuicStream),
    /// Shared poll synchronization — see PollSync docs.
    poll_sync: ?*PollSync = null,

    pub fn openStream(self: *QuicConnection, bidirectional: bool) !*QuicStream {
        const qc = self.quic_connection orelse return QuicError.Closed;
        const stream_id = try api.openStream(qc, bidirectional);

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
        const qc = self.quic_connection orelse return QuicError.Closed;
        const stream_id = try api.acceptStream(qc);
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

    /// Non-blocking stream accept: returns null when no peer-initiated stream
    /// is pending, instead of returning error.WouldBlock like acceptStream().
    /// Used by the multiplexed connection handler to poll for new streams
    /// while servicing the first stream inline.
    pub fn tryAcceptStream(self: *QuicConnection) ?*QuicStream {
        const qc = self.quic_connection orelse return null;
        const stream_id = api.acceptStream(qc) catch return null;
        const stream = self.allocator.create(QuicStream) catch return null;
        stream.* = QuicStream{
            .allocator = self.allocator,
            .connection = self.inner,
            .stream_id = stream_id,
            .poll_sync = self.poll_sync,
            .tracking_index = self.streams.items.len,
        };
        self.streams.append(self.allocator, stream) catch {
            self.allocator.destroy(stream);
            return null;
        };
        return stream;
    }

    pub fn isDrained(self: *QuicConnection) bool {
        const qc = self.quic_connection orelse return true;
        return api.isDrained(qc);
    }

    pub fn isHandshakeConfirmed(self: *QuicConnection) bool {
        const qc = self.quic_connection orelse return false;
        return api.isHandshakeConfirmed(qc);
    }

    /// Retrieve the peer's leaf certificate in DER format from the TLS handshake.
    /// Returns null if no client certificate was presented or the TLS context is unavailable.
    /// CANARY: REQ=REQ-AUTH-MTLS-QUIC-001; FEATURE="mTLS over QUIC"; ASPECT=PeerCertExtraction; STATUS=IMPL; OWNER=transport; UPDATED=2026-02-13
    pub fn getPeerCertificateDer(self: *QuicConnection) ?[]const u8 {
        const qc = self.quic_connection orelse return null;
        const tls_ctx = qc.tls_context orelse return null;
        const chain = tls_ctx.peer_cert_chain orelse return null;
        if (chain.len == 0) return null;
        return chain[0];
    }

    /// Return a human-readable IP string for the peer (e.g. "192.168.1.1").
    /// Falls back to "unknown" when the underlying connection is closed or the
    /// address family is unrecognised.
    /// CANARY: REQ=REQ-SEC-RATE-LIMIT-002; FEATURE="AuthRateLimiting"; ASPECT=PeerIPExtraction; STATUS=IMPL; OWNER=transport; UPDATED=2026-03-26
    pub fn getPeerAddressString(self: *QuicConnection, allocator: std.mem.Allocator) []const u8 {
        const qc = self.quic_connection orelse return "unknown";
        const peer = &qc.peer;
        const fam = peer.family();
        if (fam == std.posix.AF.INET) {
            const ip_bytes = peer.getIpBytes();
            if (ip_bytes.len == 4) {
                return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{
                    ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3],
                }) catch "unknown";
            }
        } else if (fam == std.posix.AF.INET6) {
            const ip_bytes = peer.getIpBytes();
            if (ip_bytes.len == 16) {
                return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}", .{
                    ip_bytes[0],  ip_bytes[1],  ip_bytes[2],  ip_bytes[3],
                    ip_bytes[4],  ip_bytes[5],  ip_bytes[6],  ip_bytes[7],
                    ip_bytes[8],  ip_bytes[9],  ip_bytes[10], ip_bytes[11],
                    ip_bytes[12], ip_bytes[13], ip_bytes[14], ip_bytes[15],
                }) catch "unknown";
            }
        }
        return "unknown";
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
        // CANARY: REQ=REQ-QUIC-CONN-CLEANUP-001; FEATURE="ConnectionMemoryManagement"; ASPECT=ResourceLeak; STATUS=EXEMPT; OWNER=transport; UPDATED=2025-12-27
        // Use quic_connection and null it out to prevent double-close.
        if (self.quic_connection) |qc| {
            api.closeConnection(qc, 0) catch {};
            self.quic_connection = null;
        }
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
        // QUIC library v0.1.10: writeStream is internally thread-safe
        // (per-connection mutex protects stream state). No PollSync needed.
        return self.connection.writeStream(self.stream_id, data, false);
    }

    pub fn writeAll(self: *QuicStream, data: []const u8) !void {
        var written: usize = 0;
        var blocked_retries: usize = 0;
        const max_blocked_retries: usize = 2000; // ~10s at 5ms sleep
        while (written < data.len) {
            const n = self.connection.writeStream(self.stream_id, data[written..], false) catch |err| {
                if (err == error.FlowControlBlocked) {
                    blocked_retries += 1;
                    if (blocked_retries > max_blocked_retries) return QuicError.WriteError;
                    std.Thread.sleep(5 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            if (n == 0) {
                // Congestion window full — retry with backoff (same as FlowControlBlocked)
                blocked_retries += 1;
                if (blocked_retries > max_blocked_retries) return QuicError.WriteError;
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            }
            written += n;
            blocked_retries = 0;
        }
    }

    pub fn read(self: *QuicStream, buffer: []u8) !usize {
        // QUIC library v0.1.10: readStream is internally thread-safe
        // (per-connection mutex protects stream reassembly buffers).
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

/// Resolve a hostname to an IPv4 address string.
/// If the host is already an IP address, returns it unchanged (no allocation).
/// If it's a hostname, performs DNS resolution and returns an allocated IP string
/// that the caller must free.
fn resolveHostToIp(allocator: std.mem.Allocator, host: []const u8) !struct { ip: []const u8, allocated: bool } {
    // Fast path: already an IP address.
    if (std.net.Address.parseIp4(host, 0)) |_| {
        return .{ .ip = host, .allocated = false };
    } else |_| {}

    // Try IPv6.
    if (std.net.Address.parseIp6(host, 0)) |_| {
        return .{ .ip = host, .allocated = false };
    } else |_| {}

    // DNS resolution needed.
    var client = dns.Client.init(allocator) catch {
        return error.InvalidAddress;
    };
    defer client.deinit();

    var result = client.resolveA(host) catch {
        return error.InvalidAddress;
    };
    defer result.deinit(allocator);

    // ResolveResult.addresses is []const []const u8 — each entry is an
    // IP address string like "172.176.193.24" (not binary bytes).
    if (result.addresses.len > 0) {
        const ip_str = try allocator.dupe(u8, result.addresses[0]);
        return .{ .ip = ip_str, .allocated = true };
    }

    return error.InvalidAddress;
}

pub const QuicClient = struct {
    allocator: std.mem.Allocator,
    /// Heap-allocated endpoint (via api.endpointInit / api.endpointDeinit).
    endpoint: ?*Endpoint = null,
    connection: ?*Connection = null,
    /// Heap-allocated QUIC config; freed in deinit().
    quic_config: ?*VendorQuicConfig = null,
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
        if (self.endpoint) |ep| {
            api.endpointDeinit(ep);
            self.endpoint = null;
        }
        if (self.quic_config) |cfg| {
            self.allocator.destroy(cfg);
            self.quic_config = null;
        }
    }

    pub fn connect(self: *QuicClient, host: []const u8, port: u16) !void {
        return self.connectInsecure(host, port, false);
    }

    pub fn connectInsecure(self: *QuicClient, address: []const u8, port: u16, allow_insecure: bool) !void {
        // SEC: Guard against allow_insecure=true in release builds before it reaches the TLS
        // library (which would panic). Return a recoverable error so callers can show a
        // user-friendly message instead of a core dump.
        if (allow_insecure and comptime @import("builtin").mode != .Debug and !@import("builtin").is_test) {
            return error.InsecureForbiddenInRelease;
        }

        // CANARY: REQ=REQ-QUIC-LOCALHOST-001; FEATURE="LocalhostNormalization"; ASPECT=ClientConnect; STATUS=IMPL; OWNER=transport; UPDATED=2026-01-28
        // Issue #382: Normalize "localhost" to "127.0.0.1" for consistent DNS/TLS handling
        const normalized_address = if (std.mem.eql(u8, address, "localhost"))
            "127.0.0.1"
        else
            address;

        // Resolve hostname to IP for the vendor QUIC library (which cannot resolve DNS).
        // Keep the original hostname for TLS SNI verification.
        const resolved = try resolveHostToIp(self.allocator, normalized_address);
        defer if (resolved.allocated) self.allocator.free(resolved.ip);

        // Allocate QUIC config on the heap so the alpn_storage slice remains valid.
        const cfg = try self.allocator.create(VendorQuicConfig);
        errdefer {
            self.allocator.destroy(cfg);
            self.quic_config = null;
        }
        // ALPN is stored in struct field to persist beyond this function call
        cfg.* = VendorQuicConfig{
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
        self.quic_config = cfg;

        // Initialize client endpoint using api.endpointInit (heap-allocates Endpoint).
        self.endpoint = try api.endpointInit(&self.allocator, "0.0.0.0:0", cfg);

        // Create server address string using resolved IP.
        const server_addr = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ resolved.ip, port });
        defer self.allocator.free(server_addr);

        // Connect to server using public API.
        // SNI always uses original hostname so server can match its certificate.
        self.connection = try api.connect(self.endpoint.?, server_addr, normalized_address);
    }

    pub fn connectEx(self: *QuicClient, address: []const u8, port: u16, ca_cert_path: ?[]const u8, client_cert_path: ?[]const u8, client_key_path: ?[]const u8) !void {
        // CANARY: REQ=REQ-QUIC-LOCALHOST-002; FEATURE="LocalhostNormalization"; ASPECT=ClientConnectEx; STATUS=IMPL; OWNER=transport; UPDATED=2026-01-28
        // Issue #382: Normalize "localhost" to "127.0.0.1" for consistent DNS/TLS handling
        const normalized_address = if (std.mem.eql(u8, address, "localhost"))
            "127.0.0.1"
        else
            address;

        // Resolve hostname to IP for the vendor QUIC library (which cannot resolve DNS).
        const resolved = try resolveHostToIp(self.allocator, normalized_address);
        defer if (resolved.allocated) self.allocator.free(resolved.ip);

        // Allocate QUIC config on the heap so the alpn_storage slice remains valid.
        const cfg = try self.allocator.create(VendorQuicConfig);
        errdefer {
            self.allocator.destroy(cfg);
            self.quic_config = null;
        }
        cfg.* = VendorQuicConfig{
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
        self.quic_config = cfg;

        // Initialize client endpoint using api.endpointInit (heap-allocates Endpoint).
        self.endpoint = try api.endpointInit(&self.allocator, "0.0.0.0:0", cfg);

        // Create server address string using resolved IP.
        const server_addr = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ resolved.ip, port });
        defer self.allocator.free(server_addr);

        // Connect to server using public API. SNI uses original hostname for TLS.
        self.connection = try api.connect(self.endpoint.?, server_addr, normalized_address);
    }

    pub fn waitForHandshake(self: *QuicClient, timeout_secs: u32) !void {
        if (self.endpoint == null or self.connection == null) {
            return QuicError.InvalidState;
        }

        const timeout_ns = @as(u64, timeout_secs) * std.time.ns_per_s;
        const start = std.time.nanoTimestamp();

        while (std.time.nanoTimestamp() - start < timeout_ns) {
            try api.poll(self.endpoint.?, 10);
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
            .endpoint = self.endpoint.?,
        };
        return stream;
    }

    pub fn getStream(self: *QuicClient) !*QuicClientStream {
        return self.openStream(true);
    }

    pub fn poll(self: *QuicClient, timeout_ms: u32) !void {
        if (self.endpoint) |ep| {
            const timeout_i32: i32 = if (timeout_ms > std.math.maxInt(i32))
                std.math.maxInt(i32)
            else
                @intCast(timeout_ms);
            try api.poll(ep, timeout_i32);
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
        var blocked_retries: usize = 0;
        const max_blocked_retries: usize = 2000; // ~10s at 5ms sleep
        while (written < data.len) {
            const n = self.write(data[written..]) catch |err| {
                if (err == error.FlowControlBlocked) {
                    blocked_retries += 1;
                    if (blocked_retries > max_blocked_retries) return QuicError.WriteError;
                    // Poll to process incoming frames, then retry
                    api.poll(self.endpoint, 5) catch {};
                    std.Thread.sleep(5 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            if (n == 0) return QuicError.WriteError;
            written += n;
            blocked_retries = 0;
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
                api.poll(self.endpoint, 10) catch {};
                return error.WouldBlock;
            }
            if (debug_read) std.debug.print("[QUIC] read: error {}\n", .{err});
            return err;
        };
        if (debug_read) std.debug.print("[QUIC] read: got {} bytes\n", .{result});
        if (result == 0) {
            api.poll(self.endpoint, 10) catch {};
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
                    api.poll(self.endpoint, 10) catch {};
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
                api.poll(self.endpoint, 10) catch {};
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

// --- Unit tests for PollSync ---

test "PollSync: waitForPoll times out without signal" {
    var ps = PollSync{};
    const start = std.time.nanoTimestamp();
    ps.waitForPoll(10 * std.time.ns_per_ms);
    const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
    try std.testing.expect(elapsed_ns >= 8 * std.time.ns_per_ms);
    try std.testing.expect(elapsed_ns < 100 * std.time.ns_per_ms);
}

test "PollSync: waitForPoll wakes on leavePoll broadcast" {
    var ps = PollSync{};
    const t = try std.Thread.spawn(.{}, struct {
        fn run(sync: *PollSync) void {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            sync.mu.lock();
            defer sync.mu.unlock();
            sync.poll_cv.broadcast();
        }
    }.run, .{&ps});
    const start = std.time.nanoTimestamp();
    ps.waitForPoll(200 * std.time.ns_per_ms); // should return in ~5ms, not 200ms
    const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
    try std.testing.expect(elapsed_ns < 100 * std.time.ns_per_ms);
    t.join();
}

test "PollSync: enterIo/leaveIo/enterPoll/leavePoll still correct" {
    var ps = PollSync{};
    ps.enterIo();
    ps.enterIo();
    try std.testing.expectEqual(@as(u32, 2), ps.active_io_count);
    ps.leaveIo();
    ps.leaveIo();
    try std.testing.expectEqual(@as(u32, 0), ps.active_io_count);
    ps.enterPoll();
    try std.testing.expect(ps.poll_requested);
    ps.leavePoll();
    try std.testing.expect(!ps.poll_requested);
}
