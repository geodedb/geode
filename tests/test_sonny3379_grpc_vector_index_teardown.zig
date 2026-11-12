// SONNY-3379: the in-process gRPC fixture crashed on cleanup after a vector
// index was created through it.
//
// The executor creates the process-wide index manager on the first CREATE
// INDEX, from the allocator that statement runs on. The in-process gRPC
// fixtures hand the handlers their request arena, so the manager lived in
// that arena; the fixture freed the arena and only then tore down the
// catalog, whose cleanup calls into the manager (`clearVectorDimRegistry`):
// a read of freed memory, and a dangling `getGlobalIndexManager()` for every
// later fixture in the binary. The I-4 vector case (W round 4b-1b,
// SONNY-3319) therefore ran over QUIC only.
//
// Here the I-4 case runs over the real gRPC handlers through the shared
// round-12 fixture, twice (two fixture lifetimes in one process), and the
// fixture leaves no index manager behind.
//
// CANARY: REQ=REQ-SONNY-3379-GRPC-VECTOR-TEARDOWN; FEATURE="Test Fixtures"; ASPECT=GrpcFixtureIndexManagerTeardown; STATUS=TESTED; TEST=tests/test_sonny3379_grpc_vector_index_teardown.zig; OWNER=index; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const index_manager = geode.index_manager;

/// The I-4 case (SONNY-3319): a label SET checks the vectors the node holds.
fn runI4(f: *fx.Fixture, name: []const u8) !void {
    const ga = f.ga();
    const s = try f.session(name);
    try fx.expectRuns(ga, s, "USE GRAPH g1");
    try fx.expectRuns(ga, s, "CREATE INDEX vk4b_idx ON VK4b (emb) USING HNSW WITH (metric = 'l2')");
    try fx.expectRuns(ga, s, "CREATE (:VK4b {id: 1, emb: vectorf32('[1.0, 0.0, 0.0, 0.0]')})");
    try fx.expectRuns(ga, s, "CREATE (:VO4b {id: 5, emb: vectorf32('[8.0, 8.0]')})");
    _ = try fx.expectRefused(ga, s, "MATCH (n:VO4b) SET n:VK4b", "22000");
    _ = try fx.expectRefused(ga, s, "CREATE (n:VP4b {id: 3, emb: vectorf32('[9.0, 9.0]')}) SET n:VK4b", "22000");
    try testing.expectEqual(@as(usize, 1), fx.countLabel(f.st, "g1", "VK4b"));
    try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "g1", "VP4b"));
}

test "SONNY-3379: the I-4 vector case runs over in-process gRPC and the fixture tears down cleanly" {
    var f: fx.Fixture = undefined;
    try f.init();
    try runI4(&f, "i4-first");
    // The CREATE INDEX made the process-wide index manager.
    try testing.expect(index_manager.getGlobalIndexManager() != null);
    f.deinit();
    // The fixture released it: nothing dangles into freed request memory.
    try testing.expect(index_manager.getGlobalIndexManager() == null);
}

test "SONNY-3379: a second fixture lifetime in the same process runs the I-4 case again" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    try runI4(&f, "i4-second");
}
