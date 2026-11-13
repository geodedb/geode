// SONNY-6468 regression.
//
// (1) `execution.ensureCatalogInstance` created the process-wide schema
//     catalog on the first caller's allocator. A caller holding a transient
//     allocator (a request arena, as the bulk fast paths' auto-index hook
//     may be) became the owner of a process singleton: once that allocator
//     was torn down the catalog was freed memory (the SONNY-2670 class). The
//     catalog now lives on the process allocator; the caller's allocator is
//     used only for the call.
// (2) `GraphStore.setNodePropertiesBatch` (and its edge sibling
//     `setEdgePropertiesBatch`) encrypted each FLE value twice: once for the
//     storage adapter and once more for the in-memory copy. Twice the
//     encryption work per write, and, since every seal draws a fresh nonce,
//     two different envelopes for one write: the engine held one and the
//     in-memory store another. Each value is now sealed once and both copies
//     hold that envelope.
//
// Through the real catalog singleton, and the graph-store batch primitives on
// the in-process persisted store (so the storage adapter is present), with
// the persisted copy read back from the adapter.
//
// CANARY: REQ=REQ-SONNY-6468-CATALOG-AND-BATCH-FLE; FEATURE="SchemaCatalog"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6468_catalog_and_batch_fle.zig; OWNER=security; UPDATED=2026-11-13

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const execution = geode.execution;
const fle_integration = geode.fle_integration;
const fle_catalog = fle_integration.catalog_mod;
const graph_store = geode.graph_store;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const master_key = "6468a6468a6468a6468a6468a6468a6468a6468a6468a6468a6468a6468a6468";
const secret = "SSN-6468-SECRET";

// ---------------------------------------------------------------------------
// (1) the process catalog outlives its first caller's allocator
// ---------------------------------------------------------------------------

test "SONNY-6468 (1): the process catalog made by a first caller on a transient arena outlives the arena" {
    // No catalog yet in this process (and no data dir: an in-memory one).
    execution.tearDownGlobalCatalogForTest();
    defer execution.tearDownGlobalCatalogForTest();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var arena_live = true;
    // On a failure below, release the singleton while the arena it may live
    // on still exists, so no later test touches freed memory.
    defer if (arena_live) {
        execution.tearDownGlobalCatalogForTest();
        arena.deinit();
    };

    const cat = try execution.ensureCatalogInstance(arena.allocator());
    if (cat.allocator.ptr == arena.allocator().ptr) {
        std.debug.print("the process catalog is owned by its first caller's arena\n", .{});
        return error.CatalogOnCallerAllocator;
    }

    // The request ends: its arena is torn down (its pages unmapped).
    arena.deinit();
    arena_live = false;

    // The catalog is still the process's, and still usable.
    try testing.expect(execution.getCatalogInstanceIfPresent() == cat);
    try testing.expect(try execution.ensureCatalogInstance(testing.allocator) == cat);
    const rows = try cat.listIndexesForGraph(testing.allocator, graph_store.DEFAULT_GRAPH_NAME);
    defer testing.allocator.free(rows);
    try testing.expectEqual(@as(usize, 0), rows.len);
}

// ---------------------------------------------------------------------------
// (2) a batch property write seals each FLE value once
// ---------------------------------------------------------------------------

/// The persisted in-process store, authentication off, an FLE master key.
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

    fn exec(self: *Env, query: []const u8) !execution.ExecutionResult {
        const catalog = try execution.ensureCatalogInstance(testing.allocator);
        const ctx = execution.ExecutionContext{
            .catalog = catalog,
            .session_state = &self.session,
            .fle_role = "pii",
        };
        var parsed = try geode.parseGqlOptions(query, self.arena.allocator(), .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(self.arena.allocator(), parsed.program.statements[0], ctx);
    }

    fn run(self: *Env, query: []const u8) !void {
        _ = self.exec(query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
    }

    fn str(self: *Env, query: []const u8) ![]const u8 {
        const res = try self.exec(query);
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

    fn onlyNode(self: *Env, label: []const u8) !u64 {
        const ids = self.f.st.getNodesByLabel(graph_store.DEFAULT_GRAPH_NAME, label) orelse return error.NoNodes;
        if (ids.len != 1) return error.UnexpectedNodes;
        return ids[0];
    }

    /// The engine slot of a public node or edge id in the default graph.
    fn slotOf(self: *Env, id: u64, comptime kind: enum { node, edge }) !u64 {
        const refs = try self.f.st.idMapsSnapshotForTest(testing.allocator);
        defer self.f.st.releaseIdMapsForTest(testing.allocator, refs);
        for (refs) |r| {
            if (!std.mem.eql(u8, r.graph_name, graph_store.DEFAULT_GRAPH_NAME)) continue;
            const slot = switch (kind) {
                .node => r.map.nodeSlot(@as(u128, id)),
                .edge => r.map.edgeSlot(@as(u128, id)),
            };
            return slot orelse error.NoSlot;
        }
        return error.NoIdMap;
    }
};

/// The persisted copy (what the storage engine holds) must be the very
/// envelope the in-memory store holds: one seal per write.
fn expectOneEnvelope(in_memory: []const u8, persisted: []const u8, what: []const u8) !void {
    if (std.mem.indexOf(u8, in_memory, secret) != null or std.mem.indexOf(u8, persisted, secret) != null) {
        std.debug.print("{s}: the secret is stored in the clear\n", .{what});
        return error.StoredInPlaintext;
    }
    if (!std.mem.eql(u8, in_memory, persisted)) {
        std.debug.print("{s}: the in-memory store and the engine hold two different envelopes ({d} and {d} bytes): the value was encrypted twice\n", .{ what, in_memory.len, persisted.len });
        return error.EncryptedTwice;
    }
}

test "SONNY-6468 (2): a batch node property write seals an FLE value once (the store and the engine hold one envelope)" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.encrypt("T6468", "ssn");
    try e.run("CREATE (:T6468 {k: 1})");
    const id = try e.onlyNode("T6468");

    const props = [_]graph_store.GraphStore.BatchPropertyEntry{
        .{ .key = "ssn", .value = .{ .String = secret } },
        .{ .key = "plain", .value = .{ .String = "visible" } },
    };
    try e.f.st.setNodePropertiesBatch(id, &props);

    const in_memory = e.f.st.getNodeProperty(id, "ssn").?.String;
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const pv = (try adapter.getNodeProperty(graph_store.DEFAULT_GRAPH_NAME, try e.slotOf(id, .node), "ssn", testing.allocator)) orelse return error.NotPersisted;
    const persisted = switch (pv) {
        .string => |s| s,
        else => return error.UnexpectedType,
    };
    defer testing.allocator.free(persisted);
    try expectOneEnvelope(in_memory, persisted, "setNodePropertiesBatch");

    // An unencrypted field is untouched, and the encrypted one reads back.
    try testing.expectEqualStrings("visible", e.f.st.getNodeProperty(id, "plain").?.String);
    try testing.expectEqualStrings(secret, try e.str("MATCH (n:T6468) RETURN n.ssn"));
}

test "SONNY-6468 (2): a batch edge property write seals an FLE value once (the store and the engine hold one envelope)" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.encrypt("R6468", "p");
    try e.run("CREATE (:A6468)-[:R6468 {k: 1}]->(:B6468)");
    const edges = e.f.st.getEdgesByType(testing.allocator, "R6468", null, graph_store.DEFAULT_GRAPH_NAME);
    defer testing.allocator.free(edges);
    try testing.expectEqual(@as(usize, 1), edges.len);

    const props = [_]graph_store.GraphStore.BatchPropertyEntry{.{ .key = "p", .value = .{ .String = secret } }};
    try e.f.st.setEdgePropertiesBatch(edges[0], &props);

    const edge = e.f.st.getEdgeHydrated(edges[0]).?;
    const in_memory = edge.properties.get("p").?.String;
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const pv = (try adapter.getEdgeProperty(
        graph_store.DEFAULT_GRAPH_NAME,
        try e.slotOf(edge.from_id, .node),
        try e.slotOf(edges[0], .edge),
        "p",
        testing.allocator,
    )) orelse return error.NotPersisted;
    const persisted = switch (pv) {
        .string => |s| s,
        else => return error.UnexpectedType,
    };
    defer testing.allocator.free(persisted);
    try expectOneEnvelope(in_memory, persisted, "setEdgePropertiesBatch");
    try testing.expectEqualStrings(secret, try e.str("MATCH ()-[r:R6468]->() RETURN r.p"));
}
