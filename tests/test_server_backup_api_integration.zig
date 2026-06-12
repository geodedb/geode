// CANARY: REQ=REQ-CLI-BACKUP-INTEGRATION-001; FEATURE="Remote Backup/Restore Operations"; ASPECT=IntegrationTesting; STATUS=TESTED; TEST=geodetestlab/specs/backup_restore_operations.yml; TEST=TestCANARY_REQ_CLI_BACKUP_INTEGRATION_001; OWNER=claude; UPDATED=2026-02-05
// Integration tests for server-side backup API with QUIC protobuf

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqualStrings = testing.expectEqualStrings;
const proto = @import("proto_test_util.zig");

fn makeTempDir(allocator: std.mem.Allocator, suffix: []const u8) ![]u8 {
    const base = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const path = try std.fmt.allocPrint(allocator, "{s}/tmp_backup_api_{s}_{d}", .{ base, suffix, std.time.nanoTimestamp() });
    try std.fs.cwd().makePath(path);
    return path;
}

fn cleanupTempDir(allocator: std.mem.Allocator, dir: []const u8) void {
    std.fs.cwd().deleteTree(dir) catch {};
    allocator.free(dir);
}

fn cleanupServerArtifacts() void {
    std.fs.cwd().deleteTree("./server_backups") catch {};
    std.fs.cwd().deleteTree("./uploaded_backups") catch {};
}

fn spawnServerWithDataDir(allocator: std.mem.Allocator, data_dir: []const u8) !proto.ServerHandle {
    const port = try proto.getRandomPort();
    const addr = try proto.formatAddr(allocator, port);
    errdefer allocator.free(addr);

    const env_pair = try std.fmt.allocPrint(allocator, "GEODE_DATA_DIR={s}", .{data_dir});
    defer allocator.free(env_pair);

    var handle = try proto.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--data_dir", data_dir },
        &.{env_pair},
    );
    handle.addr = addr;
    handle.port = port;

    try proto.waitForServerReady(allocator, addr, 10000);
    return handle;
}

test "backup: full request flow" {
    const allocator = testing.allocator;

    const data_dir = try makeTempDir(allocator, "full");
    defer cleanupTempDir(allocator, data_dir);
    defer cleanupServerArtifacts();

    var server = try spawnServerWithDataDir(allocator, data_dir);
    defer server.deinit();

    var client = try proto.QuicProtoClient.connect(allocator, server.getAddr());
    defer client.deinit();

    var res = try client.backup(allocator, "full", false);
    defer res.deinit(allocator);

    try expect(res.success);
    try expect(res.backup_id.len > 0);
    try expectEqualStrings("full", res.backup_type);
    try expectEqualStrings("none", res.compression);
    try expect(res.size_bytes > 0);
}

test "backup: incremental rejected" {
    const allocator = testing.allocator;

    const data_dir = try makeTempDir(allocator, "incremental");
    defer cleanupTempDir(allocator, data_dir);
    defer cleanupServerArtifacts();

    var server = try spawnServerWithDataDir(allocator, data_dir);
    defer server.deinit();

    var client = try proto.QuicProtoClient.connect(allocator, server.getAddr());
    defer client.deinit();

    var res = try client.backup(allocator, "incremental", true);
    defer res.deinit(allocator);

    try expect(!res.success);
    try expect(std.mem.indexOf(u8, res.message, "Only full backups") != null);
}

test "restore: requires confirmation" {
    const allocator = testing.allocator;

    const data_dir = try makeTempDir(allocator, "restore_confirm");
    defer cleanupTempDir(allocator, data_dir);
    defer cleanupServerArtifacts();

    var server = try spawnServerWithDataDir(allocator, data_dir);
    defer server.deinit();

    var client = try proto.QuicProtoClient.connect(allocator, server.getAddr());
    defer client.deinit();

    var res = try client.restore(allocator, null, false);
    defer res.deinit(allocator);

    try expect(!res.success);
    try expect(std.mem.indexOf(u8, res.message, "Restore requires confirmation") != null);
}

test "restore: full roundtrip" {
    const allocator = testing.allocator;

    const data_dir = try makeTempDir(allocator, "restore_roundtrip");
    defer cleanupTempDir(allocator, data_dir);
    defer cleanupServerArtifacts();

    var server = try spawnServerWithDataDir(allocator, data_dir);
    defer server.deinit();

    var client = try proto.QuicProtoClient.connect(allocator, server.getAddr());
    defer client.deinit();

    var backup_res = try client.backup(allocator, "full", false);
    defer backup_res.deinit(allocator);
    try expect(backup_res.success);

    var restore_res = try client.restore(allocator, null, true);
    defer restore_res.deinit(allocator);

    try expect(restore_res.success);
    try expectEqualStrings(data_dir, restore_res.restore_dir);

    const restore_path = try std.fmt.allocPrint(allocator, "{s}/graph_registry.dat", .{data_dir});
    defer allocator.free(restore_path);
    try std.fs.cwd().access(restore_path, .{});
}

test "upload: metadata-only requests are rejected (GAP-0880)" {
    const allocator = testing.allocator;

    const data_dir = try makeTempDir(allocator, "upload");
    defer cleanupTempDir(allocator, data_dir);
    defer cleanupServerArtifacts();

    var server = try spawnServerWithDataDir(allocator, data_dir);
    defer server.deinit();

    var client = try proto.QuicProtoClient.connect(allocator, server.getAddr());
    defer client.deinit();

    var invalid_res = try client.uploadBackup(allocator, 0, "");
    defer invalid_res.deinit(allocator);
    try expect(!invalid_res.success);

    // GAP-0880: the old contract accepted metadata-only uploads and created
    // an empty file. Uploads now require the artifact payload (and verify
    // size + CRC32 before any write), so a metadata-only request must be
    // rejected — no file, no registry entry, no fake success.
    var meta_only_res = try client.uploadBackup(allocator, 2048, "deadbeef");
    defer meta_only_res.deinit(allocator);
    try expect(!meta_only_res.success);
}
