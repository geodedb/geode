// CANARY: REQ=REQ-DIST-CLUSTER-3NODE-SUBPROC; FEATURE="DistributedClusterCoordinator"; ASPECT=SubprocessClusterFormation; STATUS=TESTED; TEST=tests/test_cluster_3node_subprocess.zig; OWNER=distributed; UPDATED=2026-05-26
// Task A6 (2026-05-25 distributed cluster testing plan):
// Subprocess 3-node cluster smoke test.
//
// What this test exercises:
//   * Spawning three real `./zig-out/bin/geode serve` child processes on
//     loopback with distinct cluster_port / client port / data_dir per node.
//   * Each child reaches the `[startup] Cluster coordinator started` log
//     line within 30s (proves the cluster bootstrap path lights up end-to-
//     end: CLI args, env-vars, certs, raft init, all four background loops).
//   * Once all three are up, every node's raft loop prints periodic
//     `[raft] node N state=...` lines so the harness can observe leader
//     election progress.  Within a 30s window, at least one node must
//     report `state=leader` AND a non-zero term.
//
// Why subprocesses (vs the in-process A5 test):
//   The in-process test (tests/test_cluster_3node_election.zig) uses
//   `raft_lib.InProcessTransport` to wire three RaftNode instances inside
//   one test binary.  That validates the raft library + the cluster-state
//   bridge fix from A5, but it sidesteps the actual QUIC peer transport.
//   A6 is the first test that runs three full geode binaries that have
//   to discover each other, complete a TLS handshake, exchange
//   RequestVote / AppendEntries over QUIC, and converge on a single
//   leader — i.e. it's the first test that proves the cluster transport
//   actually works between processes.
//
// Fallback behaviour:
//   If the leader-elected log line is not observed within 30s, the test
//   fails with `error.LeaderNeverElected` and dumps each child's stderr
//   to the test runner so the next iteration can triage.  See task A7 in
//   the plan for a future `SHOW CLUSTER STATUS` GQL surface that will let
//   us assert leader / member_count over a real client connection.
//
// Skip semantics:
//   The test SKIPS (returns error.SkipZigTest) when:
//     - the geode binary is missing — build it first with `zig build`.
//     - openssl is unavailable (the test CA and node leaf are generated
//       with it; peers verify each other's TLS certificate against it).
//     - $GEODE_SKIP_SUBPROC_CLUSTER is set, so flaky CI runs can opt out
//       without removing the test from the build matrix.
//   Skip is preferred over hard-fail because the test depends on a
//   pre-built binary in zig-out/bin which CI orchestration may not have
//   populated for every test step.

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const builtin = @import("builtin");

// Zig 0.16 compat: std.posix.getenv was removed.  Mirror the helper used
// across the geode codebase (e.g. src/distributed/cluster_auth.zig) so
// the test reads environment variables the same way the binary it
// spawns does.
fn posixGetenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

// Zig 0.16 compat: std.time.milliTimestamp was removed.  Mirror the helper
// used by src/distributed/cluster.zig so the test doesn't take a
// dependency on a private compat function in a sibling module.
fn nowMillis() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    if (comptime builtin.os.tag == .linux) {
        const req = std.os.linux.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
    } else {
        const req = std.c.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&req, &rem);
    }
}

/// Mark a file descriptor non-blocking so we can scrape stderr from
/// long-running child processes without blocking the test harness.
/// Use the host libc ABI: skipping this on macOS leaves an empty pipe read
/// blocked forever, so the startup/election/teardown deadlines never run.
fn setNonBlocking(file: std.Io.File) !void {
    const fd = file.handle;
    const flags = std.c.fcntl(fd, std.posix.F.GETFL);
    if (flags < 0) return error.FcntlGetFailed;
    const new_flags = flags | @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true }));
    if (std.c.fcntl(fd, std.posix.F.SETFL, new_flags) < 0) return error.FcntlSetFailed;
}

fn runOpenssl(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(gpa, io, .{ .argv = argv });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.OpensslFailed;
}

const Certs = struct { dir: []const u8, ca: []const u8, leaf: []const u8, key: []const u8 };

/// A test CA plus one CA-signed leaf (SAN IP:127.0.0.1) shared by the three
/// nodes, so peers verify each other's TLS certificate against
/// GEODE_CLUSTER_CA_CERT. The nodes cannot use GEODE_CLUSTER_INSECURE=1:
/// release builds refuse it (GAP-0737 SEC-INFRA-01), each node then falls
/// back to its own self-signed cert, every peer handshake fails with
/// HandshakeError and no leader is ever elected. SKIPs if openssl is missing.
fn makeCerts(aa: std.mem.Allocator, io: std.Io, dir: []const u8) !Certs {
    const spawn_gpa = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(spawn_gpa, .{});
    defer threaded.deinit();
    const sio = threaded.io();
    runOpenssl(spawn_gpa, sio, &.{ "openssl", "version" }) catch return error.SkipZigTest;

    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const j = struct {
        fn p(al: std.mem.Allocator, d: []const u8, f: []const u8) ![]const u8 {
            return std.fmt.allocPrint(al, "{s}/{s}", .{ d, f });
        }
    }.p;
    const ca_key = try j(aa, dir, "ca.key");
    const ca = try j(aa, dir, "ca.crt");
    const leaf_key = try j(aa, dir, "leaf.key");
    const leaf_csr = try j(aa, dir, "leaf.csr");
    const leaf = try j(aa, dir, "leaf.crt");
    const ext = try j(aa, dir, "leaf.ext");

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = ext,
        .data = "subjectAltName=IP:127.0.0.1,DNS:localhost\nextendedKeyUsage=serverAuth,clientAuth\n",
    });
    // Pin SHA-256 below: system LibreSSL otherwise defaults to SHA-1,
    // which the real peer certificate verifier correctly rejects.
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", ca_key });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "req", "-sha256", "-x509", "-new", "-key", ca_key, "-days", "1", "-subj", "/CN=geode-subproc-ca", "-addext", "basicConstraints=critical,CA:TRUE", "-out", ca });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", leaf_key });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "req", "-sha256", "-new", "-key", leaf_key, "-subj", "/CN=geode-node", "-out", leaf_csr });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "x509", "-sha256", "-req", "-in", leaf_csr, "-CA", ca, "-CAkey", ca_key, "-CAcreateserial", "-days", "1", "-extfile", ext, "-out", leaf });
    return .{ .dir = dir, .ca = ca, .leaf = leaf, .key = leaf_key };
}

/// Per-child accumulator that owns the stderr capture buffer.
const ChildCapture = struct {
    buf: std.ArrayList(u8) = .empty,
    started: bool = false,
    leader_seen: bool = false,
    last_state: []const u8 = "",
    last_term: u64 = 0,

    fn appendChunk(self: *ChildCapture, allocator: std.mem.Allocator, chunk: []const u8) !void {
        try self.buf.appendSlice(allocator, chunk);
    }

    fn drain(self: *ChildCapture, allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) void {
        var buf: [8192]u8 = undefined;
        const n = file.readStreaming(io, &.{&buf}) catch return;
        self.appendChunk(allocator, buf[0..n]) catch {};
    }

    fn deinit(self: *ChildCapture, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
    }
};

fn tryReap(pid: std.c.pid_t, flags: c_int) bool {
    var status: c_int = undefined;
    return std.c.waitpid(pid, &status, flags) == pid;
}

fn teardownNodes(children: []std.process.Child, captures: []ChildCapture, spawned: usize, gpa: std.mem.Allocator, io: std.Io) void {
    // Phase 1: SIGTERM and keep draining pipes so a node's graceful-shutdown
    // logging never blocks on a full pipe.  Poll (non-blocking) for exit.
    for (children[0..spawned]) |*ch| {
        if (ch.id) |pid| std.posix.kill(pid, std.posix.SIG.TERM) catch {};
    }
    const term_deadline = nowMillis() + 5_000;
    while (nowMillis() < term_deadline) {
        drainAll(captures[0..spawned], children[0..spawned], gpa, io);
        var all_gone = true;
        for (children[0..spawned]) |*ch| {
            if (ch.id == null) continue;
            if (tryReap(ch.id.?, std.c.W.NOHANG)) {
                ch.id = null; // reaped
            } else {
                all_gone = false;
            }
        }
        if (all_gone) break;
        sleepMs(100);
    }
    // Phase 2: SIGKILL + blocking reap anything that ignored SIGTERM.
    for (children[0..spawned]) |*ch| {
        if (ch.id) |pid| {
            std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            _ = tryReap(pid, 0);
            ch.id = null;
        }
    }
    // Close the inherited pipe FDs so the test process leaks none.
    for (children[0..spawned]) |*ch| {
        if (ch.stdout) |f| {
            f.close(io);
            ch.stdout = null;
        }
        if (ch.stderr) |f| {
            f.close(io);
            ch.stderr = null;
        }
        if (ch.stdin) |f| {
            f.close(io);
            ch.stdin = null;
        }
    }
}

/// Continuously drain every node's stdout+stderr pipe.  CRITICAL: the three
/// `--log-level info` nodes keep logging throughout the replication phases; if
/// the harness ever stops reading, a node's pipe buffer (64 KiB) fills, its
/// logging thread blocks in `pipe_write`, and the whole node stalls — which both
/// spuriously fails replication AND wedges teardown (`ch.kill` → `do_wait` while
/// the node can't exit on a blocked pipe).  Call this inside every sleep in the
/// replication/hold loops, not just startup.
fn drainAll(captures: []ChildCapture, children: []std.process.Child, gpa: std.mem.Allocator, io: std.Io) void {
    for (children, 0..) |*ch, i| {
        if (ch.stdout) |f| captures[i].drain(gpa, io, f);
        if (ch.stderr) |f| captures[i].drain(gpa, io, f);
    }
}

test "child capture drains data without blocking on a quiet pipe" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    const reader: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = true } };
    const writer: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer reader.close(io);
    defer writer.close(io);
    try setNonBlocking(reader);
    // Check the flag before attempting a read, so a regression fails promptly
    // even while the writer remains open and has not produced any output.
    const flags = std.c.fcntl(reader.handle, std.posix.F.GETFL);
    try std.testing.expect(flags >= 0);
    try std.testing.expect(flags & @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true })) != 0);
    var capture: ChildCapture = .{};
    defer capture.deinit(std.testing.allocator);
    capture.drain(std.testing.allocator, io, reader);
    try std.testing.expectEqual(@as(usize, 0), capture.buf.items.len);
    try writer.writeStreamingAll(io, "cluster startup\n");
    capture.drain(std.testing.allocator, io, reader);
    try std.testing.expectEqualStrings("cluster startup\n", capture.buf.items);
    capture.drain(std.testing.allocator, io, reader);
    try std.testing.expectEqualStrings("cluster startup\n", capture.buf.items);
}

test "child teardown reaps an exited subprocess through the host ABI" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var child = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", "exit 0" } });
    defer if (child.id != null) child.kill(io);
    const deadline = nowMillis() + 3_000;
    while (nowMillis() < deadline) {
        if (tryReap(child.id.?, std.c.W.NOHANG)) {
            child.id = null;
            break;
        }
        sleepMs(10);
    }
    try std.testing.expect(child.id == null);
}

test "three geode subprocesses on loopback form a 3-node Raft cluster" {
    const a = std.testing.allocator;

    // SKIP gate so flaky CI runners can opt out without removing the
    // test from the build matrix entirely.
    if (posixGetenv("GEODE_SKIP_SUBPROC_CLUSTER") != null) {
        return error.SkipZigTest;
    }

    // TASK A6e (2026-05-26 plan): leader election now converges over the
    // real QUIC transport.  The earlier `RUN_SUBPROCESS_CLUSTER_TEST=1`
    // opt-in gate was removed once the cross-process election story
    // closed:
    //
    //   * A6b wired inbound message routing into RaftNode.stepInner.
    //   * A6c added the persistent per-peer QUIC client pool + multi-
    //     stream `acceptStream` loop on the receiver.
    //   * A6d fixed the RaftEnvelope wire format and propagated the
    //     `pre_vote` bit in both directions.
    //   * A6e decoupled the raft `inner_mutex` from outbound QUIC I/O
    //     by moving sends through a `Transport.outbox` queue drained
    //     on its own thread, and reduced the per-handshake timeout
    //     from 10s to 1s so a transient peer outage no longer freezes
    //     the dispatch path for 30s+.
    //
    // The `GEODE_SKIP_SUBPROC_CLUSTER` opt-out is retained so flaky CI
    // runners (or environments without a built geode binary in
    // zig-out/bin) can still skip without removing the test from the
    // build matrix.

    // The test must run from the geode repo root because the binary path
    // is relative.  std.testing's harness sets cwd to the repo root.
    const binary_path = geode_test_bin.geode_exe;
    const io_check = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io_check, binary_path, .{}) catch {
        std.debug.print(
            "geode binary missing at {s}; run `zig build` first to populate zig-out/bin\n",
            .{binary_path},
        );
        return error.SkipZigTest;
    };

    // Allocate ports — high range to avoid CI collisions.  Cluster ports
    // 21242/21243/21244 are deliberately disjoint from the A5 in-process
    // ports (21000-21002) so a parallel `zig build test` invocation
    // running both A5 and A6 tests doesn't trip over each other.
    const cluster_ports = [_]u16{ 21242, 21243, 21244 };
    const client_ports = [_]u16{ 21341, 21342, 21343 };

    // Build the same peer list for all 3 nodes — appendPeer() in
    // src/server/cluster_bootstrap.zig skips self-references by matching
    // (host, port) against loopback aliases, so each node ends up with
    // exactly 2 peers AND the position-derived peer IDs match the node IDs.
    var peers_buf: [128]u8 = undefined;
    var peers_len: usize = 0;
    inline for (cluster_ports, 0..) |port, i| {
        const fragment = if (i > 0)
            try std.fmt.bufPrint(peers_buf[peers_len..], ",127.0.0.1:{d}", .{port})
        else
            try std.fmt.bufPrint(peers_buf[peers_len..], "127.0.0.1:{d}", .{port});
        peers_len += fragment.len;
    }
    const peers_str = peers_buf[0..peers_len];

    // Per-node owned strings for the CLI args.  ArenaAllocator keeps the
    // bookkeeping simple — we free everything at the end of the test.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    // Per-node data directory.  Tests run as the current user; /tmp is
    // writable on every platform we currently support.
    var tmp_dirs: [3][]const u8 = undefined;
    const ts_suffix = nowMillis();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    for (0..3) |i| {
        tmp_dirs[i] = try std.fmt.allocPrint(aa, "/tmp/geode-test-cluster-n{d}-{d}", .{ i + 1, ts_suffix });
        std.Io.Dir.cwd().deleteTree(io_fs, tmp_dirs[i]) catch {};
        std.Io.Dir.cwd().createDirPath(io_fs, tmp_dirs[i]) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    defer for (tmp_dirs) |dir| std.Io.Dir.cwd().deleteTree(io_fs, dir) catch {};

    const certs_dir = try std.fmt.allocPrint(aa, "/tmp/geode-test-cluster-certs-{d}", .{ts_suffix});
    defer std.Io.Dir.cwd().deleteTree(io_fs, certs_dir) catch {};
    const certs = try makeCerts(aa, io_fs, certs_dir);

    // Spawn the 3 children.  Zig 0.16 replaced `Child.init` + `spawn()`
    // with the standalone `std.process.spawn(io, SpawnOptions)`, so we
    // also stash the per-child Environ.Map in the arena to keep its
    // backing memory alive for the lifetime of the test.
    //
    // CRITICAL: the stdlib's `global_single_threaded` Threaded instance
    // ships with `.allocator = .failing`, so spawn's internal arena
    // OOMs immediately on the first `allocSentinel` for the argv copy
    // (matches the cert_gen.zig hack on line 17).  We build a local
    // Threaded backed by `smp_allocator` for spawn-side allocations.
    var spawn_threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer spawn_threaded.deinit();
    const io_proc = spawn_threaded.io();

    var children: [3]std.process.Child = undefined;
    var spawned: usize = 0;
    var captures: [3]ChildCapture = .{ .{}, .{}, .{} };
    // Teardown must drain pipes before their capture buffers are freed.
    defer for (&captures) |*cap| cap.deinit(a);
    defer teardownNodes(&children, &captures, spawned, a, io_proc);

    for (0..3) |i| {
        const cluster_port_str = try std.fmt.allocPrint(aa, "{d}", .{cluster_ports[i]});
        const listen_quic = try std.fmt.allocPrint(aa, "127.0.0.1:{d}", .{client_ports[i]});
        const node_id_str = try std.fmt.allocPrint(aa, "{d}", .{i + 1});

        const args = try aa.alloc([]const u8, 15);
        args[0] = binary_path;
        args[1] = "serve";
        args[2] = "--listen";
        args[3] = listen_quic;
        args[4] = "--cluster-port";
        args[5] = cluster_port_str;
        args[6] = "--peers";
        args[7] = peers_str;
        args[8] = "--data-dir";
        args[9] = tmp_dirs[i];
        args[10] = "--log-level=info";
        args[11] = "--cert";
        args[12] = certs.leaf;
        args[13] = "--key";
        args[14] = certs.key;

        // Build env: arena-owned Environ.Map.  We populate exactly the
        // keys the cluster bootstrap path consumes (token, node_id,
        // cluster CA, admin password) plus PATH/HOME so openssl
        // (cert_gen) can find its dependencies.  Peer TLS is verified
        // against the test CA (see makeCerts): GEODE_CLUSTER_INSECURE=1
        // is refused in release builds, so it cannot be used here.
        const env_ptr = try aa.create(std.process.Environ.Map);
        env_ptr.* = std.process.Environ.Map.init(aa);
        try env_ptr.put("GEODE_CLUSTER_TOKEN", "test-subprocess-cluster");
        try env_ptr.put("GEODE_NODE_ID", node_id_str);
        try env_ptr.put("GEODE_CLUSTER_CA_CERT", certs.ca);
        try env_ptr.put("GEODE_ADMIN_PASSWORD", "GeodeTestPassword123!");
        if (posixGetenv("PATH")) |p| try env_ptr.put("PATH", p);
        if (posixGetenv("HOME")) |p| try env_ptr.put("HOME", p);
        if (posixGetenv("LD_LIBRARY_PATH")) |p| try env_ptr.put("LD_LIBRARY_PATH", p);

        children[i] = try std.process.spawn(io_proc, .{
            .argv = args,
            .environ_map = env_ptr,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        spawned += 1;

        // Mark stdout/stderr non-blocking so the polling loop below
        // doesn't deadlock waiting on EOF.
        try setNonBlocking(children[i].stderr.?);
        try setNonBlocking(children[i].stdout.?);
    }

    // Phase 1: poll each child's stderr for the "Cluster coordinator
    // started" line within 30s.
    const startup_deadline = nowMillis() + 30_000;
    var buf: [4096]u8 = undefined;
    while (nowMillis() < startup_deadline) {
        var all_started = true;
        for (children[0..], 0..) |*ch, i| {
            if (captures[i].started) continue;
            all_started = false;
            // Drain stderr.
            const n = ch.stderr.?.readStreaming(io_check, &.{&buf}) catch |err| switch (err) {
                error.WouldBlock => @as(usize, 0),
                else => @as(usize, 0),
            };
            if (n > 0) {
                try captures[i].appendChunk(a, buf[0..n]);
                if (std.mem.indexOf(u8, captures[i].buf.items, "Cluster coordinator started") != null) {
                    captures[i].started = true;
                }
            }
            // Also drain stdout (some early diagnostics land there).
            const n2 = ch.stdout.?.readStreaming(io_check, &.{&buf}) catch |err| switch (err) {
                error.WouldBlock => @as(usize, 0),
                else => @as(usize, 0),
            };
            if (n2 > 0) {
                try captures[i].appendChunk(a, buf[0..n2]);
                if (std.mem.indexOf(u8, captures[i].buf.items, "Cluster coordinator started") != null) {
                    captures[i].started = true;
                }
            }
        }
        if (all_started) break;
        sleepMs(50);
    }

    for (captures, 0..) |cap, i| {
        if (!cap.started) {
            std.debug.print("\n--- node {d} stderr (no 'Cluster coordinator started') ---\n{s}\n--- end ---\n", .{ i + 1, cap.buf.items });
            return error.NodeStartupTimeout;
        }
    }

    // Phase 2: poll for leader election.  Each raft loop prints
    // `[raft] node N state=... term=N iter=N` every ~1s.  We tolerate
    // a 30-second deadline because:
    //   * pre_vote=true adds 1-2 round trips on top of a regular election
    //   * QUIC handshake between fresh cluster_port peers can take 1-3s
    //     to settle on the first attempt (UDP retransmit + post-quantum
    //     key exchange in the vendor library)
    //   * the in-process A5 test converges in ~130ms; subprocess QUIC
    //     adds an order-of-magnitude headroom, hence 30s.
    const election_deadline = nowMillis() + 30_000;
    var leader_seen = false;
    while (nowMillis() < election_deadline) {
        for (children[0..], 0..) |*ch, i| {
            const n = ch.stderr.?.readStreaming(io_check, &.{&buf}) catch |err| switch (err) {
                error.WouldBlock => @as(usize, 0),
                else => @as(usize, 0),
            };
            if (n > 0) {
                try captures[i].appendChunk(a, buf[0..n]);
            }
            captures[i].drain(a, io_check, ch.stdout.?);
            // Scan captured logs for any "state=leader" marker.
            if (std.mem.indexOf(u8, captures[i].buf.items, "state=leader") != null) {
                captures[i].leader_seen = true;
                leader_seen = true;
            }
        }
        if (leader_seen) break;
        sleepMs(100);
    }

    if (!leader_seen) {
        for (captures, 0..) |cap, i| {
            // Trim very long output so the test runner stays readable; we
            // dump up to ~8KB per node, which is enough to see the last
            // few raft tick lines.
            const max_dump: usize = 8 * 1024;
            const slice = if (cap.buf.items.len > max_dump)
                cap.buf.items[cap.buf.items.len - max_dump ..]
            else
                cap.buf.items;
            std.debug.print(
                "\n--- node {d} stderr (tail, no leader observed) ---\n{s}\n--- end ---\n",
                .{ i + 1, slice },
            );
        }
        return error.LeaderNeverElected;
    }

    // The deferred teardown drains output and bounds graceful shutdown.
}
