const std = @import("std");
const testing = std.testing;

// GAP-0880: Backup protocol upload ingestion + honest compression codec.
//
// Before this fix the QUIC/gRPC upload-backup handlers validated only
// size/checksum metadata, created an EMPTY file, and reported success —
// clients believed their backup uploaded when it didn't. And the storage
// layer recorded `.none` compression silently when `.zstd` was requested.
//
// This regression drives the REAL backup engine paths the handlers now call:
//   - `BackupManager.ingestUploadedBackup` (verify -> persist -> register)
//   - the gzip encoder (`std.compress.flate`) round-trip with truthful
//     manifest codec (header + metadata record what was ACTUALLY applied)
//   - `.zstd` requests fail loudly with error.UnsupportedCompression
//   - the new `UploadBackupRequest.payload` wire field round-trips
//
// CANARY: REQ=REQ-BACKUP-UPLOAD-001; FEATURE="BackupUploadIngestion"; ASPECT=TEST; STATUS=TESTED; TEST=tests/test_gap0880_backup_upload.zig; OWNER=backup; UPDATED=2026-06-10
// CANARY: REQ=REQ-BACKUP-COMPRESS-001; FEATURE="BackupGzipCompression"; ASPECT=TEST; STATUS=TESTED; TEST=tests/test_gap0880_backup_upload.zig; OWNER=backup; UPDATED=2026-06-10

const backup = @import("storage/backup");
const graph_store = @import("geode").graph_store;
const protobuf = @import("protobuf");
const schema = @import("schema");

fn uniqueNanos() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}

fn cwdAbsAlloc(allocator: std.mem.Allocator) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return allocator.dupe(u8, cwd_buf[0..actual_len]);
}

fn makeTempDir(allocator: std.mem.Allocator, suffix: []const u8) ![]u8 {
    const base = try cwdAbsAlloc(allocator);
    defer allocator.free(base);
    const path = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/gap0880_{s}_{d}", .{ base, suffix, uniqueNanos() });
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().createDirPath(io, path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return path;
}

fn cleanupTempDir(allocator: std.mem.Allocator, dir: []const u8) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    allocator.free(dir);
}

fn initAdapterForDir(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    graph_store.deinitGlobalStore();
    graph_store.deinitGlobalAdapter();
    graph_store.setDataDirOverride(allocator, data_dir);
    _ = try graph_store.initGlobalAdapter(allocator, data_dir);
}

fn resetGlobalStorage(allocator: std.mem.Allocator) void {
    graph_store.deinitGlobalStore();
    graph_store.deinitGlobalAdapter();
    graph_store.setDataDirOverride(allocator, null);
}

/// Seed a small known graph (2 nodes, 1 edge, sampled properties).
fn seedGraph(store: *graph_store.GraphStore) !struct { alice: u64, post: u64, edge: u64 } {
    const alice = try store.createNode(&.{"User"});
    try store.setNodeProperty(alice, "name", .{ .String = "Alice" });
    try store.setNodeProperty(alice, "age", .{ .Int = 30 });

    const post = try store.createNode(&.{"Post"});
    try store.setNodeProperty(post, "title", .{ .String = "Hello World" });

    const edge = try store.createEdge(alice, post, "AUTHORED");
    try store.setEdgeProperty(edge, "since", .{ .Int = 2026 });

    try store.saveToFile();
    return .{ .alice = alice, .post = post, .edge = edge };
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    const data = try allocator.alloc(u8, size);
    errdefer allocator.free(data);
    const n = try file.readPositionalAll(io, data, 0);
    if (n != size) return error.UnexpectedEof;
    return data;
}

// ---------------------------------------------------------------------------
// Compression truth
// ---------------------------------------------------------------------------

// gzip request -> a REAL gzip-compressed payload: the manifest (header +
// metadata) records `.gzip`, the payload bytes carry the gzip magic, and the
// round-trip restores the graph intact.
test "GAP-0880 gzip backup compresses for real and round-trips" {
    const allocator = testing.allocator;
    defer resetGlobalStorage(allocator);

    const data_dir = try makeTempDir(allocator, "gzdata");
    defer cleanupTempDir(allocator, data_dir);
    try initAdapterForDir(allocator, data_dir);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    store.data_dir = data_dir;
    const seed = try seedGraph(&store);

    const backup_dir = try makeTempDir(allocator, "gzbackups");
    defer cleanupTempDir(allocator, backup_dir);

    var mgr = try backup.BackupManager.init(allocator, backup_dir, .{ .compression = .gzip }, &store);
    defer mgr.deinit();

    const meta = try mgr.createFullBackup();
    try testing.expect(meta.size_bytes > 0);
    // Manifest codec is truthful: gzip was requested AND applied.
    try testing.expectEqual(backup.CompressionType.gzip, meta.compression);

    // The on-disk artifact must agree: header records .gzip and the payload
    // section starts with the gzip magic bytes (0x1f 0x8b).
    const backup_path = try std.fmt.allocPrint(allocator, "{s}/full_{x}.backup", .{ backup_dir, meta.backup_id });
    defer allocator.free(backup_path);
    const file_bytes = try readFileAlloc(allocator, backup_path);
    defer allocator.free(file_bytes);

    try testing.expect(file_bytes.len > @sizeOf(backup.BackupHeader) + 2);
    var header_buf: [@sizeOf(backup.BackupHeader)]u8 = undefined;
    @memcpy(&header_buf, file_bytes[0..@sizeOf(backup.BackupHeader)]);
    const header: backup.BackupHeader = @bitCast(header_buf);
    try testing.expectEqual(backup.CompressionType.gzip, header.compression);
    const payload = file_bytes[@sizeOf(backup.BackupHeader)..];
    try testing.expectEqual(@as(u8, 0x1f), payload[0]);
    try testing.expectEqual(@as(u8, 0x8b), payload[1]);

    // Round-trip: restore and verify the data is identical.
    const restore_dir = try makeTempDir(allocator, "gzrestore");
    defer cleanupTempDir(allocator, restore_dir);
    try mgr.restoreToPointInTime(restore_dir, meta.timestamp + 1);

    try initAdapterForDir(allocator, restore_dir);
    var restored = try graph_store.GraphStore.init(allocator);
    defer restored.deinit();
    restored.data_dir = restore_dir;
    try restored.loadFromFile();

    // Counted through the hydrating reads: the restored store is cold, its
    // resident `nodes`/`edges` caches empty until first access (SONNY-6277).
    try testing.expectEqual(@as(usize, 2), restored.getNodeCount());
    try testing.expectEqual(@as(usize, 1), restored.getEdgeCount());
    const name = restored.getNodeProperty(seed.alice, "name") orelse return error.NodePropertyMissing;
    try testing.expectEqualStrings("Alice", name.String);
    const title = restored.getNodeProperty(seed.post, "title") orelse return error.NodePropertyMissing;
    try testing.expectEqualStrings("Hello World", title.String);
    const edge_ptr = restored.getEdgePtr(seed.edge) orelse return error.EdgeMissing;
    const since = edge_ptr.properties.get("since") orelse return error.EdgePropertyMissing;
    try testing.expectEqual(@as(i64, 2026), since.Int);
}

// A `.zstd` request must fail loudly — there is no zstd encoder, and silently
// recording a codec that wasn't applied (or silently degrading) lies to the
// caller about what they got.
test "GAP-0880 zstd request fails with UnsupportedCompression" {
    const allocator = testing.allocator;
    defer resetGlobalStorage(allocator);

    const data_dir = try makeTempDir(allocator, "zdata");
    defer cleanupTempDir(allocator, data_dir);
    try initAdapterForDir(allocator, data_dir);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    store.data_dir = data_dir;
    _ = try seedGraph(&store);

    const backup_dir = try makeTempDir(allocator, "zbackups");
    defer cleanupTempDir(allocator, backup_dir);

    var mgr = try backup.BackupManager.init(allocator, backup_dir, .{ .compression = .zstd }, &store);
    defer mgr.deinit();

    try testing.expectError(error.UnsupportedCompression, mgr.createFullBackup());
}

// ---------------------------------------------------------------------------
// Upload ingestion
// ---------------------------------------------------------------------------

// The real upload contract: ingest verifies the artifact (magic, version,
// payload length, CRC32, client-asserted checksum), persists the EXACT bytes
// to disk, registers the backup durably in the metadata log, and the result
// is restorable. Before GAP-0880 the handlers created an EMPTY file.
test "GAP-0880 upload ingestion stores payload bytes and registers durably" {
    const allocator = testing.allocator;
    defer resetGlobalStorage(allocator);

    const data_dir = try makeTempDir(allocator, "updata");
    defer cleanupTempDir(allocator, data_dir);
    try initAdapterForDir(allocator, data_dir);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    store.data_dir = data_dir;
    const seed = try seedGraph(&store);

    // Produce a real backup artifact (source side).
    const src_backup_dir = try makeTempDir(allocator, "upsrc");
    defer cleanupTempDir(allocator, src_backup_dir);
    var src_mgr = try backup.BackupManager.init(allocator, src_backup_dir, .{ .compression = .gzip }, &store);
    defer src_mgr.deinit();
    const src_meta = try src_mgr.createFullBackup();

    const src_path = try std.fmt.allocPrint(allocator, "{s}/full_{x}.backup", .{ src_backup_dir, src_meta.backup_id });
    defer allocator.free(src_path);
    const upload_bytes = try readFileAlloc(allocator, src_path);
    defer allocator.free(upload_bytes);
    try testing.expect(upload_bytes.len > 0);

    // Ingest into a separate server-side backup dir (what the QUIC/gRPC
    // upload handlers now do), passing the client-asserted checksum from
    // the original BackupResponse.
    const dst_backup_dir = try makeTempDir(allocator, "updst");
    defer cleanupTempDir(allocator, dst_backup_dir);
    var dst_mgr = try backup.BackupManager.init(allocator, dst_backup_dir, .{}, &store);
    defer dst_mgr.deinit();

    const ingested = try dst_mgr.ingestUploadedBackup(upload_bytes, src_meta.checksum);
    try testing.expectEqual(upload_bytes.len, @as(usize, @intCast(ingested.size_bytes)));
    try testing.expectEqual(src_meta.checksum, ingested.checksum);
    try testing.expectEqual(backup.CompressionType.gzip, ingested.compression);

    // The file on disk contains the payload bytes — NOT an empty placeholder.
    const dst_path = try std.fmt.allocPrint(allocator, "{s}/full_{x}.backup", .{ dst_backup_dir, ingested.backup_id });
    defer allocator.free(dst_path);
    const stored_bytes = try readFileAlloc(allocator, dst_path);
    defer allocator.free(stored_bytes);
    try testing.expectEqualSlices(u8, upload_bytes, stored_bytes);

    // Durable registration: a FRESH manager over the same dir finds the
    // backup in the persisted metadata log and can restore from it.
    var fresh_mgr = try backup.BackupManager.init(allocator, dst_backup_dir, .{}, &store);
    defer fresh_mgr.deinit();
    const entries = try fresh_mgr.loadMetadata();
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(ingested.backup_id, entries[0].backup_id);
    try testing.expectEqual(ingested.checksum, entries[0].checksum);

    const restore_dir = try makeTempDir(allocator, "uprestore");
    defer cleanupTempDir(allocator, restore_dir);
    try fresh_mgr.restoreToPointInTime(restore_dir, ingested.timestamp + 1);

    try initAdapterForDir(allocator, restore_dir);
    var restored = try graph_store.GraphStore.init(allocator);
    defer restored.deinit();
    restored.data_dir = restore_dir;
    try restored.loadFromFile();
    // Counted through the hydrating reads: the restored store is cold, its
    // resident `nodes`/`edges` caches empty until first access (SONNY-6277).
    try testing.expectEqual(@as(usize, 2), restored.getNodeCount());
    try testing.expectEqual(@as(usize, 1), restored.getEdgeCount());
    const name = restored.getNodeProperty(seed.alice, "name") orelse return error.NodePropertyMissing;
    try testing.expectEqualStrings("Alice", name.String);
}

// Rejection paths: nothing may be written or registered for bad uploads.
test "GAP-0880 upload ingestion rejects invalid payloads" {
    const allocator = testing.allocator;
    defer resetGlobalStorage(allocator);

    const data_dir = try makeTempDir(allocator, "rjdata");
    defer cleanupTempDir(allocator, data_dir);
    try initAdapterForDir(allocator, data_dir);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    store.data_dir = data_dir;
    _ = try seedGraph(&store);

    const src_backup_dir = try makeTempDir(allocator, "rjsrc");
    defer cleanupTempDir(allocator, src_backup_dir);
    var src_mgr = try backup.BackupManager.init(allocator, src_backup_dir, .{}, &store);
    defer src_mgr.deinit();
    const src_meta = try src_mgr.createFullBackup();
    const src_path = try std.fmt.allocPrint(allocator, "{s}/full_{x}.backup", .{ src_backup_dir, src_meta.backup_id });
    defer allocator.free(src_path);
    const good_bytes = try readFileAlloc(allocator, src_path);
    defer allocator.free(good_bytes);

    const dst_backup_dir = try makeTempDir(allocator, "rjdst");
    defer cleanupTempDir(allocator, dst_backup_dir);
    var dst_mgr = try backup.BackupManager.init(allocator, dst_backup_dir, .{}, &store);
    defer dst_mgr.deinit();

    // Empty payload.
    try testing.expectError(error.InvalidBackupFile, dst_mgr.ingestUploadedBackup(&.{}, null));

    // Garbage bytes (no magic).
    const garbage = [_]u8{0xAB} ** 128;
    try testing.expectError(error.InvalidBackupFile, dst_mgr.ingestUploadedBackup(&garbage, null));

    // Truncated artifact (header claims more payload than present).
    try testing.expectError(error.InvalidBackupFile, dst_mgr.ingestUploadedBackup(good_bytes[0 .. good_bytes.len - 1], null));

    // Client-asserted checksum mismatch.
    try testing.expectError(error.BackupChecksumMismatch, dst_mgr.ingestUploadedBackup(good_bytes, src_meta.checksum +% 1));

    // Corrupted payload byte: CRC32 verification must reject it.
    const corrupted = try allocator.dupe(u8, good_bytes);
    defer allocator.free(corrupted);
    corrupted[@sizeOf(backup.BackupHeader) + 4] ^= 0xFF;
    try testing.expectError(error.BackupChecksumMismatch, dst_mgr.ingestUploadedBackup(corrupted, null));

    // None of the rejections may have written a backup file or registered
    // anything in the metadata log.
    const entries = dst_mgr.loadMetadata() catch &.{};
    try testing.expectEqual(@as(usize, 0), entries.len);
}

// ---------------------------------------------------------------------------
// Wire schema
// ---------------------------------------------------------------------------

// The UploadBackupRequest now carries the artifact bytes (field 4). Lock the
// wire contract with an encode/decode round-trip including a binary payload.
test "GAP-0880 UploadBackupRequest payload field round-trips on the wire" {
    const allocator = testing.allocator;

    const payload_bytes = [_]u8{ 0x42, 0x47, 0x45, 0x4F, 0x00, 0xFF, 0x1f, 0x8b, 0x00 };
    var req = schema.UploadBackupRequest{
        .size_bytes = payload_bytes.len,
        .checksum = try allocator.dupe(u8, "deadbeef"),
        .session_id = try allocator.dupe(u8, "sess-1"),
        .payload = try allocator.dupe(u8, &payload_bytes),
    };
    defer req.deinit(allocator);

    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, req);

    var reader: std.Io.Reader = .fixed(aw.writer.buffer[0..aw.writer.end]);
    var decoded = try protobuf.decode(schema.UploadBackupRequest, &reader, allocator);
    defer decoded.deinit(allocator);

    try testing.expectEqual(@as(u64, payload_bytes.len), decoded.size_bytes);
    try testing.expectEqualStrings("deadbeef", decoded.checksum);
    try testing.expectEqualStrings("sess-1", decoded.session_id);
    try testing.expectEqualSlices(u8, &payload_bytes, decoded.payload);
}
