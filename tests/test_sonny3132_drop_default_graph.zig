// SONNY-3132 regression: the default graph cannot be dropped or replaced.
//
// `GraphStore.dropGraph` dropped the storage adapter's graph BEFORE its check
// for `default`, and the executor's DROP GRAPH logged the resulting
// `CannotDropDefaultGraph` and answered ok. So `DROP GRAPH default`, from any
// principal with the schema permission on `default` (a ReadWrite user with a
// FOR SCHEMA grant on it, too), deleted the default graph's engine and its
// files on disk while the in-memory store still showed its data (review
// probes R12-V7, R12-X7b). CREATE OR REPLACE GRAPH default took the same
// path.
//
// Now `GraphStore.dropGraph` refuses `default` before it calls the adapter,
// the adapter refuses it as well, the executor returns the refusal, and
// CREATE OR REPLACE GRAPH default is refused before anything is dropped.
//
// CANARY: REQ=REQ-SONNY-3132-DROP-DEFAULT-GRAPH; FEATURE="MultiGraphIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3132_drop_default_graph.zig; OWNER=storage; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const policy_catalog = geode.security.policy_catalog;

const default_graph = graph_store.DEFAULT_GRAPH_NAME;

/// What the default graph is before a refused statement, to compare after.
const DefaultGraph = struct {
    uuid: [16]u8,
    keep_in_engine: usize,
    dir: []u8,

    fn take(allocator: std.mem.Allocator, data_dir: []const u8) !DefaultGraph {
        const ad = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
        const mg = try ad.lookupManagedGraph(default_graph);
        const hex = std.fmt.bytesToHex(mg.uuid, .lower);
        return .{
            .uuid = mg.uuid,
            .keep_in_engine = (try ad.getNodesByLabelCapped(default_graph, "Keep", null, allocator)).len,
            .dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, &hex }),
        };
    }

    /// The same engine (UUID), its data, and its directory on disk.
    fn expectUnchanged(self: DefaultGraph, allocator: std.mem.Allocator, what: []const u8) !void {
        const ad = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
        const mg = ad.lookupManagedGraph(default_graph) catch |err| {
            std.debug.print("{s}: the default graph's engine is gone ({s})\n", .{ what, @errorName(err) });
            return err;
        };
        if (!std.mem.eql(u8, &mg.uuid, &self.uuid)) {
            std.debug.print("{s}: the default graph was replaced\n", .{what});
            return error.TestUnexpectedResult;
        }
        const keep: usize = if (ad.getNodesByLabelCapped(default_graph, "Keep", null, allocator)) |ids| ids.len else |_| 0;
        try testing.expectEqual(self.keep_in_engine, keep);
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().access(io, self.dir, .{}) catch |err| {
            std.debug.print("{s}: the default graph's directory is gone ({s})\n", .{ what, @errorName(err) });
            return err;
        };
    }
};

test "SONNY-3132: over gRPC DROP GRAPH default, DROP GRAPH IF EXISTS default and CREATE OR REPLACE GRAPH default are refused; the default graph's engine, data and files stay (R12-V7)" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("v7");
    try fx.expectRuns(ga, s, "CREATE (:Keep {v: 1})");
    const before = try DefaultGraph.take(ga, f.h.data_dir);
    try testing.expectEqual(@as(usize, 1), before.keep_in_engine);

    const refused = [_][]const u8{
        "DROP GRAPH default",
        "DROP GRAPH IF EXISTS default",
        "CREATE OR REPLACE GRAPH default",
    };
    var ran: usize = 0;
    for (refused) |q| {
        if (try fx.outcome(ga, s, q)) |code| {
            std.debug.print("{s} -> {s}\n", .{ q, code });
        } else {
            std.debug.print("{s} ran\n", .{q});
            ran += 1;
        }
        try before.expectUnchanged(ga, q);
    }
    try testing.expectEqual(@as(usize, 0), ran);
    // The session still reads and writes the default graph.
    try fx.expectRuns(ga, s, "CREATE (:Keep {v: 2})");
    try testing.expectEqual(@as(usize, 2), fx.countLabel(f.st, default_graph, "Keep"));
}

test "SONNY-3132: GraphStore.dropGraph and the storage adapter refuse the default graph before dropping anything" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("store");
    try fx.expectRuns(ga, s, "CREATE (:Keep {v: 1})");
    const before = try DefaultGraph.take(ga, f.h.data_dir);

    const store_result: anyerror!void = f.st.dropGraph(default_graph);
    if (store_result) |_| {
        std.debug.print("GraphStore.dropGraph(default) succeeded\n", .{});
        return error.TestUnexpectedResult;
    } else |err| try testing.expectEqual(error.CannotDropDefaultGraph, err);
    try before.expectUnchanged(ga, "GraphStore.dropGraph");
    try testing.expectEqual(@as(usize, 1), fx.countLabel(f.st, default_graph, "Keep"));

    const ad = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const adapter_result: anyerror!void = ad.dropGraph(default_graph);
    if (adapter_result) |_| {
        std.debug.print("StorageAdapter.dropGraph(default) succeeded\n", .{});
        return error.TestUnexpectedResult;
    } else |err| try testing.expectEqual(error.CannotDropDefaultGraph, err);
    try before.expectUnchanged(ga, "StorageAdapter.dropGraph");
}

test "SONNY-3132: over gRPC a ReadWrite user holding FOR SCHEMA on default only is refused DROP GRAPH default; the engine keeps its data (R12-X7b)" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    const st = graph_store.getGlobalStore(testing.allocator);
    _ = geode.txn_undo_log.getGlobalUndoLog(testing.allocator);
    const auth_was = user_mgmt.isAuthEnabled();
    user_mgmt.setAuthEnabled(true);
    defer user_mgmt.setAuthEnabled(auth_was);
    const allow_was = gps.isInsecureAllowAll();
    gps.setInsecureAllowAll(false);
    defer gps.setInsecureAllowAll(allow_was);
    const strict_was = geode.tenancy.isStrictTenancy();
    geode.tenancy.setStrictTenancy(false);
    defer geode.tenancy.setStrictTenancy(strict_was);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ga = arena.allocator();
    var sessions = grpc.SessionStore.init(ga, .{});
    defer sessions.deinit();
    grpc.setSessionStore(&sessions);
    defer grpc.setSessionStore(null);
    const admin = try sessions.createSession("p_admin", "", .Admin, null, null, false, 0);
    const rw = try sessions.createSession("p_rw", "", .ReadWrite, null, null, false, 0);
    var cat = policy_catalog.PolicyCatalog.init(testing.allocator);
    defer cat.deinit();
    const schema_action = [_]policy_catalog.Action{.schema};
    try cat.addPolicy(.{ .name = "schema_default_3132", .scope_graph = "default", .actions = &schema_action, .effect = .allow, .expression_source = "true", .enabled = true });
    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();

    try fx.expectRuns(ga, admin, "CREATE (:Keep {v: 1})");
    const before = try DefaultGraph.take(ga, h.data_dir);
    const code = try fx.outcome(ga, rw, "DROP GRAPH default");
    std.debug.print("ReadWrite DROP GRAPH default -> {s}\n", .{code orelse "ok"});
    try testing.expect(code != null);
    try before.expectUnchanged(ga, "ReadWrite DROP GRAPH default");
    // And an Admin is refused too.
    try testing.expect((try fx.outcome(ga, admin, "DROP GRAPH default")) != null);
    try before.expectUnchanged(ga, "Admin DROP GRAPH default");
    try testing.expectEqual(@as(usize, 1), fx.countLabel(st, default_graph, "Keep"));
}
