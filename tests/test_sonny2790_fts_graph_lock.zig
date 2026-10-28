// SONNY-2790 regression (round-7 review P38): the fulltext statements run on
// the default graph, so the handlers lock the default graph for them.
//
// Fulltext search is default-graph-only by design (docs/FULLTEXT_SEARCH.md,
// "Graph scope"): CREATE INDEX ... USING fulltext creates the engine in, and
// backfills it from, the default graph; DROP INDEX drops it there; and
// geode.fts.search / phrase / proximity / rebuild read (rebuild: rewrite) it.
// After SONNY-2749 the handlers lock the graph a request's statements run on,
// and these counted as running on the session's graph. From a session on g2
// they read and wrote `default` holding only g2's lock, beside writers that
// held `default`'s (probe R7-D). They now count as statements on `default`:
// from any session they take `default`'s lock, and a request that also
// changes another graph is refused (SONNY-2749).
//
// CANARY: REQ=REQ-SONNY-2790-FTS-DEFAULT-GRAPH; FEATURE="FullText"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2790_fts_graph_lock.zig; OWNER=index; UPDATED=2026-09-26

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");

const graph_store = geode.graph_store;
const query_traits = geode.query_traits;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;
const default_graph = graph_store.DEFAULT_GRAPH_NAME;

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

test "SONNY-2790: the fulltext statements count as statements on the default graph" {
    const Case = struct { query: []const u8, session: []const u8, lock: []const u8, spans: bool = false };
    const cases = [_]Case{
        .{ .query = "CREATE INDEX doc_idx FOR (d:Doc) ON (d.body) USING fulltext", .session = "g2", .lock = default_graph },
        .{ .query = "USE GRAPH g2; CREATE INDEX doc_idx FOR (d:Doc) ON (d.body) USING fulltext", .session = default_graph, .lock = default_graph },
        .{ .query = "DROP INDEX doc_idx", .session = "g2", .lock = default_graph },
        .{ .query = "CALL geode.fts.rebuild('doc_idx')", .session = "g2", .lock = default_graph },
        .{ .query = "CALL geode.fts.search('doc_idx', 'fox')", .session = "g2", .lock = default_graph },
        .{ .query = "USE GRAPH g2; CALL geode.fts.rebuild('idx')", .session = default_graph, .lock = default_graph },
        // Another index type stays on the session's graph.
        .{ .query = "CREATE INDEX n_idx FOR (d:Doc) ON (d.v)", .session = "g2", .lock = "g2" },
        // A request that also changes g2 changes two graphs: refused.
        .{ .query = "USE GRAPH g2; CREATE (:Doc {body: 'x'}); CALL geode.fts.rebuild('doc_idx')", .session = default_graph, .lock = default_graph, .spans = true },
    };
    var failures: usize = 0;
    for (cases) |c| {
        var parsed = try geode.parseGql(c.query, testing.allocator);
        defer parsed.deinit();
        const analysis = query_traits.analyzeProgram(&parsed.program);
        const plan = query_traits.statementPlan(&parsed.program, &analysis, c.session, default_graph, .grpc);
        if (!std.mem.eql(u8, plan.lock_graph, c.lock) or plan.spans_graphs != c.spans) {
            std.debug.print("{s} (session {s}): expected lock {s} spans={}, got lock {s} spans={}\n", .{ c.query, c.session, c.lock, c.spans, plan.lock_graph, plan.spans_graphs });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

/// Holds `graph`'s read lock for `hold_ms`, then lets go.
const Holder = struct {
    graph: []const u8,
    hold_ms: u64 = 400,
    held: std.atomic.Value(bool) = .init(false),
    letting_go: std.atomic.Value(bool) = .init(false),

    fn go(self: *Holder) void {
        const lock = graph_store.acquireGraphReadLock(self.graph);
        self.held.store(true, .release);
        sleepMs(self.hold_ms);
        self.letting_go.store(true, .release);
        graph_store.releaseGraphLock(lock);
    }

    fn start(self: *Holder) !std.Thread {
        const t = try std.Thread.spawn(.{}, go, .{self});
        while (!self.held.load(.acquire)) sleepMs(1);
        return t;
    }
};

fn encodeProto(allocator: std.mem.Allocator, msg: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, msg);
    return allocator.dupe(u8, aw.written());
}

fn decodeProto(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !T {
    var reader: std.Io.Reader = .fixed(bytes);
    return protobuf.decode(T, &reader, allocator);
}

fn execute(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !schema.ExecutionResponse {
    const req = try encodeProto(ga, schema.ExecuteRequest{ .session_id = session_id, .query = query, .params = .empty });
    return decodeProto(schema.ExecutionResponse, ga, try grpc.handleExecute(req, ga, null));
}

fn expectRuns(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !void {
    const resp = try execute(ga, session_id, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("{s}: {s} {s}\n", .{ query, e.code, e.message });
            return error.QueryFailed;
        },
        else => {},
    }
}

/// `query` from `session_id` (on g2), while another thread holds
/// `default`'s read lock: true when it returned only after that lock was
/// let go, i.e. it needed `default`'s write lock.
fn waitsForDefault(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !bool {
    var holder: Holder = .{ .graph = default_graph };
    const t = try holder.start();
    defer t.join();
    try expectRuns(ga, session_id, query);
    return holder.letting_go.load(.acquire);
}

test "SONNY-2790: over gRPC a session on another graph takes the default graph's write lock for fulltext DDL and rebuild" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    const st = graph_store.getGlobalStore(testing.allocator);
    try st.createGraph("g2");
    try h.seed(&.{
        "CREATE (:Doc {body: 'the quick brown fox'})",
        "CREATE (:Doc {body: 'lazy dog sleeps'})",
    });

    const auth_was_enabled = user_mgmt.isAuthEnabled();
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(auth_was_enabled);
    const allow_all_was = gps.isInsecureAllowAll();
    gps.setInsecureAllowAll(true);
    defer gps.setInsecureAllowAll(allow_all_was);

    var grpc_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer grpc_arena.deinit();
    const ga = grpc_arena.allocator();
    var sessions = grpc.SessionStore.init(ga, .{});
    defer sessions.deinit();
    grpc.setSessionStore(&sessions);
    defer grpc.setSessionStore(null);
    const s = try sessions.createSession("indexer", "", null, null, null, false, 0);
    try expectRuns(ga, s, "USE GRAPH g2");

    try testing.expect(try waitsForDefault(ga, s, "CREATE INDEX doc_idx FOR (d:Doc) ON (d.body) USING fulltext"));
    const adapter = graph_store.getGlobalAdapter().?;
    try testing.expect(adapter.getFulltextIndexNamed(default_graph, "doc_idx") != null);
    try testing.expect(try waitsForDefault(ga, s, "CALL geode.fts.rebuild('doc_idx')"));
    try expectRuns(ga, s, "CALL geode.fts.search('doc_idx', 'fox')");
    try testing.expect(try waitsForDefault(ga, s, "DROP INDEX doc_idx"));
    try testing.expect(adapter.getFulltextIndexNamed(default_graph, "doc_idx") == null);

    // A request that changes g2 and rebuilds the default graph's index
    // changes two graphs.
    const resp = try execute(ga, s, "CREATE (:Doc {body: 'x'}); CALL geode.fts.rebuild('doc_idx')");
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| try testing.expectEqualStrings("0A000", e.code),
        else => return error.ExpectedRefusal,
    }
}
