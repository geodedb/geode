// SONNY-6607 (2): a REMOVE whose target cannot be read fails with the read's
// own error; it never reports out of memory, nor succeeds without removing.
//
// `GraphStore.removeNodeProperty` / `removeEdgeProperty` return nothing
// (void). A failure inside them reached the statement through
// `undoRecordFailed`, which recorded `OutOfMemory` whatever had happened
// (53200, "the server could not allocate the memory"), or through
// `voidWriteFailed`, which recorded only an out-of-memory and let any other
// error (an engine read error) go: the statement succeeded and the property
// stayed.
//
// A real store with a data directory, the real gRPC handlers in process
// (`sonny738_r12_grpc_fixture.zig`), and `BodyFault.ioErrorOn`: every node
// and edge body the statement must rebuild fails with an engine read error
// (`error.InputOutput`) at the caches' hydrate hook, from the k-th rebuild
// on, for every k up to the first run that needs none. Each REMOVE must
// fail, not with 53200, and leave the property in place, or remove it.
//
// CANARY: REQ=REQ-SONNY-6607-VOID-WRITE-ERRORS; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6607_void_write_errors.zig; OWNER=storage; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");
const BodyFault = @import("sonny6594_body_fault.zig").BodyFault;

const MAX_SWEEP: usize = 64;

/// The rows `query` answers (it must run).
fn rows(ga: std.mem.Allocator, s: []const u8, query: []const u8) !usize {
    const resp = try fx.execute(ga, s, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("SONNY-6607 (2) {s}: {s} {s}\n", .{ query, e.code, e.message });
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

const Case = struct { name: []const u8, query: []const u8, check: []const u8 };

const cases = [_]Case{
    .{ .name = "REMOVE a node property", .query = "MATCH (n:V6607) REMOVE n.p", .check = "MATCH (n:V6607) WHERE n.p = 1 RETURN n" },
    .{ .name = "REMOVE an edge property", .query = "MATCH ()-[r:VR6607]->() REMOVE r.p", .check = "MATCH ()-[r:VR6607]->() WHERE r.p = 1 RETURN r" },
};

test "SONNY-6607 (2): a REMOVE whose target cannot be read fails with the read's error, never out of memory or a silent success" {
    var f: fx.Fixture = undefined;
    try f.initWith(.{ .bounded_caches = true });
    defer f.deinit();
    const ga = f.ga();
    var fault: BodyFault = undefined;
    fault.init(f.st);
    const s = try f.session("v6607");
    try fx.expectRuns(ga, s, "CREATE (:V6607 {p: 1})-[:VR6607 {p: 1}]->(:V6607 {p: 1})");

    var wrong: usize = 0;
    for (cases) |c| {
        var k: usize = 0;
        while (k < MAX_SWEEP) : (k += 1) {
            try fx.expectRuns(ga, s, "MATCH (n:V6607) SET n.p = 1");
            try fx.expectRuns(ga, s, "MATCH ()-[r:VR6607]->() SET r.p = 1");
            const before = try rows(ga, s, c.check);
            try fault.evictAll();
            fault.ioErrorFrom(k);
            const resp = try fx.execute(ga, s, c.query);
            const induced = fault.off();
            const left = try rows(ga, s, c.check);
            switch (resp.payload orelse return error.MissingPayload) {
                .@"error" => |e| {
                    if (std.mem.eql(u8, e.code, "53200") or left != before) {
                        wrong += 1;
                        std.debug.print("SONNY-6607 (2) {s}, rebuild {d} failing: {s} {s}; {d} of {d} rows keep the property\n", .{ c.name, k, e.code, e.message, left, before });
                    }
                },
                else => if (left != 0) {
                    wrong += 1;
                    std.debug.print("SONNY-6607 (2) {s}, rebuild {d} failing: succeeded; {d} of {d} rows keep the property\n", .{ c.name, k, left, before });
                },
            }
            if (!induced) break;
        }
        std.debug.print("SONNY-6607 (2) {s}: {d} runs\n", .{ c.name, k + 1 });
    }
    try testing.expectEqual(@as(usize, 0), wrong);
}

/// `f` (a void store write) inside an open statement scope, every body
/// rebuild failing with an engine read error: the error the statement would
/// fail with (`eval.takeDeferredLimitError`), null when none.
fn deferredErrorOf(fault: *BodyFault, comptime f: anytype, args: anytype) !?geode.eval.EvalError {
    const statement_undo = geode.statement_undo;
    _ = geode.eval.takeDeferredLimitError(true);
    statement_undo.begin(true);
    try fault.evictAll();
    fault.ioErrorOn();
    @call(.auto, f, args);
    _ = fault.off();
    const err = geode.eval.takeDeferredLimitError(true);
    _ = statement_undo.finishFailed(true);
    return err;
}

test "SONNY-6607 (2): a void store write whose body read fails records the read's error, not out of memory or nothing" {
    var f: fx.Fixture = undefined;
    try f.initWith(.{ .bounded_caches = true });
    defer f.deinit();
    const ga = f.ga();
    var fault: BodyFault = undefined;
    fault.init(f.st);
    const s = try f.session("d6607");
    try fx.expectRuns(ga, s, "CREATE (:D6607 {p: 1})-[:DR6607 {p: 1}]->(:D6607 {p: 1})");
    const node_id = f.st.getNodesByLabel(geode.graph_store.DEFAULT_GRAPH_NAME, "D6607").?[0];
    const edge_ids = try f.st.allEdgeIds(testing.allocator);
    defer testing.allocator.free(edge_ids);
    var edge_id: u64 = 0;
    for (edge_ids) |id| {
        const e = (try f.st.getEdgeHydratedChecked(id)) orelse continue;
        if (std.mem.eql(u8, e.label, "DR6607")) edge_id = id;
    }
    try testing.expect(edge_id != 0);

    const on_node = try deferredErrorOf(&fault, geode.graph_store.GraphStore.removeNodeProperty, .{ f.st, node_id, "p" });
    const on_edge = try deferredErrorOf(&fault, geode.graph_store.GraphStore.removeEdgeProperty, .{ f.st, edge_id, "p" });
    std.debug.print("SONNY-6607 (2) removeNodeProperty, body unreadable: {?}; removeEdgeProperty: {?}\n", .{ on_node, on_edge });
    // The statement fails, and not with out of memory: the read failed.
    try testing.expect(on_node != null and on_node.? != error.OutOfMemory);
    try testing.expect(on_edge != null and on_edge.? != error.OutOfMemory);
    // Nothing was removed.
    try testing.expectEqual(@as(usize, 2), try rows(ga, s, "MATCH (n:D6607) WHERE n.p = 1 RETURN n"));
    try testing.expectEqual(@as(usize, 1), try rows(ga, s, "MATCH ()-[r:DR6607]->() WHERE r.p = 1 RETURN r"));
}
