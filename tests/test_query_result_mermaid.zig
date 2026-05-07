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

fn rowFromCells(allocator: std.mem.Allocator, cells: []const []const u8) !std.ArrayList([]const u8) {
    var row = try std.ArrayList([]const u8).initCapacity(allocator, cells.len);
    errdefer {
        for (row.items) |c| allocator.free(c);
        row.deinit(allocator);
    }
    for (cells) |c| try row.append(allocator, try allocator.dupe(u8, c));
    return row;
}

fn deinitRows(allocator: std.mem.Allocator, rows: *std.ArrayList(std.ArrayList([]const u8))) void {
    for (rows.items) |*row| {
        for (row.items) |cell| allocator.free(cell);
        row.deinit(allocator);
    }
    rows.deinit(allocator);
}

// CANARY: REQ=REQ-CLI-MERMAID-FORMAT-001; FEATURE="MermaidQueryFormat"; ASPECT=EmptyRowsGolden; STATUS=TESTED; TEST=tests/test_query_result_mermaid.zig; OWNER=cli; UPDATED=2026-05-06
test "mermaid format: empty rows emit only flowchart header" {
    const allocator = std.testing.allocator;

    const rows: []const std.ArrayList([]const u8) = &.{};

    const rendered = try renderMermaidToSlice(allocator, rows);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("flowchart LR\n", rendered);
}

// CANARY: REQ=REQ-CLI-MERMAID-FORMAT-001; FEATURE="MermaidQueryFormat"; ASPECT=NodeWithLabelsAndName; STATUS=TESTED; TEST=tests/test_query_result_mermaid.zig; OWNER=cli; UPDATED=2026-05-06
test "mermaid format: single node with labels and name property" {
    const allocator = std.testing.allocator;

    var rows = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 1);
    defer deinitRows(allocator, &rows);

    const node_json =
        \\{"id":123,"labels":["Person"],"properties":{"name":"Alice"}}
    ;
    try rows.append(allocator, try rowFromCells(allocator, &.{node_json}));

    const rendered = try renderMermaidToSlice(allocator, rows.items);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "flowchart LR\n  n123[\"Person<br/>Alice\"]\n",
        rendered,
    );
}

// CANARY: REQ=REQ-CLI-MERMAID-FORMAT-001; FEATURE="MermaidQueryFormat"; ASPECT=NodeFallbackToId; STATUS=TESTED; TEST=tests/test_query_result_mermaid.zig; OWNER=cli; UPDATED=2026-05-06
test "mermaid format: single node falls back to id when no labels match" {
    const allocator = std.testing.allocator;

    var rows = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 1);
    defer deinitRows(allocator, &rows);

    const node_json =
        \\{"id":7,"labels":[],"properties":{}}
    ;
    try rows.append(allocator, try rowFromCells(allocator, &.{node_json}));

    const rendered = try renderMermaidToSlice(allocator, rows.items);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "flowchart LR\n  n7[\"7\"]\n",
        rendered,
    );
}

// CANARY: REQ=REQ-CLI-MERMAID-FORMAT-001; FEATURE="MermaidQueryFormat"; ASPECT=MultiLabelJoin; STATUS=TESTED; TEST=tests/test_query_result_mermaid.zig; OWNER=cli; UPDATED=2026-05-06
test "mermaid format: multi-label node joins labels with colon" {
    const allocator = std.testing.allocator;

    var rows = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 1);
    defer deinitRows(allocator, &rows);

    const node_json =
        \\{"id":42,"labels":["User","Admin"],"properties":{"username":"root"}}
    ;
    try rows.append(allocator, try rowFromCells(allocator, &.{node_json}));

    const rendered = try renderMermaidToSlice(allocator, rows.items);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "flowchart LR\n  n42[\"User:Admin<br/>root\"]\n",
        rendered,
    );
}
