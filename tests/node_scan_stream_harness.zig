//! Shared harness for engine-direct node-scan-stream regressions (SONNY-1221
//! and its follow-ups). It provides an in-process PERSISTED deployment, so the
//! fast path is live, and helpers to open a fast-path stream and page it.
//! A test module that imports this file also needs the `geode` and `logging`
//! modules.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const logging = @import("logging");

const execution = geode.execution;
const graph_store = geode.graph_store;
const node_scan_stream = geode.node_scan_stream;
const proto_util = geode.proto_util;

/// Pin the engine logger to `.fatal`: the in-process handlers log every request
/// at info, which the build runner would echo back as piped stderr.
pub fn silenceEngineLogs() void {
    logging.init(.{ .level = .fatal });
    logging.setLevel(.fatal);
}

pub fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// In-process PERSISTED deployment (`--data-dir`): the storage adapter exists,
/// so the engine-direct fast path is live (SONNY-1218 declines without it).
pub const Harness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    arena: std.heap.ArenaAllocator,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);
        // Fail loud rather than prove nothing: without the adapter every read
        // below would be the executor's.
        if (graph_store.getGlobalAdapter() == null) return error.ExpectedPersistedAdapter;

        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .tmp = tmp,
            .data_dir = data_dir,
            .arena = std.heap.ArenaAllocator.init(allocator),
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

    pub fn run(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    /// Run each statement through the executor, discarding its result.
    pub fn seed(self: *Harness, queries: []const []const u8) !void {
        for (queries) |q| {
            var r = try self.run(q);
            r.deinit(self.arena.allocator());
        }
    }

    /// The executor path's schema types for `query` (arena-owned).
    pub fn executorTypes(self: *Harness, query: []const u8) ![]const []const u8 {
        const aa = self.arena.allocator();
        var result = try self.run(query);
        defer result.deinit(aa);
        const def = try proto_util.buildSchemaDefinition(aa, &result);
        const types = try aa.alloc([]const u8, def.columns.items.len);
        for (def.columns.items, 0..) |col, i| types[i] = col.type;
        return types;
    }
};

/// More rows than one type sample (10), spread over several small pages.
pub const many: usize = 25;
pub const many_query = "MATCH (n:M) RETURN n.s, n.i";

/// `many` `:M` nodes, with s = 's00'..'s24' and i = 0..24.
pub fn seedMany(h: *Harness) !void {
    const aa = h.arena.allocator();
    for (0..many) |i| {
        var r = try h.run(try std.fmt.allocPrint(aa, "CREATE (:M {{s: 's{d:0>2}', i: {d}}})", .{ i, i }));
        r.deinit(aa);
    }
}

pub fn parseQuery(arena: *std.heap.ArenaAllocator, src: []const u8) !*const geode.gql.ast.Query {
    var lx = geode.gql.lexer.Lexer{ .src = src };
    var p = geode.gql.parser.Parser{ .lx = &lx, .arena = arena, .cur = lx.next() };
    const program = try p.parseProgram();
    return &program.statements[0].Query;
}

/// A fast-path stream for `src`. `query_arena` must outlive it: the stream
/// borrows column names from the parsed query.
pub fn openStream(
    h: *Harness,
    allocator: std.mem.Allocator,
    query_arena: *std.heap.ArenaAllocator,
    src: []const u8,
) !node_scan_stream.NodeScanStream {
    const q = try parseQuery(query_arena, src);
    return (try node_scan_stream.prepare(allocator, q, h.ctx, &.{}, &.{}, &.{})) orelse error.FastPathDeclined;
}

/// Page `stream` to its end with `page_size` and return column 0 (`n.s`) in
/// serve order, owned by `allocator`. Every page but the last must be full.
pub fn drainColumn0(stream: *node_scan_stream.NodeScanStream, allocator: std.mem.Allocator, page_size: usize) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }
    const full = if (page_size == 0) node_scan_stream.default_page_rows else page_size;
    var pages: usize = 0;
    while (true) : (pages += 1) {
        if (pages > many + 1) return error.NeverFinal;
        var page = try stream.buildNextPage(allocator, page_size);
        defer page.result.deinit(allocator);
        if (!page.final) try testing.expectEqual(full, page.result.rows.len);
        for (page.result.rows) |row| try out.append(allocator, try allocator.dupe(u8, row[0].Str));
        if (page.final) break;
    }
    try testing.expect(!stream.hasRemaining());
    return out.toOwnedSlice(allocator);
}

pub fn freeStrings(allocator: std.mem.Allocator, items: [][]const u8) void {
    for (items) |s| allocator.free(s);
    allocator.free(items);
}

pub fn expectDistinct(items: []const []const u8) !void {
    for (items, 0..) |s, i| {
        for (items[i + 1 ..]) |t| try testing.expect(!std.mem.eql(u8, s, t));
    }
}
