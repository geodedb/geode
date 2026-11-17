// CANARY: REQ=REQ-SONNY-6322-AUDIT-SEED-HMAC-STARTUP; FEATURE="Backup Restore"; ASPECT=AuditSeedEpochsAndHmacStartup; STATUS=TESTED; TEST=tests/test_sonny6322_audit_seed_and_hmac_startup.zig; OWNER=security; UPDATED=2026-11-11
//
// SONNY-6322:
//   (1) a backup archived `<graph>/audit.jsonl.key`, the Ed25519 seed that
//       signs the audit log, so whoever read a backup could forge audit
//       entries. Excluding it needs continuity: when the seed was missing the
//       logger generated a new pair and TRUNCATED `audit.jsonl.pub`, so the
//       restored (older) entries no longer verified with any kept key;
//   (2) server startup on a directory with __geode_security records and no
//       HMAC key generated a new random `.geode_hmac_key`, failed
//       verifyChain (AuthChainTampered) and left the junk key behind;
//   (3) a server restore did not verify the restored auth chain, so a backup
//       sealed under another key "restored" and failed at the next startup.
//
// The contract:
//   - a backup holds the audit log and its public key(s), never the seed;
//   - a store with an audit log and public key but no seed starts a new key
//     epoch: a new pair, the new public key in `audit.jsonl.pub.<n>`, the old
//     public key file kept byte for byte, and a KEY_EPOCH record (signed by
//     the new key) in the log; `geode audit verify` checks each epoch's
//     digests with that epoch's key (`--pubkey` once per epoch, in order) and
//     rejects a record signed by any other key;
//   - startup with auth records and no key refuses ("HMAC key required"),
//     writes no key, and starts once the key is supplied; a first boot still
//     creates the key;
//   - a server restore verifies the staged copy's auth chain and fails,
//     leaving nothing behind, when it does not verify;
//   - an older archive that holds the seed still restores, with a warning
//     naming it, the file 0600.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const backup = @import("storage/backup");
const audit = geode.security.audit;
const verify = @import("audit_verify");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");
const test_ports = @import("test_ports.zig");
const util = @import("proto_test_util.zig");

const linux = std.os.linux;
const posix = std.posix;
const geode_binary = geode_test_bin.geode_exe;
const admin_pw = util.DefaultAuth.password;
const seed_name = "audit.jsonl.key";

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn join(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ a, b });
}

fn sleepMs(ms: u64) void {
    fsIo().sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

fn pathExists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(fsIo(), path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(fsIo(), path, allocator, .limited(64 << 20));
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(fsIo(), path, .{});
    defer f.close(fsIo());
    try f.writeStreamingAll(fsIo(), bytes);
}

fn mode(path: []const u8) !u32 {
    const st = try std.Io.Dir.cwd().statFile(fsIo(), path, .{ .follow_symlinks = false });
    return @intCast(st.permissions.toMode() & 0o777);
}

fn listNames(allocator: std.mem.Allocator, dir_path: []const u8) ![][]u8 {
    var dir = try std.Io.Dir.cwd().openDir(fsIo(), dir_path, .{ .iterate = true });
    defer dir.close(fsIo());
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var it = dir.iterate();
    while (try it.next(fsIo())) |entry| try names.append(allocator, try allocator.dupe(u8, entry.name));
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return names.toOwnedSlice(allocator);
}

fn freeNames(allocator: std.mem.Allocator, names: [][]u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}

/// The graph directory under `data_dir` that holds an `audit.jsonl` (the
/// __geode_security graph's). Caller frees.
fn auditGraphDir(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    const names = try listNames(allocator, data_dir);
    defer freeNames(allocator, names);
    for (names) |n| {
        const d = try join(allocator, data_dir, n);
        const log_path = try join(allocator, d, "audit.jsonl");
        defer allocator.free(log_path);
        if (pathExists(log_path)) return d;
        allocator.free(d);
    }
    std.debug.print("SONNY-6322: no graph directory with audit.jsonl under {s}\n", .{data_dir});
    return error.NoAuditLog;
}

/// The archive entry names of the backup at `path`.
fn archiveNames(allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
    var decoded = try backup.readBackupFile(allocator, path, null);
    defer decoded.deinit(allocator);
    const archive = decoded.archive;
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |n| allocator.free(n);
        out.deinit(allocator);
    }
    var count = std.mem.readInt(u32, archive[12..16], .little);
    var off: usize = 16;
    while (count > 0) : (count -= 1) {
        const nl = std.mem.readInt(u32, archive[off..][0..4], .little);
        off += 4;
        try out.append(allocator, try allocator.dupe(u8, archive[off .. off + nl]));
        off += nl;
        const dl: usize = @intCast(std.mem.readInt(u64, archive[off..][0..8], .little));
        off += 8 + dl;
    }
    return out.toOwnedSlice(allocator);
}

/// The newest `full_*.backup` in `dir`. Caller frees.
fn newestBackup(allocator: std.mem.Allocator, dir: []const u8) ![]u8 {
    const names = try listNames(allocator, dir);
    defer freeNames(allocator, names);
    var best: ?[]const u8 = null;
    for (names) |n| {
        if (std.mem.startsWith(u8, n, "full_") and std.mem.endsWith(u8, n, ".backup")) best = n;
    }
    return join(allocator, dir, best orelse return error.NoBackup);
}

const Run = struct {
    code: ?u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }

    fn output(self: Run, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.stdout, needle) != null or
            std.mem.indexOf(u8, self.stderr, needle) != null;
    }

    fn dump(self: Run, what: []const u8) void {
        std.debug.print("SONNY-6322 {s}: exit={?d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ what, self.code, self.stdout, self.stderr });
    }
};

fn runGeode(argv: []const []const u8, env_kv: []const [2][]const u8, cwd: []const u8, timeout_s: i64) !Run {
    // A hard deadline: a server that keeps logging would keep std.process.run's
    // per-read timeout from ever firing. Output goes to a scratch file.
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    for (env_kv) |kv| try env.put(kv[0], kv[1]);
    var rnd: [8]u8 = undefined;
    _ = linux.getrandom(&rnd, rnd.len, 0);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const out_path = try std.fmt.bufPrint(&name_buf, "{s}/run-{x}.out", .{ try test_scratch.processRoot(), std.mem.readInt(u64, &rnd, .little) });
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .exclusive = true });
    defer {
        out.close(fsIo());
        std.Io.Dir.cwd().deleteFile(fsIo(), out_path) catch {};
    }
    const child = try std.process.spawn(threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .{ .file = out },
        .stderr = .{ .file = out },
    });
    const pid = child.id.?;
    var status: u32 = 0;
    var exited = false;
    var waited_ms: i64 = 0;
    while (true) {
        const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
        if (rc == @as(usize, @intCast(pid))) {
            exited = true;
            break;
        }
        if (waited_ms >= timeout_s * 1000) {
            posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            break;
        }
        sleepMs(100);
        waited_ms += 100;
    }
    const code: ?u8 = if (exited and (status & 0x7f) == 0) @intCast((status >> 8) & 0xff) else null;
    const text = try std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, testing.allocator, .limited(8 << 20));
    errdefer testing.allocator.free(text);
    const note = try testing.allocator.dupe(u8, if (exited) "" else "(killed: still running at the timeout)");
    return .{ .code = code, .stdout = text, .stderr = note };
}

const Server = struct {
    threaded: std.Io.Threaded,
    env: std.process.Environ.Map,
    child: std.process.Child,
    addr: []u8,

    fn start(allocator: std.mem.Allocator, cwd: []const u8, data_dir: []const u8, env_kv: []const [2][]const u8) !Server {
        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        var parts_owned = true;
        errdefer if (parts_owned) threaded.deinit();
        var env = std.process.Environ.Map.init(allocator);
        errdefer if (parts_owned) env.deinit();
        inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
            if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
        }
        try env.put("GEODE_ADMIN_PASSWORD", admin_pw);
        for (env_kv) |kv| try env.put(kv[0], kv[1]);
        const addr = try util.formatAddr(allocator, try test_ports.freeUdpPort());
        // `addr` is the caller's until `server` exists; from then on `server.stop`
        // (the errdefer below) frees it. An errdefer on both freed it twice when
        // the server never became ready (SONNY-6708 triage).
        var addr_owned = true;
        errdefer if (addr_owned) allocator.free(addr);
        const inherit = std.c.getenv("GEODE_TEST_INHERIT_SERVER_STDERR") != null;
        const child = try std.process.spawn(threaded.io(), .{
            .argv = &.{ geode_binary, "serve", "--listen", addr, "--data-dir", data_dir },
            .environ_map = &env,
            .cwd = .{ .path = cwd },
            .stdin = .ignore,
            .stdout = if (inherit) .inherit else .ignore,
            .stderr = if (inherit) .inherit else .ignore,
        });
        var server: Server = .{ .threaded = threaded, .env = env, .child = child, .addr = addr };
        addr_owned = false;
        parts_owned = false;
        errdefer server.stop(allocator);
        try util.waitForServerReady(allocator, addr, 60_000);
        return server;
    }

    fn stop(self: *Server, allocator: std.mem.Allocator) void {
        if (self.child.id) |pid| {
            posix.kill(pid, .TERM) catch {};
            var waited: u32 = 0;
            while (util.processAlive(pid) and waited < 30_000) : (waited += 100) sleepMs(100);
            if (util.processAlive(pid)) posix.kill(pid, .KILL) catch {};
            _ = self.child.wait(self.threaded.io()) catch {};
        }
        self.threaded.deinit();
        self.env.deinit();
        allocator.free(self.addr);
    }

    fn connect(self: *Server, allocator: std.mem.Allocator) !util.QuicProtoClient {
        var client = try util.QuicProtoClient.connect(allocator, self.addr);
        errdefer client.deinit();
        var h = try client.hello(allocator, util.DefaultAuth.username, admin_pw);
        defer h.deinit(allocator);
        if (!h.success) {
            std.debug.print("SONNY-6322: HELLO failed: {s}\n", .{h.error_message});
            return error.HelloFailed;
        }
        return client;
    }
};

fn exec(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !void {
    // A Debug server hashing a password (Argon2id) on a loaded machine needs more than
    // the 5 s default no-progress timeout; this is a client wait, not an assertion.
    var r = try client.executeAndCollectWait(allocator, query, util.emptyParams(), 1000, 90, .{ .while_server_alive_ms = 90_000 }, null);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("SONNY-6322: {s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
}

const QuicRestore = struct {
    success: bool,
    message: []u8,
    restore_dir: []u8,

    fn deinit(self: *QuicRestore, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        allocator.free(self.restore_dir);
    }
};

fn quicRestore(client: *util.QuicProtoClient, allocator: std.mem.Allocator) !QuicRestore {
    try client.writeMessage(.{ .restore = .{ .target_time = "", .confirm = true } });
    var packet = try client.readPacket(allocator, 120_000);
    defer packet.deinit(allocator);
    const msg = packet.quic orelse return error.InvalidMessage;
    if (msg != .restore) return error.InvalidMessage;
    const message = try allocator.dupe(u8, msg.restore.message);
    errdefer allocator.free(message);
    return .{ .success = msg.restore.success, .message = message, .restore_dir = try allocator.dupe(u8, msg.restore.restore_dir) };
}

/// A scratch root: working directory and a data directory X served once
/// (first boot, admin password from the environment) with two auth users,
/// one :P node and one server backup.
const Fixture = struct {
    root: test_scratch.ScratchDir,
    cwd: []u8,
    x: []u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !Fixture {
        var root = try test_scratch.ScratchDir.create(tag);
        errdefer root.remove();
        const cwd = try join(allocator, root.path(), "cwd");
        errdefer allocator.free(cwd);
        const x = try join(allocator, root.path(), "X");
        errdefer allocator.free(x);
        try std.Io.Dir.cwd().createDirPath(fsIo(), cwd);
        return .{ .root = root, .cwd = cwd, .x = x };
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.cwd);
        allocator.free(self.x);
        self.root.remove();
    }

    fn path(self: *Fixture, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        return join(allocator, self.root.path(), name);
    }

    fn seed(self: *Fixture, allocator: std.mem.Allocator, server: *Server) !void {
        _ = self;
        var admin = try server.connect(allocator);
        defer admin.deinit();
        try exec(&admin, allocator, "CREATE USER sonny6322a SET PASSWORD 'Sonny 6322 First Passphrase 1'");
        try exec(&admin, allocator, "INSERT (:P {n: 1})");
        var b = try admin.backup(allocator, "full", false);
        defer b.deinit(allocator);
        if (!b.success) std.debug.print("SONNY-6322: backup failed: {s}\n", .{b.message});
        try testing.expect(b.success);
    }
};

fn pubHex(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try readFileAlloc(allocator, path);
    defer allocator.free(raw);
    return allocator.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
}

// ===========================================================================
// (1) the audit seed is not in a backup; a restore starts a new key epoch
// ===========================================================================

test "SONNY-6322 (1) a server backup holds the audit log and public key but not the audit signing seed; a restored store starts a new key epoch that verifies across the boundary" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, "sonny6322-seed");
    defer fx.deinit(allocator);

    var restore_dir: []u8 = &.{};
    defer allocator.free(restore_dir);
    var old_pub: []u8 = &.{};
    defer allocator.free(old_pub);
    var old_pub_bytes: []u8 = &.{};
    defer allocator.free(old_pub_bytes);
    {
        var server = try Server.start(allocator, fx.cwd, fx.x, &.{});
        defer server.stop(allocator);
        // A first boot creates the HMAC key.
        const hk = try join(allocator, fx.x, ".geode_hmac_key");
        defer allocator.free(hk);
        try testing.expect(pathExists(hk));
        try fx.seed(allocator, &server);

        const gdir = try auditGraphDir(allocator, fx.x);
        defer allocator.free(gdir);
        const pub_path = try join(allocator, gdir, "audit.jsonl.pub");
        defer allocator.free(pub_path);
        old_pub_bytes = try readFileAlloc(allocator, pub_path);
        old_pub = try pubHex(allocator, pub_path);

        const bdir = try join(allocator, fx.x, "backups");
        defer allocator.free(bdir);
        const bfile = try newestBackup(allocator, bdir);
        defer allocator.free(bfile);
        const names = try archiveNames(allocator, bfile);
        defer freeNames(allocator, names);
        var has_log = false;
        var has_pub = false;
        var has_seed = false;
        for (names) |n| {
            const base = std.fs.path.basename(n);
            if (std.mem.eql(u8, base, "audit.jsonl")) has_log = true;
            if (std.mem.eql(u8, base, "audit.jsonl.pub")) has_pub = true;
            if (std.mem.eql(u8, base, seed_name)) {
                std.debug.print("SONNY-6322: the backup holds the audit signing seed {s}\n", .{n});
                has_seed = true;
            }
        }
        try testing.expect(has_log);
        try testing.expect(has_pub);
        try testing.expect(!has_seed);

        var admin = try server.connect(allocator);
        defer admin.deinit();
        var r = try quicRestore(&admin, allocator);
        defer r.deinit(allocator);
        if (!r.success) std.debug.print("SONNY-6322: restore failed: {s}\n", .{r.message});
        try testing.expect(r.success);
        restore_dir = try allocator.dupe(u8, r.restore_dir);
    }

    // A server on the restored directory, one more audited auth change.
    {
        var server = try Server.start(allocator, fx.cwd, restore_dir, &.{});
        defer server.stop(allocator);
        var admin = try server.connect(allocator);
        defer admin.deinit();
        try exec(&admin, allocator, "CREATE USER sonny6322b SET PASSWORD 'Sonny 6322 Second Passphrase 2'");
    }

    const gdir = try auditGraphDir(allocator, restore_dir);
    defer allocator.free(gdir);
    const pub0_path = try join(allocator, gdir, "audit.jsonl.pub");
    defer allocator.free(pub0_path);
    const pub1_path = try join(allocator, gdir, "audit.jsonl.pub.1");
    defer allocator.free(pub1_path);
    const seed_path = try join(allocator, gdir, seed_name);
    defer allocator.free(seed_path);
    const log_path = try join(allocator, gdir, "audit.jsonl");
    defer allocator.free(log_path);

    // The old public key is intact byte for byte; the new epoch has its own.
    const now_pub0 = try readFileAlloc(allocator, pub0_path);
    defer allocator.free(now_pub0);
    try testing.expectEqualSlices(u8, old_pub_bytes, now_pub0);
    if (!pathExists(pub1_path)) {
        std.debug.print("SONNY-6322: no new key epoch (audit.jsonl.pub.1) after a restore without the seed\n", .{});
        return error.TestUnexpectedResult;
    }
    try testing.expect(pathExists(seed_path));
    try testing.expectEqual(@as(u32, 0o600), try mode(seed_path));
    const new_pub = try pubHex(allocator, pub1_path);
    defer allocator.free(new_pub);
    try testing.expect(!std.mem.eql(u8, old_pub, new_pub));

    // geode audit verify: both epochs' keys, in order, verify.
    const v = try runGeode(&.{ geode_binary, "audit", "verify", "--file", log_path, "--pubkey", old_pub, "--pubkey", new_pub }, &.{}, fx.cwd, 120);
    defer v.deinit();
    if (v.code != @as(?u8, 0) or !v.output("KEY_EPOCH")) v.dump("audit verify (both keys)");
    try testing.expectEqual(@as(?u8, 0), v.code);
    try testing.expect(v.output("KEY_EPOCH"));
    try testing.expect(v.output("signatures_failed=0"));

    // A made-up key for the new epoch is rejected.
    var bogus: [32]u8 = undefined;
    _ = linux.getrandom(&bogus, bogus.len, 0);
    const bogus_hex = std.fmt.bytesToHex(bogus, .lower);
    const w = try runGeode(&.{ geode_binary, "audit", "verify", "--file", log_path, "--pubkey", old_pub, "--pubkey", &bogus_hex }, &.{}, fx.cwd, 120);
    defer w.deinit();
    if (w.code == @as(?u8, 0)) w.dump("audit verify (made-up epoch key)");
    try testing.expect(w.code != @as(?u8, 0));
}

// ===========================================================================
// (1) the epoch rule and the verifier, on the real writer
// ===========================================================================

const AuditLogger = audit.AuditLogger;
const AuditEvent = audit.AuditEvent;

fn appendEvents(logger: *AuditLogger, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var ev = AuditEvent{
            .timestamp = 1000 + @as(i64, @intCast(i)),
            .event_type = .data_access,
            .severity = .info,
            .user_id = 1,
            .resource = .{ .type = "node", .id = "1", .name = "n", .graph = null, .table = null },
            .action = "read",
            .result = .success,
            .session_id = null,
            .details = null,
        };
        try logger.appendAuditEvent(&ev);
    }
}

fn hexToKey(hex: []const u8) ![32]u8 {
    var out: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, hex);
    return out;
}

/// The last line's event_hash and seq_no of the log at `path`.
fn lastHashAndSeq(allocator: std.mem.Allocator, path: []const u8) !struct { hash: [32]u8, seq: u64 } {
    const raw = try readFileAlloc(allocator, path);
    defer allocator.free(raw);
    var it = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, raw, "\n"), '\n');
    const line = it.next() orelse return error.EmptyLog;
    const eh = "\"event_hash\":\"";
    const i = std.mem.indexOf(u8, line, eh) orelse return error.NoHash;
    const sq = "\"seq_no\":";
    const j = std.mem.indexOf(u8, line, sq) orelse return error.NoSeq;
    var k = j + sq.len;
    while (k < line.len and std.ascii.isDigit(line[k])) k += 1;
    return .{ .hash = try hexToKey(line[i + eh.len ..][0..64]), .seq = try std.fmt.parseInt(u64, line[j + sq.len .. k], 10) };
}

fn appendLine(path: []const u8, line: []const u8) !void {
    const f = try std.Io.Dir.cwd().openFile(fsIo(), path, .{ .mode = .read_write });
    defer f.close(fsIo());
    const size = (try f.stat(fsIo())).size;
    try f.writePositionalAll(fsIo(), line, size);
}

test "SONNY-6322 (1) a missing audit seed starts a new key epoch without touching the old public key; each epoch verifies only with its own key; forged records are rejected" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (comptime !@hasDecl(verify, "verifyFileEpochs")) {
        std.debug.print("SONNY-6322: the audit verifier has no key epochs (verifyFileEpochs), and a missing seed truncates audit.jsonl.pub (src/security/audit.zig loadOrCreateFileBackedKeys)\n", .{});
        // Show the truncation on the real writer before failing.
        try epochWriterOnly();
        return error.TestUnexpectedResult;
    } else try epochCase();
}

/// Writer half of the epoch case: the old public key must survive.
fn epochWriterOnly() !void {
    const allocator = testing.allocator;
    var dir = try test_scratch.ScratchDir.create("sonny6322-epoch-red");
    defer dir.remove();
    const log_path = try join(allocator, dir.path(), "audit.jsonl");
    defer allocator.free(log_path);
    const pub_path = try join(allocator, dir.path(), "audit.jsonl.pub");
    defer allocator.free(pub_path);
    const seed_path = try join(allocator, dir.path(), seed_name);
    defer allocator.free(seed_path);
    {
        var logger = try AuditLogger.init(allocator, .{ .enabled = true, .file_path = log_path, .digest_interval = 3 });
        defer logger.deinit();
        try appendEvents(&logger, 4);
    }
    const before = try readFileAlloc(allocator, pub_path);
    defer allocator.free(before);
    try std.Io.Dir.cwd().deleteFile(fsIo(), seed_path);
    {
        var logger = try AuditLogger.init(allocator, .{ .enabled = true, .file_path = log_path, .digest_interval = 3 });
        defer logger.deinit();
    }
    const after = try readFileAlloc(allocator, pub_path);
    defer allocator.free(after);
    if (!std.mem.eql(u8, before, after)) std.debug.print("SONNY-6322: audit.jsonl.pub was overwritten when the seed was missing\n", .{});
}

fn epochCase() !void {
    const allocator = testing.allocator;
    var dir = try test_scratch.ScratchDir.create("sonny6322-epoch");
    defer dir.remove();
    const log_path = try join(allocator, dir.path(), "audit.jsonl");
    defer allocator.free(log_path);
    const pub0_path = try join(allocator, dir.path(), "audit.jsonl.pub");
    defer allocator.free(pub0_path);
    const pub1_path = try join(allocator, dir.path(), "audit.jsonl.pub.1");
    defer allocator.free(pub1_path);
    const pub2_path = try join(allocator, dir.path(), "audit.jsonl.pub.2");
    defer allocator.free(pub2_path);
    const seed_path = try join(allocator, dir.path(), seed_name);
    defer allocator.free(seed_path);

    // Epoch 0: two signed digests.
    {
        var logger = try AuditLogger.init(allocator, .{ .enabled = true, .file_path = log_path, .digest_interval = 3 });
        defer logger.deinit();
        try appendEvents(&logger, 7);
    }
    try testing.expectEqual(@as(u32, 0o600), try mode(seed_path));
    const pub0_bytes = try readFileAlloc(allocator, pub0_path);
    defer allocator.free(pub0_bytes);
    const k0 = try hexToKey(std.mem.trim(u8, pub0_bytes, " \r\n"));

    // The seed is gone (a restore): a new epoch, the old key file untouched.
    try std.Io.Dir.cwd().deleteFile(fsIo(), seed_path);
    {
        var logger = try AuditLogger.init(allocator, .{ .enabled = true, .file_path = log_path, .digest_interval = 3 });
        defer logger.deinit();
        try appendEvents(&logger, 7);
    }
    const pub0_after = try readFileAlloc(allocator, pub0_path);
    defer allocator.free(pub0_after);
    try testing.expectEqualSlices(u8, pub0_bytes, pub0_after);
    try testing.expect(pathExists(pub1_path));
    try testing.expectEqual(@as(u32, 0o600), try mode(seed_path));
    const pub1_bytes = try readFileAlloc(allocator, pub1_path);
    defer allocator.free(pub1_bytes);
    const k1 = try hexToKey(std.mem.trim(u8, pub1_bytes, " \r\n"));
    try testing.expect(!std.mem.eql(u8, &k0, &k1));

    // With the seed present, a restart stays in the same epoch.
    {
        var logger = try AuditLogger.init(allocator, .{ .enabled = true, .file_path = log_path, .digest_interval = 3 });
        defer logger.deinit();
        try appendEvents(&logger, 1);
    }
    try testing.expect(!pathExists(pub2_path));

    // Both epochs, in order: every signature verifies.
    const ok = try verify.verifyFileEpochs(allocator, log_path, .sha256, 0, false, &.{ k0, k1 }, false);
    try testing.expectEqual(@as(u32, 1), ok.epochs);
    try testing.expect(ok.signatures_verified >= 5); // 2 + 1 KEY_EPOCH + 2
    try testing.expectEqual(@as(u32, 0), ok.signatures_failed);

    // Keys out of order, or a made-up key for epoch 1: rejected.
    try testing.expect(std.meta.isError(verify.verifyFileEpochs(allocator, log_path, .sha256, 0, false, &.{ k1, k0 }, false)));
    var bogus: [32]u8 = undefined;
    _ = linux.getrandom(&bogus, bogus.len, 0);
    try testing.expect(std.meta.isError(verify.verifyFileEpochs(allocator, log_path, .sha256, 0, false, &.{ k0, bogus }, false)));
    // Only the first epoch's key: the second epoch is unverifiable, refused.
    try testing.expect(std.meta.isError(verify.verifyFileEpochs(allocator, log_path, .sha256, 0, false, &.{k0}, false)));

    // A forged DIGEST signed by a made-up key, correctly chained: rejected.
    {
        const forged_path = try join(allocator, dir.path(), "forged-digest.jsonl");
        defer allocator.free(forged_path);
        const raw = try readFileAlloc(allocator, log_path);
        defer allocator.free(raw);
        try writeFile(forged_path, raw);
        const last = try lastHashAndSeq(allocator, forged_path);
        var prev: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&last.hash, &prev, .{});
        var ev_hash: [32]u8 = undefined;
        _ = linux.getrandom(&ev_hash, ev_hash.len, 0);
        var seed: [32]u8 = undefined;
        _ = linux.getrandom(&seed, seed.len, 0);
        const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
        const sig = try kp.sign(&ev_hash, null);
        const line = try std.fmt.allocPrint(allocator, "{{\"stream\":\"geode\",\"seq_no\":{d},\"timestamp\":1,\"event_type\":\"DIGEST\",\"details\":{{}},\"prev_hash\":\"{s}\",\"event_hash\":\"{s}\",\"signature\":\"{s}\"}}\n", .{
            last.seq + 1,
            std.fmt.bytesToHex(prev, .lower),
            std.fmt.bytesToHex(ev_hash, .lower),
            std.fmt.bytesToHex(sig.toBytes(), .lower),
        });
        defer allocator.free(line);
        try appendLine(forged_path, line);
        try testing.expect(std.meta.isError(verify.verifyFileEpochs(allocator, forged_path, .sha256, 0, false, &.{ k0, k1 }, false)));
    }

    // A forged KEY_EPOCH that installs a made-up key: rejected against the
    // trusted keys.
    {
        const forged_path = try join(allocator, dir.path(), "forged-epoch.jsonl");
        defer allocator.free(forged_path);
        const raw = try readFileAlloc(allocator, log_path);
        defer allocator.free(raw);
        try writeFile(forged_path, raw);
        const last = try lastHashAndSeq(allocator, forged_path);
        var prev: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&last.hash, &prev, .{});
        var seed: [32]u8 = undefined;
        _ = linux.getrandom(&seed, seed.len, 0);
        const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
        const pk_hex = std.fmt.bytesToHex(kp.public_key.toBytes(), .lower);
        const id = try std.fmt.allocPrint(allocator, "epoch-2:{s}", .{pk_hex});
        defer allocator.free(id);
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(&prev);
        h.update("system_event");
        h.update(id);
        h.update("KEY_EPOCH");
        var ev_hash: [32]u8 = undefined;
        h.final(&ev_hash);
        const sig = try kp.sign(&ev_hash, null);
        const line = try std.fmt.allocPrint(allocator, "{{\"stream\":\"geode\",\"seq_no\":{d},\"timestamp\":1,\"event_type\":\"system_event\",\"resource\":{{\"type\":\"audit_key_epoch\",\"id\":\"{s}\"}},\"action\":\"KEY_EPOCH\",\"result\":\"success\",\"details\":{{}},\"prev_hash\":\"{s}\",\"event_hash\":\"{s}\",\"signature\":\"{s}\"}}\n", .{
            last.seq + 1,
            id,
            std.fmt.bytesToHex(prev, .lower),
            std.fmt.bytesToHex(ev_hash, .lower),
            std.fmt.bytesToHex(sig.toBytes(), .lower),
        });
        defer allocator.free(line);
        try appendLine(forged_path, line);
        try testing.expect(std.meta.isError(verify.verifyFileEpochs(allocator, forged_path, .sha256, 0, false, &.{ k0, k1 }, false)));
    }
}

// ===========================================================================
// (2) startup never invents an HMAC key over existing auth records
// ===========================================================================

test "SONNY-6322 (2) startup with auth records and no HMAC key refuses with 'HMAC key required' and writes no key; the right key then starts it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, "sonny6322-hmac");
    defer fx.deinit(allocator);
    {
        var server = try Server.start(allocator, fx.cwd, fx.x, &.{});
        defer server.stop(allocator);
        var admin = try server.connect(allocator);
        defer admin.deinit();
        try exec(&admin, allocator, "CREATE USER sonny6322c SET PASSWORD 'Sonny 6322 Third Passphrase 3'");
    }
    const hk = try join(allocator, fx.x, ".geode_hmac_key");
    defer allocator.free(hk);
    const raw = try readFileAlloc(allocator, hk);
    defer {
        std.crypto.secureZero(u8, raw);
        allocator.free(raw);
    }
    var key_hex_buf: [64]u8 = undefined;
    defer std.crypto.secureZero(u8, &key_hex_buf);
    const key_hex: []const u8 = if (raw.len == 32) blk: {
        key_hex_buf = std.fmt.bytesToHex(raw[0..32].*, .lower);
        break :blk &key_hex_buf;
    } else std.mem.trim(u8, raw, " \r\n");
    try testing.expectEqual(@as(usize, 64), key_hex.len);
    // Keep the key outside the data directory (a copy without its key).
    const saved = try fx.path(allocator, "saved_hmac_key");
    defer allocator.free(saved);
    try std.Io.Dir.cwd().rename(hk, std.Io.Dir.cwd(), saved, fsIo());

    const before = try listNames(allocator, fx.x);
    defer freeNames(allocator, before);
    const addr = try util.formatAddr(allocator, try test_ports.freeUdpPort());
    defer allocator.free(addr);
    const r = try runGeode(&.{ geode_binary, "serve", "--listen", addr, "--data-dir", fx.x }, &.{.{ "GEODE_ADMIN_PASSWORD", admin_pw }}, fx.cwd, 90);
    defer r.deinit();
    if (r.code == null or r.code.? == 0 or !r.output("HMAC key required")) r.dump("startup without the HMAC key");
    try testing.expect(r.code != null and r.code.? != 0);
    try testing.expect(r.output("HMAC key required"));
    try testing.expect(r.output("GEODE_AUTH_HMAC_KEY"));
    try testing.expect(r.output(".geode_hmac_key"));
    // No key bytes in the output.
    try testing.expect(!r.output(key_hex));
    if (pathExists(hk)) {
        std.debug.print("SONNY-6322: startup wrote a new .geode_hmac_key over existing auth records\n", .{});
        try testing.expect(false);
    }
    const after = try listNames(allocator, fx.x);
    defer freeNames(allocator, after);
    try testing.expectEqual(before.len, after.len);
    for (before, after) |a, b| try testing.expectEqualStrings(a, b);

    // With the right key in the environment the server starts.
    {
        var server = try Server.start(allocator, fx.cwd, fx.x, &.{.{ "GEODE_AUTH_HMAC_KEY", key_hex }});
        defer server.stop(allocator);
        var admin = try server.connect(allocator);
        defer admin.deinit();
        try exec(&admin, allocator, "MATCH (n) RETURN count(n) AS c");
    }
    try testing.expect(!pathExists(hk));
}

// ===========================================================================
// (3) a server restore verifies the staged copy's auth chain
// ===========================================================================

test "SONNY-6322 (3) a server restore of a backup sealed under another HMAC key fails and leaves nothing behind" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, "sonny6322-foreign");
    defer fx.deinit(allocator);
    // Server A: auth records sealed under A's key, one backup.
    {
        var server = try Server.start(allocator, fx.cwd, fx.x, &.{});
        defer server.stop(allocator);
        try fx.seed(allocator, &server);
    }
    // Server B: its own first boot, its own key; A's backups in its backup dir.
    const xb = try fx.path(allocator, "XB");
    defer allocator.free(xb);
    var server = try Server.start(allocator, fx.cwd, xb, &.{});
    defer server.stop(allocator);
    {
        const a_dir = try join(allocator, fx.x, "backups");
        defer allocator.free(a_dir);
        const b_dir = try join(allocator, xb, "backups");
        defer allocator.free(b_dir);
        try std.Io.Dir.cwd().createDirPath(fsIo(), b_dir);
        const names = try listNames(allocator, a_dir);
        defer freeNames(allocator, names);
        for (names) |n| {
            const src = try join(allocator, a_dir, n);
            defer allocator.free(src);
            const dst = try join(allocator, b_dir, n);
            defer allocator.free(dst);
            const bytes = try readFileAlloc(allocator, src);
            defer allocator.free(bytes);
            try writeFile(dst, bytes);
        }
    }
    const parent = fx.root.path();
    const before = try listNames(allocator, parent);
    defer freeNames(allocator, before);

    var admin = try server.connect(allocator);
    defer admin.deinit();
    var r = try quicRestore(&admin, allocator);
    defer r.deinit(allocator);
    if (r.success) {
        std.debug.print("SONNY-6322: a backup sealed under another HMAC key restored ({s}); the server would fail AuthChainTampered on it\n", .{r.restore_dir});
        try testing.expect(false);
    }
    // Nothing left beside B's data directory (no restored or staging dir).
    const after = try listNames(allocator, parent);
    defer freeNames(allocator, after);
    try testing.expectEqual(before.len, after.len);
    // B is still serving.
    try exec(&admin, allocator, "MATCH (n) RETURN count(n) AS c");
}

// ===========================================================================
// (1) an older archive that holds the seed still restores
// ===========================================================================

/// `base` plus a `<graph>/audit.jsonl.key` entry, as an older geode wrote it.
fn writeArchiveWithSeed(allocator: std.mem.Allocator, base_path: []const u8, path: []const u8, graph_prefix: []const u8, seed_hex: []const u8) !void {
    var decoded = try backup.readBackupFile(allocator, base_path, null);
    defer decoded.deinit(allocator);
    const base = decoded.archive;
    const name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ graph_prefix, seed_name });
    defer allocator.free(name);
    var archive: std.ArrayList(u8) = .empty;
    defer archive.deinit(allocator);
    try archive.appendSlice(allocator, base[0..12]);
    const count = std.mem.readInt(u32, base[12..16], .little) + 1;
    try archive.appendSlice(allocator, &std.mem.toBytes(count));
    try archive.appendSlice(allocator, base[16..]);
    try archive.appendSlice(allocator, &std.mem.toBytes(@as(u32, @intCast(name.len))));
    try archive.appendSlice(allocator, name);
    try archive.appendSlice(allocator, &std.mem.toBytes(@as(u64, seed_hex.len)));
    try archive.appendSlice(allocator, seed_hex);
    const header = backup.BackupHeader{
        .magic = backup.BACKUP_MAGIC,
        .version = backup.BACKUP_VERSION,
        .backup_type = .full,
        .timestamp = decoded.header.timestamp,
        .compression = .none,
        .encrypted = false,
        .payload_len = archive.items.len,
        .checksum = std.hash.crc.Crc32.hash(archive.items),
    };
    const f = try std.Io.Dir.cwd().createFile(fsIo(), path, .{});
    defer f.close(fsIo());
    try f.writeStreamingAll(fsIo(), std.mem.asBytes(&header));
    try f.writeStreamingAll(fsIo(), archive.items);
}

test "SONNY-6322 (1) an older archive that holds the audit seed still restores, with a warning naming it, the file 0600" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try Fixture.init(allocator, "sonny6322-old-seed");
    defer fx.deinit(allocator);
    {
        var server = try Server.start(allocator, fx.cwd, fx.x, &.{});
        defer server.stop(allocator);
        try fx.seed(allocator, &server);
    }
    const gdir = try auditGraphDir(allocator, fx.x);
    defer allocator.free(gdir);
    const graph_prefix = std.fs.path.basename(gdir);
    const bdir = try join(allocator, fx.x, "backups");
    defer allocator.free(bdir);
    const bfile = try newestBackup(allocator, bdir);
    defer allocator.free(bfile);
    // The live seed, as an older backup would have carried it.
    const live_seed_path = try join(allocator, gdir, seed_name);
    defer allocator.free(live_seed_path);
    const seed_raw = try readFileAlloc(allocator, live_seed_path);
    defer {
        std.crypto.secureZero(u8, seed_raw);
        allocator.free(seed_raw);
    }
    const old = try fx.path(allocator, "old-with-seed.backup");
    defer allocator.free(old);
    try writeArchiveWithSeed(allocator, bfile, old, graph_prefix, seed_raw);

    const t = try fx.path(allocator, "t-old");
    defer allocator.free(t);
    const hk = try join(allocator, fx.x, ".geode_hmac_key");
    defer allocator.free(hk);
    const r = try runGeode(&.{ geode_binary, "restore", old, "--data-dir", t, "--yes", "--hmac-key-file", hk }, &.{}, fx.cwd, 180);
    defer r.deinit();
    if (r.code != @as(?u8, 0) or !r.output(seed_name)) r.dump("restore of an archive with the audit seed");
    try testing.expectEqual(@as(?u8, 0), r.code);
    try testing.expect(r.output("WARNING"));
    try testing.expect(r.output(seed_name));
    try testing.expect(!r.output(std.mem.trim(u8, seed_raw, " \r\n")));
    const restored_seed = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ t, graph_prefix, seed_name });
    defer allocator.free(restored_seed);
    try testing.expect(pathExists(restored_seed));
    try testing.expectEqual(@as(u32, 0o600), try mode(restored_seed));
}
