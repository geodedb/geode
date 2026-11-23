// SONNY-6276 regression: EXPLAIN describes the access path the executor
// takes, the one PROFILE reports (SONNY-1335).
//
// SONNY-1335 made PROFILE name an index only when the executor seeked
// through a catalog btree or hash index on the label and property. EXPLAIN
// kept its own guesses:
//
//   * the planned EXPLAIN (`planned_read_runtime.nodeCanUseIndex`) called
//     the start an `IndexSeek` for an index of any type on the property (a
//     fulltext index too), and for an indexed equality anywhere in an AND
//     chain, where the executor seeks only on a WHERE that is one equality;
//   * the legacy EXPLAIN of the QUIC and gRPC handlers (`whereHasIndexedEq`
//     and the inline-property loop beside it, the version-1 payload a
//     tenant-bound or RLS session gets) did the same, although the legacy
//     executor behind it never reported a catalog index seek (SONNY-6941:
//     it now seeks an indexed inline equality, and both report that);
//   * every query with a WHERE or FILTER equality carried the response flag
//     `U:HeuristicIndexSelection`, index or not.
//
// These tests drive the real gRPC Execute handler in process (the QUIC
// handler builds the same payloads) against a persisted store and compare,
// for each query, what EXPLAIN says the start does with what PROFILE says
// the executor did.
//
// CANARY: REQ=REQ-SONNY-6276-EXPLAIN-ACCESS-PATH; FEATURE="EXPLAIN"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6276_explain_access_path.zig; OWNER=engine; UPDATED=2026-11-13

const std = @import("std");
const testing = std.testing;
const schema = @import("schema");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const heuristic_flag = "U:HeuristicIndexSelection";

/// Whether a payload's operators claim an index, and whether the response
/// carried the heuristic flag.
const Claim = struct { index: bool, flag: bool };

fn hasFlag(status: ?schema.Status) bool {
    const st = status orelse return false;
    for (st.additional_statuses.items) |f| if (std.mem.eql(u8, f, heuristic_flag)) return true;
    for (st.flagger_findings.items) |f| if (std.mem.eql(u8, f, heuristic_flag)) return true;
    return false;
}

fn explain(ga: std.mem.Allocator, session: []const u8, body: []const u8) !Claim {
    const q = try std.fmt.allocPrint(ga, "EXPLAIN {s}", .{body});
    const resp = try fx.execute(ga, session, q);
    const p = switch (resp.payload orelse return error.MissingPayload) {
        .explain => |p| p,
        .@"error" => |e| {
            std.debug.print("{s}: {s} {s}\n", .{ q, e.code, e.message });
            return error.QueryFailed;
        },
        else => return error.ExpectedExplain,
    };
    var index = false;
    for (p.ops.items) |op| {
        if (std.mem.eql(u8, op.kind, "IndexSeek") or std.mem.eql(u8, op.kind, "NodeIndexScan")) index = true;
    }
    return .{ .index = index, .flag = hasFlag(resp.status) };
}

fn profile(ga: std.mem.Allocator, session: []const u8, body: []const u8) !Claim {
    const q = try std.fmt.allocPrint(ga, "PROFILE {s}", .{body});
    const resp = try fx.execute(ga, session, q);
    const p = switch (resp.payload orelse return error.MissingPayload) {
        .profile => |p| p,
        .@"error" => |e| {
            std.debug.print("{s}: {s} {s}\n", .{ q, e.code, e.message });
            return error.QueryFailed;
        },
        else => return error.ExpectedProfile,
    };
    var index = false;
    for (p.ops.items) |op| {
        if (std.mem.eql(u8, op.op, "IndexSeek") or std.mem.eql(u8, op.op, "NodeIndexScan") or op.index_name.len > 0) index = true;
    }
    return .{ .index = index, .flag = hasFlag(resp.status) };
}

const Failures = struct {
    list: std.ArrayList([]const u8) = .empty,

    fn check(self: *Failures, ga: std.mem.Allocator, session: []const u8, label: []const u8, body: []const u8, want_index: bool) !void {
        const e = try explain(ga, session, body);
        const p = try profile(ga, session, body);
        if (e.index != p.index or p.index != want_index or e.flag or p.flag) {
            try self.list.append(ga, try std.fmt.allocPrint(ga, "[{s}] {s}: EXPLAIN index={} flag={}, PROFILE index={} flag={}, want index={}", .{ label, body, e.index, e.flag, p.index, p.flag, want_index }));
        }
    }

    fn finish(self: *Failures, name: []const u8) !void {
        if (self.list.items.len == 0) return;
        std.debug.print("\n{s}: {d} failed check(s):\n", .{ name, self.list.items.len });
        for (self.list.items) |m| std.debug.print("  {s}\n", .{m});
        return error.ExplainDisagreesWithProfile;
    }
};

fn seed(ga: std.mem.Allocator, session: []const u8) !void {
    try fx.expectRuns(ga, session, "USE GRAPH g1");
    try fx.expectRuns(ga, session, "CREATE (:PlanProbe {k: 1, note: 'n1', tag: 't1', body: 'alpha beta'})");
    try fx.expectRuns(ga, session, "CREATE (:PlanProbe {k: 2, note: 'n2', tag: 't2', body: 'gamma delta'})");
    try fx.expectRuns(ga, session, "CREATE (:PlanProbe {k: 3, note: 'n3', tag: 't3', body: 'alpha omega'})");
    try fx.expectRuns(ga, session, "CREATE (:Other {k: 9, note: 'n1'})");
}

const eq_where = "MATCH (n:PlanProbe) WHERE n.note = 'n1' RETURN n.k";
const eq_inline = "MATCH (n:PlanProbe {note: 'n1'}) RETURN n.k";
const eq_and = "MATCH (n:PlanProbe) WHERE n.k >= 0 AND n.note = 'n1' RETURN n.k";
const eq_body = "MATCH (n:PlanProbe) WHERE n.body = 'alpha beta' RETURN n.k";
const eq_body_inline = "MATCH (n:PlanProbe {body: 'alpha beta'}) RETURN n.k";

test "SONNY-6276: a planned EXPLAIN names the access path PROFILE reports" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("planned");
    try seed(ga, s);
    var fails: Failures = .{};

    // No index: a scan, and no heuristic flag for the equality.
    try fails.check(ga, s, "no index", eq_where, false);
    try fails.check(ga, s, "no index", eq_inline, false);

    // An index on another property of the label, and on the property of
    // another label: a scan.
    try fx.expectRuns(ga, s, "CREATE INDEX pp_tag FOR (n:PlanProbe) ON (n.tag)");
    try fx.expectRuns(ga, s, "CREATE INDEX other_note FOR (n:Other) ON (n.note)");
    try fails.check(ga, s, "other index", eq_where, false);

    // A fulltext index does not serve an equality.
    try fx.expectRuns(ga, s, "CREATE INDEX pp_body FOR (n:PlanProbe) ON (n.body) USING fulltext");
    try fails.check(ga, s, "fulltext index", eq_body, false);
    try fails.check(ga, s, "fulltext index", eq_body_inline, false);

    // A btree index on the label and property: a seek, for a WHERE that is
    // one equality and for the inline map; an equality under an AND scans.
    try fx.expectRuns(ga, s, "CREATE INDEX pp_note FOR (n:PlanProbe) ON (n.note)");
    try fails.check(ga, s, "btree index", eq_where, true);
    try fails.check(ga, s, "btree index", eq_inline, true);
    try fails.check(ga, s, "btree index", eq_and, false);

    // DROP INDEX: a scan again.
    try fx.expectRuns(ga, s, "DROP INDEX pp_note");
    try fails.check(ga, s, "dropped index", eq_where, false);
    try fails.check(ga, s, "dropped index", eq_inline, false);

    try fails.finish("SONNY-6276 planned EXPLAIN");
}

test "SONNY-6276: a tenant-bound EXPLAIN (the legacy executor) names the access path its PROFILE reports" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const admin = try f.session("admin");
    try seed(ga, admin);
    const t = try f.sessions.createSession("tenant", "", null, "tenant_a", null, false, 0);
    try fx.expectRuns(ga, t, "USE GRAPH g1");
    var fails: Failures = .{};

    try fails.check(ga, t, "tenant, no index", eq_where, false);
    try fx.expectRuns(ga, admin, "CREATE INDEX pp_note FOR (n:PlanProbe) ON (n.note)");
    // SONNY-6941: the legacy executor seeks an indexed inline equality (its
    // simple-node branch starts from the exact index); a WHERE equality
    // scans.
    try fails.check(ga, t, "tenant, btree index", eq_where, false);
    try fails.check(ga, t, "tenant, btree index", eq_inline, true);
    try fails.check(ga, t, "tenant, btree index", eq_and, false);

    try fails.finish("SONNY-6276 tenant EXPLAIN");
}
