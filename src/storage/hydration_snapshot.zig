// SPDX-License-Identifier: Apache-2.0
// Copyright 2024-2026 CodePros
//
// GAP-ENT-0023 P3: per-graph, counter-gated snapshots of geode's loop2
// hydration products (introspection counters, label-index postings, merge
// property index), so first-access hydration after a warm reopen is
// O(snapshot) instead of the O(graph) engine scan in
// loadOneGraphFromAdapterFull.
//
// This module is the FORMAT layer only: a common 40-byte header, an atomic
// (tmp + fsync + rename) streaming writer with an incremental payload CRC32,
// and an mmap-backed loader + cursor. The per-product payload layouts and the
// resident-structure traversal live in graph_store.zig — the products are
// GraphStore internals.
//
// Crash-safety / staleness discipline (mirrors the IdMap snapshot,
// src/storage/id_map.zig): every file is stamped with the engine's per-graph
// manifest counter at FULL-checkpoint time; a loader accepts the file IFF the
// stored counter matches the engine's current counter (the caller compares —
// this module only surfaces the stored value). Any structural damage (bad
// magic/version, torn length, header or payload CRC mismatch) loads as null
// and the caller falls back to the scan-rebuild. NOTHING in this module ever
// "repairs" a file: reject-and-rescan is always the safe direction.

const std = @import("std");

/// Fixed header layout (little-endian):
///   off  0: magic            [8]u8
///   off  8: version          u32
///   off 12: reserved/flags   u32 (always 0 for now)
///   off 16: manifest_counter u64 (engine per-graph counter at write time)
///   off 24: payload_len      u64
///   off 32: payload_crc      u32 (CRC32 over the payload bytes only)
///   off 36: header_crc       u32 (CRC32 over bytes [0..36))
pub const HEADER_SIZE: usize = 40;

const Crc32 = std.hash.crc.Crc32;

fn ioNow() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn writeHeader(
    buf: *[HEADER_SIZE]u8,
    magic: [8]u8,
    version: u32,
    manifest_counter: u64,
    payload_len: u64,
    payload_crc: u32,
) void {
    @memcpy(buf[0..8], &magic);
    std.mem.writeInt(u32, buf[8..12], version, .little);
    std.mem.writeInt(u32, buf[12..16], 0, .little);
    std.mem.writeInt(u64, buf[16..24], manifest_counter, .little);
    std.mem.writeInt(u64, buf[24..32], payload_len, .little);
    std.mem.writeInt(u32, buf[32..36], payload_crc, .little);
    const hcrc = Crc32.hash(buf[0..36]);
    std.mem.writeInt(u32, buf[36..40], hcrc, .little);
}

/// Streaming snapshot writer: payload bytes are appended (buffered, with an
/// incremental CRC32) at offsets past the header; `finish` writes the header
/// (with the final payload length + CRC), fsyncs the temp file, and renames it
/// over the final name so a reader only ever sees a complete file. `abort`
/// (or an error mid-write) leaves at most a stale `.tmp` that the next save
/// overwrites and `deleteFiles` clears.
pub const AtomicWriter = struct {
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    file: std.Io.File,
    tmp_name: []const u8,
    final_name: []const u8,
    magic: [8]u8,
    buf: []u8,
    buf_len: usize = 0,
    payload_len: u64 = 0,
    crc: Crc32,
    finished: bool = false,

    const BUF_CAP: usize = 1 << 20; // 1 MiB flush granularity

    pub fn init(
        allocator: std.mem.Allocator,
        dir: std.Io.Dir,
        tmp_name: []const u8,
        final_name: []const u8,
        magic: [8]u8,
    ) !AtomicWriter {
        const io = ioNow();
        const buf = try allocator.alloc(u8, BUF_CAP);
        errdefer allocator.free(buf);
        const file = try dir.createFile(io, tmp_name, .{});
        return .{
            .allocator = allocator,
            .dir = dir,
            .file = file,
            .tmp_name = tmp_name,
            .final_name = final_name,
            .magic = magic,
            .buf = buf,
            .crc = Crc32.init(),
        };
    }

    fn flush(self: *AtomicWriter) !void {
        if (self.buf_len == 0) return;
        const io = ioNow();
        const off: u64 = @as(u64, HEADER_SIZE) + self.payload_len;
        try self.file.writePositionalAll(io, self.buf[0..self.buf_len], off);
        self.payload_len += self.buf_len;
        self.buf_len = 0;
    }

    pub fn writeAll(self: *AtomicWriter, bytes: []const u8) !void {
        self.crc.update(bytes);
        var rest = bytes;
        while (rest.len > 0) {
            const room = self.buf.len - self.buf_len;
            const take = @min(room, rest.len);
            @memcpy(self.buf[self.buf_len..][0..take], rest[0..take]);
            self.buf_len += take;
            rest = rest[take..];
            if (self.buf_len == self.buf.len) try self.flush();
        }
    }

    pub fn writeInt(self: *AtomicWriter, comptime T: type, value: T) !void {
        var tmp: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(T, &tmp, value, .little);
        try self.writeAll(&tmp);
    }

    /// Length-prefixed byte string (u32 length + bytes).
    pub fn writeBytes(self: *AtomicWriter, bytes: []const u8) !void {
        try self.writeInt(u32, @intCast(bytes.len));
        try self.writeAll(bytes);
    }

    /// Flush the payload, stamp the header, fsync, and atomically publish.
    /// The writer is consumed either way (buffers freed).
    pub fn finish(self: *AtomicWriter, version: u32, manifest_counter: u64) !void {
        std.debug.assert(!self.finished);
        const io = ioNow();
        errdefer {
            self.file.close(io);
            self.dir.deleteFile(io, self.tmp_name) catch {};
            self.allocator.free(self.buf);
            self.finished = true;
        }
        try self.flush();
        var hdr: [HEADER_SIZE]u8 = undefined;
        writeHeader(&hdr, self.magic, version, manifest_counter, self.payload_len, self.crc.final());
        try self.file.writePositionalAll(io, &hdr, 0);
        try self.file.sync(io);
        self.file.close(io);
        try self.dir.rename(self.tmp_name, self.dir, self.final_name, io);
        self.allocator.free(self.buf);
        self.finished = true;
    }

    /// Discard: close + delete the temp file. Safe to call after a failed
    /// write; must not be called after a successful finish.
    pub fn abort(self: *AtomicWriter) void {
        if (self.finished) return;
        const io = ioNow();
        self.file.close(io);
        self.dir.deleteFile(io, self.tmp_name) catch {};
        self.allocator.free(self.buf);
        self.finished = true;
    }
};

/// A successfully validated, mmap-backed snapshot. `payload` borrows from
/// `mapping`; call `deinit` to unmap when the payload has been consumed.
pub const Loaded = struct {
    mapping: []align(std.heap.page_size_min) const u8,
    manifest_counter: u64,
    payload: []const u8,

    pub fn deinit(self: *Loaded) void {
        std.posix.munmap(self.mapping);
        self.* = undefined;
    }
};

/// Load + structurally validate a snapshot file. Returns null (caller falls
/// back to the scan) when the file is absent, wrong magic/version, torn, or
/// fails either CRC. The MANIFEST-COUNTER gate is the caller's job: compare
/// `Loaded.manifest_counter` against the engine's current per-graph counter
/// and reject on any mismatch.
pub fn load(dir: std.Io.Dir, name: []const u8, magic: [8]u8, version: u32) ?Loaded {
    const io = ioNow();
    const file = dir.openFile(io, name, .{}) catch return null;

    const len_u64 = file.length(io) catch {
        file.close(io);
        return null;
    };
    if (len_u64 < HEADER_SIZE) {
        file.close(io);
        return null;
    }
    const len: usize = std.math.cast(usize, len_u64) orelse {
        file.close(io);
        return null;
    };

    const mapping = std.posix.mmap(
        null,
        len,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    ) catch {
        file.close(io);
        return null;
    };
    // The mapping survives closing the fd.
    file.close(io);

    // Sequential parse + one CRC pass: hint readahead.
    std.posix.madvise(mapping.ptr, mapping.len, std.posix.MADV.SEQUENTIAL) catch {};

    if (!std.mem.eql(u8, mapping[0..8], &magic)) {
        std.posix.munmap(mapping);
        return null;
    }
    if (std.mem.readInt(u32, mapping[8..12], .little) != version) {
        std.posix.munmap(mapping);
        return null;
    }
    const stored_hcrc = std.mem.readInt(u32, mapping[36..40], .little);
    if (Crc32.hash(mapping[0..36]) != stored_hcrc) {
        std.posix.munmap(mapping);
        return null;
    }
    const manifest_counter = std.mem.readInt(u64, mapping[16..24], .little);
    const payload_len_u64 = std.mem.readInt(u64, mapping[24..32], .little);
    const payload_len = std.math.cast(usize, payload_len_u64) orelse {
        std.posix.munmap(mapping);
        return null;
    };
    if (len != HEADER_SIZE + payload_len) {
        std.posix.munmap(mapping);
        return null;
    }
    const payload = mapping[HEADER_SIZE..][0..payload_len];
    const stored_pcrc = std.mem.readInt(u32, mapping[32..36], .little);
    if (Crc32.hash(payload) != stored_pcrc) {
        std.posix.munmap(mapping);
        return null;
    }

    return .{
        .mapping = mapping,
        .manifest_counter = manifest_counter,
        .payload = payload,
    };
}

/// Best-effort removal of a snapshot file (and a leftover temp). Missing files
/// are success. Used by the checkpoint gate to INVALIDATE stale snapshots for
/// a deferred-never-hydrated graph — persisting that graph's EMPTY resident
/// structures instead would freeze the graph empty on every future open (the
/// 9b2d42eb hazard class).
pub fn deleteFiles(dir: std.Io.Dir, final_name: []const u8, tmp_name: []const u8) void {
    const io = ioNow();
    dir.deleteFile(io, final_name) catch {};
    dir.deleteFile(io, tmp_name) catch {};
}

/// Bounds-checked little-endian payload reader. Any overrun surfaces as
/// error.SnapshotTruncated — the caller treats the file as invalid and falls
/// back to the scan (belt-and-braces on top of the CRC).
pub const Cursor = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn readInt(self: *Cursor, comptime T: type) !T {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        if (self.buf.len - self.pos < n) return error.SnapshotTruncated;
        const v = std.mem.readInt(T, self.buf[self.pos..][0..n], .little);
        self.pos += n;
        return v;
    }

    pub fn readSlice(self: *Cursor, len: usize) ![]const u8 {
        if (self.buf.len - self.pos < len) return error.SnapshotTruncated;
        const s = self.buf[self.pos..][0..len];
        self.pos += len;
        return s;
    }

    /// Length-prefixed byte string (u32 length + bytes), the writeBytes dual.
    pub fn readBytes(self: *Cursor) ![]const u8 {
        const len = try self.readInt(u32);
        return self.readSlice(len);
    }

    pub fn remaining(self: *const Cursor) usize {
        return self.buf.len - self.pos;
    }
};

// ---------------------------------------------------------------------------
// Unit tests (format-level): round-trip, counter surfacing, corruption gates.
// ---------------------------------------------------------------------------

const TEST_MAGIC: [8]u8 = "GHYDTST1".*;

test "hydration snapshot: atomic write + load round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;

    var w = try AtomicWriter.init(a, tmp.dir, "t.snap.tmp", "t.snap", TEST_MAGIC);
    errdefer w.abort();
    try w.writeInt(u64, 42);
    try w.writeBytes("hello-label");
    // Force multiple flushes: > 2 MiB of patterned payload.
    var block: [4096]u8 = undefined;
    for (&block, 0..) |*b, i| b.* = @truncate(i);
    var k: usize = 0;
    while (k < 600) : (k += 1) try w.writeAll(&block);
    try w.finish(7, 0xABCDEF);

    var loaded = load(tmp.dir, "t.snap", TEST_MAGIC, 7) orelse return error.LoadFailed;
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u64, 0xABCDEF), loaded.manifest_counter);

    var cur = Cursor{ .buf = loaded.payload };
    try std.testing.expectEqual(@as(u64, 42), try cur.readInt(u64));
    try std.testing.expectEqualStrings("hello-label", try cur.readBytes());
    try std.testing.expectEqual(@as(usize, 600 * 4096), cur.remaining());
    const first = try cur.readSlice(4096);
    try std.testing.expectEqualSlices(u8, &block, first);
}

test "hydration snapshot: absent / wrong-magic / wrong-version load as null" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;

    try std.testing.expect(load(tmp.dir, "missing.snap", TEST_MAGIC, 1) == null);

    var w = try AtomicWriter.init(a, tmp.dir, "v.snap.tmp", "v.snap", TEST_MAGIC);
    errdefer w.abort();
    try w.writeInt(u32, 99);
    try w.finish(3, 5);

    try std.testing.expect(load(tmp.dir, "v.snap", TEST_MAGIC, 4) == null); // version mismatch
    try std.testing.expect(load(tmp.dir, "v.snap", "WRONGMAG".*, 3) == null); // magic mismatch
    try std.testing.expect(load(tmp.dir, "v.snap", TEST_MAGIC, 3) != null);
    var ok = load(tmp.dir, "v.snap", TEST_MAGIC, 3).?;
    ok.deinit();
}

test "hydration snapshot: torn payload and corrupt byte are rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = ioNow();

    var w = try AtomicWriter.init(a, tmp.dir, "c.snap.tmp", "c.snap", TEST_MAGIC);
    errdefer w.abort();
    var i: u64 = 0;
    while (i < 1000) : (i += 1) try w.writeInt(u64, i);
    try w.finish(1, 11);

    // Corrupt one payload byte -> payload CRC must reject.
    {
        const f = try tmp.dir.openFile(io, "c.snap", .{ .mode = .read_write });
        var b: [1]u8 = undefined;
        _ = try f.readPositionalAll(io, &b, HEADER_SIZE + 123);
        b[0] ^= 0xFF;
        try f.writePositionalAll(io, &b, HEADER_SIZE + 123);
        f.close(io);
        try std.testing.expect(load(tmp.dir, "c.snap", TEST_MAGIC, 1) == null);
        // Undo.
        const f2 = try tmp.dir.openFile(io, "c.snap", .{ .mode = .read_write });
        b[0] ^= 0xFF;
        try f2.writePositionalAll(io, &b, HEADER_SIZE + 123);
        f2.close(io);
        var ok = load(tmp.dir, "c.snap", TEST_MAGIC, 1) orelse return error.LoadFailed;
        ok.deinit();
    }

    // Truncate (torn tail) -> length gate must reject.
    {
        const f = try tmp.dir.openFile(io, "c.snap", .{ .mode = .read_write });
        try f.setLength(io, HEADER_SIZE + 1000 * 8 - 3);
        f.close(io);
        try std.testing.expect(load(tmp.dir, "c.snap", TEST_MAGIC, 1) == null);
    }

    // deleteFiles is idempotent and clears the final file.
    deleteFiles(tmp.dir, "c.snap", "c.snap.tmp");
    deleteFiles(tmp.dir, "c.snap", "c.snap.tmp");
    try std.testing.expect(load(tmp.dir, "c.snap", TEST_MAGIC, 1) == null);
}

test "hydration snapshot: cursor overrun surfaces SnapshotTruncated" {
    var buf: [12]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], 5, .little);
    std.mem.writeInt(u32, buf[8..12], 100, .little); // claims 100 bytes; none follow
    var cur = Cursor{ .buf = &buf };
    _ = try cur.readInt(u64);
    try std.testing.expectError(error.SnapshotTruncated, cur.readBytes());
}
