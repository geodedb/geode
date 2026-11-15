// SONNY-6612 (4): a write to a node whose body cannot be read reports the
// read's error, not NodeNotFound.
//
// The write paths resolved their target node with
// `(store.nodes.getOrHydratePtr(id) catch null) orelse return
// error.NodeNotFound` (or `getNodePtrForScan`, which swallows the same
// error): a read error was reported as "the node does not exist"
// (58000 NodeNotFound), which sends an operator looking for a deleted node.
//
// A real store with a data directory, the real gRPC handlers in process
// (`sonny738_r12_grpc_fixture.zig`), and `BodyFault.ioErrorOn`: every node
// and edge body the statement must rebuild fails with an engine read error
// (`error.InputOutput`). Each write must fail, with neither NodeNotFound nor
// EdgeNotFound, and change nothing.
//
// CANARY: REQ=REQ-SONNY-6612-UNREADABLE-NODE-WRITE; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6612_unreadable_node_write.zig; OWNER=execution; UPDATED=2026-11-15

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

const writes = [_][]const u8{
    "MATCH (n:U6612) REMOVE n.p",
    "MATCH (n:U6612) SET n.p = 2",
    "MATCH (n:U6612) SET n:Extra6612",
};

test "SONNY-6612 (4): a write to a node whose body cannot be read reports the read error, not NodeNotFound" {
    var f: fx.Fixture = undefined;
    try f.initWith(.{ .bounded_caches = true });
    defer f.deinit();
    const ga = f.ga();
    var fault: BodyFault = undefined;
    fault.init(f.st);
    const s = try f.session("u6612");
    try fx.expectRuns(ga, s, "CREATE (:U6612 {p: 1})");

    var wrong: usize = 0;
    for (writes) |q| {
        try fault.evictAll();
        fault.ioErrorOn();
        const resp = try fx.execute(ga, s, q);
        _ = fault.off();
        const left = try rows(ga, s, "MATCH (n:U6612) WHERE n.p = 1 RETURN n");
        switch (resp.payload orelse return error.MissingPayload) {
            .@"error" => |e| {
                std.debug.print("SONNY-6612 (4) {s}: {s} {s}\n", .{ q, e.code, e.message });
                if (std.mem.indexOf(u8, e.message, "NodeNotFound") != null or
                    std.mem.indexOf(u8, e.message, "EdgeNotFound") != null or left != 1) wrong += 1;
            },
            else => {
                std.debug.print("SONNY-6612 (4) {s}: succeeded with every body unreadable\n", .{q});
                wrong += 1;
            },
        }
    }
    try testing.expectEqual(@as(usize, 0), wrong);
}
