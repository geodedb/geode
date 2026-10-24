// PERF-D / #816 follow-up: regression tests for the admission control
// futex wake path. The prior commit (7cf46483) left the accept-loop
// admission control on a 5 ms nanosleep poll because the producer side
// (connection removal in `src/transport/quic.zig`) was classified as
// "no-signal-source". This follow-up wires `connection_slot_freed_gen`
// onto `QuicTransport` and has `destroyConnection`/`drainPendingDestroy`
// bump the counter and `futexWake(..., 1)` after dropping the slot.
//
// What this test pins:
//
//   1. **Wake-on-slot-freed fast path.** A thread parked on
//      `futexWaitTimeout(&connection_slot_freed_gen.raw, gen_at_park,
//      5ms)` must be unblocked by the producer-side `fetchAdd(1) +
//      futexWake(..., 1)` well before the 5 ms safety-net timeout.
//      Asserts <2 ms wake latency with generous slop for CI noise.
//   2. **Timeout still fires when no slot frees.** With no producer
//      activity, the waiter must return after ~5 ms (the upper bound)
//      and NOT block indefinitely.
//   3. **Lost-wake guard via gen mismatch.** If the producer increments
//      BEFORE the waiter takes its `gen_at_park` snapshot, the
//      `futexWaitTimeout` call returns immediately with a value-mismatch
//      result rather than blocking — proving the re-check discipline
//      works.
//
// The upper latency bounds exclude the time a thread sat runnable waiting
// for a CPU (its schedstat `run_delay`): that is the CI runner's scheduler,
// not the futex path; see `threadRunDelayNs`.
//
// We test the futex-word primitives directly against
// `QuicTransport.connection_slot_freed_gen` rather than driving
// `destroyConnection` end-to-end, because the latter requires a fully
// configured endpoint (certs, listen state, inner Connection bookkeeping)
// that is not feasible in a unit test. The producer code in
// destroyConnection/drainPendingDestroy is literally `fetchAdd(1,
// .release) + futexWake(u32, &gen.raw, 1)`, which is exactly what this
// test exercises against the SAME atomic word on a real `QuicTransport`
// instance. So this test pins the wire-up contract, while
// test-perf-d-admission-signal (against GlobalStreamThrottle) pins the
// canonical futex-wake pattern itself.
//
// CANARY: REQ=PERF-D-ADMISSION-WAKE-001; FEATURE="QuicTransport.connection_slot_freed_gen"; ASPECT=AdmissionFutexWake; STATUS=TESTED; OWNER=transport; UPDATED=2026-05-15; TEST=tests/test_perf_d_admission_wake.zig

const std = @import("std");
const testing = std.testing;

const transport_mod = @import("transport/quic");
const QuicTransport = transport_mod.QuicTransport;

fn nowMonoNs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec);
}

/// Time (ns) the calling thread has spent runnable but waiting for a CPU:
/// field 2 (`run_delay`) of /proc/thread-self/schedstat. 0 when the kernel
/// does not expose it (no /proc, or sched_info accounting off), so the
/// latency assertions below then fall back to plain wall time.
///
/// The latency bounds in this file are about the futex primitive (does the
/// wait return on the wake, or on the timeout, promptly?), not about the CI
/// runner's scheduler. On a CPU-starved runner (many test binaries in
/// parallel, a cgroup CPU quota) a thread whose futex returned on time can
/// sit runnable for tens of ms before it runs again and reads the clock
/// (job 17406246495: the 5 ms timeout case overran its 55 ms bound). That
/// wait is exactly this counter, so subtracting its delta over the timed
/// window removes the starvation and nothing else: a wait that really
/// blocks past its timeout, or misses a wake, is time spent ASLEEP, which
/// `run_delay` does not count, and still fails the same bound.
fn threadRunDelayNs() u64 {
    const linux = std.os.linux;
    const fd_rc = linux.open("/proc/thread-self/schedstat", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd_rc) != .SUCCESS) return 0;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    var buf: [128]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    if (linux.errno(n) != .SUCCESS) return 0;
    var it = std.mem.tokenizeAny(u8, buf[0..n], " \n");
    _ = it.next() orelse return 0; // sum_exec_runtime
    const run_delay = it.next() orelse return 0;
    return std.fmt.parseInt(u64, run_delay, 10) catch 0;
}

/// Wall time minus the scheduler wait accrued over the same window.
fn awakeLatencyNs(wall_ns: i64, run_delay_ns: u64) i64 {
    return wall_ns - @as(i64, @intCast(@min(run_delay_ns, @as(u64, std.math.maxInt(i64)))));
}

fn sleepNs(ns: i64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(@divTrunc(ns, std.time.ns_per_s)),
        .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

const WaiterCtx = struct {
    transport: *QuicTransport,
    timeout_ns: u64,
    ready: *std.atomic.Value(u32),
    gen_at_park: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    wake_ns: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    start_ns: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    woke_on_signal: std.atomic.Value(u32) = std.atomic.Value(u32).init(0), // 1 = woke
    /// Scheduler wait (ns) of this thread from just before the park to just
    /// after it woke (see `threadRunDelayNs`).
    run_delay_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn run(self: *WaiterCtx) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        // Snapshot the generation counter BEFORE marking ready. The main
        // thread will only call the producer wake AFTER ready is set, so
        // this guarantees gen_at_park == the value the producer will
        // bump from.
        const snap = self.transport.connection_slot_freed_gen.load(.acquire);
        self.gen_at_park.store(snap, .release);
        _ = self.ready.fetchAdd(1, .release);
        self.start_ns.store(nowMonoNs(), .release);

        const timeout: std.Io.Timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromNanoseconds(@intCast(self.timeout_ns)),
            .clock = .awake,
        } };
        const rd0 = threadRunDelayNs();
        io.futexWaitTimeout(u32, &self.transport.connection_slot_freed_gen.raw, snap, timeout) catch |err| switch (err) {
            error.Canceled => {},
        };
        self.wake_ns.store(nowMonoNs(), .release);
        self.run_delay_ns.store(threadRunDelayNs() -| rd0, .release);

        // If the gen counter actually moved, the producer signaled us.
        const after = self.transport.connection_slot_freed_gen.load(.acquire);
        if (after != snap) self.woke_on_signal.store(1, .release);
    }
};

test "PERF-D follow-up: producer-side fetchAdd+futexWake unblocks parked admission waiter in <2ms" {
    const alloc = testing.allocator;
    var transport = try QuicTransport.init(alloc, .{});
    defer transport.deinit();

    var ready: std.atomic.Value(u32) = .init(0);
    var ctx = WaiterCtx{
        .transport = &transport,
        // 500 ms — large enough that a missed wake would obviously hang
        // the test rather than passing on the timeout fast path.
        .timeout_ns = 500 * std.time.ns_per_ms,
        .ready = &ready,
    };

    const t = try std.Thread.spawn(.{}, WaiterCtx.run, .{&ctx});

    // Wait until the waiter has snapshotted its gen value and entered
    // futexWaitTimeout.
    while (ready.load(.acquire) == 0) sleepNs(50 * std.time.ns_per_us);
    sleepNs(500 * std.time.ns_per_us); // descend into the futex syscall

    // Mimic the producer (destroyConnection / drainPendingDestroy)
    // exactly: bump the gen counter and wake one waiter. This is the
    // same code those producers run, just exercised directly against
    // the same atomic word on the same QuicTransport instance.
    const io = std.Io.Threaded.global_single_threaded.io();
    const main_rd0 = threadRunDelayNs();
    const release_t0 = nowMonoNs();
    _ = transport.connection_slot_freed_gen.fetchAdd(1, .release);
    io.futexWake(u32, &transport.connection_slot_freed_gen.raw, 1);
    const main_run_delay_ns = threadRunDelayNs() -| main_rd0;

    t.join();

    try testing.expectEqual(@as(u32, 1), ctx.woke_on_signal.load(.acquire));

    const wall_latency_ns = ctx.wake_ns.load(.acquire) - release_t0;
    try testing.expect(wall_latency_ns >= 0);
    // Scheduler wait of the producer (between its clock read and the wake)
    // and of the waiter (between the wake and its clock read) is runner
    // starvation, not wake latency; see `threadRunDelayNs`.
    const wake_latency_ns = awakeLatencyNs(wall_latency_ns, main_run_delay_ns +| ctx.run_delay_ns.load(.acquire));
    // Critical assertion: wake within 2 ms. The pre-follow-up nanosleep
    // poll always sat out at least 5 ms (and could miss a slot-free
    // entirely if more than 5 ms passed between checks).
    if (wake_latency_ns >= 2 * std.time.ns_per_ms) std.debug.print("PERF-D wake: wall {d} ns, scheduler wait {d}+{d} ns\n", .{ wall_latency_ns, main_run_delay_ns, ctx.run_delay_ns.load(.acquire) });
    try testing.expect(wake_latency_ns < 2 * std.time.ns_per_ms);
}

test "PERF-D follow-up: parked admission waiter wakes via timeout when no producer signals" {
    const alloc = testing.allocator;
    var transport = try QuicTransport.init(alloc, .{});
    defer transport.deinit();

    const timeout_ns: u64 = 5 * std.time.ns_per_ms;
    const io = std.Io.Threaded.global_single_threaded.io();
    const snap = transport.connection_slot_freed_gen.load(.acquire);

    const timeout: std.Io.Timeout = .{ .duration = .{
        .raw = std.Io.Duration.fromNanoseconds(@intCast(timeout_ns)),
        .clock = .awake,
    } };

    const rd0 = threadRunDelayNs();
    const start = nowMonoNs();
    io.futexWaitTimeout(u32, &transport.connection_slot_freed_gen.raw, snap, timeout) catch {};
    const wall_ns = nowMonoNs() - start;
    const run_delay_ns = threadRunDelayNs() -| rd0;
    const elapsed_ns: u64 = @intCast(wall_ns);

    // Must wait at least most of the timeout (no premature wakeup). Plain
    // wall time: scheduler wait can only lengthen it.
    try testing.expect(elapsed_ns >= timeout_ns - 2 * std.time.ns_per_ms);
    // Must NOT wait substantially longer than the timeout. The 5 ms
    // safety-net IS the per-iteration upper bound for the admission
    // loop, so an order-of-magnitude overrun would defeat the purpose.
    // Measured without the time this thread sat runnable waiting for a
    // CPU after the timeout fired (see `threadRunDelayNs`).
    const awake_ns = awakeLatencyNs(wall_ns, run_delay_ns);
    if (awake_ns >= timeout_ns + 50 * std.time.ns_per_ms) std.debug.print("PERF-D timeout: wall {d} ns, scheduler wait {d} ns\n", .{ wall_ns, run_delay_ns });
    try testing.expect(awake_ns < timeout_ns + 50 * std.time.ns_per_ms);
}

test "PERF-D follow-up: gen mismatch returns immediately (lost-wake race guard)" {
    const alloc = testing.allocator;
    var transport = try QuicTransport.init(alloc, .{});
    defer transport.deinit();

    const io = std.Io.Threaded.global_single_threaded.io();
    // Snapshot the gen, then mutate it BEFORE entering futexWaitTimeout.
    // The kernel must observe value != expected and return immediately
    // rather than parking the thread — this is the lost-wake guard the
    // admission loop relies on (producer might increment between the
    // count check and the futex park).
    const snap = transport.connection_slot_freed_gen.load(.acquire);
    _ = transport.connection_slot_freed_gen.fetchAdd(1, .release);

    const timeout: std.Io.Timeout = .{ .duration = .{
        .raw = std.Io.Duration.fromNanoseconds(500 * std.time.ns_per_ms),
        .clock = .awake,
    } };
    const rd0 = threadRunDelayNs();
    const start = nowMonoNs();
    io.futexWaitTimeout(u32, &transport.connection_slot_freed_gen.raw, snap, timeout) catch {};
    const wall_ns = nowMonoNs() - start;
    const run_delay_ns = threadRunDelayNs() -| rd0;

    // Must return within a small fraction of the 500 ms timeout — well
    // under 10 ms even on a slow CI runner, once the time this thread sat
    // runnable waiting for a CPU is taken out (see `threadRunDelayNs`).
    const awake_ns = awakeLatencyNs(wall_ns, run_delay_ns);
    if (awake_ns >= 10 * std.time.ns_per_ms) std.debug.print("PERF-D mismatch: wall {d} ns, scheduler wait {d} ns\n", .{ wall_ns, run_delay_ns });
    try testing.expect(awake_ns < 10 * std.time.ns_per_ms);
}
