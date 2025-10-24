const std = @import("std");
const jsonb = @import("../types/jsonb.zig");

pub const JsonbInvertedIndex = struct {
    paths: std.StringHashMap(std.ArrayList(usize)),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) JsonbInvertedIndex {
        return JsonbInvertedIndex{
            .paths = std.StringHashMap(std.ArrayList(usize)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn indexDocument(self: *JsonbInvertedIndex, doc_id: usize, document: jsonb.JsonbDocument) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, document.data, .{}) catch return;
        defer parsed.deinit();

        try indexValue(self, doc_id, parsed.value, "");
    }

    fn indexValue(self: *JsonbInvertedIndex, doc_id: usize, value: std.json.Value, current_path: []const u8) !void {
        switch (value) {
            .object => |obj| {
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    const key_path = if (current_path.len == 0)
                        try std.fmt.allocPrint(self.allocator, "{s}", .{entry.key_ptr.*})
                    else
                        try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ current_path, entry.key_ptr.* });
                    defer self.allocator.free(key_path);

                    try indexValue(self, doc_id, entry.value_ptr.*, key_path);
                }
            },
            .array => |arr| {
                for (arr.items, 0..) |item, i| {
                    const idx_path = if (current_path.len == 0)
                        try std.fmt.allocPrint(self.allocator, "[{d}]", .{i})
                    else
                        try std.fmt.allocPrint(self.allocator, "{s}[{d}]", .{ current_path, i });
                    defer self.allocator.free(idx_path);

                    try indexValue(self, doc_id, item, idx_path);
                }
            },
            .string => |s| {
                try addToPath(self, current_path, doc_id);
                const str_path = try std.fmt.allocPrint(self.allocator, "{s}:string:{s}", .{ current_path, s });
                defer self.allocator.free(str_path);
                try addToPath(self, str_path, doc_id);
            },
            .integer => |n| {
                try addToPath(self, current_path, doc_id);
                const num_path = try std.fmt.allocPrint(self.allocator, "{s}:number:{d}", .{ current_path, n });
                defer self.allocator.free(num_path);
                try addToPath(self, num_path, doc_id);
            },
            .float => |f| {
                try addToPath(self, current_path, doc_id);
                const num_path = try std.fmt.allocPrint(self.allocator, "{s}:number:{d}", .{ current_path, f });
                defer self.allocator.free(num_path);
                try addToPath(self, num_path, doc_id);
            },
            .bool => |b| {
                try addToPath(self, current_path, doc_id);
                const bool_path = try std.fmt.allocPrint(self.allocator, "{s}:bool:{}", .{ current_path, b });
                defer self.allocator.free(bool_path);
                try addToPath(self, bool_path, doc_id);
            },
            .null => {
                try addToPath(self, current_path, doc_id);
                const null_path = try std.fmt.allocPrint(self.allocator, "{s}:null", .{current_path});
                defer self.allocator.free(null_path);
                try addToPath(self, null_path, doc_id);
            },
            else => {},
        }
    }

    fn addToPath(self: *JsonbInvertedIndex, path: []const u8, doc_id: usize) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        const result = try self.paths.getOrPut(owned_path);

        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(usize).initCapacity(self.allocator, 0) catch std.ArrayList(usize){};
        } else {
            self.allocator.free(owned_path);
        }

        for (result.value_ptr.items) |existing_id| {
            if (existing_id == doc_id) return;
        }

        try result.value_ptr.append(self.allocator, doc_id);
    }

    pub fn queryPath(self: JsonbInvertedIndex, path: []const u8, allocator: std.mem.Allocator) ![]usize {
        if (self.paths.get(path)) |list| {
            return try allocator.dupe(usize, list.items);
        }
        return try allocator.alloc(usize, 0);
    }

    pub fn deinit(self: *JsonbInvertedIndex) void {
        var iter = self.paths.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.paths.deinit();
    }
};

test "jsonb inverted index" {
    const allocator = std.testing.allocator;
    var index = JsonbInvertedIndex.init(allocator);
    defer index.deinit();

    const doc = try jsonb.JsonbDocument.fromString(allocator, "{\"a\":1,\"b\":[2,3]}");
    defer doc.deinit();

    try index.indexDocument(0, doc);

    const results = try index.queryPath("a", allocator);
    defer allocator.free(results);

    std.testing.expect(results.len == 1) catch unreachable;
    std.testing.expect(results[0] == 0) catch unreachable;
}
