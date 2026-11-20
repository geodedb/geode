// SONNY-6355 items 1, 2, 5 and 6 (item 4 was fixed in cd2acd5b; items 3 and
// 7 need a read-only open in the graph_storage dependency):
//
//   (1) backups were never encrypted: every caller of BackupManager passed
//       `.encryption = false` (src/cli/backup_cli.zig, the QUIC and gRPC
//       backup handlers), although BackupManager encrypts with AES-256-GCM
//       under GEODE_TDE_KEY and every restore path decrypts with it. A server
//       whose pages are encrypted under GEODE_TDE_KEY wrote its backups in
//       plaintext. With GEODE_TDE_KEY set, a backup is now encrypted, and an
//       unusable GEODE_TDE_KEY fails the backup instead of writing plaintext;
//   (2) createFullBackup (the server's backups) and metadata.json were not
//       fsynced;
//   (5) BackupConfig.retention_days had no consumer;
//   (6) `backup create --local` created a missing --output parent directory
//       (as a side effect of BackupManager.init) and the remote path did
//       not: both now refuse a missing parent before doing any work.
//
// CANARY: REQ=REQ-SONNY-6355-BACKUP-ENCRYPT-FSYNC; FEATURE="Backup"; ASPECT=EncryptedUnderTdeKeySyncedOutputDir; STATUS=TESTED; TEST=tests/test_sonny6355_backup_encryption_fsync_output.zig; OWNER=storage; UPDATED=2026-11-12

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const backup = @import("storage/backup");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");
const options = @import("sonny6355b_options");

const geode_binary = geode_test_bin.geode_exe;
const admin_pw = "Correct horse battery staple sonny";
const tde_key_hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
const other_key_hex = "ff0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1eff";

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn join(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ a, b });
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(fsIo(), path, allocator, .limited(64 << 20));
}

fn readRepoFile(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    const abs = try std.fs.path.join(allocator, &.{ options.repo_root, rel });
    defer allocator.free(abs);
    return readFileAlloc(allocator, abs);
}

fn exists(path: []const u8) bool {
    std.Io.Dir.cwd().access(fsIo(), path, .{}) catch return false;
    return true;
}

fn hexKey(hex: []const u8) [32]u8 {
    var k: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&k, hex) catch unreachable;
    return k;
}

const Run = struct {
    code: ?u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }

    fn dump(self: Run, what: []const u8) void {
        std.debug.print("SONNY-6355 {s}: exit={?d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ what, self.code, self.stdout, self.stderr });
    }
};

fn runGeode(argv: []const []const u8, cwd: []const u8, env_kv: []const [2][]const u8) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "HOME" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    for (env_kv) |kv| try env.put(kv[0], kv[1]);
    const result = try std.process.run(testing.allocator, threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(300), .clock = .awake } },
    });
    const code: ?u8 = switch (result.term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .code = code, .stdout = result.stdout, .stderr = result.stderr };
}

/// A store at `<root>/<name>` made by the offline auth bootstrap, with the
/// given environment (GEODE_TDE_KEY or none).
fn makeStore(allocator: std.mem.Allocator, root: []const u8, name: []const u8, env: []const [2][]const u8) ![]u8 {
    const d = try join(allocator, root, name);
    errdefer allocator.free(d);
    try std.Io.Dir.cwd().createDirPath(fsIo(), d);
    var full: [4][2][]const u8 = undefined;
    full[0] = .{ "GEODE_ADMIN_PASSWORD", admin_pw };
    for (env, 0..) |kv, i| full[i + 1] = kv;
    const r = try runGeode(&.{ geode_binary, "auth", "init", "--data-dir", d }, root, full[0 .. env.len + 1]);
    defer r.deinit();
    if (r.code != @as(?u8, 0)) r.dump("auth init");
    try testing.expectEqual(@as(?u8, 0), r.code);
    return d;
}

// ---------------------------------------------------------------------------
// (1) encryption under GEODE_TDE_KEY
// ---------------------------------------------------------------------------

test "SONNY-6355 (1) with GEODE_TDE_KEY set a backup is encrypted under it, restores with it and not without it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6355-enc");
    defer root.remove();
    const cwd = root.path();
    const key_env = [_][2][]const u8{.{ "GEODE_TDE_KEY", tde_key_hex }};

    const d = try makeStore(allocator, cwd, "D", &key_env);
    defer allocator.free(d);
    const out = try join(allocator, cwd, "enc.backup");
    defer allocator.free(out);
    {
        const r = try runGeode(&.{ geode_binary, "backup", "create", "--local", "--data-dir", d, "--output", out }, cwd, &key_env);
        defer r.deinit();
        if (r.code != @as(?u8, 0)) r.dump("backup create --local (GEODE_TDE_KEY set)");
        try testing.expectEqual(@as(?u8, 0), r.code);
    }

    const hdr = try backup.readBackupHeader(out);
    if (!hdr.header.encrypted) {
        std.debug.print("SONNY-6355 (1): a backup taken with GEODE_TDE_KEY set is not encrypted (header.encrypted=false; .encryption = false in src/cli/backup_cli.zig executeLocalDirectoryBackup)\n", .{});
        return error.TestUnexpectedResult;
    }
    // The payload is ciphertext: the archive magic does not appear in it.
    const bytes = try readFileAlloc(allocator, out);
    defer allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes[@sizeOf(backup.BackupHeader)..], "GEODBAK1") == null);

    // It decodes with the key, and not with another one.
    var decoded = try backup.readBackupFile(allocator, out, hexKey(tde_key_hex));
    defer decoded.deinit(allocator);
    try testing.expect(decoded.stats.files > 0);
    try testing.expectError(error.DecryptionFailed, backup.readBackupFile(allocator, out, hexKey(other_key_hex)));

    // geode restore without the key refuses; with it, it restores the store.
    const hk = try join(allocator, d, ".geode_hmac_key");
    defer allocator.free(hk);
    const t0 = try join(allocator, cwd, "T0");
    defer allocator.free(t0);
    {
        const r = try runGeode(&.{ geode_binary, "restore", out, "--data-dir", t0, "--yes", "--hmac-key-file", hk }, cwd, &.{});
        defer r.deinit();
        if (r.code == @as(?u8, 0)) {
            r.dump("restore of an encrypted backup without GEODE_TDE_KEY");
            return error.TestUnexpectedResult;
        }
    }
    const t = try join(allocator, cwd, "T");
    defer allocator.free(t);
    {
        // GEODE_TDE_KEY is also the auth-chain HMAC key source, so no
        // --hmac-key-file (restore refuses both).
        const r = try runGeode(&.{ geode_binary, "restore", out, "--data-dir", t, "--yes" }, cwd, &key_env);
        defer r.deinit();
        if (r.code != @as(?u8, 0)) r.dump("restore of an encrypted backup with GEODE_TDE_KEY");
        try testing.expectEqual(@as(?u8, 0), r.code);
    }
    const reg_src = try join(allocator, d, "graph_registry.dat");
    defer allocator.free(reg_src);
    const reg_dst = try join(allocator, t, "graph_registry.dat");
    defer allocator.free(reg_dst);
    const a = try readFileAlloc(allocator, reg_src);
    defer allocator.free(a);
    const b = try readFileAlloc(allocator, reg_dst);
    defer allocator.free(b);
    try testing.expectEqualSlices(u8, a, b);
}

test "SONNY-6355 (1) without GEODE_TDE_KEY a backup is plaintext, and an unusable GEODE_TDE_KEY writes no backup" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6355-plain");
    defer root.remove();
    const cwd = root.path();

    const d = try makeStore(allocator, cwd, "D", &.{});
    defer allocator.free(d);
    const plain = try join(allocator, cwd, "plain.backup");
    defer allocator.free(plain);
    {
        const r = try runGeode(&.{ geode_binary, "backup", "create", "--local", "--data-dir", d, "--output", plain }, cwd, &.{});
        defer r.deinit();
        if (r.code != @as(?u8, 0)) r.dump("backup create --local (no key)");
        try testing.expectEqual(@as(?u8, 0), r.code);
    }
    const hdr = try backup.readBackupHeader(plain);
    try testing.expect(!hdr.header.encrypted);

    const bad = try join(allocator, cwd, "bad.backup");
    defer allocator.free(bad);
    {
        const r = try runGeode(&.{ geode_binary, "backup", "create", "--local", "--data-dir", d, "--output", bad }, cwd, &.{.{ "GEODE_TDE_KEY", "not-a-hex-key" }});
        defer r.deinit();
        if (r.code == @as(?u8, 0) or exists(bad)) {
            r.dump("backup create --local with an unusable GEODE_TDE_KEY");
            std.debug.print("SONNY-6355 (1): an unusable GEODE_TDE_KEY must fail the backup, not write it in plaintext (file written: {})\n", .{exists(bad)});
            return error.TestUnexpectedResult;
        }
    }
}

test "SONNY-6355 (1) no backup caller hard-codes .encryption = false" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    for ([_][]const u8{ "src/cli/backup_cli.zig", "src/server/quic_connection_handler.zig", "src/transport/grpc_server.zig" }) |rel| {
        const src = try readRepoFile(allocator, rel);
        defer allocator.free(src);
        var lines = std.mem.splitScalar(u8, src, '\n');
        var n: usize = 0;
        while (lines.next()) |line| {
            n += 1;
            if (std.mem.indexOf(u8, line, ".encryption = false") != null) {
                bad += 1;
                std.debug.print("SONNY-6355 (1): {s}:{d}: {s}\n", .{ rel, n, std.mem.trim(u8, line, " ") });
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

// ---------------------------------------------------------------------------
// (2) the server's backups are synced
// ---------------------------------------------------------------------------

/// The body of `fn name(` in `src`, up to the next line that closes a
/// function at the same indentation.
fn fnBody(src: []const u8, comptime sig: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, src, sig) orelse return null;
    const end = std.mem.indexOfPos(u8, src, at, "\n    }\n") orelse return null;
    return src[at..end];
}

test "SONNY-6355 (2) createFullBackup and the metadata log are synced before they are reported written" {
    const allocator = testing.allocator;
    const src = try readRepoFile(allocator, "src/storage/backup.zig");
    defer allocator.free(src);
    var bad: usize = 0;
    const create = fnBody(src, "pub fn createFullBackup(self: *BackupManager)") orelse return error.MissingFunction;
    if (std.mem.indexOf(u8, create, ".sync = true") == null) {
        bad += 1;
        std.debug.print("SONNY-6355 (2): createFullBackup writes the server's backup without syncing it\n", .{});
    }
    const meta = fnBody(src, "fn writeMetadata(self: *BackupManager)") orelse return error.MissingFunction;
    if (std.mem.indexOf(u8, meta, ".sync(") == null) {
        bad += 1;
        std.debug.print("SONNY-6355 (2): writeMetadata writes metadata.json without syncing it\n", .{});
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

// ---------------------------------------------------------------------------
// (5) retention_days
// ---------------------------------------------------------------------------

test "SONNY-6355 (5) BackupConfig has no retention_days nothing reads" {
    if (@hasField(backup.BackupConfig, "retention_days")) {
        std.debug.print("SONNY-6355 (5): BackupConfig.retention_days is still there; nothing applies it (runRetention was removed in SONNY-6323)\n", .{});
        return error.TestUnexpectedResult;
    }
}

// ---------------------------------------------------------------------------
// (6) a missing --output directory
// ---------------------------------------------------------------------------

test "SONNY-6355 (6) backup create refuses a missing --output directory, local and remote, and creates nothing" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var root = try test_scratch.ScratchDir.create("sonny6355-outdir");
    defer root.remove();
    const cwd = root.path();
    const d = try makeStore(allocator, cwd, "D", &.{});
    defer allocator.free(d);

    const missing = try join(allocator, cwd, "no/such/dir");
    defer allocator.free(missing);
    const out = try join(allocator, missing, "x.backup");
    defer allocator.free(out);
    const parent = try join(allocator, cwd, "no");
    defer allocator.free(parent);

    var bad: usize = 0;
    {
        const r = try runGeode(&.{ geode_binary, "backup", "create", "--local", "--data-dir", d, "--output", out }, cwd, &.{});
        defer r.deinit();
        if (r.code == @as(?u8, 0) or exists(parent) or std.mem.indexOf(u8, r.stderr, "does not exist") == null) {
            bad += 1;
            r.dump("backup create --local into a missing directory");
            std.debug.print("SONNY-6355 (6): --local: exit {?d}, directory created: {}\n", .{ r.code, exists(parent) });
        }
    }
    {
        // Nothing listens on this server; the directory is checked first.
        // SONNY-6782: a release build refuses --insecure-tls-skip-verify without GEODE_ALLOW_INSECURE_TLS=1.
        const r = try runGeode(&.{ geode_binary, "backup", "create", "--server", "127.0.0.1:1", "--insecure-tls-skip-verify", "--output", out, "--timeout", "2" }, cwd, &.{.{ "GEODE_ALLOW_INSECURE_TLS", "1" }});
        defer r.deinit();
        if (r.code == @as(?u8, 0) or exists(parent) or std.mem.indexOf(u8, r.stderr, "does not exist") == null) {
            bad += 1;
            r.dump("backup create (remote) into a missing directory");
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}
