//! SONNY-6636 (1): the durable intent of a graph restore
//! (`StorageAdapter.beginGraphRestore`).
//!
//! A restored graph keeps the uuid its files were written under (graph-storage
//! binds a graph's uuid into its manifest, WAL header, shard uuids and, under
//! at-rest encryption, its keys), so it is staged at `<data_dir>/<uuid>.restore`
//! and renamed into `<data_dir>/<uuid>` once committed. The intent names each
//! graph, the uuid it had (if any) and the uuid it is restored under. It is
//! written (fsynced, renamed, directory fsynced) before anything is staged,
//! rewritten with `committed` set as the commit point, and removed last.
//! `StorageAdapter.init` reads it before any graph opens: not committed, the
//! staged directories are deleted (the old graphs stay); committed, the swap
//! is finished (renames, registry, old directories deleted).
//!
//! It names graphs, so under at-rest encryption it is sealed under the data
//! directory's cipher, as the graph registry is. A uuid only ever becomes a
//! hex directory name, and a name is only a registry key: nothing read from
//! the file reaches a path unescaped.
//!
//! Layout (before sealing): magic "GEODRIN2" | committed u8 | count u32 |
//! per graph: name_len u16 | name | has_old u8 | old [16]u8 | new [16]u8 |
//! then crc32 u32 over everything before it (little-endian).

const std = @import("std");
const gs = @import("graph_storage");

pub const file_name = "graph_restore.intent";
/// A staged graph's directory: `<data_dir>/<uuid hex>` + this.
pub const staged_suffix = ".restore";
/// A live directory renamed aside for a graph restored under its own uuid.
pub const aside_suffix = ".old";
const magic = "GEODRIN2";
/// More graphs than any data directory holds; bounds a damaged count.
pub const max_graphs: u32 = 1 << 16;
const max_file_bytes: usize = 64 << 20;

pub const Entry = struct {
    name: []const u8,
    /// The graph's uuid before the restore; null for a graph new here.
    old: ?[16]u8,
    /// The uuid it is restored under (its files').
    new: [16]u8,
};

pub const Intent = struct {
    committed: bool,
    entries: []const Entry,
};

/// An intent read from disk; `deinit` frees it.
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    intent: Intent,

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
    }
};

pub const Error = error{ CorruptGraphRestoreIntent, TooManyGraphs, NameTooLong };

pub fn encode(allocator: std.mem.Allocator, intent: Intent) ![]u8 {
    if (intent.entries.len > max_graphs) return Error.TooManyGraphs;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, magic);
    try buf.append(allocator, @intFromBool(intent.committed));
    var n4: [4]u8 = undefined;
    std.mem.writeInt(u32, &n4, @intCast(intent.entries.len), .little);
    try buf.appendSlice(allocator, &n4);
    for (intent.entries) |e| {
        if (e.name.len == 0 or e.name.len > std.math.maxInt(u16)) return Error.NameTooLong;
        var n2: [2]u8 = undefined;
        std.mem.writeInt(u16, &n2, @intCast(e.name.len), .little);
        try buf.appendSlice(allocator, &n2);
        try buf.appendSlice(allocator, e.name);
        try buf.append(allocator, @intFromBool(e.old != null));
        try buf.appendSlice(allocator, &(e.old orelse [_]u8{0} ** 16));
        try buf.appendSlice(allocator, &e.new);
    }
    std.mem.writeInt(u32, &n4, std.hash.Crc32.hash(buf.items), .little);
    try buf.appendSlice(allocator, &n4);
    return buf.toOwnedSlice(allocator);
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Owned {
    const bad = Error.CorruptGraphRestoreIntent;
    if (bytes.len < magic.len + 5 + 4 or !std.mem.eql(u8, bytes[0..magic.len], magic)) return bad;
    const body = bytes[0 .. bytes.len - 4];
    if (std.hash.Crc32.hash(body) != std.mem.readInt(u32, bytes[bytes.len - 4 ..][0..4], .little)) return bad;
    if (body[magic.len] > 1) return bad;
    const count = std.mem.readInt(u32, body[magic.len + 1 ..][0..4], .little);
    if (count > max_graphs) return bad;
    var owned: Owned = .{ .arena = .init(allocator), .intent = undefined };
    errdefer owned.arena.deinit();
    const a = owned.arena.allocator();
    const entries = try a.alloc(Entry, count);
    var pos: usize = magic.len + 5;
    for (entries) |*e| {
        if (body.len - pos < 2) return bad;
        const len = std.mem.readInt(u16, body[pos..][0..2], .little);
        pos += 2;
        if (len == 0 or body.len - pos < @as(usize, len) + 33) return bad;
        e.name = try a.dupe(u8, body[pos..][0..len]);
        pos += len;
        const has_old = body[pos];
        if (has_old > 1) return bad;
        e.old = if (has_old == 1) body[pos + 1 ..][0..16].* else null;
        e.new = body[pos + 17 ..][0..16].*;
        pos += 33;
    }
    if (pos != body.len) return bad;
    owned.intent = .{ .committed = body[magic.len] == 1, .entries = entries };
    return owned;
}

fn pathIn(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, file_name });
}

/// fsync `dir_path` itself, so a rename or unlink in it survives power loss
/// (`.iterate = true`: a real descriptor; an O_PATH one cannot fsync).
pub fn syncDir(dir_path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    const f = std.Io.File{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try f.sync(io);
}

/// Write the intent durably (sealed under `cipher` when there is one): a
/// temporary file, fsynced, renamed over the intent, the directory fsynced.
pub fn write(allocator: std.mem.Allocator, data_dir: []const u8, cipher: ?*const gs.side_file_crypto.Cipher, kind: gs.side_file_crypto.Kind, intent: Intent) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const plain = try encode(allocator, intent);
    defer {
        std.crypto.secureZero(u8, plain);
        allocator.free(plain);
    }
    const disk = try gs.side_file_crypto.encode(allocator, cipher, kind, file_name, plain);
    defer allocator.free(disk);
    const path = try pathIn(allocator, data_dir);
    defer allocator.free(path);
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp);
    {
        const f = try std.Io.Dir.cwd().createFile(io, tmp, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer f.close(io);
        try f.writeStreamingAll(io, disk);
        try f.sync(io);
    }
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, io);
    try syncDir(data_dir);
}

/// The intent in `data_dir`, or null when there is none. A damaged one (or
/// a plaintext one under a cipher) is an error: the caller refuses to open
/// rather than guess which directories are live.
pub fn read(allocator: std.mem.Allocator, data_dir: []const u8, cipher: ?*const gs.side_file_crypto.Cipher, kind: gs.side_file_crypto.Kind) !?Owned {
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try pathIn(allocator, data_dir);
    defer allocator.free(path);
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.StreamTooLong => return Error.CorruptGraphRestoreIntent,
        else => return err,
    };
    const decoded = gs.side_file_crypto.decode(allocator, .{ .cipher = cipher, .require_sealed = cipher != null }, kind, file_name, raw) catch |err| switch (err) {
        error.OutOfMemory, error.SideFileEncrypted => return err,
        else => return Error.CorruptGraphRestoreIntent,
    };
    defer {
        std.crypto.secureZero(u8, decoded.bytes);
        allocator.free(decoded.bytes);
    }
    return try decode(allocator, decoded.bytes);
}

/// Remove the intent durably (a missing one is fine).
pub fn remove(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try pathIn(allocator, data_dir);
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try syncDir(data_dir);
}
