// SONNY-6313: EXPLAIN POLICY asks what the real gates ask, and the tenant
// listings are read-only procedures.
//
// (1) `executeExplainPolicy` derived one action for the inner statement
// (`classifyAction`) and asked `gps.decide` about it on the resource
// `database`, always. The handlers' gates ask per graph and per action: the
// read gate `decide(match_, graph)` on every graph the program reads
// (`query_traits.programReadGraphList`), the write gate `changePermittedOn`
// by the write walk's actions (`write_walk.Actions`) on the graph it changes.
// After SONNY-2753 a graph-scoped policy never matches `database`, so EXPLAIN
// POLICY reported a graph-scoped deny (or allow) as not applying, and it did
// not know the per-action gates (SONNY-2781): an operator debugging a policy
// was told the wrong thing. It now reports one row per decision those gates
// make, for the session's graph.
//
// (2) `geode.tenant.list` and `geode.tenant.show` were not on the read-only
// procedure list, so they classified as changes: a read-only request could
// not list tenants. They are read-only now; listing tenants still needs the
// `admin_tenant` permission (Admin).
//
// Each case runs the statement through the real gRPC Execute handler (the
// gate's verdict) and EXPLAIN POLICY FOR it in the same session (the report).
//
// CANARY: REQ=REQ-SONNY-6313-EXPLAIN-POLICY-GATES; FEATURE="GPS EXPLAIN POLICY"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6313_explain_policy_gates.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const grpc = @import("grpc_impl").impl;
const wd = @import("sonny2753_gps_world.zig");

const World = wd.World;
const write_walk = geode.execution.write_walk;

const read = [_]wd.policy_catalog.Action{.read};
const delete_a = [_]wd.policy_catalog.Action{.delete};

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

const Row = struct { action: []const u8, resource: []const u8, decision: []const u8, reason: []const u8 };

/// EXPLAIN POLICY FOR `inner` through the gRPC Execute handler, as rows.
fn explain(ga: std.mem.Allocator, session_id: []const u8, inner: []const u8) ![]const Row {
    const query = try std.fmt.allocPrint(ga, "EXPLAIN POLICY FOR {s}", .{inner});
    const req = try encodeProto(ga, schema.ExecuteRequest{ .session_id = session_id, .query = query, .params = .empty });
    const resp = try decodeProto(schema.ExecutionResponse, ga, try grpc.handleExecute(req, ga, null));
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("{s}: refused {s} {s}\n", .{ query, e.code, e.message });
            return error.Refused;
        },
        else => {},
    }
    var out = std.ArrayList(Row).empty;
    var pulls: usize = 0;
    while (pulls < 32) : (pulls += 1) {
        const preq = try encodeProto(ga, schema.PullRequest{ .session_id = session_id, .page_size = 64 });
        const pull = try decodeProto(schema.PullResponse, ga, try grpc.handlePull(preq, ga));
        const presp = pull.response orelse return error.MissingPayload;
        const page = switch (presp.payload orelse return error.MissingPayload) {
            .page => |p| p,
            else => return error.UnexpectedPayload,
        };
        for (page.rows.items) |row| {
            if (row.values.items.len != 5) return error.WrongColumnCount;
            var s: [4][]const u8 = undefined;
            for (row.values.items[1..5], 0..) |v, i| {
                s[i] = if (v.kind) |k| switch (k) {
                    .string_val => |sv| sv.value,
                    else => return error.NotAString,
                } else return error.NotAString;
            }
            try out.append(ga, .{ .action = s[0], .resource = s[1], .decision = s[2], .reason = s[3] });
        }
        if (page.final) return out.toOwnedSlice(ga);
    }
    return error.PullNeverFinished;
}

fn findRow(rows: []const Row, action: []const u8, resource: []const u8) ?Row {
    for (rows) |r| {
        if (std.mem.eql(u8, r.action, action) and std.mem.eql(u8, r.resource, resource)) return r;
    }
    return null;
}

fn dump(rows: []const Row) void {
    for (rows) |r| std.debug.print("  {s} {s} {s} {s}\n", .{ r.action, r.resource, r.decision, r.reason });
}

/// EXPLAIN POLICY FOR `inner` has a row for (`action`, `resource`) whose
/// decision is (`allowed`) or is not (`!allowed`) allow.
fn expectReported(ga: std.mem.Allocator, session_id: []const u8, inner: []const u8, action: []const u8, resource: []const u8, allowed: bool) !void {
    const rows = try explain(ga, session_id, inner);
    const r = findRow(rows, action, resource) orelse {
        std.debug.print("EXPLAIN POLICY FOR {s}: no row for {s} on {s}; rows:\n", .{ inner, action, resource });
        dump(rows);
        return error.DecisionNotReported;
    };
    const is_allow = std.mem.eql(u8, r.decision, "allow");
    if (is_allow != allowed) {
        std.debug.print("EXPLAIN POLICY FOR {s}: {s} on {s} reported {s} ({s}); the gate {s}\n", .{ inner, action, resource, r.decision, r.reason, if (allowed) "allows it" else "refuses it" });
        return error.ReportDisagreesWithGate;
    }
}

/// Every row EXPLAIN POLICY FOR `inner` reports is allow.
fn expectAllAllowed(ga: std.mem.Allocator, session_id: []const u8, inner: []const u8) !void {
    const rows = try explain(ga, session_id, inner);
    for (rows) |r| {
        if (!std.mem.eql(u8, r.decision, "allow")) {
            std.debug.print("EXPLAIN POLICY FOR {s}: reports a refusal the gate does not make; rows:\n", .{inner});
            dump(rows);
            return error.ReportDisagreesWithGate;
        }
    }
}

test "SONNY-6313: EXPLAIN POLICY reports a graph-scoped DENY READ on the session's graph, as the read gate applies it" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    try w.policy("no_reads_g1", "g1", &read, .deny);

    const on_g1 = try w.session("rita", .ReadWrite, "g1");
    try wd.expectDenied(ga, on_g1, "MATCH (n) RETURN n");
    try expectReported(ga, on_g1, "MATCH (n) RETURN n", "match_", "graph:g1", false);

    const on_g2 = try w.session("rita", .ReadWrite, "g2");
    try wd.expectRuns(ga, on_g2, "MATCH (n) RETURN n");
    try expectReported(ga, on_g2, "MATCH (n) RETURN n", "match_", "graph:g2", true);
    try expectAllAllowed(ga, on_g2, "MATCH (n) RETURN n");
}

test "SONNY-6313: EXPLAIN POLICY reports the write gate's per-action decisions (a DENY DELETE refuses DELETE, not CREATE)" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    try w.policy("no_deletes_g1", "g1", &delete_a, .deny);

    const on_g1 = try w.session("rita", .ReadWrite, "g1");
    try expectReported(ga, on_g1, "MATCH (n:C) DELETE n", "delete", "graph:g1", false);
    try wd.expectDenied(ga, on_g1, "MATCH (n:C) DELETE n");

    try expectReported(ga, on_g1, "CREATE (:W {v: 1})", "create", "graph:g1", true);
    try expectAllAllowed(ga, on_g1, "CREATE (:W {v: 1})");
    try wd.expectRuns(ga, on_g1, "CREATE (:W {v: 1})");

    try expectReported(ga, on_g1, "MATCH (n:C) SET n.v = 2", "update", "graph:g1", true);
}

test "SONNY-6313: EXPLAIN POLICY reports a graph-scoped allow for a user with no stored role, as the read gate applies it" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    try w.policy("reads_g1", "g1", &read, .allow);

    const on_g1 = try w.session("nora", .None, "g1");
    try wd.expectRuns(ga, on_g1, "MATCH (n) RETURN n");
    try expectReported(ga, on_g1, "MATCH (n) RETURN n", "match_", "graph:g1", true);

    const on_default = try w.session("nora", .None, null);
    try wd.expectDenied(ga, on_default, "MATCH (n) RETURN n");
    try expectReported(ga, on_default, "MATCH (n) RETURN n", "match_", "graph:default", false);
}

/// Whether the write walk (the one derivation behind the lock, the write
/// gate and the read-only floor) counts `query` as a change.
fn changesState(query: []const u8) !bool {
    var parsed = try geode.parseGql(query, testing.allocator);
    defer parsed.deinit();
    return write_walk.statementActions(&parsed.program.statements[0], .{}).changesState();
}

test "SONNY-6313: geode.tenant.list and geode.tenant.show are read-only procedures" {
    try testing.expect(!try changesState("CALL geode.tenant.list()"));
    try testing.expect(!try changesState("CALL geode.tenant.show('t1')"));
    // The changes stay changes.
    for ([_][]const u8{ "CALL geode.tenant.create('t1')", "CALL geode.tenant.drop('t1')", "CALL geode.tenant.set_quota('t1', 'max_nodes', 10)", "CALL geode.tenant.backfill_edge_tags()" }) |q| {
        try testing.expect(try changesState(q));
    }
}

fn executeReadOnly(ga: std.mem.Allocator, session_id: []const u8, query: []const u8) !?schema.Error {
    const req = try encodeProto(ga, schema.ExecuteRequest{ .session_id = session_id, .query = query, .params = .empty, .read_only = true });
    const resp = try decodeProto(schema.ExecutionResponse, ga, try grpc.handleExecute(req, ga, null));
    return switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| e,
        else => null,
    };
}

test "SONNY-6313: a read-only Admin request lists and shows tenants; a ReadOnly user still cannot (admin_tenant)" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ga = w.ga();
    // The server's registry, in memory.
    var reg = geode.security.tenant_registry.TenantRegistry.init(testing.allocator);
    defer reg.deinit();
    geode.security.tenant_registry.setGlobalRegistry(&reg);
    defer geode.security.tenant_registry.setGlobalRegistry(null);
    try reg.create("t6313", null);

    const admin = try w.session("ada", .Admin, null);
    for ([_][]const u8{ "CALL geode.tenant.list()", "CALL geode.tenant.show('t6313')" }) |q| {
        if (try executeReadOnly(ga, admin, q)) |e| {
            std.debug.print("read-only `{s}` as Admin: refused {s} '{s}'\n", .{ q, e.code, e.message });
            return error.ReadOnlyListingRefused;
        }
        try wd.expectDenied(ga, try w.session("otto", .ReadOnly, null), q);
    }
    // A read-only request still refuses a tenant change.
    const e = (try executeReadOnly(ga, admin, "CALL geode.tenant.create('t6314')")) orelse return error.ReadOnlyChangeRan;
    try testing.expectEqualStrings("42501", e.code);
}
