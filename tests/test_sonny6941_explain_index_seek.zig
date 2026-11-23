// SONNY-6941 regression: EXPLAIN of an equality covered by a btree index
// plans an index seek, for the parameterised single-node lookup a client
// sends on a tenant-bound session.
//
// The geode-client-go plan test seeds `MERGE (n:PlanProbe {k: $k}) ON CREATE
// SET n.note = ...`, creates `planprobe_k_idx ON PlanProbe(k) USING btree`,
// and sends `EXPLAIN MATCH (n:PlanProbe {k: $p}) RETURN n.k` as a
// parameterised Execute on a session bound to a tenant. v0.8.22 answered
// `IndexSeek, Expand, Project`; main answered `Scan, Expand, Project`: the
// index ignored, and an Expand for a pattern with no relationship.
//
// These tests drive the real gRPC Execute handler in process (the QUIC
// handler builds the same payloads) with the parameter bound on the wire,
// and check, for each session, that EXPLAIN seeks the index for the indexed
// key, scans for the unindexed control, plans no Expand for a pattern with
// no relationship, and says what PROFILE reports the executor did.
//
// CANARY: REQ=REQ-SONNY-6941-EXPLAIN-INDEX-SEEK; FEATURE="EXPLAIN"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6941_explain_index_seek.zig; OWNER=engine; UPDATED=2026-11-23

const std = @import("std");
const testing = std.testing;
const schema = @import("schema");
const fx = @import("sonny738_r12_grpc_fixture.zig");
const grpc = @import("grpc_impl").impl;
const geode = @import("geode");
const rls = @import("rls");
const rls_types = @import("rls_types");
const rh = @import("rls_session_harness.zig");

const execution = geode.execution;

const indexed = "MATCH (n:PlanProbe {k: $p}) RETURN n.k";
const unindexed = "MATCH (n:PlanProbe {note: $p}) RETURN n.k";

fn text(v: []const u8) schema.Value {
    return .{ .kind = .{ .string_val = .{ .value = v, .kind = .STRING } } };
}

/// Runs `query` with `$p` bound to `p` (and `$n` to `n` when given).
fn executeWith(ga: std.mem.Allocator, session: []const u8, query: []const u8, p: []const u8, n: ?[]const u8) !schema.ExecutionResponse {
    var params = std.ArrayList(schema.Param).empty;
    try params.append(ga, .{ .name = "p", .value = text(p) });
    if (n) |v| try params.append(ga, .{ .name = "n", .value = text(v) });
    const req = try fx.encodeProto(ga, schema.ExecuteRequest{ .session_id = session, .query = query, .params = params });
    return fx.decodeProto(schema.ExecutionResponse, ga, try grpc.handleExecute(req, ga, null));
}

fn expectOk(resp: schema.ExecutionResponse, query: []const u8) !void {
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("{s}: {s} {s}\n", .{ query, e.code, e.message });
            return error.QueryFailed;
        },
        else => {},
    }
}

/// What a plan's operators say: an index seek, an expand, a scan.
const Shape = struct { seek: bool = false, expand: bool = false, scan: bool = false };

fn isSeek(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "IndexSeek") or std.mem.eql(u8, kind, "NodeIndexScan");
}

fn isExpand(kind: []const u8) bool {
    return std.mem.startsWith(u8, kind, "Expand") or std.mem.eql(u8, kind, "VarLengthExpand");
}

fn isScan(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "Scan") or std.mem.eql(u8, kind, "LabelScan") or std.mem.eql(u8, kind, "AllNodesScan");
}

fn explain(ga: std.mem.Allocator, session: []const u8, body: []const u8, out: *std.ArrayList([]const u8)) !Shape {
    const q = try std.fmt.allocPrint(ga, "EXPLAIN {s}", .{body});
    const resp = try executeWith(ga, session, q, "a", null);
    try expectOk(resp, q);
    const p = switch (resp.payload.?) {
        .explain => |p| p,
        else => return error.ExpectedExplain,
    };
    var shape: Shape = .{};
    var line = std.ArrayList(u8).empty;
    try line.print(ga, "EXPLAIN {s} [{s}]:", .{ body, p.schema });
    for (p.ops.items) |op| {
        try line.print(ga, " {s}", .{op.kind});
        if (isSeek(op.kind)) shape.seek = true;
        if (isExpand(op.kind)) shape.expand = true;
        if (isScan(op.kind)) shape.scan = true;
    }
    try out.append(ga, line.items);
    return shape;
}

fn profile(ga: std.mem.Allocator, session: []const u8, body: []const u8, out: *std.ArrayList([]const u8)) !Shape {
    const q = try std.fmt.allocPrint(ga, "PROFILE {s}", .{body});
    const resp = try executeWith(ga, session, q, "a", null);
    try expectOk(resp, q);
    const p = switch (resp.payload.?) {
        .profile => |p| p,
        else => return error.ExpectedProfile,
    };
    var shape: Shape = .{};
    var line = std.ArrayList(u8).empty;
    try line.print(ga, "PROFILE {s}:", .{body});
    for (p.ops.items) |op| {
        try line.print(ga, " {s}", .{op.op});
        if (isSeek(op.op) or op.index_name.len > 0) shape.seek = true;
        if (isExpand(op.op)) shape.expand = true;
        if (isScan(op.op)) shape.scan = true;
    }
    try out.append(ga, line.items);
    return shape;
}

/// The client's setup, on `session`: three MERGEd PlanProbe nodes, then a
/// btree index on PlanProbe(k).
fn seed(ga: std.mem.Allocator, session: []const u8) !void {
    try fx.expectRuns(ga, session, "USE GRAPH g1");
    for ([_][]const u8{ "a", "b", "c" }) |k| {
        const note = try std.fmt.allocPrint(ga, "seed-{s}", .{k});
        const q = "MERGE (n:PlanProbe {k: $p}) ON CREATE SET n.note = $n";
        try expectOk(try executeWith(ga, session, q, k, note), q);
    }
    try fx.expectRuns(ga, session, "CREATE INDEX planprobe_k_idx ON PlanProbe(k) USING btree");
}

fn checkSession(ga: std.mem.Allocator, session: []const u8, label: []const u8) !void {
    var lines = std.ArrayList([]const u8).empty;
    var fails = std.ArrayList([]const u8).empty;

    const e_idx = try explain(ga, session, indexed, &lines);
    const p_idx = try profile(ga, session, indexed, &lines);
    const e_ctl = try explain(ga, session, unindexed, &lines);
    const p_ctl = try profile(ga, session, unindexed, &lines);

    if (!e_idx.seek) try fails.append(ga, "EXPLAIN of the indexed key plans no index seek");
    if (!p_idx.seek) try fails.append(ga, "PROFILE of the indexed key reports no index seek");
    if (e_idx.expand) try fails.append(ga, "EXPLAIN of the indexed key plans an Expand for a pattern with no relationship");
    if (e_ctl.seek or !e_ctl.scan) try fails.append(ga, "EXPLAIN of the unindexed control does not plan a scan");
    if (p_ctl.seek) try fails.append(ga, "PROFILE of the unindexed control reports an index seek");
    if (e_ctl.expand) try fails.append(ga, "EXPLAIN of the unindexed control plans an Expand for a pattern with no relationship");

    if (fails.items.len == 0) return;
    std.debug.print("\nSONNY-6941 [{s}]:\n", .{label});
    for (lines.items) |l| std.debug.print("  {s}\n", .{l});
    for (fails.items) |f| std.debug.print("  FAIL: {s}\n", .{f});
    return error.ExplainIgnoresIndex;
}

test "SONNY-6941: a tenant-bound session's EXPLAIN seeks the btree index for a parameterised equality" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const t = try f.sessions.createSession("tenant", "", null, "tenant_a", null, false, 0);
    try seed(ga, t);
    try checkSession(ga, t, "tenant-bound");
}

/// The `n.k` values `indexed` returns with `$p` bound to `p`.
fn keysFor(ga: std.mem.Allocator, session: []const u8, p: []const u8) ![]const []const u8 {
    return keysOf(ga, session, indexed, p);
}

/// The first column (strings) of the rows `query` returns with `$p` bound to
/// `p`.
fn keysOf(ga: std.mem.Allocator, session: []const u8, query: []const u8, p: []const u8) ![]const []const u8 {
    try expectOk(try executeWith(ga, session, query, p, null), query);
    const req = try fx.encodeProto(ga, schema.PullRequest{ .session_id = session, .page_size = 256 });
    const pull = try fx.decodeProto(schema.PullResponse, ga, try grpc.handlePull(req, ga));
    const resp = pull.response orelse return error.MissingPayload;
    var keys = std.ArrayList([]const u8).empty;
    switch (resp.payload orelse return error.MissingPayload) {
        .page => |page| for (page.rows.items) |row| {
            const kind = row.values.items[0].kind orelse return error.UnexpectedValue;
            switch (kind) {
                .string_val => |sv| try keys.append(ga, sv.value),
                else => return error.UnexpectedValue,
            }
        },
        else => return error.UnexpectedPayload,
    }
    return keys.items;
}

/// The rows of the index operator `PROFILE indexed` reports with `$p` bound
/// to `p`.
fn seekRows(ga: std.mem.Allocator, session: []const u8, p: []const u8) !u64 {
    const q = "PROFILE " ++ indexed;
    const resp = try executeWith(ga, session, q, p, null);
    try expectOk(resp, q);
    const prof = switch (resp.payload.?) {
        .profile => |pp| pp,
        else => return error.ExpectedProfile,
    };
    for (prof.ops.items) |op| {
        if (op.index_name.len > 0) return @intCast(op.rows);
    }
    return error.NoIndexOperator;
}

test "SONNY-6941: the tenant-bound seek returns the tenant's own node and no other tenant's" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const a = try f.sessions.createSession("tenant_a", "", null, "tenant_a", null, false, 0);
    const b = try f.sessions.createSession("tenant_b", "", null, "tenant_b", null, false, 0);
    try seed(ga, a);
    try fx.expectRuns(ga, b, "USE GRAPH g1");

    // tenant_a's node is the index's only posting for 'a'; tenant_b's seek
    // finds it and must drop it.
    const own = try keysFor(ga, a, "a");
    try testing.expectEqual(@as(usize, 1), own.len);
    try testing.expectEqualStrings("a", own[0]);
    try testing.expectEqual(@as(usize, 0), (try keysFor(ga, b, "a")).len);
    try testing.expectEqual(@as(usize, 0), (try keysFor(ga, a, "zz")).len);
    // Nor does tenant_b's PROFILE count tenant_a's node among the seek's rows.
    try testing.expectEqual(@as(u64, 1), try seekRows(ga, a, "a"));
    try testing.expectEqual(@as(u64, 0), try seekRows(ga, b, "a"));

    // tenant_b MERGEs its own 'a': each tenant sees exactly its own.
    const q = "MERGE (n:PlanProbe {k: $p}) ON CREATE SET n.note = $n";
    try expectOk(try executeWith(ga, b, q, "a", "seed-b"), q);
    try testing.expectEqual(@as(usize, 1), (try keysFor(ga, a, "a")).len);
    try testing.expectEqual(@as(usize, 1), (try keysFor(ga, b, "a")).len);
}

test "SONNY-6941: an unscoped session's EXPLAIN seeks the btree index for a parameterised equality" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("plain");
    try seed(ga, s);
    try checkSession(ga, s, "unscoped");
}

// ---------------------------------------------------------------------------
// The seek's isolation (security review of the SONNY-6941 fix). Each case
// checks the rows a restricted session gets on the seek path, and whether the
// legacy executor took the seek (`execution.takeExactSeek`: the transport
// reads it only for a PROFILE, so after a plain Execute on this thread it is
// the statement's).

/// The rows of `query` (with `$p` = `p`) as `session`, and the seek the
/// legacy executor took for it, if any.
const Run = struct { keys: []const []const u8, seek: @TypeOf(execution.takeExactSeek()) };

fn runSeek(ga: std.mem.Allocator, session: []const u8, query: []const u8, p: []const u8) !Run {
    _ = execution.takeExactSeek();
    const keys = try keysOf(ga, session, query, p);
    return .{ .keys = keys, .seek = execution.takeExactSeek() };
}

fn expectKeys(want: []const []const u8, got: Run) !void {
    if (want.len != got.keys.len) {
        std.debug.print("want {d} row(s), got {d}:", .{ want.len, got.keys.len });
        for (got.keys) |k| std.debug.print(" {s}", .{k});
        std.debug.print("\n", .{});
        return error.WrongRows;
    }
    for (want, got.keys) |w, g| try testing.expectEqualStrings(w, g);
}

fn merge(ga: std.mem.Allocator, session: []const u8, k: []const u8, note: []const u8) !void {
    const q = "MERGE (n:PlanProbe {k: $p}) ON CREATE SET n.note = $n";
    try expectOk(try executeWith(ga, session, q, k, note), q);
}

const by_k_note = "MATCH (n:PlanProbe {k: $p}) RETURN n.note";

test "SONNY-6941: with no catalog index the legacy executor scans, as its EXPLAIN and PROFILE say" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const t = try f.sessions.createSession("tenant", "", null, "tenant_a", null, false, 0);
    try fx.expectRuns(ga, t, "USE GRAPH g1");
    try merge(ga, t, "a", "seed-a");
    try merge(ga, t, "b", "seed-b");

    // The exact property index is always on; with no btree or hash index
    // in the catalog the executor must not seek it unreported.
    const r = try runSeek(ga, t, indexed, "a");
    try expectKeys(&.{"a"}, r);
    try testing.expect(r.seek == null);
    var lines = std.ArrayList([]const u8).empty;
    try testing.expect(!(try explain(ga, t, indexed, &lines)).seek);
    try testing.expect(!(try profile(ga, t, indexed, &lines)).seek);
}

test "SONNY-6941: the seek reads only the session's graph" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const t1 = try f.sessions.createSession("t1", "", null, "tenant_a", null, false, 0);
    const t2 = try f.sessions.createSession("t2", "", null, "tenant_a", null, false, 0);
    try seed(ga, t1);
    try fx.expectRuns(ga, t2, "USE GRAPH g2");
    try merge(ga, t2, "a", "g2-a");

    // g1 has the index, g2 holds the same label, key and value.
    const r1 = try runSeek(ga, t1, by_k_note, "a");
    try expectKeys(&.{"seed-a"}, r1);
    try testing.expect(r1.seek != null);
    try expectKeys(&.{"g2-a"}, try runSeek(ga, t2, by_k_note, "a"));

    // And with an index in g2 too, each graph seeks its own.
    try fx.expectRuns(ga, t2, "CREATE INDEX planprobe_k_idx2 ON PlanProbe(k) USING btree");
    const r2 = try runSeek(ga, t2, by_k_note, "a");
    try expectKeys(&.{"g2-a"}, r2);
    try testing.expect(r2.seek != null);
    try expectKeys(&.{"seed-a"}, try runSeek(ga, t1, by_k_note, "a"));
}

test "SONNY-6941: the seek drops a deleted node" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const t = try f.sessions.createSession("tenant", "", null, "tenant_a", null, false, 0);
    try seed(ga, t);
    try fx.expectRuns(ga, t, "MATCH (n:PlanProbe {k: 'a'}) DETACH DELETE n");

    const r = try runSeek(ga, t, indexed, "a");
    try expectKeys(&.{}, r);
    try testing.expect(r.seek != null);
    try testing.expectEqual(@as(u64, 0), r.seek.?.rows);
    try expectKeys(&.{"b"}, try runSeek(ga, t, indexed, "b"));
}

test "SONNY-6941: in lean index mode a key outside the exact index scans, with the right rows" {
    graph_store_lean(true);
    defer graph_store_lean(false);
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const t = try f.sessions.createSession("tenant", "", null, "tenant_a", null, false, 0);
    try seed(ga, t);
    try fx.expectRuns(ga, t, "CREATE INDEX planprobe_note_idx ON PlanProbe(note) USING btree");

    // `note` is no MERGE key: the exact index does not hold it, so the
    // executor cannot seek it and must scan; EXPLAIN and PROFILE agree.
    try testing.expect(!geode.graph_store.shouldIndexProperty("note"));
    const r = try runSeek(ga, t, unindexed, "seed-b");
    try expectKeys(&.{"b"}, r);
    try testing.expect(r.seek == null);
    var lines = std.ArrayList([]const u8).empty;
    try testing.expect(!(try explain(ga, t, unindexed, &lines)).seek);
    try testing.expect(!(try profile(ga, t, unindexed, &lines)).seek);
}

fn graph_store_lean(on: bool) void {
    geode.graph_store.setLeanIndexingForTest(on);
}

test "SONNY-6941: the seek honours the tenant hierarchy (a parent sees its child's node, a stranger does not)" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const engine = try testing.allocator.create(rls.RLSEngine);
    engine.* = try rls.RLSEngine.init(testing.allocator);
    rls_types.setGlobalExprRLSEngine(@ptrCast(engine));
    defer {
        rls_types.setGlobalExprRLSEngine(null);
        engine.deinit();
        testing.allocator.destroy(engine);
    }
    try engine.hierarchy_manager.addTenant("p6941", null);
    try engine.hierarchy_manager.addTenant("c6941", "p6941");
    try engine.hierarchy_manager.addTenant("u6941", null);

    const child = try f.sessions.createSession("child", "", null, "c6941", null, false, 0);
    const parent = try f.sessions.createSession("parent", "", null, "p6941", null, false, 0);
    const stranger = try f.sessions.createSession("stranger", "", null, "u6941", null, false, 0);
    try seed(ga, child);
    try fx.expectRuns(ga, parent, "USE GRAPH g1");
    try fx.expectRuns(ga, stranger, "USE GRAPH g1");

    const rc = try runSeek(ga, child, indexed, "a");
    try expectKeys(&.{"a"}, rc);
    try testing.expect(rc.seek != null);
    const rp = try runSeek(ga, parent, indexed, "a");
    try expectKeys(&.{"a"}, rp);
    try testing.expect(rp.seek != null);
    try testing.expectEqual(@as(u64, 1), rp.seek.?.rows);
    const ru = try runSeek(ga, stranger, indexed, "a");
    try expectKeys(&.{}, ru);
    try testing.expectEqual(@as(u64, 0), ru.seek.?.rows);
}

test "SONNY-6941: the seek on a graph deferred at open hydrates it first and returns its rows" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const t = try f.sessions.createSession("tenant", "", null, "tenant_a", null, false, 0);
    try seed(ga, t);
    try f.st.markPendingHydrationForTest("g1");

    const r = try runSeek(ga, t, indexed, "b");
    try expectKeys(&.{"b"}, r);
    try testing.expect(r.seek != null);
}

test "SONNY-6941: the seek on a quarantined graph fails the read" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const t = try f.sessions.createSession("tenant", "", null, "tenant_a", null, false, 0);
    try seed(ga, t);
    f.st.quarantineGraphReads("g1", error.DataCorruption);

    const resp = try executeWith(ga, t, indexed, "a", null);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => {},
        else => return error.QuarantinedGraphRead,
    }
}

test "SONNY-6941: an expression RLS policy hides its rows on the seek path" {
    var s = try rh.Session.init(.expr_policy);
    defer s.deinit();
    try s.execAs(null, "CREATE (:Doc {k: 'x', s: 'open1', cls: 'open'})");
    try s.execAs(null, "CREATE (:Doc {k: 'x', s: 'hidden', cls: 'secret'})");
    try s.execAs(null, "CREATE (:Doc {k: 'y', s: 'other', cls: 'open'})");
    try s.execAs(null, "CREATE INDEX doc_k_6941 ON Doc(k) USING btree");
    try s.restrict("Doc");

    _ = execution.takeExactSeek();
    var r = try s.run("MATCH (n:Doc {k: 'x'}) RETURN n.s");
    const seek = execution.takeExactSeek();
    try testing.expectEqual(@as(usize, 1), r.rows.len);
    try testing.expectEqualStrings("open1", try rh.render(s.arena.allocator(), r.rows[0][0]));
    r.deinit(s.arena.allocator());
    try testing.expect(seek != null);
}
