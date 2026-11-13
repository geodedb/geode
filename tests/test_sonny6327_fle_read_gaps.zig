// SONNY-6327 regression: field-level-encryption (FLE) read gaps.
//
//   (1) An edge's string property was read with no FLE policy at all: the
//       `.PropertyAccess` arm of the evaluator returned the stored bytes
//       (the ciphertext envelope) to every principal, the `.Member` arm
//       decrypted with a node's record identity ("<id>" where the write side
//       encrypts "edge_<id>") and fell back to the stored bytes, and
//       `properties(r)`, map projection and the wire encoding of RETURN r (and
//       of RETURN n: the node paths had the same hole) sent the stored bytes.
//       Every read surface now goes through one policy
//       (`fle_integration.readStoredString`), for nodes and edges alike.
//   (2) A value that does not decrypt was returned as the stored bytes (the
//       evaluator and `graph_store.getNodeProperty`); it is now an error
//       (FleDecryptionFailed, 58030).
//   (3) The FLE catalog read API returned pointers and borrowed slices after
//       unlocking (getType, getFieldMetadata, and canReadPlaintext walked the
//       role list after unlocking); a reconfigure, grant or revoke frees that
//       memory. Reads now answer under the mutex or copy.
//   (4) There was no online revoke: `CALL geode.fle.revokePlaintext`.
//   (5) The QUIC write fast paths wrote an encrypted field's plaintext to the
//       engine; they decline while an FLE field is configured.
//
// The real executor, the real FLE catalog and key manager, the real
// `CALL geode.fle.*` dispatch, the real wire encoders and, for (5), a real
// server over QUIC with its data files inspected. No mocks.
//
// Deterministic proofs: everything in (1), (2), (4), (5), and in (3) the
// "a reader cannot finish while the catalog mutex is held" and "a copy
// outlives a reconfigure" checks. The (3) reader/mutator loop is a stress
// test (it can only fail by finding a bad interleaving, and it runs under
// std.testing.allocator so a leak or a double free fails it).
//
// CANARY: REQ=REQ-SONNY-6327-FLE-READ-POLICY; FEATURE="FieldLevelEncryption"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6327_fle_read_gaps.zig; OWNER=security; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const util = @import("proto_test_util.zig");

const graph_store = geode.graph_store;
const execution = geode.execution;
const index_manager = geode.index_manager;
const fle_integration = geode.fle_integration;
const fle_catalog = fle_integration.catalog_mod;
const storage_dispatch = geode.storage_dispatch;
const proto_util = geode.proto_util;
const principal_mod = geode.security.principal;
const ast = geode.gql.ast;

const FieldMetadata = @typeInfo(@TypeOf(fle_catalog.SchemaCatalog.configureField)).@"fn".params[2].type.?;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;

const key_a = "6327a6327a6327a6327a6327a6327a6327a6327a6327a6327a6327a6327a6327";
const key_b = "b7236b7236b7236b7236b7236b7236b7236b7236b7236b7236b7236b7236b723";

const node_secret = "111-22-3333-node-6327";
const edge_secret = "edge-secret-value-6327";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn sleepMs(ms: u64) void {
    std.Io.sleep(io(), .fromMilliseconds(@intCast(ms)), .awake) catch {};
}

/// Saves and restores an environment variable.
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

/// The process-global FLE key manager, built from GEODE_MASTER_KEY on the
/// process allocator (never a request arena: it outlives every query).
fn useMasterKey(key: [:0]const u8) !void {
    fle_integration.resetGlobalKeyStateForTesting();
    _ = setenv("GEODE_MASTER_KEY", key.ptr, 1);
}

fn resetGlobalCatalog() void {
    fle_catalog.resetGlobalCatalog(testing.allocator);
    fle_integration.setHasEncryptedFields(false);
}

/// FLE configured in memory (no data directory) for a node label and an
/// edge type, both readable in plaintext by role `pii` only.
const Fle = struct {
    env_data_dir: SavedEnv,
    env_key: SavedEnv,

    fn init() !Fle {
        const env_data_dir = try SavedEnv.take("GEODE_DATA_DIR");
        errdefer env_data_dir.restore();
        const env_key = try SavedEnv.take("GEODE_MASTER_KEY");
        errdefer env_key.restore();
        _ = unsetenv("GEODE_DATA_DIR");
        fle_catalog.setDataDirOverride(null);
        resetGlobalCatalog();
        try useMasterKey(key_a);

        const catalog = try fle_catalog.globalCatalog(testing.allocator);
        var roles = [_][]const u8{"pii"};
        try catalog.configureField("S6327P", .{ .field_name = "ssn", .encryption = .{ .enabled = true }, .visibility = .{ .to_roles = &roles } });
        try catalog.configureField("S6327R", .{ .field_name = "secret", .encryption = .{ .enabled = true }, .visibility = .{ .to_roles = &roles } });
        return .{ .env_data_dir = env_data_dir, .env_key = env_key };
    }

    fn deinit(self: *Fle) void {
        fle_catalog.setDataDirOverride(null);
        resetGlobalCatalog();
        fle_integration.resetGlobalKeyStateForTesting();
        self.env_key.restore();
        self.env_data_dir.restore();
    }
};

/// The executor harness of tests/test_sonny6324_fle_catalog_fail_closed.zig;
/// `role` is the request's FLE role (GAP-0852: the context's role wins).
const Exec = struct {
    arena: std.heap.ArenaAllocator,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    fn init() !Exec {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        _ = graph_store.getGlobalStore(testing.allocator);
        const catalog = try execution.ensureCatalogInstance(testing.allocator);
        return .{
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
            .session = execution.SessionState.init(testing.allocator),
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    fn deinit(self: *Exec) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        self.arena.deinit();
    }

    fn aa(self: *Exec) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn exec(self: *Exec, role: ?[]const u8, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        self.ctx.fle_role = role;
        var parsed = try geode.parseGqlOptions(query, self.aa(), .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(self.aa(), parsed.program.statements[0], self.ctx);
    }

    fn run(self: *Exec, role: ?[]const u8, query: []const u8) !execution.ExecutionResult {
        return self.exec(role, query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
    }

    /// The one string cell of a one-row, one-column result.
    fn str(self: *Exec, role: ?[]const u8, query: []const u8) ![]const u8 {
        const res = try self.run(role, query);
        if (res.rows.len != 1) {
            std.debug.print("{s}: {d} rows\n", .{ query, res.rows.len });
            return error.UnexpectedRows;
        }
        return switch (res.rows[0][0]) {
            .Str => |s| s,
            else => |v| {
                std.debug.print("{s}: {s}\n", .{ query, @tagName(v) });
                return error.UnexpectedValue;
            },
        };
    }

    fn count(self: *Exec, role: ?[]const u8, query: []const u8) !i64 {
        const res = try self.run(role, query);
        if (res.rows.len != 1) return error.UnexpectedRows;
        return switch (res.rows[0][0]) {
            .Int => |n| n,
            else => error.UnexpectedValue,
        };
    }

    fn refused(self: *Exec, role: ?[]const u8, query: []const u8) anyerror {
        if (self.exec(role, query)) |res| {
            std.debug.print("{s}: ran ({d} rows); expected a refusal\n", .{ query, res.rows.len });
            return error.ExpectedRefusal;
        } else |err| return err;
    }
};

fn expectStr(want: []const u8, got: []const u8, what: []const u8) !void {
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("{s}: got '{f}' (len {d}), expected '{s}'\n", .{ what, std.zig.fmtString(got), got.len, want });
        return error.WrongValue;
    }
}

fn expectCode(err: anyerror, code: []const u8) !void {
    const info = proto_util.mapError(err);
    if (!std.mem.eql(u8, info.code, code)) {
        std.debug.print("{s} maps to {s}; expected {s}\n", .{ @errorName(err), info.code, code });
        return error.WrongSqlstate;
    }
}

fn createData(e: *Exec) !void {
    _ = try e.run("pii", "CREATE (a:S6327P {ssn: '" ++ node_secret ++ "', n: 1})-[:S6327R {secret: '" ++ edge_secret ++ "', w: 2}]->(b:S6327P {ssn: 'other-node'})");
}

const Entities = struct { node: geode.value_types.Value, edge: geode.value_types.Value };

/// RETURN a, r: the node and the edge as whole values.
fn entities(e: *Exec, role: ?[]const u8) !Entities {
    const res = try e.run(role, "MATCH (a:S6327P {n: 1})-[r:S6327R]->(b) RETURN a, r");
    if (res.rows.len != 1) return error.UnexpectedRows;
    return .{ .node = res.rows[0][0], .edge = res.rows[0][1] };
}

/// The QUIC handler sets the connection's FLE role on its thread at the
/// request boundary (`fle_integration.setCurrentUserRole`); the result rows
/// are encoded there, after the executor's context is gone.
fn threadRole(role: ?[]const u8) void {
    fle_integration.setCurrentUserRole(role);
}

/// The string the wire encoding (QUIC and gRPC share proto_util) sends for
/// property `key` of a whole node or edge value, encoded as `role`.
fn wireProperty(e: *Exec, role: ?[]const u8, value: geode.value_types.Value, key: []const u8) ![]const u8 {
    threadRole(role);
    defer fle_integration.clearCurrentThreadState();
    const pv = try proto_util.valueToProto(e.aa(), value);
    const props = switch (pv.kind.?) {
        .node_val => |n| n.properties.items,
        .edge_val => |ed| ed.properties.items,
        else => return error.NotAnEntity,
    };
    for (props) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value.?.kind.?.string_val.value;
    }
    return error.NoSuchProperty;
}

/// The JSON encoding of a whole node or edge value, as `role`.
fn json(e: *Exec, role: ?[]const u8, value: geode.value_types.Value) ![]const u8 {
    threadRole(role);
    defer fle_integration.clearCurrentThreadState();
    var aw: std.Io.Writer.Allocating = .init(e.aa());
    try execution.writeValue(e.aa(), &aw.writer, value);
    return aw.written();
}

fn storedString(value: geode.value_types.Value, key: []const u8) ![]const u8 {
    const props = switch (value) {
        .Node => |n| n.properties,
        .Edge => |ed| ed.properties,
        else => return error.NotAnEntity,
    };
    const pv = props.get(key) orelse return error.NoSuchProperty;
    return switch (pv) {
        .String => |s| s,
        else => error.NotAString,
    };
}

// ---------------------------------------------------------------------------
// (1) edge reads go through the node read policy
// ---------------------------------------------------------------------------

test "SONNY-6327 (1): an encrypted edge property is read like an encrypted node property, on every read surface" {
    var f = try Fle.init();
    defer f.deinit();
    var e = try Exec.init();
    defer e.deinit();
    try createData(&e);

    // The write side encrypts both: what is stored is an envelope.
    const ents = try entities(&e, "pii");
    const stored_node = try storedString(ents.node, "ssn");
    const stored_edge = try storedString(ents.edge, "secret");
    try testing.expect(!std.mem.eql(u8, stored_node, node_secret) and stored_node.len >= 35);
    try testing.expect(!std.mem.eql(u8, stored_edge, edge_secret) and stored_edge.len >= 35);

    // A principal with the plaintext role reads the plaintext, node and edge.
    try expectStr(node_secret, try e.str("pii", "MATCH (a:S6327P {n: 1}) RETURN a.ssn AS v"), "pii a.ssn");
    try expectStr(edge_secret, try e.str("pii", "MATCH ()-[r:S6327R]->() RETURN r.secret AS v"), "pii r.secret");
    try expectStr(node_secret, try e.str("pii", "MATCH (a:S6327P {n: 1}) RETURN properties(a).ssn AS v"), "pii properties(a)");
    try expectStr(edge_secret, try e.str("pii", "MATCH ()-[r:S6327R]->() RETURN properties(r).secret AS v"), "pii properties(r)");
    try testing.expectEqual(@as(i64, 1), try e.count("pii", "MATCH (a:S6327P) WHERE a.ssn = '" ++ node_secret ++ "' RETURN count(a) AS c"));
    try testing.expectEqual(@as(i64, 1), try e.count("pii", "MATCH ()-[r:S6327R]->() WHERE r.secret = '" ++ edge_secret ++ "' RETURN count(r) AS c"));
    try expectStr(edge_secret, try e.str("pii", "MATCH ()-[r:S6327R]->() RETURN max(r.secret) AS v"), "pii max(r.secret)");
    // Whole values over the wire and as JSON.
    const pii = try entities(&e, "pii");
    try expectStr(node_secret, try wireProperty(&e, "pii", pii.node, "ssn"), "pii wire RETURN a");
    try expectStr(edge_secret, try wireProperty(&e, "pii", pii.edge, "secret"), "pii wire RETURN r");
    try testing.expect(std.mem.indexOf(u8, try json(&e, "pii", pii.edge), edge_secret) != null);
    try testing.expect(std.mem.indexOf(u8, try json(&e, "pii", pii.node), node_secret) != null);

    // A principal without it gets what a node gives it: "[REDACTED]" (the
    // fields have no blind index), never the stored bytes; a predicate on
    // the plaintext never matches.
    for ([_]?[]const u8{ "analyst", null }) |role| {
        try expectStr("[REDACTED]", try e.str(role, "MATCH (a:S6327P {n: 1}) RETURN a.ssn AS v"), "other a.ssn");
        try expectStr("[REDACTED]", try e.str(role, "MATCH ()-[r:S6327R]->() RETURN r.secret AS v"), "other r.secret");
        try expectStr("[REDACTED]", try e.str(role, "MATCH ()-[r:S6327R]->() RETURN properties(r).secret AS v"), "other properties(r)");
        try testing.expectEqual(@as(i64, 0), try e.count(role, "MATCH (a:S6327P) WHERE a.ssn = '" ++ node_secret ++ "' RETURN count(a) AS c"));
        try testing.expectEqual(@as(i64, 0), try e.count(role, "MATCH ()-[r:S6327R]->() WHERE r.secret = '" ++ edge_secret ++ "' RETURN count(r) AS c"));
        const other = try entities(&e, role);
        try expectStr("[REDACTED]", try wireProperty(&e, role, other.node, "ssn"), "other wire RETURN a");
        try expectStr("[REDACTED]", try wireProperty(&e, role, other.edge, "secret"), "other wire RETURN r");
        const j = try json(&e, role, other.edge);
        try testing.expect(std.mem.indexOf(u8, j, "[REDACTED]") != null);
        try testing.expect(std.mem.indexOf(u8, j, edge_secret) == null);
    }

    // A property that is not encrypted is untouched.
    try testing.expectEqual(@as(i64, 2), try e.count("analyst", "MATCH ()-[r:S6327R]->() RETURN r.w AS c"));
}

// ---------------------------------------------------------------------------
// (2) a value that does not decrypt is an error, never the stored bytes
// ---------------------------------------------------------------------------

test "SONNY-6327 (2): a stored value that does not decrypt is an error (58030) on every read surface, node and edge" {
    var f = try Fle.init();
    defer f.deinit();
    var e = try Exec.init();
    defer e.deinit();
    try createData(&e);
    const ids = blk: {
        const res = try e.run("pii", "MATCH (a:S6327P {n: 1})-[r:S6327R]->() RETURN id(a) AS a, id(r) AS r");
        break :blk .{ @as(u64, @intCast(res.rows[0][0].Int)), @as(u64, @intCast(res.rows[0][1].Int)) };
    };
    const ents = try entities(&e, "pii");

    // Another master key: the stored envelopes no longer decrypt.
    try useMasterKey(key_b);
    defer useMasterKey(key_a) catch {};

    try testing.expectEqual(error.FleDecryptionFailed, e.refused("pii", "MATCH (a:S6327P {n: 1}) RETURN a.ssn AS v"));
    try testing.expectEqual(error.FleDecryptionFailed, e.refused("pii", "MATCH ()-[r:S6327R]->() RETURN r.secret AS v"));
    try testing.expectEqual(error.FleDecryptionFailed, e.refused("pii", "MATCH ()-[r:S6327R]->() RETURN properties(r).secret AS v"));
    try testing.expectEqual(error.FleDecryptionFailed, e.refused("pii", "MATCH ()-[r:S6327R]->() WHERE r.secret = 'x' RETURN r.w AS c"));
    try testing.expectEqual(error.FleDecryptionFailed, e.refused("pii", "MATCH (a:S6327P) WHERE a.ssn = 'x' RETURN a.n AS c"));
    try testing.expectEqual(error.FleDecryptionFailed, e.refused("pii", "MATCH (a:S6327P) WHERE a.ssn = 'x' RETURN count(a) AS c"));
    try testing.expectEqual(error.FleDecryptionFailed, e.refused("pii", "MATCH ()-[r:S6327R]->() RETURN count(r.secret) AS c"));
    try expectCode(error.FleDecryptionFailed, "58030");
    try testing.expectError(error.FleDecryptionFailed, wireProperty(&e, "pii", ents.edge, "secret"));
    try testing.expectError(error.FleDecryptionFailed, wireProperty(&e, "pii", ents.node, "ssn"));
    try testing.expectError(error.FleDecryptionFailed, json(&e, "pii", ents.edge));

    // The graph store's checked reads say so too; its plain read is the
    // stored value and says it is (never "the value").
    const store = graph_store.getGlobalStore(testing.allocator);
    {
        e.ctx.fle_role = "pii";
        const prev = execution.pushActiveContext(&e.ctx);
        defer execution.popActiveContext(prev);
        try testing.expectError(error.FleDecryptionFailed, store.getNodePropertyChecked(e.aa(), ids[0], "ssn"));
        try testing.expectError(error.FleDecryptionFailed, store.getEdgePropertyChecked(e.aa(), ids[1], "secret"));
    }
    try testing.expectEqualStrings(try storedString(ents.node, "ssn"), store.getNodeProperty(ids[0], "ssn").?.String);

    // A principal without the plaintext role is not told anything more.
    try expectStr("[REDACTED]", try e.str("analyst", "MATCH ()-[r:S6327R]->() RETURN r.secret AS v"), "analyst under a wrong key");

    // With the right key again, the checked reads decrypt.
    try useMasterKey(key_a);
    {
        e.ctx.fle_role = "pii";
        const prev = execution.pushActiveContext(&e.ctx);
        defer execution.popActiveContext(prev);
        try expectStr(node_secret, (try store.getNodePropertyChecked(e.aa(), ids[0], "ssn")).?.String, "checked node read");
        try expectStr(edge_secret, (try store.getEdgePropertyChecked(e.aa(), ids[1], "secret")).?.String, "checked edge read");
    }
}

// ---------------------------------------------------------------------------
// (1)+SONNY-6324: edge string reads are refused while the catalog is unavailable
// ---------------------------------------------------------------------------

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn setMode(path: []const u8, mode: c_uint) !void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    if (chmod(buf[0..path.len :0], mode) != 0) return error.ChmodFailed;
}

test "SONNY-6327 (1): while the FLE catalog cannot be loaded, an edge's string property is refused like a node's" {
    var f = try Fle.init();
    defer f.deinit();
    var e = try Exec.init();
    defer e.deinit();
    try createData(&e);
    const ents = try entities(&e, "pii");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, fle_catalog.catalog_file_name });
    defer testing.allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = path, .data = "corrupt FLE catalog bytes, cannot be parsed in any way" });
    fle_catalog.setDataDirOverride(dir);
    resetGlobalCatalog();

    try testing.expectEqual(error.FleCatalogUnavailable, e.refused("pii", "MATCH (a:S6327P {n: 1}) RETURN a.ssn AS v"));
    try testing.expectEqual(error.FleCatalogUnavailable, e.refused("pii", "MATCH ()-[r:S6327R]->() RETURN r.secret AS v"));
    try testing.expectEqual(error.FleCatalogUnavailable, e.refused("analyst", "MATCH ()-[r:S6327R]->() RETURN r.secret AS v"));
    try testing.expectEqual(error.FleCatalogUnavailable, e.refused("pii", "MATCH ()-[r:S6327R]->() RETURN properties(r) AS v"));
    try testing.expectError(error.FleCatalogUnavailable, wireProperty(&e, "pii", ents.edge, "secret"));
    try testing.expectError(error.FleCatalogUnavailable, json(&e, "pii", ents.edge));
}

// ---------------------------------------------------------------------------
// (4) CALL geode.fle.revokePlaintext
// ---------------------------------------------------------------------------

/// `CALL <proc>(args...)` through the real FLE procedure dispatch.
fn callFle(arena: std.mem.Allocator, normalized: []const u8, args_in: []const []const u8) !void {
    var exprs: [3]ast.Expr = undefined;
    var ptrs: [3]*ast.Expr = undefined;
    for (args_in, 0..) |a, i| {
        exprs[i] = .{ .String = a };
        ptrs[i] = &exprs[i];
    }
    var callee = ast.Expr{ .String = normalized };
    const proc_expr = ast.Expr{ .Call = .{ .callee = &callee, .args = ptrs[0..args_in.len] } };
    const call_stmt = ast.CallProcedure{ .procedure = proc_expr };
    const result = try storage_dispatch.executeFle(arena, normalized, call_stmt);
    try testing.expect(result != null);
}

fn testPrincipal(role: []const u8, user: []const u8) principal_mod.Principal {
    const S = struct {
        var admin = [_][]const u8{"Admin"};
        var read_only = [_][]const u8{"ReadOnly"};
    };
    return .{
        .user_id = 6327,
        .username = user,
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = if (std.mem.eql(u8, role, "Admin")) &S.admin else &S.read_only,
        .custom_roles = &.{},
        .auth_method = .password,
        .auth_version = 0,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .test_harness,
    };
}

test "SONNY-6327 (4): CALL geode.fle.revokePlaintext revokes online, takes effect on the next read, and is a mutating, gated procedure" {
    var f = try Fle.init();
    defer f.deinit();
    var e = try Exec.init();
    defer e.deinit();
    try createData(&e);
    const catalog = try fle_catalog.globalCatalog(testing.allocator);

    try callFle(e.aa(), "geode.fle.grantplaintext", &.{ "S6327R", "secret", "auditor" });
    try expectStr(edge_secret, try e.str("auditor", "MATCH ()-[r:S6327R]->() RETURN r.secret AS v"), "granted auditor");

    try callFle(e.aa(), "geode.fle.revokeplaintext", &.{ "S6327R", "secret", "auditor" });
    try testing.expect(!catalog.hasVisibilityRole("S6327R", "secret", "auditor"));
    try testing.expect(catalog.hasVisibilityRole("S6327R", "secret", "pii"));
    try expectStr("[REDACTED]", try e.str("auditor", "MATCH ()-[r:S6327R]->() RETURN r.secret AS v"), "revoked auditor");
    try expectStr(edge_secret, try e.str("pii", "MATCH ()-[r:S6327R]->() RETURN r.secret AS v"), "pii after another role's revoke");
    // A revoke of a role that has no access is a no-op; an unknown field is an error.
    try callFle(e.aa(), "geode.fle.revokeplaintext", &.{ "S6327R", "secret", "auditor" });
    try testing.expectError(error.FieldNotFound, callFle(e.aa(), "geode.fle.revokeplaintext", &.{ "S6327R", "nope", "auditor" }));

    // Through the executor: a read-only principal is refused before the
    // procedure runs (the procedure is mutating: GPS `.write`); Admin runs it.
    const q = "CALL geode.fle.revokePlaintext('S6327P', 'ssn', 'pii')";
    var ro = testPrincipal("ReadOnly", "ro6327");
    e.ctx.principal = &ro;
    try testing.expectEqual(error.Unauthorized, e.refused(null, q));
    try testing.expect(catalog.hasVisibilityRole("S6327P", "ssn", "pii"));
    var admin = testPrincipal("Admin", "admin6327");
    e.ctx.principal = &admin;
    _ = try e.run(null, q);
    e.ctx.principal = null;
    try testing.expect(!catalog.hasVisibilityRole("S6327P", "ssn", "pii"));
    try expectStr("[REDACTED]", try e.str("pii", "MATCH (a:S6327P {n: 1}) RETURN a.ssn AS v"), "pii after revoke");
}

test "SONNY-6327 (4): a revokePlaintext whose save fails stays revoked and says it is not saved (58030); a retry saves it" {
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;
    var f = try Fle.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(dir);
    defer setMode(dir, 0o700) catch {};
    fle_catalog.setDataDirOverride(dir);
    resetGlobalCatalog();
    var roles = [_][]const u8{ "pii", "auditor" };
    const catalog = try fle_catalog.globalCatalog(testing.allocator);
    try catalog.configureField("S6327R", .{ .field_name = "secret", .encryption = .{ .enabled = true }, .visibility = .{ .to_roles = &roles } });

    try setMode(dir, 0o500);
    const err = callFle(arena.allocator(), "geode.fle.revokeplaintext", &.{ "S6327R", "secret", "auditor" });
    try testing.expectError(error.FleRevokeNotPersisted, err);
    try expectCode(error.FleRevokeNotPersisted, "58030");
    try testing.expect(!catalog.hasVisibilityRole("S6327R", "secret", "auditor"));

    try setMode(dir, 0o700);
    try callFle(arena.allocator(), "geode.fle.revokeplaintext", &.{ "S6327R", "secret", "auditor" });
    var reloaded = fle_catalog.SchemaCatalog.init(testing.allocator);
    defer reloaded.deinit();
    try fle_catalog.loadCatalog(&reloaded);
    try testing.expect(!reloaded.hasVisibilityRole("S6327R", "secret", "auditor"));
    try testing.expect(reloaded.hasVisibilityRole("S6327R", "secret", "pii"));
}

// ---------------------------------------------------------------------------
// (3) the catalog read API answers under its mutex
// ---------------------------------------------------------------------------

var roles_a = [_][]const u8{ "r1", "r2" };
var roles_b = [_][]const u8{"r3"};

fn configure(catalog: *fle_catalog.SchemaCatalog, roles: [][]const u8) !void {
    try catalog.configureField("T6327", .{ .field_name = "f", .encryption = .{ .enabled = true }, .visibility = .{ .to_roles = roles } });
}

/// A role list a reader may see: one of the configured lists, with or
/// without the role the mutator grants and revokes.
fn validRoles(roles: []const []const u8) bool {
    const valid = [_][]const []const u8{
        &.{ "r1", "r2" }, &.{"r3"}, &.{ "r1", "r2", "r9" }, &.{ "r3", "r9" },
    };
    outer: for (valid) |want| {
        if (want.len != roles.len) continue;
        for (want, roles) |w, r| if (!std.mem.eql(u8, w, r)) continue :outer;
        return true;
    }
    return false;
}

const Stress = struct {
    catalog: *fle_catalog.SchemaCatalog,
    stop: std.atomic.Value(bool) = .init(false),
    bad: std.atomic.Value(u32) = .init(0),
    reads: std.atomic.Value(u64) = .init(0),
    failed: ?anyerror = null,

    fn reader(self: *Stress) void {
        while (!self.stop.load(.acquire)) {
            const p = self.catalog.fieldPolicy("T6327", "f") orelse {
                _ = self.bad.fetchAdd(1, .monotonic);
                continue;
            };
            if (!p.encrypted) _ = self.bad.fetchAdd(1, .monotonic);
            const d = self.catalog.readDecision("T6327", "f", "r9");
            if (!d.encrypted) _ = self.bad.fetchAdd(1, .monotonic);
            _ = self.catalog.canReadPlaintext("T6327", "f", "r1");
            _ = self.catalog.hasVisibilityRole("T6327", "f", "r3");
            // A reader with no role never reads an encrypted field that lists roles.
            if (self.catalog.canReadPlaintext("T6327", "f", null)) _ = self.bad.fetchAdd(1, .monotonic);
            const copy = self.catalog.copyFieldMetadata(testing.allocator, "T6327", "f") catch |err| {
                self.failed = err;
                return;
            } orelse {
                _ = self.bad.fetchAdd(1, .monotonic);
                continue;
            };
            if (!validRoles(copy.visibility.to_roles) or !std.mem.eql(u8, copy.field_name, "f")) _ = self.bad.fetchAdd(1, .monotonic);
            fle_catalog.freeFieldCopy(testing.allocator, copy);
            _ = self.reads.fetchAdd(1, .monotonic);
        }
    }
};

test "SONNY-6327 (3) stress: readers of the catalog while another thread reconfigures, grants and revokes see only valid answers, leak-free" {
    const env_data_dir = try SavedEnv.take("GEODE_DATA_DIR");
    defer env_data_dir.restore();
    _ = unsetenv("GEODE_DATA_DIR");
    fle_catalog.setDataDirOverride(null); // memory-only: nothing to save

    var catalog = fle_catalog.SchemaCatalog.init(testing.allocator);
    defer catalog.deinit();
    try configure(&catalog, &roles_a);

    var stress: Stress = .{ .catalog = &catalog };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Stress.reader, .{&stress});
    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        try configure(&catalog, if (i % 2 == 0) &roles_b else &roles_a);
        try catalog.grantPlaintextAccess("T6327", "f", "r9");
        try catalog.revokePlaintextAccess("T6327", "f", "r9");
    }
    stress.stop.store(true, .release);
    for (threads) |t| t.join();
    if (stress.failed) |err| return err;
    try testing.expectEqual(@as(u32, 0), stress.bad.load(.acquire));
    try testing.expect(stress.reads.load(.acquire) > 0);
}

test "SONNY-6327 (3) deterministic: a catalog read cannot finish while the catalog mutex is held, and a copy outlives a reconfigure" {
    const env_data_dir = try SavedEnv.take("GEODE_DATA_DIR");
    defer env_data_dir.restore();
    _ = unsetenv("GEODE_DATA_DIR");
    fle_catalog.setDataDirOverride(null);

    var catalog = fle_catalog.SchemaCatalog.init(testing.allocator);
    defer catalog.deinit();
    try configure(&catalog, &roles_a);

    // A copy the caller owns stays valid after the catalog frees its own.
    const copy = (try catalog.copyFieldMetadata(testing.allocator, "T6327", "f")).?;
    defer fle_catalog.freeFieldCopy(testing.allocator, copy);
    try configure(&catalog, &roles_b); // frees the catalog's old field copy
    try catalog.grantPlaintextAccess("T6327", "f", "r9"); // frees the old role list
    try testing.expect(validRoles(copy.visibility.to_roles));
    try testing.expectEqualStrings("r1", copy.visibility.to_roles[0]);
    try testing.expectEqualStrings("f", copy.field_name);

    // The plaintext decision is made under the mutex: with it held (as a
    // mutator holds it from its change to its free), a reader waits.
    const Runner = struct {
        done: std.atomic.Value(bool) = .init(false),
        answer: bool = false,
        fn go(self: *@This(), c: *fle_catalog.SchemaCatalog) void {
            self.answer = c.canReadPlaintext("T6327", "f", "r9");
            self.done.store(true, .release);
        }
    };
    catalog.mutex.lockUncancelable(io());
    var runner: Runner = .{};
    const t = std.Thread.spawn(.{}, Runner.go, .{ &runner, &catalog }) catch |err| {
        catalog.mutex.unlock(io());
        return err;
    };
    var waited: u64 = 0;
    while (waited < 500 and !runner.done.load(.acquire)) : (waited += 10) sleepMs(10);
    const finished_while_held = runner.done.load(.acquire);
    catalog.mutex.unlock(io());
    t.join();
    try testing.expect(!finished_while_held);
    try testing.expect(runner.answer);
}

// ---------------------------------------------------------------------------
// (5) the QUIC write fast paths never store an encrypted field's plaintext
// ---------------------------------------------------------------------------

fn wireStatus(client: *util.QuicProtoClient, query: []const u8) ![]u8 {
    var r = try client.executeAndCollect(testing.allocator, query, util.emptyParams(), 1000);
    defer r.deinit(testing.allocator);
    const code = r.error_code orelse "00000";
    if (!std.mem.eql(u8, code, "00000")) std.debug.print("  [{s}] -> {s} {s}\n", .{ query, code, r.error_message orelse "" });
    return testing.allocator.dupe(u8, code);
}

fn wireOk(client: *util.QuicProtoClient, query: []const u8) !void {
    const code = try wireStatus(client, query);
    defer testing.allocator.free(code);
    if (!std.mem.eql(u8, code, "00000")) return error.UnexpectedStatus;
}

/// Does any file under `dir` contain `needle`?
fn dirContains(allocator: std.mem.Allocator, dir_path: []const u8, needle: []const u8) !bool {
    var dir = try std.Io.Dir.cwd().openDir(io(), dir_path, .{ .iterate = true });
    defer dir.close(io());
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io())) |entry| {
        if (entry.kind != .file) continue;
        const bytes = dir.readFileAlloc(io(), entry.path, allocator, .limited(512 * 1024 * 1024)) catch continue;
        defer allocator.free(bytes);
        if (std.mem.indexOf(u8, bytes, needle) != null) return true;
    }
    return false;
}

fn fastPathsKeepPlaintextOffDisk(env: []const []const u8) !void {
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny6327-{d}", .{port});
    std.Io.Dir.cwd().createDirPath(io(), data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io(), data_dir) catch {};
    {
        const addr = try util.formatAddr(allocator, port);
        defer allocator.free(addr);
        var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--data-dir", data_dir }, env);
        defer server.deinit();
        try util.waitForServerReady(allocator, addr, 30000);
        var admin = try util.QuicProtoClient.connect(allocator, addr);
        defer admin.deinit();
        admin.watchServerLiveness(server.child.id.?);
        var h = try admin.hello(allocator, util.defaultUsername(), util.defaultPassword());
        defer h.deinit(allocator);
        if (!h.success) return error.HelloRefused;

        // Control: an unencrypted value written by the same shapes reaches
        // the data files as written (so the scan below can see plaintext).
        try wireOk(&admin, "MERGE (n:Fp6327 {k: 0}) ON CREATE SET n.note = 'CONTROLPLAIN6327N'");

        try wireOk(&admin, "CALL geode.fle.configureField('Fp6327', 'ssn', {visibility: ['nobody6327']})");
        try wireOk(&admin, "CALL geode.fle.configureField('FpE6327', 'secret', {visibility: ['nobody6327']})");
        // The node fast-path shapes: simple CREATE, bulk MERGE, /*+BATCH*/,
        // USE GRAPH; MERGE; the edge shape MATCH ... CREATE.
        try wireOk(&admin, "CREATE (:Fp6327 {k: 1, ssn: 'PLAINSECRET6327A'})");
        try wireOk(&admin, "MERGE (n:Fp6327 {k: 2}) ON CREATE SET n.ssn = 'PLAINSECRET6327B'");
        try wireOk(&admin, "/*+BATCH*/MERGE (n:Fp6327 {k: 3}) ON CREATE SET n.ssn = 'PLAINSECRET6327C'; MERGE (n:Fp6327 {k: 4}) ON CREATE SET n.ssn = 'PLAINSECRET6327D'");
        try wireOk(&admin, "USE GRAPH default; MERGE (n:Fp6327 {k: 5}) ON CREATE SET n.ssn = 'PLAINSECRET6327E'");
        try wireOk(&admin, "MATCH (a:Fp6327 {k: 1}), (b:Fp6327 {k: 2}) CREATE (a)-[:FpE6327 {secret: 'PLAINSECRET6327F'}]->(b)");
        var r = try admin.executeAndCollect(allocator, "MATCH (n:Fp6327) RETURN count(n) AS c", util.emptyParams(), 1000);
        defer r.deinit(allocator);
        try testing.expectEqual(@as(i64, 6), r.rows[0][0].int);
    }
    // The server is stopped; its data files are read as they are on disk.
    try testing.expect(try dirContains(allocator, data_dir, "CONTROLPLAIN6327N"));
    const markers = [_][]const u8{ "PLAINSECRET6327A", "PLAINSECRET6327B", "PLAINSECRET6327C", "PLAINSECRET6327D", "PLAINSECRET6327E", "PLAINSECRET6327F" };
    var leaked = false;
    for (markers) |m| {
        if (try dirContains(allocator, data_dir, m)) {
            std.debug.print("plaintext of an encrypted field on disk: {s}\n", .{m});
            leaked = true;
        }
    }
    try testing.expect(!leaked);
}

test "SONNY-6327 (5): over QUIC the write fast paths never store an encrypted field's plaintext (group commit on)" {
    try fastPathsKeepPlaintextOffDisk(&.{"GEODE_MASTER_KEY=" ++ key_a});
}

test "SONNY-6327 (5): over QUIC the write fast paths never store an encrypted field's plaintext (group commit off, GEODE_BULK_INGEST=1)" {
    try fastPathsKeepPlaintextOffDisk(&.{ "GEODE_MASTER_KEY=" ++ key_a, "GEODE_GROUP_COMMIT=0", "GEODE_BULK_INGEST=1" });
}

// The adapter's bulk writers refuse, before any engine write, while an FLE
// field is configured (the race window after the handler's check).
test "SONNY-6327 (5): the adapter's bulk-writer guard refuses while an FLE field is configured" {
    var f = try Fle.init();
    defer f.deinit();
    try testing.expectError(error.EncryptionRequired, graph_store.refuseIfFleConfigured());
    try expectCode(error.EncryptionRequired, "58030");
    resetGlobalCatalog();
    try graph_store.refuseIfFleConfigured();
}
