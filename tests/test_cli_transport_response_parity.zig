const std = @import("std");
const geode = @import("geode");
const cli_transport_response = geode.cli_transport_response;

fn renderToSlice(
    allocator: std.mem.Allocator,
    format: []const u8,
    rows_text: ?*std.ArrayList(std.ArrayList([]const u8)),
    rows_json: ?*std.ArrayList(std.ArrayList(std.json.Value)),
    view: cli_transport_response.TransportResponseView,
) ![]u8 {
    var out_buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    const writer = fbs.writer();
    try cli_transport_response.renderTransportResponse(allocator, writer, format, rows_text, rows_json, view);
    return try allocator.dupe(u8, fbs.getWritten());
}

fn deinitTextRows(allocator: std.mem.Allocator, rows: *std.ArrayList(std.ArrayList([]const u8))) void {
    for (rows.items) |*row| row.deinit(allocator);
    rows.deinit(allocator);
}

fn deinitJsonRows(allocator: std.mem.Allocator, rows: *std.ArrayList(std.ArrayList(std.json.Value))) void {
    for (rows.items) |*row| row.deinit(allocator);
    rows.deinit(allocator);
}

// CANARY: REQ=REQ-QUALITY-461-001; FEATURE="CliTransportResponseAbstraction"; ASPECT=GoldenParityJson; STATUS=TESTED; TEST=tests/test_cli_transport_response_parity.zig; OWNER=cli; UPDATED=2026-02-16
test "cli transport response parity: json golden" {
    const allocator = std.testing.allocator;

    var rows_json = try std.ArrayList(std.ArrayList(std.json.Value)).initCapacity(allocator, 1);
    defer deinitJsonRows(allocator, &rows_json);

    var row = try std.ArrayList(std.json.Value).initCapacity(allocator, 2);
    try row.append(allocator, .{ .integer = 7 });
    try row.append(allocator, .{ .bool = true });
    try rows_json.append(allocator, row);

    const columns = [_]cli_transport_response.ColumnInfo{
        .{ .name = "x", .type = "ANY" },
        .{ .name = "ok", .type = "ANY" },
    };
    const order_keys = [_][]const u8{"x"};
    const none = [_][]const u8{};

    const rendered = try renderToSlice(
        allocator,
        "json",
        null,
        &rows_json,
        .{
            .columns = columns[0..],
            .ordered = true,
            .order_keys = order_keys[0..],
            .status_class = "00000",
            .status_subclass = "",
            .additional_statuses = none[0..],
            .flagger_findings = none[0..],
            .has_error = false,
            .error_message = "",
            .error_status = "58000",
            .result_kind = .rows,
            .result_payload = null,
        },
    );
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "{\"status_class\":\"00000\",\"ordered\":true,\"order_keys\":[\"x\"],\"columns\":[{\"name\":\"x\",\"type\":\"ANY\"},{\"name\":\"ok\",\"type\":\"ANY\"}],\"rows\":[{\"x\":7,\"ok\":true}],\"additional_statuses\":[],\"flagger_findings\":[]}\n",
        rendered,
    );
}

// CANARY: REQ=REQ-QUALITY-461-002; FEATURE="CliTransportResponseAbstraction"; ASPECT=GoldenParityTextFormats; STATUS=TESTED; TEST=tests/test_cli_transport_response_parity.zig; OWNER=cli; UPDATED=2026-02-16
test "cli transport response parity: csv and table goldens" {
    const allocator = std.testing.allocator;

    var rows_text = try std.ArrayList(std.ArrayList([]const u8)).initCapacity(allocator, 2);
    defer deinitTextRows(allocator, &rows_text);

    var row1 = try std.ArrayList([]const u8).initCapacity(allocator, 2);
    try row1.append(allocator, "Alice");
    try row1.append(allocator, "31");
    try rows_text.append(allocator, row1);

    var row2 = try std.ArrayList([]const u8).initCapacity(allocator, 2);
    try row2.append(allocator, "Bob");
    try row2.append(allocator, "42");
    try rows_text.append(allocator, row2);

    const columns = [_]cli_transport_response.ColumnInfo{
        .{ .name = "name", .type = "ANY" },
        .{ .name = "age", .type = "ANY" },
    };
    const none = [_][]const u8{};

    const csv_rendered = try renderToSlice(
        allocator,
        "csv",
        &rows_text,
        null,
        .{
            .columns = columns[0..],
            .ordered = false,
            .order_keys = none[0..],
            .status_class = "00000",
            .status_subclass = "",
            .additional_statuses = none[0..],
            .flagger_findings = none[0..],
            .has_error = false,
            .error_message = "",
            .error_status = "58000",
            .result_kind = .rows,
            .result_payload = null,
        },
    );
    defer allocator.free(csv_rendered);

    try std.testing.expectEqualStrings(
        "name,age\nAlice,31\nBob,42\n",
        csv_rendered,
    );

    const table_rendered = try renderToSlice(
        allocator,
        "table",
        &rows_text,
        null,
        .{
            .columns = columns[0..],
            .ordered = false,
            .order_keys = none[0..],
            .status_class = "00000",
            .status_subclass = "",
            .additional_statuses = none[0..],
            .flagger_findings = none[0..],
            .has_error = false,
            .error_message = "",
            .error_status = "58000",
            .result_kind = .rows,
            .result_payload = null,
        },
    );
    defer allocator.free(table_rendered);

    try std.testing.expectEqualStrings(
        "+-------+-----+\r\n| name  | age |\r\n+-------+-----+\r\n| Alice | 31  |\r\n| Bob   | 42  |\r\n+-------+-----+\r\n(2 rows)\r\n",
        table_rendered,
    );
}
