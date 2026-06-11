// GAP-0871: GQL BACKUP/RESTORE statements are intentionally unsupported.
//
// The supported surface is the engine-backed CLI (`geode backup create` /
// `geode restore`). The parser accepts the GQL `BACKUP`/`RESTORE` forms
// (so the refusal is a clean executor-level contract, not a parse error),
// and the executor returns the STABLE named error
// `error.GqlBackupRestoreUnsupported` instead of a bare `NotImplemented`.
// The wire layer maps it to SQLSTATE 0A000 ("feature not supported") with a
// client-visible message naming the CLI alternative — same pattern as
// GAP-0856 (`error.DistributedExplainUnsupported`).
//
// CANARY: REQ=REQ-GQL-BACKUP-REFUSAL-001; FEATURE="GqlBackupRestoreRefusal"; ASPECT=StableUnsupportedContract; STATUS=TESTED; TEST=tests/test_gap0871_gql_backup_refusal.zig; OWNER=engine; UPDATED=2026-06-11

const std = @import("std");
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const proto_util = geode.proto_util;

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by
// joining cwd with the relative tmp sub_path.
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

    pub fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        var parsed = try geode.parseGql(query, self.allocator);
        defer parsed.deinit();
        return execution.executeStatementWithContext(self.allocator, parsed.program.statements[0], self.ctx);
    }
};

// ---------------------------------------------------------------------------
// Executor contract: BACKUP/RESTORE parse cleanly, then refuse with the
// stable named error (NOT a bare NotImplemented).
// ---------------------------------------------------------------------------

test "GQL BACKUP TO returns the stable GqlBackupRestoreUnsupported error" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    try std.testing.expectError(
        error.GqlBackupRestoreUnsupported,
        h.runQuery("BACKUP TO '/tmp/gap0871.bak'"),
    );
}

test "GQL BACKUP with options returns the stable GqlBackupRestoreUnsupported error" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    try std.testing.expectError(
        error.GqlBackupRestoreUnsupported,
        h.runQuery("BACKUP TO '/tmp/gap0871.bak' WITH INCREMENTAL COMPRESSED"),
    );
}

test "GQL RESTORE FROM returns the stable GqlBackupRestoreUnsupported error" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    try std.testing.expectError(
        error.GqlBackupRestoreUnsupported,
        h.runQuery("RESTORE FROM '/tmp/gap0871.bak'"),
    );
}

test "GQL RESTORE ... VERIFY ONLY returns the stable GqlBackupRestoreUnsupported error" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    try std.testing.expectError(
        error.GqlBackupRestoreUnsupported,
        h.runQuery("RESTORE FROM '/tmp/gap0871.bak' VERIFY ONLY"),
    );
}

test "GQL RESTORE ... TO TIMESTAMP returns the stable GqlBackupRestoreUnsupported error" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    try std.testing.expectError(
        error.GqlBackupRestoreUnsupported,
        h.runQuery("RESTORE FROM '/tmp/gap0871.bak' TO TIMESTAMP '2024-01-01T00:00:00Z'"),
    );
}

// ---------------------------------------------------------------------------
// Wire contract: the error maps to SQLSTATE 0A000 with a client-visible
// message naming the supported CLI alternative.
// ---------------------------------------------------------------------------

test "GqlBackupRestoreUnsupported maps to SQLSTATE 0A000 on the wire" {
    const info = proto_util.mapError(error.GqlBackupRestoreUnsupported);
    try std.testing.expectEqualStrings("0A000", info.code);
}

test "wire message names the geode backup create CLI alternative" {
    const info = proto_util.mapError(error.GqlBackupRestoreUnsupported);
    try std.testing.expect(std.mem.indexOf(u8, info.message, "geode backup create") != null);
    try std.testing.expect(std.mem.indexOf(u8, info.message, "geode restore") != null);
}

test "stable message constant names the limitation and the CLI path" {
    // The message is part of the contract (same pattern as GAP-0856's
    // distributed_explain.unsupported_message). Shell regression suites grep
    // for "unsupported" / "0A000" — keep the word "unsupported" present.
    const msg = execution.gql_backup_restore_unsupported_message;
    try std.testing.expect(std.mem.indexOf(u8, msg, "BACKUP/RESTORE") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "unsupported") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "geode backup create") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "geode restore") != null);
}
