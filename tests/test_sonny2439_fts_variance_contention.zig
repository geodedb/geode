// SONNY-2439: the fts-storage VarianceEnvelope must hold on a contended host.
//
// test-performance-benchmarks failed on main about every other pipeline on
// fts_index_batch (cv 1.9-2.5 against a 2.0 maximum; CI samples 27-761 us per
// document) while the same benchmark run locally is flat at ~55 us/doc with
// cv 0.02-0.04. The spread came from the shared kvm runner (preempted vCPU,
// contended fsync), not from fts-storage: one stalled batch is enough to push
// a mean / standard-deviation envelope past its bound.
//
// This runs the real benchmark scenarios of benchmarks/benchmark_fts_storage.zig
// against the real fts_storage engine while the host is made noisy on
// purpose: the benchmark thread (at a lower priority) and a set of bursty CPU
// hogs share one CPU, and two writer threads dirty and fsync files in the same
// filesystem. Nothing is simulated: the product code runs under real
// interference, which is what the CI runner does to it. The envelope must
// still report VARIANCE_OK in every one of `contended_runs` runs.
//
// Under the old one-pass mean / CV envelope fts_search_term breaches in most
// runs; fts_index_batch breaches in some, depending on how loaded the host
// already is (as on CI, where it failed about every other pipeline).
//
// CANARY: REQ=REQ-SONNY-2439-FTS-VARIANCE-ROBUST; FEATURE="Perf Gates"; ASPECT=FtsVarianceEnvelopeUnderContention; STATUS=TESTED; TEST=tests/test_sonny2439_fts_variance_contention.zig; OWNER=performance; UPDATED=2026-11-22
const std = @import("std");
const builtin = @import("builtin");
const bench = @import("fts_bench");

const testing = std.testing;
const linux = std.os.linux;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn monoNs() u64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn sleepNs(n: u64) void {
    const req: linux.timespec = .{ .sec = @intCast(n / std.time.ns_per_s), .nsec = @intCast(n % std.time.ns_per_s) };
    _ = linux.nanosleep(&req, null);
}

const Noise = struct {
    stop: std.atomic.Value(bool) = .init(false),
    cpu: usize,

    fn pin(cpu: usize) void {
        var set: linux.cpu_set_t = @splat(0);
        set[cpu / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(cpu % @bitSizeOf(usize));
        linux.sched_setaffinity(0, &set) catch {};
    }

    /// Bursts of `burst` ms of spinning on the benchmark's CPU, `gap` ms apart
    /// (gap first, so a burst lands inside the timed region, not the setup).
    fn cpuHog(self: *Noise, seed: u64, burst: [2]u64, gap: [2]u64) void {
        pin(self.cpu);
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();
        var sink: u64 = 0;
        while (!self.stop.load(.acquire)) {
            sleepNs(r.intRangeAtMost(u64, gap[0], gap[1]) * std.time.ns_per_ms);
            const until = monoNs() + r.intRangeAtMost(u64, burst[0], burst[1]) * std.time.ns_per_ms;
            while (monoNs() < until and !self.stop.load(.monotonic)) sink +%= sink *% 6364136223846793005 +% 1;
        }
        std.mem.doNotOptimizeAway(sink);
    }

    /// Dirties 16 MiB of a file in the benchmark's filesystem, then fsyncs it
    /// 20-80 ms later. On ext4 (data=ordered) the benchmark's own WAL fsync
    /// then waits for the journal commit that writes those pages back.
    fn fsyncHog(self: *Noise, seed: u64) void {
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();
        var name_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrintZ(&name_buf, ".sonny2439-fsync-noise-{x}", .{seed}) catch return;
        const fd_rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
        if (@as(isize, @bitCast(fd_rc)) < 0) return;
        const fd: i32 = @intCast(fd_rc);
        defer {
            _ = linux.close(fd);
            _ = linux.unlinkat(linux.AT.FDCWD, path, 0);
        }
        var buf: [64 * 1024]u8 = undefined;
        r.bytes(&buf);
        while (!self.stop.load(.acquire)) {
            for (0..256) |i| _ = linux.pwrite(fd, &buf, buf.len, @intCast(i * buf.len));
            sleepNs(r.intRangeAtMost(u64, 20, 80) * std.time.ns_per_ms);
            _ = linux.fsync(fd);
        }
    }
};

fn firstAllowedCpu() ?usize {
    var set: linux.cpu_set_t = @splat(0);
    if (linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &set) != 0) return null;
    for (set, 0..) |word, w| {
        if (word != 0) return w * @bitSizeOf(usize) + @ctz(word);
    }
    return null;
}

/// The benchmark thread runs at this nice value, so while a hog bursts it
/// gets a few percent of the shared CPU: a noisy neighbour stealing the vCPU,
/// which is what the shared kvm runner does to it.
const bench_nice = 19;

fn ScenarioRun(comptime scenario: anytype) type {
    return struct {
        cpu: usize,
        allocator: std.mem.Allocator,
        out: std.ArrayListUnmanaged(u8) = .empty,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            Noise.pin(self.cpu);
            _ = linux.syscall3(.setpriority, 0, @as(usize, @intCast(linux.gettid())), bench_nice);
            _ = scenario(io(), self.allocator, &self.out) catch |e| {
                self.err = e;
            };
        }
    };
}

/// Run `scenario` on its own thread, on one CPU shared with bursty CPU hogs,
/// while two more threads fsync, and return its benchmark output.
/// A CPU hog's burst and gap ranges, in ms.
const Hog = struct { burst: [2]u64, gap: [2]u64 };

/// Long, sparse stalls: a few per pass of 33 index batches (~9 ms each),
/// each stretching a batch 15-30x, the shape the CI runner showed.
const sparse_long = [_]Hog{.{ .burst = .{ 150, 250 }, .gap = .{ 100, 200 } }};

/// Short, frequent stalls: one per few search samples (~50-100 us each).
const frequent_short = [_]Hog{
    .{ .burst = .{ 1, 20 }, .gap = .{ 5, 60 } },
    .{ .burst = .{ 5, 60 }, .gap = .{ 10, 80 } },
};

fn runContended(comptime scenario: anytype, comptime hogs: []const Hog, allocator: std.mem.Allocator) ![]u8 {
    const cpu = firstAllowedCpu() orelse return error.SkipZigTest;

    var noise: Noise = .{ .cpu = cpu };
    // A different interference pattern every run, as on a shared runner.
    const seed = monoNs();
    var threads: [hogs.len + 2]std.Thread = undefined;
    inline for (hogs, 0..) |h, i| {
        threads[i] = try std.Thread.spawn(.{}, Noise.cpuHog, .{ &noise, seed +% i, h.burst, h.gap });
    }
    threads[hogs.len] = try std.Thread.spawn(.{}, Noise.fsyncHog, .{ &noise, seed +% 101 });
    threads[hogs.len + 1] = try std.Thread.spawn(.{}, Noise.fsyncHog, .{ &noise, seed +% 102 });
    defer {
        noise.stop.store(true, .release);
        for (threads) |t| t.join();
    }

    var state: ScenarioRun(scenario) = .{ .cpu = cpu, .allocator = allocator };
    errdefer state.out.deinit(allocator);
    const t = try std.Thread.spawn(.{}, ScenarioRun(scenario).run, .{&state});
    t.join();
    if (state.err) |e| return e;
    return state.out.toOwnedSlice(allocator);
}

/// The verdict token of `name` in `output`: true for VARIANCE_OK.
fn verdictOf(output: []const u8, name: []const u8) !bool {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "VARIANCE_")) continue;
        var tok = std.mem.tokenizeScalar(u8, line, ' ');
        const verdict = tok.next() orelse continue;
        const bench_name = tok.next() orelse continue;
        if (!std.mem.eql(u8, bench_name, name)) continue;
        return std.mem.eql(u8, verdict, "VARIANCE_OK");
    }
    return error.NoVarianceToken;
}

/// Contended runs per scenario. The runner breached about every other
/// pipeline; a gate that is robust to it must hold in every run.
const contended_runs = 3;

fn expectHoldsUnderContention(comptime scenario: anytype, comptime hogs: []const Hog, name: []const u8) !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.heap.smp_allocator;
    var breached: usize = 0;
    for (0..contended_runs) |run| {
        const output = try runContended(scenario, hogs, allocator);
        defer allocator.free(output);
        std.debug.print("[run {d}] {s}", .{ run + 1, output });
        if (!try verdictOf(output, name)) breached += 1;
    }
    if (breached != 0) {
        std.debug.print("SONNY-2439: {s} breached its variance envelope in {d} of {d} contended runs\n", .{ name, breached, contended_runs });
        return error.VarianceEnvelopeBreachedUnderContention;
    }
}

test "SONNY-2439 fts_index_batch variance envelope holds while the host is contended (CPU + fsync)" {
    try expectHoldsUnderContention(bench.runIndexBatch, &sparse_long, "fts_index_batch");
}

test "SONNY-2439 fts_search_term variance envelope holds while the host is contended (CPU + fsync)" {
    try expectHoldsUnderContention(bench.runSearchTerm, &frequent_short, "fts_search_term");
}
