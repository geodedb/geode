// SONNY-3315 regression (round 16, I3; pre-existing): a parallel UNION's
// result no longer frees through an allocator in a dead stack frame.
//
// `set_operations.tryParallelUnion` gave its arms a `LockedAllocator` that
// lives in its own frame. A result keeps the allocator it was built with
// where it frees through it later (its node/edge tracker,
// `OwnedGraphEntities`, and its variable bindings), so
// `ExecutionResult.deinit`, after `tryParallelUnion` returned, locked a mutex
// and read a parent allocator from a frame the stack had reused since. The
// review's repro, `MATCH (n:C) WHERE n.v >= 0 RETURN [[...60 levels...n.v...]]
// AS v UNION ALL MATCH (m:C) WHERE m.v >= 0 RETURN m.v AS v`, hung a Debug
// server thread in `LockedAllocator.freeFn`; any read could hang a request
// thread or corrupt its stack. The arms' results now free through the parent
// allocator (`reownArmResult`).
//
// Here: the review's shape (and 8 to 100 levels) through the real gRPC
// handler on an 8 MiB thread, with a watchdog for the hang; and parallel
// UNIONs of nodes and scalars through the executor, over the testing (debug)
// allocator, with the stack scribbled between the query and the free of its
// result, as a deep request would. Run it in Debug and ReleaseSafe.
//
// CANARY: REQ=REQ-SONNY-3315-UNION-ARM-ALLOCATOR; FEATURE="ParallelUnionArms"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3315_parallel_union_allocator.zig; OWNER=execution; UPDATED=2026-09-28

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");

const execution = geode.execution;

const MiB = 1024 * 1024;

fn seed(ga: std.mem.Allocator, s: []const u8) !void {
    try fx.expectRuns(ga, s, "CREATE (:C {v: 0})");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 1})");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 2})");
}

fn nestedList(a: std.mem.Allocator, depth: usize) ![]u8 {
    var q: std.ArrayList(u8) = .empty;
    try q.appendSlice(a, "MATCH (n:C) WHERE n.v >= 0 RETURN ");
    for (0..depth) |_| try q.append(a, '[');
    try q.appendSlice(a, "n.v");
    for (0..depth) |_| try q.append(a, ']');
    try q.appendSlice(a, " AS v UNION ALL MATCH (m:C) WHERE m.v >= 0 RETURN m.v AS v");
    return q.toOwnedSlice(a);
}

const Run = struct {
    ga: std.mem.Allocator,
    session: []const u8,
    query: []const u8,
    rows: usize = 0,
    code: ?[]const u8 = null,
    err: ?anyerror = null,
    client_decode_limit: bool = false,
    done: std.atomic.Value(bool) = .init(false),

    fn go(self: *Run) void {
        defer self.done.store(true, .release);
        self.run() catch |e| {
            self.err = e;
        };
    }

    fn run(self: *Run) !void {
        const resp = try fx.execute(self.ga, self.session, self.query);
        switch (resp.payload orelse return error.MissingPayload) {
            .@"error" => |e| {
                self.code = e.code;
                return;
            },
            .schema => {},
            else => return,
        }
        const req = try fx.encodeProto(self.ga, schema.PullRequest{ .session_id = self.session, .page_size = 64 });
        const pull_bytes = try grpc.handlePull(req, self.ga);
        // The server answered. This test client's protobuf decoder takes
        // less nesting than a 60-level list: count that as an answer too.
        const pull = fx.decodeProto(schema.PullResponse, self.ga, pull_bytes) catch |err| {
            if (err != error.InvalidInput) return err;
            self.client_decode_limit = true;
            return;
        };
        const presp = pull.response orelse return error.MissingPayload;
        switch (presp.payload orelse return error.MissingPayload) {
            .page => |p| self.rows = p.rows.items.len,
            .@"error" => |e| self.code = e.code,
            else => return error.UnexpectedPayload,
        }
    }
};

/// Run `query` over gRPC on a thread of `stack` bytes; a hang (the review's
/// symptom) fails the whole test binary loudly after 30 s.
fn runOn(stack: usize, ga: std.mem.Allocator, session: []const u8, query: []const u8) !Run {
    var r: Run = .{ .ga = ga, .session = session, .query = query };
    const t = try std.Thread.spawn(.{ .stack_size = stack }, Run.go, .{&r});
    var waited: u64 = 0;
    while (!r.done.load(.acquire)) : (waited += 20) {
        if (waited > 30_000) {
            std.debug.print("SONNY-3315: no answer in 30 s (the dead-frame allocator hang): {s}\n", .{query[0..@min(query.len, 120)]});
            std.process.exit(3);
        }
        fx.sleepMs(20);
    }
    t.join();
    if (r.err) |e| {
        std.debug.print("SONNY-3315: {s}: {s}\n", .{ query[0..@min(query.len, 60)], @errorName(e) });
        return e;
    }
    return r;
}

test "SONNY-3315: over gRPC the review's parallel UNION ALL of a nested list answers, no hang (8 to 100 levels, 8 MiB thread)" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3315");
    try seed(ga, s);
    for ([_]usize{ 8, 32, 60, 100 }) |depth| {
        const q = try nestedList(ga, depth);
        const before = execution.parallelUnionInvocations();
        const r = try runOn(8 * MiB, ga, s, q);
        const after = execution.parallelUnionInvocations();
        std.debug.print("SONNY-3315 nested list depth {d}: {s} rows={d} parallel={} client_decode_limit={}\n", .{ depth, r.code orelse "ran", r.rows, after > before, r.client_decode_limit });
        // A refusal for depth (54001, or the parser's 42000 past its nesting
        // limit) is an answer; a hang or a crash is not.
        if (r.code) |code| {
            try testing.expect(std.mem.eql(u8, code, "54001") or std.mem.eql(u8, code, "42000"));
        } else if (!r.client_decode_limit) {
            try testing.expectEqual(@as(usize, 6), r.rows);
        }
    }
    // The server thread serves on.
    const again = try runOn(8 * MiB, ga, s, "MATCH (n:C) WHERE n.v >= 0 RETURN n.v AS v UNION ALL MATCH (m:C) WHERE m.v >= 0 RETURN m.v AS v");
    try testing.expectEqual(@as(usize, 6), again.rows);
}

/// Overwrite `n` KiB of the stack below the caller with a pattern, as a deep
/// request would: a frame that returned is garbage from here on.
noinline fn scribbleStack(n: usize) void {
    var buf: [1024]u8 = undefined;
    @memset(&buf, 0xAA);
    std.mem.doNotOptimizeAway(&buf);
    if (n > 1) scribbleStack(n - 1);
    std.mem.doNotOptimizeAway(&buf);
}

test "SONNY-3315: parallel UNIONs of nodes and scalars free their results through the caller's allocator, under the debug allocator" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3315b");
    try seed(ga, s);
    const catalog = try execution.ensureCatalogInstance(testing.allocator);
    const ctx = execution.ExecutionContext{ .catalog = catalog };

    const queries = [_]struct { q: []const u8, rows: usize }{
        .{ .q = "MATCH (n:C) WHERE n.v >= 0 RETURN n.v AS v UNION MATCH (m:C) WHERE m.v >= 0 RETURN m.v AS v", .rows = 3 },
        .{ .q = "MATCH (n:C) WHERE n.v >= 0 RETURN n AS v UNION ALL MATCH (m:C) WHERE m.v >= 0 RETURN m AS v", .rows = 6 },
        .{ .q = "MATCH (n:C) WHERE n.v >= 0 RETURN n.v AS v UNION ALL MATCH (m:C) WHERE m.v >= 0 RETURN m.v AS v UNION ALL MATCH (k:C) WHERE k.v > 0 RETURN k.v AS v", .rows = 8 },
        .{ .q = "MATCH (n:C) WHERE n.v >= 0 RETURN [[[n.v]]] AS v UNION ALL MATCH (m:C) WHERE m.v >= 0 RETURN m.v AS v", .rows = 6 },
    };
    for (queries) |entry| {
        for (0..5) |_| {
            // A query's allocator, as the handlers give one (a planned read's
            // nodes keep their interior in it), over the debug allocator.
            var query_arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer query_arena.deinit();
            const qa = query_arena.allocator();
            var parsed = try geode.parseGql(entry.q, qa);
            defer parsed.deinit();
            const before = execution.parallelUnionInvocations();
            var res = try execution.executeStatementWithContext(qa, parsed.program.statements[0], ctx);
            const parallel = execution.parallelUnionInvocations() > before;
            // The frame `tryParallelUnion` ran in is reused before the free.
            scribbleStack(64);
            try testing.expectEqual(entry.rows, res.rows.len);
            res.deinit(qa);
            try testing.expect(parallel);
        }
    }
}
