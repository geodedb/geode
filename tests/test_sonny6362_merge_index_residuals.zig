// SONNY-6362 regression (items 2-5): MERGE answers from its indexes only
// what the store holds.
//
//   2. A node id with bit 63 set is refused when a node is created with it.
//      MERGE's index keeps a flag in that bit, so such a node was never an
//      entry, and the persisted-id loader refuses one
//      (`parsePersistedPublicId`): the node could not be found by MERGE
//      (which then created a duplicate) and vanished at the next restart.
//   3. `StorageAdapter.lookupNodeIdByLabelAndAllProps` checks every filter,
//      the seed's included, against the node it returns. A posting of the
//      exact property index is a value hash: a collision or a stale posting
//      returned a node whose value is another.
//   4. MERGE on an FLE-encrypted property is refused (0A000). The stored
//      value is randomized ciphertext, so the plaintext pattern value never
//      equalled it and MERGE created a duplicate every time. Matching an
//      encrypted value needs deterministic or blind-index encryption
//      (SONNY-6350).
//   5. A MERGE index entry that could not be added (out of memory) leaves the
//      index unable to answer (the caller scans), not answering "no such
//      node", which made MERGE create a duplicate.
//
// Through the graph store and storage adapter on the in-process persisted
// store, and the executor (executeStatementWithContext).
//
// CANARY: REQ=REQ-SONNY-6362-MERGE-INDEX-RESIDUALS; FEATURE="MergeIdempotency"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6362_merge_index_residuals.zig; OWNER=storage; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const execution = geode.execution;
const fle_integration = geode.fle_integration;
const fle_catalog = fle_integration.catalog_mod;
const proto_util = geode.proto_util;
const graph_store = geode.graph_store;
const PropKV = geode.graph_storage_adapter.StorageAdapter.PropKV;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const master_key = "6362a6362a6362a6362a6362a6362a6362a6362a6362a6362a6362a6362a6362";
const G = graph_store.DEFAULT_GRAPH_NAME;
const flag: u64 = @as(u64, 1) << 63;

/// The persisted in-process store, authentication off, an FLE master key
/// (the SONNY-6335 fixture).
const Env = struct {
    f: fx.Fixture,
    session: execution.SessionState,
    arena: std.heap.ArenaAllocator,

    fn init(self: *Env) !void {
        try self.f.init();
        errdefer self.f.deinit();
        _ = setenv("GEODE_MASTER_KEY", master_key, 1);
        fle_integration.resetGlobalKeyStateForTesting();
        _ = try fle_integration.getCurrentKeyVersion(.{ .tenant_id = "default", .schema_name = "P6362", .allocator = std.heap.smp_allocator }, "init");
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

    fn refused(self: *Env, query: []const u8, code: []const u8) !void {
        if (self.exec(query)) |_| {
            std.debug.print("{s}: ran; expected a refusal ({s})\n", .{ query, code });
            return error.ExpectedRefusal;
        } else |err| {
            const info = proto_util.mapError(err);
            if (!std.mem.eql(u8, info.code, code)) {
                std.debug.print("{s}: {s} maps to {s}; expected {s}\n", .{ query, @errorName(err), info.code, code });
                return error.WrongSqlstate;
            }
        }
    }

    fn count(self: *Env, label: []const u8) usize {
        return fx.countLabel(self.f.st, G, label);
    }

    fn encrypt(self: *Env, type_name: []const u8, field: []const u8) !void {
        _ = self;
        const catalog = try fle_catalog.globalCatalog(testing.allocator);
        var roles = [_][]const u8{"pii"};
        try catalog.configureField(type_name, .{ .field_name = field, .encryption = .{ .enabled = true }, .visibility = .{ .to_roles = &roles } });
        fle_integration.setHasEncryptedFields(true);
    }
};

test "SONNY-6362 (2): a node id with bit 63 set is refused at creation, on every path that takes one" {
    // A store of its own (no engine).
    {
        var gs = try graph_store.GraphStore.init(testing.allocator);
        defer gs.deinit();
        try gs.createGraph("g");
        try testing.expectError(error.NodeIdFlagged, gs.createNodeWithReservedIdAndGraph(flag | 5, &[_][]const u8{"B6362"}, "g"));
        try testing.expect(gs.getNodePtr(flag | 5) == null);
        try testing.expectError(error.NodeIdFlagged, gs.createNodeWithId(flag | 6, &[_][]const u8{"B6362"}, "g"));
        try testing.expect(gs.getNodePtr(flag | 6) == null);
        try testing.expectEqual(@as(?[]const u64, null), gs.getNodesByLabel("g", "B6362"));
    }

    // The persisted store: the adapter's bulk insert writes no engine slot.
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const props = [_]PropKV{.{ .key = "x", .value = .{ .Int = 7 } }};
    try testing.expectError(error.NodeIdFlagged, adapter.bulkInsertNodeWithReservedId(G, flag | 9, &[_][]const u8{"B6362"}, &props));
    try testing.expectEqual(@as(usize, 0), e.count("B6362"));
    try testing.expectError(error.NodeIdFlagged, e.f.st.createNodeWithReservedIdAndGraph(flag | 10, &[_][]const u8{"B6362"}, G));
    try testing.expectEqual(@as(usize, 0), e.count("B6362"));

    // MERGE finds the value's one holder: it creates none.
    try e.run("CREATE (:B6362 {x: 7})");
    try e.run("MERGE (n:B6362 {x: 7})");
    try testing.expectEqual(@as(usize, 1), e.count("B6362"));
}

test "SONNY-6362 (3): the all-properties resolver checks the seed filter against the node it returns" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;

    try e.run("CREATE (:S6362 {k: 2, t: 'two'})");
    const two = [_]PropKV{.{ .key = "k", .value = .{ .Int = 2 } }};
    const slot = try adapter.lookupNodeIdByLabelAndAllProps(G, "S6362", &two, error.EndpointMissing);

    // A posting naming that node under k = 1: what a hash collision of the
    // two values, or a posting left stale, reads as.
    try adapter.addExactIndexPostingForTesting(G, "S6362", "k", .{ .Int = 1 }, slot);

    const one = [_]PropKV{.{ .key = "k", .value = .{ .Int = 1 } }};
    try testing.expectError(error.EndpointMissing, adapter.lookupNodeIdByLabelAndAllProps(G, "S6362", &one, error.EndpointMissing));
    const one_two = [_]PropKV{ .{ .key = "k", .value = .{ .Int = 1 } }, .{ .key = "t", .value = .{ .String = "two" } } };
    try testing.expectError(error.EndpointMissing, adapter.lookupNodeIdByLabelAndAllProps(G, "S6362", &one_two, error.EndpointMissing));
    // The node is still found by its own value.
    try testing.expectEqual(slot, try adapter.lookupNodeIdByLabelAndAllProps(G, "S6362", &two, error.EndpointMissing));
}

test "SONNY-6362 (4): MERGE on an FLE-encrypted property is refused, with nothing written" {
    var e: Env = undefined;
    try e.init();
    defer e.deinit();
    try e.encrypt("P6362", "ssn");
    try e.encrypt("R6362", "p");

    try e.run("CREATE (:P6362 {k: 1, ssn: 'SSN-1'})");
    try testing.expectEqual(@as(usize, 1), e.count("P6362"));

    // The node holds the value; MERGE could not see it and created another.
    try e.refused("MERGE (n:P6362 {ssn: 'SSN-1'})", "0A000");
    try e.refused("MERGE (n:P6362 {k: 1, ssn: 'SSN-1'}) RETURN n.k", "0A000");
    // Without a label the stored value may be another type's ciphertext.
    try e.refused("MERGE (n {ssn: 'SSN-1'})", "0A000");
    // A node whose first label encrypts the field, matched by another label.
    try e.refused("MERGE (n:Q6362 {ssn: 'SSN-1'})", "0A000");
    try testing.expectEqual(@as(usize, 1), e.count("P6362"));
    try testing.expectEqual(@as(usize, 0), e.count("Q6362"));

    // A relationship property.
    try e.run("CREATE (:A6362 {k: 1})-[:R6362 {p: 'secret'}]->(:C6362 {k: 1})");
    try e.refused("MATCH (a:A6362 {k: 1}), (c:C6362 {k: 1}) MERGE (a)-[:R6362 {p: 'secret'}]->(c)", "0A000");
    try testing.expectEqual(@as(usize, 1), e.f.st.countEdgesByTypeForGraph(G, "R6362"));

    // MERGE on an unencrypted key still runs, and sets the encrypted field.
    try e.run("MERGE (n:P6362 {k: 2}) ON CREATE SET n.ssn = 'SSN-2'");
    try e.run("MERGE (n:P6362 {k: 2}) ON CREATE SET n.ssn = 'SSN-2'");
    try testing.expectEqual(@as(usize, 2), e.count("P6362"));
}

test "SONNY-6362 (5): a MERGE index entry that could not be added leaves the index unable to answer, not answering a miss" {
    // Sweep the allocation that fails over a label add's work (the undo of
    // a REMOVE n:L, `addNodeLabelNoSave`), whose last step adds the node's
    // MERGE entries under the label.
    var unanswerable: usize = 0;
    var k: usize = 0;
    while (k < 64) : (k += 1) {
        var failing = std.testing.FailingAllocator.init(std.heap.smp_allocator, .{});
        var gs = try graph_store.GraphStore.init(failing.allocator());
        defer gs.deinit();
        try gs.createGraph("g");
        const id = try gs.createNodeWithGraph(&[_][]const u8{"A6362"}, "g");
        try gs.setNodeProperty(id, "x", .{ .Int = 7 });

        failing.fail_index = failing.alloc_index + k;
        const added = gs.addNodeLabelNoSave(id, "M6362");
        const injected = failing.has_induced_failure;
        failing.fail_index = std.math.maxInt(usize);
        if (added) |_| {} else |_| continue; // the label add itself failed

        const node = gs.getNodePtr(id) orelse return error.NodeGone;
        var labelled = false;
        for (node.labels) |l| labelled = labelled or std.mem.eql(u8, l, "M6362");
        if (!labelled) continue;

        var out: u64 = 0;
        switch (gs.lookupMergeCandidate("g", "M6362", "x", .{ .Int = 7 }, &out)) {
            .found => try testing.expectEqual(id, out),
            .not_indexable => unanswerable += 1,
            .not_found => {
                std.debug.print("allocation {d} of the label add failed: MERGE's index answers 'no such node' for a node that holds the key\n", .{k});
                return error.TrustedMiss;
            },
        }
        if (!injected) break; // the whole add ran: the sweep is done
    }
    try testing.expect(unanswerable > 0);
}
