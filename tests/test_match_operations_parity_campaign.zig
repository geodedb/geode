const std = @import("std");
const geode = @import("geode");


// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;
var parity_campaign_mutex: std.Io.Mutex = .init;

// CANARY: REQ=REQ-QUALITY-401-001; FEATURE="MatchOpsStagedParity"; ASPECT=GoldenParity; STATUS=TESTED; TEST=tests/test_match_operations_parity_campaign.zig; OWNER=execution; UPDATED=2026-02-16
// Stage parity suite for MATCH refactor checkpoints. These golden assertions guard
// behavior while executeMatchQueryImpl is decomposed incrementally.

const Harness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        var parsed = try geode.parseGql(query, self.allocator);
        defer parsed.deinit();
        return execution.executeStatementWithContext(self.allocator, parsed.program.statements[0], self.ctx);
    }
};

fn seedParityGraph(allocator: std.mem.Allocator) !void {
    const store = graph_store.getGlobalStore(allocator);
    const person_labels = @constCast(&[_][]const u8{"Person"});

    const alice = try store.createNode(person_labels);
    const bob = try store.createNode(person_labels);
    const carol = try store.createNode(person_labels);
    const dave = try store.createNode(person_labels);

    try store.setNodeProperty(alice, "name", .{ .String = "Alice" });
    try store.setNodeProperty(alice, "age", .{ .Int = 31 });

    try store.setNodeProperty(bob, "name", .{ .String = "Bob" });
    try store.setNodeProperty(bob, "age", .{ .Int = 42 });

    try store.setNodeProperty(carol, "name", .{ .String = "Carol" });
    try store.setNodeProperty(carol, "age", .{ .Int = 35 });

    try store.setNodeProperty(dave, "name", .{ .String = "Dave" });
    try store.setNodeProperty(dave, "age", .{ .Int = 29 });

    _ = try store.createEdge(alice, bob, "KNOWS");
    _ = try store.createEdge(alice, carol, "KNOWS");
    _ = try store.createEdge(bob, dave, "KNOWS");
    _ = try store.createEdge(carol, dave, "KNOWS");
}

fn expectValueStr(v: Value, expected: []const u8) !void {
    switch (v) {
        .Str => |actual| try std.testing.expectEqualStrings(expected, actual),
        else => return error.UnexpectedValueTag,
    }
}

fn expectValueInt(v: Value, expected: i64) !void {
    switch (v) {
        .Int => |actual| try std.testing.expectEqual(expected, actual),
        else => return error.UnexpectedValueTag,
    }
}

test "match refactor parity: single-hop and aggregation goldens" {
    parity_campaign_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer parity_campaign_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    try seedParityGraph(allocator);

    var rel_rows = try h.exec(
        "MATCH (a:Person)-[:KNOWS]->(b:Person) " ++
            "RETURN a.name AS src, b.name AS dst ORDER BY src, dst",
    );
    defer rel_rows.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), rel_rows.rows.len);
    try expectValueStr(rel_rows.rows[0][0], "Alice");
    try expectValueStr(rel_rows.rows[0][1], "Bob");
    try expectValueStr(rel_rows.rows[1][0], "Alice");
    try expectValueStr(rel_rows.rows[1][1], "Carol");
    try expectValueStr(rel_rows.rows[2][0], "Bob");
    try expectValueStr(rel_rows.rows[2][1], "Dave");
    try expectValueStr(rel_rows.rows[3][0], "Carol");
    try expectValueStr(rel_rows.rows[3][1], "Dave");

    var grouped = try h.exec(
        "MATCH (a:Person)-[:KNOWS]->(b:Person) " ++
            "RETURN a.name AS src, count(*) AS c GROUP BY a.name ORDER BY src",
    );
    defer grouped.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), grouped.rows.len);
    try expectValueStr(grouped.rows[0][0], "Alice");
    try expectValueInt(grouped.rows[0][1], 2);
    try expectValueStr(grouped.rows[1][0], "Bob");
    try expectValueInt(grouped.rows[1][1], 1);
    try expectValueStr(grouped.rows[2][0], "Carol");
    try expectValueInt(grouped.rows[2][1], 1);
}

test "match refactor parity: variable-length and filtering goldens" {
    parity_campaign_mutex.lock(std.Io.Threaded.global_single_threaded.io()) catch unreachable;
    defer parity_campaign_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h = try Harness.init(allocator);
    defer h.deinit();

    try seedParityGraph(allocator);

    var var_len = try h.exec(
        "MATCH (a:Person)-[:KNOWS*2..2]->(b:Person) " ++
            "RETURN count(*) AS c",
    );
    defer var_len.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), var_len.rows.len);
    try expectValueInt(var_len.rows[0][0], 2);

    var filtered = try h.exec(
        "MATCH (p:Person) WHERE p.age >= 35 " ++
            "RETURN p.name AS name ORDER BY name LIMIT 2",
    );
    defer filtered.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), filtered.rows.len);
    try expectValueStr(filtered.rows[0][0], "Bob");
    try expectValueStr(filtered.rows[1][0], "Carol");
}
