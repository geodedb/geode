const std = @import("std");
const testing = std.testing;

/// Mock filesystem that intercepts operations to simulate failures (e.g., power loss during fsync)
/// and track durability properties. Only handles basic file operations needed for storage tests.
pub const FakeEnv = struct {
    allocator: std.mem.Allocator,
    files: std.StringHashMap(FakeFileData),
    current_time: i64,

    // Fault injection config
    fail_next_fsync: bool = false,
    fail_next_write: bool = false,
    write_latency_ms: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) FakeEnv {
        return .{
            .allocator = allocator,
            .files = std.StringHashMap(FakeFileData).init(allocator),
            .current_time = 0,
        };
    }

    pub fn deinit(self: *FakeEnv) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.files.deinit();
    }

    pub fn createFile(self: *FakeEnv, path: []const u8) !FakeFile {
        if (self.files.contains(path)) return error.PathAlreadyExists;

        const path_dupe = try self.allocator.dupe(u8, path);
        try self.files.put(path_dupe, FakeFileData.init(self.allocator));

        return FakeFile{ .path = path_dupe, .env = self };
    }

    pub fn openFile(self: *FakeEnv, path: []const u8) !FakeFile {
        if (!self.files.contains(path)) return error.FileNotFound;
        // Note: returning a handle that points to the stable map entry
        // Real implementation would handle handles properly
        return FakeFile{ .path = path, .env = self }; // Path lifetime managed by map key
    }

    pub fn deleteFile(self: *FakeEnv, path: []const u8) !void {
        if (self.files.fetchRemove(path)) |kv| {
            self.allocator.free(kv.key);
            var data = kv.value;
            data.deinit(self.allocator);
        } else {
            return error.FileNotFound;
        }
    }
};

const FakeFileData = struct {
    content: std.ArrayList(u8),
    synced_len: usize = 0,

    fn init(allocator: std.mem.Allocator) FakeFileData {
        return .{
            .content = std.ArrayList(u8).init(allocator),
        };
    }

    fn deinit(self: *FakeFileData, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.content.deinit();
    }
};

pub const FakeFile = struct {
    path: []const u8,
    env: *FakeEnv,
    pos: usize = 0,

    pub fn writeAll(self: *FakeFile, data: []const u8) !void {
        if (self.env.fail_next_write) {
            self.env.fail_next_write = false;
            return error.DiskFull; // or InputOutput
        }

        // Find file data
        const ptr = self.env.files.getPtr(self.path) orelse return error.FileNotFound;

        // Append or overwrite? simplistic append for snapshot-like writes
        try ptr.content.appendSlice(data);
        self.pos += data.len;
    }

    pub fn sync(self: *FakeFile) !void {
        if (self.env.fail_next_fsync) {
            self.env.fail_next_fsync = false;
            return error.InputOutput;
        }

        const ptr = self.env.files.getPtr(self.path) orelse return error.FileNotFound;
        ptr.synced_len = ptr.content.items.len;
    }

    pub fn close(self: *FakeFile) void {
        _ = self;
    }

    pub fn seekFromEnd(self: *FakeFile, offset: i64) !void {
        const ptr = self.env.files.getPtr(self.path) orelse return error.FileNotFound;
        const end = @as(i64, @intCast(ptr.content.items.len));
        const new_pos = end + offset;
        if (new_pos < 0) return error.InvalidArgument;
        self.pos = @intCast(new_pos);
    }
};

test "fake fs durability" {
    var env = FakeEnv.init(testing.allocator);
    defer env.deinit();

    var file = try env.createFile("graph_store.dat");
    defer file.close();

    try file.writeAll("entry1");
    try testing.expectEqual(@as(usize, 6), env.files.get("graph_store.dat").?.content.items.len);
    try testing.expectEqual(@as(usize, 0), env.files.get("graph_store.dat").?.synced_len);

    try file.sync();
    try testing.expectEqual(@as(usize, 6), env.files.get("graph_store.dat").?.synced_len);

    env.fail_next_fsync = true;
    try testing.expectError(error.InputOutput, file.sync());
}
