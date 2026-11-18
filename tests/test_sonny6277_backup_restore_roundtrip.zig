// CANARY: REQ=REQ-BACKUP-REAL-DATA-001; FEATURE="BackupRealData"; ASPECT=ColdRestoreRoundTrip; STATUS=TESTED; TEST=tests/test_sonny6277_backup_restore_roundtrip.zig; OWNER=backup; UPDATED=2026-11-11
//
// SONNY-6277: a backup restored into a fresh data directory must hold every
// node, edge and typed property of the source, in the default graph and in a
// named graph, read cold through the executor (MATCH ... RETURN count(...))
// and through the store's full-node enumeration, and again after the restored
// store is closed and reopened. Runs with and without gzip.
//
// Drives the real executor, the real engine-backed storage and the real backup
// engine (src/storage/backup.zig BackupManager); no mocks.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const backup = @import("storage/backup");
const test_scratch = @import("test_scratch.zig");

const graph_store = geode.graph_store;
const execution = geode.execution;

const named_graph = "sonny6277";

const Session = struct {
    arena: std.heap.ArenaAllocator,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    fn open(allocator: std.mem.Allocator, data_dir: []const u8) !Session {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        _ = try graph_store.initGlobalStore(allocator, data_dir);
        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .session = execution.SessionState.init(allocator),
            .ctx = .{ .catalog = catalog },
        };
    }

    fn close(self: *Session, allocator: std.mem.Allocator) void {
        self.session.deinit();
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }

    fn exec(self: *Session, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn run(self: *Session, query: []const u8) !void {
        var r = try self.exec(query);
        r.deinit(self.arena.allocator());
    }

    fn count(self: *Session, query: []const u8) !i64 {
        var r = try self.exec(query);
        defer r.deinit(self.arena.allocator());
        try testing.expectEqual(@as(usize, 1), r.rows.len);
        return switch (r.rows[0][0]) {
            .Int => |c| c,
            else => error.UnexpectedValueTag,
        };
    }
};

/// Default graph: 3 :Person, 2 :City, 3 edges. Named graph: 2 :Item, 1 edge.
fn seed(s: *Session) !void {
    try s.run("INSERT (:Person {name: 'Alice', age: 30, score: 1.5, active: true})");
    try s.run("INSERT (:Person {name: 'Bob', age: 25, score: 2.25, active: false})");
    try s.run("INSERT (:Person {name: 'Carol', age: 41, score: 3.0, active: true})");
    try s.run("INSERT (:City {name: 'Oslo'})");
    try s.run("INSERT (:City {name: 'Lima'})");
    try s.run("MATCH (a:Person {name: 'Alice'}), (c:City {name: 'Oslo'}) CREATE (a)-[:LIVES_IN {since: 2019}]->(c)");
    try s.run("MATCH (a:Person {name: 'Bob'}), (c:City {name: 'Lima'}) CREATE (a)-[:LIVES_IN {since: 2021}]->(c)");
    try s.run("MATCH (a:Person {name: 'Alice'}), (b:Person {name: 'Carol'}) CREATE (a)-[:KNOWS {weight: 0.75}]->(b)");

    try s.run("CREATE GRAPH " ++ named_graph);
    try s.run("USE GRAPH " ++ named_graph);
    try s.run("INSERT (:Item {sku: 'A-1', qty: 7})");
    try s.run("INSERT (:Item {sku: 'B-2', qty: 9})");
    try s.run("MATCH (a:Item {sku: 'A-1'}), (b:Item {sku: 'B-2'}) CREATE (a)-[:PAIRS {rank: 1}]->(b)");
}

const Phase = enum { source, restored_cold, restored_reopened };

/// Counts and typed properties, read through the executor and the store.
fn expectGraphData(allocator: std.mem.Allocator, s: *Session, phase: Phase) !void {
    errdefer std.debug.print("SONNY-6277: data check failed at phase {t}\n", .{phase});

    try s.run("USE GRAPH " ++ named_graph);
    try testing.expectEqual(@as(i64, 2), try s.count("MATCH (n) RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 1), try s.count("MATCH ()-[e]->() RETURN count(e) AS c"));
    try testing.expectEqual(@as(i64, 1), try s.count("MATCH (:Item {sku: 'A-1'})-[e:PAIRS {rank: 1}]->(:Item {qty: 9}) RETURN count(e) AS c"));

    // Back to the default graph.
    s.session.deinit();
    s.session = execution.SessionState.init(allocator);
    try testing.expectEqual(@as(i64, 5), try s.count("MATCH (n) RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 3), try s.count("MATCH (n:Person) RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 3), try s.count("MATCH ()-[e]->() RETURN count(e) AS c"));
    try testing.expectEqual(@as(i64, 1), try s.count("MATCH (:Person {name: 'Alice'})-[e:KNOWS]->(:Person {name: 'Carol'}) RETURN count(e) AS c"));
    try testing.expectEqual(@as(i64, 1), try s.count("MATCH (:Person {name: 'Bob'})-[e:LIVES_IN {since: 2021}]->(:City {name: 'Lima'}) RETURN count(e) AS c"));

    // Typed property values compare equal through the engine (Int, Float,
    // Bool, String), and a value comes back with its type.
    try testing.expectEqual(@as(i64, 1), try s.count("MATCH (n:Person) WHERE n.age = 30 AND n.score = 1.5 AND n.active = true AND n.name = 'Alice' RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 1), try s.count("MATCH (n:Person) WHERE n.age = 25 AND n.score = 2.25 AND n.active = false RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 1), try s.count("MATCH ()-[e:KNOWS]->() WHERE e.weight = 0.75 RETURN count(e) AS c"));
    {
        var r = try s.exec("MATCH (n:Person {name: 'Carol'}) RETURN n.age AS age, n.active AS active, n.name AS name");
        defer r.deinit(s.arena.allocator());
        try testing.expectEqual(@as(usize, 1), r.rows.len);
        try testing.expectEqual(@as(i64, 41), r.rows[0][0].Int);
        try testing.expectEqual(true, r.rows[0][1].Bool);
        try testing.expectEqualStrings("Carol", r.rows[0][2].Str);
    }

    // The store's full enumeration (every graph) sees all seven nodes.
    const store = graph_store.getGlobalStore(allocator);
    const ids = try store.getAllNodes(allocator);
    defer allocator.free(ids);
    try testing.expectEqual(@as(usize, 7), ids.len);
}

fn roundTrip(compression: backup.CompressionType) !void {
    const allocator = testing.allocator;

    var data_dir = try test_scratch.ScratchDir.create("sonny6277-data");
    defer data_dir.remove();
    var backup_dir = try test_scratch.ScratchDir.create("sonny6277-backups");
    defer backup_dir.remove();
    var restore_dir = try test_scratch.ScratchDir.create("sonny6277-restore");
    defer restore_dir.remove();

    // Source: seed, check, back up while open (as the server does), restore
    // into a fresh directory.
    {
        var s = try Session.open(allocator, data_dir.path());
        defer s.close(allocator);
        try seed(&s);
        s.session.deinit();
        s.session = execution.SessionState.init(allocator);
        try expectGraphData(allocator, &s, .source);

        var mgr = try backup.BackupManager.init(allocator, backup_dir.path(), .{ .compression = compression }, graph_store.getGlobalStore(allocator));
        defer mgr.deinit();
        const meta = try mgr.createFullBackup();
        try testing.expectEqual(compression, meta.compression);
        var restored_side = try mgr.restoreInto(restore_dir.path(), meta.timestamp + 1, .{});
        restored_side.deinit();
    }

    // Restored, cold: a fresh store opened on the restored directory.
    {
        var s = try Session.open(allocator, restore_dir.path());
        defer s.close(allocator);
        try expectGraphData(allocator, &s, .restored_cold);
    }

    // Restored, reopened: closed and opened again, nothing touched in between.
    {
        var s = try Session.open(allocator, restore_dir.path());
        defer s.close(allocator);
        try expectGraphData(allocator, &s, .restored_reopened);
    }
}

test "SONNY-6277 backup restore round-trips nodes, edges and typed properties cold (uncompressed)" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try roundTrip(.none);
}

test "SONNY-6277 backup restore round-trips nodes, edges and typed properties cold (gzip)" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try roundTrip(.gzip);
}
