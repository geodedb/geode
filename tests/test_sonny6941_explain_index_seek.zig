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
    try expectOk(try executeWith(ga, session, indexed, p, null), indexed);
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
