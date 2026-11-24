//! The GEODBAK1 file archive: a data directory's (or some graphs') files,
//! byte for byte, in one buffer. Used by backups (`backup.zig`) and, per
//! graph, by Raft snapshots (SONNY-6636). It imports nothing of geode, so the
//! storage adapter and the Raft layer can use it without the import cycle
//! `backup.zig` (which imports `geode`) would make.
//!
//! Layout: magic "GEODBAK1" | version u32 | file_count u32 |
//! (name_len u32 | name | data_len u64 | data)*, little-endian. Names are
//! relative paths; a reader refuses any that could leave its directory.
//!
//! The archive is lossless by construction: it carries the storage engine's
//! own files (manifest, WAL, shards, side files, fulltext segments), so every
//! property value (an `ExtValue` too), label, edge, tenant tag and per-graph
//! index reaches the other side exactly as the engine wrote it.

const std = @import("std");
const builtin = @import("builtin");

pub const magic = "GEODBAK1";

/// The running process's data-directory lock: never data.
pub const lock_file_name = ".geode.lock";

/// SONNY-6322: the Ed25519 seed that signs an audit log (`<graph
/// uuid>/audit.jsonl.key`, or `audit.jsonl.key` beside the process-global
/// log): never archived, at any depth. Whoever read an archive could sign
/// forged audit entries with it.
pub const audit_seed_file_name = "audit.jsonl.key";

/// Whether a file at any depth stays out of an archive by its name.
pub fn isExcludedNestedFile(name: []const u8) bool {
    return std.mem.eql(u8, name, audit_seed_file_name);
}

/// Number of files and data bytes in an archive.
pub const ArchiveStats = struct {
    files: u32 = 0,
    bytes: u64 = 0,
};

pub const Error = error{ InvalidBackupFile, UnsafeArchiveEntryName };

/// An archive entry name is a relative path under the restore directory:
/// not empty, not absolute, no `.`/`..`/empty components, no backslash or
/// NUL. Anything else could write outside the target (SONNY-6280).
pub fn isSafeArchiveEntryName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '/') return false;
    if (std.mem.indexOfAny(u8, name, "\\\x00") != null) return false;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |component| {
        if (component.len == 0) return false;
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

pub const ArchiveEntry = struct {
    name: []const u8,
    data: []const u8,
};

pub const ArchiveIterator = struct {
    payload: []const u8,
    offset: usize = 16,
    remaining: u32,

    pub fn init(payload: []const u8) !ArchiveIterator {
        if (payload.len < 16) return error.InvalidBackupFile;
        if (!std.mem.eql(u8, payload[0..8], magic)) return error.InvalidBackupFile;
        // version (u32) at offset 8 — currently ignored.
        return .{ .payload = payload, .remaining = std.mem.readInt(u32, payload[12..16], .little) };
    }

    pub fn next(self: *ArchiveIterator) !?ArchiveEntry {
        if (self.remaining == 0) {
            if (self.offset != self.payload.len) return error.InvalidBackupFile;
            return null;
        }
        self.remaining -= 1;
        const p = self.payload;
        if (p.len - self.offset < 4) return error.InvalidBackupFile;
        const name_len = std.mem.readInt(u32, p[self.offset..][0..4], .little);
        self.offset += 4;
        if (p.len - self.offset < name_len) return error.InvalidBackupFile;
        const name = p[self.offset .. self.offset + name_len];
        self.offset += name_len;
        if (p.len - self.offset < 8) return error.InvalidBackupFile;
        const data_len = std.mem.readInt(u64, p[self.offset..][0..8], .little);
        self.offset += 8;
        if (data_len > p.len - self.offset) return error.InvalidBackupFile;
        const data_size: usize = @intCast(data_len);
        const data = p[self.offset .. self.offset + data_size];
        self.offset += data_size;
        return .{ .name = name, .data = data };
    }
};

/// Check a whole archive before anything is written: well-formed, no
/// trailing bytes, every entry name safe and unique.
pub fn validateArchive(allocator: std.mem.Allocator, payload: []const u8) !ArchiveStats {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var stats: ArchiveStats = .{};
    var it = try ArchiveIterator.init(payload);
    while (try it.next()) |entry| {
        if (!isSafeArchiveEntryName(entry.name)) return error.UnsafeArchiveEntryName;
        const gop = try seen.getOrPut(entry.name);
        if (gop.found_existing) return error.InvalidBackupFile;
        if (std.mem.eql(u8, entry.name, lock_file_name)) continue;
        stats.files += 1;
        stats.bytes += entry.data.len;
    }
    return stats;
}

/// An archive being written: `init`, `appendFile` / `appendTree`, then
/// `finish` (which patches the file count) or `deinit`.
pub const Builder = struct {
    buffer: std.ArrayList(u8) = .empty,
    files: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) !Builder {
        var b: Builder = .{};
        errdefer b.buffer.deinit(allocator);
        try b.buffer.appendSlice(allocator, magic);
        try b.buffer.appendSlice(allocator, &std.mem.toBytes(@as(u32, 1))); // version = 1
        try b.buffer.appendSlice(allocator, &std.mem.toBytes(@as(u32, 0))); // file count, patched
        return b;
    }

    pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
    }

    /// Append one entry with the given bytes.
    pub fn appendBytes(self: *Builder, allocator: std.mem.Allocator, archive_name: []const u8, data: []const u8) !void {
        try self.buffer.appendSlice(allocator, &std.mem.toBytes(@as(u32, @intCast(archive_name.len))));
        try self.buffer.appendSlice(allocator, archive_name);
        try self.buffer.appendSlice(allocator, &std.mem.toBytes(@as(u64, @intCast(data.len))));
        try self.buffer.appendSlice(allocator, data);
        self.files += 1;
    }

    /// Append the file at `file_path` as `archive_name`.
    pub fn appendFile(self: *Builder, allocator: std.mem.Allocator, file_path: []const u8, archive_name: []const u8) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
        defer file.close(io);
        const stat = try file.stat(io);
        const size: usize = @intCast(stat.size);
        const data = try allocator.alloc(u8, size);
        defer allocator.free(data);
        const n = try file.readPositionalAll(io, data, 0);
        if (n != size) return error.FileChangedWhileArchived;
        try self.appendBytes(allocator, archive_name, data);
    }

    /// Append every file under `root_path`, recursively, named
    /// `archive_prefix/<relative path>` (just the relative path for an empty
    /// prefix). A missing directory adds nothing. Never an audit signing
    /// seed (`isExcludedNestedFile`). Returns the number of files added.
    pub fn appendTree(self: *Builder, allocator: std.mem.Allocator, root_path: []const u8, archive_prefix: []const u8) !u32 {
        var count: u32 = 0;
        const io = std.Io.Threaded.global_single_threaded.io();
        var dir = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return 0;
            return err;
        };
        defer dir.close(io);

        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root_path, entry.name });
            defer allocator.free(full_path);
            const archive_name = if (archive_prefix.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ archive_prefix, entry.name });
            defer allocator.free(archive_name);

            switch (entry.kind) {
                .file => {
                    if (isExcludedNestedFile(entry.name)) continue;
                    try self.appendFile(allocator, full_path, archive_name);
                    count += 1;
                },
                .directory => count += try self.appendTree(allocator, full_path, archive_name),
                else => {},
            }
        }
        return count;
    }

    /// The archive; the builder is spent.
    pub fn finish(self: *Builder, allocator: std.mem.Allocator) ![]u8 {
        std.mem.writeInt(u32, self.buffer.items[12..16], self.files, .little);
        return self.buffer.toOwnedSlice(allocator);
    }
};

const file_perms: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else std.Io.File.Permissions.fromMode(0o600);

/// Write `payload`'s entries whose names start with `prefix` + "/" (every
/// entry for an empty prefix) into `dir`, the prefix stripped, recreating
/// subdirectories. The whole archive is validated first (names cannot escape
/// `dir`). Files are created 0600. A `.geode.lock` entry is never written.
///
/// With `durable`, everything written is on disk before this returns. On
/// Linux every file and every directory written (and `dir`'s parent, for
/// `dir`'s own entry) is fsynced once after all of them are written, on up
/// to `max_sync_workers` threads (SONNY-6956);
/// elsewhere each file as it is written. Returns the number of sync calls
/// made.
///
/// SONNY-6300: an fsync per file as it was written took over 10 s for a
/// tiny store's 700 files on a loaded disk, so the filesystem was synced
/// once instead (syncfs(2)). SONNY-6956: syncfs writes back every dirty page
/// of the filesystem, other processes' too, so a restore took as long as
/// the machine's other writers made it (5.6 s instead of 0.9 s with 7.6 GB
/// pending; past 120 s on loaded CI runners). Synced after the writes, the
/// files' journal commits batch, and in parallel 700 small files sync in
/// about 0.2 s, whatever else the filesystem holds.
pub fn writeTree(allocator: std.mem.Allocator, dir: []const u8, payload: []const u8, prefix: []const u8, durable: bool) !u32 {
    _ = try validateArchive(allocator, payload);

    const io = std.Io.Threaded.global_single_threaded.io();
    const sync_after = comptime builtin.os.tag == .linux;
    var syncs: u32 = 0;
    // SONNY-6956: what to sync once everything is written (Linux).
    var written: SyncSet = .{};
    defer written.deinit(allocator);
    if (durable and sync_after) {
        try written.addDir(allocator, dir);
        // `dir`'s own entry, as syncfs made it durable.
        if (std.fs.path.dirname(dir)) |parent| try written.addDir(allocator, parent);
    }
    var it = try ArchiveIterator.init(payload);
    while (try it.next()) |entry| {
        if (std.mem.eql(u8, entry.name, lock_file_name)) continue;
        const rel = stripPrefix(entry.name, prefix) orelse continue;
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, rel });
        defer allocator.free(full_path);

        if (std.mem.lastIndexOfScalar(u8, full_path, '/')) |last_slash| {
            // error-policy: A — ensure-parent-dirs is best-effort (the dir may
            // already exist); a real failure surfaces on the createFile below.
            std.Io.Dir.cwd().createDirPath(io, full_path[0..last_slash]) catch {};
        }

        const out = try std.Io.Dir.cwd().createFile(io, full_path, .{ .permissions = file_perms });
        defer out.close(io);
        try out.writeStreamingAll(io, entry.data);
        if (durable and !sync_after) {
            try out.sync(io);
            syncs += 1;
        }
        if (durable and sync_after) try written.addFile(allocator, dir, full_path);
    }
    if (durable and sync_after) syncs += try written.syncAll();
    return syncs;
}

/// SONNY-6956: the most threads a durable `writeTree` syncs on. fsync waits
/// on the disk, not the CPU, and concurrent fsyncs on one filesystem share
/// its journal commits: 700 small files took 3.5 s one after another, 0.9 s
/// on 8 threads and 0.2 s on 32.
pub const max_sync_workers: usize = 32;

/// SONNY-6956: the threads a durable `writeTree` syncs `paths` paths on.
pub fn durableSyncWorkers(paths: usize) usize {
    return @max(1, @min(paths, max_sync_workers));
}

/// SONNY-6956: the files and directories a durable `writeTree` wrote, synced
/// after all of them are written. Linux only.
const SyncSet = struct {
    files: std.ArrayList([:0]u8) = .empty,
    dirs: std.ArrayList([:0]u8) = .empty,
    seen_dirs: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(self: *SyncSet, allocator: std.mem.Allocator) void {
        for (self.files.items) |p| allocator.free(p);
        self.files.deinit(allocator);
        for (self.dirs.items) |p| allocator.free(p);
        self.dirs.deinit(allocator);
        self.seen_dirs.deinit(allocator);
    }

    fn addDir(self: *SyncSet, allocator: std.mem.Allocator, path: []const u8) !void {
        if (self.seen_dirs.contains(path)) return;
        try self.dirs.ensureUnusedCapacity(allocator, 1);
        try self.seen_dirs.ensureUnusedCapacity(allocator, 1);
        const owned = try allocator.dupeZ(u8, path);
        self.dirs.appendAssumeCapacity(owned);
        self.seen_dirs.putAssumeCapacityNoClobber(owned, {});
    }

    /// `full_path`, under `root`, and every directory between them: a new
    /// file's directory entry is durable once its directory is synced.
    fn addFile(self: *SyncSet, allocator: std.mem.Allocator, root: []const u8, full_path: []const u8) !void {
        try self.files.ensureUnusedCapacity(allocator, 1);
        self.files.appendAssumeCapacity(try allocator.dupeZ(u8, full_path));
        var parent = full_path;
        while (std.mem.lastIndexOfScalar(u8, parent, '/')) |slash| {
            parent = parent[0..slash];
            if (parent.len <= root.len) break;
            try self.addDir(allocator, parent);
        }
    }

    /// Syncs every file, then every directory; returns how many.
    fn syncAll(self: *SyncSet) !u32 {
        try syncPaths(self.files.items, false);
        try syncPaths(self.dirs.items, true);
        return @intCast(self.files.items.len + self.dirs.items.len);
    }
};

const SyncJob = struct {
    paths: []const [:0]u8,
    directory: bool,
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),

    fn run(self: *SyncJob) void {
        while (!self.failed.load(.acquire)) {
            const i = self.next.fetchAdd(1, .monotonic);
            if (i >= self.paths.len) return;
            if (!fsyncPath(self.paths[i], self.directory)) self.failed.store(true, .release);
        }
    }
};

fn fsyncPath(path: [:0]const u8, directory: bool) bool {
    const linux = std.os.linux;
    const rc = while (true) {
        const r = linux.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = directory }, 0);
        switch (linux.errno(r)) {
            .SUCCESS => break r,
            .INTR => continue,
            else => |e| {
                std.log.err("durable write: open {s} for fsync failed: {s}", .{ path, @tagName(e) });
                return false;
            },
        }
    };
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    while (true) switch (linux.errno(linux.fsync(fd))) {
        .SUCCESS => return true,
        .INTR => continue,
        else => |e| {
            std.log.err("durable write: fsync {s} failed: {s}", .{ path, @tagName(e) });
            return false;
        },
    };
}

/// fsync each of `paths` once, on `durableSyncWorkers` threads (this one
/// included); error.RestoreSyncFailed if any open or fsync failed.
fn syncPaths(paths: []const [:0]u8, directory: bool) !void {
    if (paths.len == 0) return;
    var job: SyncJob = .{ .paths = paths, .directory = directory };
    var threads: [max_sync_workers - 1]std.Thread = undefined;
    var spawned: usize = 0;
    const extra = durableSyncWorkers(paths.len) - 1;
    while (spawned < extra) : (spawned += 1) {
        // A thread that cannot start leaves its share to the others.
        threads[spawned] = std.Thread.spawn(.{}, SyncJob.run, .{&job}) catch break;
    }
    job.run();
    for (threads[0..spawned]) |t| t.join();
    if (job.failed.load(.acquire)) return error.RestoreSyncFailed;
}

/// `name` without `prefix` and its slash, or null when it is not under it
/// (the whole name for an empty prefix).
fn stripPrefix(name: []const u8, prefix: []const u8) ?[]const u8 {
    if (prefix.len == 0) return name;
    if (name.len <= prefix.len + 1 or name[prefix.len] != '/') return null;
    if (!std.mem.eql(u8, name[0..prefix.len], prefix)) return null;
    return name[prefix.len + 1 ..];
}

/// Re-read every file `payload` names (under `prefix`, as `writeTree`)
/// in `dir` and compare it byte for byte with the archive.
pub fn verifyTree(allocator: std.mem.Allocator, dir: []const u8, payload: []const u8, prefix: []const u8) !ArchiveStats {
    const io = std.Io.Threaded.global_single_threaded.io();
    var stats: ArchiveStats = .{};
    var it = try ArchiveIterator.init(payload);
    var buf: [64 * 1024]u8 = undefined;
    while (try it.next()) |entry| {
        if (std.mem.eql(u8, entry.name, lock_file_name)) continue;
        const rel = stripPrefix(entry.name, prefix) orelse continue;
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, rel });
        defer allocator.free(full_path);
        const f = try std.Io.Dir.cwd().openFile(io, full_path, .{ .mode = .read_only });
        defer f.close(io);
        if ((try f.stat(io)).size != entry.data.len) return error.RestoreVerificationFailed;
        var off: usize = 0;
        while (off < entry.data.len) {
            const want = @min(buf.len, entry.data.len - off);
            const n = try f.readPositionalAll(io, buf[0..want], off);
            if (n != want or !std.mem.eql(u8, buf[0..want], entry.data[off .. off + want])) return error.RestoreVerificationFailed;
            off += want;
        }
        stats.files += 1;
        stats.bytes += entry.data.len;
    }
    return stats;
}

test "graph_archive: a tree round-trips byte for byte, under a prefix too, and unsafe names are refused" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try tmp.dir.createDirPath(io, "src/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.bin", .data = "\x00\x01binary\xff" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sub/b", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sub/audit.jsonl.key", .data = "seed" });
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..cwd_len], &tmp.sub_path });
    defer a.free(root);
    const src = try std.fmt.allocPrint(a, "{s}/src", .{root});
    defer a.free(src);
    const dst = try std.fmt.allocPrint(a, "{s}/dst", .{root});
    defer a.free(dst);

    var b = try Builder.init(a);
    errdefer b.deinit(a);
    try std.testing.expectEqual(@as(u32, 2), try b.appendTree(a, src, "g"));
    try b.appendBytes(a, "other/x", "not g's");
    const payload = try b.finish(a);
    defer a.free(payload);

    try std.Io.Dir.cwd().createDirPath(io, dst);
    _ = try writeTree(a, dst, payload, "g", false);
    const stats = try verifyTree(a, dst, payload, "g");
    try std.testing.expectEqual(@as(u32, 2), stats.files);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "dst/x", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "dst/sub/audit.jsonl.key", .{}));

    var bad = try Builder.init(a);
    errdefer bad.deinit(a);
    try bad.appendBytes(a, "g/../escape", "x");
    const bad_payload = try bad.finish(a);
    defer a.free(bad_payload);
    try std.testing.expectError(error.UnsafeArchiveEntryName, validateArchive(a, bad_payload));
}
