const std = @import("std");
const geode = @import("geode");
const query_results = geode.query_result_accumulator;

fn renderMermaidToSlice(
    allocator: std.mem.Allocator,
    rows: []const std.ArrayList([]const u8),
) ![]u8 {
    var out_buf: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out_buf);
    try query_results.outputMermaidFormatFromRows(allocator, rows, &writer);
    return try allocator.dupe(u8, writer.buffered());
}

test "mermaid format: empty rows emit only flowchart header" {
    const allocator = std.testing.allocator;

    const rows: []const std.ArrayList([]const u8) = &.{};

    const rendered = try renderMermaidToSlice(allocator, rows);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("flowchart LR\n", rendered);
}
