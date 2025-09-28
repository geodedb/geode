const std = @import("std");

pub fn Array(comptime T: type) type {
    return struct {
        const Self = @This();

        elements: []T,
        allocator: std.mem.Allocator,

        pub const Error = error{
            IndexOutOfBounds,
            TypeMismatch,
            OutOfMemory,
        };

        pub fn init(allocator: std.mem.Allocator, elements: []const T) Error!Self {
            const owned_elements = try allocator.dupe(T, elements);
            return Self{ .elements = owned_elements, .allocator = allocator };
        }

        pub fn deinit(self: Self) void {
            self.allocator.free(self.elements);
        }

        pub fn length(self: Self) usize {
            return self.elements.len;
        }

        pub fn get(self: Self, index: usize) Error!T {
            if (index >= self.elements.len) return Error.IndexOutOfBounds;
            return self.elements[index];
        }

        pub fn contains(self: Self, value: T) bool {
            for (self.elements) |elem| {
                if (std.meta.eql(elem, value)) return true;
            }
            return false;
        }

        pub fn toSlice(self: Self) []const T {
            return self.elements;
        }
    };
}

pub const DynamicArray = struct {
    elem_type: ElemType,
    data: []const u8,
    allocator: std.mem.Allocator,

    pub const ElemType = enum(u16) {
        int = 0x20,
        text = 0x21,
        bool = 0x22,
        decimal = 0x23,
    };

    pub const Error = error{
        TypeMismatch,
        IndexOutOfBounds,
        OutOfMemory,
    };

    pub fn fromInts(allocator: std.mem.Allocator, values: []const i64) Error!DynamicArray {
        var data = std.ArrayList(u8).initCapacity(allocator, values.len * 8) catch return Error.OutOfMemory;
        errdefer data.deinit(allocator);

        for (values) |val| {
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(i64, &bytes, val, .little);
            try data.appendSlice(allocator, &bytes);
        }

        return DynamicArray{
            .elem_type = .int,
            .data = try data.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    pub fn getInt(self: DynamicArray, index: usize) Error!i64 {
        if (self.elem_type != .int) return Error.TypeMismatch;
        const elem_size = 8;
        if (index * elem_size + elem_size > self.data.len) return Error.IndexOutOfBounds;

        const start = index * elem_size;
        return std.mem.readInt(i64, self.data[start .. start + elem_size][0..8], .little);
    }

    pub fn length(self: DynamicArray) usize {
        return switch (self.elem_type) {
            .int => self.data.len / 8,
            .bool => self.data.len,
            .text => blk: {
                var count: usize = 0;
                var i: usize = 0;
                while (i < self.data.len) {
                    const len = std.mem.readInt(u32, self.data[i .. i + 4][0..4], .little);
                    i += 4 + len;
                    count += 1;
                }
                break :blk count;
            },
            .decimal => self.data.len / 18,
        };
    }

    pub fn contains(self: DynamicArray, value: anytype) bool {
        const T = @TypeOf(value);
        switch (T) {
            i64 => {
                if (self.elem_type != .int) return false;
                for (0..self.length()) |i| {
                    if (self.getInt(i) catch continue == value) return true;
                }
            },
            else => return false,
        }
        return false;
    }

    pub fn deinit(self: DynamicArray) void {
        self.allocator.free(self.data);
    }
};

test "array operations" {
    const allocator = std.testing.allocator;
    const arr = try DynamicArray.fromInts(allocator, &[_]i64{ 1, 2, 3 });
    defer arr.deinit();

    std.testing.expect(arr.length() == 3) catch unreachable;
    std.testing.expect(arr.contains(@as(i64, 2))) catch unreachable;
    std.testing.expect(!arr.contains(@as(i64, 4))) catch unreachable;
}
