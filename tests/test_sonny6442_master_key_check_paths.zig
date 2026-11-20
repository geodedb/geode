// CANARY: REQ=REQ-SONNY-6442-MASTER-KEY-CHECK-PATHS; FEATURE="Key configuration"; ASPECT=EveryFleKeyPathChecksKcv; STATUS=TESTED; TEST=tests/test_sonny6442_master_key_check_paths.zig; OWNER=security; UPDATED=2026-11-12
//
// SONNY-6442 (8): the master-key check value (`fle_master_key.kcv`,
// SONNY-6435) was verified by `geode serve` only. `geode fle
// migrate-encrypt` (src/admin/fle_commands.zig migrateEncrypt) and the
// in-process FLE key manager (src/fle_integration.zig getGlobalKeyManager)
// built a key manager from whatever GEODE_MASTER_KEY was set, so a wrong
// key re-encrypted fields under another key, or encrypted new ones under
// it, beside fields written with the recorded one.
//
// The contract, driven through the real functions against a data directory
// on disk:
//   - with a GEODE_MASTER_KEY other than the recorded one, migrateEncrypt
//     and the in-process key manager refuse (error.MasterKeyMismatch) before
//     building a key manager;
//   - with the recorded key they proceed, and a directory without a value
//     records one (as `geode serve` does);
//   - all three paths call one shared helper.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const fle_integration = geode.fle_integration;
const fle_commands = geode.fle_commands;
const km = geode.fle_key_manager;
const tde = geode.tde_file_encryption;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const key_a_hex = "5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8"; // gitleaks:allow
const key_b_hex = "6b86b273ff34fce19c6b804eff5a3f5747ada4eaa22f1d49c01e52ddb7875b4b"; // gitleaks:allow

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn keyBytes(hex: []const u8) [32]u8 {
    var k: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&k, hex) catch unreachable;
    return k;
}

/// A private data directory the FLE catalog (and its key check file) lives
/// in, with GEODE_MASTER_KEY set to `key_hex` (format hex) for the test.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    dir: []u8,
    kcv: []u8,
    saved: fle_integration.catalog_mod.DataDirOverrideSnapshot,

    fn init(key_hex: [:0]const u8) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = try std.process.currentPath(fsIo(), &cwd_buf);
        const dir = try std.fmt.allocPrint(testing.allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..cwd_len], &tmp.sub_path });
        errdefer testing.allocator.free(dir);
        const kcv = try std.fs.path.join(testing.allocator, &.{ dir, km.master_key_check_file_name });
        const saved = fle_integration.catalog_mod.saveDataDirOverride();
        fle_integration.catalog_mod.setDataDirOverride(dir);
        _ = setenv("GEODE_MASTER_KEY", key_hex.ptr, 1);
        _ = setenv("GEODE_MASTER_KEY_FORMAT", "hex", 1);
        fle_integration.resetGlobalKeyStateForTesting();
        return .{ .tmp = tmp, .dir = dir, .kcv = kcv, .saved = saved };
    }

    fn deinit(self: *Fixture) void {
        fle_integration.resetGlobalKeyStateForTesting();
        _ = unsetenv("GEODE_MASTER_KEY");
        _ = unsetenv("GEODE_MASTER_KEY_FORMAT");
        self.saved.restore();
        testing.allocator.free(self.kcv);
        testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }

    /// Record `key_hex` as the directory's master key, as `geode serve` does.
    fn record(self: *Fixture, key_hex: []const u8) !void {
        const line = try km.encodeMasterKeyCheck(keyBytes(key_hex));
        try tde.writeEncryptedFilePrivate(testing.allocator, self.kcv, &line);
    }

    fn recorded(self: *Fixture) !?[]u8 {
        return tde.readDecryptedFileNoFollow(testing.allocator, self.kcv) catch |err| switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    }
};

test "SONNY-6442 (8) geode fle migrate-encrypt refuses a GEODE_MASTER_KEY other than the recorded one" {
    var f = try Fixture.init(key_b_hex);
    defer f.deinit();
    try f.record(key_a_hex);
    try testing.expectError(error.MasterKeyMismatch, fle_commands.migrateEncrypt(testing.allocator, .{
        .tenant_id = "t",
        .schema_name = "Sonny6442",
        .field_name = "ssn",
    }));
}

test "SONNY-6442 (8) the in-process FLE key manager refuses a GEODE_MASTER_KEY other than the recorded one" {
    var f = try Fixture.init(key_b_hex);
    defer f.deinit();
    try f.record(key_a_hex);
    try testing.expectError(error.MasterKeyMismatch, fle_integration.rotateFieldKey(testing.allocator, "t", "Sonny6442", "ssn"));
}

test "SONNY-6442 (8) the in-process FLE key manager accepts the recorded key and records one where none is" {
    {
        var f = try Fixture.init(key_a_hex);
        defer f.deinit();
        try f.record(key_a_hex);
        _ = try fle_integration.rotateFieldKey(testing.allocator, "t", "Sonny6442", "ssn");
    }
    {
        var f = try Fixture.init(key_a_hex);
        defer f.deinit();
        _ = try fle_integration.rotateFieldKey(testing.allocator, "t", "Sonny6442", "ssn");
        const rec = (try f.recorded()) orelse return error.CheckValueNotRecorded;
        defer testing.allocator.free(rec);
        try testing.expect(try km.masterKeyCheckMatches(rec, keyBytes(key_a_hex)));
    }
}

test "SONNY-6442 (8) geode serve, geode fle and in-process FLE check the key with one shared helper" {
    for ([_][]const u8{ "src/server/server_init.zig", "src/admin/fle_commands.zig", "src/fle_integration.zig" }) |path| {
        const src = try std.Io.Dir.cwd().readFileAlloc(fsIo(), path, testing.allocator, .limited(16 << 20));
        defer testing.allocator.free(src);
        if (std.mem.indexOf(u8, src, "master_key_check.verifyOrRecord(") == null) {
            std.debug.print("SONNY-6442 (8): {s} does not call master_key_check.verifyOrRecord\n", .{path});
            return error.SharedHelperNotUsed;
        }
    }
}
