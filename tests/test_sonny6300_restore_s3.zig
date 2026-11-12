// CANARY: REQ=REQ-SONNY-6300; FEATURE="Offline restore safety"; ASPECT=S3Transport; STATUS=TESTED; TEST=tests/test_sonny6300_restore_s3.zig; OWNER=storage; UPDATED=2026-11-11
const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;
const s3 = @import("s3_backup");
const Fixture = @import("support/restore_harness.zig").Fixture;

fn environment(name: [*:0]const u8) ![]const u8 {
    return if (std.c.getenv(name)) |value| std.mem.span(value) else error.SkipZigTest;
}

// The required test-restore-s3 CI job supplies an owned real MinIO server.
// Ordinary shards without the fixture explicitly skip this external-I/O case.
test "SONNY-6300 real SigV4 S3 upload download verified restore preserves the open store" {
    const endpoint = try environment("GEODE_TEST_S3_ENDPOINT");
    const access = try environment("GEODE_TEST_S3_ACCESS_KEY");
    const secret = try environment("GEODE_TEST_S3_SECRET_KEY");
    const bucket = try environment("GEODE_TEST_S3_BUCKET");
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var manager = try s3.S3BackupManager.init(testing.allocator, .{
        .bucket = bucket,
        .prefix = "restore-test",
        .access_key_id = access,
        .secret_access_key = secret,
        .endpoint = endpoint,
        .use_ssl = false, // Private owned loopback object store, never external.
        .addressing_style = .path,
        .max_retries = 1,
    }, .{});
    defer manager.deinit();
    const meta = try manager.fullBackup(&fixture.store, fixture.backups);
    _ = try fixture.store.createNode(&.{"AfterBackup"});
    try fixture.store.saveToFile();
    try testing.expectError(error.LiveRestoreRequiresRestart, manager.restore(meta.backup_id, fixture.live, &fixture.store));
    const target = try std.fmt.allocPrint(testing.allocator, "{s}/restored-s3", .{fixture.root});
    defer testing.allocator.free(target);
    try manager.restore(meta.backup_id, target, &fixture.store);
    const restored = try geode.graph_storage_adapter.StorageAdapter.initForRestoreVerification(testing.allocator, target);
    defer restored.deinit();
    try testing.expectEqual(@as(u64, 1), try restored.nodeCount("default"));
    try fixture.assertLiveAfterReopen();
    // Refuse merging into an already published target on a second download.
    try testing.expectError(error.RestoreTargetNotEmpty, manager.restore(meta.backup_id, target, &fixture.store));
    try testing.expectEqual(@as(u64, 1), try restored.nodeCount("default"));
    const io = std.Io.Threaded.global_single_threaded.io();
    var entries = try std.Io.Dir.cwd().openDir(io, fixture.root, .{ .iterate = true });
    defer entries.close(io);
    var iterator = entries.iterate();
    while (try iterator.next(io)) |entry| {
        try testing.expect(!std.mem.startsWith(u8, entry.name, ".geode-s3-download-"));
        try testing.expect(!std.mem.startsWith(u8, entry.name, ".geode-restore-"));
    }
}
