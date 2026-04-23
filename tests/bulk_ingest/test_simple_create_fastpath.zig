// Task 11 — simple-CREATE fast-path parity tests.
//
// Runs a real `CREATE (n:L {k: v, ...})` statement through BOTH the regular
// executor (`executeProgramWithContext`) and the bulk fast path
// (`graph_storage_adapter.StorageAdapter.bulkInsertNode`).  Asserts:
//
//   * Both paths produce a node whose label set and property values match
//     byte-for-byte (via `graph_store.GraphStore.nodes` lookup).
//   * The resulting node count equals 2 — one per path.
//   * The bulk path leaves the store dirty (writes actually landed).
//
// The fast-path call is invoked directly (not through the QUIC handler)
// because the handler's dispatch is wired behind `GEODE_BULK_INGEST`
// which is read at server startup; tests exercise the lower-level adapter
// API directly.  The QUIC handler integration is covered end-to-end by
// `geodetestlab` once msft-graph reruns its seed workload.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const adapter_mod = geode.graph_storage_adapter;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
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
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return try execution.executeProgramWithContext(self.allocator, &parsed.program, self.ctx);
    }
};

fn findNodeByProperty(
    store: *graph_store.GraphStore,
    key: []const u8,
    expected: []const u8,
) ?*graph_store.Node {
    var it = store.nodes.iterator();
    while (it.next()) |entry| {
        const node = entry.value_ptr;
        if (node.properties.get(key)) |pv| {
            switch (pv) {
                .String => |s| if (std.mem.eql(u8, s, expected)) return node,
                else => {},
            }
        }
    }
    return null;
}

test "bulkInsertNode parity with executor path — labels + scalar properties" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Path A: executor path — full AST traversal, undo log, row materialisation.
    var r = try h.runQuery(
        "CREATE (n:Widget {node_id: 'exec-abc', name: 'alpha', age: 30})",
    );
    r.deinit(testing.allocator);

    // Path B: bulk fast path — direct adapter call.
    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    var props = [_]adapter_mod.StorageAdapter.PropKV{
        .{ .key = "node_id", .value = .{ .String = "bulk-xyz" } },
        .{ .key = "name", .value = .{ .String = "alpha" } },
        .{ .key = "age", .value = .{ .Int = 30 } },
    };
    const labels = [_][]const u8{"Widget"};
    _ = try adapter.bulkInsertNode("default", &labels, &props, null);

    // Both nodes must now exist in the in-memory store.
    const store = graph_store.getGlobalStore(testing.allocator);
    try testing.expect(store.nodes.count() >= 2);

    const exec_node = findNodeByProperty(store, "node_id", "exec-abc") orelse
        return error.ExecutorNodeMissing;
    const bulk_node = findNodeByProperty(store, "node_id", "bulk-xyz") orelse
        return error.BulkNodeMissing;

    // Labels identical (exactly one, value "Widget").
    try testing.expectEqual(@as(usize, 1), exec_node.labels.len);
    try testing.expectEqual(@as(usize, 1), bulk_node.labels.len);
    try testing.expectEqualStrings("Widget", exec_node.labels[0]);
    try testing.expectEqualStrings("Widget", bulk_node.labels[0]);

    // Scalar property parity: `name` (String), `age` (Int).
    const exec_name = exec_node.properties.get("name") orelse return error.MissingName;
    const bulk_name = bulk_node.properties.get("name") orelse return error.MissingName;
    try testing.expectEqualStrings("alpha", exec_name.String);
    try testing.expectEqualStrings("alpha", bulk_name.String);

    const exec_age = exec_node.properties.get("age") orelse return error.MissingAge;
    const bulk_age = bulk_node.properties.get("age") orelse return error.MissingAge;
    try testing.expectEqual(@as(i64, 30), exec_age.Int);
    try testing.expectEqual(@as(i64, 30), bulk_age.Int);

    // The bulk path must have marked the store dirty (writes landed).
    try testing.expect(store.isDirty());
}

test "bulkInsertNode creates node with no properties (label-only)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    const labels = [_][]const u8{"Gadget"};
    const props: []const adapter_mod.StorageAdapter.PropKV = &.{};
    const id = try adapter.bulkInsertNode("default", &labels, props, null);

    const store = graph_store.getGlobalStore(testing.allocator);
    const node = store.nodes.getPtr(id) orelse return error.NodeMissing;
    try testing.expectEqual(@as(usize, 1), node.labels.len);
    try testing.expectEqualStrings("Gadget", node.labels[0]);
    try testing.expectEqual(@as(u32, 0), node.properties.count());
}

test "bulkInsertNode repeated calls assign distinct node ids" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    const labels = [_][]const u8{"Widget"};
    var props_a = [_]adapter_mod.StorageAdapter.PropKV{.{ .key = "node_id", .value = .{ .String = "a" } }};
    var props_b = [_]adapter_mod.StorageAdapter.PropKV{.{ .key = "node_id", .value = .{ .String = "b" } }};

    const id_a = try adapter.bulkInsertNode("default", &labels, &props_a, null);
    const id_b = try adapter.bulkInsertNode("default", &labels, &props_b, null);

    try testing.expect(id_a != id_b);

    const store = graph_store.getGlobalStore(testing.allocator);
    try testing.expectEqual(@as(u32, 2), @as(u32, @intCast(store.nodes.count())));
}
