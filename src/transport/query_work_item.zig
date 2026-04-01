const std = @import("std");

// Geode-specific query work tracking for async connection handling and tests.
// This is not provided by the external concurrency library because it carries
// query text, stream IDs, and result buffering specific to Geode.
pub const QueryWorkItem = struct {
    allocator: std.mem.Allocator,
    query: []const u8,
    stream_id: u64,
    result: ?[]const u8 = null,
    err: ?anyerror = null,
    completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator, query: []const u8, stream_id: u64) !*QueryWorkItem {
        const self = try allocator.create(QueryWorkItem);
        self.* = .{
            .allocator = allocator,
            .query = try allocator.dupe(u8, query),
            .stream_id = stream_id,
        };
        return self;
    }

    pub fn deinit(self: *QueryWorkItem) void {
        self.allocator.free(self.query);
        if (self.result) |result| {
            self.allocator.free(result);
        }
        self.allocator.destroy(self);
    }

    pub fn isCompleted(self: *QueryWorkItem) bool {
        return self.completed.load(.acquire);
    }

    pub fn markCompleted(self: *QueryWorkItem) void {
        self.completed.store(true, .release);
    }

    pub fn setResult(self: *QueryWorkItem, result: []const u8) !void {
        self.result = try self.allocator.dupe(u8, result);
    }

    pub fn setError(self: *QueryWorkItem, err: anyerror) void {
        self.err = err;
    }
};
