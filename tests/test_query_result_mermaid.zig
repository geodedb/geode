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

// CANARY: REQ=REQ-CLI-MERMAID-FORMAT-001; FEATURE="MermaidQueryFormat"; ASPECT=EdgeWithLabel; STATUS=TESTED; TEST=tests/test_query_result_mermaid.zig; OWNER=cli; UPDATED=2026-05-06
test "mermaid format: edge between two nodes uses relationship label" {
    const allocator = std.testing.allocator;

    var rows = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 1);
    defer deinitRows(allocator, &rows);

    const a_json =
        \\{"id":1,"labels":["Person"],"properties":{"name":"Alice"}}
    ;
    const r_json =
        \\{"id":99,"from":1,"to":2,"label":"KNOWS","properties":{}}
    ;
    const b_json =
        \\{"id":2,"labels":["Person"],"properties":{"name":"Bob"}}
    ;
    try rows.append(allocator, try rowFromCells(allocator, &.{ a_json, r_json, b_json }));

    const rendered = try renderMermaidToSlice(allocator, rows.items);
    defer allocator.free(rendered);

    const expected =
        "flowchart LR\n" ++
        "  n1[\"Person<br/>Alice\"]\n" ++
        "  n2[\"Person<br/>Bob\"]\n" ++
        "  n1 -->|\"KNOWS\"| n2\n";
    try std.testing.expectEqualStrings(expected, rendered);
}

// CANARY: REQ=REQ-CLI-MERMAID-FORMAT-001; FEATURE="MermaidQueryFormat"; ASPECT=EdgeWithTypeField; STATUS=TESTED; TEST=tests/test_query_result_mermaid.zig; OWNER=cli; UPDATED=2026-05-06
test "mermaid format: edge accepts type field instead of label" {
    const allocator = std.testing.allocator;

    var rows = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 1);
    defer deinitRows(allocator, &rows);

    const r_json =
        \\{"id":99,"from":3,"to":4,"type":"FRIENDS_WITH"}
    ;
    try rows.append(allocator, try rowFromCells(allocator, &.{r_json}));

    const rendered = try renderMermaidToSlice(allocator, rows.items);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "flowchart LR\n  n3 -->|\"FRIENDS_WITH\"| n4\n",
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

// CANARY: REQ=REQ-CLI-MERMAID-FORMAT-001; FEATURE="MermaidQueryFormat"; ASPECT=DuplicateNodeDedup; STATUS=TESTED; TEST=tests/test_query_result_mermaid.zig; OWNER=cli; UPDATED=2026-05-06
test "mermaid format: duplicate nodes across rows render once" {
    const allocator = std.testing.allocator;

    var rows = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 2);
    defer deinitRows(allocator, &rows);

    const node_json =
        \\{"id":7,"labels":["Person"],"properties":{"name":"Carol"}}
    ;
    try rows.append(allocator, try rowFromCells(allocator, &.{node_json}));
    try rows.append(allocator, try rowFromCells(allocator, &.{node_json}));

    const rendered = try renderMermaidToSlice(allocator, rows.items);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "flowchart LR\n  n7[\"Person<br/>Carol\"]\n",
        rendered,
    );
}

// CANARY: REQ=REQ-CLI-MERMAID-FORMAT-001; FEATURE="MermaidQueryFormat"; ASPECT=QuoteEscape; STATUS=TESTED; TEST=tests/test_query_result_mermaid.zig; OWNER=cli; UPDATED=2026-05-06
test "mermaid format: label with quotes is HTML-escaped" {
    const allocator = std.testing.allocator;

    var rows = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 1);
    defer deinitRows(allocator, &rows);

    const node_json =
        \\{"id":11,"labels":["Person"],"properties":{"name":"He said \"hi\""}}
    ;
    try rows.append(allocator, try rowFromCells(allocator, &.{node_json}));

    const rendered = try renderMermaidToSlice(allocator, rows.items);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "flowchart LR\n  n11[\"Person<br/>He said &quot;hi&quot;\"]\n",
        rendered,
    );
}

// CANARY: REQ=REQ-CLI-MERMAID-FORMAT-001; FEATURE="MermaidQueryFormat"; ASPECT=AmpersandEscapePreservesBrTag; STATUS=TESTED; TEST=tests/test_query_result_mermaid.zig; OWNER=cli; UPDATED=2026-05-06
test "mermaid format: label with ampersand is HTML-escaped without breaking br tags" {
    const allocator = std.testing.allocator;

    var rows = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 1);
    defer deinitRows(allocator, &rows);

    const node_json =
        \\{"id":12,"labels":["Co"],"properties":{"name":"R&D"}}
    ;
    try rows.append(allocator, try rowFromCells(allocator, &.{node_json}));

    const rendered = try renderMermaidToSlice(allocator, rows.items);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "flowchart LR\n  n12[\"Co<br/>R&amp;D\"]\n",
        rendered,
    );
}

// CANARY: REQ=REQ-CLI-MERMAID-FORMAT-001; FEATURE="MermaidQueryFormat"; ASPECT=EdgeLabelAngleBracketEscape; STATUS=TESTED; TEST=tests/test_query_result_mermaid.zig; OWNER=cli; UPDATED=2026-05-06
test "mermaid format: edge label with angle bracket is escaped" {
    const allocator = std.testing.allocator;

    var rows = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 1);
    defer deinitRows(allocator, &rows);

    const r_json =
        \\{"id":50,"from":1,"to":2,"label":"A<B"}
    ;
    try rows.append(allocator, try rowFromCells(allocator, &.{r_json}));

    const rendered = try renderMermaidToSlice(allocator, rows.items);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "flowchart LR\n  n1 -->|\"A&lt;B\"| n2\n",
        rendered,
    );
}

// CANARY: REQ=REQ-CLI-MERMAID-FORMAT-001; FEATURE="MermaidQueryFormat"; ASPECT=EdgeStartNodeEndNodeAlternates; STATUS=TESTED; TEST=tests/test_query_result_mermaid.zig; OWNER=cli; UPDATED=2026-05-06
test "mermaid format: edge with start_node and end_node alternate endpoint fields" {
    const allocator = std.testing.allocator;

    var rows = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 1);
    defer deinitRows(allocator, &rows);

    const r_json =
        \\{"id":77,"start_node":10,"end_node":20,"type":"LIKES"}
    ;
    try rows.append(allocator, try rowFromCells(allocator, &.{r_json}));

    const rendered = try renderMermaidToSlice(allocator, rows.items);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "flowchart LR\n  n10 -->|\"LIKES\"| n20\n",
        rendered,
    );
}
