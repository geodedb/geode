// SONNY-6621 (1): a write whose node body cannot be read fails; it never
// takes the node for absent.
//
// MERGE's node probe, MATCH ... CREATE, DETACH DELETE and the scan reads
// rebuilt an evicted node with `getOrHydratePtr(id) catch null` (or
// `getNodePtrForScan`, which swallowed the same error): a node that could
// not be read was "not there", so MERGE created a second node beside it and
// the other paths skipped it.
//
// A real store with a data directory, the real gRPC handlers in process
// (`sonny738_r12_grpc_fixture.zig`), and `BodyFault.ioErrorFrom(k)`: the
// k-th node or edge body rebuild on fails with an engine read error, for
// every k up to the first run that needs none. Each statement must fail or
// leave exactly the healthy state.
//
// CANARY: REQ=REQ-SONNY-6621-HYDRATE-CATCH-NULL; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6621_hydrate_catch_null.zig; OWNER=execution; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");
const BodyFault = @import("sonny6594_body_fault.zig").BodyFault;

fn rows(ga: std.mem.Allocator, s: []const u8, query: []const u8) !usize {
    const resp = try fx.execute(ga, s, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => return error.QueryFailed,
        else => {},
    }
    const req = try fx.encodeProto(ga, schema.PullRequest{ .session_id = s, .page_size = 64 });
    const pull = try fx.decodeProto(schema.PullResponse, ga, try grpc.handlePull(req, ga));
    return switch ((pull.response orelse return error.MissingPayload).payload orelse return error.MissingPayload) {
        .page => |p| p.rows.items.len,
        else => error.UnexpectedPayload,
    };
}

const Case = struct { write: []const u8, check: []const u8, healthy: usize };

const cases = [_]Case{
    // MERGE of an existing node: never a second one.
    .{ .write = "MERGE (n:M6621 {k: 1}) SET n.seen = 1", .check = "MATCH (n:M6621 {k: 1}) RETURN n", .healthy = 1 },
    // MATCH ... CREATE: the edge to the matched node, or nothing.
    .{ .write = "MATCH (a:M6621 {k: 1}) CREATE (a)-[:ME6621]->(:M6621 {k: 2})", .check = "MATCH (:M6621 {k: 1})-[r:ME6621]->() RETURN r", .healthy = 1 },
    // DETACH DELETE: the node and its edges, or nothing.
    .{ .write = "MATCH (a:M6621 {k: 1}) DETACH DELETE a", .check = "MATCH (n:M6621 {k: 1}) RETURN n", .healthy = 0 },
};

fn reseed(ga: std.mem.Allocator, s: []const u8) !void {
    try fx.expectRuns(ga, s, "MATCH (n:M6621) DETACH DELETE n");
    try fx.expectRuns(ga, s, "CREATE (:M6621 {k: 1})-[:MO6621]->(:M6621 {k: 9})");
}

test "SONNY-6621 (1): a write whose node body cannot be read fails or has exactly the healthy effect" {
    var f: fx.Fixture = undefined;
    try f.initWith(.{ .bounded_caches = true });
    defer f.deinit();
    const ga = f.ga();
    var fault: BodyFault = undefined;
    fault.init(f.st);
    const s = try f.session("h6621");
    var wrong: usize = 0;
    for (cases) |c| {
        var k: usize = 0;
        while (k < 64) : (k += 1) {
            try reseed(ga, s);
            const before = try rows(ga, s, c.check);
            try fault.evictAll();
            fault.ioErrorFrom(k);
            const resp = try fx.execute(ga, s, c.write);
            const induced = fault.off();
            const after = try rows(ga, s, c.check);
            const failed = switch (resp.payload orelse return error.MissingPayload) {
                .@"error" => true,
                else => false,
            };
            if ((failed and after != before) or (!failed and after != c.healthy)) {
                wrong += 1;
                std.debug.print("SONNY-6621 (1) {s}, rebuild {d} on failing: {s}, check {d} (before {d}, healthy {d})\n", .{ c.write, k, if (failed) "failed" else "succeeded", after, before, c.healthy });
            }
            if (!induced) break;
        }
    }
    try testing.expectEqual(@as(usize, 0), wrong);
}
