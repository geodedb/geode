// SONNY-3312 regression (round 16, C1): a read program whose statements run
// on several graphs reads each graph's data.
//
// Round 15 (60adb372, SONNY-3180) scoped the snapshot a read runs on to the
// one graph whose read lock it holds (`snapshotUnderReadLock(lock_graph)`).
// For a read program that spans graphs `programGraph` is null and
// `lock_graph` is the session graph, so every other graph in the snapshot was
// empty: from a session on g1, `MATCH (n:C) RETURN count(n) AS c; USE GRAPH
// g2; MATCH (n:C) RETURN count(n) AS c` answered 0 for g2's two :C nodes.
//
// The fix (`StatementPlan.reads_several_graphs`,
// `query_traits.programDataGraphList`, `graph_store.snapshotUnderReadLocks`)
// hydrates every graph the program reads, takes each one's read lock shared
// in name order, and snapshots all of them. Both handlers use it.
//
// Here: the review's repro and its mirror image over gRPC (in process) with
// unbounded and bounded (production) caches; three graphs; a missing graph
// answers as it does in a read of one graph; readers of several graphs in both
// orders race writers of each graph and CREATE/DROP GRAPH churn without a
// deadlock or a wrong count; and the repro over QUIC against a spawned server.
//
// CANARY: REQ=REQ-SONNY-3312-MULTI-GRAPH-READ; FEATURE="MultiGraphIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3312_multi_graph_read.zig; OWNER=storage; UPDATED=2026-09-28

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const util = @import("proto_test_util.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;
const query_traits = geode.query_traits;

const repro = "MATCH (n:C) RETURN count(n) AS c; USE GRAPH g2; MATCH (n:C) RETURN count(n) AS c";

/// The first column of the first row a gRPC read answers, or the SQLSTATE it
/// is refused with.
const Answer = union(enum) { int: i64, code: []const u8, other };

fn grpcAnswer(ga: std.mem.Allocator, session: []const u8, query: []const u8) !Answer {
    const resp = try fx.execute(ga, session, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| return .{ .code = e.code },
        .schema => {},
        else => return .other,
    }
    const req = try fx.encodeProto(ga, schema.PullRequest{ .session_id = session, .page_size = 64 });
    const pull = try fx.decodeProto(schema.PullResponse, ga, try grpc.handlePull(req, ga));
    const presp = pull.response orelse return error.MissingPayload;
    switch (presp.payload orelse return error.MissingPayload) {
        .page => |p| {
            if (p.rows.items.len == 0 or p.rows.items[0].values.items.len == 0) return .other;
            const k = p.rows.items[0].values.items[0].kind orelse return .other;
            return switch (k) {
                .int_val => |x| .{ .int = x.value },
                else => .other,
            };
        },
        .@"error" => |e| return .{ .code = e.code },
        else => return .other,
    }
}

fn expectCount(ga: std.mem.Allocator, session: []const u8, query: []const u8, want: i64) !void {
    const got = try grpcAnswer(ga, session, query);
    switch (got) {
        .int => |v| {
            if (v != want) std.debug.print("{s}: {d}, want {d}\n", .{ query, v, want });
            try testing.expectEqual(want, v);
        },
        .code => |c| {
            std.debug.print("{s}: refused {s}, want {d}\n", .{ query, c, want });
            return error.Refused;
        },
        .other => return error.UnexpectedAnswer,
    }
}

fn seedTwoGraphs(ga: std.mem.Allocator, s: []const u8) !void {
    try fx.expectRuns(ga, s, "USE GRAPH g2");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 1})");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 2})");
    try fx.expectRuns(ga, s, "USE GRAPH g1");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 10})");
}

fn reproOverGrpc(opts: fx.Fixture.Options) !void {
    var f: fx.Fixture = undefined;
    try f.initWith(opts);
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3312");
    try seedTwoGraphs(ga, s);

    // The review's repro: a session on g1 reads g2 (2 :C nodes).
    try expectCount(ga, s, repro, 2);
    // The session graph is g2 after it; a later read of g1 alone still works.
    try expectCount(ga, s, "MATCH (n:C) RETURN count(n) AS c", 2);
    try expectCount(ga, s, "USE GRAPH g1; MATCH (n:C) RETURN count(n) AS c", 1);
    // Mirror image: the session is on g1 again; read g2 first, then g1.
    try expectCount(ga, s, "USE GRAPH g2; MATCH (n:C) RETURN count(n) AS c; USE GRAPH g1; MATCH (n:C) RETURN count(n) AS c", 1);
    // Leaving the session graph for another one and back.
    try expectCount(ga, s, "USE GRAPH g2; MATCH (n:C) RETURN count(n) AS c; USE GRAPH g1; MATCH (n:C) RETURN count(n) AS c; USE GRAPH g2; MATCH (n:C) WHERE n.v >= 2 RETURN count(n) AS c", 1);
    // Property values read from the other graph, not only counts.
    try expectCount(ga, s, "USE GRAPH g1; MATCH (n:C) RETURN count(n) AS c; USE GRAPH g2; MATCH (n:C) RETURN sum(n.v) AS c", 3);
}

test "SONNY-3312: over gRPC a read of several graphs reads each (the review's repro), unbounded caches" {
    try reproOverGrpc(.{});
}

test "SONNY-3312: over gRPC a read of several graphs reads each (the review's repro), bounded caches" {
    try reproOverGrpc(.{ .bounded_caches = true });
}

test "SONNY-3312: three graphs, and a missing graph answers as in a read of one graph" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3312b");
    try seedTwoGraphs(ga, s);
    try fx.expectRuns(ga, s, "CREATE GRAPH g3");
    try fx.expectRuns(ga, s, "USE GRAPH g3");
    for (0..4) |_| try fx.expectRuns(ga, s, "CREATE (:C {v: 100})");
    try fx.expectRuns(ga, s, "USE GRAPH g1");
    try expectCount(ga, s, "MATCH (n:C) RETURN count(n) AS c; USE GRAPH g3; MATCH (n:C) RETURN count(n) AS c; USE GRAPH g2; MATCH (n:C) RETURN count(n) AS c", 2);
    try fx.expectRuns(ga, s, "USE GRAPH g1");
    try expectCount(ga, s, "USE GRAPH g2; MATCH (n:C) RETURN count(n) AS c; USE GRAPH g3; MATCH (n:C) RETURN count(n) AS c", 4);

    // A graph that does not exist: the same answer as a read of it alone.
    try fx.expectRuns(ga, s, "USE GRAPH g1");
    const alone = try grpcAnswer(ga, s, "USE GRAPH nope3312; MATCH (n:C) RETURN count(n) AS c");
    try fx.expectRuns(ga, s, "USE GRAPH g1");
    const several = try grpcAnswer(ga, s, "MATCH (n:C) RETURN count(n) AS c; USE GRAPH nope3312; MATCH (n:C) RETURN count(n) AS c");
    try testing.expect(alone == .code);
    try testing.expect(several == .code);
    try testing.expectEqualStrings(alone.code, several.code);

    // The list the handlers lock: sorted, no repeats.
    var parsed = try geode.parseGql("MATCH (n) RETURN n; USE GRAPH g3; MATCH (n) RETURN n; USE GRAPH g1; MATCH (n) RETURN n; USE GRAPH g2; MATCH (n) RETURN n", testing.allocator);
    defer parsed.deinit();
    const list = try query_traits.programDataGraphList(testing.allocator, &parsed.program, "g2", graph_store.DEFAULT_GRAPH_NAME);
    defer testing.allocator.free(list);
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqualStrings("g1", list[0]);
    try testing.expectEqualStrings("g2", list[1]);
    try testing.expectEqualStrings("g3", list[2]);
}

const Worker = struct {
    ga: std.mem.Allocator,
    session: []const u8,
    kind: enum { read_g1_first, read_g2_first, write_g1, write_g2, churn },
    stop: *std.atomic.Value(bool),
    iterations: usize = 0,
    wrong: usize = 0,
    failures: usize = 0,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *Worker) void {
        defer self.done.store(true, .release);
        while (!self.stop.load(.acquire)) {
            self.step() catch {
                self.failures += 1;
            };
            self.iterations += 1;
        }
    }

    fn step(self: *Worker) !void {
        switch (self.kind) {
            // g2 has 2 :C nodes and only ever gains :W nodes; g1 has 1.
            .read_g1_first => {
                try fx.expectRuns(self.ga, self.session, "USE GRAPH g1");
                switch (try grpcAnswer(self.ga, self.session, repro)) {
                    .int => |v| if (v != 2) {
                        self.wrong += 1;
                    },
                    else => self.wrong += 1,
                }
            },
            .read_g2_first => {
                try fx.expectRuns(self.ga, self.session, "USE GRAPH g2");
                switch (try grpcAnswer(self.ga, self.session, "MATCH (n:C) RETURN count(n) AS c; USE GRAPH g1; MATCH (n:C) RETURN count(n) AS c")) {
                    .int => |v| if (v != 1) {
                        self.wrong += 1;
                    },
                    else => self.wrong += 1,
                }
            },
            .write_g1 => try fx.expectRuns(self.ga, self.session, "USE GRAPH g1; CREATE (:W {v: 1})"),
            .write_g2 => try fx.expectRuns(self.ga, self.session, "USE GRAPH g2; CREATE (:W {v: 2})"),
            .churn => {
                _ = try fx.outcome(self.ga, self.session, "CREATE GRAPH g0");
                _ = try fx.outcome(self.ga, self.session, "USE GRAPH g0; CREATE (:C {v: 0})");
                // A read of g0 (dropped or not) and g2, in lock order g0, g2.
                _ = try grpcAnswer(self.ga, self.session, "USE GRAPH g0; MATCH (n:C) RETURN count(n) AS c; USE GRAPH g2; MATCH (n:C) RETURN count(n) AS c");
                _ = try fx.outcome(self.ga, self.session, "USE GRAPH default");
                _ = try fx.outcome(self.ga, self.session, "DROP GRAPH IF EXISTS g0");
            },
        }
    }
};

test "SONNY-3312: readers of several graphs in both orders race writers of each and CREATE/DROP GRAPH churn: right counts, no deadlock" {
    const kinds = [_]@FieldType(Worker, "kind"){ .read_g1_first, .read_g1_first, .read_g2_first, .read_g2_first, .write_g1, .write_g2, .churn };
    // Each worker thread has its own arena (the fixture's is not
    // thread-safe). The sessions keep their last result, built with it, until
    // the fixture goes: the arenas outlive the fixture.
    var arenas: [kinds.len]std.heap.ArenaAllocator = undefined;
    for (&arenas) |*a| a.* = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer for (&arenas) |*a| a.deinit();
    var f: fx.Fixture = undefined;
    try f.initWith(.{ .bounded_caches = true });
    defer f.deinit();
    const seed_s = try f.session("seed");
    try seedTwoGraphs(f.ga(), seed_s);

    var stop: std.atomic.Value(bool) = .init(false);
    var workers: [kinds.len]Worker = undefined;
    var threads: [kinds.len]std.Thread = undefined;
    for (kinds, 0..) |k, i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "w3312-{d}", .{i});
        workers[i] = .{ .ga = arenas[i].allocator(), .session = try f.session(name), .kind = k, .stop = &stop };
    }
    for (&workers, 0..) |*w, i| threads[i] = try std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 }, Worker.run, .{w});

    fx.sleepMs(2000);
    stop.store(true, .release);
    // A deadlock would leave a worker running: give them 30 s, then fail loudly.
    var waited: u64 = 0;
    for (&workers) |*w| {
        while (!w.done.load(.acquire)) : (waited += 10) {
            if (waited > 30_000) {
                std.debug.print("SONNY-3312: a worker ({s}) did not finish in 30 s: deadlock\n", .{@tagName(w.kind)});
                std.process.exit(3);
            }
            fx.sleepMs(10);
        }
    }
    for (threads) |t| t.join();

    var reads: usize = 0;
    for (workers) |w| {
        std.debug.print("SONNY-3312 {s}: {d} iterations, {d} wrong, {d} failed\n", .{ @tagName(w.kind), w.iterations, w.wrong, w.failures });
        try testing.expectEqual(@as(usize, 0), w.wrong);
        switch (w.kind) {
            .read_g1_first, .read_g2_first => {
                try testing.expectEqual(@as(usize, 0), w.failures);
                reads += w.iterations;
            },
            .write_g1, .write_g2 => try testing.expectEqual(@as(usize, 0), w.failures),
            .churn => {},
        }
    }
    try testing.expect(reads > 0);
}

// ---------------------------------------------------------------------------
// QUIC
// ---------------------------------------------------------------------------

fn quicRun(c: *util.QuicProtoClient, allocator: std.mem.Allocator, q: []const u8) !void {
    var r = try c.executeAndCollectWithTimeout(allocator, q, util.emptyParams(), 100, 30);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("{s}: {s} {s}\n", .{ q, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
}

fn quicCount(c: *util.QuicProtoClient, allocator: std.mem.Allocator, q: []const u8) !i64 {
    var r = try c.executeAndCollectWithTimeout(allocator, q, util.emptyParams(), 100, 30);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("{s}: {s} {s}\n", .{ q, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
    if (r.rows.len != 1 or r.rows[0].len != 1 or r.rows[0][0] != .int) return error.UnexpectedAnswer;
    return r.rows[0][0].int;
}

test "SONNY-3312: over QUIC a read of several graphs reads each (the review's repro; spawned server)" {
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny3312-{d}", .{port});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);
    var server = try util.spawnServer(
        allocator,
        &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir },
        util.TestEnv.standard(),
    );
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 30000);
    var c = try util.QuicProtoClient.connect(allocator, addr);
    defer c.deinit();
    var hello = try c.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    try quicRun(&c, allocator, "CREATE GRAPH g1");
    try quicRun(&c, allocator, "CREATE GRAPH g2");
    try quicRun(&c, allocator, "USE GRAPH g2");
    try quicRun(&c, allocator, "CREATE (:C {v: 1})");
    try quicRun(&c, allocator, "CREATE (:C {v: 2})");
    try quicRun(&c, allocator, "USE GRAPH g1");
    try quicRun(&c, allocator, "CREATE (:C {v: 10})");

    try testing.expectEqual(@as(i64, 2), try quicCount(&c, allocator, repro));
    try quicRun(&c, allocator, "USE GRAPH g1");
    try testing.expectEqual(@as(i64, 1), try quicCount(&c, allocator, "USE GRAPH g2; MATCH (n:C) RETURN count(n) AS c; USE GRAPH g1; MATCH (n:C) RETURN count(n) AS c"));
    try quicRun(&c, allocator, "USE GRAPH g1");
    try testing.expectEqual(@as(i64, 3), try quicCount(&c, allocator, "MATCH (n:C) RETURN count(n) AS c; USE GRAPH g2; MATCH (n:C) RETURN sum(n.v) AS c"));
}
