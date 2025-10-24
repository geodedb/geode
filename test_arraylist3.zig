const std = @import("std");

const TestStruct = struct {
    const Node = struct {
        id: u64,
    };

    nodes: std.ArrayList(Node),

    pub fn init(allocator: std.mem.Allocator) TestStruct {
        return .{
            .nodes = std.ArrayList(Node).init(allocator),
        };
    }
};

test "ArrayList in struct" {
    const allocator = std.testing.allocator;
    const ts = TestStruct.init(allocator);
    _ = ts;
}
