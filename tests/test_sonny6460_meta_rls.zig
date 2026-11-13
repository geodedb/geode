// SONNY-6460 item 5: `CALL db.propertyKeys()` applied the RLS label
// policies to an edge's type only (SONNY-6437): an edge whose endpoint node
// the policy hides still contributed its keys, and `CALL
// db.relationshipTypes()` listed a type every edge of which has such an
// endpoint. A MATCH never reaches those edges (SONNY-2679: a hop's target
// must pass RLS, and a pattern's start node is checked where it is scanned),
// so their keys and types are not visible either.
//
// The real executor, the real RLS filter engine and the real parser,
// leak-checked with std.testing.allocator. No mocks.
//
// CANARY: REQ=REQ-SONNY-6460-META-ENDPOINT-RLS; FEATURE="GPS Metadata Isolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6460_meta_rls.zig; OWNER=security; UPDATED=2026-11-13

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const logging = @import("logging");
const rls_types = @import("rls_types");

const graph_store = geode.graph_store;
const execution = geode.execution;
const index_manager = geode.index_manager;

const Session = struct {
    arena: std.heap.ArenaAllocator,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,
    rls: *rls_types.RLSFilterEngine,

    fn init(self: *Session) !void {
        logging.init(.{ .level = .fatal });
        logging.setLevel(.fatal);
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        _ = graph_store.getGlobalStore(testing.allocator);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.session = execution.SessionState.init(testing.allocator);
        self.ctx = .{ .catalog = try execution.ensureCatalogInstance(testing.allocator) };
        self.ctx.session_state = &self.session;
        self.rls = try testing.allocator.create(rls_types.RLSFilterEngine);
        self.rls.* = rls_types.RLSFilterEngine.init(testing.allocator);

        // bob is denied `:Sec`. No edge type is denied. A `:LINK` edge only
        // ever touches a `:Sec` node; `:BOTH` has one edge between two
        // `:Pub` nodes and one from a `:Sec` node, which alone carries
        // `sec_edge_key`.
        for ([_][]const u8{
            "CREATE (:Pub {pub_key: 1})-[:OK {ok_key: 1}]->(:Pub {pub_key: 2})",
            "CREATE (:Sec {sec_key: 1})-[:LINK {link_key: 1}]->(:Pub {pub_key: 3})",
            "CREATE (:Pub {pub_key: 4})-[:LINK2 {link2_key: 1}]->(:Sec {sec_key: 2})",
            "CREATE (:Pub {pub_key: 5})-[:BOTH {both_key: 1}]->(:Pub {pub_key: 6})",
            "CREATE (:Sec {sec_key: 3})-[:BOTH {both_key: 2, sec_edge_key: 1}]->(:Pub {pub_key: 7})",
        }) |q| {
            var r = try self.run(null, q);
            r.deinit(self.arena.allocator());
        }
        try self.rls.addDenyPolicy(graph_store.DEFAULT_GRAPH_NAME, "Sec", "bob");
        rls_types.setGlobalRLSFilterEngine(self.rls);
    }

    fn deinit(self: *Session) void {
        rls_types.setGlobalRLSFilterEngine(null);
        self.rls.deinit();
        testing.allocator.destroy(self.rls);
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        self.arena.deinit();
    }

    fn run(self: *Session, user: ?[]const u8, query: []const u8) !execution.ExecutionResult {
        self.ctx.user = user;
        var parsed = try geode.parseGqlOptions(query, self.arena.allocator(), .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(self.arena.allocator(), parsed.program.statements[0], self.ctx);
    }

    /// The one string column of `query`'s rows, in order.
    fn strings(self: *Session, user: ?[]const u8, query: []const u8) ![]const []const u8 {
        const res = self.run(user, query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
        const out = try self.arena.allocator().alloc([]const u8, res.rows.len);
        for (res.rows, out) |row, *s| s.* = row[0].Str;
        return out;
    }
};

fn expectStrings(want: []const []const u8, got: []const []const u8, what: []const u8) !void {
    var ok = want.len == got.len;
    if (ok) for (want, got) |w, g| {
        if (!std.mem.eql(u8, w, g)) ok = false;
    };
    if (!ok) {
        std.debug.print("{s}: got", .{what});
        for (got) |g| std.debug.print(" '{s}'", .{g});
        std.debug.print(", expected", .{});
        for (want) |w| std.debug.print(" '{s}'", .{w});
        std.debug.print("\n", .{});
        return error.WrongRows;
    }
}

test "SONNY-6460 (5): MATCH hides an edge whose endpoint the session's RLS policy hides" {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    // The premise of the two tests below: what bob's MATCH sees.
    const q = "MATCH ()-[r]->() RETURN DISTINCT type(r) AS t ORDER BY t";
    try expectStrings(&.{ "BOTH", "LINK", "LINK2", "OK" }, try s.strings("alice", q), "alice");
    try expectStrings(&.{ "BOTH", "OK" }, try s.strings("bob", q), "bob");
}

test "SONNY-6460 (5): db.relationshipTypes() omits a type whose every edge has an endpoint the session's RLS policy hides" {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    const q = "CALL db.relationshipTypes() YIELD relationshipType RETURN relationshipType ORDER BY relationshipType";
    try expectStrings(&.{ "BOTH", "LINK", "LINK2", "OK" }, try s.strings("alice", q), "alice");
    try expectStrings(&.{ "BOTH", "LINK", "LINK2", "OK" }, try s.strings(null, q), "no user");
    try expectStrings(&.{ "BOTH", "OK" }, try s.strings("bob", q), "bob");
}

test "SONNY-6460 (5): db.propertyKeys() omits the keys only edges with a hidden endpoint carry" {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    const q = "CALL db.propertyKeys() YIELD propertyKey RETURN propertyKey ORDER BY propertyKey";
    const all = [_][]const u8{ "both_key", "link2_key", "link_key", "ok_key", "pub_key", "sec_edge_key", "sec_key" };
    try expectStrings(&all, try s.strings("alice", q), "alice");
    try expectStrings(&all, try s.strings(null, q), "no user");
    try expectStrings(&.{ "both_key", "ok_key", "pub_key" }, try s.strings("bob", q), "bob");
}
