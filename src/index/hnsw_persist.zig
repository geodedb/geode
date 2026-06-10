const std = @import("std");
const hnsw = @import("hnsw");
const tde = @import("tde");

// CANARY: REQ=REQ-TDE-FILELEVEL-001; FEATURE="TDEFileLevelEncryption"; ASPECT=HNSWIndex; STATUS=TESTED; OWNER=security; UPDATED=2026-04-01

pub fn saveSnapshot(index: *const hnsw.Hnsw, snapshot_path: []const u8, vec_path: []const u8) !void {
    _ = vec_path;

    // Zig 0.16: ArrayList.writer removed; hnsw.persist.save takes *std.Io.Writer.
    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(index.allocator, 4096);
    defer aw.deinit();

    try hnsw.persist.save(index, &aw.writer);
    try tde.writeEncryptedFile(index.allocator, snapshot_path, aw.written());
}

pub fn loadSnapshot(allocator: std.mem.Allocator, snapshot_path: []const u8, vec_path: []const u8) !hnsw.Hnsw {
    _ = vec_path;

    const data = try tde.readDecryptedFile(allocator, snapshot_path);
    defer allocator.free(data);

    // Zig 0.16: fixedBufferStream removed; hnsw.persist.load takes *std.Io.Reader.
    var reader: std.Io.Reader = .fixed(data);
    return try hnsw.persist.load(allocator, &reader);
}
