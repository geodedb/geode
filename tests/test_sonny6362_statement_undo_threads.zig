// SONNY-6362 item 1 regression: the statement undo record is the
// statement's, not the thread's.
//
// The report (src/statement_undo.zig:34, "The record is per thread"): a
// write another thread made for a statement was not in the statement's undo
// record, so a statement that failed did not undo it, and the checks run
// when the statement ends (UNIQUE, NOT NULL / EXISTS / NODE KEY,
// `unique_constraints.checkStatementWrites`, which read the record) never
// saw it.
//
// A thread working for a statement now joins its record
// (`statement_undo.current` on the statement's thread, `attach` / `detach`
// on the worker), and every append takes the record's mutex. The parallel
// UNION arms (`set_operations.tryParallelUnion`), the executor's one path
// that runs a statement's work on threads of its own, join it.
//
// Driven through the real graph-store write methods and the executor's
// statement scope (`execution.beginStatementScope` / `endStatementFailed` /
// `endStatementSucceeded`) on the in-process persisted store; data and
// constraints through the real gRPC handlers.
//
// CANARY: REQ=REQ-SONNY-6362-STATEMENT-RECORD; FEATURE="Execution"; ASPECT=CrossThreadRecordRegression; STATUS=TESTED; TEST=tests/test_sonny6362_statement_undo_threads.zig; OWNER=execution; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const sa = @import("statement_atomicity_fixture.zig");
const fx = sa.fx;

const execution = geode.execution;
const statement_undo = geode.statement_undo;
const graph_store = geode.graph_store;

const rowsOf = sa.rowsOf;
const runs = sa.runs;

/// Writes for the statement whose record it joins, on a thread of its own.
const Worker = struct {
    record: *statement_undo.Record,
    st: *graph_store.GraphStore,
    label: []const u8,
    nodes: usize = 0,
    /// Property `key` = `value` on each node it creates (none when null).
    key: ?[]const u8 = null,
    value: i64 = 0,
    /// An existing node it sets `x` = 1 on.
    set_node: ?u64 = null,
    err: ?anyerror = null,

    fn run(self: *Worker) void {
        statement_undo.attach(self.record);
        defer statement_undo.detach();
        self.work() catch |e| {
            self.err = e;
        };
    }

    fn work(self: *Worker) !void {
        const labels = [_][]const u8{self.label};
        for (0..self.nodes) |_| {
            const id = try self.st.createNodeWithGraph(&labels, "default");
            if (self.key) |k| try self.st.setNodeProperty(id, k, .{ .Int = self.value });
        }
        if (self.set_node) |id| try self.st.setNodeProperty(id, "x", .{ .Int = 1 });
    }

    fn runOnThread(self: *Worker) !void {
        const t = try std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 }, run, .{self});
        t.join();
        if (self.err) |e| return e;
    }
};

fn soleNode(st: *graph_store.GraphStore, label: []const u8) !u64 {
    const ids = st.getNodesByLabel("default", label) orelse return error.NodeNotFound;
    if (ids.len != 1) return error.NodeNotFound;
    return ids[0];
}

test "SONNY-6362: a failed statement undoes the writes another thread made for it" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s6362a");
    try runs(ga, s, "CREATE (:P6362 {name: 'p'})");
    const p = try soleNode(f.st, "P6362");

    const owner_labels = [_][]const u8{"A6362"};
    execution.beginStatementScope(true);
    const record = statement_undo.current() orelse return error.NoStatementRecord;
    _ = try f.st.createNodeWithGraph(&owner_labels, "default");
    var w: Worker = .{ .record = record, .st = f.st, .label = "W6362", .nodes = 3, .key = "k", .value = 7, .set_node = p };
    try w.runOnThread();
    // The owner's create, and the worker's three creates, three SETs and the
    // SET on P.
    try testing.expectEqual(@as(usize, 8), statement_undo.pendingCount());
    try testing.expectError(error.Injected6362, execution.endStatementFailed(true, error.Injected6362));

    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (n:A6362) RETURN n"));
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (n:W6362) RETURN n"));
    try testing.expectEqual(@as(usize, 1), try rowsOf(ga, s, "MATCH (n:P6362) WHERE n.x IS NULL RETURN n"));
}

test "SONNY-6362: the UNIQUE and NOT NULL checks at the end of a statement see the writes another thread made for it" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s6362c");
    try runs(ga, s, "CREATE CONSTRAINT c6362u FOR (n:U6362) REQUIRE n.k IS UNIQUE");
    try runs(ga, s, "CREATE CONSTRAINT c6362n FOR (n:N6362) REQUIRE n.v IS NOT NULL");
    try runs(ga, s, "CREATE (:U6362 {k: 1})");
    const catalog = try execution.ensureCatalogInstance(testing.allocator);

    // A second holder of k = 1, written by the worker.
    execution.beginStatementScope(true);
    var wu: Worker = .{ .record = statement_undo.current() orelse return error.NoStatementRecord, .st = f.st, .label = "U6362", .nodes = 1, .key = "k", .value = 1 };
    try wu.runOnThread();
    try testing.expectError(error.UniqueConstraintViolation, execution.endStatementSucceeded(true, catalog));
    try testing.expectEqual(@as(usize, 1), try rowsOf(ga, s, "MATCH (n:U6362) RETURN n"));

    // A node of N6362 without v, written by the worker.
    execution.beginStatementScope(true);
    var wn: Worker = .{ .record = statement_undo.current() orelse return error.NoStatementRecord, .st = f.st, .label = "N6362", .nodes = 1 };
    try wn.runOnThread();
    try testing.expectError(error.NotNullConstraintViolation, execution.endStatementSucceeded(true, catalog));
    try testing.expectEqual(@as(usize, 0), try rowsOf(ga, s, "MATCH (n:N6362) RETURN n"));

    // A worker's write that breaks nothing is kept.
    execution.beginStatementScope(true);
    var wk: Worker = .{ .record = statement_undo.current() orelse return error.NoStatementRecord, .st = f.st, .label = "U6362", .nodes = 1, .key = "k", .value = 2 };
    try wk.runOnThread();
    try execution.endStatementSucceeded(true, catalog);
    try testing.expectEqual(@as(usize, 2), try rowsOf(ga, s, "MATCH (n:U6362) RETURN n"));
}

/// Records `n` creates of ids no node has (their undo is a no-op) into
/// `record`, concurrently with its siblings.
const Appender = struct {
    record: *statement_undo.Record,
    st: *graph_store.GraphStore,
    base: u64,
    n: usize,
    err: ?anyerror = null,

    fn run(self: *Appender) void {
        statement_undo.attach(self.record);
        defer statement_undo.detach();
        for (0..self.n) |i| {
            statement_undo.reserve(1) catch |e| {
                self.err = e;
                return;
            };
            statement_undo.appendCreated(self.st, .{ .CreateNode = .{ .node_id = self.base + i, .graph_name = "" } });
        }
    }
};

test "SONNY-6362: threads appending to one statement's record concurrently lose no entry" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();

    execution.beginStatementScope(true);
    const record = statement_undo.current() orelse return error.NoStatementRecord;
    const per_thread = 2000;
    var appenders: [4]Appender = undefined;
    var threads: [4]std.Thread = undefined;
    for (&appenders, &threads, 0..) |*a, *t, i| {
        // Ids far above any the store hands out: the undo finds no node.
        a.* = .{ .record = record, .st = f.st, .base = (@as(u64, 1) << 50) + i * per_thread, .n = per_thread };
        t.* = try std.Thread.spawn(.{}, Appender.run, .{a});
    }
    for (&threads) |*t| t.join();
    for (appenders) |a| if (a.err) |e| return e;
    try testing.expectEqual(@as(usize, 4 * per_thread), statement_undo.pendingCount());
    try testing.expectError(error.Injected6362, execution.endStatementFailed(true, error.Injected6362));
    try testing.expectEqual(@as(usize, 0), statement_undo.pendingCount());
}

test "SONNY-6362: a parallel UNION's arms run inside the statement's record" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s6362u");
    try runs(ga, s, "CREATE (:C6362 {v: 0})");
    try runs(ga, s, "CREATE (:C6362 {v: 1})");

    const parallel0 = execution.parallelUnionInvocations();
    const attached0 = statement_undo.attached_threads_total.load(.monotonic);
    try testing.expectEqual(@as(usize, 4), try rowsOf(ga, s, "MATCH (n:C6362) WHERE n.v >= 0 RETURN n.v AS v UNION ALL MATCH (m:C6362) WHERE m.v >= 0 RETURN m.v AS v"));
    try testing.expect(execution.parallelUnionInvocations() > parallel0);
    try testing.expect(statement_undo.attached_threads_total.load(.monotonic) > attached0);
}
