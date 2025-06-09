// create the i256 type
const std = @import("std");

const i256 = struct {
    // The i256 type is represented as an array of 4 i64 values.
    // This allows for efficient arithmetic operations and comparisons.
    data: [4]i64,

    pub fn init(value: i64) i256 {
        return i256{ .data = [_]i64{ value, 0, 0, 0 } };
    }

    pub fn add(self: i256, other: i256) i256 {
        var result = i256.init(0);
        var carry = 0;
        for (0..4) |i| {
            const sum = self.data[i] + other.data[i] + carry;
            result.data[i] = sum & 0xFFFFFFFFFFFFFFFF; // Mask to fit in i64
            carry = if (sum > 0xFFFFFFFFFFFFFFFF) 1 else 0;
        }
        return result;
    }

    pub fn toString(self: i256) []const u8 {
        // Convert the i256 to a string representation
        return std.fmt.allocPrint(std.testing.allocator, "{d}", .{self.data[0]}) catch "error";
    }
};

// This function is used to test the i256 type.
test "i256 arithmetic" {
    const a = i256.init(1);
    const b = i256.init(2);
    const c = a.add(b);
    try std.testing.expectEqual(c.toString(), "3");
}

test "i256 addition with carry" {
    const a = i256.init(0xFFFFFFFFFFFFFFFF);
    const b = i256.init(1);
    const c = a.add(b);
    try std.testing.expectEqual(c.toString(), "0");
    try std.testing.expectEqual(c.data[1], 1); // Check the carry
}

test "i256 addition overflow" {
    const a = i256.init(0xFFFFFFFFFFFFFFFF);
    const b = i256.init(0xFFFFFFFFFFFFFFFF);
    const c = a.add(b);
    try std.testing.expectEqual(c.toString(), "0");
    try std.testing.expectEqual(c.data[1], 1); // Check the carry
}

// This code defines a simple i256 type with basic arithmetic operations.
// It includes tests to verify the correctness of addition, including 
// cases with carry and overflow.
test "i256 addition with multiple carries" {
    const a = i256.init(0xFFFFFFFFFFFFFFFF);
    const b = i256.init(0xFFFFFFFFFFFFFFFF);
    const c = a.add(b);
    const d = c.add(i256.init(1));
    try std.testing.expectEqual(d.toString(), "1");
    try std.testing.expectEqual(d.data[1], 2); // Check the carry
}
