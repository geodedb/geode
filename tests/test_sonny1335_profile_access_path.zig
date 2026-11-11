// SONNY-1335 regression: a PROFILE payload reports the access path the
// executor took, and names an index only when it is a real catalog index.
//
// The version-1 payload (`profile_payload.buildProfilePayload`, the PROFILE
// arm every tenant-bound or RLS-evaluating session is demoted to) put a
// `NodeIndexScan` operator first whenever the query had a WHERE or FILTER
// equality, and named it with the literal "heuristic_index": no catalog
// lookup, and the legacy executor that ran the query did a label scan. The
// version-2 payload (`buildProfilePayloadFromTrace`, planned reads) copied
// the plan's `IndexSeek` decision into the trace whether or not the executor
// then seeked (an AND in the WHERE, a fulltext index on the property), and
// never carried the index's name.
//
// These tests drive the real gRPC Execute handler in process (the same
// payload builders the QUIC handler uses) against a persisted store, and read
// the profile payload a client receives.
//
// CANARY: REQ=REQ-SONNY-1335-PROFILE-ACCESS-PATH; FEATURE="PROFILE"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny1335_profile_access_path.zig; OWNER=engine; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");

/// What a profile payload says about how the query found its rows.
const Access = struct {
    version: u32,
    /// Operators that claim an index (`IndexSeek`, `NodeIndexScan`, or any
    /// operator carrying an `index_name`).
    index_ops: usize,
    /// The non-empty `index_name`s, in operator order.
    names: []const []const u8,
    /// Operators that say they scanned (`LabelScan`, `AllNodesScan`,
    /// `NodeScan`).
    scan_ops: usize,
};

fn profile(ga: std.mem.Allocator, session: []const u8, query: []const u8) !Access {
    const resp = try fx.execute(ga, session, query);
    const p = switch (resp.payload orelse return error.MissingPayload) {
        .profile => |p| p,
        .@"error" => |e| {
            std.debug.print("{s}: {s} {s}\n", .{ query, e.code, e.message });
            return error.QueryFailed;
        },
        else => return error.ExpectedProfile,
    };
    var names = std.ArrayList([]const u8).empty;
    var index_ops: usize = 0;
    var scan_ops: usize = 0;
    for (p.ops.items) |op| {
        const claims = std.mem.eql(u8, op.op, "IndexSeek") or
            std.mem.eql(u8, op.op, "NodeIndexScan") or
            op.index_name.len > 0;
        if (claims) index_ops += 1;
        if (op.index_name.len > 0) try names.append(ga, op.index_name);
        if (std.mem.eql(u8, op.op, "LabelScan") or
            std.mem.eql(u8, op.op, "AllNodesScan") or
            std.mem.eql(u8, op.op, "NodeScan")) scan_ops += 1;
    }
    const a = Access{ .version = p.profile_version, .index_ops = index_ops, .names = names.items, .scan_ops = scan_ops };
    std.debug.print("{s}\n  -> v{d} index_ops={d} scan_ops={d} names=", .{ query, a.version, a.index_ops, a.scan_ops });
    for (a.names) |n| std.debug.print("\"{s}\" ", .{n});
    std.debug.print("\n", .{});
    return a;
}

/// Index names SHOW INDEXES lists, read through Execute + Pull as a client
/// reads them.
fn showIndexNames(ga: std.mem.Allocator, session: []const u8) ![]const []const u8 {
    const resp = try fx.execute(ga, session, "SHOW INDEXES");
    switch (resp.payload orelse return error.MissingPayload) {
        .schema => {},
        .@"error" => |e| {
            std.debug.print("SHOW INDEXES: {s} {s}\n", .{ e.code, e.message });
            return error.QueryFailed;
        },
        else => return error.UnexpectedPayload,
    }
    var names = std.ArrayList([]const u8).empty;
    const req = try fx.encodeProto(ga, schema.PullRequest{ .session_id = session, .page_size = 256 });
    const pull = try fx.decodeProto(schema.PullResponse, ga, try grpc.handlePull(req, ga));
    const presp = pull.response orelse return error.MissingPayload;
    switch (presp.payload orelse return error.MissingPayload) {
        .page => |page| for (page.rows.items) |row| {
            if (row.values.items.len == 0) continue;
            const kind = row.values.items[0].kind orelse continue;
            switch (kind) {
                .string_val => |sv| try names.append(ga, sv.value),
                else => {},
            }
        },
        else => return error.UnexpectedPayload,
    }
    return names.items;
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// No profile ever names an index the catalog does not have.
fn expectNamesAreCatalogIndexes(ga: std.mem.Allocator, session: []const u8, a: Access) !void {
    const catalog_names = try showIndexNames(ga, session);
    for (a.names) |n| {
        if (!contains(catalog_names, n)) std.debug.print("index_name \"{s}\" is not in SHOW INDEXES\n", .{n});
        try testing.expect(contains(catalog_names, n));
    }
}

fn expectScan(ga: std.mem.Allocator, session: []const u8, a: Access) !void {
    try testing.expectEqual(@as(usize, 0), a.index_ops);
    try testing.expectEqual(@as(usize, 0), a.names.len);
    try testing.expect(a.scan_ops >= 1);
    try expectNamesAreCatalogIndexes(ga, session, a);
}

fn expectIndex(ga: std.mem.Allocator, session: []const u8, a: Access, name: []const u8) !void {
    try testing.expectEqual(@as(usize, 1), a.index_ops);
    try testing.expectEqual(@as(usize, 1), a.names.len);
    try testing.expectEqualStrings(name, a.names[0]);
    try testing.expect(contains(try showIndexNames(ga, session), name));
}

fn seed(ga: std.mem.Allocator, session: []const u8) !void {
    try fx.expectRuns(ga, session, "USE GRAPH g1");
    try fx.expectRuns(ga, session, "CREATE (:PlanProbe {k: 1, note: 'n1', tag: 't1', body: 'alpha beta'})");
    try fx.expectRuns(ga, session, "CREATE (:PlanProbe {k: 2, note: 'n2', tag: 't2', body: 'gamma delta'})");
    try fx.expectRuns(ga, session, "CREATE (:PlanProbe {k: 3, note: 'n3', tag: 't3', body: 'alpha omega'})");
    try fx.expectRuns(ga, session, "CREATE (:Other {k: 9, note: 'n1'})");
}

const eq_where = "PROFILE MATCH (n:PlanProbe) WHERE n.note = 'n1' RETURN n.k";
const eq_inline = "PROFILE MATCH (n:PlanProbe {note: 'n1'}) RETURN n.k";
const eq_and = "PROFILE MATCH (n:PlanProbe) WHERE n.k >= 0 AND n.note = 'n1' RETURN n.k";
const eq_body = "PROFILE MATCH (n:PlanProbe) WHERE n.body = 'alpha beta' RETURN n.k";

test "SONNY-1335: a planned PROFILE names exactly the catalog index the executor seeked, and says scan otherwise" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("planned");
    try seed(ga, s);

    // (1) No index on PlanProbe.note: a scan, no index name.
    try expectScan(ga, s, try profile(ga, s, eq_where));
    try expectScan(ga, s, try profile(ga, s, eq_inline));

    // (3) An index on another property of the label, and on the same
    // property of another label: still a scan.
    try fx.expectRuns(ga, s, "CREATE INDEX pp_tag FOR (n:PlanProbe) ON (n.tag)");
    try fx.expectRuns(ga, s, "CREATE INDEX other_note FOR (n:Other) ON (n.note)");
    try expectScan(ga, s, try profile(ga, s, eq_where));

    // (6) A fulltext index serves CALL geode.fts.*, not an equality: a
    // WHERE n.body = ... is not served by it.
    try fx.expectRuns(ga, s, "CREATE INDEX pp_body FOR (n:PlanProbe) ON (n.body) USING fulltext");
    try expectScan(ga, s, try profile(ga, s, eq_body));

    // (2) CREATE INDEX on the label and property: the profile names exactly
    // that index, a name SHOW INDEXES lists.
    try fx.expectRuns(ga, s, "CREATE INDEX pp_note FOR (n:PlanProbe) ON (n.note)");
    const seek_where = try profile(ga, s, eq_where);
    try testing.expect(seek_where.version >= 2);
    try expectIndex(ga, s, seek_where, "pp_note");
    try expectIndex(ga, s, try profile(ga, s, eq_inline), "pp_note");

    // (5) The old heuristic called any WHERE equality an index scan, and the
    // plan called this one an IndexSeek (an equality on an indexed property
    // under an AND), but the executor seeks only on a WHERE that is a single
    // equality: it scanned the label, and the profile says so.
    try expectScan(ga, s, try profile(ga, s, eq_and));

    // A procedure call is not reported as an index scan of a made-up index.
    try expectNamesAreCatalogIndexes(ga, s, try profile(ga, s, "PROFILE CALL geode.fts.search('pp_body', 'alpha')"));

    // (4) DROP INDEX: a scan again.
    try fx.expectRuns(ga, s, "DROP INDEX pp_note");
    try expectScan(ga, s, try profile(ga, s, eq_where));
    try expectScan(ga, s, try profile(ga, s, eq_inline));
}

test "SONNY-1335: a tenant-bound PROFILE (version 1, the legacy executor) never fabricates an index scan" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const admin = try f.session("admin");
    try seed(ga, admin);
    const t = try f.sessions.createSession("tenant", "", null, "tenant_a", null, false, 0);
    try fx.expectRuns(ga, t, "USE GRAPH g1");

    // The ticket's reproduction: an UNINDEXED property profiled as
    // NodeIndexScan index_name="heuristic_index".
    const unindexed = try profile(ga, t, eq_where);
    try testing.expectEqual(@as(u32, 1), unindexed.version);
    try expectScan(ga, t, unindexed);
    try expectScan(ga, t, try profile(ga, t, "PROFILE MATCH (n) WHERE n.note = 'n1' RETURN n.k"));

    // With a catalog index on the property the legacy executor still scans
    // the label (it never consults the index catalog), so no index is
    // claimed: the payload reports what ran.
    try fx.expectRuns(ga, admin, "CREATE INDEX pp_note FOR (n:PlanProbe) ON (n.note)");
    try expectScan(ga, t, try profile(ga, t, eq_where));
    try expectScan(ga, t, try profile(ga, t, eq_and));
    try fx.expectRuns(ga, admin, "DROP INDEX pp_note");
    try expectScan(ga, t, try profile(ga, t, eq_where));
}
