// SONNY-6335 regression: one FLE encryption identity; no index over an
// encrypted field.
//
// (1) The graph-store write sites (setNodeProperty, applyFleEncryption,
//     setEdgeProperty, applyFleEncryptionForEdge) encrypted a plaintext value
//     that reached them (raft apply, internal callers) with the store's
//     tenant/schema ("default"/"default") and "node_<id>" / "edge_<id>"; the
//     executor hook and every reader use the label, the request tenant and
//     "<id>" / "edge_<id>". A value encrypted at the store layer could not be
//     decrypted (FleDecryptionFailed). Now every writer and reader uses one
//     identity (fle_integration.recordIdentity), and readers fall back to the
//     old store identity so values already written that way decrypt.
// (2) An index over an FLE-encrypted field indexed the ciphertext (a fulltext
//     search, an equality seek, a UNIQUE check never match) or could hold the
//     plaintext. CREATE INDEX (any type) and CREATE CONSTRAINT UNIQUE / NODE
//     KEY on an encrypted field, and configureField on an indexed field, are
//     refused (0A000); a fulltext index made before (an existing deployment)
//     refuses searches instead of matching nothing.
//
// Through the executor (executeStatementWithContext) and the graph-store
// primitives on the in-process persisted store; the data directory is read
// back from disk.
//
// CANARY: REQ=REQ-SONNY-6335-FLE-IDENTITY-INDEXES; FEATURE="FieldLevelEncryption"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6335_fle_identity_and_indexes.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const execution = geode.execution;
const fle_integration = geode.fle_integration;
const fle_catalog = fle_integration.catalog_mod;
const proto_util = geode.proto_util;
const graph_store = geode.graph_store;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const master_key = "6335a6335a6335a6335a6335a6335a6335a6335a6335a6335a6335a6335a6335";
const secret = "SSN-6335-SECRET";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn expectSqlstate(err: anyerror, code: []const u8) !void {
    const info = proto_util.mapError(err);
    if (!std.mem.eql(u8, info.code, code)) {
        std.debug.print("{s} maps to {s}; expected {s}\n", .{ @errorName(err), info.code, code });
        return error.WrongSqlstate;
    }
}

fn expectStr(want: []const u8, got: []const u8, what: []const u8) !void {
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("{s}: got '{s}', expected '{s}'\n", .{ what, got, want });
        return error.WrongValue;
    }
}

/// The persisted in-process store, authentication off (implicit admin: the
/// FLE role list alone decides), an FLE master key.
const Env = struct {
    f: fx.Fixture,
    session: execution.SessionState,
    arena: std.heap.ArenaAllocator,

    fn init(self: *Env) !void {
        try self.f.init();
        errdefer self.f.deinit();
        _ = setenv("GEODE_MASTER_KEY", master_key, 1);
        fle_integration.resetGlobalKeyStateForTesting();
        fle_catalog.resetGlobalCatalog(testing.allocator);
        fle_integration.setHasEncryptedFields(false);
        self.session = execution.SessionState.init(testing.allocator);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
    }

    fn deinit(self: *Env) void {
        fle_integration.clearCurrentThreadState();
        self.arena.deinit();
        self.session.deinit();
        fle_catalog.resetGlobalCatalog(testing.allocator);
        fle_integration.setHasEncryptedFields(false);
        fle_integration.resetGlobalKeyStateForTesting();
        _ = unsetenv("GEODE_MASTER_KEY");
        self.f.deinit();
    }

    fn exec(self: *Env, fle_role: ?[]const u8, tenant: ?[]const u8, query: []const u8) !execution.ExecutionResult {
        const catalog = try execution.ensureCatalogInstance(testing.allocator);
        const ctx = execution.ExecutionContext{
            .catalog = catalog,
            .session_state = &self.session,
            .fle_role = fle_role,
            .tenant_id = tenant,
        };
        var parsed = try geode.parseGqlOptions(query, self.arena.allocator(), .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(self.arena.allocator(), parsed.program.statements[0], ctx);
    }

    fn run(self: *Env, query: []const u8) !void {
        _ = self.exec("pii", null, query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
    }

    fn refused(self: *Env, query: []const u8) anyerror {
        if (self.exec("pii", null, query)) |_| {
            std.debug.print("{s}: ran; expected a refusal\n", .{query});
            return error.ExpectedRefusal;
        } else |err| return err;
    }

    fn str(self: *Env, fle_role: ?[]const u8, query: []const u8) ![]const u8 {
        const res = self.exec(fle_role, null, query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
        if (res.rows.len != 1) return error.UnexpectedRows;
        return switch (res.rows[0][0]) {
            .Str => |s| s,
            else => error.UnexpectedValue,
        };
    }

    fn encrypt(self: *Env, type_name: []const u8, field: []const u8) !void {
        _ = self;
        const catalog = try fle_catalog.globalCatalog(testing.allocator);
        var roles = [_][]const u8{"pii"};
        try catalog.configureField(type_name, .{ .field_name = field, .encryption = .{ .enabled = true }, .visibility = .{ .to_roles = &roles } });
        fle_integration.setHasEncryptedFields(true);
    }
};

/// Does any file under `dir_path` contain `needle`?
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

// ---------------------------------------------------------------------------
// (1) one encryption identity
// ---------------------------------------------------------------------------

test "SONNY-6335 (1): a node value encrypted by the graph-store primitive (raft apply, internal callers) decrypts for the plaintext role, through member access and RETURN n" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.encrypt("T6335", "ssn");

    // The executor writes one node; the store primitive writes another's
    // value in plaintext, as raft apply does (cluster_replication applies
    // GNC2/GUPD payloads through store.setNodeProperty).
    try e.run("CREATE (:T6335 {k: 1, ssn: '" ++ secret ++ "'})");
    try e.run("CREATE (:T6335 {k: 2})");
    const ids = e.f.st.getNodesByLabel(graph_store.DEFAULT_GRAPH_NAME, "T6335") orelse return error.NoNodes;
    var store_written: ?u64 = null;
    for (ids) |id| {
        if ((try e.f.st.getNodePropertyOrError(id, "ssn")) == null) store_written = id;
    }
    try e.f.st.setNodeProperty(store_written.?, "ssn", .{ .String = secret });
    // Stored encrypted, not in plaintext.
    const stored = (try e.f.st.getNodePropertyOrError(store_written.?, "ssn")).?.String;
    try testing.expect(std.mem.indexOf(u8, stored, secret) == null);

    try expectStr(secret, try e.str("pii", "MATCH (n:T6335 {k: 1}) RETURN n.ssn"), "executor-written");
    try expectStr(secret, try e.str("pii", "MATCH (n:T6335 {k: 2}) RETURN n.ssn"), "store-written");
    try expectStr("[REDACTED]", try e.str("other", "MATCH (n:T6335 {k: 2}) RETURN n.ssn"), "store-written, other role");
}

test "SONNY-6335 (1): an edge value encrypted by the graph-store primitive decrypts like one the executor encrypted" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.encrypt("R6335", "p");
    try e.run("CREATE (:A6335 {k: 1})-[:R6335 {k: 1, p: '" ++ secret ++ "'}]->(:B6335 {k: 1})");
    try e.run("CREATE (:A6335 {k: 2})-[:R6335 {k: 2}]->(:B6335 {k: 2})");
    const edges = try e.f.st.getEdgesByType(testing.allocator, "R6335", null, graph_store.DEFAULT_GRAPH_NAME);
    defer testing.allocator.free(edges);
    var store_written: ?u64 = null;
    for (edges) |id| {
        const edge = (try e.f.st.getEdgeHydratedChecked(id)) orelse continue;
        if (edge.properties.get("p") == null) store_written = id;
    }
    try e.f.st.setEdgeProperty(store_written.?, "p", .{ .String = secret });
    try expectStr(secret, try e.str("pii", "MATCH ()-[r:R6335 {k: 1}]->() RETURN r.p"), "executor-written edge");
    try expectStr(secret, try e.str("pii", "MATCH ()-[r:R6335 {k: 2}]->() RETURN r.p"), "store-written edge");
}

test "SONNY-6335 (1): a value already on disk under the old graph-store identity (tenant/schema 'default', \"node_<id>\") still decrypts; one under no known identity is encrypted as a value (SONNY-6347)" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.encrypt("T6335", "ssn");
    try e.run("CREATE (:T6335 {k: 3})");
    const ids = e.f.st.getNodesByLabel(graph_store.DEFAULT_GRAPH_NAME, "T6335") orelse return error.NoNodes;
    const id = ids[0];

    // The envelope the old store write sites produced.
    var buf: [32]u8 = undefined;
    const legacy = fle_integration.legacyStoreIdentity(&buf, .node, id);
    const envelope = try fle_integration.encryptFieldIfNeeded(.{ .tenant_id = legacy.tenant_id, .schema_name = legacy.schema_name, .allocator = testing.allocator }, "T6335", "ssn", secret, legacy.record_id);
    defer testing.allocator.free(envelope);
    // An envelope reaching the store is kept as it is (never re-encrypted).
    try e.f.st.setNodeProperty(id, "ssn", .{ .String = envelope });
    try testing.expectEqualSlices(u8, envelope, (try e.f.st.getNodePropertyOrError(id, "ssn")).?.String);
    try expectStr(secret, try e.str("pii", "MATCH (n:T6335 {k: 3}) RETURN n.ssn"), "legacy store identity");

    // Under another record's identity: no identity a reader tries.
    var buf2: [32]u8 = undefined;
    const other = fle_integration.legacyStoreIdentity(&buf2, .node, id + 1000);
    const foreign = try fle_integration.encryptFieldIfNeeded(.{ .tenant_id = other.tenant_id, .schema_name = other.schema_name, .allocator = testing.allocator }, "T6335", "ssn", secret, other.record_id);
    defer testing.allocator.free(foreign);
    // SONNY-6347: the store keeps only an envelope that authenticates as
    // this record's; a foreign one is a value like any other, and is
    // encrypted. (Stored bytes that do not decrypt are refused, 58030:
    // test-sonny6327-fle-read-gaps.)
    try e.f.st.setNodeProperty(id, "ssn", .{ .String = foreign });
    try testing.expect(!std.mem.eql(u8, foreign, (try e.f.st.getNodePropertyOrError(id, "ssn")).?.String));
    try expectStr(foreign, try e.str("pii", "MATCH (n:T6335 {k: 3}) RETURN n.ssn"), "a foreign envelope is a value");
}

// ---------------------------------------------------------------------------
// (2) no index over an encrypted field
// ---------------------------------------------------------------------------

test "SONNY-6335 (2): CREATE INDEX of every kind and CREATE CONSTRAINT UNIQUE / NODE KEY on an encrypted field are refused (0A000); NOT NULL is allowed; an index on a plain field of the label is not affected" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.encrypt("T6335", "ssn");
    const refused = [_][]const u8{
        "CREATE INDEX i6335a FOR (n:T6335) ON (n.ssn)",
        "CREATE INDEX i6335b FOR (n:T6335) ON (n.k, n.ssn)",
        "CREATE INDEX i6335c FOR (n:T6335) ON (n.ssn) USING fulltext",
        "CREATE INDEX i6335d FOR (n:T6335) ON (n.ssn) USING hash",
        "CREATE CONSTRAINT c6335a FOR (n:T6335) REQUIRE n.ssn IS UNIQUE",
    };
    for (refused) |q| try expectSqlstate(e.refused(q), "0A000");
    const cat = try execution.ensureCatalogInstance(testing.allocator);
    try testing.expect((try cat.indexOrUniqueOnField(testing.allocator, "T6335", "ssn")) == null);
    try e.run("CREATE INDEX i6335k FOR (n:T6335) ON (n.k)");
}

test "SONNY-6335 (2): configureField on a field with an index or a UNIQUE constraint is refused (0A000) and the field stays unencrypted" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.run("CREATE INDEX i6335x FOR (n:U6335) ON (n.ssn)");
    try expectSqlstate(e.refused("CALL geode.fle.configureField('U6335', 'ssn', {visibility: ['pii']})"), "0A000");
    try e.run("CREATE CONSTRAINT c6335u FOR (n:V6335) REQUIRE n.ssn IS UNIQUE");
    try expectSqlstate(e.refused("CALL geode.fle.configureField('V6335', 'ssn', {visibility: ['pii']})"), "0A000");
    const catalog = try fle_catalog.globalCatalog(testing.allocator);
    try testing.expect(!catalog.isFieldEncrypted("U6335", "ssn"));
    try testing.expect(!catalog.isFieldEncrypted("V6335", "ssn"));
    // A field with no index is configured.
    try e.run("CALL geode.fle.configureField('U6335', 'other', {visibility: ['pii']})");
}

test "SONNY-6335 (2): a fulltext index made before its field was encrypted (an existing deployment) refuses searches (0A000), and no index or data file holds the plaintext" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.run("CREATE INDEX f6335 FOR (n:W6335) ON (n.body) USING fulltext");
    // The field encrypted behind the index's back (the catalog API, as a
    // deployment upgraded with both in place).
    try e.encrypt("W6335", "body");
    try e.run("CREATE (:W6335 {k: 1, body: 'zebra " ++ secret ++ "'})");
    try expectSqlstate(e.refused("CALL geode.fts.search('f6335', 'zebra')"), "0A000");
    try expectSqlstate(e.refused("CALL geode.fts.phrase('f6335', 'zebra')"), "0A000");
    try expectStr("zebra " ++ secret, try e.str("pii", "MATCH (n:W6335 {k: 1}) RETURN n.body"), "the value itself");
    try testing.expect(!try dirContains(testing.allocator, e.f.h.data_dir, secret));
    try testing.expect(!try dirContains(testing.allocator, e.f.h.data_dir, "zebra"));
}

// ---------------------------------------------------------------------------
// (3) inline property maps on an encrypted field, (4) count() over a refusal
// ---------------------------------------------------------------------------

const other_master_key = "5336b5336b5336b5336b5336b5336b5336b5336b5336b5336b5336b5336b5336";

/// The rows' first column as integers, in order.
fn ints(e: *Env, fle_role: ?[]const u8, query: []const u8) ![]i64 {
    const res = e.exec(fle_role, null, query) catch |err| {
        std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
        return err;
    };
    const out = try e.arena.allocator().alloc(i64, res.rows.len);
    for (res.rows, 0..) |row, i| out[i] = switch (row[0]) {
        .Int => |v| v,
        else => return error.UnexpectedValue,
    };
    std.mem.sort(i64, out, {}, std.sort.asc(i64));
    return out;
}

/// `inline` and `where` answer the same rows for `fle_role`.
fn sameAsWhere(e: *Env, fle_role: ?[]const u8, inline_q: []const u8, where_q: []const u8, want: []const i64) !void {
    const a = try ints(e, fle_role, inline_q);
    const b = try ints(e, fle_role, where_q);
    if (!std.mem.eql(i64, a, b) or !std.mem.eql(i64, a, want)) {
        std.debug.print("SONNY-6335 (3), role {s}:\n  {s} -> {any}\n  {s} -> {any}\n  want {any}\n", .{ fle_role orelse "-", inline_q, a, where_q, b, want });
        return error.InlineMapDisagreesWithWhere;
    }
}

test "SONNY-6335 (3): an inline property map on an encrypted node or edge field matches exactly as the WHERE equality does, for each role" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.encrypt("M6335", "ssn");
    try e.encrypt("Q6335", "p");
    try e.run("CREATE (:M6335 {k: 1, ssn: '" ++ secret ++ "'})-[:Q6335 {k: 10, p: '" ++ secret ++ "'}]->(:M6335 {k: 2, ssn: 'other'})");
    try e.run("CREATE (:M6335 {k: 3, ssn: '" ++ secret ++ "'})");

    // The plaintext role: the value it reads is the one it matches.
    try sameAsWhere(&e, "pii", "MATCH (n:M6335 {ssn: '" ++ secret ++ "'}) RETURN n.k", "MATCH (n:M6335) WHERE n.ssn = '" ++ secret ++ "' RETURN n.k", &.{ 1, 3 });
    try sameAsWhere(&e, "pii", "MATCH (n {ssn: '" ++ secret ++ "'}) RETURN n.k", "MATCH (n) WHERE n.ssn = '" ++ secret ++ "' RETURN n.k", &.{ 1, 3 });
    try sameAsWhere(&e, "pii", "MATCH ()-[r:Q6335 {p: '" ++ secret ++ "'}]->() RETURN r.k", "MATCH ()-[r:Q6335]->() WHERE r.p = '" ++ secret ++ "' RETURN r.k", &.{10});
    try sameAsWhere(&e, "pii", "MATCH ()-[r {p: '" ++ secret ++ "'}]->() RETURN r.k", "MATCH ()-[r]->() WHERE r.p = '" ++ secret ++ "' RETURN r.k", &.{10});
    try sameAsWhere(&e, "pii", "MATCH (a:M6335)-[:Q6335]->(b:M6335 {ssn: 'other'}) RETURN a.k", "MATCH (a:M6335)-[:Q6335]->(b:M6335) WHERE b.ssn = 'other' RETURN a.k", &.{1});
    try sameAsWhere(&e, "pii", "MATCH (a:M6335 {ssn: '" ++ secret ++ "'})-[:Q6335 {p: '" ++ secret ++ "'}]->(b) RETURN b.k", "MATCH (a:M6335)-[r:Q6335]->(b) WHERE a.ssn = '" ++ secret ++ "' AND r.p = '" ++ secret ++ "' RETURN b.k", &.{2});
    try sameAsWhere(&e, "pii", "MATCH (n:M6335 {ssn: 'nobody'}) RETURN n.k", "MATCH (n:M6335) WHERE n.ssn = 'nobody' RETURN n.k", &.{});
    // Counted, too (the count fast paths).
    try sameAsWhere(&e, "pii", "MATCH (n:M6335 {ssn: '" ++ secret ++ "'}) RETURN count(n)", "MATCH (n:M6335) WHERE n.ssn = '" ++ secret ++ "' RETURN count(n)", &.{2});
    try sameAsWhere(&e, "pii", "MATCH ()-[r:Q6335 {p: '" ++ secret ++ "'}]->() RETURN count(r)", "MATCH ()-[r:Q6335]->() WHERE r.p = '" ++ secret ++ "' RETURN count(r)", &.{1});

    // A role without plaintext reads "[REDACTED]": neither form matches the
    // value (nor reveals it by matching).
    try sameAsWhere(&e, "other", "MATCH (n:M6335 {ssn: '" ++ secret ++ "'}) RETURN n.k", "MATCH (n:M6335) WHERE n.ssn = '" ++ secret ++ "' RETURN n.k", &.{});
    try sameAsWhere(&e, "other", "MATCH ()-[r:Q6335 {p: '" ++ secret ++ "'}]->() RETURN r.k", "MATCH ()-[r:Q6335]->() WHERE r.p = '" ++ secret ++ "' RETURN r.k", &.{});
    try sameAsWhere(&e, "other", "MATCH (n:M6335 {ssn: '" ++ secret ++ "'}) RETURN count(n)", "MATCH (n:M6335) WHERE n.ssn = '" ++ secret ++ "' RETURN count(n)", &.{0});

    // The stored ciphertext itself matches for nobody.
    const ids = e.f.st.getNodesByLabel(graph_store.DEFAULT_GRAPH_NAME, "M6335") orelse return error.NoNodes;
    const stored = (try e.f.st.getNodePropertyOrError(ids[0], "ssn")).?.String;
    // The ciphertext is random bytes: escape the literal's quote and
    // backslash so the query names exactly the stored value, whatever the
    // nonce produced (a raw `'` or `\` in it broke the parse).
    var lit: std.ArrayList(u8) = .empty;
    for (stored) |b| {
        if (b == '\'' or b == '\\') try lit.append(e.arena.allocator(), '\\');
        try lit.append(e.arena.allocator(), b);
    }
    const q = try std.fmt.allocPrint(e.arena.allocator(), "MATCH (n:M6335 {{ssn: '{s}'}}) RETURN n.k", .{lit.items});
    try testing.expectEqual(@as(usize, 0), (try ints(&e, "pii", q)).len);
    try testing.expectEqual(@as(usize, 0), (try ints(&e, "other", q)).len);

    // Values that do not decrypt (another master key): an error, as WHERE.
    _ = setenv("GEODE_MASTER_KEY", other_master_key, 1);
    fle_integration.resetGlobalKeyStateForTesting();
    try testing.expectEqual(error.FleDecryptionFailed, e.refused("MATCH (n:M6335) WHERE n.ssn = 'x' RETURN n.k"));
    try testing.expectEqual(error.FleDecryptionFailed, e.refused("MATCH (n:M6335 {ssn: 'x'}) RETURN n.k"));
    try testing.expectEqual(error.FleDecryptionFailed, e.refused("MATCH ()-[r:Q6335 {p: 'x'}]->() RETURN r.k"));
}

test "SONNY-6335 (4): MATCH ()-[r]->() WHERE r.p = ... RETURN count(r) over an encrypted field that does not decrypt answers 58030, not 0" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.encrypt("C6335", "p");
    try e.run("CREATE (:X6335)-[:C6335 {p: '" ++ secret ++ "'}]->(:Y6335)");
    try testing.expectEqualSlices(i64, &.{1}, try ints(&e, "pii", "MATCH ()-[r]->() WHERE r.p = '" ++ secret ++ "' RETURN count(r)"));

    _ = setenv("GEODE_MASTER_KEY", other_master_key, 1);
    fle_integration.resetGlobalKeyStateForTesting();
    for ([_][]const u8{
        "MATCH ()-[r]->() WHERE r.p = '" ++ secret ++ "' RETURN count(r)",
        "MATCH ()-[r:C6335]->() WHERE r.p = '" ++ secret ++ "' RETURN count(r)",
        "MATCH ()-[r]->() WHERE r.p = '" ++ secret ++ "' RETURN count(*)",
        "MATCH (a)-[r]->(b) WHERE r.p = '" ++ secret ++ "' RETURN count(r)",
    }) |q| {
        if (e.exec("pii", null, q)) |res| {
            std.debug.print("SONNY-6335 (4): {s} answered {any} over a field that does not decrypt (want 58030)\n", .{ q, res.rows });
            return error.DecryptFailureSwallowed;
        } else |err| try expectSqlstate(err, "58030");
    }
}
