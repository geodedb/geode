// Shared fixture for the SONNY-6338 / SONNY-2820 / SONNY-2848 regressions: a
// persisted deployment with a live, globally published expr-RLS engine whose
// tenant hierarchy holds P -> {C1, C2} and an unrelated root U, all in one
// graph, driven through the real parse -> execute pipeline.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls = @import("rls");
const rls_types = @import("rls_types");

const execution = geode.execution;
const graph_store = geode.graph_store;
const tenancy = geode.tenancy;
const query_arena = geode.query_arena;

pub const P = "t6338-parent";
pub const C1 = "t6338-child1";
pub const C2 = "t6338-child2";
pub const U = "t6338-unrelated";

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// A persisted deployment with a live, globally published expr-RLS engine whose
/// hierarchy holds P -> {C1, C2} and U (the same harness shape as
/// tests/test_sonny1326_expression_tenancy.zig and test_gap0846).
pub const Harness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    engine: *rls.RLSEngine,
    ctx: execution.ExecutionContext,
    arena: std.heap.ArenaAllocator,
    strict: bool,
    /// Mismatches recorded by `expectInt`, reported together.
    mismatches: usize = 0,

    pub fn init(allocator: std.mem.Allocator, strict: bool) !Harness {
        execution.initEvaluator();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
        tenancy.setStrictTenancy(strict);
        tenancy.resetWarnState();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);
        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);
        const catalog = try execution.ensureCatalogInstance(allocator);

        const engine = try allocator.create(rls.RLSEngine);
        errdefer allocator.destroy(engine);
        engine.* = try rls.RLSEngine.init(allocator);
        rls_types.setGlobalExprRLSEngine(@ptrCast(engine));
        try engine.hierarchy_manager.addTenant(P, null);
        try engine.hierarchy_manager.addTenant(C1, P);
        try engine.hierarchy_manager.addTenant(C2, P);
        try engine.hierarchy_manager.addTenant(U, null);

        return .{
            .allocator = allocator,
            .tmp = tmp,
            .data_dir = data_dir,
            .engine = engine,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
            .arena = std.heap.ArenaAllocator.init(allocator),
            .strict = strict,
        };
    }

    pub fn deinit(self: *Harness) void {
        self.arena.deinit();
        rls_types.setGlobalExprRLSEngine(null);
        self.engine.deinit();
        self.allocator.destroy(self.engine);
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
        tenancy.setStrictTenancy(false);
        tenancy.resetWarnState();
    }

    /// Close the store and open it again from disk (the catalog and the
    /// hierarchy stay, as they do across a server restart that rehydrates them).
    pub fn reopen(self: *Harness) !void {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        _ = graph_store.getGlobalStore(self.allocator);
        self.ctx = execution.ExecutionContext{ .catalog = try execution.ensureCatalogInstance(self.allocator) };
    }

    pub fn ctxFor(self: *const Harness, tenant: ?[]const u8) execution.ExecutionContext {
        var c = self.ctx;
        c.tenant_id = tenant;
        return c;
    }

    /// Run one statement as `tenant`'s session, as a transport does after
    /// HELLO (the active ExecutionContext and the per-thread FLE tenant).
    /// The result lives in the harness arena.
    pub fn run(self: *Harness, tenant: ?[]const u8, src: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(src, aa);
        defer parsed.deinit();
        const prev_scratch = query_arena.pushScratchAllocator(aa);
        defer query_arena.popScratchAllocator(prev_scratch);
        geode.fle_integration.setCurrentTenantId(tenant);
        defer geode.fle_integration.setCurrentTenantId(null);
        // The admin's reads in a strict-tenancy fixture are the operator's
        // view, taken with strict tenancy off for that one statement.
        if (tenant == null and self.strict) tenancy.setStrictTenancy(false);
        defer if (tenant == null and self.strict) tenancy.setStrictTenancy(true);
        const ctx = self.ctxFor(tenant);
        const prev_ctx = execution.pushActiveContext(&ctx);
        defer execution.popActiveContext(prev_ctx);
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx);
    }

    pub fn exec(self: *Harness, tenant: ?[]const u8, src: []const u8) !void {
        _ = try self.run(tenant, src);
    }

    pub fn int(self: *Harness, tenant: ?[]const u8, src: []const u8) !i64 {
        const res = try self.run(tenant, src);
        if (res.rows.len == 0 or res.rows[0].len == 0) return error.NoRows;
        return switch (res.rows[0][0]) {
            .Int => |i| i,
            .Bool => |b| @intFromBool(b),
            else => error.UnexpectedValueType,
        };
    }

    /// `int`, recording a mismatch (with the query) instead of failing at once.
    pub fn expectInt(self: *Harness, want: i64, tenant: ?[]const u8, src: []const u8) void {
        const got = self.int(tenant, src) catch |err| {
            std.debug.print("MISMATCH tenant={?s} want {d} got error {s}: {s}\n", .{ tenant, want, @errorName(err), src });
            self.mismatches += 1;
            return;
        };
        if (got != want) {
            std.debug.print("MISMATCH tenant={?s} want {d} got {d}: {s}\n", .{ tenant, want, got, src });
            self.mismatches += 1;
        }
    }

    /// The node ids a `RETURN knn(...)` returned, in order.
    pub fn ids(self: *Harness, tenant: ?[]const u8, src: []const u8) ![]const u64 {
        const res = try self.run(tenant, src);
        if (res.rows.len == 0 or res.rows[0].len == 0) return error.NoRows;
        const aa = self.arena.allocator();
        var out: std.ArrayList(u64) = .empty;
        switch (res.rows[0][0]) {
            .List => |items| for (items) |cell| switch (cell) {
                .Int => |i| try out.append(aa, @intCast(i)),
                else => return error.UnexpectedValueType,
            },
            else => return error.UnexpectedValueType,
        }
        return out.items;
    }

    /// The (only) node carrying `who` = `name`, read as an admin.
    pub fn nodeId(self: *Harness, label: []const u8, name: []const u8) !u64 {
        const q = try std.fmt.allocPrint(self.arena.allocator(), "MATCH (n:{s} {{who: '{s}'}}) RETURN id(n)", .{ label, name });
        const res = try self.run(null, q);
        if (res.rows.len != 1) return error.NotExactlyOneNode;
        return switch (res.rows[0][0]) {
            .Int => |i| @intCast(i),
            else => error.UnexpectedValueType,
        };
    }

    pub fn tagOf(self: *Harness, id: u64) ![]const u8 {
        _ = self;
        const store = graph_store.getGlobalStore(testing.allocator);
        const tag = store.dupeNodeTenantForRead(testing.allocator, id) orelse return error.NodeNotFound;
        defer testing.allocator.free(tag);
        return testing.allocator.dupe(u8, tag);
    }
};

pub fn expectTag(h: *Harness, id: u64, want: []const u8) !void {
    const tag = try h.tagOf(id);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings(want, tag);
}
