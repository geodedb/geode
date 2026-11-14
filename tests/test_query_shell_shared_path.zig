const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const cli_test_util = @import("cli_test_util.zig");
const proto_test_util = @import("proto_test_util.zig");

// CANARY: REQ=REQ-CLI-SHARED-QUERY-001; FEATURE="ShellQuerySharedPath"; ASPECT=ParityTesting; STATUS=IMPL; TEST=../geode-test-harness/geodetestlab-cli/specs/gap_0200_shell_test_verification.yml; OWNER=cli; UPDATED=2026-11-14
// CANARY: REQ=REQ-CLI-SHARED-QUERY-002; FEATURE="ShellQuerySharedPath"; ASPECT=GraphScopingParity; STATUS=IMPL; TEST=../geode-test-harness/geodetestlab-cli/specs/dsn_graph_binding.yml; OWNER=cli; UPDATED=2026-11-14
// CANARY: REQ=REQ-CLI-SHARED-QUERY-003; FEATURE="ShellQuerySharedPath"; ASPECT=LargeOrderedStreamingParity; STATUS=IMPL; TEST=../geode-test-harness/geodetestlab-cli/specs/gap_0257_orderby_large_resultset.yml; OWNER=cli; UPDATED=2026-11-14
// CANARY: REQ=REQ-CLI-SHARED-QUERY-004; FEATURE="ShellQuerySharedPath"; ASPECT=ExplainProfileParity; STATUS=IMPL; TEST=../geode-test-harness/geodetestlab-cli/specs/explain_profile_unit_tests.yml; OWNER=cli; UPDATED=2026-11-14
// CANARY: REQ=REQ-CLI-SHARED-QUERY-005; FEATURE="ShellQuerySharedPath"; ASPECT=ErrorPayloadParity; STATUS=IMPL; TEST=../geode-test-harness/geodetestlab-cli/specs/query_output_formats.yml; OWNER=cli; UPDATED=2026-11-14
// CANARY: REQ=REQ-CLI-SHARED-QUERY-006; FEATURE="ShellQuerySharedPath"; ASPECT=BatchFileSourceParity; STATUS=IMPL; TEST=../geode-test-harness/geodetestlab-cli/specs/shell_source_batch.yml; OWNER=cli; UPDATED=2026-11-14
// CANARY: REQ=REQ-CLI-SHARED-QUERY-007; FEATURE="ShellQuerySharedPath"; ASPECT=QueryFileParity; STATUS=IMPL; TEST=../geode-test-harness/geodetestlab-cli/specs/query_file_flag_comprehensive.yml; OWNER=cli; UPDATED=2026-11-14

const CliResult = cli_test_util.CliResult;

fn runQueryAgainstServer(
    allocator: std.mem.Allocator,
    addr: []const u8,
    args: []const []const u8,
) !CliResult {
    return cli_test_util.runAgainstServer(allocator, addr, args);
}

fn runJsonQueryAgainstServer(
    allocator: std.mem.Allocator,
    addr: []const u8,
    query_text: []const u8,
) !CliResult {
    return runQueryAgainstServer(
        allocator,
        addr,
        &.{ geode_test_bin.geode_exe, "query", "--format", "json", query_text },
    );
}

fn runShellAgainstServer(
    allocator: std.mem.Allocator,
    addr: []const u8,
    commands: []const []const u8,
) !CliResult {
    if (std.fs.accessAbsolute("/usr/bin/script", .{})) |_| {} else |_| return error.SkipZigTest;

    const command = try std.fmt.allocPrint(
        allocator,
        "{s} shell --server {s} --insecure-tls-skip-verify -U {s} -P {s} --format json --no-history",
        .{ geode_test_bin.geode_exe, addr, proto_test_util.defaultUsername(), proto_test_util.defaultPassword() },
    );
    defer allocator.free(command);

    var child = std.process.Child.init(&.{ "/usr/bin/script", "-qec", command, "/dev/null" }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    std.Thread.sleep(1200 * std.time.ns_per_ms);
    for (commands) |input| {
        try child.stdin.?.writeAll(input);
        try child.stdin.?.writeAll("\r");
        std.Thread.sleep(250 * std.time.ns_per_ms);
    }
    try child.stdin.?.writeAll("\\quit\r");
    child.stdin.?.close();
    child.stdin = null;

    const out = try child.stdout.?.readToEndAlloc(allocator, 8 << 20);
    const err = try child.stderr.?.readToEndAlloc(allocator, 1 << 20);
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |status| status,
        else => 2,
    };
    return .{ .code = code, .out = out, .err = err };
}

fn extractLastJsonObject(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var start: ?usize = null;
    var last_start: ?usize = null;
    var last_end: ?usize = null;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;

    for (text, 0..) |ch, idx| {
        if (start == null) {
            if (ch == '{') {
                start = idx;
                depth = 1;
                in_string = false;
                escaped = false;
            }
            continue;
        }

        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == '"') {
                in_string = false;
            }
            continue;
        }

        switch (ch) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) {
                    last_start = start;
                    last_end = idx + 1;
                    start = null;
                }
            },
            else => {},
        }
    }

    const json_start = last_start orelse return error.MissingJsonObject;
    const json_end = last_end orelse return error.MissingJsonObject;
    return try allocator.dupe(u8, text[json_start..json_end]);
}

fn parseJsonValue(allocator: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
}

fn jsonValueEqual(a: std.json.Value, b: std.json.Value) bool {
    if (@intFromEnum(a) != @intFromEnum(b)) return false;

    return switch (a) {
        .null => true,
        .bool => |value| b.bool == value,
        .integer => |value| b.integer == value,
        .float => |value| b.float == value,
        .number_string => |value| std.mem.eql(u8, b.number_string, value),
        .string => |value| std.mem.eql(u8, b.string, value),
        .array => |items| blk: {
            if (b.array.items.len != items.items.len) break :blk false;
            for (items.items, 0..) |item, idx| {
                if (!jsonValueEqual(item, b.array.items[idx])) break :blk false;
            }
            break :blk true;
        },
        .object => |obj| blk: {
            if (obj.count() != b.object.count()) break :blk false;
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonValueEqual(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn assertResultJsonEqual(expected_text: []const u8, actual_text: []const u8) !void {
    const allocator = testing.allocator;
    const expected = try parseJsonValue(allocator, expected_text);
    defer expected.deinit();
    const actual = try parseJsonValue(allocator, actual_text);
    defer actual.deinit();

    try testing.expect(jsonValueEqual(expected.value, actual.value));
}

fn assertCommandSucceeded(result: CliResult) !void {
    try testing.expectEqual(@as(i32, 0), result.code);
}

fn execOkQuery(allocator: std.mem.Allocator, addr: []const u8, query_text: []const u8) !void {
    const result = try runJsonQueryAgainstServer(allocator, addr, query_text);
    defer allocator.free(result.out);
    defer allocator.free(result.err);
    try assertCommandSucceeded(result);
}

fn execOkGraphQuery(allocator: std.mem.Allocator, addr: []const u8, graph: []const u8, query_text: []const u8) !void {
    const result = try runQueryAgainstServer(allocator, addr, &.{ geode_test_bin.geode_exe, "query", "--format", "json", "--graph", graph, query_text });
    defer allocator.free(result.out);
    defer allocator.free(result.err);
    try assertCommandSucceeded(result);
}

fn createGap0257BatchQuery(allocator: std.mem.Allocator, start_id: usize, end_id: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "CREATE ");
    for (start_id..end_id + 1) |id| {
        if (id != start_id) try out.appendSlice(allocator, ", ");
        try out.writer(allocator).print(
            "(:GAP0257 {{id: {d}, value: {d}, category: {d}}})",
            .{ id, id * 10, id % 5 },
        );
    }
    return try out.toOwnedSlice(allocator);
}

fn extractIntegerColumnValues(allocator: std.mem.Allocator, json_text: []const u8, column_name: []const u8) ![]i64 {
    const parsed = try parseJsonValue(allocator, json_text);
    defer parsed.deinit();

    const root = parsed.value.object;
    const rows_value = root.get("rows") orelse return error.MissingRows;
    if (rows_value != .array) return error.InvalidRows;

    const rows = rows_value.array.items;
    var values = try allocator.alloc(i64, rows.len);
    errdefer allocator.free(values);

    for (rows, 0..) |row, idx| {
        if (row != .object) return error.InvalidRows;
        const value = row.object.get(column_name) orelse return error.MissingColumn;
        values[idx] = switch (value) {
            .integer => value.integer,
            .number_string => try std.fmt.parseInt(i64, value.number_string, 10),
            else => return error.InvalidColumnType,
        };
    }
    return values;
}

fn writeQueryFile(tmp: *std.testing.TmpDir, allocator: std.mem.Allocator, file_name: []const u8, contents: []const u8) ![]u8 {
    const file = try tmp.dir.createFile(file_name, .{});
    defer file.close();
    try file.writeAll(contents);
    return try tmp.dir.realpathAlloc(allocator, file_name);
}

test "query and shell share result semantics for gap_0200 chained WITH query" {
    const allocator = testing.allocator;

    var server = try proto_test_util.spawnServerRandom(allocator, proto_test_util.TestEnv.standard());
    defer server.deinit();
    const addr = server.getAddr();

    const query_text = "WITH 1 AS x WITH x + 1 AS y RETURN y AS result";

    const query_result = try runQueryAgainstServer(allocator, addr, &.{ geode_test_bin.geode_exe, "query", "--format", "json", query_text });
    defer allocator.free(query_result.out);
    defer allocator.free(query_result.err);
    try assertCommandSucceeded(query_result);

    const shell_result = try runShellAgainstServer(allocator, addr, &.{query_text ++ ";"});
    defer allocator.free(shell_result.out);
    defer allocator.free(shell_result.err);
    try assertCommandSucceeded(shell_result);

    const shell_json = try extractLastJsonObject(allocator, shell_result.out);
    defer allocator.free(shell_json);

    try assertResultJsonEqual(query_result.out, shell_json);
}

test "query graph flag and shell use command share graph-scoped execution semantics" {
    const allocator = testing.allocator;

    var server = try proto_test_util.spawnServerRandom(allocator, proto_test_util.TestEnv.standard());
    defer server.deinit();
    const addr = server.getAddr();
    const graph_name = "test_graph_ctx";

    try execOkQuery(allocator, addr, "CREATE GRAPH IF NOT EXISTS test_graph_ctx");
    try execOkGraphQuery(allocator, addr, graph_name, "CREATE (:ParityNode {name: 'alice'})");

    const query_result = try runQueryAgainstServer(
        allocator,
        addr,
        &.{ geode_test_bin.geode_exe, "query", "--format", "json", "--graph", graph_name, "MATCH (n:ParityNode) RETURN n.name AS name" },
    );
    defer allocator.free(query_result.out);
    defer allocator.free(query_result.err);
    try assertCommandSucceeded(query_result);

    const shell_result = try runShellAgainstServer(allocator, addr, &.{ "/use test_graph_ctx", "MATCH (n:ParityNode) RETURN n.name AS name;" });
    defer allocator.free(shell_result.out);
    defer allocator.free(shell_result.err);
    try assertCommandSucceeded(shell_result);

    const shell_json = try extractLastJsonObject(allocator, shell_result.out);
    defer allocator.free(shell_json);

    try assertResultJsonEqual(query_result.out, shell_json);
}

test "query and shell stay aligned for gap_0257 ordered and unordered large result sets" {
    const allocator = testing.allocator;

    var server = try proto_test_util.spawnServerRandom(allocator, proto_test_util.TestEnv.standard());
    defer server.deinit();
    const addr = server.getAddr();

    var start_id: usize = 1;
    while (start_id <= 1000) : (start_id += 50) {
        const end_id = @min(start_id + 49, 1000);
        const batch_query = try createGap0257BatchQuery(allocator, start_id, end_id);
        defer allocator.free(batch_query);
        try execOkQuery(allocator, addr, batch_query);
    }

    const ordered_query = "MATCH (n:GAP0257) RETURN n.id AS id, n.value AS value ORDER BY n.id";
    const ordered_query_result = try runQueryAgainstServer(allocator, addr, &.{ geode_test_bin.geode_exe, "query", "--format", "json", ordered_query });
    defer allocator.free(ordered_query_result.out);
    defer allocator.free(ordered_query_result.err);
    try assertCommandSucceeded(ordered_query_result);

    const ordered_shell_result = try runShellAgainstServer(allocator, addr, &.{ordered_query ++ ";"});
    defer allocator.free(ordered_shell_result.out);
    defer allocator.free(ordered_shell_result.err);
    try assertCommandSucceeded(ordered_shell_result);

    const ordered_shell_json = try extractLastJsonObject(allocator, ordered_shell_result.out);
    defer allocator.free(ordered_shell_json);
    try assertResultJsonEqual(ordered_query_result.out, ordered_shell_json);

    const unordered_query = "MATCH (n:GAP0257) RETURN n.id AS id";
    const unordered_query_result = try runQueryAgainstServer(allocator, addr, &.{ geode_test_bin.geode_exe, "query", "--format", "json", unordered_query });
    defer allocator.free(unordered_query_result.out);
    defer allocator.free(unordered_query_result.err);
    try assertCommandSucceeded(unordered_query_result);

    const unordered_shell_result = try runShellAgainstServer(allocator, addr, &.{unordered_query ++ ";"});
    defer allocator.free(unordered_shell_result.out);
    defer allocator.free(unordered_shell_result.err);
    try assertCommandSucceeded(unordered_shell_result);

    const unordered_shell_json = try extractLastJsonObject(allocator, unordered_shell_result.out);
    defer allocator.free(unordered_shell_json);

    const query_ids = try extractIntegerColumnValues(allocator, unordered_query_result.out, "id");
    defer allocator.free(query_ids);
    const shell_ids = try extractIntegerColumnValues(allocator, unordered_shell_json, "id");
    defer allocator.free(shell_ids);

    std.mem.sort(i64, query_ids, {}, std.sort.asc(i64));
    std.mem.sort(i64, shell_ids, {}, std.sort.asc(i64));

    try testing.expectEqual(@as(usize, 1000), query_ids.len);
    try testing.expectEqual(@as(usize, 1000), shell_ids.len);
    try testing.expectEqualSlices(i64, query_ids, shell_ids);
}

test "query and shell share explain and profile payload semantics" {
    const allocator = testing.allocator;

    var server = try proto_test_util.spawnServerRandom(allocator, proto_test_util.TestEnv.standard());
    defer server.deinit();
    const addr = server.getAddr();

    const explain_query = "EXPLAIN MATCH (p:ExplainProfileNode) RETURN p.name";
    const explain_query_result = try runJsonQueryAgainstServer(allocator, addr, explain_query);
    defer allocator.free(explain_query_result.out);
    defer allocator.free(explain_query_result.err);
    try assertCommandSucceeded(explain_query_result);

    const explain_shell_result = try runShellAgainstServer(allocator, addr, &.{explain_query ++ ";"});
    defer allocator.free(explain_shell_result.out);
    defer allocator.free(explain_shell_result.err);
    try assertCommandSucceeded(explain_shell_result);

    const explain_shell_json = try extractLastJsonObject(allocator, explain_shell_result.out);
    defer allocator.free(explain_shell_json);
    try assertResultJsonEqual(explain_query_result.out, explain_shell_json);

    try execOkQuery(
        allocator,
        addr,
        "CREATE (:ExplainProfileNode {name: 'alice'}), (:ExplainProfileNode {name: 'bob'})",
    );

    const profile_query = "PROFILE MATCH (p:ExplainProfileNode) RETURN count(p) AS cnt";
    const profile_query_result = try runJsonQueryAgainstServer(allocator, addr, profile_query);
    defer allocator.free(profile_query_result.out);
    defer allocator.free(profile_query_result.err);
    try assertCommandSucceeded(profile_query_result);

    const profile_shell_result = try runShellAgainstServer(allocator, addr, &.{profile_query ++ ";"});
    defer allocator.free(profile_shell_result.out);
    defer allocator.free(profile_shell_result.err);
    try assertCommandSucceeded(profile_shell_result);

    const profile_shell_json = try extractLastJsonObject(allocator, profile_shell_result.out);
    defer allocator.free(profile_shell_json);
    try assertResultJsonEqual(profile_query_result.out, profile_shell_json);
}

test "query and shell share server error payload semantics" {
    const allocator = testing.allocator;

    var server = try proto_test_util.spawnServerRandom(allocator, proto_test_util.TestEnv.standard());
    defer server.deinit();
    const addr = server.getAddr();

    const invalid_query = "MATCH (n RETURN n";

    const query_result = try runJsonQueryAgainstServer(allocator, addr, invalid_query);
    defer allocator.free(query_result.out);
    defer allocator.free(query_result.err);
    try assertCommandSucceeded(query_result);

    const shell_result = try runShellAgainstServer(allocator, addr, &.{invalid_query ++ ";"});
    defer allocator.free(shell_result.out);
    defer allocator.free(shell_result.err);
    try assertCommandSucceeded(shell_result);

    const shell_json = try extractLastJsonObject(allocator, shell_result.out);
    defer allocator.free(shell_json);
    try assertResultJsonEqual(query_result.out, shell_json);
}

test "query file mode and shell source mode apply the same batch semantics" {
    const allocator = testing.allocator;

    var server = try proto_test_util.spawnServerRandom(allocator, proto_test_util.TestEnv.standard());
    defer server.deinit();
    const addr = server.getAddr();

    try execOkQuery(allocator, addr, "CREATE GRAPH IF NOT EXISTS test_query_file_ctx");
    try execOkQuery(allocator, addr, "CREATE GRAPH IF NOT EXISTS test_shell_source_ctx");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const query_file_path = try writeQueryFile(
        &tmp,
        allocator,
        "query_batch.gql",
        "USE GRAPH test_query_file_ctx; CREATE (a:BatchParity {id: 1, name: 'alpha'}); CREATE (b:BatchParity {id: 2, name: 'beta'}); MATCH (a:BatchParity {id: 1}), (b:BatchParity {id: 2}) CREATE (a)-[:LINKED_TO]->(b);",
    );
    defer allocator.free(query_file_path);

    const source_file_path = try writeQueryFile(
        &tmp,
        allocator,
        "source_batch.gql",
        "\\use test_shell_source_ctx\nCREATE (a:BatchParity {id: 1, name: 'alpha'});\nCREATE (b:BatchParity {id: 2, name: 'beta'});\nMATCH (a:BatchParity {id: 1}), (b:BatchParity {id: 2}) CREATE (a)-[:LINKED_TO]->(b);\n",
    );
    defer allocator.free(source_file_path);

    const file_result = try runQueryAgainstServer(
        allocator,
        addr,
        &.{ geode_test_bin.geode_exe, "query", "--format", "json", "--file", query_file_path },
    );
    defer allocator.free(file_result.out);
    defer allocator.free(file_result.err);
    try assertCommandSucceeded(file_result);

    const source_command = try std.fmt.allocPrint(allocator, "/source {s}", .{source_file_path});
    defer allocator.free(source_command);
    const shell_result = try runShellAgainstServer(allocator, addr, &.{source_command});
    defer allocator.free(shell_result.out);
    defer allocator.free(shell_result.err);
    try assertCommandSucceeded(shell_result);

    const verify_query_graph = try runQueryAgainstServer(
        allocator,
        addr,
        &.{ geode_test_bin.geode_exe, "query", "--format", "json", "--graph", "test_query_file_ctx", "MATCH (n:BatchParity) OPTIONAL MATCH ()-[r:LINKED_TO]->() RETURN count(DISTINCT n) AS nodes, count(r) AS rels" },
    );
    defer allocator.free(verify_query_graph.out);
    defer allocator.free(verify_query_graph.err);
    try assertCommandSucceeded(verify_query_graph);

    const verify_shell_graph = try runQueryAgainstServer(
        allocator,
        addr,
        &.{ geode_test_bin.geode_exe, "query", "--format", "json", "--graph", "test_shell_source_ctx", "MATCH (n:BatchParity) OPTIONAL MATCH ()-[r:LINKED_TO]->() RETURN count(DISTINCT n) AS nodes, count(r) AS rels" },
    );
    defer allocator.free(verify_shell_graph.out);
    defer allocator.free(verify_shell_graph.err);
    try assertCommandSucceeded(verify_shell_graph);

    try assertResultJsonEqual(verify_query_graph.out, verify_shell_graph.out);
}
