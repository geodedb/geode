// CANARY: REQ=REQ-BACKUP-RESTORE-003; FEATURE="Backup Restore"; ASPECT=ServerRestoreTarget; STATUS=TESTED; TEST=tests/test_sonny6288_server_restore_target.zig; OWNER=storage; UPDATED=2026-11-11
//
// SONNY-6288: a restore request to a running server (QUIC `restore`, gRPC
// /geode.GeodeService/Restore, `geode restore --server`) restored into
// GEODE_DATA_DIR if set, else ./data in the server's working directory —
// never the directory the server was started on with --data-dir — wrote in
// place with no staging, and answered "Restore completed" while the server
// kept serving its old data. With GEODE_DATA_DIR naming the live directory
// it wrote over the open store, and the restore was lost: the server served
// the old data before and after a restart.
//
// The contract: the server never writes a restore into its live data
// directory or anywhere else outside the directory it reports. It restores
// its newest server-managed backup (at or before target_time) into a NEW
// directory beside its real data directory, staged and verified (byte
// compare, opened as a store, counted per graph), and reports that
// directory; the running server keeps serving its data until the operator
// restarts it on the restored directory. A failed restore leaves no new
// directory and the server healthy; only an Admin may restore.
//
// Every case spawns the geode this build emitted (SONNY-2697) in its own
// working directory, so a restore into ./data is caught.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const protobuf = @import("protobuf");
const schema = @import("schema");
const backup = @import("storage/backup");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");
const util = @import("proto_test_util.zig");

const grpc_query_transport = geode.grpc_query_transport;
const posix = std.posix;

const admin_user = util.DefaultAuth.username;
const admin_pw = util.DefaultAuth.password;
const reader_user = "reader6288";
const reader_pw = "Reader 6288 Restore Passphrase";

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn join(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ a, b });
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(fsIo(), path, .{}) catch return false;
    return true;
}

fn sleepMs(ms: u64) void {
    fsIo().sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

/// The entry names in `dir`, sorted. Caller frees with `freeNames`.
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

/// `dir` holds exactly `expected` (any order).
fn expectNames(allocator: std.mem.Allocator, dir_path: []const u8, expected: []const []const u8) !void {
    const names = try listNames(allocator, dir_path);
    defer freeNames(allocator, names);
    var ok = names.len == expected.len;
    for (expected) |want| {
        var found = false;
        for (names) |n| {
            if (std.mem.eql(u8, n, want)) found = true;
        }
        if (!found) ok = false;
    }
    if (!ok) {
        std.debug.print("SONNY-6288: {s} holds:", .{dir_path});
        for (names) |n| std.debug.print(" '{s}'", .{n});
        std.debug.print("\n  expected:", .{});
        for (expected) |n| std.debug.print(" '{s}'", .{n});
        std.debug.print("\n", .{});
    }
    try testing.expect(ok);
}

/// A geode server spawned in its own working directory with an environment
/// built from scratch (PATH, HOME, admin credentials and `extra_env` only),
/// so neither the parent's GEODE_DATA_DIR nor its cwd leaks in.
const Server = struct {
    threaded: std.Io.Threaded,
    env: std.process.Environ.Map,
    child: std.process.Child,
    addr: []u8,
    grpc_addr: ?[]u8 = null,

    fn start(
        allocator: std.mem.Allocator,
        cwd: []const u8,
        data_dir_flag: ?[]const u8,
        extra_env: []const [2][]const u8,
        with_grpc: bool,
    ) !Server {
        var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        errdefer threaded.deinit();
        var env = std.process.Environ.Map.init(allocator);
        errdefer env.deinit();
        inline for (.{ "PATH", "HOME", "LD_LIBRARY_PATH" }) |name| {
            if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
        }
        try env.put("GEODE_ADMIN_USERNAME", admin_user);
        try env.put("GEODE_ADMIN_PASSWORD", admin_pw);
        try env.put("GEODE_DEFAULT_PASSWORD", admin_pw);
        if (with_grpc) {
            for (util.TestEnv.grpcPlaintext()) |kv| {
                const eq = std.mem.indexOfScalar(u8, kv, '=').?;
                try env.put(kv[0..eq], kv[eq + 1 ..]);
            }
        }
        for (extra_env) |kv| try env.put(kv[0], kv[1]);

        const quic_port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, quic_port);
        errdefer allocator.free(addr);
        var grpc_addr: ?[]u8 = null;
        errdefer if (grpc_addr) |g| allocator.free(g);
        if (with_grpc) {
            // SONNY-6301: the gRPC listener is TCP; probe TCP, not UDP.
            var port = try util.getRandomTcpPort();
            while (port == quic_port) port = try util.getRandomTcpPort();
            grpc_addr = try util.formatAddr(allocator, port);
        }

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr });
        if (grpc_addr) |g| try argv.appendSlice(allocator, &.{ "--listen-grpc", g });
        if (data_dir_flag) |d| try argv.appendSlice(allocator, &.{ "--data-dir", d });

        const child = try std.process.spawn(threaded.io(), .{
            .argv = argv.items,
            .environ_map = &env,
            .cwd = .{ .path = cwd },
            .stdin = .ignore,
            .stdout = if (std.c.getenv("GEODE_TEST_INHERIT_SERVER_STDERR") != null) .inherit else .ignore,
            .stderr = if (std.c.getenv("GEODE_TEST_INHERIT_SERVER_STDERR") != null) .inherit else .ignore,
        });
        var server: Server = .{ .threaded = threaded, .env = env, .child = child, .addr = addr, .grpc_addr = grpc_addr };
        errdefer server.stop(allocator);
        try util.waitForServerReady(allocator, addr, 30000);
        if (grpc_addr) |g| try util.waitForGrpcServerReady(allocator, g, 30000);
        return server;
    }

    /// SIGTERM and wait for a clean shutdown (bounded), then reap.
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
        if (self.grpc_addr) |g| allocator.free(g);
    }

    fn connect(self: *Server, allocator: std.mem.Allocator, user: []const u8, password: []const u8) !util.QuicProtoClient {
        var client = try util.QuicProtoClient.connect(allocator, self.addr);
        errdefer client.deinit();
        var h = try client.hello(allocator, user, password);
        defer h.deinit(allocator);
        if (!h.success) {
            std.debug.print("SONNY-6288: HELLO {s} failed: {s}\n", .{ user, h.error_message });
            return error.HelloFailed;
        }
        return client;
    }
};

fn exec(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !void {
    var r = try client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("SONNY-6288: {s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
}

fn countP(client: *util.QuicProtoClient, allocator: std.mem.Allocator) !i64 {
    var r = try client.executeAndCollect(allocator, "MATCH (n:P) RETURN count(n) AS c", util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("SONNY-6288: count: {s} {s}\n", .{ code, r.error_message orelse "" });
        return error.QueryFailed;
    }
    if (r.rows.len != 1) return error.UnexpectedRows;
    return switch (r.rows[0][0]) {
        .int => |v| v,
        else => error.UnexpectedValue,
    };
}

/// Two :P nodes, a server-side backup of them, then two more (live: 4).
fn seedAndBackup(client: *util.QuicProtoClient, allocator: std.mem.Allocator) !void {
    try exec(client, allocator, "INSERT (:P {n: 1})");
    try exec(client, allocator, "INSERT (:P {n: 2})");
    var b = try client.backup(allocator, "full", false);
    defer b.deinit(allocator);
    if (!b.success) std.debug.print("SONNY-6288: backup failed: {s}\n", .{b.message});
    try testing.expect(b.success);
    try exec(client, allocator, "INSERT (:P {n: 3})");
    try exec(client, allocator, "INSERT (:P {n: 4})");
    try testing.expectEqual(@as(i64, 4), try countP(client, allocator));
}

/// A restore writes and fsyncs every file of the store (hundreds, one per
/// shard file) and opens it; on a loaded disk that takes longer than the
/// shared client helpers' 5-10 s read timeouts, so the restore calls here
/// wait up to a minute.
const restore_timeout_ms: u32 = 60_000;

const QuicRestore = struct {
    success: bool,
    message: []u8,
    restore_dir: []u8,

    fn deinit(self: *QuicRestore, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        allocator.free(self.restore_dir);
    }
};

fn quicRestore(client: *util.QuicProtoClient, allocator: std.mem.Allocator, confirm: bool) !QuicRestore {
    try client.writeMessage(.{ .restore = .{ .target_time = "", .confirm = confirm } });
    var packet = try client.readPacket(allocator, restore_timeout_ms);
    defer packet.deinit(allocator);
    const msg = packet.quic orelse return error.InvalidMessage;
    if (msg != .restore) return error.InvalidMessage;
    const message = try allocator.dupe(u8, msg.restore.message);
    errdefer allocator.free(message);
    return .{ .success = msg.restore.success, .message = message, .restore_dir = try allocator.dupe(u8, msg.restore.restore_dir) };
}

const Layout = struct {
    root: test_scratch.ScratchDir,
    cwd: []u8,
    x: []u8,
    y: []u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !Layout {
        var root = try test_scratch.ScratchDir.create(tag);
        errdefer root.remove();
        const cwd = try join(allocator, root.path(), "cwd");
        errdefer allocator.free(cwd);
        const x = try join(allocator, root.path(), "X");
        errdefer allocator.free(x);
        const y = try join(allocator, root.path(), "Y");
        errdefer allocator.free(y);
        try std.Io.Dir.cwd().createDirPath(fsIo(), cwd);
        try std.Io.Dir.cwd().createDirPath(fsIo(), x);
        return .{ .root = root, .cwd = cwd, .x = x, .y = y };
    }

    fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        allocator.free(self.cwd);
        allocator.free(self.x);
        allocator.free(self.y);
        self.root.remove();
    }

    /// The server wrote nothing into its working directory (never ./data;
    /// since SONNY-6299 its backups live under its data directory, not in
    /// ./server_backups).
    fn expectCwdClean(self: *Layout, allocator: std.mem.Allocator) !void {
        const data = try join(allocator, self.cwd, "data");
        defer allocator.free(data);
        if (pathExists(data)) std.debug.print("SONNY-6288: restore wrote into the server's ./data ({s})\n", .{data});
        try testing.expect(!pathExists(data));
        try expectNames(allocator, self.cwd, &.{});
    }
};

const Config = enum { flag, env, both };

fn startFor(allocator: std.mem.Allocator, lay: *Layout, config: Config, with_grpc: bool) !Server {
    return switch (config) {
        .flag => Server.start(allocator, lay.cwd, lay.x, &.{}, with_grpc),
        .env => Server.start(allocator, lay.cwd, null, &.{.{ "GEODE_DATA_DIR", lay.x }}, with_grpc),
        .both => Server.start(allocator, lay.cwd, lay.x, &.{.{ "GEODE_DATA_DIR", lay.y }}, with_grpc),
    };
}

/// A successful restore response: a new directory beside the live data
/// directory X (never X, never ./data), the message telling the operator
/// the running server still serves X and how to serve the restore.
fn expectRestoredBeside(allocator: std.mem.Allocator, lay: *Layout, success: bool, message: []const u8, restore_dir: []const u8) !void {
    if (!success) std.debug.print("SONNY-6288: restore failed: {s}\n", .{message});
    try testing.expect(success);
    const prefix = try std.fmt.allocPrint(allocator, "{s}.restored-", .{lay.x});
    defer allocator.free(prefix);
    if (!std.mem.startsWith(u8, restore_dir, prefix)) {
        std.debug.print("SONNY-6288: restore_dir '{s}' is not a new directory beside the live data directory '{s}' (message: {s})\n", .{ restore_dir, lay.x, message });
    }
    try testing.expect(std.mem.startsWith(u8, restore_dir, prefix));
    try testing.expect(std.mem.indexOfScalar(u8, restore_dir[prefix.len..], '/') == null);
    try testing.expect(pathExists(restore_dir));
    // Truthful: it does not claim the server now serves the restore.
    try testing.expect(!std.mem.eql(u8, message, "Restore completed"));
    try testing.expect(std.mem.indexOf(u8, message, "--data-dir") != null);
    try testing.expect(std.mem.indexOf(u8, message, restore_dir) != null);
    try testing.expect(std.mem.indexOf(u8, message, "2 nodes") != null);
}

/// The whole contract for one data-directory configuration, over QUIC.
fn restoreContract(config: Config) !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var lay = try Layout.init(allocator, switch (config) {
        .flag => "sonny6288-flag",
        .env => "sonny6288-env",
        .both => "sonny6288-both",
    });
    defer lay.deinit(allocator);

    var restore_dir: []u8 = &.{};
    defer allocator.free(restore_dir);
    {
        var server = try startFor(allocator, &lay, config, false);
        defer server.stop(allocator);
        var admin = try server.connect(allocator, admin_user, admin_pw);
        defer admin.deinit();
        try seedAndBackup(&admin, allocator);

        var r = try quicRestore(&admin, allocator, true);
        defer r.deinit(allocator);
        restore_dir = try allocator.dupe(u8, r.restore_dir);

        try lay.expectCwdClean(allocator);
        if (config == .both) {
            // GEODE_DATA_DIR is not the server's data directory here.
            if (pathExists(lay.y)) try expectNames(allocator, lay.y, &.{});
        }
        try expectRestoredBeside(allocator, &lay, r.success, r.message, r.restore_dir);
        const base = std.fs.path.basename(r.restore_dir);
        if (config == .both and pathExists(lay.y)) {
            try expectNames(allocator, lay.root.path(), &.{ "cwd", "X", "Y", base });
        } else {
            try expectNames(allocator, lay.root.path(), &.{ "cwd", "X", base });
        }

        // The running server still serves its own data, as reported.
        try testing.expectEqual(@as(i64, 4), try countP(&admin, allocator));
    }

    // Restarted on its old directory: the previous data is intact.
    {
        var server = try startFor(allocator, &lay, config, false);
        defer server.stop(allocator);
        var admin = try server.connect(allocator, admin_user, admin_pw);
        defer admin.deinit();
        try testing.expectEqual(@as(i64, 4), try countP(&admin, allocator));
    }

    // Started on the restored directory: it serves the backup's data.
    {
        var server = try Server.start(allocator, lay.cwd, restore_dir, &.{}, false);
        defer server.stop(allocator);
        var admin = try server.connect(allocator, admin_user, admin_pw);
        defer admin.deinit();
        try testing.expectEqual(@as(i64, 2), try countP(&admin, allocator));
    }
}

test "SONNY-6288 QUIC restore on a server started with --data-dir and no GEODE_DATA_DIR restores beside its data directory, never ./data" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try restoreContract(.flag);
}

test "SONNY-6288 QUIC restore on a server whose data directory comes from GEODE_DATA_DIR never writes over the live store" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try restoreContract(.env);
}

test "SONNY-6288 QUIC restore with --data-dir and a different GEODE_DATA_DIR restores beside --data-dir and leaves GEODE_DATA_DIR alone" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try restoreContract(.both);
}

/// A backup artifact (header + archive) whose archive holds one entry
/// named `entry_name`, stamped `timestamp` so it is the newest backup.
fn unsafeBackupBytes(allocator: std.mem.Allocator, entry_name: []const u8, timestamp: i64) ![]u8 {
    var archive: std.ArrayList(u8) = .empty;
    defer archive.deinit(allocator);
    try archive.appendSlice(allocator, "GEODBAK1");
    try archive.appendSlice(allocator, &std.mem.toBytes(@as(u32, 1)));
    try archive.appendSlice(allocator, &std.mem.toBytes(@as(u32, 1)));
    const data = "escaped";
    try archive.appendSlice(allocator, &std.mem.toBytes(@as(u32, @intCast(entry_name.len))));
    try archive.appendSlice(allocator, entry_name);
    try archive.appendSlice(allocator, &std.mem.toBytes(@as(u64, data.len)));
    try archive.appendSlice(allocator, data);

    const header = backup.BackupHeader{
        .magic = backup.BACKUP_MAGIC,
        .version = backup.BACKUP_VERSION,
        .backup_type = .full,
        .timestamp = timestamp,
        .compression = .none,
        .encrypted = false,
        .payload_len = archive.items.len,
        .checksum = std.hash.crc.Crc32.hash(archive.items),
    };
    const out = try allocator.alloc(u8, @sizeOf(backup.BackupHeader) + archive.items.len);
    @memcpy(out[0..@sizeOf(backup.BackupHeader)], std.mem.asBytes(&header));
    @memcpy(out[@sizeOf(backup.BackupHeader)..], archive.items);
    return out;
}

fn uploadBackup(client: *util.QuicProtoClient, allocator: std.mem.Allocator, bytes: []const u8) !void {
    const hdr: backup.BackupHeader = @bitCast(bytes[0..@sizeOf(backup.BackupHeader)].*);
    var checksum_buf: [32]u8 = undefined;
    const checksum = try std.fmt.bufPrint(&checksum_buf, "{x}", .{hdr.checksum});
    try client.writeMessage(.{ .upload_backup = .{ .size_bytes = bytes.len, .checksum = checksum, .payload = bytes } });
    var packet = try client.readPacket(allocator, 10000);
    defer packet.deinit(allocator);
    const msg = packet.quic orelse return error.InvalidMessage;
    if (msg != .upload_backup) return error.InvalidMessage;
    if (!msg.upload_backup.success) std.debug.print("SONNY-6288: upload failed: {s}\n", .{msg.upload_backup.message});
    try testing.expect(msg.upload_backup.success);
}

fn nowMs() i64 {
    var ts: posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// A failed restore: no success, the named error, nothing new beside the
/// data directory, the server healthy and serving its data.
fn expectRestoreRefused(allocator: std.mem.Allocator, lay: *Layout, client: *util.QuicProtoClient, admin: *util.QuicProtoClient, needle: []const u8) !void {
    var r = try quicRestore(client, allocator, true);
    defer r.deinit(allocator);
    if (r.success or std.mem.indexOf(u8, r.message, needle) == null) {
        std.debug.print("SONNY-6288: expected a refused restore naming '{s}', got success={} message='{s}' restore_dir='{s}'\n", .{ needle, r.success, r.message, r.restore_dir });
    }
    try testing.expect(!r.success);
    try testing.expect(std.mem.indexOf(u8, r.message, needle) != null);
    try expectNames(allocator, lay.root.path(), &.{ "cwd", "X" });
    try lay.expectCwdClean(allocator);
    try testing.expectEqual(@as(i64, 4), try countP(admin, allocator));
}

test "SONNY-6288 a failed server restore (corrupt backup, unsafe entry names, non-admin) writes nothing and the server keeps serving" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var lay = try Layout.init(allocator, "sonny6288-fail");
    defer lay.deinit(allocator);

    var server = try startFor(allocator, &lay, .flag, false);
    defer server.stop(allocator);
    var admin = try server.connect(allocator, admin_user, admin_pw);
    defer admin.deinit();
    try seedAndBackup(&admin, allocator);

    // Non-admin: refused before anything is read or written.
    try exec(&admin, allocator, "CREATE USER " ++ reader_user ++ " SET PASSWORD '" ++ reader_pw ++ "' ROLE readwrite");
    {
        var reader = try server.connect(allocator, reader_user, reader_pw);
        defer reader.deinit();
        try expectRestoreRefused(allocator, &lay, &reader, &admin, "Permission denied");
    }

    // No confirmation: refused.
    {
        var r = try quicRestore(&admin, allocator, false);
        defer r.deinit(allocator);
        try testing.expect(!r.success);
        try expectNames(allocator, lay.root.path(), &.{ "cwd", "X" });
    }

    // Corrupt the server's backup: refused, nothing written.
    {
        const backups = try join(allocator, lay.x, "backups");
        defer allocator.free(backups);
        const names = try listNames(allocator, backups);
        defer freeNames(allocator, names);
        var corrupted = false;
        for (names) |n| {
            if (!std.mem.endsWith(u8, n, ".backup")) continue;
            const p = try join(allocator, backups, n);
            defer allocator.free(p);
            const f = try std.Io.Dir.cwd().openFile(fsIo(), p, .{ .mode = .read_write });
            defer f.close(fsIo());
            const len = (try f.stat(fsIo())).size;
            var byte: [1]u8 = undefined;
            _ = try f.readPositionalAll(fsIo(), &byte, len - 1);
            byte[0] ^= 0xFF;
            try f.writePositionalAll(fsIo(), &byte, len - 1);
            corrupted = true;
        }
        try testing.expect(corrupted);
        try expectRestoreRefused(allocator, &lay, &admin, &admin, "BackupChecksumMismatch");
    }

    // A backup whose archive names a path outside the restore directory:
    // refused before anything is written, nothing escapes.
    {
        const evil = try unsafeBackupBytes(allocator, "../escaped.txt", nowMs());
        defer allocator.free(evil);
        try uploadBackup(&admin, allocator, evil);
        try expectRestoreRefused(allocator, &lay, &admin, &admin, "UnsafeArchiveEntryName");
        const escaped = try join(allocator, lay.root.path(), "escaped.txt");
        defer allocator.free(escaped);
        try testing.expect(!pathExists(escaped));
    }
}

const GrpcRestore = struct {
    resp: schema.RestoreResponse,
    fn deinit(self: *GrpcRestore, allocator: std.mem.Allocator) void {
        self.resp.deinit(allocator);
    }
};

/// A restore over the real gRPC wire (/geode.GeodeService/Restore).
fn grpcRestore(allocator: std.mem.Allocator, addr: []const u8, user: []const u8, password: []const u8) !GrpcRestore {
    const colon = std.mem.lastIndexOfScalar(u8, addr, ':').?;
    const port = try std.fmt.parseInt(u16, addr[colon + 1 ..], 10);
    var client: util.GrpcProtoClient = .{
        .allocator = allocator,
        .stream = try grpc_query_transport.connectPlaintext(allocator, addr[0..colon], port, restore_timeout_ms / 1000, .{}),
    };
    defer client.deinit();
    var h = try client.hello(allocator, user, password);
    defer h.deinit(allocator);
    if (!h.success) return error.HelloFailed;
    const req = schema.RestoreRequest{ .confirm = true, .session_id = client.session_id };
    const req_bytes = try grpc_query_transport.encodeMessage(allocator, req);
    defer allocator.free(req_bytes);
    try grpc_query_transport.sendRequest(allocator, client.stream, "/geode.GeodeService/Restore", req_bytes, grpc_query_transport.execute_stream_id);
    const resp_bytes = (try grpc_query_transport.readResponse(allocator, client.stream, .{})) orelse return error.EmptyResponse;
    defer allocator.free(resp_bytes);
    var reader: std.Io.Reader = .fixed(resp_bytes);
    return .{ .resp = try protobuf.decode(schema.RestoreResponse, &reader, allocator) };
}

test "SONNY-6288 gRPC restore on a server started with --data-dir restores beside its data directory and refuses a non-admin" {
    // SONNY-6782: plaintext gRPC is served in Debug only.
    if (!util.grpc_plaintext_served) return error.SkipZigTest;
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var lay = try Layout.init(allocator, "sonny6288-grpc");
    defer lay.deinit(allocator);

    var server = try startFor(allocator, &lay, .flag, true);
    defer server.stop(allocator);
    var admin = try server.connect(allocator, admin_user, admin_pw);
    defer admin.deinit();
    try seedAndBackup(&admin, allocator);
    try exec(&admin, allocator, "CREATE USER " ++ reader_user ++ " SET PASSWORD '" ++ reader_pw ++ "' ROLE readwrite");

    {
        var r = try grpcRestore(allocator, server.grpc_addr.?, reader_user, reader_pw);
        defer r.deinit(allocator);
        try testing.expect(!r.resp.success);
        try testing.expect(std.mem.indexOf(u8, r.resp.message, "Permission denied") != null);
        try expectNames(allocator, lay.root.path(), &.{ "cwd", "X" });
    }

    var r = try grpcRestore(allocator, server.grpc_addr.?, admin_user, admin_pw);
    defer r.deinit(allocator);
    try lay.expectCwdClean(allocator);
    try expectRestoredBeside(allocator, &lay, r.resp.success, r.resp.message, r.resp.restore_dir);
    try expectNames(allocator, lay.root.path(), &.{ "cwd", "X", std.fs.path.basename(r.resp.restore_dir) });
    try testing.expectEqual(@as(i64, 4), try countP(&admin, allocator));
}

// The cluster gate lives in the request function both handlers call
// (backup_manager.restoreForServer); a cluster needs certificates and three
// nodes, so the gate is driven in process with a coordinator installed as
// the process's cluster coordinator (a fresh one is a follower).
test "SONNY-6288 a server restore is refused in cluster mode before anything is read or written" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    const cluster = geode.distributed.cluster;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var coord = try cluster.ClusterCoordinator.init(arena.allocator(), 1, .{ .peers = &.{}, .cluster_token = "sonny6288" });
    const saved = cluster.getGlobalClusterCoordinator();
    cluster.setGlobalClusterCoordinator(&coord);
    defer if (saved) |c| cluster.setGlobalClusterCoordinator(c) else cluster.clearGlobalClusterCoordinator();

    var root = try test_scratch.ScratchDir.create("sonny6288-cluster");
    defer root.remove();
    const backups = try join(allocator, root.path(), "server_backups");
    defer allocator.free(backups);

    const result = try geode.backup_manager.restoreForServer(allocator, &.{backups}, "", "geode");
    defer allocator.free(result.message);
    defer allocator.free(result.restore_dir);
    try testing.expect(!result.success);
    try testing.expect(std.mem.indexOf(u8, result.message, "ClusterNotLeader") != null);
    try testing.expectEqual(@as(usize, 0), result.restore_dir.len);
    try expectNames(allocator, root.path(), &.{});
}
