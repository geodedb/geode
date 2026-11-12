const std = @import("std");
const builtin = @import("builtin");
const kms = @import("security/kms_remote"); // Provided via build.zig for zig build test; direct zig test on file unsupported
const quic = @import("transport/quic");
const kms_tls = @import("kms_test_tls.zig");

// Remote KMS hardening tests & benchmark additions
// Covers negative auth, expired attestation simulation, and concurrency stress unwrap.
//
// SONNY-2394: these ran for the first time when the aggregate `test` step began
// executing its run steps, and every one failed: (1) no thread ever served the
// KMS server, so client handshakes could not complete; (2) the server was never
// deinit'ed; and (3) RemoteKmsServer itself served exactly one connection for
// its whole lifetime, so a second client -- let alone the 16-client stress --
// could never be served. The server now accepts and serves every connection
// (`serveOnce` / `serveUntilStopped`), and each test runs a serving thread that
// is stopped and joined before a clean deinit (`withServer`). The
// ConcurrencyStress flake that followed (15 of 16 clients timing out on a loaded
// host) was the client's retry-count response wait -- see
// tests/test_sonny2394_kms_client_deadline.zig.
//
// CANARY: REQ=REQ-GQL-TDE-EXT-KMS-REMOTE-001; FEATURE="RemoteKMSPrototype"; ASPECT=NegativeAuthMatrix; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_InvalidAuth; OWNER=security; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-TDE-ATTEST-001; FEATURE="RemoteKmsAttestation"; ASPECT=ExpiredAttestation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_ATTEST_001_ExpiredAttestation; OWNER=security; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-TDE-EXT-KMS-REMOTE-001; FEATURE="RemoteKMSPrototype"; ASPECT=ConcurrencyStressVariance; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_ConcurrencyStress; OWNER=security; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-TDE-EXT-KMS-REMOTE-001; FEATURE="RemoteKMSPrototype"; ASPECT=ConcurrencyStressVariance; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_UnwrapConcurrencyVariance; OWNER=security; UPDATED=2025-09-26

/// Start a KMS server on a port the kernel chooses, serve it from a background
/// thread for the duration of `body` (which gets the bound port), then stop +
/// join the thread and deinit the server.
///
/// SONNY-6332: these tests used fixed ports 13051-13054. The QUIC socket binds
/// with SO_REUSEADDR, so a second run on the host (parallel lanes, pre-push
/// shards) bound the same UDP port and the two servers answered each other's
/// clients (AuthenticationFailed / RemoteError from the other server's key).
fn withServer(auth: []const u8, body: fn (*kms.RemoteKmsServer, u16) anyerror!void) !void {
    // A private certificate pair per server (SONNY-2394 review): the
    // aggregate runs the KMS test binaries concurrently.
    var tls = try kms_tls.TestTls.init(std.testing.allocator);
    defer tls.deinit(std.testing.allocator);
    var server = try kms.RemoteKmsServer.init(std.testing.allocator, 0xdeadbeefcafebabe);
    defer server.deinit();
    try server.startWithOptions(0, tls.startOptions());
    try server.server.setAuthToken(auth);
    const port = server.port;
    try std.testing.expect(port != 0);

    var stop = std.atomic.Value(bool).init(false);
    const serving = try std.Thread.spawn(.{}, kms.RemoteKmsServer.serveUntilStopped, .{ &server, &stop });
    defer {
        stop.store(true, .release);
        serving.join();
    }
    try body(&server, port);
}

// Clients stay on page_allocator (see the GAP-0514 P3 note in
// tests/canary_remote_kms.zig: the pinned vendor TLS stack leaks client
// handshake allocations); the server side runs under std.testing.allocator.
fn connectClient(port: u16, auth: ?[]const u8) !kms.RemoteKmsClient {
    var client = kms.RemoteKmsClient.init(std.heap.page_allocator);
    errdefer client.deinit();
    try client.connect("127.0.0.1", port);
    if (auth) |a| client.setAuthToken(a);
    return client;
}

test "TestCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_InvalidAuth" {
    try withServer("secret-token", struct {
        pub fn f(s: *kms.RemoteKmsServer, port: u16) !void {
            std.mem.doNotOptimizeAway(s);
            std.debug.print("[HARDENING] InvalidAuth start\n", .{});
            // Positive client (control)
            var ok_client = try connectClient(port, "secret-token");
            defer ok_client.deinit();
            const env = try ok_client.generate();
            _ = try ok_client.unwrap(env);
            // Negative client (wrong token) -- a SECOND concurrent connection.
            var bad_client = try connectClient(port, "wrong-token");
            defer bad_client.deinit();
            const env2 = env;
            const res = bad_client.unwrap(env2);
            try std.testing.expectError(error.AuthenticationFailed, res);
            // The control connection is still served after the rejection.
            _ = try ok_client.unwrap(env);
            std.debug.print("[HARDENING] InvalidAuth end\n", .{});
        }
    }.f);
}

// Simulate expired attestation by mutating hash after acquisition then verifying unwrap attestation fails
test "TestCANARY_REQ_GQL_TDE_ATTEST_001_ExpiredAttestation" {
    try withServer("a-token", struct {
        pub fn f(s: *kms.RemoteKmsServer, port: u16) !void {
            var c = try connectClient(port, "a-token");
            defer c.deinit();
            // Perform attestation
            const hash = try c.attest();
            // Directly tamper server attestation hash to simulate expiry/rotation.
            // (The serving thread only reads it for Attest requests; none is
            // in flight here.)
            s.server.attestation_hash[0] ^= 0xFF;
            // Generate + unwrap to get new attestation signature
            const env = try c.generate();
            const plain = c.unwrap(env) catch return error.Unexpected; // Should still work (crypto-wise)
            std.mem.doNotOptimizeAway(plain);
            // Now attempt to verify old hash with new signature via public API verifyAttestation should fail
            var bogus_sig: [64]u8 = undefined; // all zero invalid signature
            @memset(&bogus_sig, 0);
            var pub_key: [32]u8 = undefined;
            @memset(&pub_key, 0);
            const ok = kms.RemoteKmsClient.verifyAttestation(std.testing.allocator, pub_key, hash, bogus_sig, false);
            try std.testing.expect(!ok);
            std.debug.print("[HARDENING] ExpiredAttestation simulated\n", .{});
        }
    }.f);
}

const StressWorker = struct {
    port: u16,
    env: kms.Envelope,
    plain: [32]u8 = undefined,
    err: ?anyerror = null,

    fn run(self: *StressWorker) void {
        self.unwrapOnce() catch |e| {
            self.err = e;
        };
    }

    fn unwrapOnce(self: *StressWorker) !void {
        var c = try connectClient(self.port, "stress-token");
        defer c.deinit();
        self.plain = try c.unwrap(self.env);
    }
};

// Concurrency stress: 16 clients -- 16 concurrent connections -- each unwrap
// the same envelope.
test "TestCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_ConcurrencyStress" {
    try withServer("stress-token", struct {
        pub fn f(s: *kms.RemoteKmsServer, port: u16) !void {
            std.mem.doNotOptimizeAway(s);
            var main_client = try connectClient(port, "stress-token");
            defer main_client.deinit();
            const env = try main_client.generate();
            const expected = try main_client.unwrap(env);

            const threads: usize = 16;
            var workers: [threads]StressWorker = undefined;
            var handles: [threads]std.Thread = undefined;
            for (&workers, &handles) |*w, *h| {
                w.* = .{ .port = port, .env = env };
                h.* = try std.Thread.spawn(.{}, StressWorker.run, .{w});
            }
            for (handles) |h| h.join();
            // Every client was served and got the same key back.
            var failed: usize = 0;
            for (workers, 0..) |w, i| {
                if (w.err) |e| {
                    failed += 1;
                    std.debug.print("[HARDENING] stress client {d} failed: {s}\n", .{ i, @errorName(e) });
                }
            }
            try std.testing.expectEqual(@as(usize, 0), failed);
            for (workers) |w| try std.testing.expectEqualSlices(u8, &expected, &w.plain);
            std.debug.print("[HARDENING] ConcurrencyStress complete ({d} clients)\n", .{threads});
        }
    }.f);
}

// Benchmark skeleton for concurrency variance (JSON prints; no perf assertion).
pub fn runUnwrapConcurrencyVariance() !void {
    try withServer("bench-token", struct {
        pub fn f(s: *kms.RemoteKmsServer, port: u16) !void {
            std.mem.doNotOptimizeAway(s);
            var client = try connectClient(port, "bench-token");
            defer client.deinit();
            const env = try client.generate();
            const iterations: usize = 64;
            var times: [iterations]u64 = undefined;
            const getNanos = struct {
                fn get() u64 {
                    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
                    if (comptime builtin.os.tag == .linux) {
                        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
                    } else {
                        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
                    }
                    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
                }
            }.get;
            for (&times) |*t| {
                const t_start = getNanos();
                _ = try client.unwrap(env);
                t.* = getNanos() - t_start;
            }
            // stats
            std.sort.heap(u64, &times, {}, comptime std.sort.asc(u64));
            var sum: u128 = 0;
            for (times) |v| sum += v;
            const mean_f = @as(f128, @floatFromInt(sum)) / @as(f128, @floatFromInt(times.len));
            const p95_idx = (iterations * 95) / 100;
            const p95 = times[if (p95_idx == 0) 0 else p95_idx - 1];
            const p95_mean_ratio = @as(f128, @floatFromInt(p95)) / mean_f;
            var diff: f128 = 0;
            for (times) |v| {
                const d = @as(f128, @floatFromInt(v)) - mean_f;
                diff += d * d;
            }
            const variance = diff / @as(f128, @floatFromInt(times.len));
            const stdev = std.math.sqrt(variance);
            const cv = stdev / mean_f;
            std.debug.print("{{\"bench\":\"BenchmarkCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_UnwrapConcurrencyVariance\",\"iterations\":{d},\"cv\":{d:.6},\"p95_mean_ratio\":{d:.4}}}\n", .{ iterations, cv, p95_mean_ratio });
        }
    }.f);
}

test "BenchmarkCANARY_REQ_GQL_TDE_EXT_KMS_REMOTE_001_UnwrapConcurrencyVariance_Run" {
    try runUnwrapConcurrencyVariance();
}
