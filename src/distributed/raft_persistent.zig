const std = @import("std");

// GAP-0889: std.log (dependency-free) so the standalone test root for this
// file does not need the geode logging module wired in build.zig.
const log = std.log.scoped(.raft_persistent);

// CANARY: REQ=REQ-GQL-RAFT-PERSIST; FEATURE="Raft Persistence"; ASPECT=CorePersistence; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-09
// CANARY: REQ=REQ-TDE-FILELEVEL-001; FEATURE="TDEFileLevelEncryption"; ASPECT=RaftState; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
//
// Persistent Raft node — compatibility wrapper around the external raft library's
// FileStorage. Preserves the existing geode API for cluster membership and state.

pub const RaftNode = struct {
    allocator: std.mem.Allocator,
    node_id: u32,
    storage_path: []const u8,
    state: State,
    current_term: u64,
    voted_for: ?u32,
    commit_index: u64,
    last_applied: u64,
    cluster: ClusterConfig,
    snapshot: ?Snapshot,

    pub const State = enum {
        follower,
        candidate,
        leader,
    };

    pub const ClusterConfig = struct {
        members: std.ArrayList(Member),
        pending_config: ?JointConfig = null,
    };

    pub const Member = struct {
        id: u32,
        address: []const u8,
        voting: bool = true,
    };

    pub const JointConfig = struct {
        old_members: []const Member,
        new_members: []const Member,
        phase: ConfigPhase,
    };

    pub const ConfigPhase = enum {
        joint,
        final_commit,
    };

    pub const Snapshot = struct {
        last_included_index: u64,
        last_included_term: u64,
        data: []const u8,
        checksum: u32,
    };

    pub const LogEntry = struct {
        term: u64,
        index: u64,
        entry_type: LogEntryType,
        data: []const u8,
    };

    pub const LogEntryType = enum {
        command,
        config_change,
        noop,
    };

    pub fn raftOpen(allocator: std.mem.Allocator, storage_path: []const u8) !*RaftNode {
        const node = try allocator.create(RaftNode);
        node.* = RaftNode{
            .allocator = allocator,
            .node_id = 0,
            .storage_path = storage_path,
            .state = .follower,
            .current_term = 0,
            .voted_for = null,
            .commit_index = 0,
            .last_applied = 0,
            .cluster = .{ .members = std.ArrayList(Member).empty },
            .snapshot = null,
        };

        // GAP-0889: load failures must not be silently ignored — a node that
        // boots with current_term=0 after persisting a higher term can vote
        // twice in the same term (raft safety violation). `loadPersistentState`
        // treats "no state yet" (missing dir/file) as a clean fresh start; any
        // other failure (unreadable or corrupt state) propagates.
        errdefer allocator.destroy(node);
        try node.loadPersistentState();

        return node;
    }

    pub fn deinit(self: *RaftNode) void {
        // GAP-0889: deinit cannot propagate, but a failed final save means the
        // persisted term is stale — say so instead of swallowing the error.
        self.savePersistentState() catch |err| {
            log.warn("raft persistent-state save failed on shutdown: {s} (path={s})", .{ @errorName(err), self.storage_path });
        };
        // Free snapshot data if it was allocated by createSnapshot
        if (self.snapshot) |snap| {
            if (snap.data.len > 0) {
                self.allocator.free(snap.data);
            }
        }
        self.cluster.members.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn raftAddMember(self: *RaftNode, id: u32, addr: []const u8) !void {
        try self.cluster.members.append(self.allocator, .{
            .id = id,
            .address = addr,
        });
    }

    pub fn raftRemoveMember(self: *RaftNode, id: u32) void {
        var i: usize = 0;
        while (i < self.cluster.members.items.len) {
            if (self.cluster.members.items[i].id == id) {
                _ = self.cluster.members.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Create a snapshot from pre-serialized graph store data.
    /// Pass `snapshot_data` and `checksum` from `raft_snapshot_manager.createSnapshotData`.
    /// Pass `null` for `snapshot_data` to create an empty snapshot (backward-compatible).
    // CANARY: REQ=REQ-GQL-RAFT-SNAPSHOT; FEATURE="Raft Snapshot Persistence"; ASPECT=CreateSnapshot; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-09
    pub fn createSnapshot(self: *RaftNode, snapshot_data: ?[]const u8, checksum: u32) !void {
        // Free any previous snapshot data owned by this node
        if (self.snapshot) |prev| {
            if (prev.data.len > 0) {
                self.allocator.free(prev.data);
            }
        }

        if (snapshot_data) |data| {
            const owned = try self.allocator.dupe(u8, data);
            self.snapshot = Snapshot{
                .last_included_index = self.commit_index,
                .last_included_term = self.current_term,
                .data = owned,
                .checksum = checksum,
            };
        } else {
            self.snapshot = Snapshot{
                .last_included_index = self.commit_index,
                .last_included_term = self.current_term,
                .data = "",
                .checksum = 0,
            };
        }
    }

    fn loadPersistentState(self: *RaftNode) !void {
        // Use external raft library's FileStorage for persistent state.
        // A missing state dir is a clean fresh start; any other open failure
        // (permissions, I/O) propagates — GAP-0889.
        var dir = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), self.storage_path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => return err,
        };
        defer dir.close(std.Io.Threaded.global_single_threaded.io());

        // Read term file (missing file = fresh start; corrupt content must
        // fail loud — silently resetting current_term to 0 lets a node vote
        // twice in the same term).
        if (dir.openFile(std.Io.Threaded.global_single_threaded.io(), "current_term", .{})) |f| {
            defer f.close(std.Io.Threaded.global_single_threaded.io());
            var buf: [32]u8 = undefined;
            const n = try f.readPositionalAll(std.Io.Threaded.global_single_threaded.io(), &buf, 0);
            if (n > 0) {
                const trimmed = std.mem.trim(u8, buf[0..n], " \n\r\t");
                self.current_term = std.fmt.parseInt(u64, trimmed, 10) catch {
                    log.warn("corrupt current_term file in {s}: {s}", .{ self.storage_path, trimmed });
                    return error.CorruptPersistentState;
                };
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    // SEC-D014: Atomic file write — write to temp file, fsync, then rename.
    // This ensures that either the old or new file exists, never a partial write.
    fn savePersistentState(self: *RaftNode) !void {
        std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), self.storage_path) catch {};
        var dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), self.storage_path, .{});
        defer dir.close(std.Io.Threaded.global_single_threaded.io());

        const term_str = try std.fmt.allocPrint(self.allocator, "{d}", .{self.current_term});
        defer self.allocator.free(term_str);

        try atomicWriteFile(dir, "current_term", term_str);
    }

    /// Write `data` to `name` atomically via write-to-temp-then-rename.
    fn atomicWriteFile(dir: std.Io.Dir, name: []const u8, data: []const u8) !void {
        // Temp file name: original name + ".tmp" suffix.
        var tmp_buf: [256]u8 = undefined;
        const tmp_name = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{name}) catch return error.FileNotFound;

        // Write to temp file.
        const f = try dir.createFile(std.Io.Threaded.global_single_threaded.io(), tmp_name, .{});
        errdefer {
            f.close(std.Io.Threaded.global_single_threaded.io());
            dir.deleteFile(std.Io.Threaded.global_single_threaded.io(), tmp_name) catch {};
        }
        try f.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), data);

        // fsync to ensure data is durable on disk before rename.
        try f.sync(std.Io.Threaded.global_single_threaded.io());
        f.close(std.Io.Threaded.global_single_threaded.io());

        // Atomic rename: replaces the target file in one operation.
        try dir.rename(tmp_name, dir, name, std.Io.Threaded.global_single_threaded.io());
    }
};

// ---- Tests ----
// CANARY: REQ=REQ-SEC-ATOMIC-WRITE-001; FEATURE="Atomic Raft File Write"; ASPECT=Persistence; STATUS=TESTED; TEST="raft_persistent: atomic write creates file with correct content"; OWNER=security; UPDATED=2026-04-10

test "raft_persistent: atomic write creates file with correct content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try RaftNode.atomicWriteFile(tmp.dir, "test_file", "hello123");

    // Verify the file exists and has the correct content.
    const f = try tmp.dir.openFile(std.Io.Threaded.global_single_threaded.io(), "test_file", .{});
    defer f.close(std.Io.Threaded.global_single_threaded.io());
    var buf: [64]u8 = undefined;
    const n = try f.readPositionalAll(std.Io.Threaded.global_single_threaded.io(), &buf, 0);
    try std.testing.expectEqualStrings("hello123", buf[0..n]);

    // Verify that the temp file does NOT exist (it was renamed).
    if (tmp.dir.openFile(std.Io.Threaded.global_single_threaded.io(), "test_file.tmp", .{})) |tf| {
        tf.close(std.Io.Threaded.global_single_threaded.io());
        return error.TestUnexpectedResult; // temp file should not exist
    } else |err| {
        try std.testing.expect(err == error.FileNotFound);
    }
}

test "raft_persistent: atomic write overwrites existing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write initial content.
    try RaftNode.atomicWriteFile(tmp.dir, "state", "old_data");

    // Overwrite with new content.
    try RaftNode.atomicWriteFile(tmp.dir, "state", "new_data");

    const f = try tmp.dir.openFile(std.Io.Threaded.global_single_threaded.io(), "state", .{});
    defer f.close(std.Io.Threaded.global_single_threaded.io());
    var buf: [64]u8 = undefined;
    const n = try f.readPositionalAll(std.Io.Threaded.global_single_threaded.io(), &buf, 0);
    try std.testing.expectEqualStrings("new_data", buf[0..n]);
}

test "raft_persistent: savePersistentState writes current_term atomically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Build a path string for the RaftNode.
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{&tmp.sub_path},
    );
    defer std.testing.allocator.free(path);

    var node = (try RaftNode.raftOpen(std.testing.allocator, path));
    node.current_term = 42;
    try node.savePersistentState();

    // Verify the file.
    const f = try tmp.dir.openFile(std.Io.Threaded.global_single_threaded.io(), "current_term", .{});
    defer f.close(std.Io.Threaded.global_single_threaded.io());
    var buf: [64]u8 = undefined;
    const n = try f.readPositionalAll(std.Io.Threaded.global_single_threaded.io(), &buf, 0);
    try std.testing.expectEqualStrings("42", buf[0..n]);

    // No temp file should remain.
    if (tmp.dir.openFile(std.Io.Threaded.global_single_threaded.io(), "current_term.tmp", .{})) |tf| {
        tf.close(std.Io.Threaded.global_single_threaded.io());
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expect(err == error.FileNotFound);
    }

    // Cleanup: destroy the node.
    node.cluster.members.deinit(std.testing.allocator);
    std.testing.allocator.destroy(node);
}

test "raft_persistent: createSnapshot with null creates empty snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/snap",
        .{&tmp.sub_path},
    );
    defer std.testing.allocator.free(path);

    var node = try RaftNode.raftOpen(std.testing.allocator, path);
    node.current_term = 3;
    node.commit_index = 7;

    try std.testing.expect(node.snapshot == null);
    try node.createSnapshot(null, 0);

    try std.testing.expect(node.snapshot != null);
    const snap = node.snapshot.?;
    try std.testing.expectEqual(@as(u64, 7), snap.last_included_index);
    try std.testing.expectEqual(@as(u64, 3), snap.last_included_term);
    try std.testing.expectEqualStrings("", snap.data);
    try std.testing.expectEqual(@as(u32, 0), snap.checksum);

    node.cluster.members.deinit(std.testing.allocator);
    std.testing.allocator.destroy(node);
}

test "raft_persistent: corrupt current_term fails loud at open (GAP-0889)" {
    // The corrupt-state warn is expected here — keep test output clean.
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{&tmp.sub_path},
    );
    defer std.testing.allocator.free(path);

    // Plant a corrupt term file.
    try RaftNode.atomicWriteFile(tmp.dir, "current_term", "not-a-number");

    // raftOpen must refuse to start with silently-reset state.
    try std.testing.expectError(
        error.CorruptPersistentState,
        RaftNode.raftOpen(std.testing.allocator, path),
    );
}

test "raft_persistent: persisted term round-trips through open (GAP-0889)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{&tmp.sub_path},
    );
    defer std.testing.allocator.free(path);

    var node = try RaftNode.raftOpen(std.testing.allocator, path);
    node.current_term = 17;
    try node.savePersistentState();
    node.cluster.members.deinit(std.testing.allocator);
    std.testing.allocator.destroy(node);

    // Re-open: the persisted term must be loaded, not reset.
    var reopened = try RaftNode.raftOpen(std.testing.allocator, path);
    try std.testing.expectEqual(@as(u64, 17), reopened.current_term);
    reopened.cluster.members.deinit(std.testing.allocator);
    std.testing.allocator.destroy(reopened);
}

test "raft_persistent: createSnapshot with data stores owned copy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/snap2",
        .{&tmp.sub_path},
    );
    defer std.testing.allocator.free(path);

    var node = try RaftNode.raftOpen(std.testing.allocator, path);
    node.current_term = 5;
    node.commit_index = 10;

    const test_data = "{\"type\":\"node\",\"id\":1}\n";
    try node.createSnapshot(test_data, 0xCAFE);

    try std.testing.expect(node.snapshot != null);
    const snap = node.snapshot.?;
    try std.testing.expectEqual(@as(u64, 10), snap.last_included_index);
    try std.testing.expectEqual(@as(u64, 5), snap.last_included_term);
    try std.testing.expectEqualStrings(test_data, snap.data);
    try std.testing.expectEqual(@as(u32, 0xCAFE), snap.checksum);

    // deinit frees the snapshot data
    node.deinit();
}
