const std = @import("std");
const hnsw = @import("hnsw");
const tde = @import("tde");

// CANARY: REQ=REQ-TDE-FILELEVEL-001; FEATURE="TDEFileLevelEncryption"; ASPECT=HNSWIndex; STATUS=TESTED; OWNER=security; UPDATED=2026-04-01

pub fn saveSnapshot(index: *const hnsw.Hnsw, snapshot_path: []const u8, vec_path: []const u8) !void {
    _ = vec_path;

    var buffer = try std.ArrayList(u8).initCapacity(index.allocator, 4096);
    defer buffer.deinit(index.allocator);

    try hnsw.persist.save(index, buffer.writer(index.allocator));
    try tde.writeEncryptedFile(index.allocator, snapshot_path, buffer.items);
}

pub fn loadSnapshot(allocator: std.mem.Allocator, snapshot_path: []const u8, vec_path: []const u8) !hnsw.Hnsw {
    _ = vec_path;

    const data = try tde.readDecryptedFile(allocator, snapshot_path);
    defer allocator.free(data);

    var stream = std.io.fixedBufferStream(data);
    return try hnsw.persist.load(allocator, stream.reader());
}
