// SONNY-6571: with TDE on (GEODE_TDE_KEY set), no written graph data appears
// in plaintext anywhere under a server's data directory: not in the storage
// engine's pages or WAL, and, in cluster mode, not in the Raft log, hard
// state or snapshots.
//
// Real `geode serve` processes (this build's binary), real files. Each test
// generates its own TDE key and a label, relationship type, property key,
// string value and integer value that are random per run (so a stale file
// cannot match), writes them, reads them back, then reads every regular file
// under the data directory (or every node's), once with the server(s)
// running (the write is durable: the engine fsyncs each commit, the Raft log
// each append) and once after a clean SIGTERM shutdown (which checkpoints),
// and reports each file holding any of them.
//
// Single node: the configuration CLAUDE.md calls production-ready.
// Cluster: three nodes on 127.0.0.171-173 (no other test uses those
// addresses, SONNY-6460) with CA-signed peer TLS, the fixture of
// tests/test_cluster_replicable_mutations.zig. The write goes to the leader
// and is read back on every node, so every node has applied it.
//
// Two steps run this file:
// * test-sonny6571-tde-at-rest (the single-node and cluster tests): no value
//   in any file, and no name outside the storage engine's schema-name files
//   (`schema_name_files`). RED before the fix: every cluster node's Raft log
//   (`<data>/raft/entries.wal`, the raft library's FileStorage) held the
//   replicated CREATE - label, key, string and integer value - in plaintext.
// * test-sonny6571-schema-names (the schema-names test): no name in those
//   files either. RED until graph-storage encrypts `labels.dict` and
//   `props.idx` and geode its `prop_exact.idx` / `prop_rev.idx`
//   (docs/KNOWN_TEST_ISSUES.md).
//
// Skips (error.SkipZigTest) when not on linux, the geode binary is missing,
// openssl is unavailable, or GEODE_SKIP_SUBPROC_CLUSTER is set (cluster test).
//
// CANARY: REQ=REQ-SONNY-6571-TDE-RAFT-AT-REST; FEATURE="TDEFileLevelEncryption"; ASPECT=NoPlaintextUnderDataDir; STATUS=TESTED; TEST=tests/test_sonny6571_tde_at_rest.zig; OWNER=security; UPDATED=2026-11-15

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const test_ports = @import("test_ports.zig");

const BINARY_PATH = geode_test_bin.geode_exe;
const NODE_IPS = [_][]const u8{ "127.0.0.171", "127.0.0.172", "127.0.0.173" };
const SINGLE_IP = "127.0.0.1";
const ADMIN_PW = "Sonny6571 TDE At Rest Admin Passphrase";
const STARTUP_DEADLINE_MS: i64 = 45_000;
/// Largest file the scan reads whole (the engine's store files are a few MB).
const MAX_SCAN_BYTES: usize = 1 << 30;

// ---------------------------------------------------------------------------
// Small helpers (Zig 0.16 compat shims, as in the cluster fixtures).
// ---------------------------------------------------------------------------

fn posixGetenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

fn nowMillis() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.os.linux.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

fn setNonBlocking(file: std.Io.File) !void {
    const fd = file.handle;
    const flags = std.os.linux.fcntl(fd, std.posix.F.GETFL, 0);
    if (@as(isize, @bitCast(flags)) < 0) return error.FcntlGetFailed;
    const new_flags = flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true }));
    const rc = std.os.linux.fcntl(fd, std.posix.F.SETFL, new_flags);
    if (@as(isize, @bitCast(rc)) < 0) return error.FcntlSetFailed;
}

fn binaryPresent() bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, BINARY_PATH, .{}) catch return false;
    return true;
}

/// `n` random bytes as lowercase hex (never a fixed key in a test).
fn randomHex(aa: std.mem.Allocator, comptime n: usize) ![]u8 {
    var raw: [n]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&raw);
    return std.fmt.allocPrint(aa, "{x}", .{&raw});
}

/// The per-run secrets: a TDE key, and a label, property key, property
/// value and relationship type the scan looks for.
const Needles = struct {
    tde_key: []const u8,
    label: []const u8,
    key: []const u8,
    value: []const u8,
    rel_type: []const u8,
    /// An integer property value; the scan looks for its 8 bytes,
    /// little-endian (how an i64 is laid out on disk).
    number: i64,
    number_le: [8]u8,

    fn make(aa: std.mem.Allocator) !Needles {
        var raw: [8]u8 = undefined;
        std.Io.Threaded.global_single_threaded.io().random(&raw);
        // Positive, and wide enough that no other 8 bytes match by chance.
        const n: i64 = @intCast((std.mem.readInt(u64, &raw, .little) >> 2) | (1 << 60));
        var le: [8]u8 = undefined;
        std.mem.writeInt(i64, &le, n, .little);
        return .{
            .tde_key = try randomHex(aa, 32),
            .label = try std.fmt.allocPrint(aa, "Sonny6571L{s}", .{try randomHex(aa, 6)}),
            .key = try std.fmt.allocPrint(aa, "sonny6571k{s}", .{try randomHex(aa, 6)}),
            .value = try std.fmt.allocPrint(aa, "sonny6571-secret-{s}", .{try randomHex(aa, 12)}),
            .rel_type = try std.fmt.allocPrint(aa, "SONNY6571R{s}", .{try randomHex(aa, 6)}),
            .number = n,
            .number_le = le,
        };
    }
};

// ---------------------------------------------------------------------------
// Certificates: a CA and one leaf naming every address the tests listen on.
// ---------------------------------------------------------------------------

fn runOpenssl(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(gpa, io, .{ .argv = argv });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.OpensslFailed;
}

const Certs = struct { dir: []const u8, ca: []const u8, leaf: []const u8, key: []const u8 };

fn makeCerts(aa: std.mem.Allocator, io: std.Io) !Certs {
    const spawn_gpa = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(spawn_gpa, .{});
    defer threaded.deinit();
    const sio = threaded.io();
    runOpenssl(spawn_gpa, sio, &.{ "openssl", "version" }) catch return error.SkipZigTest;

    const dir = try std.fmt.allocPrint(aa, "/tmp/geode-sonny6571-{d}-{d}", .{ std.os.linux.getpid(), nowMillis() });
    try std.Io.Dir.cwd().createDirPath(io, dir);
    errdefer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const ca_key = try std.fmt.allocPrint(aa, "{s}/ca.key", .{dir});
    const ca = try std.fmt.allocPrint(aa, "{s}/ca.crt", .{dir});
    const leaf_key = try std.fmt.allocPrint(aa, "{s}/leaf.key", .{dir});
    const leaf_csr = try std.fmt.allocPrint(aa, "{s}/leaf.csr", .{dir});
    const leaf = try std.fmt.allocPrint(aa, "{s}/leaf.crt", .{dir});
    const ext = try std.fmt.allocPrint(aa, "{s}/leaf.ext", .{dir});
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = ext,
        .data = "subjectAltName=IP:127.0.0.171,IP:127.0.0.172,IP:127.0.0.173,IP:127.0.0.1,DNS:localhost\nextendedKeyUsage=serverAuth,clientAuth\n",
    });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", ca_key });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "req", "-sha256", "-x509", "-new", "-key", ca_key, "-days", "1", "-subj", "/CN=geode-sonny6571-ca", "-addext", "basicConstraints=critical,CA:TRUE", "-out", ca });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", leaf_key });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "req", "-sha256", "-new", "-key", leaf_key, "-subj", "/CN=geode-node", "-out", leaf_csr });
    try runOpenssl(spawn_gpa, sio, &.{ "openssl", "x509", "-sha256", "-req", "-in", leaf_csr, "-CA", ca, "-CAkey", ca_key, "-CAcreateserial", "-days", "1", "-extfile", ext, "-out", leaf });
    return .{ .dir = dir, .ca = ca, .leaf = leaf, .key = leaf_key };
}

/// `geode query` against `ip:port`, verifying the server against the test CA.
/// Returns stdout (caller frees with `gpa`).
fn runQuery(gpa: std.mem.Allocator, io: std.Io, aa: std.mem.Allocator, ca: []const u8, ip: []const u8, port: u16, q: []const u8) ![]u8 {
    const server = try std.fmt.allocPrint(aa, "{s}:{d}", .{ ip, port });
    const argv = [_][]const u8{ BINARY_PATH, "query", "--server", server, "--ca-cert", ca, "-U", "geode", "-P", ADMIN_PW, q };
    const res = try std.process.run(gpa, io, .{
        .argv = &argv,
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromNanoseconds(15 * std.time.ns_per_s), .clock = .awake } },
    });
    defer gpa.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) {
        std.debug.print("[query] {s} on {s} exited {any}: {s}\n", .{ q, server, res.term, res.stderr[0..@min(res.stderr.len, 400)] });
    }
    return res.stdout;
}

// ---------------------------------------------------------------------------
// Child processes: spawn, log capture, clean stop.
// ---------------------------------------------------------------------------

const Capture = struct {
    buf: std.ArrayList(u8) = .empty,
    fn drain(self: *Capture, gpa: std.mem.Allocator, io: std.Io, file: std.Io.File) void {
        var tmp: [8192]u8 = undefined;
        while (true) {
            const n = file.readStreaming(io, &.{&tmp}) catch return;
            if (n == 0) return;
            self.buf.appendSlice(gpa, tmp[0..n]) catch return;
        }
    }
};

const Node = struct {
    child: std.process.Child,
    capture: Capture = .{},
    data_dir: []const u8,

    fn drain(self: *Node, gpa: std.mem.Allocator, io: std.Io) void {
        if (self.child.stdout) |f| self.capture.drain(gpa, io, f);
        if (self.child.stderr) |f| self.capture.drain(gpa, io, f);
    }

    fn tail(self: *const Node) []const u8 {
        const b = self.capture.buf.items;
        return b[if (b.len > 2000) b.len - 2000 else 0..];
    }
};

fn tryReap(pid: i32, flags: u32) bool {
    var status: u32 = undefined;
    const rc = std.os.linux.waitpid(pid, &status, flags);
    return @as(isize, @bitCast(rc)) > 0;
}

/// SIGTERM every node (a clean shutdown checkpoints), wait up to 20 s, then
/// SIGKILL whatever is left. Only PIDs this test spawned are signalled.
fn stopNodes(nodes: []Node, gpa: std.mem.Allocator, io: std.Io) void {
    for (nodes) |*n| {
        if (n.child.id) |pid| std.posix.kill(pid, std.posix.SIG.TERM) catch {};
    }
    const deadline = nowMillis() + 20_000;
    while (nowMillis() < deadline) {
        var all_gone = true;
        for (nodes) |*n| {
            n.drain(gpa, io);
            const pid = n.child.id orelse continue;
            if (tryReap(pid, std.os.linux.W.NOHANG)) n.child.id = null else all_gone = false;
        }
        if (all_gone) break;
        sleepMs(100);
    }
    for (nodes) |*n| {
        if (n.child.id) |pid| {
            std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            _ = tryReap(pid, 0);
            n.child.id = null;
        }
        inline for (.{ "stdout", "stderr", "stdin" }) |field| {
            if (@field(n.child, field)) |f| {
                f.close(io);
                @field(n.child, field) = null;
            }
        }
    }
}

fn spawnServe(io: std.Io, args: []const []const u8, env: *std.process.Environ.Map) !std.process.Child {
    if (posixGetenv("PATH")) |p| try env.put("PATH", p);
    if (posixGetenv("HOME")) |p| try env.put("HOME", p);
    if (posixGetenv("LD_LIBRARY_PATH")) |p| try env.put("LD_LIBRARY_PATH", p);
    const child = try std.process.spawn(io, .{ .argv = args, .environ_map = env, .stdout = .pipe, .stderr = .pipe });
    errdefer {
        if (child.id) |pid| std.posix.kill(pid, std.posix.SIG.KILL) catch {};
    }
    try setNonBlocking(child.stdout.?);
    try setNonBlocking(child.stderr.?);
    return child;
}

// ---------------------------------------------------------------------------
// The scan: every regular file under a directory, searched for the needles.
// ---------------------------------------------------------------------------

const Finding = struct {
    phase: []const u8,
    path: []const u8,
    what: []const u8,
    /// A label, relationship type or property key name in one of the files
    /// where the storage engine keeps those names (`schema_name_files`).
    schema_name: bool,
};

/// The files the scan found label, relationship type and property key NAMES
/// in with TDE on, on a single server (values: none), at the time of
/// SONNY-6571. `labels.dict` (every shard) and `props.idx` are graph-storage's
/// (v0.4.15 engine_persist.zig saveLabelDictionary; file_manager.zig prop_idx);
/// `prop_exact.idx` and `prop_rev.idx` are geode's exact property index
/// (src/storage/graph_storage_adapter.zig NodePropertyExactIndex.saveToFile,
/// prop_rev_index_file_name). The schema-names test below requires them to
/// hold no names either; it stays red until they are encrypted. The other
/// tests fail on any other hit, and on any value anywhere.
const schema_name_files = [_][]const u8{ "labels.dict", "props.idx", "prop_exact.idx", "prop_rev.idx" };

fn isSchemaName(what: []const u8, basename: []const u8) bool {
    const is_name = std.mem.eql(u8, what, "label") or std.mem.eql(u8, what, "key") or std.mem.eql(u8, what, "reltype");
    if (!is_name) return false;
    for (schema_name_files) |f| {
        if (std.mem.eql(u8, f, basename)) return true;
    }
    return false;
}

fn scanTree(
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    needles: Needles,
    phase: []const u8,
    findings: *std.ArrayList(Finding),
    files_scanned: *usize,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const bytes = entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(MAX_SCAN_BYTES)) catch |err| switch (err) {
            // A file the server removed between the listing and the read.
            error.FileNotFound => continue,
            else => return err,
        };
        defer gpa.free(bytes);
        files_scanned.* += 1;
        const checks = [_]struct { what: []const u8, needle: []const u8 }{
            .{ .what = "value", .needle = needles.value },
            .{ .what = "label", .needle = needles.label },
            .{ .what = "key", .needle = needles.key },
            .{ .what = "reltype", .needle = needles.rel_type },
            .{ .what = "number", .needle = &needles.number_le },
        };
        for (checks) |c| {
            if (std.mem.indexOf(u8, bytes, c.needle) != null) {
                try findings.append(aa, .{
                    .phase = phase,
                    .path = try std.fmt.allocPrint(aa, "{s}/{s}", .{ root, entry.path }),
                    .what = c.what,
                    .schema_name = isSchemaName(c.what, entry.basename),
                });
            }
        }
    }
}

fn report(title: []const u8, findings: []const Finding, files_scanned: usize) void {
    std.debug.print("\n[SONNY-6571] {s}: {d} file reads, {d} plaintext hit(s)\n", .{ title, files_scanned, findings.len });
    for (findings) |f| std.debug.print("[SONNY-6571]   {s:<8} {s:<7} {s}{s}\n", .{ f.phase, f.what, f.path, if (f.schema_name) "  (schema-name file)" else "" });
}

/// Hits outside the schema-name files (every value hit, and any name hit
/// elsewhere, e.g. the Raft log).
fn countOtherHits(findings: []const Finding) usize {
    var n: usize = 0;
    for (findings) |f| {
        if (!f.schema_name) n += 1;
    }
    return n;
}

const ScanResult = struct { findings: []const Finding, files_scanned: usize };

// ---------------------------------------------------------------------------
// Single node.
// ---------------------------------------------------------------------------

/// Start one server with TDE on, write a node pair and a relationship, read
/// it back, and scan the data directory running and after a clean stop.
fn singleNodeScan(gpa: std.mem.Allocator, aa: std.mem.Allocator, io: std.Io) !ScanResult {
    const certs = try makeCerts(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, certs.dir) catch {};
    const needles = try Needles.make(aa);
    const port = try test_ports.freeUdpPort();
    const data_dir = try std.fmt.allocPrint(aa, "{s}/data", .{certs.dir});
    try std.Io.Dir.cwd().createDirPath(io, data_dir);
    const listen = try std.fmt.allocPrint(aa, "{s}:{d}", .{ SINGLE_IP, port });

    const env = try aa.create(std.process.Environ.Map);
    env.* = std.process.Environ.Map.init(aa);
    try env.put("GEODE_TDE_KEY", needles.tde_key);
    try env.put("GEODE_ADMIN_PASSWORD", ADMIN_PW);
    var nodes = [_]Node{.{
        .child = try spawnServe(io, &.{ BINARY_PATH, "serve", "--listen", listen, "--data-dir", data_dir, "--cert", certs.leaf, "--key", certs.key }, env),
        .data_dir = data_dir,
    }};
    defer {
        stopNodes(&nodes, gpa, io);
        nodes[0].capture.buf.deinit(gpa);
    }

    // Ready when a query answers.
    const deadline = nowMillis() + STARTUP_DEADLINE_MS;
    while (true) {
        nodes[0].drain(gpa, io);
        const out = try runQuery(gpa, io, aa, certs.ca, SINGLE_IP, port, "RETURN 1 AS ready");
        defer gpa.free(out);
        if (std.mem.indexOf(u8, out, "ready") != null) break;
        if (nowMillis() > deadline) {
            std.debug.print("server never answered; log tail:\n{s}\n", .{nodes[0].tail()});
            return error.ServerStartupTimeout;
        }
        sleepMs(250);
    }

    const create_q = try std.fmt.allocPrint(aa, "CREATE (:{s} {{{s}: '{s}', n6571: {d}}})-[:{s} {{{s}: '{s}'}}]->(:{s})", .{ needles.label, needles.key, needles.value, needles.number, needles.rel_type, needles.key, needles.value, needles.label });
    gpa.free(try runQuery(gpa, io, aa, certs.ca, SINGLE_IP, port, create_q));
    const read_q = try std.fmt.allocPrint(aa, "MATCH (n:{s})-[r:{s}]->() RETURN r.{s} AS s", .{ needles.label, needles.rel_type, needles.key });
    const read_out = try runQuery(gpa, io, aa, certs.ca, SINGLE_IP, port, read_q);
    defer gpa.free(read_out);
    if (std.mem.indexOf(u8, read_out, needles.value) == null) {
        std.debug.print("write not visible: {s}\nlog tail:\n{s}\n", .{ read_out, nodes[0].tail() });
        return error.WriteNotVisible;
    }

    var findings: std.ArrayList(Finding) = .empty;
    var scanned: usize = 0;
    try scanTree(gpa, aa, io, data_dir, needles, "running", &findings, &scanned);
    stopNodes(&nodes, gpa, io);
    try scanTree(gpa, aa, io, data_dir, needles, "stopped", &findings, &scanned);
    report("single node, TDE on", findings.items, scanned);
    return .{ .findings = findings.items, .files_scanned = scanned };
}

test "single node: with TDE on, no written plaintext appears anywhere under the data directory" {
    if (builtin.os.tag != .linux or !binaryPresent()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const result = try singleNodeScan(gpa, arena.allocator(), threaded.io());
    try std.testing.expectEqual(@as(usize, 0), countOtherHits(result.findings));
}

test "single node schema names: with TDE on, no label, relationship type or property key name appears in plaintext in the storage engine's schema files" {
    if (builtin.os.tag != .linux or !binaryPresent()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const result = try singleNodeScan(gpa, arena.allocator(), threaded.io());
    try std.testing.expectEqual(@as(usize, 0), result.findings.len);
}

// ---------------------------------------------------------------------------
// Three-node cluster.
// ---------------------------------------------------------------------------

/// Last raft role node `id` logged ("node <id> state=<role> ...").
fn lastRole(buf: []const u8, id: usize) ?[]const u8 {
    var prefix_buf: [48]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "node {d} state=", .{id}) catch return null;
    var role: ?[]const u8 = null;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, buf, search, prefix)) |pos| {
        const after = pos + prefix.len;
        var e = after;
        while (e < buf.len and buf[e] != ' ' and buf[e] != '\n') e += 1;
        role = buf[after..e];
        search = after;
    }
    return role;
}

fn leaderIndex(nodes: []Node) ?usize {
    var idx: ?usize = null;
    for (nodes, 0..) |n, i| {
        if (lastRole(n.capture.buf.items, i + 1)) |r| {
            if (std.mem.eql(u8, r, "leader")) idx = i;
        }
    }
    return idx;
}

/// What every node of the test cluster is started with.
const ClusterSpec = struct {
    certs: Certs,
    needles: Needles,
    client_port: u16,
    peers: []const u8,
    cluster_port_str: []const u8,
    hmac: []const u8,
    token: []const u8,

    fn dataDir(self: ClusterSpec, aa: std.mem.Allocator, i: usize) ![]const u8 {
        return std.fmt.allocPrint(aa, "{s}/data{d}", .{ self.certs.dir, i + 1 });
    }
};

/// Spawn the three nodes on their data directories (created if missing) and
/// wait for a leader and a quorum; returns the leader's index.
fn startCluster(spec: ClusterSpec, gpa: std.mem.Allocator, aa: std.mem.Allocator, io: std.Io, nodes: *[3]Node, spawned: *usize) !usize {
    for (0..3) |i| {
        const ip = NODE_IPS[i];
        const data_dir = try spec.dataDir(aa, i);
        try std.Io.Dir.cwd().createDirPath(io, data_dir);
        const listen = try std.fmt.allocPrint(aa, "{s}:{d}", .{ ip, spec.client_port });
        const env = try aa.create(std.process.Environ.Map);
        env.* = std.process.Environ.Map.init(aa);
        try env.put("GEODE_TDE_KEY", spec.needles.tde_key);
        try env.put("GEODE_CLUSTER_TOKEN", spec.token);
        try env.put("GEODE_AUTH_HMAC_KEY", spec.hmac);
        try env.put("GEODE_NODE_ID", try std.fmt.allocPrint(aa, "{d}", .{i + 1}));
        try env.put("GEODE_PEERS", spec.peers);
        try env.put("GEODE_CLUSTER_PORT", spec.cluster_port_str);
        try env.put("GEODE_CLUSTER_LISTEN_ADDRESS", ip);
        try env.put("GEODE_CLUSTER_CA_CERT", spec.certs.ca);
        try env.put("GEODE_ADMIN_PASSWORD", ADMIN_PW);
        nodes[i] = .{
            .child = try spawnServe(io, &.{
                BINARY_PATH,      "serve",               "--listen",    listen,
                "--cluster-port", spec.cluster_port_str, "--peers",     spec.peers,
                "--data-dir",     data_dir,              "--cert",      spec.certs.leaf,
                "--key",          spec.certs.key,        "--log-level", "info",
            }, env),
            .data_dir = data_dir,
        };
        spawned.* += 1;
    }

    const deadline = nowMillis() + STARTUP_DEADLINE_MS;
    while (nowMillis() < deadline) : (sleepMs(250)) {
        var followers: usize = 0;
        var leaders: usize = 0;
        for (nodes, 0..) |*n, i| {
            n.drain(gpa, io);
            if (lastRole(n.capture.buf.items, i + 1)) |r| {
                if (std.mem.eql(u8, r, "leader")) leaders += 1;
                if (std.mem.eql(u8, r, "follower")) followers += 1;
            }
        }
        if (leaders == 1 and followers >= 1) return leaderIndex(nodes) orelse continue;
    }
    for (nodes, 0..) |*n, i| std.debug.print("\n--- node {d} log tail ---\n{s}\n", .{ i + 1, n.tail() });
    return error.NoLeaderElected;
}

/// Poll every node until `read_q` returns `want` on each.
fn expectOnEveryNode(spec: ClusterSpec, gpa: std.mem.Allocator, aa: std.mem.Allocator, io: std.Io, nodes: *[3]Node, read_q: []const u8, want: []const u8) !void {
    for (0..3) |i| {
        var seen = false;
        var poll: usize = 0;
        while (poll < 20 and !seen) : (poll += 1) {
            const out = try runQuery(gpa, io, aa, spec.certs.ca, NODE_IPS[i], spec.client_port, read_q);
            defer gpa.free(out);
            seen = std.mem.indexOf(u8, out, want) != null;
            if (!seen) sleepMs(500);
        }
        if (!seen) {
            std.debug.print("node {d} never answered '{s}' with '{s}'\n", .{ i + 1, read_q, want });
            for (nodes, 0..) |*n, j| {
                n.drain(gpa, io);
                std.debug.print("\n--- node {d} log tail ---\n{s}\n", .{ j + 1, n.tail() });
            }
            return error.WriteNotReplicated;
        }
    }
}

test "cluster: with TDE on, no replicated plaintext appears anywhere under any node's data directory" {
    if (builtin.os.tag != .linux or !binaryPresent()) return error.SkipZigTest;
    if (posixGetenv("GEODE_SKIP_SUBPROC_CLUSTER") != null) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const certs = try makeCerts(aa, io);
    defer std.Io.Dir.cwd().deleteTree(io, certs.dir) catch {};
    const client_port = try test_ports.freeUdpPort();
    const cluster_port = try test_ports.freeUdpPortExcept(&.{client_port});
    const spec = ClusterSpec{
        .certs = certs,
        .needles = try Needles.make(aa),
        .client_port = client_port,
        .peers = try std.fmt.allocPrint(aa, "{s}:{d},{s}:{d},{s}:{d}", .{ NODE_IPS[0], cluster_port, NODE_IPS[1], cluster_port, NODE_IPS[2], cluster_port }),
        .cluster_port_str = try std.fmt.allocPrint(aa, "{d}", .{cluster_port}),
        .hmac = try randomHex(aa, 32),
        .token = try randomHex(aa, 16),
    };
    const needles = spec.needles;

    var nodes: [3]Node = undefined;
    var spawned: usize = 0;
    defer {
        stopNodes(nodes[0..spawned], gpa, io);
        for (nodes[0..spawned]) |*n| n.capture.buf.deinit(gpa);
    }
    const li = try startCluster(spec, gpa, aa, io, &nodes, &spawned);

    const create_q = try std.fmt.allocPrint(aa, "CREATE (:{s} {{{s}: '{s}', n6571: {d}}})", .{ needles.label, needles.key, needles.value, needles.number });
    gpa.free(try runQuery(gpa, io, aa, certs.ca, NODE_IPS[li], client_port, create_q));
    const read_q = try std.fmt.allocPrint(aa, "MATCH (n:{s}) RETURN n.{s} AS s", .{ needles.label, needles.key });
    try expectOnEveryNode(spec, gpa, aa, io, &nodes, read_q, needles.value);

    var findings: std.ArrayList(Finding) = .empty;
    var scanned: usize = 0;
    for (&nodes) |*n| try scanTree(gpa, aa, io, n.data_dir, needles, "running", &findings, &scanned);
    stopNodes(&nodes, gpa, io);
    for (&nodes) |*n| try scanTree(gpa, aa, io, n.data_dir, needles, "stopped", &findings, &scanned);

    // Restart every node on its encrypted Raft directory: the cluster elects
    // a leader from the persisted (sealed) logs, keeps the data and
    // replicates a second write, which the leader appends to and reads from
    // the sealed log.
    for (nodes[0..spawned]) |*n| n.capture.buf.deinit(gpa);
    spawned = 0;
    const li2 = try startCluster(spec, gpa, aa, io, &nodes, &spawned);
    try expectOnEveryNode(spec, gpa, aa, io, &nodes, read_q, needles.value);
    const second = try std.fmt.allocPrint(aa, "{s}-after-restart", .{needles.value});
    const create2_q = try std.fmt.allocPrint(aa, "CREATE (:{s} {{{s}: '{s}'}})", .{ needles.label, needles.key, second });
    gpa.free(try runQuery(gpa, io, aa, certs.ca, NODE_IPS[li2], client_port, create2_q));
    try expectOnEveryNode(spec, gpa, aa, io, &nodes, read_q, second);
    for (&nodes, 0..) |*n, i| {
        n.drain(gpa, io);
        for ([_][]const u8{ "RaftStorageAuthenticationFailed", "RaftStorageCorrupt", "RaftStorageTdeKeyMismatch" }) |bad| {
            if (std.mem.indexOf(u8, n.capture.buf.items, bad) != null) {
                std.debug.print("node {d} logged {s}:\n{s}\n", .{ i + 1, bad, n.tail() });
                return error.RaftStorageError;
            }
        }
    }
    stopNodes(&nodes, gpa, io);
    for (&nodes) |*n| try scanTree(gpa, aa, io, n.data_dir, needles, "restart", &findings, &scanned);

    report("3-node cluster, TDE on", findings.items, scanned);
    try std.testing.expectEqual(@as(usize, 0), countOtherHits(findings.items));
}
