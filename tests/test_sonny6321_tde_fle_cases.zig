// SONNY-6321 (remaining parts): real tests for what the CANARY markers that
// were downgraded to IMPL claim, so each is promoted only against a test
// that executes it.
//
//   TDE procedures:
//     (1) tde.simulate_oltp_workload: happy path through the executor's TDE
//         dispatch (it had only argument-bound tests), and FeatureDisabled
//         with TDE off;
//     (2) authorization: a CALL runs the GPS gate first; a ReadOnly
//         principal may not run the self tests classified as writes, which
//         an Admin may run (SONNY-6442: tde.measure_overhead, the one
//         read-only TDE procedure, is refused as unsupported and so
//         classified as a write too);
//     (3) argument validation: out-of-range simulate_oltp_workload arguments
//         are refused;
//     (4) cluster gate: the TDE self tests change nothing durable and run
//         in cluster mode (a follower), while a gated write procedure
//         (geode.fle.configureField) is refused there.
//   FLE (REQ-FLE-AST/PARSER/SCHEMA/BI-002/EXECUTION/STORAGE):
//     (5) CREATE GRAPH TYPE field annotations parse into the AST;
//     (6) the annotation texts apply to field metadata, and (7) the blind
//         index stores, normalizes, looks up and removes: in
//         tests/test_sonny6321_fle_schema_blind_index.zig (those modules
//         cannot share a test binary with the geode module);
//     (8) a field configured through geode.fle.configureField is stored as
//         an FLE envelope by a CREATE through the executor and read back as
//         plaintext only by a role it is visible to.
//   REQ-FLE-ADMIN-001 and REQ-FLE-MIGRATE-CLI-001 are not backed here: see
//   tests/test_sonny6321_fle_admin_cli.zig (ADMIN-001 TESTED there; the
//   migrate-encrypt CLI is refused as unsupported and stays IMPL).
//   (9) the promoted markers cite this file.
//
// CANARY: REQ=REQ-SONNY-6321-TDE-FLE-CASES; FEATURE="TDEProcedures"; ASPECT=OltpAuthClusterFleEvidence; STATUS=TESTED; TEST=tests/test_sonny6321_tde_fle_cases.zig; OWNER=tde; UPDATED=2026-11-12
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const options = @import("sonny6321b_options");

const ast = geode.ast;
const execution = geode.execution;
const graph_store = geode.graph_store;
const storage_dispatch = geode.storage_dispatch;
const fle_integration = geode.fle_integration;
const runtime_flags = geode.util_feature_flags;
const principal_mod = geode.security.principal;
const cluster = geode.distributed.cluster;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const tde_key_hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
const fle_master_hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"; // gitleaks:allow — test fixture

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn enableTde() void {
    runtime_flags.global().tde.enableForTests();
    _ = setenv("GEODE_TDE_KEY", tde_key_hex, 1);
}

fn disableTde() void {
    _ = unsetenv("GEODE_TDE_KEY");
    runtime_flags.global().tde.clearTestOverride();
}

fn call(arena: std.mem.Allocator, name: []const u8, args: []const ast.Expr) !ast.CallProcedure {
    const callee = try arena.create(ast.Expr);
    callee.* = .{ .Ident = .{ .orig = name, .cnf = name } };
    const ptrs = try arena.alloc(*ast.Expr, args.len);
    for (args, 0..) |a, i| {
        ptrs[i] = try arena.create(ast.Expr);
        ptrs[i].* = a;
    }
    return .{ .procedure = .{ .Call = .{ .callee = callee, .args = ptrs } } };
}

fn column(res: anytype, name: []const u8) ?usize {
    for (res.columns, 0..) |c, i| {
        if (std.mem.eql(u8, c, name)) return i;
    }
    return null;
}

fn principal(roles: []const []const u8, name: []const u8) principal_mod.Principal {
    return .{
        .user_id = 6321,
        .username = name,
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = roles,
        .custom_roles = &.{},
        .auth_method = .password,
        .auth_version = 1,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .test_harness,
    };
}

// ---------------------------------------------------------------------------
// (1) (3) simulate_oltp_workload
// ---------------------------------------------------------------------------

test "SONNY-6321 (1) tde.simulate_oltp_workload runs encrypted and plain transactions and reports them" {
    enableTde();
    defer disableTde();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const name = "tde.simulate_oltp_workload";

    const res = (try storage_dispatch.executeTde(arena, name, try call(arena, name, &.{ .{ .Int = 3 }, .{ .Int = 2 } }))) orelse return error.ProcedureNotRecognized;
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    const row = res.rows[0];
    try testing.expect(row[column(res, "tps_with_encryption") orelse return error.MissingColumn].Int > 0);
    try testing.expect(row[column(res, "tps_without_encryption") orelse return error.MissingColumn].Int > 0);
    try testing.expectEqual(@as(i64, 30), row[column(res, "transactions") orelse return error.MissingColumn].Int);
    try testing.expectEqual(@as(i64, 2), row[column(res, "concurrent_transactions") orelse return error.MissingColumn].Int);
    try testing.expect(column(res, "avg_transaction_time_ms") != null);
    try testing.expect(column(res, "degradation_percentage") != null);
}

test "SONNY-6321 (1) with TDE off tde.simulate_oltp_workload claims nothing" {
    runtime_flags.global().tde.disableForTests();
    defer runtime_flags.global().tde.clearTestOverride();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const name = "tde.simulate_oltp_workload";
    try testing.expectError(error.FeatureDisabled, storage_dispatch.executeTde(arena, name, try call(arena, name, &.{ .{ .Int = 1 }, .{ .Int = 1 } })));
}

test "SONNY-6321 (3) tde.simulate_oltp_workload refuses out-of-range arguments" {
    enableTde();
    defer disableTde();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const name = "tde.simulate_oltp_workload";
    for ([_][2]i64{ .{ -1, 1 }, .{ 1, -1 }, .{ 1, 0 }, .{ 1, 65 }, .{ 5_000_000_000, 1 } }) |a| {
        try testing.expectError(error.InvalidArgs, storage_dispatch.executeTde(arena, name, try call(arena, name, &.{ .{ .Int = a[0] }, .{ .Int = a[1] } })));
    }
}

// ---------------------------------------------------------------------------
// (2) authorization through the executor
// ---------------------------------------------------------------------------

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, sub: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(io(), &cwd_buf);
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..n], sub });
}

/// A real store and catalog for executor-level tests (the pattern of
/// tests/test_fts_authorization.zig).
const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    fn init(allocator: std.mem.Allocator) !Harness {
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
            .ctx = .{ .catalog = catalog },
        };
    }

    fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    fn run(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

test "SONNY-6321 (2) the GPS gate refuses the TDE self tests to a ReadOnly principal; an Admin runs them" {
    enableTde();
    defer disableTde();
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const ro_roles = [_][]const u8{"ReadOnly"};
    var ro = principal(&ro_roles, "sonny6321-ro");
    h.ctx.principal = &ro;
    try testing.expectError(error.Unauthorized, h.run("CALL tde.encrypt_page_test()"));
    try testing.expectError(error.Unauthorized, h.run("CALL tde.simulate_oltp_workload(1, 1)"));
    try testing.expectError(error.Unauthorized, h.run("CALL tde.measure_overhead()"));

    const admin_roles = [_][]const u8{"Admin"};
    var admin = principal(&admin_roles, "sonny6321-admin");
    h.ctx.principal = &admin;
    {
        const res = try h.run("CALL tde.encrypt_page_test()");
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        const i = column(res, "integrity_check") orelse return error.MissingColumn;
        try testing.expect(res.rows[0][i].Bool);
    }
    // SONNY-6442: refused to every principal.
    try testing.expectError(error.Unsupported, h.run("CALL tde.measure_overhead()"));
}

// ---------------------------------------------------------------------------
// (4) cluster mode
// ---------------------------------------------------------------------------

test "SONNY-6321 (4) in cluster mode the TDE self tests run while a gated write procedure is refused" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    enableTde();
    defer disableTde();
    var coord_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer coord_arena.deinit();
    // A fresh coordinator is a follower (as in test-sonny6288).
    var coord = try cluster.ClusterCoordinator.init(coord_arena.allocator(), 1, .{ .peers = &.{}, .cluster_token = "sonny6321" });
    const saved = cluster.getGlobalClusterCoordinator();
    cluster.setGlobalClusterCoordinator(&coord);
    defer if (saved) |c| cluster.setGlobalClusterCoordinator(c) else cluster.clearGlobalClusterCoordinator();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "tde.encrypt_page_test", "tde.encrypt_backup_test", "tde.test_encryption" }) |name| {
        const res = (try storage_dispatch.executeTde(arena, name, try call(arena, name, &.{}))) orelse return error.ProcedureNotRecognized;
        try testing.expectEqual(@as(usize, 1), res.rows.len);
    }
    const fle = "geode.fle.configurefield";
    try testing.expectError(error.ClusterNotLeader, storage_dispatch.executeFle(arena, fle, try call(arena, fle, &.{ .{ .String = "S6321Cluster" }, .{ .String = "f" } })));
}

// ---------------------------------------------------------------------------
// (5) (6) FLE annotations: parser, AST, schema metadata
// ---------------------------------------------------------------------------

const graph_type_ddl =
    \\CREATE GRAPH TYPE S6321Person AS { ssn text @encrypted(alg:"AES-256-GCM", key_scope:"field") @searchable(index:"blind-hmac-sha256") @visible(to_roles:["admin","auditor"]), id long PRIMARY KEY }
;

test "SONNY-6321 (5) CREATE GRAPH TYPE field annotations parse into the AST" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var parsed = try geode.parseGql(graph_type_ddl, arena_state.allocator());
    defer parsed.deinit();
    const stmt = parsed.program.statements[0];
    try testing.expect(stmt == .CreateGraphType);
    const fields = stmt.CreateGraphType.fields;
    try testing.expectEqual(@as(usize, 2), fields.len);
    try testing.expectEqualStrings("ssn", fields[0].name);
    try testing.expectEqualStrings("text", fields[0].type_name);
    try testing.expectEqual(@as(usize, 3), fields[0].annotations.len);
    try testing.expectEqualStrings("encrypted", fields[0].annotations[0].name);
    try testing.expectEqualStrings("@encrypted(alg:\"AES-256-GCM\", key_scope:\"field\")", fields[0].annotations[0].text);
    try testing.expectEqualStrings("searchable", fields[0].annotations[1].name);
    try testing.expectEqualStrings("visible", fields[0].annotations[2].name);
    try testing.expectEqualStrings("id", fields[1].name);
    try testing.expect(fields[1].primary_key);
    try testing.expectEqual(@as(usize, 0), fields[1].annotations.len);
}

// ---------------------------------------------------------------------------
// (7) the blind index
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// (8) encryption on write and decryption on read through the executor
// ---------------------------------------------------------------------------

/// Whether any file under `dir` contains `needle`.
fn dirContains(allocator: std.mem.Allocator, dir_path: []const u8, needle: []const u8) !bool {
    var dir = try std.Io.Dir.cwd().openDir(io(), dir_path, .{ .iterate = true });
    defer dir.close(io());
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io())) |entry| {
        if (entry.kind != .file) continue;
        const bytes = dir.readFileAlloc(io(), entry.path, allocator, .limited(256 << 20)) catch continue;
        defer allocator.free(bytes);
        if (std.mem.indexOf(u8, bytes, needle) != null) return true;
    }
    return false;
}

test "SONNY-6321 (8) a configured FLE field is stored as an envelope and read as plaintext only by a role it is visible to" {
    const allocator = testing.allocator;
    _ = setenv("GEODE_MASTER_KEY", fle_master_hex, 1);
    defer _ = unsetenv("GEODE_MASTER_KEY");
    fle_integration.resetGlobalKeyStateForTesting();

    var h = try Harness.init(allocator);
    defer h.deinit();
    // Registered after the harness, so the key state is reset while the
    // store it was created under still exists.
    defer fle_integration.resetGlobalKeyStateForTesting();
    const aa = h.arena.allocator();

    // Configure the field through the procedure the server runs.
    {
        const fle = "geode.fle.configurefield";
        var vis = [_]*ast.Expr{try aa.create(ast.Expr)};
        vis[0].* = .{ .String = "admin" };
        const list = try aa.create(ast.Expr);
        list.* = .{ .List = &vis };
        const props = try aa.alloc(ast.Property, 1);
        props[0] = .{ .key = "visibility", .value = list };
        _ = (try storage_dispatch.executeFle(aa, fle, try call(aa, fle, &.{ .{ .String = "S6321Patient" }, .{ .String = "ssn" }, .{ .Map = props } }))) orelse return error.ProcedureNotRecognized;
    }
    try testing.expect(fle_integration.hasEncryptedFields());

    h.ctx.fle_role = "admin";
    _ = try h.run("CREATE (:S6321Patient {name: 'S6321PlainMarker', ssn: '123-45-6789'})");
    const id_res = try h.run("MATCH (n:S6321Patient) RETURN id(n)");
    try testing.expectEqual(@as(usize, 1), id_res.rows.len);
    const node_id: u64 = @intCast(id_res.rows[0][0].Int);

    // The store's property API does not hand out the stored value of an
    // encrypted field, and what reaches disk (WAL and checkpointed pages)
    // holds no plaintext of it, while the unencrypted field's value is there.
    const store = graph_store.getGlobalStore(allocator);
    const raw = (try store.getNodePropertyOrError(node_id, "ssn")) orelse return error.NoProperty;
    try testing.expect(raw == .String);
    try testing.expect(std.mem.indexOf(u8, raw.String, "123-45-6789") == null);
    try store.saveToFile();
    try testing.expect(try dirContains(allocator, h.data_dir, "S6321PlainMarker"));
    try testing.expect(!try dirContains(allocator, h.data_dir, "123-45-6789"));

    // The admin role reads the plaintext back.
    {
        const res = try h.run("MATCH (n:S6321Patient) RETURN n.ssn AS ssn");
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        try testing.expect(res.rows[0][0] == .Str);
        try testing.expectEqualStrings("123-45-6789", res.rows[0][0].Str);
    }
    // A role the field is not visible to does not.
    h.ctx.fle_role = "analyst";
    {
        const res = try h.run("MATCH (n:S6321Patient) RETURN n.ssn AS ssn");
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        const v = res.rows[0][0];
        if (v == .Str) try testing.expect(!std.mem.eql(u8, v.Str, "123-45-6789"));
    }
}

// ---------------------------------------------------------------------------
// (9) the markers
// ---------------------------------------------------------------------------

fn readRepoFile(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    const abs = try std.fs.path.join(allocator, &.{ options.repo_root, rel });
    defer allocator.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(io(), abs, allocator, .limited(64 << 20));
}

test "SONNY-6321 (9) the markers this file backs are TESTED and cite it" {
    const allocator = testing.allocator;
    const backed = [_][2][]const u8{
        .{ "src/execution/storage_dispatch.zig", "REQ=REQ-TDE-PROC-046;" },
        .{ "src/gql/ast.zig", "REQ=REQ-FLE-AST-001;" },
        .{ "src/gql/parser.zig", "REQ=REQ-FLE-PARSER-001;" },
        .{ "src/execution/fle_hooks.zig", "REQ=REQ-FLE-EXECUTION-001;" },
        .{ "src/graph_store.zig", "REQ=REQ-FLE-STORAGE-001;" },
    };
    var bad: usize = 0;
    for (backed) |b| {
        const src = try readRepoFile(allocator, b[0]);
        defer allocator.free(src);
        const at = std.mem.indexOf(u8, src, b[1]) orelse {
            bad += 1;
            std.debug.print("SONNY-6321 (9): {s} has no {s} marker\n", .{ b[0], b[1] });
            continue;
        };
        const end = std.mem.indexOfScalarPos(u8, src, at, '\n') orelse src.len;
        const line = src[at..end];
        if (std.mem.indexOf(u8, line, "STATUS=TESTED") == null or std.mem.indexOf(u8, line, "tests/test_sonny6321_tde_fle_cases.zig") == null) {
            bad += 1;
            std.debug.print("SONNY-6321 (9): {s}: {s}\n", .{ b[0], line });
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}
