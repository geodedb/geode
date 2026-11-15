// SONNY-6607 (3): a CREATE INDEX whose backfill fails over gRPC tells the
// client; it never reports a clean success.
//
// The QUIC and gRPC handlers run an advanced index's backfill after the
// statement, once the graph lock is released (`rebuildPendingIndexes`), and
// only logged its failure: the client saw CREATE INDEX succeed while the
// index was dropped (SONNY-6594 (2)) or empty. The statement has already
// committed its catalog row by then, so it cannot be failed honestly; the
// failure now rides on the statement's status as a flagger finding
// (`IndexBackfillFailed: ...`; the index and the error are in the log).
//
// A real store with a data directory, the real gRPC handlers in process
// (`sonny738_r12_grpc_fixture.zig`), half the indexed node bodies evicted
// and their rebuild made to fail (`sonny6594_body_fault.zig`).
//
// CANARY: REQ=REQ-SONNY-6607-INDEX-BACKFILL-WARNING; FEATURE="VectorIndex"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6607_index_backfill_warning.zig; OWNER=index; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");
const BodyFault = @import("sonny6594_body_fault.zig").BodyFault;

const graph_store = geode.graph_store;

/// The flagger findings on the statement's result (its Pull page status).
fn findings(ga: std.mem.Allocator, s: []const u8, query: []const u8) !?[]const []const u8 {
    const resp = try fx.execute(ga, s, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("SONNY-6607 (3) {s}: {s} {s}\n", .{ query, e.code, e.message });
            return null;
        },
        else => {},
    }
    const req = try fx.encodeProto(ga, schema.PullRequest{ .session_id = s, .page_size = 8 });
    const pull = try fx.decodeProto(schema.PullResponse, ga, try grpc.handlePull(req, ga));
    const status = pull.response.?.status orelse return &.{};
    return status.flagger_findings.items;
}

fn mentions(list: []const []const u8, needle: []const u8) bool {
    for (list) |f| if (std.mem.indexOf(u8, f, needle) != null) return true;
    return false;
}

test "SONNY-6607 (3): CREATE INDEX over gRPC whose backfill cannot read a body reports it to the client" {
    var f: fx.Fixture = undefined;
    try f.initWith(.{ .bounded_caches = true });
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("b6607");
    var buf: [160]u8 = undefined;
    for (0..6) |i| try fx.expectRuns(ga, s, try std.fmt.bufPrint(&buf, "CREATE (:W6607 {{id: {d}, emb6607: vectorf32('[{d}.0, 1.0, 0.0, 0.0]')}})", .{ i, i }));

    // Healthy: no finding.
    const healthy = (try findings(ga, s, "CREATE INDEX h6607 ON W6607 (emb6607) USING vector WITH (metric = 'l2')")) orelse return error.HealthyRunFailed;
    try testing.expect(!mentions(healthy, "IndexBackfillFailed"));
    try fx.expectRuns(ga, s, "DROP INDEX h6607");

    var fault: BodyFault = undefined;
    fault.init(f.st);
    try testing.expect(fault.evictHalfOfLabel(graph_store.DEFAULT_GRAPH_NAME, "W6607") > 0);
    fault.on();
    const got = try findings(ga, s, "CREATE INDEX v6607 ON W6607 (emb6607) USING vector WITH (metric = 'l2')");
    const induced = fault.off();
    try testing.expect(induced);
    if (got) |list| {
        for (list) |x| std.debug.print("SONNY-6607 (3) finding: {s}\n", .{x});
        // Succeeded: the client must be told the backfill failed.
        try testing.expect(mentions(list, "IndexBackfillFailed"));
    }
}
