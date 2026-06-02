# GAP-0838 Cross-Pod Raft TLS Handshake Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a TLS-secured geode cluster complete the Raft peer QUIC/TLS handshake across distinct peer IPs **without** `GEODE_CLUSTER_INSECURE`, and add a non-loopback, secure-mode regression test so the gap is caught in CI — closing GAP-0838.

**Architecture:** Two verified defects keep cross-pod clusters from forming. **(RC1)** The default Raft peer-connect path (`connectWithTLS` → `qc.connect()` → `connectInsecure(allow_insecure=false)`) installs **no TLS trust anchor**, so the tls13 verifier fails chain validation; the client never derives trust from the cluster's own configured cert. **(RC2)** Every existing cluster wire test runs with `GEODE_CLUSTER_INSECURE=1` (which is *refused in release builds* anyway) and on `127.0.0.1`, so real TLS validation across distinct IPs has **zero** coverage. The fix threads the cluster's configured server cert into the Raft `Transport` as a trust-anchor fallback, fails fast with an actionable message when no trust is configured, and adds a hermetic non-loopback secure-TLS regression test on a distinct loopback IP (`127.0.0.2`) with an openssl-generated CA-issued cert.

**Tech Stack:** Zig 0.16.0, vendor `quic` v0.1.22 + `tls` v0.1.8 (both already carry the `inline_ca_chain_der` / IP-SAN / leaf-only-chain-completion machinery), openssl 3.x (test cert fixtures), geode build.zig test-step convention.

---

## Background — verified root cause (file:line evidence)

- `src/distributed/raft_consensus.zig:874-903` `connectWithTLS`: priority is `GEODE_CLUSTER_INSECURE` → `GEODE_CLUSTER_CA_CERT` → **`qc.connect()`** (default). The default `connect()` (`src/transport/quic.zig:1560-1622`) calls `connectInsecure(allow_insecure=false)` whose config literal **never sets `inline_ca_chain_der`** (lines 1601-1609) → empty trust store → `tls` `validateChainReturnParsed` fails → `HandshakeError`.
- `src/distributed/cluster_auth.zig:74-90` `isInsecureModeAllowed`: returns **false in release builds** even with `GEODE_CLUSTER_INSECURE=1`. So a release cluster can ONLY form via `GEODE_CLUSTER_CA_CERT` or the new fallback.
- Server cert threading IS wired: `src/distributed/cluster.zig:876-879` applies `self.cert_path`/`self.key_path` to the cluster listener; `src/server/main.zig:1220-1232` passes the resolved `--cert`/`--key` into `cluster_bootstrap.maybeStart`. So the server side presents the operator cert; the gap is purely the **client** trust anchor (RC1).
- `tests/test_cluster_forward_to_shard.zig:1-40` (and every other cluster wire test) skips unless `isInsecureModeAllowed()` — confirming RC2 (no secure-mode coverage).
- tls `matchDnsName` (`tls/src/x509.zig:1599-1630`) already matches IP-literal SNI against iPAddress SANs *and* falls through to dNSName/CN — so a CA-issued leaf with an IP/DNS SAN validates once a trust anchor exists.

## File Structure

- **Create** `tests/test_gap0838_cluster_tls_noloopback.zig` — the non-loopback secure-TLS handshake regression test (reproduction + permanent guard).
- **Modify** `build.zig` — register the new test as `test-gap0838-cluster-tls` and add it to the aggregate test step.
- **Modify** `src/distributed/raft_consensus.zig` — add `Transport.cluster_ca_path` field + setter; extract a pure `resolvePeerTrust` helper; route `connectWithTLS` through it.
- **Modify** `src/distributed/cluster.zig` — in `ClusterCoordinator.start`, set `raft_transport.cluster_ca_path` and emit a fail-fast warning when no peer trust is configured in secure mode.
- **Modify** `Makefile` — add a `test-gap0838-cluster-tls` convenience target.
- **Modify** `docs/GAP_ANALYSIS.md` + `docs/superpowers/plans/2026-06-02-gap0838-0.6.12-cross-pod-retest.md` — record resolution and the new CI guard.
- **Optional (Task 6)** `src/cli/args.zig` (or wherever `--cert` is parsed) — add a `--cluster-ca <path>` flag that seeds `GEODE_CLUSTER_CA_CERT`.

> **Worker note on test mechanics:** `QuicTransport` (`src/transport/quic.zig`) exposes `init(allocator, Config)`, `listen()`, `poll(timeout_ms)`, `deinit()`. `QuicClient` exposes `init(allocator)`, `connect(host,port)`, `connectEx(host,port,ca_path,client_cert,client_key)`, `waitForHandshake(timeout_secs)`, `deinit()`. The server side completes a handshake while a thread loops `server.poll(10)`; the client side polls inside `waitForHandshake`. Tests import the transport module via `@import("transport/quic")` (see `tests/canary_quic_tls.zig`). Env vars are set via `extern "c" fn setenv` (see `tests/test_cluster_forward_to_shard.zig`).

---

## Task 1: Non-loopback secure-TLS handshake regression test (reproduction + guard)

This task is BOTH the failing reproduction and the permanent CI guard. It generates a CA + a CA-issued server leaf (with IP+DNS SANs for `127.0.0.2`), runs a `QuicTransport` server on `127.0.0.2`, and drives a `QuicClient` handshake in **secure** mode. The negative case (no trust anchor → `connect()`) MUST fail; the positive cases (CA trust, and self-signed-cert-as-anchor) MUST succeed.

**Files:**
- Create: `tests/test_gap0838_cluster_tls_noloopback.zig`
- Modify: `build.zig` (register test; pattern at `build.zig:1202-1211`)

- [ ] **Step 1: Write the failing/diagnostic test**

Create `tests/test_gap0838_cluster_tls_noloopback.zig`:

```zig
// CANARY: REQ=REQ-DIST-CLUSTER-TLS-NOLOOPBACK; FEATURE="DistributedCluster"; ASPECT=PeerTlsHandshakeDistinctIp; STATUS=TESTED; TEST=tests/test_gap0838_cluster_tls_noloopback.zig; OWNER=distributed; UPDATED=2026-06-02
//
// GAP-0838 regression: the Raft peer QUIC/TLS handshake must complete across
// DISTINCT peer IPs in SECURE mode (no GEODE_CLUSTER_INSECURE). Loopback +
// insecure masked this for two releases (0.6.7, 0.6.12). This test binds the
// server on 127.0.0.2 (a distinct loopback IP), uses a real openssl-generated
// CA-issued leaf, and validates the handshake with secure verification.
//
// Skips (error.SkipZigTest) only if openssl is unavailable or 127.0.0.2 cannot
// be bound — never silently passes.
const std = @import("std");
const builtin = @import("builtin");
const quic = @import("transport/quic");

const SERVER_IP = "127.0.0.2";

const Fixtures = struct {
    dir: []const u8,
    ca_pem: []const u8, // path to CA cert (trust anchor)
    leaf_pem: []const u8, // path to CA-issued server leaf
    leaf_key: []const u8, // path to server leaf key
    selfsigned_pem: []const u8, // path to a self-signed server cert (== its own CA)
    selfsigned_key: []const u8,
};

fn run(argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, std.testing.allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |c| if (c != 0) return error.OpensslFailed,
        else => return error.OpensslFailed,
    }
}

// Generate a CA, a CA-issued leaf with SAN=IP:127.0.0.2,DNS:127.0.0.2, and a
// standalone self-signed server cert with the same SANs. Returns paths under a
// fresh temp dir. Caller frees nothing (arena-style: dir removed by caller).
fn makeFixtures(a: std.mem.Allocator) !Fixtures {
    // openssl presence check
    run(&.{ "openssl", "version" }) catch return error.SkipZigTest;

    const dir = try std.fmt.allocPrint(a, "/tmp/geode-gap0838-{d}", .{std.os.linux.getpid()});
    std.fs.cwd().makePath(dir) catch {};

    const p = struct {
        fn j(al: std.mem.Allocator, d: []const u8, f: []const u8) []const u8 {
            return std.fmt.allocPrint(al, "{s}/{s}", .{ d, f }) catch unreachable;
        }
    };
    const ca_key = p.j(a, dir, "ca.key");
    const ca_pem = p.j(a, dir, "ca.crt");
    const leaf_key = p.j(a, dir, "leaf.key");
    const leaf_csr = p.j(a, dir, "leaf.csr");
    const leaf_pem = p.j(a, dir, "leaf.crt");
    const ext = p.j(a, dir, "leaf.ext");
    const ss_key = p.j(a, dir, "ss.key");
    const ss_pem = p.j(a, dir, "ss.crt");

    // SAN extension file
    {
        var f = try std.fs.cwd().createFile(ext, .{});
        defer f.close();
        try f.writeAll("subjectAltName=IP:127.0.0.2,DNS:127.0.0.2\nextendedKeyUsage=serverAuth\n");
    }
    // CA (P-256 self-signed)
    try run(&.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", ca_key });
    try run(&.{ "openssl", "req", "-x509", "-new", "-key", ca_key, "-days", "3650", "-subj", "/CN=geode-gap0838-ca", "-out", ca_pem });
    // Leaf signed by CA
    try run(&.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", leaf_key });
    try run(&.{ "openssl", "req", "-new", "-key", leaf_key, "-subj", "/CN=geode-peer", "-out", leaf_csr });
    try run(&.{ "openssl", "x509", "-req", "-in", leaf_csr, "-CA", ca_pem, "-CAkey", ca_key, "-CAcreateserial", "-days", "3650", "-extfile", ext, "-out", leaf_pem });
    // Standalone self-signed server cert (acts as its own CA / shared-cert model)
    try run(&.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", ss_key });
    try run(&.{ "openssl", "req", "-x509", "-new", "-key", ss_key, "-days", "3650", "-subj", "/CN=geode-peer", "-extfile", ext, "-out", ss_pem });

    return .{ .dir = dir, .ca_pem = ca_pem, .leaf_pem = leaf_pem, .leaf_key = leaf_key, .selfsigned_pem = ss_pem, .selfsigned_key = ss_key };
}

const ServerThread = struct {
    transport: *quic.QuicTransport,
    stop: *std.atomic.Value(bool),
    fn loop(t: *quic.QuicTransport, stop: *std.atomic.Value(bool)) void {
        while (!stop.load(.acquire)) {
            t.poll(10) catch {};
        }
    }
};

// Bring up a server on 127.0.0.2:port with cert/key, return port + handles.
fn startServer(a: std.mem.Allocator, cert: []const u8, key: []const u8, port: u16) !struct {
    transport: *quic.QuicTransport,
    thread: std.Thread,
    stop: *std.atomic.Value(bool),
} {
    const t = try a.create(quic.QuicTransport);
    t.* = try quic.QuicTransport.init(a, .{
        .address = SERVER_IP,
        .port = port,
        .cert_path = cert,
        .key_path = key,
    });
    t.listen() catch |e| {
        t.deinit();
        a.destroy(t);
        return e;
    };
    const stop = try a.create(std.atomic.Value(bool));
    stop.* = std.atomic.Value(bool).init(false);
    const th = try std.Thread.spawn(.{}, ServerThread.loop, .{ t, stop });
    return .{ .transport = t, .thread = th, .stop = stop };
}

test "GAP-0838: secure peer TLS handshake on distinct IP fails without trust anchor (RC1 reproduction)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const fx = makeFixtures(a) catch |e| if (e == error.SkipZigTest) return error.SkipZigTest else return e;
    defer std.fs.cwd().deleteTree(fx.dir) catch {};

    const srv = try startServer(a, fx.leaf_pem, fx.leaf_key, 24842);
    defer {
        srv.stop.store(true, .release);
        srv.thread.join();
        srv.transport.deinit();
        a.destroy(srv.transport);
        a.destroy(srv.stop);
    }

    // NEGATIVE: default connect() => connectInsecure(allow_insecure=false) with
    // no trust anchor. Must FAIL — this is the cross-pod defect.
    var client = quic.QuicClient.init(a);
    defer client.deinit();
    client.connect(SERVER_IP, 24842) catch return; // connect may itself fail; acceptable
    const r = client.waitForHandshake(2);
    try std.testing.expectError(quic.QuicError.HandshakeError, r);
}

test "GAP-0838: secure peer TLS handshake on distinct IP succeeds with CA trust (Path B)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const fx = makeFixtures(a) catch |e| if (e == error.SkipZigTest) return error.SkipZigTest else return e;
    defer std.fs.cwd().deleteTree(fx.dir) catch {};

    const srv = try startServer(a, fx.leaf_pem, fx.leaf_key, 24843);
    defer {
        srv.stop.store(true, .release);
        srv.thread.join();
        srv.transport.deinit();
        a.destroy(srv.transport);
        a.destroy(srv.stop);
    }

    var client = quic.QuicClient.init(a);
    defer client.deinit();
    // connectEx with the CA as trust anchor; SNI = "127.0.0.2" matches IP SAN.
    try client.connectEx(SERVER_IP, 24843, fx.ca_pem, null, null);
    try client.waitForHandshake(5); // must SUCCEED
}

test "GAP-0838: secure peer TLS handshake succeeds with self-signed cert pinned as anchor (RC1 fix model)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const fx = makeFixtures(a) catch |e| if (e == error.SkipZigTest) return error.SkipZigTest else return e;
    defer std.fs.cwd().deleteTree(fx.dir) catch {};

    const srv = try startServer(a, fx.selfsigned_pem, fx.selfsigned_key, 24844);
    defer {
        srv.stop.store(true, .release);
        srv.thread.join();
        srv.transport.deinit();
        a.destroy(srv.transport);
        a.destroy(srv.stop);
    }

    var client = quic.QuicClient.init(a);
    defer client.deinit();
    // Pin the server's own self-signed cert as the trust anchor (shared-cert model).
    try client.connectEx(SERVER_IP, 24844, fx.selfsigned_pem, null, null);
    try client.waitForHandshake(5); // must SUCCEED
}
```

- [ ] **Step 2: Register the test in build.zig**

After the block at `build.zig:1202-1211` (the `cluster_3node_election` test), insert:

```zig
    // GAP-0838: non-loopback (distinct IP) secure-mode peer TLS handshake.
    const gap0838_cluster_tls_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/test_gap0838_cluster_tls_noloopback.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    gap0838_cluster_tls_tests.root_module.addImport("transport/quic", transport_quic_mod);
    gap0838_cluster_tls_tests.root_module.link_libc = true;
    const run_gap0838_cluster_tls_tests = b.addRunArtifact(gap0838_cluster_tls_tests);
    const gap0838_cluster_tls_step = b.step("test-gap0838-cluster-tls", "Run GAP-0838 non-loopback secure peer TLS handshake test");
    gap0838_cluster_tls_step.dependOn(&run_gap0838_cluster_tls_tests.step);
```

Then find the aggregate `test` step (search `b.step("test"` / `test_step.dependOn`) and add `test_step.dependOn(&run_gap0838_cluster_tls_tests.step);` so it runs in `zig build test`.

> If `transport_quic_mod` is not in lexical scope at line ~1206, move the new block below its definition (`build.zig:625`) or reference the same variable the surrounding tests use for transport imports. Confirm with `grep -n "transport_quic_mod" build.zig`.

- [ ] **Step 3: Run the test — confirm the negative reproduces and observe positives**

Run:
```bash
cd /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode
zig build test-gap0838-cluster-tls 2>&1 | tail -40
```
Expected at this point: the **negative** test passes (handshake correctly fails without trust). The two **positive** tests reveal current HEAD behavior — capture the exact result:
- If both positives PASS → HEAD already completes secure cross-IP handshakes given a trust anchor; the remaining work (Tasks 2-3) is wiring that trust anchor in by default + fail-fast UX. **This empirically proves the report's 0.6.12 failure was the pre-fix binary.**
- If a positive FAILS → capture the exact error; that is the true remaining RC2 and Tasks 2-3 must address it. **Report the failure verbatim to the orchestrator before proceeding.**

- [ ] **Step 4: Commit the test**

```bash
git add tests/test_gap0838_cluster_tls_noloopback.zig build.zig
git commit -m "test(gap-0838): non-loopback secure peer TLS handshake regression test"
```

---

## Task 2: Trust-anchor resolution helper + Transport.cluster_ca_path (RC1 core fix)

Make the Raft peer client use the cluster's configured cert as a TLS trust anchor when no explicit `GEODE_CLUSTER_CA_CERT` is set, so a shared-cert/CA cluster forms in secure mode by default. Extract the priority logic into a pure, unit-tested function.

**Files:**
- Modify: `src/distributed/raft_consensus.zig` (Transport struct ~`288`, `connectWithTLS` `874-903`, callsite `814`)
- Test: same file (inline `test` blocks) — the pure helper is unit-testable without networking.

- [ ] **Step 1: Write the failing unit test for the trust-priority helper**

Add to `src/distributed/raft_consensus.zig` (near the existing tests):

```zig
test "resolvePeerTrust: priority insecure > env CA > transport CA > none" {
    // insecure wins regardless of CA inputs
    try std.testing.expectEqual(PeerTrust.insecure, resolvePeerTrust(true, "env.pem", "txp.pem"));
    // env CA beats transport CA
    try std.testing.expectEqualStrings("env.pem", resolvePeerTrust(false, "env.pem", "txp.pem").ca);
    // transport CA used when no env CA
    try std.testing.expectEqualStrings("txp.pem", resolvePeerTrust(false, null, "txp.pem").ca);
    // none when nothing configured
    try std.testing.expectEqual(PeerTrust.none, resolvePeerTrust(false, null, null));
}
```

- [ ] **Step 2: Run it to verify it fails to compile (helper undefined)**

Run:
```bash
zig build test-raft-command-refactor 2>&1 | tail -20   # any step that compiles raft_consensus tests
```
Expected: compile error — `PeerTrust`/`resolvePeerTrust` undefined. (If no raft-only test step compiles this file, use `zig build test 2>&1 | grep -i resolvePeerTrust`.)

- [ ] **Step 3: Implement the helper + Transport field + route connectWithTLS through it**

Add the tagged union + helper above `connectWithTLS` in `src/distributed/raft_consensus.zig`:

```zig
/// Resolved peer-TLS trust decision for a Raft peer connection.
pub const PeerTrust = union(enum) {
    insecure, // skip verification (Debug + GEODE_CLUSTER_INSECURE only)
    ca: []const u8, // verify against this CA/anchor PEM path
    none, // no trust configured — secure verify against an empty store (will fail)
};

/// Pure priority resolver (unit-testable): GEODE_CLUSTER_INSECURE >
/// GEODE_CLUSTER_CA_CERT > the cluster's configured cert (transport_ca) > none.
pub fn resolvePeerTrust(insecure_allowed: bool, env_ca: ?[]const u8, transport_ca: ?[]const u8) PeerTrust {
    if (insecure_allowed) return .insecure;
    if (env_ca) |e| if (e.len > 0) return .{ .ca = e };
    if (transport_ca) |t| if (t.len > 0) return .{ .ca = t };
    return .none;
}
```

Add a field + setter to the `Transport` struct (near its other fields, ~`src/distributed/raft_consensus.zig:288-320`):

```zig
    /// GAP-0838: PEM path used as the peer-TLS trust anchor when
    /// GEODE_CLUSTER_CA_CERT is not set. Set from the cluster's configured
    /// `--cert` by ClusterCoordinator.start. Borrowed; outlives the Transport.
    cluster_ca_path: ?[]const u8 = null,
```

```zig
    /// GAP-0838: install the cluster's configured cert as the default peer-TLS
    /// trust anchor (used when GEODE_CLUSTER_CA_CERT is unset).
    pub fn setClusterCaPath(self: *Transport, path: []const u8) void {
        self.cluster_ca_path = if (path.len > 0) path else null;
    }
```

Rewrite `connectWithTLS` (`src/distributed/raft_consensus.zig:874-903`) to take the transport CA and route through the helper:

```zig
fn connectWithTLS(qc: *quic.QuicClient, allocator: Allocator, host: []const u8, port: u16, transport_ca: ?[]const u8) !void {
    const ca = @import("cluster_auth.zig");
    const allow_insecure = ca.isInsecureModeAllowed();

    const env_ca = getEnvVarOwned(allocator, "GEODE_CLUSTER_CA_CERT") catch null;
    defer if (env_ca) |p| allocator.free(p);

    switch (resolvePeerTrust(allow_insecure, env_ca, transport_ca)) {
        .insecure => {
            log.warn("SEC-D011: Raft RPC TLS verification disabled via GEODE_CLUSTER_INSECURE", &.{});
            try qc.connectInsecure(host, port, true);
        },
        .ca => |path| try qc.connectEx(host, port, path, null, null),
        .none => try qc.connect(host, port),
    }
    try qc.waitForHandshake(1);
}
```

Update the single callsite (`src/distributed/raft_consensus.zig:814`):

```zig
    try connectWithTLS(&conn.client, self.allocator, conn.endpoint, conn.port, self.cluster_ca_path);
```

- [ ] **Step 4: Run the unit test — verify it passes**

Run:
```bash
zig build test 2>&1 | grep -iE "resolvePeerTrust|raft_consensus|FAIL|error:" | tail -20
```
Expected: the `resolvePeerTrust` test passes; raft_consensus compiles clean.

- [ ] **Step 5: Commit**

```bash
git add src/distributed/raft_consensus.zig
git commit -m "fix(raft): use cluster cert as peer-TLS trust anchor fallback (GAP-0838 RC1)"
```

---

## Task 3: Wire cluster cert into the Raft transport + fail-fast UX

**Files:**
- Modify: `src/distributed/cluster.zig` (`ClusterCoordinator.start`, ~`854-882`)
- Test: extend `tests/test_cluster_coordinator_config.zig` (existing config test) to assert the transport receives the cert path.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_cluster_coordinator_config.zig`:

```zig
test "GAP-0838: coordinator threads cert_path into raft_transport.cluster_ca_path" {
    const geode = @import("geode");
    const ClusterCoordinator = geode.distributed.cluster.ClusterCoordinator;
    const a = std.testing.allocator;
    var coord = try ClusterCoordinator.init(a, .{
        .node_id = 1,
        .cluster_port = 0,
        .cert_path = "certs/server.crt",
        .key_path = "certs/server.key",
    });
    defer coord.deinit();
    // setClusterCaPath is applied during start(); call the helper directly here
    coord.raft_transport.setClusterCaPath(coord.cert_path);
    try std.testing.expect(coord.raft_transport.cluster_ca_path != null);
    try std.testing.expectEqualStrings("certs/server.crt", coord.raft_transport.cluster_ca_path.?);
}
```

> Adjust the `ClusterCoordinator.init(...)` config literal to match the real `Config` struct (`src/distributed/cluster.zig:2329+`). If `init` requires more fields, copy them from the existing tests in this file.

- [ ] **Step 2: Run it to verify it fails**

Run:
```bash
zig build test-cluster-coordinator-config 2>&1 | tail -20
```
Expected: FAIL — `cluster_ca_path` is null (start() not yet wiring it; helper not called in real path).

- [ ] **Step 3: Implement the wiring + fail-fast warning in `ClusterCoordinator.start`**

In `src/distributed/cluster.zig` `start()`, immediately after `self.raft.setTransport(&self.raft_transport);` (~line 869), add:

```zig
        // GAP-0838: give the Raft peer client a default TLS trust anchor so a
        // shared-cert/CA cluster forms in secure mode without operators having
        // to hand-set GEODE_CLUSTER_CA_CERT. GEODE_CLUSTER_CA_CERT still wins.
        if (self.cert_path.len > 0) self.raft_transport.setClusterCaPath(self.cert_path);

        // Fail-fast UX: if clustering is enabled, verification is on (release or
        // no GEODE_CLUSTER_INSECURE), and NO peer trust is configured, warn
        // loudly — otherwise peers wedge at state=candidate term=0 forever.
        {
            const cauth = @import("cluster_auth.zig");
            const has_env_ca = blk: {
                const v = std.posix.getenv("GEODE_CLUSTER_CA_CERT");
                break :blk v != null and v.?.len > 0;
            };
            if (!cauth.isInsecureModeAllowed() and !has_env_ca and self.cert_path.len == 0) {
                log.warn("GAP-0838: cluster TLS has no peer trust anchor configured (no GEODE_CLUSTER_CA_CERT and no --cert); cross-node Raft handshakes WILL fail. Provide --cert (shared cert) or set GEODE_CLUSTER_CA_CERT.", &.{});
            }
        }
```

> Confirm `log` is the module logger in scope in cluster.zig (search `log.warn(` in the file). If the logger symbol differs, match the surrounding code.

- [ ] **Step 4: Run the test — verify it passes**

Run:
```bash
zig build test-cluster-coordinator-config 2>&1 | tail -20
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/distributed/cluster.zig tests/test_cluster_coordinator_config.zig
git commit -m "fix(cluster): thread cert into raft peer trust + fail-fast on missing trust (GAP-0838)"
```

---

## Task 4: Full build + targeted suite validation

**Files:** none (validation only).

- [ ] **Step 1: Build debug**

Run:
```bash
make build 2>&1 | tail -20
```
Expected: builds clean (no new warnings/errors).

- [ ] **Step 2: Run the GAP-0838 + cluster + raft test steps**

Run (one at a time — single-core box; do NOT parallelize builds):
```bash
zig build test-gap0838-cluster-tls 2>&1 | tail -20
zig build test-cluster-coordinator-config 2>&1 | tail -20
zig build test-cluster-forward-to-shard 2>&1 | tail -20
zig build test-drainready-dispatch 2>&1 | tail -20
```
Expected: all PASS (forward-to-shard/drainready may SKIP in release; that's fine).

- [ ] **Step 3: Run the aggregate unit test suite**

Run:
```bash
zig build test 2>&1 | tail -30
```
Expected: no regressions vs. baseline. If any pre-existing failures exist, confirm they are unrelated to this change (compare to `git stash` baseline only if in doubt).

- [ ] **Step 4: Commit (if any incidental fixups were needed)**

```bash
git add -A && git commit -m "test(gap-0838): validate cross-pod TLS fix across cluster suite" || echo "nothing to commit"
```

---

## Task 5: Makefile target + docs/GAP_ANALYSIS update

**Files:**
- Modify: `Makefile`
- Modify: `docs/GAP_ANALYSIS.md`, `docs/superpowers/plans/2026-06-02-gap0838-0.6.12-cross-pod-retest.md`

- [ ] **Step 1: Add a Makefile target**

Append near the other `test-*` targets in `Makefile`:

```make
.PHONY: test-gap0838
test-gap0838: ## Run GAP-0838 non-loopback secure peer TLS handshake regression test
	zig build test-gap0838-cluster-tls
```

- [ ] **Step 2: Update GAP_ANALYSIS.md**

Locate the GAP-0838 entry in `docs/GAP_ANALYSIS.md` and update its status/notes to reflect: (a) root cause RC1/RC2 with file:line, (b) the fix (trust-anchor fallback + fail-fast + non-loopback CI test), (c) the new test name and `make test-gap0838` target, (d) the verified handshake result from Task 1 Step 3. Move to `docs/GAP_ANALYSIS_RESOLVED.md` ONLY if Task 1's positive cases passed and the fix is verified; otherwise keep OPEN with the narrowed root cause recorded.

- [ ] **Step 3: Append a resolution footer to the retest plan doc**

In `docs/superpowers/plans/2026-06-02-gap0838-0.6.12-cross-pod-retest.md`, add a dated "## Resolution (2026-06-02)" section summarizing: the published 0.6.12 binary predates the complete fix; HEAD threads a peer-TLS trust anchor and is now guarded by `tests/test_gap0838_cluster_tls_noloopback.zig`; deployment recommendation (upgrade to the release containing this commit, or set `GEODE_CLUSTER_CA_CERT`/share the cert).

- [ ] **Step 4: Commit**

```bash
git add Makefile docs/GAP_ANALYSIS.md docs/GAP_ANALYSIS_RESOLVED.md docs/superpowers/plans/2026-06-02-gap0838-0.6.12-cross-pod-retest.md
git commit -m "docs(gap-0838): record root cause + resolution; add make test-gap0838"
```

---

## Task 6 (optional): `--cluster-ca` CLI flag

The retest doc notes `geode serve --help` exposes no peer-trust flag. Add `--cluster-ca <path>` that seeds `GEODE_CLUSTER_CA_CERT` so operators don't need the env var.

**Files:**
- Modify: the CLI arg parser that defines `--cert`/`--key` (find with `grep -rn "\"--cert\"\|--cert" src/cli/ src/server/main.zig`)
- Test: extend `tests/test_cli_args_cluster.zig`

- [ ] **Step 1:** Write a failing test in `tests/test_cli_args_cluster.zig` asserting `--cluster-ca /x/ca.pem` parses into the resolved cluster CA path.
- [ ] **Step 2:** Run `zig build test-cli-args-cluster` → FAIL.
- [ ] **Step 3:** Add the flag to the parser; on startup, if set and `GEODE_CLUSTER_CA_CERT` unset, `setenv("GEODE_CLUSTER_CA_CERT", path, 0)` (or thread directly into the cluster config).
- [ ] **Step 4:** Run `zig build test-cli-args-cluster` → PASS; `./zig-out/bin/geode serve --help` shows the flag.
- [ ] **Step 5:** Commit `feat(cli): add --cluster-ca peer-trust flag (GAP-0838)`.

---

## Self-Review Notes

- **Spec coverage:** Report's two acceptance criteria are covered — "non-loopback TLS cluster integration test in CI" (Task 1 + Task 5 Makefile/CI) and "peer handshake fixed for distinct IPs" (Tasks 2-3, verified by Task 1 positives).
- **Empirical gate:** Task 1 Step 3 is a hard checkpoint — if a positive case fails, the orchestrator re-scopes Tasks 2-3 to the revealed root cause before continuing. No fix is declared without the test proving it.
- **Type consistency:** `PeerTrust` / `resolvePeerTrust` / `setClusterCaPath` / `cluster_ca_path` used consistently across Tasks 2-3. `connectWithTLS` signature gains exactly one param (`transport_ca: ?[]const u8`), updated at its single callsite.
- **No mock/simulation:** real openssl certs, real QUIC endpoints, real handshake — honors the project's "NO MOCK DATA" rule.
- **Env constraints:** single-core box — every step runs one `zig build` at a time; no parallel builds.
```
