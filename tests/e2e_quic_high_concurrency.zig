// CANARY: REQ=REQ-QUIC-HC-002; FEATURE="QUIC High-Concurrency Requests"; ASPECT=ParallelReadWriteE2E; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-25
const std = @import("std");
const builtin = @import("builtin");
const util = @import("proto_test_util.zig");

const default_worker_count = if (builtin.mode == .Debug) 32 else 64;
const default_ops_per_worker = if (builtin.mode == .Debug) 12 else 8;
const default_mutation_stride = 3;
const default_connect_attempts = if (builtin.mode == .Debug) 5 else 16;
const default_connect_backoff_ms = 50;
const default_handshake_timeout_secs = if (builtin.mode == .Debug) 5 else 15;
const default_hello_timeout_ms = 1000;
const default_setup_timeout_secs = if (builtin.mode == .Debug) 30 else 45;
const default_execute_timeout_secs = if (builtin.mode == .Debug) 5 else 10;
const default_execute_retries = if (builtin.mode == .Debug) 0 else 1;
const default_request_stagger_us = if (builtin.mode == .Debug) 0 else 100;
const default_detached_first_stream_threads = if (builtin.mode == .Debug) 64 else 256;
// ENG-3914 (RC-4): mirrors `default_quic_poll_worker_count` in
// src/server/main.zig, which moved its Debug default 1 -> 4 (one endpoint poll
// worker serialises datagram delivery for every connection; measured >30x
// slower than 2+ under four concurrent batch sessions). Kept in lockstep so
// this harness spawns servers with the shipping default.
const default_poll_worker_count = if (builtin.mode == .Debug) 4 else 16;
const default_cooperative_first_stream_worker_count = if (builtin.mode == .Debug) 16 else 256;
const default_connection_worker_count = 64;
const default_group_commit_coalesce_us: u32 = 500;
const high_fanout_group_commit_coalesce_us: u32 = 500;
const default_group_commit_active_shards: u32 = 16;
const default_mutation_admission_cap: u32 = 80;
const high_fanout_mutation_admission_cap: u32 = 80;
const objective_worker_count: u32 = 16_384;
const objective_ops_per_worker: u32 = 8;
const objective_mutation_stride: u32 = 4;
const objective_min_completion_ppm: u32 = 999_500;
const objective_min_mutation_ppm: u32 = 250_000;
const objective_min_qps: u32 = 10_000;
const objective_p50_max_ms: u32 = 20;
const objective_p95_max_ms: u32 = 100;
const objective_p99_max_ms: u32 = 250;
const objective_p999_max_ms: u32 = 1000;
const objective_memory_growth_max_kb: u32 = 2 * 1024 * 1024;
const high_fanout_worker_threshold = 64;
const high_fanout_connection_worker_cap = 64;
// CANARY: REQ=REQ-QUIC-HC-152; FEATURE="High-Concurrency Test Harness"; ASPECT=FailureLogBackpressure; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-29
//
// A 4k failed probe can otherwise print thousands of per-worker timeout lines,
// making the local test driver a meaningful part of failure cost. Keep exact
// counters and summaries, but cap individual failure lines.
const failure_log_limit: u32 = 64;
// CANARY: REQ=REQ-QUIC-HC-141; FEATURE="QUIC High-Concurrency Requests"; ASPECT=PollWorkerContentionCap; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-29
//
// QUIC v0.1.21 removes the old long-header TLS dispatch choke point. Keep the
// proven 16-worker high-fanout default, but allow explicit 64-worker A/B probes
// without patching the server/harness.
const high_fanout_poll_worker_cap = if (builtin.mode == .Debug) 4 else 64;
// CANARY: REQ=REQ-QUIC-HC-138; FEATURE="High-Concurrency Test Harness"; ASPECT=CooperativeFirstStreamWorkerHeadroom; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-28
//
// Keep the cooperative owner pool bounded; raising it to match 1024 clients
// stalls HELLO setup in same-process fan-out tests. Tail latency is protected
// by the scheduler's one-message FIFO turn rather than one server thread per
// active client.
const high_fanout_cooperative_first_stream_worker_cap = if (builtin.mode == .Debug) 64 else 512;
// CANARY: REQ=REQ-QUIC-HC-118; FEATURE="High-Concurrency Test Harness"; ASPECT=BoundedDriverThreadStacks; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-06-11
//
// The E2E harness intentionally opens hundreds to thousands of clients in one
// process. Use a bounded stack for those simple driver threads so the client
// side does not consume default multi-megabyte stacks before the server is the
// limiting factor.
const high_concurrency_worker_stack_size = 1024 * 1024;

fn monoNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    const rc = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    if (rc != 0) return 0;
    const sec: u64 = if (ts.sec < 0) 0 else @intCast(ts.sec);
    const nsec: u64 = if (ts.nsec < 0) 0 else @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}

fn sleepNs(ns: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(ns), .awake) catch {};
}

fn envU32(name: [*:0]const u8, default_value: u32) u32 {
    const raw = std.c.getenv(name) orelse return default_value;
    const value = std.mem.span(raw);
    if (value.len == 0) return default_value;
    return std.fmt.parseUnsigned(u32, value, 10) catch default_value;
}

fn envBool(name: [*:0]const u8, default_value: bool) bool {
    const raw = std.c.getenv(name) orelse return default_value;
    const value = std.mem.span(raw);
    if (value.len == 0) return default_value;
    if (std.mem.eql(u8, value, "0")) return false;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    if (std.ascii.eqlIgnoreCase(value, "no")) return false;
    if (std.ascii.eqlIgnoreCase(value, "off")) return false;
    return true;
}

fn connectAndHelloWithRetry(
    allocator: std.mem.Allocator,
    addr: []const u8,
    attempts: u32,
    base_backoff_ms: u32,
    handshake_timeout_secs: u32,
    hello_timeout_ms: u32,
    counters: ?*Counters,
    abort_setup: ?*std.atomic.Value(bool),
) !util.QuicProtoClient {
    var attempt: u32 = 0;
    var last_err: anyerror = error.HandshakeError;
    while (attempt < attempts) : (attempt += 1) {
        if (abort_setup) |abort| {
            if (abort.load(.acquire)) return error.Aborted;
        }
        if (counters) |setup_counters| {
            _ = setup_counters.setup_attempts.fetchAdd(1, .acq_rel);
        }
        const shift: u6 = @intCast(@min(attempt, 4));
        const delay_ms: u64 = @min(@as(u64, 1000), @as(u64, base_backoff_ms) << shift);
        var client = util.QuicProtoClient.connectWithHandshakeTimeout(allocator, addr, handshake_timeout_secs) catch |err| {
            last_err = err;
            if (counters) |setup_counters| {
                if (attempt + 1 < attempts) _ = setup_counters.setup_retries.fetchAdd(1, .acq_rel);
            }
            sleepNs(delay_ms * @as(u64, std.time.ns_per_ms));
            if (abort_setup) |abort| {
                if (abort.load(.acquire)) return error.Aborted;
            }
            continue;
        };
        errdefer client.deinit();
        if (counters) |setup_counters| {
            _ = setup_counters.connected.fetchAdd(1, .acq_rel);
        }

        var hello_result = client.helloWithTimeout(allocator, util.defaultUsername(), util.defaultPassword(), hello_timeout_ms) catch |err| {
            last_err = err;
            client.deinit();
            if (counters) |setup_counters| {
                if (attempt + 1 < attempts) _ = setup_counters.setup_retries.fetchAdd(1, .acq_rel);
            }
            sleepNs(delay_ms * @as(u64, std.time.ns_per_ms));
            if (abort_setup) |abort| {
                if (abort.load(.acquire)) return error.Aborted;
            }
            continue;
        };
        defer hello_result.deinit(allocator);
        if (!hello_result.success) {
            last_err = error.AuthenticationFailed;
            client.deinit();
            if (counters) |setup_counters| {
                if (attempt + 1 < attempts) _ = setup_counters.setup_retries.fetchAdd(1, .acq_rel);
            }
            sleepNs(delay_ms * @as(u64, std.time.ns_per_ms));
            if (abort_setup) |abort| {
                if (abort.load(.acquire)) return error.Aborted;
            }
            continue;
        }
        if (counters) |setup_counters| {
            _ = setup_counters.hello_ok.fetchAdd(1, .acq_rel);
        }
        return client;
    }
    return last_err;
}

fn envSlice(name: [*:0]const u8, default_value: []const u8) []const u8 {
    const raw = std.c.getenv(name) orelse return default_value;
    const value = std.mem.span(raw);
    if (value.len == 0) return default_value;
    return value;
}

fn highFanoutConnectionWorkerDefault(worker_count: u32) u32 {
    const doubled = std.math.mul(u32, worker_count, 2) catch std.math.maxInt(u32);
    return @min(@max(doubled, default_connection_worker_count), high_fanout_connection_worker_cap);
}

fn highFanoutPollWorkerDefault(worker_count: u32) u32 {
    _ = worker_count;
    return @min(@as(u32, 16), high_fanout_poll_worker_cap);
}

fn highFanoutMutationAdmissionCapDefault(worker_count: u32) u32 {
    _ = worker_count;
    return high_fanout_mutation_admission_cap;
}

// CANARY: REQ=REQ-QUIC-HC-128; FEATURE="High-Concurrency Test Harness"; ASPECT=CooperativeFirstStreamWorkerHeadroom; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-06-11
//
// Cooperative first-stream workers execute the persistent request loops. At
// high fanout, leaving this at the debug default of 16 turns storage/transport
// work into an artificial scheduler bottleneck, but matching the full client
// count at 128+ can overrun the debug scheduler and starve the server process.
fn highFanoutCooperativeFirstStreamWorkerDefault(worker_count: u32) u32 {
    return @min(@max(worker_count, default_cooperative_first_stream_worker_count), high_fanout_cooperative_first_stream_worker_cap);
}

const Counters = struct {
    ok: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    read_ok: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    mutation_ok: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    read_failed: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    mutation_failed: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    failed: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    setup_failed: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    setup_attempts: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    setup_retries: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    connected: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    hello_ok: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    ready: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    ops_started: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    execute_attempts: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    execute_retries: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    execute_reconnects: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    exec_timing_samples: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    response_messages: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    first_response_timeouts: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    execute_write_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    execute_prepare_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    execute_stream_write_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    execute_post_write_poll_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    first_response_wait_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    first_response_read_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    response_read_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    max_first_response_wait_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    first_execute_lag_samples: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    first_execute_lag_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    max_first_execute_lag_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    read_latency_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    mutation_latency_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    first_op_ok: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    followup_op_ok: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    first_op_latency_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    followup_op_latency_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    max_latency_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    verify_done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    verify_failed: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    failure_logs: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

const WorkerCtx = struct {
    addr: []const u8,
    worker_id: u32,
    ops_per_worker: u32,
    mutation_stride: u32,
    read_query: []const u8,
    connect_attempts: u32,
    connect_backoff_ms: u32,
    handshake_timeout_secs: u32,
    hello_timeout_ms: u32,
    connect_stagger_us: u32,
    request_stagger_us: u32,
    execute_timeout_secs: u32,
    execute_retries: u32,
    post_write_poll: bool,
    counters: *Counters,
    start: *std.atomic.Value(bool),
    start_generation: *std.atomic.Value(u32),
    abort_setup: *std.atomic.Value(bool),
    release_clients: *std.atomic.Value(bool),
    release_generation: *std.atomic.Value(u32),
    workload_start_ns: *std.atomic.Value(u64),
    op_latency_samples_ns: []u64,
    op_latency_sample_index: *std.atomic.Value(u32),
    expected_ops: u32,
    verify_after_workload: bool,
    client_diagnostics: bool,
};

fn recordFailure(counters: *Counters, comptime fmt: []const u8, args: anytype) void {
    const log_idx = counters.failure_logs.fetchAdd(1, .acq_rel);
    if (log_idx < failure_log_limit) {
        std.debug.print("high-concurrency QUIC E2E failure: " ++ fmt ++ "\n", args);
    } else if (log_idx == failure_log_limit) {
        std.debug.print("high-concurrency QUIC E2E failure: suppressing additional per-worker failures; summary follows\n", .{});
    }
    _ = counters.failed.fetchAdd(1, .acq_rel);
}

fn recordOperationFailure(counters: *Counters, is_mutation: bool, comptime fmt: []const u8, args: anytype) void {
    if (is_mutation) {
        _ = counters.mutation_failed.fetchAdd(1, .acq_rel);
    } else {
        _ = counters.read_failed.fetchAdd(1, .acq_rel);
    }
    recordFailure(counters, fmt, args);
}

fn recordSetupFailure(counters: *Counters, comptime fmt: []const u8, args: anytype) void {
    const log_idx = counters.failure_logs.fetchAdd(1, .acq_rel);
    if (log_idx < failure_log_limit) {
        std.debug.print("high-concurrency QUIC E2E setup failure: " ++ fmt ++ "\n", args);
    } else if (log_idx == failure_log_limit) {
        std.debug.print("high-concurrency QUIC E2E setup failure: suppressing additional per-worker failures; summary follows\n", .{});
    }
    _ = counters.setup_failed.fetchAdd(1, .acq_rel);
    _ = counters.failed.fetchAdd(1, .acq_rel);
}

fn recordMaxAtomic(atom: *std.atomic.Value(u64), value: u64) void {
    var observed = atom.load(.acquire);
    while (value > observed) {
        observed = atom.cmpxchgWeak(observed, value, .acq_rel, .acquire) orelse break;
    }
}

fn recordMaxLatency(counters: *Counters, latency_ns: u64) void {
    recordMaxAtomic(&counters.max_latency_ns, latency_ns);
}

fn recordLatencySample(ctx: *WorkerCtx, latency_ns: u64) void {
    const idx = ctx.op_latency_sample_index.fetchAdd(1, .acq_rel);
    if (idx < ctx.op_latency_samples_ns.len) {
        ctx.op_latency_samples_ns[idx] = latency_ns;
    }
}

// CANARY: REQ=REQ-QUIC-HC-155; FEATURE="QUIC High-Concurrency Diagnostics"; ASPECT=ExecutePhaseAggregation; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-06-11
//
// Aggregate client-visible transport phases so failed ceiling probes can
// distinguish local start-barrier/scheduler lag, request write cost, first
// response wait, and response read/parse time.
fn recordExecTiming(ctx: *WorkerCtx, timing: *const util.QuicProtoClient.ExecTiming, op: usize) void {
    if (timing.total_ns == 0 and timing.execute_write_start_ns == 0 and timing.response_read_ns == 0) return;

    _ = ctx.counters.exec_timing_samples.fetchAdd(1, .acq_rel);
    _ = ctx.counters.execute_write_ns.fetchAdd(timing.execute_write_ns, .acq_rel);
    _ = ctx.counters.execute_prepare_ns.fetchAdd(timing.execute_prepare_ns, .acq_rel);
    _ = ctx.counters.execute_stream_write_ns.fetchAdd(timing.execute_stream_write_ns, .acq_rel);
    _ = ctx.counters.execute_post_write_poll_ns.fetchAdd(timing.execute_post_write_poll_ns, .acq_rel);
    _ = ctx.counters.first_response_wait_ns.fetchAdd(timing.first_response_wait_ns, .acq_rel);
    _ = ctx.counters.first_response_read_ns.fetchAdd(timing.first_response_read_ns, .acq_rel);
    _ = ctx.counters.response_read_ns.fetchAdd(timing.response_read_ns, .acq_rel);
    _ = ctx.counters.response_messages.fetchAdd(timing.response_messages, .acq_rel);
    recordMaxAtomic(&ctx.counters.max_first_response_wait_ns, timing.first_response_wait_ns);
    if (timing.timed_out_before_first_response) {
        _ = ctx.counters.first_response_timeouts.fetchAdd(1, .acq_rel);
    }

    if (op == 0 and timing.execute_write_start_ns != 0) {
        const workload_start_ns = ctx.workload_start_ns.load(.acquire);
        if (workload_start_ns != 0) {
            const scheduled_start_ns = workload_start_ns +| (@as(u64, ctx.request_stagger_us) * @as(u64, ctx.worker_id) * std.time.ns_per_us);
            const lag_ns = timing.execute_write_start_ns -| scheduled_start_ns;
            _ = ctx.counters.first_execute_lag_samples.fetchAdd(1, .acq_rel);
            _ = ctx.counters.first_execute_lag_ns.fetchAdd(lag_ns, .acq_rel);
            recordMaxAtomic(&ctx.counters.max_first_execute_lag_ns, lag_ns);
        }
    }
}

fn nsAvgMsX100(total_ns: u64, samples: u32) u64 {
    if (samples == 0) return 0;
    return total_ns / @as(u64, samples) / (std.time.ns_per_ms / 100);
}

fn nsMsX100(ns: u64) u64 {
    return ns / (std.time.ns_per_ms / 100);
}

const LatencyPercentiles = struct {
    sample_count: u32 = 0,
    p50_ns: u64 = 0,
    p95_ns: u64 = 0,
    p99_ns: u64 = 0,
    p999_ns: u64 = 0,
};

fn lessThanU64(_: void, lhs: u64, rhs: u64) bool {
    return lhs < rhs;
}

fn percentileIndex(sample_count: usize, ppm: u32) usize {
    if (sample_count == 0) return 0;
    const rank = (@as(u64, sample_count) * @as(u64, ppm) + 999_999) / 1_000_000;
    const clamped = @min(@max(rank, 1), @as(u64, sample_count));
    return @intCast(clamped - 1);
}

fn computeLatencyPercentiles(samples: []u64, sample_count_raw: u32) LatencyPercentiles {
    const sample_count = @min(samples.len, @as(usize, sample_count_raw));
    if (sample_count == 0) return .{};
    const slice = samples[0..sample_count];
    std.mem.sort(u64, slice, {}, lessThanU64);
    return .{
        .sample_count = @intCast(sample_count),
        .p50_ns = slice[percentileIndex(sample_count, 500_000)],
        .p95_ns = slice[percentileIndex(sample_count, 950_000)],
        .p99_ns = slice[percentileIndex(sample_count, 990_000)],
        .p999_ns = slice[percentileIndex(sample_count, 999_000)],
    };
}

fn printLatencyPercentiles(percentiles: LatencyPercentiles) void {
    const p50_ms_x100 = nsMsX100(percentiles.p50_ns);
    const p95_ms_x100 = nsMsX100(percentiles.p95_ns);
    const p99_ms_x100 = nsMsX100(percentiles.p99_ns);
    const p999_ms_x100 = nsMsX100(percentiles.p999_ns);
    std.debug.print(
        "high-concurrency QUIC E2E latency_percentiles samples={d} p50_ms={d}.{d:0>2} p95_ms={d}.{d:0>2} p99_ms={d}.{d:0>2} p99_9_ms={d}.{d:0>2}\n",
        .{
            percentiles.sample_count,
            p50_ms_x100 / 100,
            p50_ms_x100 % 100,
            p95_ms_x100 / 100,
            p95_ms_x100 % 100,
            p99_ms_x100 / 100,
            p99_ms_x100 % 100,
            p999_ms_x100 / 100,
            p999_ms_x100 % 100,
        },
    );
}

fn printTimingSummary(counters: *Counters) void {
    const timing_samples = counters.exec_timing_samples.load(.acquire);
    const first_execute_samples = counters.first_execute_lag_samples.load(.acquire);
    const response_messages = counters.response_messages.load(.acquire);
    const avg_first_execute_lag_ms_x100 = nsAvgMsX100(counters.first_execute_lag_ns.load(.acquire), first_execute_samples);
    const avg_execute_write_ms_x100 = nsAvgMsX100(counters.execute_write_ns.load(.acquire), timing_samples);
    const avg_execute_prepare_ms_x100 = nsAvgMsX100(counters.execute_prepare_ns.load(.acquire), timing_samples);
    const avg_execute_stream_write_ms_x100 = nsAvgMsX100(counters.execute_stream_write_ns.load(.acquire), timing_samples);
    const avg_execute_post_write_poll_ms_x100 = nsAvgMsX100(counters.execute_post_write_poll_ns.load(.acquire), timing_samples);
    const avg_first_response_wait_ms_x100 = nsAvgMsX100(counters.first_response_wait_ns.load(.acquire), timing_samples);
    const avg_first_response_read_ms_x100 = nsAvgMsX100(counters.first_response_read_ns.load(.acquire), timing_samples);
    const avg_response_read_ms_x100 = nsAvgMsX100(counters.response_read_ns.load(.acquire), timing_samples);
    const avg_response_msg_read_ms_x100 = nsAvgMsX100(counters.response_read_ns.load(.acquire), response_messages);
    const max_first_execute_lag_ms_x100 = counters.max_first_execute_lag_ns.load(.acquire) / (std.time.ns_per_ms / 100);
    const max_first_response_wait_ms_x100 = counters.max_first_response_wait_ns.load(.acquire) / (std.time.ns_per_ms / 100);
    std.debug.print(
        "high-concurrency QUIC E2E timing samples={d} response_messages={d} first_response_timeouts={d} avg_ready_to_first_execute_ms={d}.{d:0>2} max_ready_to_first_execute_ms={d}.{d:0>2} avg_execute_write_ms={d}.{d:0>2} avg_execute_prepare_ms={d}.{d:0>2} avg_execute_stream_write_ms={d}.{d:0>2} avg_execute_post_write_poll_ms={d}.{d:0>2} avg_first_response_wait_ms={d}.{d:0>2} max_first_response_wait_ms={d}.{d:0>2} avg_first_response_read_ms={d}.{d:0>2} avg_response_read_ms={d}.{d:0>2} avg_response_message_read_ms={d}.{d:0>2}\n",
        .{
            timing_samples,
            response_messages,
            counters.first_response_timeouts.load(.acquire),
            avg_first_execute_lag_ms_x100 / 100,
            avg_first_execute_lag_ms_x100 % 100,
            max_first_execute_lag_ms_x100 / 100,
            max_first_execute_lag_ms_x100 % 100,
            avg_execute_write_ms_x100 / 100,
            avg_execute_write_ms_x100 % 100,
            avg_execute_prepare_ms_x100 / 100,
            avg_execute_prepare_ms_x100 % 100,
            avg_execute_stream_write_ms_x100 / 100,
            avg_execute_stream_write_ms_x100 % 100,
            avg_execute_post_write_poll_ms_x100 / 100,
            avg_execute_post_write_poll_ms_x100 % 100,
            avg_first_response_wait_ms_x100 / 100,
            avg_first_response_wait_ms_x100 % 100,
            max_first_response_wait_ms_x100 / 100,
            max_first_response_wait_ms_x100 % 100,
            avg_first_response_read_ms_x100 / 100,
            avg_first_response_read_ms_x100 % 100,
            avg_response_read_ms_x100 / 100,
            avg_response_read_ms_x100 % 100,
            avg_response_msg_read_ms_x100 / 100,
            avg_response_msg_read_ms_x100 % 100,
        },
    );
}

fn expectNoQueryError(res: *const util.ExecResult) !void {
    if (res.error_code) |code| {
        std.debug.print("query returned error_code={s}", .{code});
        if (res.error_message) |msg| std.debug.print(" message={s}", .{msg});
        std.debug.print("\n", .{});
        return error.QueryReturnedError;
    }
}

fn firstInt(res: *const util.ExecResult) !i64 {
    if (res.rows.len == 0 or res.rows[0].len == 0) return error.MissingResult;
    return switch (res.rows[0][0]) {
        .int => |value| value,
        else => error.UnexpectedResultType,
    };
}

fn readServerRssKb(server: *const util.ServerHandle) u64 {
    const pid = server.child.id orelse return 0;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/status", .{pid}) catch return 0;
    const rc = std.os.linux.open(path.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(rc)) < 0) return 0;
    const fd: i32 = @intCast(rc);
    defer _ = std.os.linux.close(fd);

    var status_buf: [8192]u8 = undefined;
    const n_rc = std.os.linux.read(fd, &status_buf, status_buf.len);
    const n_signed: isize = @bitCast(n_rc);
    if (n_signed <= 0) return 0;
    const status = status_buf[0..@as(usize, @intCast(n_signed))];
    const key = "VmRSS:";
    const start = std.mem.indexOf(u8, status, key) orelse return 0;
    var idx = start + key.len;
    while (idx < status.len and (status[idx] == ' ' or status[idx] == '\t')) : (idx += 1) {}
    const value_start = idx;
    while (idx < status.len and std.ascii.isDigit(status[idx])) : (idx += 1) {}
    if (idx == value_start) return 0;
    return std.fmt.parseUnsigned(u64, status[value_start..idx], 10) catch 0;
}

fn linuxWriteAll(fd: i32, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = std.os.linux.write(fd, bytes[offset..].ptr, bytes.len - offset);
        const signed: isize = @bitCast(rc);
        if (signed <= 0) return error.WriteFailed;
        offset += @intCast(signed);
    }
}

fn httpResponseComplete(data: []const u8) bool {
    const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return false;
    const headers = data[0..header_end];
    const key = "Content-Length:";
    const key_start = std.mem.indexOf(u8, headers, key) orelse return false;
    var idx = key_start + key.len;
    while (idx < headers.len and (headers[idx] == ' ' or headers[idx] == '\t')) : (idx += 1) {}
    const value_start = idx;
    while (idx < headers.len and std.ascii.isDigit(headers[idx])) : (idx += 1) {}
    if (idx == value_start) return false;
    const content_len = std.fmt.parseUnsigned(usize, headers[value_start..idx], 10) catch return false;
    return data.len >= header_end + 4 + content_len;
}

fn httpGetLoopback(allocator: std.mem.Allocator, port: u16, path: []const u8, max_bytes: usize) ![]u8 {
    const linux = std.os.linux;
    const fd_raw = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
    const fd_err = linux.errno(fd_raw);
    if (fd_err != .SUCCESS) return error.SocketCreateFailed;
    const fd: i32 = @intCast(fd_raw);
    defer _ = linux.close(fd);

    const sa = linux.sockaddr.in{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
        .zero = .{0} ** 8,
    };
    const conn_rc = linux.connect(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in));
    if (@as(isize, @bitCast(conn_rc)) < 0) return error.ConnectFailed;

    const request = try std.fmt.allocPrint(
        allocator,
        "GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n",
        .{ path, port },
    );
    defer allocator.free(request);
    try linuxWriteAll(fd, request);

    var response: std.ArrayList(u8) = .empty;
    errdefer response.deinit(allocator);
    var chunk: [8192]u8 = undefined;
    while (response.items.len < max_bytes) {
        const n_rc = linux.read(fd, &chunk, chunk.len);
        const signed: isize = @bitCast(n_rc);
        if (signed < 0) return error.ReadFailed;
        if (signed == 0) break;
        try response.appendSlice(allocator, chunk[0..@intCast(signed)]);
        if (httpResponseComplete(response.items)) break;
    }

    const header_end = std.mem.indexOf(u8, response.items, "\r\n\r\n") orelse return try response.toOwnedSlice(allocator);
    const body = response.items[header_end + 4 ..];
    const owned = try allocator.dupe(u8, body);
    response.deinit(allocator);
    return owned;
}

const MetricAggregateMode = enum { sum, max };

fn runtimeMetricAggregate(metrics: []const u8, name: []const u8, mode: MetricAggregateMode) u64 {
    var value: u64 = 0;
    var lines = std.mem.splitScalar(u8, metrics, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, name)) continue;
        if (line.len <= name.len or !std.ascii.isWhitespace(line[name.len])) continue;
        var rest = std.mem.trim(u8, line[name.len..], " \t");
        const end = std.mem.indexOfAny(u8, rest, " \t\r") orelse rest.len;
        rest = rest[0..end];
        const parsed = std.fmt.parseUnsigned(u64, rest, 10) catch continue;
        switch (mode) {
            .sum => value +|= parsed,
            .max => {
                if (parsed > value) value = parsed;
            },
        }
    }
    return value;
}

fn runtimeMetricSum(metrics: []const u8, name: []const u8) u64 {
    return runtimeMetricAggregate(metrics, name, .sum);
}

fn runtimeMetricMax(metrics: []const u8, name: []const u8) u64 {
    return runtimeMetricAggregate(metrics, name, .max);
}

fn printRuntimeMetricsSnapshot(allocator: std.mem.Allocator, metrics_port: u16) void {
    // CANARY: REQ=REQ-QUIC-HC-172; FEATURE="High-Concurrency Diagnostics"; ASPECT=HarnessRuntimeMetricsScrape; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-06-11
    //
    // The 4096x8+ ceiling is dominated by first-response tail. Scrape the
    // server-side runtime metrics while the child is still alive so failed
    // probes split QUIC response-write, first-stream scheduler, execution, and
    // storage tuple-lock costs without relying on periodic stderr timing.
    const metrics = httpGetLoopback(allocator, metrics_port, "/metrics", 2 * 1024 * 1024) catch |err| {
        std.debug.print("high-concurrency QUIC E2E runtime_metrics scrape_failed={s} port={d}\n", .{ @errorName(err), metrics_port });
        return;
    };
    defer allocator.free(metrics);

    std.debug.print(
        "high-concurrency QUIC E2E runtime_metrics stream_write_calls={d} stream_write_success={d} stream_write_errors={d} stream_write_timeouts={d} stream_write_blocked_retries={d} stream_write_elapsed_ns_total={d} stream_write_elapsed_max_ns={d}\n",
        .{
            runtimeMetricSum(metrics, "quic_stream_write_calls_total"),
            runtimeMetricSum(metrics, "quic_stream_write_success_total"),
            runtimeMetricSum(metrics, "quic_stream_write_errors_total"),
            runtimeMetricSum(metrics, "quic_stream_write_timeouts_total"),
            runtimeMetricSum(metrics, "quic_stream_write_blocked_retries_total"),
            runtimeMetricSum(metrics, "quic_stream_write_elapsed_ns_total"),
            runtimeMetricMax(metrics, "quic_stream_write_elapsed_max_ns"),
        },
    );
    std.debug.print(
        "high-concurrency QUIC E2E runtime_metrics first_stream_ready_enqueued={d} first_stream_ready_dequeued={d} first_stream_ready_wait_ns_total={d} first_stream_ready_wait_max_ns={d} first_stream_packets_started={d} first_stream_packets_completed={d} first_stream_packet_process_ns_total={d} first_stream_packet_process_max_ns={d} first_stream_mutation_deferrals={d}\n",
        .{
            runtimeMetricSum(metrics, "quic_first_stream_ready_enqueued_total"),
            runtimeMetricSum(metrics, "quic_first_stream_ready_dequeued_total"),
            runtimeMetricSum(metrics, "quic_first_stream_ready_queue_wait_ns_total"),
            runtimeMetricMax(metrics, "quic_first_stream_ready_queue_wait_max_ns"),
            runtimeMetricSum(metrics, "quic_first_stream_packets_started_total"),
            runtimeMetricSum(metrics, "quic_first_stream_packets_completed_total"),
            runtimeMetricSum(metrics, "quic_first_stream_packet_process_ns_total"),
            runtimeMetricMax(metrics, "quic_first_stream_packet_process_max_ns"),
            runtimeMetricSum(metrics, "quic_first_stream_mutation_deferrals_total"),
        },
    );
    std.debug.print(
        "high-concurrency QUIC E2E runtime_metrics first_stream_prepare_samples={d} first_stream_prepare_ns_total={d} first_stream_prepare_max_ns={d} first_stream_execute_samples={d} first_stream_execute_ns_total={d} first_stream_execute_max_ns={d} first_stream_response_send_samples={d} first_stream_response_send_ns_total={d} first_stream_response_send_max_ns={d}\n",
        .{
            runtimeMetricSum(metrics, "quic_first_stream_query_prepare_samples_total"),
            runtimeMetricSum(metrics, "quic_first_stream_query_prepare_ns_total"),
            runtimeMetricMax(metrics, "quic_first_stream_query_prepare_max_ns"),
            runtimeMetricSum(metrics, "quic_first_stream_query_execute_samples_total"),
            runtimeMetricSum(metrics, "quic_first_stream_query_execute_ns_total"),
            runtimeMetricMax(metrics, "quic_first_stream_query_execute_max_ns"),
            runtimeMetricSum(metrics, "quic_first_stream_response_send_samples_total"),
            runtimeMetricSum(metrics, "quic_first_stream_response_send_ns_total"),
            runtimeMetricMax(metrics, "quic_first_stream_response_send_max_ns"),
        },
    );
    std.debug.print(
        "high-concurrency QUIC E2E runtime_metrics first_stream_read_execute_samples={d} first_stream_read_execute_ns_total={d} first_stream_read_execute_max_ns={d} first_stream_mutation_execute_samples={d} first_stream_mutation_execute_ns_total={d} first_stream_mutation_execute_max_ns={d}\n",
        .{
            runtimeMetricSum(metrics, "quic_first_stream_read_query_execute_samples_total"),
            runtimeMetricSum(metrics, "quic_first_stream_read_query_execute_ns_total"),
            runtimeMetricMax(metrics, "quic_first_stream_read_query_execute_max_ns"),
            runtimeMetricSum(metrics, "quic_first_stream_mutation_query_execute_samples_total"),
            runtimeMetricSum(metrics, "quic_first_stream_mutation_query_execute_ns_total"),
            runtimeMetricMax(metrics, "quic_first_stream_mutation_query_execute_max_ns"),
        },
    );
    std.debug.print(
        "high-concurrency QUIC E2E runtime_metrics poll_cycle_max_ns={d} poll_transport_max_ns={d} poll_recv_process_max_ns={d} poll_recv_short_header_max_ns={d} poll_recv_short_endpoint_map_max_ns={d} poll_recv_short_rx_serial_wait_max_ns={d} poll_recv_short_conn_lock_wait_max_ns={d} poll_recv_short_decrypt_max_ns={d} poll_recv_short_frame_process_max_ns={d} poll_recv_short_ack_send_max_ns={d} poll_overrun_total={d}\n",
        .{
            runtimeMetricMax(metrics, "quic_poll_cycle_max_ns"),
            runtimeMetricMax(metrics, "quic_poll_transport_max_ns"),
            runtimeMetricMax(metrics, "quic_poll_recv_process_max_ns"),
            runtimeMetricMax(metrics, "quic_poll_recv_short_header_max_ns"),
            runtimeMetricMax(metrics, "quic_poll_recv_short_endpoint_map_max_ns"),
            runtimeMetricMax(metrics, "quic_poll_recv_short_rx_serial_wait_max_ns"),
            runtimeMetricMax(metrics, "quic_poll_recv_short_conn_lock_wait_max_ns"),
            runtimeMetricMax(metrics, "quic_poll_recv_short_decrypt_max_ns"),
            runtimeMetricMax(metrics, "quic_poll_recv_short_frame_process_max_ns"),
            runtimeMetricMax(metrics, "quic_poll_recv_short_ack_send_max_ns"),
            runtimeMetricSum(metrics, "quic_poll_overrun_total"),
        },
    );
    std.debug.print(
        "high-concurrency QUIC E2E runtime_metrics storage merge_tuple_acquired={d} merge_tuple_wait_ns_total={d} merge_tuple_hold_ns_total={d} merge_tuple_max_wait_ns={d} merge_tuple_max_hold_ns={d} rwlock_shared_wait_ns_total={d} rwlock_shared_hold_ns_total={d} rwlock_shared_hold_snapshot_ns_total={d} rwlock_shared_hold_bulk_merge_ns_total={d}\n",
        .{
            runtimeMetricSum(metrics, "mg_merge_tuple_lock_acquired_total"),
            runtimeMetricSum(metrics, "mg_merge_tuple_lock_wait_ns_total"),
            runtimeMetricSum(metrics, "mg_merge_tuple_lock_hold_ns_total"),
            runtimeMetricMax(metrics, "mg_merge_tuple_lock_max_wait_ns_observed"),
            runtimeMetricMax(metrics, "mg_merge_tuple_lock_max_hold_ns_observed"),
            runtimeMetricSum(metrics, "mg_rwlock_shared_wait_ns_total"),
            runtimeMetricSum(metrics, "mg_rwlock_shared_hold_ns_total"),
            runtimeMetricSum(metrics, "mg_rwlock_shared_hold_snapshot_ns_total"),
            runtimeMetricSum(metrics, "mg_rwlock_shared_hold_bulk_merge_ns_total"),
        },
    );
    std.debug.print(
        "high-concurrency QUIC E2E runtime_metrics coordinator apply_batches={d} apply_ops={d} apply_errors={d} submit_calls={d} submit_total_ns_total={d} submit_total_max_ns={d} submit_enqueue_ns_total={d} submit_enqueue_max_ns={d} submit_wait_ns_total={d} submit_wait_max_ns={d} queue_wait_ns_total={d} queue_wait_max_ns={d} queue_depth_max={d} coalesce_waits={d} coalesce_wait_ns_total={d} coalesce_wait_max_ns={d} apply_batch_ns_total={d} apply_batch_max_ns={d} apply_begin_txn_ns_total={d} apply_begin_txn_max_ns={d} apply_ops_loop_ns_total={d} apply_ops_loop_max_ns={d} apply_commit_ns_total={d} apply_commit_max_ns={d} apply_wake_ns_total={d} apply_wake_max_ns={d}\n",
        .{
            runtimeMetricSum(metrics, "coord_apply_batches_total"),
            runtimeMetricSum(metrics, "coord_apply_ops_total"),
            runtimeMetricSum(metrics, "coord_apply_errors_total"),
            runtimeMetricSum(metrics, "coord_submit_calls_total"),
            runtimeMetricSum(metrics, "coord_submit_total_ns_total"),
            runtimeMetricMax(metrics, "coord_submit_total_max_ns"),
            runtimeMetricSum(metrics, "coord_submit_enqueue_ns_total"),
            runtimeMetricMax(metrics, "coord_submit_enqueue_max_ns"),
            runtimeMetricSum(metrics, "coord_submit_wait_ns_total"),
            runtimeMetricMax(metrics, "coord_submit_wait_max_ns"),
            runtimeMetricSum(metrics, "coord_queue_wait_ns_total"),
            runtimeMetricMax(metrics, "coord_queue_wait_max_ns"),
            runtimeMetricMax(metrics, "coord_queue_depth_max"),
            runtimeMetricSum(metrics, "coord_coalesce_waits_total"),
            runtimeMetricSum(metrics, "coord_coalesce_wait_ns_total"),
            runtimeMetricMax(metrics, "coord_coalesce_wait_max_ns"),
            runtimeMetricSum(metrics, "coord_apply_batch_ns_total"),
            runtimeMetricMax(metrics, "coord_apply_batch_max_ns"),
            runtimeMetricSum(metrics, "coord_apply_begin_txn_ns_total"),
            runtimeMetricMax(metrics, "coord_apply_begin_txn_max_ns"),
            runtimeMetricSum(metrics, "coord_apply_ops_loop_ns_total"),
            runtimeMetricMax(metrics, "coord_apply_ops_loop_max_ns"),
            runtimeMetricSum(metrics, "coord_apply_commit_ns_total"),
            runtimeMetricMax(metrics, "coord_apply_commit_max_ns"),
            runtimeMetricSum(metrics, "coord_apply_wake_ns_total"),
            runtimeMetricMax(metrics, "coord_apply_wake_max_ns"),
        },
    );
}

fn stopServerGracefully(server: *util.ServerHandle, timeout_ns: u64) void {
    const pid = server.child.id orelse {
        server.deinit();
        return;
    };
    std.posix.kill(pid, .TERM) catch {};
    const deadline_ns = monoNs() +| timeout_ns;
    while (monoNs() < deadline_ns) {
        var status: u32 = 0;
        const rc = std.os.linux.waitpid(pid, &status, std.os.linux.W.NOHANG);
        const signed: isize = @bitCast(rc);
        if (signed == @as(isize, @intCast(pid))) {
            server.child.id = null;
            break;
        }
        if (signed < 0) break;
        sleepNs(50 * std.time.ns_per_ms);
    }
    server.deinit();
}

fn executeQuery(
    allocator: std.mem.Allocator,
    client: *util.QuicProtoClient,
    query: []const u8,
    timeout_secs: u32,
) !util.ExecResult {
    var res = try client.executeAndCollectWithTimeout(
        allocator,
        query,
        util.emptyParams(),
        128,
        timeout_secs,
    );
    errdefer res.deinit(allocator);
    try expectNoQueryError(&res);
    return res;
}

fn queryCountWithClient(
    allocator: std.mem.Allocator,
    client: *util.QuicProtoClient,
    query: []const u8,
    timeout_secs: u32,
) !i64 {
    var res = try executeQuery(allocator, client, query, timeout_secs);
    defer res.deinit(allocator);
    return try firstInt(&res);
}

fn queryCountWithFreshClient(
    allocator: std.mem.Allocator,
    addr: []const u8,
    timeout_secs: u32,
    query: []const u8,
) !i64 {
    var client = try connectAndHelloWithRetry(
        allocator,
        addr,
        3,
        default_connect_backoff_ms,
        default_handshake_timeout_secs,
        default_hello_timeout_ms,
        null,
        null,
    );
    defer client.deinit();
    return try queryCountWithClient(allocator, &client, query, timeout_secs);
}

fn verifyGraphIsolation(
    allocator: std.mem.Allocator,
    addr: []const u8,
    port: u16,
    timeout_secs: u32,
) !void {
    var client = try connectAndHelloWithRetry(
        allocator,
        addr,
        3,
        default_connect_backoff_ms,
        default_handshake_timeout_secs,
        default_hello_timeout_ms,
        null,
        null,
    );
    defer client.deinit();

    const graph_name = try std.fmt.allocPrint(allocator, "geode_hc_iso_{d}", .{port});
    defer allocator.free(graph_name);
    const create_graph = try std.fmt.allocPrint(allocator, "CREATE GRAPH IF NOT EXISTS {s} ANY", .{graph_name});
    defer allocator.free(create_graph);
    var create_res = try executeQuery(allocator, &client, create_graph, timeout_secs);
    create_res.deinit(allocator);

    const use_graph = try std.fmt.allocPrint(allocator, "USE GRAPH {s}", .{graph_name});
    defer allocator.free(use_graph);
    var use_res = try executeQuery(allocator, &client, use_graph, timeout_secs);
    use_res.deinit(allocator);

    const isolated_count = try queryCountWithClient(
        allocator,
        &client,
        "MATCH (n:HCParallel) RETURN count(n) AS c",
        timeout_secs,
    );
    if (isolated_count != 0) {
        std.debug.print(
            "high-concurrency QUIC E2E graph isolation failure graph={s} hc_parallel_count={d}\n",
            .{ graph_name, isolated_count },
        );
        return error.GraphIsolationFailed;
    }
}

fn verifyRestartRecovery(
    allocator: std.mem.Allocator,
    addr: []const u8,
    port: u16,
    data_dir: []const u8,
    max_connections_arg: []const u8,
    server_env: []const []const u8,
    timeout_secs: u32,
    expected_mutations: u32,
) !void {
    const restart_addr = try allocator.dupe(u8, addr);
    var restart_addr_owned = true;
    errdefer if (restart_addr_owned) allocator.free(restart_addr);

    const restart_args = &[_][]const u8{
        "./zig-out/bin/geode",
        "serve",
        "--listen",
        restart_addr,
        "--data-dir",
        data_dir,
        "--max-connections",
        max_connections_arg,
    };
    var restarted = try util.spawnServer(allocator, restart_args, server_env);
    restarted.port = port;
    restarted.addr = restart_addr;
    restart_addr_owned = false;
    defer restarted.deinit();

    try util.waitForServerReady(allocator, restart_addr, 60000);
    const recovered_mutations = try queryCountWithFreshClient(
        allocator,
        restart_addr,
        timeout_secs,
        "MATCH (n:HCParallel) RETURN count(n) AS c",
    );
    if (recovered_mutations < @as(i64, @intCast(expected_mutations))) {
        std.debug.print(
            "high-concurrency QUIC E2E restart recovery failure recovered_mutations={d} expected_at_least={d}\n",
            .{ recovered_mutations, expected_mutations },
        );
        return error.RestartRecoveryFailed;
    }
}

fn waitForClientRelease(ctx: *WorkerCtx) void {
    while (!ctx.release_clients.load(.acquire)) {
        const observed = ctx.release_generation.load(.acquire);
        if (ctx.release_clients.load(.acquire)) break;
        const io = std.Io.Threaded.global_single_threaded.io();
        const timeout: std.Io.Timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromNanoseconds(100 * std.time.ns_per_ms),
            .clock = .awake,
        } };
        io.futexWaitTimeout(u32, &ctx.release_generation.raw, observed, timeout) catch {};
    }
}

fn releaseAllClients(release_clients: *std.atomic.Value(bool), release_generation: *std.atomic.Value(u32)) void {
    release_clients.store(true, .release);
    _ = release_generation.fetchAdd(1, .acq_rel);
    std.Io.Threaded.global_single_threaded.io().futexWake(u32, &release_generation.raw, std.math.maxInt(u32));
}

fn wakeWorkloadStart(
    start: *std.atomic.Value(bool),
    start_generation: *std.atomic.Value(u32),
    worker_count: u32,
    request_stagger_us: u32,
) void {
    start.store(true, .release);
    _ = start_generation.fetchAdd(1, .acq_rel);
    const io = std.Io.Threaded.global_single_threaded.io();

    // CANARY: REQ=REQ-QUIC-HC-145; FEATURE="High-Concurrency Test Harness"; ASPECT=BatchedStartBarrierWake; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-28
    //
    // The harness runs thousands of clients in the same process as the test
    // driver. Waking all client threads on one futex tick creates a local
    // scheduler storm before the configured request stagger can shape offered
    // load. Batch only the wakeup; each worker still sleeps according to
    // `GEODE_HC_REQUEST_STAGGER_US`, so the measured request rate is unchanged.
    if (worker_count >= 1024 and request_stagger_us != 0) {
        var remaining = worker_count;
        while (remaining > 0) {
            const wake_count = @min(remaining, @as(u32, 64));
            io.futexWake(u32, &start_generation.raw, wake_count);
            remaining -= wake_count;
            if (remaining != 0) sleepNs(250 * std.time.ns_per_us);
        }
    } else {
        io.futexWake(u32, &start_generation.raw, std.math.maxInt(u32));
    }
}

fn workerRun(ctx: *WorkerCtx) void {
    const allocator = std.heap.smp_allocator;

    // CANARY: REQ=REQ-QUIC-HC-019; FEATURE="QUIC High-Concurrency Setup"; ASPECT=ConnectHelloRetry; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-26
    //
    // The measured workload starts only after every worker is authenticated.
    // Retry transient handshake/HELLO setup misses so a single simultaneous
    // fan-out blip does not hide steady-state query contention regressions.
    if (ctx.connect_stagger_us != 0) {
        sleepNs(@as(u64, ctx.connect_stagger_us) * @as(u64, ctx.worker_id) * std.time.ns_per_us);
    }
    var client = connectAndHelloWithRetry(
        allocator,
        ctx.addr,
        ctx.connect_attempts,
        ctx.connect_backoff_ms,
        ctx.handshake_timeout_secs,
        ctx.hello_timeout_ms,
        ctx.counters,
        ctx.abort_setup,
    ) catch |err| {
        if (ctx.abort_setup.load(.acquire)) return;
        recordSetupFailure(ctx.counters, "worker={d} connect/hello err={}", .{ ctx.worker_id, err });
        return;
    };
    client.post_write_poll = ctx.post_write_poll;
    defer client.deinit();

    _ = ctx.counters.ready.fetchAdd(1, .acq_rel);
    while (!ctx.start.load(.acquire)) {
        if (ctx.abort_setup.load(.acquire)) return;
        const observed = ctx.start_generation.load(.acquire);
        if (ctx.start.load(.acquire) or ctx.abort_setup.load(.acquire)) break;
        const io = std.Io.Threaded.global_single_threaded.io();
        const timeout: std.Io.Timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromNanoseconds(100 * std.time.ns_per_ms),
            .clock = .awake,
        } };
        io.futexWaitTimeout(u32, &ctx.start_generation.raw, observed, timeout) catch {};
    }
    if (ctx.abort_setup.load(.acquire)) return;
    if (ctx.request_stagger_us != 0) {
        sleepNs(@as(u64, ctx.request_stagger_us) * @as(u64, ctx.worker_id) * std.time.ns_per_us);
    }

    var query_buf: [256]u8 = undefined;
    for (0..ctx.ops_per_worker) |op| {
        const is_mutation = ctx.mutation_stride != 0 and ((op + ctx.worker_id) % ctx.mutation_stride) == 0;
        const query = if (is_mutation)
            std.fmt.bufPrint(
                &query_buf,
                "MERGE (:HCParallel {{worker: {d}, seq: {d}}})",
                .{ ctx.worker_id, op },
            ) catch |err| {
                recordOperationFailure(ctx.counters, is_mutation, "worker={d} op={d} format err={}", .{ ctx.worker_id, op, err });
                return;
            }
        else
            ctx.read_query;

        _ = ctx.counters.ops_started.fetchAdd(1, .acq_rel);
        var exec_attempt: u32 = 0;
        var last_err: anyerror = error.Timeout;
        const op_start_ns = monoNs();
        var res_opt: ?util.ExecResult = null;
        while (exec_attempt <= ctx.execute_retries) : (exec_attempt += 1) {
            _ = ctx.counters.execute_attempts.fetchAdd(1, .acq_rel);
            var timing = util.QuicProtoClient.ExecTiming{};
            var timing_recorded = false;
            res_opt = client.executeAndCollectWithTimeoutTiming(
                allocator,
                query,
                util.emptyParams(),
                128,
                ctx.execute_timeout_secs,
                &timing,
            ) catch |err| retry_blk: {
                recordExecTiming(ctx, &timing, op);
                timing_recorded = true;
                last_err = err;
                if (exec_attempt >= ctx.execute_retries) break :retry_blk null;
                _ = ctx.counters.execute_retries.fetchAdd(1, .acq_rel);
                const retry_client = connectAndHelloWithRetry(
                    allocator,
                    ctx.addr,
                    ctx.connect_attempts,
                    ctx.connect_backoff_ms,
                    ctx.handshake_timeout_secs,
                    ctx.hello_timeout_ms,
                    null,
                    null,
                ) catch |connect_err| {
                    last_err = connect_err;
                    break :retry_blk null;
                };
                client.deinit();
                client = retry_client;
                client.post_write_poll = ctx.post_write_poll;
                _ = ctx.counters.execute_reconnects.fetchAdd(1, .acq_rel);
                continue;
            };
            if (!timing_recorded) recordExecTiming(ctx, &timing, op);
            if (res_opt != null) break;
        }
        var res = res_opt orelse {
            if (ctx.client_diagnostics) client.dumpTransportDiagnostics(ctx.worker_id, op);
            recordOperationFailure(ctx.counters, is_mutation, "worker={d} op={d} mutation={} execute err={}", .{ ctx.worker_id, op, is_mutation, last_err });
            continue;
        };
        const op_latency_ns = monoNs() -| op_start_ns;
        recordMaxLatency(ctx.counters, op_latency_ns);
        recordLatencySample(ctx, op_latency_ns);
        defer res.deinit(allocator);

        expectNoQueryError(&res) catch |err| {
            recordOperationFailure(ctx.counters, is_mutation, "worker={d} op={d} mutation={} result err={}", .{ ctx.worker_id, op, is_mutation, err });
            continue;
        };
        _ = ctx.counters.ok.fetchAdd(1, .acq_rel);
        if (op == 0) {
            _ = ctx.counters.first_op_ok.fetchAdd(1, .acq_rel);
            _ = ctx.counters.first_op_latency_ns.fetchAdd(op_latency_ns, .acq_rel);
        } else {
            _ = ctx.counters.followup_op_ok.fetchAdd(1, .acq_rel);
            _ = ctx.counters.followup_op_latency_ns.fetchAdd(op_latency_ns, .acq_rel);
        }
        if (is_mutation) {
            _ = ctx.counters.mutation_ok.fetchAdd(1, .acq_rel);
            _ = ctx.counters.mutation_latency_ns.fetchAdd(op_latency_ns, .acq_rel);
        } else {
            _ = ctx.counters.read_ok.fetchAdd(1, .acq_rel);
            _ = ctx.counters.read_latency_ns.fetchAdd(op_latency_ns, .acq_rel);
        }
    }

    // CANARY: REQ=REQ-QUIC-HC-099; FEATURE="QUIC High-Concurrency Requests"; ASPECT=InWorkloadMutationVerifier; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-06-11
    //
    // Keep all workload clients alive until the designated verifier has checked
    // mutation visibility over an already-authenticated connection. This avoids
    // turning the correctness assertion into a separate post-burst handshake
    // test dominated by 1024 simultaneous client closes.
    if (ctx.verify_after_workload and ctx.mutation_stride != 0) {
        while (ctx.counters.ok.load(.acquire) + ctx.counters.failed.load(.acquire) < ctx.expected_ops) {
            sleepNs(10 * std.time.ns_per_ms);
        }
        if (ctx.counters.mutation_ok.load(.acquire) != 0) {
            var count_res = client.executeAndCollectWithTimeout(
                allocator,
                "MATCH (n:HCParallel) RETURN count(n) AS c",
                util.emptyParams(),
                128,
                ctx.execute_timeout_secs,
            ) catch |err| {
                ctx.counters.verify_failed.store(1, .release);
                recordFailure(ctx.counters, "verifier execute err={}", .{err});
                ctx.counters.verify_done.store(1, .release);
                std.Io.Threaded.global_single_threaded.io().futexWake(u32, &ctx.counters.verify_done.raw, 1);
                waitForClientRelease(ctx);
                return;
            };
            defer count_res.deinit(allocator);
            expectNoQueryError(&count_res) catch |err| {
                ctx.counters.verify_failed.store(1, .release);
                recordFailure(ctx.counters, "verifier result err={}", .{err});
                ctx.counters.verify_done.store(1, .release);
                std.Io.Threaded.global_single_threaded.io().futexWake(u32, &ctx.counters.verify_done.raw, 1);
                waitForClientRelease(ctx);
                return;
            };

            const observed_mutations = firstInt(&count_res) catch |err| {
                ctx.counters.verify_failed.store(1, .release);
                recordFailure(ctx.counters, "verifier count decode err={}", .{err});
                ctx.counters.verify_done.store(1, .release);
                std.Io.Threaded.global_single_threaded.io().futexWake(u32, &ctx.counters.verify_done.raw, 1);
                waitForClientRelease(ctx);
                return;
            };
            const expected_mutations: i64 = @intCast(ctx.counters.mutation_ok.load(.acquire));
            if (observed_mutations < expected_mutations) {
                ctx.counters.verify_failed.store(1, .release);
                recordFailure(ctx.counters, "mutations={d} expected_at_least={d}", .{ observed_mutations, expected_mutations });
            }
        }
        ctx.counters.verify_done.store(1, .release);
        std.Io.Threaded.global_single_threaded.io().futexWake(u32, &ctx.counters.verify_done.raw, 1);
    }

    waitForClientRelease(ctx);
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    // CANARY: REQ=REQ-QUIC-HC-170; FEATURE="High-Concurrency Test Harness"; ASPECT=ObjectiveGateDefaults; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-06-11
    //
    // The objective gate is deliberately opt-in so the default build step stays
    // cheap. When enabled it turns the harness into the enterprise target
    // runner: 16384 clients, 8 ops each, at least 25% mutations, 99.95%
    // completion, zero first-response timeouts, 10k QPS, percentile gates,
    // graph-isolation verification, restart recovery, and server RSS bounds.
    const objective_gate = envBool("GEODE_HC_OBJECTIVE_GATE", false);
    const default_worker_count_for_run = if (objective_gate) objective_worker_count else default_worker_count;
    const default_ops_per_worker_for_run = if (objective_gate) objective_ops_per_worker else default_ops_per_worker;
    const default_mutation_stride_for_run = if (objective_gate) objective_mutation_stride else default_mutation_stride;
    const worker_count = @max(@as(u32, 1), envU32("GEODE_HC_WORKERS", default_worker_count_for_run));
    // CANARY: REQ=REQ-QUIC-HC-126; FEATURE="High-Concurrency Test Harness"; ASPECT=FanoutScaledServerDefaults; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-28
    //
    // Debug mode keeps the default 32-worker smoke run cheap and
    // deterministic, but an explicit 128+ worker fan-out needs the same server
    // poller and connection-handler headroom that production/release runs use.
    // Scale only the harness-provided child-server defaults here; every knob
    // remains overridable through GEODE_HC_*.
    const high_fanout_setup = worker_count >= high_fanout_worker_threshold;
    const default_connect_attempts_for_run: u32 = if (high_fanout_setup) @max(@as(u32, default_connect_attempts), 16) else default_connect_attempts;
    const default_hello_timeout_ms_for_run: u32 = if (high_fanout_setup) @max(@as(u32, default_hello_timeout_ms), 15_000) else default_hello_timeout_ms;
    const default_setup_timeout_secs_for_run: u32 = if (high_fanout_setup) @max(@as(u32, default_setup_timeout_secs), 90) else default_setup_timeout_secs;
    const default_poll_workers_for_run: u32 = if (high_fanout_setup) highFanoutPollWorkerDefault(worker_count) else default_poll_worker_count;
    const default_connection_workers_for_run = if (high_fanout_setup) highFanoutConnectionWorkerDefault(worker_count) else default_connection_worker_count;
    const default_connection_admission_threads_for_run = if (high_fanout_setup) @min(@max(worker_count, @as(u32, 1024)), @as(u32, 4096)) else @as(u32, 1024);
    const default_cooperative_first_stream_workers_for_run = if (high_fanout_setup) highFanoutCooperativeFirstStreamWorkerDefault(worker_count) else default_cooperative_first_stream_worker_count;
    const default_group_commit_coalesce_us_for_run = if (high_fanout_setup) high_fanout_group_commit_coalesce_us else default_group_commit_coalesce_us;
    const default_mutation_admission_cap_for_run = if (high_fanout_setup) highFanoutMutationAdmissionCapDefault(worker_count) else default_mutation_admission_cap;
    const default_request_stagger_us_for_run: u32 = if (high_fanout_setup) @max(@as(u32, default_request_stagger_us), 1000) else default_request_stagger_us;
    const ops_per_worker = @max(@as(u32, 1), envU32("GEODE_HC_OPS_PER_WORKER", default_ops_per_worker_for_run));
    const mutation_stride = envU32("GEODE_HC_MUTATION_STRIDE", default_mutation_stride_for_run);
    const min_completion_ppm = @min(envU32("GEODE_HC_MIN_COMPLETION_PPM", if (objective_gate) objective_min_completion_ppm else 1_000_000), 1_000_000);
    const min_mutation_ppm = @min(envU32("GEODE_HC_MIN_MUTATION_PPM", if (objective_gate) objective_min_mutation_ppm else 0), 1_000_000);
    const require_zero_first_response_timeouts = envBool("GEODE_HC_REQUIRE_ZERO_FIRST_RESPONSE_TIMEOUTS", objective_gate);
    const min_qps = envU32("GEODE_HC_MIN_QPS", if (objective_gate) objective_min_qps else 0);
    const p50_max_ms = envU32("GEODE_HC_P50_MAX_MS", if (objective_gate) objective_p50_max_ms else 0);
    const p95_max_ms = envU32("GEODE_HC_P95_MAX_MS", if (objective_gate) objective_p95_max_ms else 0);
    const p99_max_ms = envU32("GEODE_HC_P99_MAX_MS", if (objective_gate) objective_p99_max_ms else 0);
    const p999_max_ms = envU32("GEODE_HC_P999_MAX_MS", if (objective_gate) objective_p999_max_ms else 0);
    const graph_isolation_verify = envBool("GEODE_HC_GRAPH_ISOLATION_VERIFY", objective_gate);
    const restart_verify = envBool("GEODE_HC_RESTART_VERIFY", objective_gate);
    const memory_growth_max_kb = envU32("GEODE_HC_MEMORY_GROWTH_MAX_KB", if (objective_gate) objective_memory_growth_max_kb else 0);
    const connect_attempts = @max(@as(u32, 1), envU32("GEODE_HC_CONNECT_ATTEMPTS", default_connect_attempts_for_run));
    const connect_backoff_ms = @max(@as(u32, 1), envU32("GEODE_HC_CONNECT_BACKOFF_MS", default_connect_backoff_ms));
    const handshake_timeout_secs = @max(@as(u32, 1), envU32("GEODE_HC_HANDSHAKE_TIMEOUT_SECS", default_handshake_timeout_secs));
    // CANARY: REQ=REQ-QUIC-HC-101; FEATURE="QUIC High-Concurrency Setup"; ASPECT=BoundedHelloRetryWindow; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-06-11
    //
    // A 30s HELLO read deadline turns one lost server response during fan-out
    // into a 30s setup plateau before connectAndHelloWithRetry can open a fresh
    // connection. Keep the retry window short enough to recover quickly while
    // still above normal sub-second HELLO latency at 512+ clients.
    const hello_timeout_ms = @max(@as(u32, 1), envU32("GEODE_HC_HELLO_TIMEOUT_MS", default_hello_timeout_ms_for_run));
    const setup_timeout_secs = @max(@as(u32, 1), envU32("GEODE_HC_SETUP_TIMEOUT_SECS", default_setup_timeout_secs_for_run));
    const setup_grace_secs = envU32("GEODE_HC_SETUP_GRACE_SECS", 30);
    // CANARY: REQ=REQ-QUIC-HC-131; FEATURE="QUIC High-Concurrency Setup"; ASPECT=HardSetupTimeoutDiagnostics; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-06-11
    //
    // The soft setup timeout remains progress-sensitive so legitimate 512+
    // connection tails are not aborted while HELLOs are still completing.
    // Keep a separate hard cap so retry churn cannot run silently until the
    // outer shell timeout kills the harness before it prints counters.
    const default_setup_hard_timeout_secs = setup_timeout_secs + setup_grace_secs;
    const setup_hard_timeout_secs = @max(setup_timeout_secs, envU32("GEODE_HC_SETUP_HARD_TIMEOUT_SECS", default_setup_hard_timeout_secs));
    const connect_stagger_us = envU32("GEODE_HC_CONNECT_STAGGER_US", 0);
    // CANARY: REQ=REQ-QUIC-HC-042; FEATURE="QUIC High-Concurrency Requests"; ASPECT=RequestBurstShaping; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-06-11
    // Release builds shape a target offered load across already-open parallel
    // connections by default. Setting GEODE_HC_REQUEST_STAGGER_US=0 keeps the
    // same-time microburst mode available when explicitly testing kernel queue
    // and packet recovery behavior.
    const request_stagger_us = envU32("GEODE_HC_REQUEST_STAGGER_US", default_request_stagger_us_for_run);
    const execute_timeout_secs = @max(@as(u32, 1), envU32("GEODE_HC_EXEC_TIMEOUT_SECS", default_execute_timeout_secs));
    const execute_retries = envU32("GEODE_HC_EXEC_RETRIES", default_execute_retries);
    // CANARY: REQ=REQ-QUIC-HC-085; FEATURE="QUIC High-Concurrency Requests"; ASPECT=HarnessConnectionHeadroom; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-06-11
    //
    // Connection setup stress intentionally permits retries. Size the server
    // logical connection cap above the worker count so retry churn does not
    // masquerade as a transport deadlock once all workers have opened at
    // least one connection.
    const default_max_connections = std.math.mul(u32, worker_count, 4) catch std.math.maxInt(u32);
    const max_connections = @max(
        @as(u32, 1024),
        envU32("GEODE_HC_MAX_CONNECTIONS", default_max_connections),
    );
    const capture_server_logs = envBool("GEODE_HC_CAPTURE_SERVER_LOGS", false);
    const metrics_scrape = envBool("GEODE_HC_METRICS_SCRAPE", false);
    const client_diagnostics = envBool("GEODE_HC_CLIENT_DIAGNOSTICS", false);
    const cooperative_first_streams = envBool("GEODE_HC_COOPERATIVE_FIRST_STREAMS", true);
    // CANARY: REQ=REQ-QUIC-HC-161; FEATURE="High-Concurrency Diagnostics"; ASPECT=ShortHeaderTimingHarness; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-06-11
    //
    // Upstream QUIC already exposes detailed short-header receive subphase
    // timing behind GEODE_QUIC_SHORT_HEADER_TIMING. Surface that flag through
    // the E2E harness so ceiling probes can split endpoint-map, RX-serial,
    // decrypt, frame-processing, and ACK-send cost without adding Geode-side
    // per-packet instrumentation.
    const short_header_timing = envBool("GEODE_HC_SHORT_HEADER_TIMING", false);
    // CANARY: REQ=REQ-QUIC-HC-156; FEATURE="High-Concurrency Test Client"; ASPECT=DeferredPostWriteFlush; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-06-11
    //
    // At 1024+ same-process clients, immediate post-write poll calls can
    // dominate request start cost before the server is the limiting factor.
    // Leave low-fanout behavior unchanged, but let high-fanout workers defer
    // the flush to the first response-read WouldBlock poll.
    const post_write_poll = envBool("GEODE_HC_POST_WRITE_POLL", worker_count < 1024);
    const read_query = envSlice("GEODE_HC_READ_QUERY", "MATCH (n:HCParallel) RETURN count(n) AS c");

    const port = try util.getRandomPort();
    const metrics_port = try util.getRandomPort();
    const addr = try util.formatAddr(allocator, port);
    var addr_owned = true;
    defer if (addr_owned) allocator.free(addr);

    const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/e2e-quic-hc-{d}", .{port});
    defer allocator.free(data_dir);
    const fs_io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteTree(fs_io, data_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(fs_io, data_dir);
    defer std.Io.Dir.cwd().deleteTree(fs_io, data_dir) catch {};

    util.progress("Starting server on port {d}...", .{port});
    const max_connections_arg = try std.fmt.allocPrint(allocator, "{d}", .{max_connections});
    defer allocator.free(max_connections_arg);
    // CANARY: REQ=REQ-QUIC-HC-071; FEATURE="QUIC High-Concurrency Requests"; ASPECT=HarnessFirstStreamThreadCap; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-06-11
    // Match the server's bounded first-stream owner default. Setting this to
    // max_connections recreates a same-instant thread wake storm at the request
    // barrier and hides the actual QUIC/query throughput behind scheduler
    // contention.
    const detached_first_stream_threads = envU32(
        "GEODE_HC_DETACHED_FIRST_STREAM_THREADS",
        default_detached_first_stream_threads,
    );
    const detached_first_stream_env = try std.fmt.allocPrint(
        allocator,
        "GEODE_QUIC_DETACHED_FIRST_STREAM_THREADS={d}",
        .{detached_first_stream_threads},
    );
    defer allocator.free(detached_first_stream_env);
    const max_global_stream_env = try std.fmt.allocPrint(
        allocator,
        "GEODE_QUIC_MAX_GLOBAL_STREAM_THREADS={d}",
        .{max_connections},
    );
    defer allocator.free(max_global_stream_env);
    const poll_workers = @min(
        @max(envU32("GEODE_HC_POLL_WORKERS", default_poll_workers_for_run), @as(u32, 1)),
        high_fanout_poll_worker_cap,
    );
    const poll_workers_env = try std.fmt.allocPrint(
        allocator,
        "GEODE_QUIC_POLL_WORKERS={d}",
        .{poll_workers},
    );
    defer allocator.free(poll_workers_env);
    const cooperative_first_stream_worker_count = envU32(
        "GEODE_HC_COOPERATIVE_FIRST_STREAM_WORKERS",
        default_cooperative_first_stream_workers_for_run,
    );
    const cooperative_first_stream_workers_env = try std.fmt.allocPrint(
        allocator,
        "GEODE_QUIC_COOPERATIVE_FIRST_STREAM_WORKERS={d}",
        .{cooperative_first_stream_worker_count},
    );
    defer allocator.free(cooperative_first_stream_workers_env);
    // CANARY: REQ=REQ-QUIC-HC-124; FEATURE="High-Concurrency Test Harness"; ASPECT=ConnectionWorkerHeadroom; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-06-11
    // CANARY: REQ=REQ-QUIC-HC-132; FEATURE="QUIC High-Concurrency Requests"; ASPECT=ConnectionPoolCapCompatibility; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-28
    //
    // The child server gets an explicit environment, so parent-level
    // GEODE_QUIC_CONNECTION_WORKERS does not pass through. Surface a harness
    // knob for the bounded pooled fallback, but keep it within the upstream
    // thread-pool's 64-worker limit. High-fanout HELLO admission is controlled
    // by GEODE_HC_CONNECTION_ADMISSION_THREADS below.
    const connection_workers = @min(
        @max(envU32("GEODE_HC_CONNECTION_WORKERS", default_connection_workers_for_run), @as(u32, 2)),
        @as(u32, 64),
    );
    const connection_workers_env = try std.fmt.allocPrint(
        allocator,
        "GEODE_QUIC_CONNECTION_WORKERS={d}",
        .{connection_workers},
    );
    defer allocator.free(connection_workers_env);
    const connection_admission_threads = @min(
        @max(envU32("GEODE_HC_CONNECTION_ADMISSION_THREADS", default_connection_admission_threads_for_run), @as(u32, 2)),
        @as(u32, 4096),
    );
    const connection_admission_threads_env = try std.fmt.allocPrint(
        allocator,
        "GEODE_QUIC_CONNECTION_ADMISSION_THREADS={d}",
        .{connection_admission_threads},
    );
    defer allocator.free(connection_admission_threads_env);
    const group_commit_coalesce_us = envU32("GEODE_HC_GROUP_COMMIT_COALESCE_US", default_group_commit_coalesce_us_for_run);
    const group_commit_coalesce_env = try std.fmt.allocPrint(
        allocator,
        "GEODE_GROUP_COMMIT_COALESCE_US={d}",
        .{group_commit_coalesce_us},
    );
    defer allocator.free(group_commit_coalesce_env);
    const group_commit_active_shards = envU32("GEODE_HC_GROUP_COMMIT_ACTIVE_SHARDS", default_group_commit_active_shards);
    const group_commit_active_shards_env = try std.fmt.allocPrint(
        allocator,
        "GEODE_GROUP_COMMIT_ACTIVE_SHARDS={d}",
        .{group_commit_active_shards},
    );
    defer allocator.free(group_commit_active_shards_env);
    const group_commit_enabled_value = envSlice("GEODE_HC_GROUP_COMMIT", "1");
    const group_commit_enabled_env = try std.fmt.allocPrint(
        allocator,
        "GEODE_GROUP_COMMIT={s}",
        .{group_commit_enabled_value},
    );
    defer allocator.free(group_commit_enabled_env);
    const default_group_commit_phase_metrics = if (metrics_scrape) "1" else "0";
    const group_commit_phase_metrics_value = envSlice("GEODE_HC_GROUP_COMMIT_PHASE_METRICS", default_group_commit_phase_metrics);
    const group_commit_phase_metrics_env = try std.fmt.allocPrint(
        allocator,
        "GEODE_GROUP_COMMIT_PHASE_METRICS={s}",
        .{group_commit_phase_metrics_value},
    );
    defer allocator.free(group_commit_phase_metrics_env);
    const mutation_admission_cap = envU32("GEODE_HC_MUTATION_ADMISSION_CAP", default_mutation_admission_cap_for_run);
    const mutation_admission_cap_env = try std.fmt.allocPrint(
        allocator,
        "GEODE_QUIC_MUTATION_ADMISSION_CAP={d}",
        .{mutation_admission_cap},
    );
    defer allocator.free(mutation_admission_cap_env);
    const server_hello_timeout_env = try std.fmt.allocPrint(
        allocator,
        "GEODE_QUIC_HELLO_READ_TIMEOUT_MS={d}",
        .{hello_timeout_ms},
    );
    defer allocator.free(server_hello_timeout_env);
    const metrics_port_env = try std.fmt.allocPrint(
        allocator,
        "GEODE_METRICS_PORT={d}",
        .{metrics_port},
    );
    defer allocator.free(metrics_port_env);
    const cooperative_first_streams_env: []const u8 = if (cooperative_first_streams)
        "GEODE_QUIC_COOPERATIVE_FIRST_STREAMS=1"
    else
        "GEODE_QUIC_COOPERATIVE_FIRST_STREAMS=0";
    const short_header_timing_env: []const u8 = if (short_header_timing)
        "GEODE_QUIC_SHORT_HEADER_TIMING=1"
    else
        "GEODE_QUIC_SHORT_HEADER_TIMING=0";
    const args = &[_][]const u8{
        "./zig-out/bin/geode",
        "serve",
        "--listen",
        addr,
        "--data-dir",
        data_dir,
        "--max-connections",
        max_connections_arg,
    };
    // CANARY: REQ=REQ-QUIC-HC-030; FEATURE="QUIC High-Concurrency Requests"; ASPECT=SingleStreamStressMode; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-26
    //
    // This test opens one stream per connection. Disabling the multiplexed
    // stream acceptor keeps setup pressure focused on real connection/query
    // work instead of hundreds of idle acceptor loops.
    const server_env: []const []const u8 = if (capture_server_logs and metrics_scrape)
        &.{
            "GEODE_QUIC_PASSIVE_TEARDOWN=1",
            "GEODE_QUIC_ENABLE_STREAM_MULTIPLEXING=0",
            cooperative_first_streams_env,
            short_header_timing_env,
            detached_first_stream_env,
            max_global_stream_env,
            poll_workers_env,
            cooperative_first_stream_workers_env,
            connection_workers_env,
            connection_admission_threads_env,
            group_commit_enabled_env,
            group_commit_phase_metrics_env,
            group_commit_coalesce_env,
            group_commit_active_shards_env,
            mutation_admission_cap_env,
            "GEODE_QUIC_DETACHED_CONNECTION_ADMISSION=1",
            server_hello_timeout_env,
            "GEODE_QUIC_STREAM_QUEUE_CAPACITY=8192",
            metrics_port_env,
            "GEODE_TEST_INHERIT_SERVER_STDERR=1",
        }
    else if (capture_server_logs)
        &.{
            "GEODE_QUIC_PASSIVE_TEARDOWN=1",
            "GEODE_QUIC_ENABLE_STREAM_MULTIPLEXING=0",
            cooperative_first_streams_env,
            short_header_timing_env,
            detached_first_stream_env,
            max_global_stream_env,
            poll_workers_env,
            cooperative_first_stream_workers_env,
            connection_workers_env,
            connection_admission_threads_env,
            group_commit_enabled_env,
            group_commit_phase_metrics_env,
            group_commit_coalesce_env,
            group_commit_active_shards_env,
            mutation_admission_cap_env,
            "GEODE_QUIC_DETACHED_CONNECTION_ADMISSION=1",
            server_hello_timeout_env,
            "GEODE_QUIC_STREAM_QUEUE_CAPACITY=8192",
            "GEODE_TEST_INHERIT_SERVER_STDERR=1",
        }
    else if (metrics_scrape)
        &.{
            "GEODE_QUIC_PASSIVE_TEARDOWN=1",
            "GEODE_QUIC_ENABLE_STREAM_MULTIPLEXING=0",
            cooperative_first_streams_env,
            short_header_timing_env,
            detached_first_stream_env,
            max_global_stream_env,
            poll_workers_env,
            cooperative_first_stream_workers_env,
            connection_workers_env,
            connection_admission_threads_env,
            group_commit_enabled_env,
            group_commit_phase_metrics_env,
            group_commit_coalesce_env,
            group_commit_active_shards_env,
            mutation_admission_cap_env,
            "GEODE_QUIC_DETACHED_CONNECTION_ADMISSION=1",
            server_hello_timeout_env,
            "GEODE_QUIC_STREAM_QUEUE_CAPACITY=8192",
            metrics_port_env,
        }
    else
        &.{
            "GEODE_QUIC_PASSIVE_TEARDOWN=1",
            "GEODE_QUIC_ENABLE_STREAM_MULTIPLEXING=0",
            cooperative_first_streams_env,
            short_header_timing_env,
            detached_first_stream_env,
            max_global_stream_env,
            poll_workers_env,
            cooperative_first_stream_workers_env,
            connection_workers_env,
            connection_admission_threads_env,
            group_commit_enabled_env,
            group_commit_phase_metrics_env,
            group_commit_coalesce_env,
            group_commit_active_shards_env,
            mutation_admission_cap_env,
            "GEODE_QUIC_DETACHED_CONNECTION_ADMISSION=1",
            server_hello_timeout_env,
            "GEODE_QUIC_STREAM_QUEUE_CAPACITY=8192",
        };
    var server = util.spawnServer(allocator, args, server_env) catch |err| {
        util.progress("Server spawn failed: {}", .{err});
        return err;
    };
    server.port = port;
    server.addr = addr;
    addr_owned = false;
    util.waitForServerReady(allocator, addr, 60000) catch |err| {
        server.deinit();
        util.progress("Server readiness failed: {}", .{err});
        return err;
    };
    util.progress("Server ready on {s}", .{addr});
    var server_running = true;
    defer if (server_running) server.deinit();
    const rss_start_kb = readServerRssKb(&server);

    var counters = Counters{};
    var start = std.atomic.Value(bool).init(false);
    var start_generation = std.atomic.Value(u32).init(0);
    var abort_setup = std.atomic.Value(bool).init(false);
    var release_clients = std.atomic.Value(bool).init(false);
    var release_generation = std.atomic.Value(u32).init(0);
    var workload_start_ns_atomic = std.atomic.Value(u64).init(0);
    const expected_ops = std.math.mul(u32, worker_count, ops_per_worker) catch return error.TooManyOperations;
    const op_latency_samples = try allocator.alloc(u64, expected_ops);
    defer allocator.free(op_latency_samples);
    @memset(op_latency_samples, 0);
    var op_latency_sample_index = std.atomic.Value(u32).init(0);
    const contexts = try allocator.alloc(WorkerCtx, worker_count);
    defer allocator.free(contexts);
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);

    const setup_start_ns = monoNs();
    for (contexts, 0..) |*ctx, i| {
        ctx.* = .{
            .addr = server.getAddr(),
            .worker_id = @intCast(i),
            .ops_per_worker = ops_per_worker,
            .mutation_stride = mutation_stride,
            .read_query = read_query,
            .connect_attempts = connect_attempts,
            .connect_backoff_ms = connect_backoff_ms,
            .handshake_timeout_secs = handshake_timeout_secs,
            .hello_timeout_ms = hello_timeout_ms,
            .connect_stagger_us = connect_stagger_us,
            .request_stagger_us = request_stagger_us,
            .execute_timeout_secs = execute_timeout_secs,
            .execute_retries = execute_retries,
            .post_write_poll = post_write_poll,
            .counters = &counters,
            .start = &start,
            .start_generation = &start_generation,
            .abort_setup = &abort_setup,
            .release_clients = &release_clients,
            .release_generation = &release_generation,
            .workload_start_ns = &workload_start_ns_atomic,
            .op_latency_samples_ns = op_latency_samples,
            .op_latency_sample_index = &op_latency_sample_index,
            .expected_ops = expected_ops,
            .verify_after_workload = i == 0,
            .client_diagnostics = client_diagnostics,
        };
        threads[i] = try std.Thread.spawn(.{ .stack_size = high_concurrency_worker_stack_size }, workerRun, .{ctx});
    }

    var setup_timed_out = false;
    var setup_elapsed_ns: u64 = 0;
    var last_progress_ns = setup_start_ns;
    var last_connected: u32 = 0;
    var last_hello_ok: u32 = 0;
    var last_ready: u32 = 0;
    var last_setup_report_ns = setup_start_ns;
    while (counters.ready.load(.acquire) < worker_count and counters.setup_failed.load(.acquire) == 0) {
        const now_ns = monoNs();
        setup_elapsed_ns = now_ns -| setup_start_ns;
        const connected_now = counters.connected.load(.acquire);
        const hello_now = counters.hello_ok.load(.acquire);
        const ready_now = counters.ready.load(.acquire);
        if (now_ns -| last_setup_report_ns >= 15 * std.time.ns_per_s) {
            last_setup_report_ns = now_ns;
            std.debug.print(
                "high-concurrency QUIC E2E setup progress elapsed_ms={d} connected={d} hello_ok={d} ready={d}/{d} setup_failed={d} setup_attempts={d} setup_retries={d}\n",
                .{
                    setup_elapsed_ns / std.time.ns_per_ms,
                    connected_now,
                    hello_now,
                    ready_now,
                    worker_count,
                    counters.setup_failed.load(.acquire),
                    counters.setup_attempts.load(.acquire),
                    counters.setup_retries.load(.acquire),
                },
            );
        }
        if (connected_now != last_connected or hello_now != last_hello_ok or ready_now != last_ready) {
            last_connected = connected_now;
            last_hello_ok = hello_now;
            last_ready = ready_now;
            last_progress_ns = now_ns;
        }
        if (hello_now >= worker_count) break;
        if (setup_elapsed_ns >= @as(u64, setup_hard_timeout_secs) * std.time.ns_per_s and ready_now < worker_count) {
            setup_timed_out = true;
            break;
        }
        if (setup_elapsed_ns >= @as(u64, setup_timeout_secs) * std.time.ns_per_s and ready_now < worker_count) {
            setup_timed_out = true;
            if (now_ns -| last_progress_ns >= @as(u64, setup_grace_secs) * std.time.ns_per_s) {
                break;
            }
        }
        sleepNs(250 * std.time.ns_per_us);
    }
    setup_elapsed_ns = monoNs() -| setup_start_ns;

    // CANARY: REQ=REQ-QUIC-HC-072; FEATURE="QUIC High-Concurrency Setup"; ASPECT=TimeoutEdgeReadySettle; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-06-11
    // At 512+ workers every client can authenticate before a few worker
    // threads get scheduled again to increment `ready`. Once hello_ok reaches
    // worker_count, the workers already own authenticated clients, so the start
    // barrier can be opened instead of treating unscheduled ready increments as
    // setup failures.
    var ready_after_setup = counters.ready.load(.acquire);
    var hello_after_setup = counters.hello_ok.load(.acquire);
    if (setup_timed_out and hello_after_setup < worker_count and ready_after_setup < worker_count and counters.setup_failed.load(.acquire) == 0) {
        // Use the same setup-grace envelope as the progress loop. At 512+
        // workers, scheduler latency can leave the authenticated worker's
        // `ready` increment a few seconds behind the HELLO response.
        const settle_deadline_ns = monoNs() + @as(u64, setup_grace_secs) * std.time.ns_per_s;
        while (hello_after_setup < worker_count and ready_after_setup < worker_count and counters.setup_failed.load(.acquire) == 0 and monoNs() < settle_deadline_ns) {
            sleepNs(std.time.ns_per_ms);
            hello_after_setup = counters.hello_ok.load(.acquire);
            ready_after_setup = counters.ready.load(.acquire);
        }
    }
    hello_after_setup = counters.hello_ok.load(.acquire);
    ready_after_setup = counters.ready.load(.acquire);
    const setup_authenticated = hello_after_setup >= worker_count;
    const setup_ready = ready_after_setup >= worker_count;
    const setup_timeout_failed = setup_timed_out and !setup_authenticated and !setup_ready;
    if (counters.setup_failed.load(.acquire) != 0 or setup_timeout_failed) {
        const setup_failures = counters.setup_failed.load(.acquire) + @as(u32, @intFromBool(setup_timeout_failed));
        std.debug.print(
            "high-concurrency QUIC E2E setup failures={d} ready={d}/{d} ready_after_setup={d} hello_after_setup={d} authenticated={} setup_failed_raw={d} timeout_failed={} setup_ms={d}\n",
            .{
                setup_failures,
                counters.ready.load(.acquire),
                worker_count,
                ready_after_setup,
                hello_after_setup,
                setup_authenticated,
                counters.setup_failed.load(.acquire),
                setup_timeout_failed,
                setup_elapsed_ns / std.time.ns_per_ms,
            },
        );
        std.debug.print(
            "high-concurrency QUIC E2E setup phases connected={d} hello_ok={d} ops_started={d} ok={d}\n",
            .{
                counters.connected.load(.acquire),
                counters.hello_ok.load(.acquire),
                counters.ops_started.load(.acquire),
                counters.ok.load(.acquire),
            },
        );
        std.debug.print(
            "high-concurrency QUIC E2E retry phases setup_attempts={d} setup_retries={d} execute_attempts={d} execute_retries={d} execute_reconnects={d}\n",
            .{
                counters.setup_attempts.load(.acquire),
                counters.setup_retries.load(.acquire),
                counters.execute_attempts.load(.acquire),
                counters.execute_retries.load(.acquire),
                counters.execute_reconnects.load(.acquire),
            },
        );
        abort_setup.store(true, .release);
        start.store(true, .release);
        _ = start_generation.fetchAdd(1, .acq_rel);
        std.Io.Threaded.global_single_threaded.io().futexWake(u32, &start_generation.raw, std.math.maxInt(u32));
        for (threads) |*thread| thread.join();
        return error.SetupFailures;
    }

    const workload_start_ns = monoNs();
    workload_start_ns_atomic.store(workload_start_ns, .release);
    wakeWorkloadStart(&start, &start_generation, worker_count, request_stagger_us);

    const workload_deadline_ns = workload_start_ns + (@as(u64, execute_timeout_secs) + 30) * @as(u64, @max(ops_per_worker, 1)) * std.time.ns_per_s;
    while (counters.ok.load(.acquire) + counters.failed.load(.acquire) < expected_ops and monoNs() < workload_deadline_ns) {
        sleepNs(10 * std.time.ns_per_ms);
    }
    const workload_elapsed_ns = monoNs() -| workload_start_ns;

    const observed_ops = counters.ok.load(.acquire);
    var failures = counters.failed.load(.acquire);
    if (failures != 0 or observed_ops != expected_ops) {
        std.debug.print(
            "high-concurrency QUIC E2E incomplete ok={d} expected={d} failed={d} read_failed={d} mutation_failed={d} ops_started={d} elapsed_ms={d} execute_attempts={d} execute_retries={d} execute_reconnects={d}\n",
            .{
                observed_ops,
                expected_ops,
                failures,
                counters.read_failed.load(.acquire),
                counters.mutation_failed.load(.acquire),
                counters.ops_started.load(.acquire),
                workload_elapsed_ns / std.time.ns_per_ms,
                counters.execute_attempts.load(.acquire),
                counters.execute_retries.load(.acquire),
                counters.execute_reconnects.load(.acquire),
            },
        );
    }
    const qps_x100: u64 = if (workload_elapsed_ns == 0) 0 else (@as(u64, observed_ops) * std.time.ns_per_s * 100) / workload_elapsed_ns;
    const observed_reads = counters.read_ok.load(.acquire);
    const observed_mutations_ok = counters.mutation_ok.load(.acquire);
    const observed_first_ops = counters.first_op_ok.load(.acquire);
    const observed_followup_ops = counters.followup_op_ok.load(.acquire);
    const read_avg_ms_x100: u64 = if (observed_reads == 0) 0 else counters.read_latency_ns.load(.acquire) / @as(u64, observed_reads) / (std.time.ns_per_ms / 100);
    const mutation_avg_ms_x100: u64 = if (observed_mutations_ok == 0) 0 else counters.mutation_latency_ns.load(.acquire) / @as(u64, observed_mutations_ok) / (std.time.ns_per_ms / 100);
    const first_op_avg_ms_x100: u64 = if (observed_first_ops == 0) 0 else counters.first_op_latency_ns.load(.acquire) / @as(u64, observed_first_ops) / (std.time.ns_per_ms / 100);
    const followup_op_avg_ms_x100: u64 = if (observed_followup_ops == 0) 0 else counters.followup_op_latency_ns.load(.acquire) / @as(u64, observed_followup_ops) / (std.time.ns_per_ms / 100);
    const max_ms_x100 = counters.max_latency_ns.load(.acquire) / (std.time.ns_per_ms / 100);
    // CANARY: REQ=REQ-QUIC-HC-103; FEATURE="QUIC High-Concurrency Requests"; ASPECT=RetryTailRegressionCounters; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-06-11
    // Include user-visible operation latency, setup retry churn, and execute
    // retry churn in the summary so high-fanout runs can distinguish transport
    // loss tails from slow successful server-side query processing.
    std.debug.print(
        "high-concurrency QUIC E2E workload workers={d} ops_per_worker={d} mutation_stride={d} ops={d} reads={d} mutations={d} setup_ms={d} elapsed_ms={d} qps={d}.{d:0>2} avg_read_ms={d}.{d:0>2} avg_mut_ms={d}.{d:0>2} avg_first_op_ms={d}.{d:0>2} avg_followup_op_ms={d}.{d:0>2} max_ms={d}.{d:0>2} setup_attempts={d} setup_retries={d} execute_attempts={d} execute_retries={d} execute_reconnects={d}\n",
        .{
            worker_count,
            ops_per_worker,
            mutation_stride,
            observed_ops,
            observed_reads,
            observed_mutations_ok,
            setup_elapsed_ns / std.time.ns_per_ms,
            workload_elapsed_ns / std.time.ns_per_ms,
            qps_x100 / 100,
            qps_x100 % 100,
            read_avg_ms_x100 / 100,
            read_avg_ms_x100 % 100,
            mutation_avg_ms_x100 / 100,
            mutation_avg_ms_x100 % 100,
            first_op_avg_ms_x100 / 100,
            first_op_avg_ms_x100 % 100,
            followup_op_avg_ms_x100 / 100,
            followup_op_avg_ms_x100 % 100,
            max_ms_x100 / 100,
            max_ms_x100 % 100,
            counters.setup_attempts.load(.acquire),
            counters.setup_retries.load(.acquire),
            counters.execute_attempts.load(.acquire),
            counters.execute_retries.load(.acquire),
            counters.execute_reconnects.load(.acquire),
        },
    );
    printTimingSummary(&counters);
    const percentiles = computeLatencyPercentiles(op_latency_samples, op_latency_sample_index.load(.acquire));
    printLatencyPercentiles(percentiles);

    if (observed_mutations_ok != 0) {
        const verify_deadline_ns = monoNs() + (@as(u64, execute_timeout_secs) + 30) * std.time.ns_per_s;
        while (counters.verify_done.load(.acquire) == 0 and monoNs() < verify_deadline_ns) {
            const observed = counters.verify_done.load(.acquire);
            if (observed != 0) break;
            const io = std.Io.Threaded.global_single_threaded.io();
            const timeout: std.Io.Timeout = .{ .duration = .{
                .raw = std.Io.Duration.fromNanoseconds(100 * std.time.ns_per_ms),
                .clock = .awake,
            } };
            io.futexWaitTimeout(u32, &counters.verify_done.raw, observed, timeout) catch {};
        }
        if (counters.verify_done.load(.acquire) == 0 or counters.verify_failed.load(.acquire) != 0) {
            _ = counters.failed.fetchAdd(1, .acq_rel);
        }
    }

    releaseAllClients(&release_clients, &release_generation);
    for (threads) |*thread| thread.join();
    sleepNs(100 * std.time.ns_per_ms);
    const rss_after_clients_kb = readServerRssKb(&server);
    const rss_delta_kb = rss_after_clients_kb -| rss_start_kb;
    std.debug.print(
        "high-concurrency QUIC E2E memory rss_start_kb={d} rss_after_clients_kb={d} rss_delta_kb={d} rss_limit_kb={d}\n",
        .{ rss_start_kb, rss_after_clients_kb, rss_delta_kb, memory_growth_max_kb },
    );
    if (metrics_scrape) {
        printRuntimeMetricsSnapshot(allocator, metrics_port);
    }

    if (graph_isolation_verify) {
        try verifyGraphIsolation(allocator, server.getAddr(), port, execute_timeout_secs);
        std.debug.print("high-concurrency QUIC E2E graph_isolation=ok\n", .{});
    }

    if (restart_verify) {
        const restart_addr = try allocator.dupe(u8, server.getAddr());
        defer allocator.free(restart_addr);
        stopServerGracefully(&server, 30 * std.time.ns_per_s);
        server_running = false;
        sleepNs(100 * std.time.ns_per_ms);
        try verifyRestartRecovery(
            allocator,
            restart_addr,
            port,
            data_dir,
            max_connections_arg,
            server_env,
            execute_timeout_secs,
            observed_mutations_ok,
        );
        std.debug.print("high-concurrency QUIC E2E restart_recovery=ok\n", .{});
    }

    failures = counters.failed.load(.acquire);
    const completion_ppm: u64 = (@as(u64, observed_ops) * 1_000_000) / @as(u64, expected_ops);
    const mutation_ppm: u64 = (@as(u64, observed_mutations_ok) * 1_000_000) / @as(u64, expected_ops);
    const qps_whole = qps_x100 / 100;
    var gate_failures: u32 = 0;
    if (completion_ppm < min_completion_ppm) {
        gate_failures += 1;
        std.debug.print(
            "high-concurrency QUIC E2E gate failure: completion_ppm={d} required_ppm={d}\n",
            .{ completion_ppm, min_completion_ppm },
        );
    }
    if (min_mutation_ppm != 0 and mutation_ppm < min_mutation_ppm) {
        gate_failures += 1;
        std.debug.print(
            "high-concurrency QUIC E2E gate failure: mutation_ppm={d} required_ppm={d}\n",
            .{ mutation_ppm, min_mutation_ppm },
        );
    }
    if (require_zero_first_response_timeouts and counters.first_response_timeouts.load(.acquire) != 0) {
        gate_failures += 1;
        std.debug.print(
            "high-concurrency QUIC E2E gate failure: first_response_timeouts={d} required=0\n",
            .{counters.first_response_timeouts.load(.acquire)},
        );
    }
    if (min_qps != 0 and qps_whole < min_qps) {
        gate_failures += 1;
        std.debug.print(
            "high-concurrency QUIC E2E gate failure: qps={d}.{d:0>2} required_min={d}\n",
            .{ qps_x100 / 100, qps_x100 % 100, min_qps },
        );
    }
    if (p50_max_ms != 0 and percentiles.p50_ns >= @as(u64, p50_max_ms) * std.time.ns_per_ms) {
        gate_failures += 1;
        std.debug.print("high-concurrency QUIC E2E gate failure: p50_ms >= {d}\n", .{p50_max_ms});
    }
    if (p95_max_ms != 0 and percentiles.p95_ns >= @as(u64, p95_max_ms) * std.time.ns_per_ms) {
        gate_failures += 1;
        std.debug.print("high-concurrency QUIC E2E gate failure: p95_ms >= {d}\n", .{p95_max_ms});
    }
    if (p99_max_ms != 0 and percentiles.p99_ns >= @as(u64, p99_max_ms) * std.time.ns_per_ms) {
        gate_failures += 1;
        std.debug.print("high-concurrency QUIC E2E gate failure: p99_ms >= {d}\n", .{p99_max_ms});
    }
    if (p999_max_ms != 0 and percentiles.p999_ns >= @as(u64, p999_max_ms) * std.time.ns_per_ms) {
        gate_failures += 1;
        std.debug.print("high-concurrency QUIC E2E gate failure: p99_9_ms >= {d}\n", .{p999_max_ms});
    }
    if (memory_growth_max_kb != 0 and rss_delta_kb > memory_growth_max_kb) {
        gate_failures += 1;
        std.debug.print(
            "high-concurrency QUIC E2E gate failure: rss_delta_kb={d} limit_kb={d}\n",
            .{ rss_delta_kb, memory_growth_max_kb },
        );
    }
    if (counters.verify_done.load(.acquire) == 0 and observed_mutations_ok != 0) {
        gate_failures += 1;
        std.debug.print("high-concurrency QUIC E2E gate failure: mutation verifier did not complete\n", .{});
    }
    if (counters.verify_failed.load(.acquire) != 0) {
        gate_failures += 1;
        std.debug.print("high-concurrency QUIC E2E gate failure: mutation verifier failed\n", .{});
    }

    std.debug.print(
        "high-concurrency QUIC E2E gate objective={} completion_ppm={d} mutation_ppm={d} failures={d} gate_failures={d}\n",
        .{ objective_gate, completion_ppm, mutation_ppm, failures, gate_failures },
    );
    if (gate_failures != 0) return error.HighConcurrencyGateFailed;
}
