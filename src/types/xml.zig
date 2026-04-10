const std = @import("std");

pub const XmlDocument = struct {
    data: []const u8,

    pub const Error = error{
        NotWellFormed,
        InvalidEntity,
        OutOfMemory,
    };

    /// P2-3: Now accepts allocator parameter for validation
    pub fn fromString(allocator: std.mem.Allocator, data: []const u8) Error!XmlDocument {
        try validateWellFormed(allocator, data);
        return XmlDocument{ .data = data };
    }

    /// P2-3: Now accepts allocator parameter for validation
    pub fn isWellFormed(allocator: std.mem.Allocator, data: []const u8) bool {
        validateWellFormed(allocator, data) catch return false;
        return true;
    }

    /// P2-3: Now accepts allocator parameter for tag stack
    fn validateWellFormed(allocator: std.mem.Allocator, data: []const u8) Error!void {
        var tag_stack = std.ArrayList([]const u8).empty;
        defer tag_stack.deinit(allocator);

        var i: usize = 0;
        var in_tag = false;
        var tag_start: usize = 0;

        while (i < data.len) {
            const c = data[i];

            if (c == '<') {
                if (in_tag) return Error.NotWellFormed;
                in_tag = true;
                tag_start = i + 1;
            } else if (c == '>') {
                if (!in_tag) return Error.NotWellFormed;
                in_tag = false;

                const tag_content = data[tag_start..i];
                if (tag_content.len == 0) return Error.NotWellFormed;

                if (tag_content[0] == '/') {
                    const tag_name = tag_content[1..];
                    if (tag_stack.items.len == 0) return Error.NotWellFormed;
                    const expected = tag_stack.pop().?;
                    if (!std.mem.eql(u8, tag_name, expected)) return Error.NotWellFormed;
                } else if (tag_content[tag_content.len - 1] == '/') {} else {
                    const space_pos = std.mem.indexOfScalar(u8, tag_content, ' ') orelse tag_content.len;
                    const tag_name = tag_content[0..space_pos];
                    try tag_stack.append(allocator, tag_name);
                }
            } else if (c == '&') {
                const end_pos = std.mem.indexOfScalarPos(u8, data, i, ';') orelse return Error.InvalidEntity;
                const entity = data[i + 1 .. end_pos];
                if (!isValidEntity(entity)) return Error.InvalidEntity;
                i = end_pos;
            }

            i += 1;
        }

        if (in_tag or tag_stack.items.len > 0) return Error.NotWellFormed;
    }

    fn isValidEntity(entity: []const u8) bool {
        const valid_entities = [_][]const u8{ "amp", "lt", "gt", "quot", "apos" };
        for (valid_entities) |valid| {
            if (std.mem.eql(u8, entity, valid)) return true;
        }
        return false;
    }
};

test "xml well-formed" {
    const doc = try XmlDocument.fromString(std.testing.allocator, "<a><b/></a>");
    std.testing.expectEqualSlices(u8, doc.data, "<a><b/></a>") catch unreachable;
}
