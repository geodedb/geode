// Shared real-executor fixture for SONNY-6291/6292 auth regressions.
const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const execution = geode.execution;
const graph_store = geode.graph_store;
const users = geode.user_management;
const audit = geode.security.audit;

pub const Harness = struct {
    tmp: testing.TmpDir,
    data_dir: []u8,
    audit_path: []u8,
    logger: *audit.AuditLogger,
    catalog: *geode.catalog.Catalog,
    arena: std.heap.ArenaAllocator,
    auth_was: bool,

    pub fn init() !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        users.deinitUserStore();
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = try std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf);
        const cwd = std.mem.trimEnd(u8, cwd_buf[0..cwd_len], "\x00");
        const data_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd, tmp.sub_path });
        errdefer testing.allocator.free(data_dir);
        graph_store.setDataDirOverride(testing.allocator, data_dir);
        _ = graph_store.getGlobalStore(testing.allocator);
        const catalog = try execution.ensureCatalogInstance(testing.allocator);
        const audit_path = try std.fmt.allocPrint(testing.allocator, "{s}/audit.jsonl", .{data_dir});
        errdefer testing.allocator.free(audit_path);
        const logger = try audit.AuditLogger.createHeap(testing.allocator, .{ .enabled = true, .file_path = audit_path });
        audit.setGlobalAuditLogger(logger);
        try users.createUserWithHash(testing.allocator, "alice", "unused-test-hash", "alice@example.test", .User, false);
        try users.createUserWithHash(testing.allocator, "bob", "unused-test-hash", "bob@example.test", .ReadOnly, false);
        const auth_was = users.isAuthEnabled();
        users.setAuthEnabled(true);
        return .{ .tmp = tmp, .data_dir = data_dir, .audit_path = audit_path, .logger = logger, .catalog = catalog, .arena = std.heap.ArenaAllocator.init(testing.allocator), .auth_was = auth_was };
    }

    pub fn deinit(self: *Harness) void {
        self.arena.deinit();
        users.setAuthEnabled(self.auth_was);
        users.deinitUserStore();
        audit.setGlobalAuditLogger(null);
        self.logger.deinit();
        testing.allocator.destroy(self.logger);
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.audit_path);
        testing.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn run(self: *Harness, query: []const u8, role: ?users.Role, username: ?[]const u8) !execution.ExecutionResult {
        const allocator = self.arena.allocator();
        var parsed = try geode.parseGql(query, allocator);
        defer parsed.deinit();
        return execution.executeStatementWithContext(allocator, parsed.program.statements[0], .{ .catalog = self.catalog, .role = role, .user = username });
    }
};
