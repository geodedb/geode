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

// CANARY: REQ=REQ-GQL-017; FEATURE="Match Label+Property Predicate"; ASPECT=Execution; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_MatchLabelProperty; OWNER=engine; UPDATED=2025-09-21

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

fn hashNodeIds(allocator: std.mem.Allocator, rows: [][]geode.value_types.Value) u64 {
    var ids = std.ArrayList(u64).init(allocator);
    defer ids.deinit(allocator);

    for (rows) |row| {
        if (row.len == 0) continue;
        if (std.meta.activeTag(row[0]) == .Node) {
            ids.append(row[0].Node.id) catch {};
        }
    }

    std.mem.sort(u64, ids.items, {}, std.sort.asc(u64));
    var h: u64 = 0;
    for (ids.items) |id| {
        h = std.hash.wyhash64(&@as([8]u8, @bitCast(id)), h);
    }
    return h;
}

pub fn TestCANARY_REQ_GQL_017_MatchLabelProperty() !void {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    const id1 = try store.createNode(&.{"Person"});
    const id2 = try store.createNode(&.{"Person"});
    const id3 = try store.createNode(&.{"Animal"});

    try store.setNodeProperty(id1, "name", .{ .String = "Alice" });
    try store.setNodeProperty(id2, "name", .{ .String = "Bob" });
    try store.setNodeProperty(id3, "name", .{ .String = "Cat" });

    var res = try h.exec("MATCH (n:Person { name: \"Alice\" }) RETURN n");
    defer res.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try std.testing.expect(std.meta.activeTag(res.rows[0][0]) == .Node);
    try std.testing.expectEqual(id1, res.rows[0][0].Node.id);

    var neg = try h.exec("MATCH (x:DoesNotExist { name: \"Alice\" }) RETURN x");
    defer neg.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), neg.rows.len);
}

// CANARY: REQ=REQ-GQL-017; FEATURE="Match Label+Property Predicate"; ASPECT=EquivalenceDeterminism; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_MatchLabelPropertyEquivalenceDeterminism; OWNER=engine; UPDATED=2025-09-21
pub fn TestCANARY_REQ_GQL_017_MatchLabelPropertyEquivalenceDeterminism() !void {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    const id1 = try store.createNode(&.{"Person"});
    const id2 = try store.createNode(&.{"Person"});
    try store.setNodeProperty(id1, "name", .{ .String = "Alice" });
    try store.setNodeProperty(id2, "name", .{ .String = "Alice" });

    var inline_res = try h.exec("MATCH (n:Person { name: \"Alice\" }) RETURN n");
    defer inline_res.deinit(allocator);

    var where_res = try h.exec("MATCH (m:Person) WHERE m.name = \"Alice\" RETURN m");
    defer where_res.deinit(allocator);

    try std.testing.expectEqual(inline_res.rows.len, where_res.rows.len);

    const hash_inline = hashNodeIds(allocator, inline_res.rows);
    const hash_where = hashNodeIds(allocator, where_res.rows);
    try std.testing.expectEqual(hash_inline, hash_where);

    var repeat: usize = 0;
    while (repeat < 10) : (repeat += 1) {
        var again = try h.exec("MATCH (n:Person { name: \"Alice\" }) RETURN n");
        defer again.deinit(allocator);
        try std.testing.expectEqual(hash_inline, hashNodeIds(allocator, again.rows));
    }
}

// CANARY: REQ=REQ-GQL-017; FEATURE="Match Label+Property Predicate"; ASPECT=OptionalMatchNullPreserve; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_OptionalMatchNullPreserve; OWNER=engine; UPDATED=2025-09-21
pub fn TestCANARY_REQ_GQL_017_OptionalMatchNullPreserve() !void {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    const id = try store.createNode(&.{"Person"});
    try store.setNodeProperty(id, "name", .{ .String = "Solo" });

    var res = try h.exec("MATCH (n:Person { name: \"Solo\" }) OPTIONAL MATCH (m:Animal { name: \"Ghost\" }) RETURN n, m");
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try std.testing.expect(std.meta.activeTag(res.rows[0][0]) == .Node);
    try std.testing.expect(res.rows[0][1] == .Null);
}
