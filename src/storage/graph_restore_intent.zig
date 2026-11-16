//! SONNY-6636 (1): the durable intent of a graph restore swap
//! (`StorageAdapter.swapInRestoredGraphs`).
//!
//! A restore writes each graph it restores into a new `<data_dir>/<uuid>`
//! directory and then commits by rewriting the graph registry to name the
//! new uuids. The intent lists every directory the swap may leave behind:
//! the ones it stages and the ones they replace. It is written (fsynced,
//! renamed, directory fsynced) before the first staged byte, and removed
//! last. `StorageAdapter.init` finishes an interrupted swap from it
//! (`recoverGraphRestoreLocked`): a listed directory the registry does not
//! name is deleted, so a crash before the registry commit leaves the old
//! graphs and one after it leaves the restored ones, never both nor a mix.
//!
//! The file holds uuids only (no graph names), so it is not sealed under
//! at-rest encryption, unlike the registry. A uuid is 16 raw bytes and is
//! only ever turned into a hex directory name: nothing read from the file
//! reaches a path unescaped.
//!
//! Layout: magic "GEODRIN1" | staged u32 | replaced u32 |
//! uuid [16]u8 * (staged + replaced) | crc32 u32 (all little-endian, the CRC
//! over everything before it).

const std = @import("std");

pub const file_name = "graph_restore.intent";
const magic = "GEODRIN1";
/// More graphs than any data directory holds; bounds a damaged count.
pub const max_uuids: u32 = 1 << 16;

pub const Intent = struct {
    /// Directories the swap writes (the restored graphs' new uuids).
    staged: []const [16]u8,
    /// Directories they replace (the graphs' uuids before the swap).
    replaced: []const [16]u8,
};

/// An intent read from disk; `deinit` frees it.
pub const Owned = struct {
    staged: [][16]u8,
    replaced: [][16]u8,

    pub fn deinit(self: Owned, allocator: std.mem.Allocator) void {
        allocator.free(self.staged);
        allocator.free(self.replaced);
    }
};

pub const Error = error{ CorruptGraphRestoreIntent, TooManyGraphs };

pub fn encode(allocator: std.mem.Allocator, intent: Intent) ![]u8 {
    if (intent.staged.len + intent.replaced.len > max_uuids) return Error.TooManyGraphs;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, magic);
    var n: [4]u8 = undefined;
    std.mem.writeInt(u32, &n, @intCast(intent.staged.len), .little);
    try buf.appendSlice(allocator, &n);
    std.mem.writeInt(u32, &n, @intCast(intent.replaced.len), .little);
    try buf.appendSlice(allocator, &n);
    for (intent.staged) |u| try buf.appendSlice(allocator, &u);
    for (intent.replaced) |u| try buf.appendSlice(allocator, &u);
    std.mem.writeInt(u32, &n, std.hash.Crc32.hash(buf.items), .little);
    try buf.appendSlice(allocator, &n);
    return buf.toOwnedSlice(allocator);
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Owned {
    const header = magic.len + 8;
    if (bytes.len < header + 4 or !std.mem.eql(u8, bytes[0..magic.len], magic)) return Error.CorruptGraphRestoreIntent;
    const body = bytes[0 .. bytes.len - 4];
    if (std.hash.Crc32.hash(body) != std.mem.readInt(u32, bytes[bytes.len - 4 ..][0..4], .little)) return Error.CorruptGraphRestoreIntent;
    const staged_n = std.mem.readInt(u32, bytes[magic.len..][0..4], .little);
    const replaced_n = std.mem.readInt(u32, bytes[magic.len + 4 ..][0..4], .little);
    if (@as(u64, staged_n) + replaced_n > max_uuids) return Error.CorruptGraphRestoreIntent;
    if (body.len != header + (@as(usize, staged_n) + replaced_n) * 16) return Error.CorruptGraphRestoreIntent;
    const staged = try allocator.alloc([16]u8, staged_n);
    errdefer allocator.free(staged);
    const replaced = try allocator.alloc([16]u8, replaced_n);
    var pos: usize = header;
    for (staged) |*u| {
        u.* = body[pos..][0..16].*;
        pos += 16;
    }
    for (replaced) |*u| {
        u.* = body[pos..][0..16].*;
        pos += 16;
    }
    return .{ .staged = staged, .replaced = replaced };
}

fn pathIn(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, file_name });
}

/// fsync `dir_path` itself, so a rename or unlink in it survives power loss
/// (`.iterate = true`: a real descriptor; an O_PATH one cannot fsync).
fn syncDir(dir_path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    const f = std.Io.File{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try f.sync(io);
}

/// Write the intent durably: a temporary file, fsynced, renamed over the
/// intent, then the data directory fsynced.
pub fn write(allocator: std.mem.Allocator, data_dir: []const u8, intent: Intent) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const bytes = try encode(allocator, intent);
    defer allocator.free(bytes);
    const path = try pathIn(allocator, data_dir);
    defer allocator.free(path);
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp);
    {
        const f = try std.Io.Dir.cwd().createFile(io, tmp, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer f.close(io);
        try f.writeStreamingAll(io, bytes);
        try f.sync(io);
    }
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, io);
    try syncDir(data_dir);
}

/// The intent in `data_dir`, or null when there is none. A damaged one is
/// `CorruptGraphRestoreIntent`: the caller refuses to open rather than guess
/// which directories are live.
pub fn read(allocator: std.mem.Allocator, data_dir: []const u8) !?Owned {
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = try pathIn(allocator, data_dir);
    defer allocator.free(path);
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(magic.len + 12 + max_uuids * 16)) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.StreamTooLong => return Error.CorruptGraphRestoreIntent,
        else => return err,
    };
    defer allocator.free(raw);
    return try decode(allocator, raw);
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
