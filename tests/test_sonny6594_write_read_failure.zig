// SONNY-6594 (3): a write that cannot read a body it targets fails with the
// read's own error; it never skips the target or reports another cause.
//
// The write paths read each target edge with the hydrated getters and took a
// body that could not be READ (the getter's error: out of memory, an engine
// read error) for an absent one. MERGE's edge probe (`crud_operations`)
// skipped it and created a SECOND edge beside the one it could not read;
// DELETE / DETACH DELETE and the write scope's SET answered
// `EdgeBodyUnresolvable` / `IncidentEdgeUnresolvable` (58000, the error's
// bare name) for what was an out-of-memory or an engine read error.
//
// A real store with a data directory, the real gRPC handlers in process
// (`sonny738_r12_grpc_fixture.zig`) and `BodyFault` (the caches' body
// rebuilds fail on demand; `sonny6594_body_fault.zig`, whose fault is an
// allocation failure: the real cause is out of memory, 53200). Each write
// runs with every edge body evicted and the rebuilds failing: it must fail
// with 53200 and leave the data as it was, or succeed with exactly the
// healthy effect.
//
// CANARY: REQ=REQ-SONNY-6594-WRITE-READ-FAILURE; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6594_write_read_failure.zig; OWNER=execution; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");
const BodyFault = @import("sonny6594_body_fault.zig").BodyFault;

/// The rows `query` answers (it must run).
fn rows(ga: std.mem.Allocator, s: []const u8, query: []const u8) !usize {
    const resp = try fx.execute(ga, s, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("SONNY-6594 (3) {s}: {s} {s}\n", .{ query, e.code, e.message });
            return error.QueryFailed;
        },
        else => {},
    }
    const req = try fx.encodeProto(ga, schema.PullRequest{ .session_id = s, .page_size = 64 });
    const pull = try fx.decodeProto(schema.PullResponse, ga, try grpc.handlePull(req, ga));
    const presp = pull.response orelse return error.MissingPayload;
    return switch (presp.payload orelse return error.MissingPayload) {
        .page => |p| p.rows.items.len,
        else => error.UnexpectedPayload,
    };
}

const Write = struct {
    name: []const u8,
    query: []const u8,
    /// Rows `check` answers before the write, and after a healthy one.
    check: []const u8,
    before: usize,
    after: usize,
};

const writes = [_]Write{
    .{ .name = "MERGE an existing edge", .query = "MATCH (a:W6594 {k: 1}), (b:W6594 {k: 2}) MERGE (a)-[:WR6594]->(b)", .check = "MATCH (:W6594 {k: 1})-[r:WR6594]->(:W6594 {k: 2}) RETURN r", .before = 1, .after = 1 },
    .{ .name = "SET an edge property", .query = "MATCH (:W6594 {k: 1})-[r:WR6594]->() SET r.w = 5", .check = "MATCH ()-[r:WR6594]->() WHERE r.w = 1 RETURN r", .before = 1, .after = 0 },
    .{ .name = "DELETE an edge", .query = "MATCH (:W6594 {k: 1})-[r:WR6594]->() DELETE r", .check = "MATCH ()-[r:WR6594]->() RETURN r", .before = 1, .after = 0 },
    .{ .name = "DETACH DELETE a node", .query = "MATCH (a:W6594 {k: 1}) DETACH DELETE a", .check = "MATCH (a:W6594 {k: 1}) RETURN a", .before = 1, .after = 0 },
};

fn reseed(ga: std.mem.Allocator, s: []const u8) !void {
    try fx.expectRuns(ga, s, "MATCH (n:W6594) DETACH DELETE n");
    try fx.expectRuns(ga, s, "CREATE (:W6594 {k: 1})-[:WR6594 {w: 1}]->(:W6594 {k: 2})");
}

test "SONNY-6594 (3): a write whose target edge body cannot be read fails with the read's error, never skips it" {
    var f: fx.Fixture = undefined;
    try f.initWith(.{ .bounded_caches = true });
    defer f.deinit();
    const ga = f.ga();
    var fault: BodyFault = undefined;
    fault.init(f.st);
    const s = try f.session("w6594");

    var wrong: usize = 0;
    for (writes) |w| {
        try reseed(ga, s);
        try testing.expectEqual(w.before, try rows(ga, s, w.check));
        try fault.evictEdges();
        fault.on();
        const resp = try fx.execute(ga, s, w.query);
        const induced = fault.off();
        const code: ?[]const u8 = switch (resp.payload orelse return error.MissingPayload) {
            .@"error" => |e| e.code,
            else => null,
        };
        const msg: []const u8 = switch (resp.payload.?) {
            .@"error" => |e| e.message,
            else => "",
        };
        const left = try rows(ga, s, w.check);
        std.debug.print("SONNY-6594 (3) {s}: {s} {s} (body read failed: {}), check {d} (before {d}, healthy after {d})\n", .{ w.name, code orelse "succeeded", msg, induced, left, w.before, w.after });
        if (code) |c| {
            // Failed: with the read's own error, and nothing changed.
            if (!std.mem.eql(u8, c, "53200") or left != w.before) wrong += 1;
        } else if (left != w.after) wrong += 1;
    }
    try testing.expectEqual(@as(usize, 0), wrong);
}
