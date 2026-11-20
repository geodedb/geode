// SONNY-6460 item 4: a statement evaluated outside the executor's statement
// entry points (`execution.executeStatementWithContext`,
// `execution.executeProgramWithContext`) had no statement scratch arena, so
// what the evaluator lends a caller (a member read's copy: a list property,
// a decrypted or redacted FLE string; `eval.lentValueAllocator`) was
// allocated on the caller's allocator and freed by no one. The embedded
// PROFILE path, `planned_read_runtime.executeProfiledIfSupported`, is such
// an entry point: it runs a statement of its own and is `pub`. It now opens
// the statement scratch itself (`query_arena.StatementScratch`) and copies
// its result out before closing it, as the other entry points do.
//
// Leak-checked over std.testing.allocator with a real FLE catalog, a
// persisted store (the planned read runtime serves it) and the real
// executor. No mocks.
//
// CANARY: REQ=REQ-SONNY-6460-PROFILE-SCRATCH; FEATURE="ExecutionResultOwnership"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6460_unscoped_eval.zig; OWNER=execution; UPDATED=2026-11-13

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const logging = @import("logging");

const graph_store = geode.graph_store;
const execution = geode.execution;
const index_manager = geode.index_manager;
const fle_integration = geode.fle_integration;
const fle_catalog = fle_integration.catalog_mod;
const query_arena = geode.query_arena;
const node_scan_stream = geode.node_scan_stream;
const Value = geode.value_types.Value;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const master_key = "6449a6449a6449a6449a6449a6449a6449a6449a6449a6449a6449a6449a6449";

const SavedEnv = struct {
    name: [:0]const u8,
    value: ?[:0]u8,

    fn take(name: [:0]const u8) !SavedEnv {
        const v: ?[:0]u8 = if (std.c.getenv(name.ptr)) |p| try testing.allocator.dupeZ(u8, std.mem.span(p)) else null;
        return .{ .name = name, .value = v };
    }

    fn restore(self: SavedEnv) void {
        if (self.value) |v| {
            _ = setenv(self.name.ptr, v.ptr, 1);
            testing.allocator.free(v);
        } else _ = unsetenv(self.name.ptr);
    }
};

/// Where the graph lives: in memory (the executor's paths), or persisted in
/// a data directory, where the storage adapter and the planned read runtime
/// serve reads.
const Store = enum { memory, persisted };

/// An executor with FLE configured on `S6449P.ssn` and `S6449W.ssn`,
/// readable in plaintext by role `pii` only.
const Fixture = struct {
    tmp: ?std.testing.TmpDir,
    data_dir: ?[]u8,
    env_data_dir: SavedEnv,
    env_key: SavedEnv,
    arena: std.heap.ArenaAllocator,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    fn init(self: *Fixture, store: Store) !void {
        logging.init(.{ .level = .fatal });
        logging.setLevel(.fatal);
        self.env_data_dir = try SavedEnv.take("GEODE_DATA_DIR");
        self.env_key = try SavedEnv.take("GEODE_MASTER_KEY");
        _ = unsetenv("GEODE_DATA_DIR");
        fle_catalog.setDataDirOverride(null);
        fle_catalog.resetGlobalCatalog(testing.allocator);
        fle_integration.setHasEncryptedFields(false);
        fle_integration.resetGlobalKeyStateForTesting();
        _ = setenv("GEODE_MASTER_KEY", master_key, 1);
        _ = try fle_integration.getCurrentKeyVersion(.{ .tenant_id = "default", .schema_name = "S6449", .allocator = std.heap.smp_allocator }, "init");
        const catalog = try fle_catalog.globalCatalog(testing.allocator);
        var roles = [_][]const u8{"pii"};
        try catalog.configureField("S6449P", .{ .field_name = "ssn", .encryption = .{ .enabled = true }, .visibility = .{ .to_roles = &roles } });
        try catalog.configureField("S6449W", .{ .field_name = "ssn", .encryption = .{ .enabled = true }, .visibility = .{ .to_roles = &roles } });

        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        self.tmp = null;
        self.data_dir = null;
        if (store == .persisted) {
            self.tmp = std.testing.tmpDir(.{});
            self.data_dir = try tmpDirRealpathAlloc(testing.allocator, &self.tmp.?.sub_path);
            graph_store.setDataDirOverride(testing.allocator, self.data_dir.?);
        }
        _ = graph_store.getGlobalStore(testing.allocator);
        if (store == .persisted and graph_store.getGlobalAdapter() == null) return error.ExpectedPersistedAdapter;
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.session = execution.SessionState.init(testing.allocator);
        self.ctx = .{ .catalog = try execution.ensureCatalogInstance(testing.allocator) };
        self.ctx.session_state = &self.session;

        // Three nodes, so a DISTINCT, a GROUP BY and an ORDER BY have work:
        // i = 0, 1, 2 hold the values of key 0, 1, 0.
        for (0..3) |i| {
            const k = i % 2;
            const q = try std.fmt.allocPrint(self.arena.allocator(), "CREATE (:S6449P {{i: {d}, s: 'plain-{d}', ssn: 'secret-{d}', v: ['a', 'b{d}']}})", .{ i, k, k, k });
            var r = try self.exec(self.arena.allocator(), "pii", q);
            r.deinit(self.arena.allocator());
        }
    }

    fn deinit(self: *Fixture) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        if (self.data_dir) |d| testing.allocator.free(d);
        if (self.tmp) |*t| t.cleanup();
        self.arena.deinit();
        fle_catalog.setDataDirOverride(null);
        fle_catalog.resetGlobalCatalog(testing.allocator);
        fle_integration.setHasEncryptedFields(false);
        fle_integration.resetGlobalKeyStateForTesting();
        self.env_key.restore();
        self.env_data_dir.restore();
    }

    fn exec(self: *Fixture, allocator: std.mem.Allocator, role: ?[]const u8, query: []const u8) !execution.ExecutionResult {
        self.ctx.fle_role = role;
        fle_integration.setCurrentUserRole(role);
        defer fle_integration.clearCurrentThreadState();
        var parsed = try geode.parseGqlOptions(query, self.arena.allocator(), .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(allocator, parsed.program.statements[0], self.ctx);
    }
};

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..cwd_len], tmp_sub_path });
}

const planned_read_runtime = geode.planned_read_runtime;

/// Runs `query` through the embedded PROFILE entry point on
/// `std.testing.allocator`, with no scratch arena installed, as role `role`,
/// and returns its rows rendered; the result is freed before returning.
fn profiled(fx: *Fixture, role: ?[]const u8, query: []const u8) ![]const []const u8 {
    try testing.expect(query_arena.currentScratchAllocator() == null);
    fx.ctx.fle_role = role;
    fle_integration.setCurrentUserRole(role);
    defer fle_integration.clearCurrentThreadState();
    var parsed = try geode.parseGqlOptions(query, fx.arena.allocator(), .{});
    defer parsed.deinit();
    const q = &parsed.program.statements[0].Query;
    var run = (try planned_read_runtime.executeProfiledIfSupported(testing.allocator, q, fx.ctx, &.{}, &.{}, true)) orelse return error.NotPlanned;
    defer run.deinitMetadata(testing.allocator);
    defer run.result.deinit(testing.allocator);
    const aa = fx.arena.allocator();
    const out = try aa.alloc([]const u8, run.result.rows.len);
    for (run.result.rows, out) |row, *o| {
        o.* = switch (row[0]) {
            .Str => |s| try aa.dupe(u8, s),
            .List => |l| try std.fmt.allocPrint(aa, "list of {d}", .{l.len}),
            .Null => "null",
            else => try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(row[0])}),
        };
    }
    std.mem.sort([]const u8, out, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return out;
}

fn expectRows(got: []const []const u8, want: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "SONNY-6460 (4): embedded PROFILE frees the member reads it lends: a plain list property" {
    var fx: Fixture = undefined;
    try fx.init(.persisted);
    defer fx.deinit();
    try expectRows(try profiled(&fx, "pii", "MATCH (n:S6449P) RETURN n.v"), &.{ "list of 2", "list of 2", "list of 2" });
}

test "SONNY-6460 (4): embedded PROFILE frees the member reads it lends: an FLE field, decrypted and redacted" {
    var fx: Fixture = undefined;
    try fx.init(.persisted);
    defer fx.deinit();
    try expectRows(try profiled(&fx, "pii", "MATCH (n:S6449P) RETURN n.ssn"), &.{ "secret-0", "secret-0", "secret-1" });
    const redacted = try profiled(&fx, null, "MATCH (n:S6449P) RETURN n.ssn");
    try testing.expectEqual(@as(usize, 3), redacted.len);
    for (redacted) |r| try testing.expect(std.mem.indexOf(u8, r, "secret") == null);
}
