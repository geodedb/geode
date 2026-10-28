//! Resource-bound join regressions run in a fresh executable, apart from
//! the long persisted-write suite. This avoids inheriting that suite's
//! allocator history and lifetime resident peak. All query, time, memory
//! and cancellation assertions remain unchanged.
//!

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const h = @import("sonny738_write_harness.zig");
const process = @import("sonny_write_process_harness.zig");
const runProgram = process.runProgram;
const openSession = process.openSession;
const monoMillis = process.monoMillis;
const resetPeakRss = process.resetPeakRss;
const statusBytes = process.statusBytes;
const ChildMemoryGuard = process.ChildMemoryGuard;
const stmt_alloc = std.heap.page_allocator;

test "child memory guard measures real memory and rejects an oversized allocation" {
    const resident = statusBytes("VmRSS");
    try testing.expect(resident > 0);
    try testing.expect(statusBytes("VmHWM") >= resident);
    const pid = std.c.fork();
    try testing.expect(pid >= 0);
    if (pid == 0) {
        var memory: ChildMemoryGuard = .{};
        // A setup error has its own exit code; it must not satisfy the
        // expected memory-limit refusal below.
        memory.start(32 << 20) catch std.c._exit(8);
        _ = std.c.alarm(10);
        const size = 128 << 20;
        const raw = std.c.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        if (raw == std.c.MAP_FAILED) std.c._exit(9);
        const bytes: [*]volatile u8 = @ptrCast(raw);
        // Fault in every page: a virtual reservation alone is not RSS.
        var offset: usize = 0;
        while (offset < size) : (offset += std.heap.page_size_min) bytes[offset] = 1;
        memory.stop();
        std.c._exit(0);
    }
    var status: c_int = 0;
    try testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
    const st: u32 = @bitCast(status);
    try testing.expect(!std.os.linux.W.IFSIGNALED(st));
    try testing.expectEqual(@as(u32, 9), std.os.linux.W.EXITSTATUS(st));
}

/// Round 4b-1c: the join's memory is flat in the product, and every step
/// polls the budget and the cancel.
const BoundJob = struct {
    s: *h.Session,
    ok: bool = true,

    fn fail(self: *BoundJob, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("  " ++ fmt ++ "\n", args);
        self.ok = false;
    }

    /// I-B: a WHERE that keeps no binding of the 2.25 million the join
    /// tries holds no memory for them.
    fn flat(self: *BoundJob) void {
        geode.read_budget.setBudgetBytesForTest(64 << 20);
        defer geode.read_budget.setBudgetBytesForTest(0);
        resetPeakRss();
        const before = statusBytes("VmRSS");
        if (before == 0) return self.fail("resident memory measurement unavailable", .{});
        const start = monoMillis();
        var r = runProgram(self.s, stmt_alloc, "MATCH (a:P)-[:E]->(b), (c:P)-[:E]->(d) WHERE 1 = 2 RETURN a.i") catch |err| {
            return self.fail("WHERE 1 = 2: error {s}", .{@errorName(err)});
        };
        defer r.deinit(stmt_alloc);
        const took = monoMillis() - start;
        const peak = statusBytes("VmHWM");
        if (peak < before) return self.fail("peak memory measurement unavailable", .{});
        const grew = peak - before;
        if (r.rows.len != 0) self.fail("WHERE 1 = 2: {d} row(s)", .{r.rows.len});
        // 1,500 pairs: about 700 MB before the fix.
        if (grew > 128 << 20) self.fail("WHERE 1 = 2: the peak grew {d} MiB (at most 128)", .{grew >> 20});
        if (took > 240_000) self.fail("WHERE 1 = 2: took {d} ms", .{took});
    }

    /// I-C: a join whose last chain matches nothing ends at once; one whose
    /// last hop never matches is stopped by the stream's cancel.
    fn polled(self: *BoundJob) void {
        var start = monoMillis();
        var r = runProgram(self.s, stmt_alloc, "MATCH (a:P)-[:E]->(b), (c:P), (d:P), (e:P {i: -1}) RETURN count(*) AS n") catch |err| {
            return self.fail("empty last chain: error {s}", .{@errorName(err)});
        };
        const rows = h.renderRows(self.s.arena.allocator(), r) catch &.{};
        r.deinit(stmt_alloc);
        if (rows.len != 1 or !std.mem.eql(u8, rows[0], "0")) self.fail("empty last chain: {d} row(s)", .{rows.len});
        if (monoMillis() - start > 1_000) self.fail("empty last chain: took {d} ms", .{monoMillis() - start});

        var cancel = std.atomic.Value(bool).init(false);
        geode.read_budget.setStreamCancelSource(&cancel);
        defer geode.read_budget.setStreamCancelSource(null);
        const Setter = struct {
            fn run(flag: *std.atomic.Value(bool)) void {
                std.Io.Threaded.global_single_threaded.io().sleep(.fromMilliseconds(200), .awake) catch {};
                flag.store(true, .release);
            }
        };
        const t = std.Thread.spawn(.{}, Setter.run, .{&cancel}) catch return self.fail("spawn failed", .{});
        start = monoMillis();
        if (runProgram(self.s, stmt_alloc, "MATCH (a:P)-[:E]->(b), (c:P), (d:P)-[:NOPE]->(z) RETURN a.i")) |got| {
            var res = got;
            res.deinit(stmt_alloc);
            self.fail("a join no binding completes: ran to the end, not cancelled", .{});
        } else |err| if (err != error.ReadQueryCancelled) self.fail("a join no binding completes: error {s}", .{@errorName(err)});
        t.join();
        // The cancel lands at 200 ms; the join stops at its next step.
        if (monoMillis() - start > 1_200) self.fail("a join no binding completes: stopped after {d} ms", .{monoMillis() - start});
    }
};

fn runBoundInChild(job: *BoundJob, comptime which: fn (*BoundJob) void) !void {
    const pid = std.c.fork();
    try testing.expect(pid >= 0);
    if (pid == 0) {
        std.posix.setrlimit(.CORE, .{ .cur = 0, .max = 0 }) catch {};
        var memory: ChildMemoryGuard = .{};
        memory.start(1 << 30) catch std.c._exit(9);
        // A regression that stops polling is killed, not waited for.
        _ = std.c.alarm(300);
        which(job);
        memory.stop();
        std.c._exit(if (job.ok) 0 else 1);
    }
    var status: c_int = 0;
    try testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
    const st: u32 = @bitCast(status);
    if (std.os.linux.W.IFSIGNALED(st)) {
        std.debug.print("the join was killed (signal {d})\n", .{std.os.linux.W.TERMSIG(st)});
        return error.Crashed;
    }
    try testing.expectEqual(@as(u32, 0), std.os.linux.W.EXITSTATUS(st));
}

test "SONNY-3368 (round 4b-1b I-B): a WHERE that keeps nothing over 2.25 million bindings holds flat memory" {
    var s = try openSession(.in_memory);
    defer s.deinit();
    var setup = try runProgram(&s, stmt_alloc, "FOR i IN range(1, 1500) CREATE (:P {i: i})-[:E]->(:P2 {i: i})");
    setup.deinit(stmt_alloc);
    var job: BoundJob = .{ .s = &s };
    try runBoundInChild(&job, BoundJob.flat);
}

test "SONNY-3368 (round 4b-1b I-C): a join polls at every step: an empty last chain ends at once, a cancel stops one that completes nothing" {
    var s = try openSession(.in_memory);
    defer s.deinit();
    var setup = try runProgram(&s, stmt_alloc, "FOR i IN range(1, 400) CREATE (:P {i: i})-[:E]->(:P2 {i: i})");
    setup.deinit(stmt_alloc);
    var job: BoundJob = .{ .s = &s };
    try runBoundInChild(&job, BoundJob.polled);
}
