// SONNY-6594 (1): a rollback that cannot read a body it must undo fails
// loudly; it never skips the change as if the entity were gone.
//
// The undo replays each change through the store (`undoEntryLogged`). It
// asked `nodeExistsForUndo` / `edgeExistsForUndo` whether the entity is
// still there, and those took a body that could not be READ (the hydrated
// getter's error: out of memory, an engine read error) for an absent one:
// the change was skipped and ROLLBACK reported success with the
// transaction's write still in place. The statement record had the same
// hole one step earlier: a write whose "before" image could not be read
// recorded nothing, so its undo had nothing to replay.
//
// A real store with a data directory, the real gRPC handlers in process
// (`sonny738_r12_grpc_fixture.zig`), and `BodyFault` (the caches' body
// rebuilds fail on demand; `sonny6594_body_fault.zig`). Each transaction
// changes a node or an edge; its body is evicted and ROLLBACK runs with the
// rebuild failing. ROLLBACK must then either fail (40003, "may be partly
// applied") or leave the data exactly as it was before the transaction; it
// must never report success with the change still there. A sweep fails the
// rebuilds from each allocation on during the write itself: the write
// fails or is undone by the ROLLBACK that follows.
//
// CANARY: REQ=REQ-SONNY-6594-UNDO-READ-FAILURE; FEATURE="TransactionUndoLog"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6594_undo_read_failure.zig; OWNER=engine; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");
const BodyFault = @import("sonny6594_body_fault.zig").BodyFault;

const MAX_SWEEP: usize = 4_000;

/// The rows `query` answers (it must run).
fn rows(ga: std.mem.Allocator, s: []const u8, query: []const u8) !usize {
    const resp = try fx.execute(ga, s, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("SONNY-6594 (1) {s}: {s} {s}\n", .{ query, e.code, e.message });
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

const Change = struct {
    name: []const u8,
    /// Run inside the transaction.
    write: []const u8,
    /// Rows when the data is as it was before the transaction.
    check: []const u8,
    clean: usize,
};

const changes = [_]Change{
    .{ .name = "SET a node property", .write = "MATCH (n:U6594 {k: 1}) SET n.v = 2", .check = "MATCH (n:U6594 {k: 1}) WHERE n.v = 1 RETURN n", .clean = 1 },
    .{ .name = "REMOVE a node property", .write = "MATCH (n:U6594 {k: 1}) REMOVE n.v", .check = "MATCH (n:U6594 {k: 1}) WHERE n.v = 1 RETURN n", .clean = 1 },
    .{ .name = "SET a label", .write = "MATCH (n:U6594 {k: 1}) SET n:Extra6594", .check = "MATCH (n:Extra6594) RETURN n", .clean = 0 },
    .{ .name = "SET an edge property", .write = "MATCH (:U6594 {k: 1})-[r:R6594]->() SET r.w = 2", .check = "MATCH ()-[r:R6594]->() WHERE r.w = 1 RETURN r", .clean = 1 },
    .{ .name = "DELETE an edge", .write = "MATCH (:U6594 {k: 1})-[r:R6594]->() DELETE r", .check = "MATCH ()-[r:R6594]->() RETURN r", .clean = 1 },
};

fn seed(ga: std.mem.Allocator, s: []const u8) !void {
    try fx.expectRuns(ga, s, "CREATE (:U6594 {k: 1, v: 1})-[:R6594 {w: 1}]->(:U6594 {k: 2, v: 1})");
}

test "SONNY-6594 (1): ROLLBACK that cannot read a body it must undo fails, never reports success with the change left in place" {
    var f: fx.Fixture = undefined;
    try f.initWith(.{ .bounded_caches = true });
    defer f.deinit();
    const ga = f.ga();
    var fault: BodyFault = undefined;
    fault.init(f.st);
    const s = try f.session("u6594");
    try seed(ga, s);

    var wrong: usize = 0;
    for (changes) |c| {
        try fx.begin(ga, s);
        try fx.expectRuns(ga, s, c.write);
        try fault.evictAll();
        fault.on();
        const ok = fx.rollback(ga, s);
        const induced = fault.off();
        const left = try rows(ga, s, c.check);
        const rolled_back = ok catch false;
        std.debug.print("SONNY-6594 (1) {s}: ROLLBACK {s}, body read failed: {}, check {d} (clean {d})\n", .{ c.name, if (rolled_back) "succeeded" else "failed", induced, left, c.clean });
        if (rolled_back and left != c.clean) wrong += 1;
        if (!rolled_back and left != c.clean) {
            // Partly applied, and reported: put the data back for the next case.
            try fx.expectRuns(ga, s, "MATCH (n:U6594) DETACH DELETE n");
            try fx.expectRuns(ga, s, "MATCH (n:Extra6594) DETACH DELETE n");
            try seed(ga, s);
        }
    }
    try testing.expectEqual(@as(usize, 0), wrong);
}

test "SONNY-6594 (1): a write whose before-image cannot be read fails or is undone by ROLLBACK" {
    var f: fx.Fixture = undefined;
    try f.initWith(.{ .bounded_caches = true });
    defer f.deinit();
    const ga = f.ga();
    var fault: BodyFault = undefined;
    fault.init(f.st);
    const s = try f.session("w6594");
    try seed(ga, s);

    var wrong: usize = 0;
    for (changes) |c| {
        var runs: usize = 0;
        var k: usize = 0;
        while (k < MAX_SWEEP) : (k += 1) {
            try fx.begin(ga, s);
            try fault.evictAll();
            fault.onFrom(k);
            _ = try fx.outcome(ga, s, c.write);
            const induced = fault.off();
            const ok = fx.rollback(ga, s) catch false;
            const left = try rows(ga, s, c.check);
            runs += 1;
            if (left != c.clean) {
                if (ok) {
                    wrong += 1;
                    std.debug.print("SONNY-6594 (1) {s}, rebuild allocation {d} failing: ROLLBACK succeeded, check {d} (clean {d})\n", .{ c.name, k, left, c.clean });
                }
                try fx.expectRuns(ga, s, "MATCH (n:U6594) DETACH DELETE n");
                try fx.expectRuns(ga, s, "MATCH (n:Extra6594) DETACH DELETE n");
                try seed(ga, s);
            }
            if (!induced) break;
        }
        std.debug.print("SONNY-6594 (1) {s}: {d} runs\n", .{ c.name, runs });
    }
    try testing.expectEqual(@as(usize, 0), wrong);
}
