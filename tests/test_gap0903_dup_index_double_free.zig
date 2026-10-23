// CANARY: REQ=REQ-GAP-0903-DUP-INDEX-DOUBLE-FREE; FEATURE="IndexDDL"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0903_dup_index_double_free.zig:1; OWNER=schema; UPDATED=2026-07-10
//
// Regression tests for GAP-0903: "repeated failing `CREATE INDEX` double-frees
// (segfault)".
//
// Root cause: `Catalog.addIndex` (src/schema/catalog.zig) freed `scoped_key`
// explicitly in the duplicate-name branch AND had an `errdefer` freeing the
// same pointer — errdefer runs on `return error.DuplicateIndex`, so every
// duplicate CREATE INDEX double-freed the key. Under the release allocator
// the corruption surfaced as a segfault after 4-5 repeats; under the test
// DebugAllocator it aborts on the first duplicate attempt.
//
// A sibling hazard in the same function: if `save()` failed after the entry
// was put into the map, the errdefers freed memory the map now owned,
// leaving dangling pointers. Fixed by removing the entry before re-raising.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    session: execution.SessionState,
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
            .session = execution.SessionState.init(allocator),
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.arena.deinit();
        self.tmp.cleanup();
    }

    pub fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

test "GAP-0903: repeated duplicate CREATE INDEX must error each time, never double-free" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH gap0903");
    _ = try h.exec("USE GRAPH gap0903");

    // First creation succeeds.
    _ = try h.exec("CREATE INDEX gap0903_idx ON Gap0903(k)");

    // Every repeat is a clean DuplicateIndex error. Before the fix the very
    // first duplicate double-freed the scoped key (DebugAllocator aborts;
    // the release allocator segfaulted after 4-5 repeats).
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try testing.expectError(error.DuplicateIndex, h.exec("CREATE INDEX gap0903_idx ON Gap0903(k)"));
    }

    // The catalog must still be fully usable afterwards.
    _ = try h.exec("CREATE INDEX gap0903_idx2 ON Gap0903(k2)");
}

test "GAP-0903: IF NOT EXISTS duplicate stays a clean no-op across repeats" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH gap0903b");
    _ = try h.exec("USE GRAPH gap0903b");

    _ = try h.exec("CREATE INDEX gap0903b_idx ON Gap0903b(k)");
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        _ = try h.exec("CREATE INDEX IF NOT EXISTS gap0903b_idx ON Gap0903b(k)");
    }
}
