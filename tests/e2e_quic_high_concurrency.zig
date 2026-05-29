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
const default_poll_worker_count = if (builtin.mode == .Debug) 1 else 16;
const default_cooperative_first_stream_worker_count = if (builtin.mode == .Debug) 16 else 256;
const default_connection_worker_count = 64;
const high_fanout_worker_threshold = 64;
const high_fanout_connection_worker_cap = 64;
// CANARY: REQ=REQ-QUIC-HC-141; FEATURE="QUIC High-Concurrency Requests"; ASPECT=PollWorkerContentionCap; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-28
//
// The QUIC endpoint now serializes per-connection TLS crypto polling. More
// than 16 poll workers on one endpoint loses high-fanout mixed read/write runs
// to endpoint mutex contention instead of increasing packet throughput.
const high_fanout_poll_worker_cap = if (builtin.mode == .Debug) 4 else 16;
// CANARY: REQ=REQ-QUIC-HC-138; FEATURE="High-Concurrency Test Harness"; ASPECT=CooperativeFirstStreamWorkerHeadroom; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-28
//
// Keep the cooperative owner pool bounded; raising it to match 1024 clients
// stalls HELLO setup in same-process fan-out tests. Tail latency is protected
// by the scheduler's one-message FIFO turn rather than one server thread per
// active client.
const high_fanout_cooperative_first_stream_worker_cap = if (builtin.mode == .Debug) 64 else 512;
// CANARY: REQ=REQ-QUIC-HC-118; FEATURE="High-Concurrency Test Harness"; ASPECT=BoundedDriverThreadStacks; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-27
//
// The E2E harness intentionally opens hundreds to thousands of clients in one
// process. Use a bounded stack for those simple driver threads so the client
// side does not consume default multi-megabyte stacks before the server is the
// limiting factor.
const high_concurrency_worker_stack_size = 1024 * 1024;

fn monoNs() u64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    const rc = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    if (rc != 0) return 0;
    const sec: u64 = if (ts.sec < 0) 0 else @intCast(ts.sec);
    const nsec: u64 = if (ts.nsec < 0) 0 else @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}

fn sleepNs(ns: u64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
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

// CANARY: REQ=REQ-QUIC-HC-128; FEATURE="High-Concurrency Test Harness"; ASPECT=CooperativeFirstStreamWorkerHeadroom; STATUS=IMPL; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-28
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
    read_latency_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    mutation_latency_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    first_op_ok: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    followup_op_ok: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    first_op_latency_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    followup_op_latency_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    max_latency_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    verify_done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    verify_failed: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
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
    counters: *Counters,
    start: *std.atomic.Value(bool),
    start_generation: *std.atomic.Value(u32),
    abort_setup: *std.atomic.Value(bool),
    release_clients: *std.atomic.Value(bool),
    release_generation: *std.atomic.Value(u32),
    expected_ops: u32,
    verify_after_workload: bool,
    client_diagnostics: bool,
};

fn recordFailure(counters: *Counters, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("high-concurrency QUIC E2E failure: " ++ fmt ++ "\n", args);
    _ = counters.failed.fetchAdd(1, .acq_rel);
}

fn recordSetupFailure(counters: *Counters, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("high-concurrency QUIC E2E setup failure: " ++ fmt ++ "\n", args);
    _ = counters.setup_failed.fetchAdd(1, .acq_rel);
    _ = counters.failed.fetchAdd(1, .acq_rel);
}

fn recordMaxLatency(counters: *Counters, latency_ns: u64) void {
    var observed = counters.max_latency_ns.load(.acquire);
    while (latency_ns > observed) {
        observed = counters.max_latency_ns.cmpxchgWeak(observed, latency_ns, .acq_rel, .acquire) orelse break;
    }
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
            const wake_count = @min(remaining, @as(u32, 256));
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
                recordFailure(ctx.counters, "worker={d} op={d} format err={}", .{ ctx.worker_id, op, err });
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
            res_opt = client.executeAndCollectWithTimeout(
                allocator,
                query,
                util.emptyParams(),
                128,
                ctx.execute_timeout_secs,
            ) catch |err| retry_blk: {
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
                _ = ctx.counters.execute_reconnects.fetchAdd(1, .acq_rel);
                continue;
            };
            if (res_opt != null) break;
        }
        var res = res_opt orelse {
            if (ctx.client_diagnostics) client.dumpTransportDiagnostics(ctx.worker_id, op);
            recordFailure(ctx.counters, "worker={d} op={d} mutation={} execute err={}", .{ ctx.worker_id, op, is_mutation, last_err });
            continue;
        };
        const op_latency_ns = monoNs() -| op_start_ns;
        recordMaxLatency(ctx.counters, op_latency_ns);
        defer res.deinit(allocator);

        expectNoQueryError(&res) catch |err| {
            recordFailure(ctx.counters, "worker={d} op={d} mutation={} result err={}", .{ ctx.worker_id, op, is_mutation, err });
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

    // CANARY: REQ=REQ-QUIC-HC-099; FEATURE="QUIC High-Concurrency Requests"; ASPECT=InWorkloadMutationVerifier; STATUS=IMPL; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-27
    //
    // Keep all workload clients alive until the designated verifier has checked
    // mutation visibility over an already-authenticated connection. This avoids
    // turning the correctness assertion into a separate post-burst handshake
    // test dominated by 1024 simultaneous client closes.
    if (ctx.verify_after_workload and ctx.mutation_stride != 0) {
        while (ctx.counters.ok.load(.acquire) + ctx.counters.failed.load(.acquire) < ctx.expected_ops) {
            sleepNs(10 * std.time.ns_per_ms);
        }
        if (ctx.counters.failed.load(.acquire) == 0) {
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
    const worker_count = @max(@as(u32, 1), envU32("GEODE_HC_WORKERS", default_worker_count));
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
    const default_poll_workers_for_run: u32 = if (high_fanout_setup) @max(@as(u32, default_poll_worker_count), 16) else default_poll_worker_count;
    const default_connection_workers_for_run = if (high_fanout_setup) highFanoutConnectionWorkerDefault(worker_count) else default_connection_worker_count;
    const default_connection_admission_threads_for_run = if (high_fanout_setup) @min(@max(worker_count, @as(u32, 1024)), @as(u32, 4096)) else @as(u32, 1024);
    const default_cooperative_first_stream_workers_for_run = if (high_fanout_setup) highFanoutCooperativeFirstStreamWorkerDefault(worker_count) else default_cooperative_first_stream_worker_count;
    const default_request_stagger_us_for_run: u32 = if (high_fanout_setup) @max(@as(u32, default_request_stagger_us), 1000) else default_request_stagger_us;
    const ops_per_worker = @max(@as(u32, 1), envU32("GEODE_HC_OPS_PER_WORKER", default_ops_per_worker));
    const mutation_stride = envU32("GEODE_HC_MUTATION_STRIDE", default_mutation_stride);
    const connect_attempts = @max(@as(u32, 1), envU32("GEODE_HC_CONNECT_ATTEMPTS", default_connect_attempts_for_run));
    const connect_backoff_ms = @max(@as(u32, 1), envU32("GEODE_HC_CONNECT_BACKOFF_MS", default_connect_backoff_ms));
    const handshake_timeout_secs = @max(@as(u32, 1), envU32("GEODE_HC_HANDSHAKE_TIMEOUT_SECS", default_handshake_timeout_secs));
    // CANARY: REQ=REQ-QUIC-HC-101; FEATURE="QUIC High-Concurrency Setup"; ASPECT=BoundedHelloRetryWindow; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-27
    //
    // A 30s HELLO read deadline turns one lost server response during fan-out
    // into a 30s setup plateau before connectAndHelloWithRetry can open a fresh
    // connection. Keep the retry window short enough to recover quickly while
    // still above normal sub-second HELLO latency at 512+ clients.
    const hello_timeout_ms = @max(@as(u32, 1), envU32("GEODE_HC_HELLO_TIMEOUT_MS", default_hello_timeout_ms_for_run));
    const setup_timeout_secs = @max(@as(u32, 1), envU32("GEODE_HC_SETUP_TIMEOUT_SECS", default_setup_timeout_secs_for_run));
    const setup_grace_secs = envU32("GEODE_HC_SETUP_GRACE_SECS", 30);
    // CANARY: REQ=REQ-QUIC-HC-131; FEATURE="QUIC High-Concurrency Setup"; ASPECT=HardSetupTimeoutDiagnostics; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-28
    //
    // The soft setup timeout remains progress-sensitive so legitimate 512+
    // connection tails are not aborted while HELLOs are still completing.
    // Keep a separate hard cap so retry churn cannot run silently until the
    // outer shell timeout kills the harness before it prints counters.
    const default_setup_hard_timeout_secs = setup_timeout_secs + setup_grace_secs;
    const setup_hard_timeout_secs = @max(setup_timeout_secs, envU32("GEODE_HC_SETUP_HARD_TIMEOUT_SECS", default_setup_hard_timeout_secs));
    const connect_stagger_us = envU32("GEODE_HC_CONNECT_STAGGER_US", 0);
    // CANARY: REQ=REQ-QUIC-HC-042; FEATURE="QUIC High-Concurrency Requests"; ASPECT=RequestBurstShaping; STATUS=IMPL; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-26
    // Release builds shape a target offered load across already-open parallel
    // connections by default. Setting GEODE_HC_REQUEST_STAGGER_US=0 keeps the
    // same-time microburst mode available when explicitly testing kernel queue
    // and packet recovery behavior.
    const request_stagger_us = envU32("GEODE_HC_REQUEST_STAGGER_US", default_request_stagger_us_for_run);
    const execute_timeout_secs = @max(@as(u32, 1), envU32("GEODE_HC_EXEC_TIMEOUT_SECS", default_execute_timeout_secs));
    const execute_retries = envU32("GEODE_HC_EXEC_RETRIES", default_execute_retries);
    // CANARY: REQ=REQ-QUIC-HC-085; FEATURE="QUIC High-Concurrency Requests"; ASPECT=HarnessConnectionHeadroom; STATUS=IMPL; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-27
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
    const client_diagnostics = envBool("GEODE_HC_CLIENT_DIAGNOSTICS", false);
    const cooperative_first_streams = envBool("GEODE_HC_COOPERATIVE_FIRST_STREAMS", true);
    const read_query = envSlice("GEODE_HC_READ_QUERY", "MATCH (n:HCParallel) RETURN count(n) AS c");

    const port = try util.getRandomPort();
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
    // CANARY: REQ=REQ-QUIC-HC-071; FEATURE="QUIC High-Concurrency Requests"; ASPECT=HarnessFirstStreamThreadCap; STATUS=IMPL; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-27
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
    // CANARY: REQ=REQ-QUIC-HC-124; FEATURE="High-Concurrency Test Harness"; ASPECT=ConnectionWorkerHeadroom; STATUS=IMPL; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-28
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
    const server_hello_timeout_env = try std.fmt.allocPrint(
        allocator,
        "GEODE_QUIC_HELLO_READ_TIMEOUT_MS={d}",
        .{hello_timeout_ms},
    );
    defer allocator.free(server_hello_timeout_env);
    const cooperative_first_streams_env: []const u8 = if (cooperative_first_streams)
        "GEODE_QUIC_COOPERATIVE_FIRST_STREAMS=1"
    else
        "GEODE_QUIC_COOPERATIVE_FIRST_STREAMS=0";
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
    const server_env: []const []const u8 = if (capture_server_logs)
        &.{
            "GEODE_QUIC_PASSIVE_TEARDOWN=1",
            "GEODE_QUIC_ENABLE_STREAM_MULTIPLEXING=0",
            cooperative_first_streams_env,
            detached_first_stream_env,
            max_global_stream_env,
            poll_workers_env,
            cooperative_first_stream_workers_env,
            connection_workers_env,
            connection_admission_threads_env,
            "GEODE_QUIC_DETACHED_CONNECTION_ADMISSION=1",
            server_hello_timeout_env,
            "GEODE_QUIC_STREAM_QUEUE_CAPACITY=8192",
            "GEODE_TEST_INHERIT_SERVER_STDERR=1",
        }
    else
        &.{
            "GEODE_QUIC_PASSIVE_TEARDOWN=1",
            "GEODE_QUIC_ENABLE_STREAM_MULTIPLEXING=0",
            cooperative_first_streams_env,
            detached_first_stream_env,
            max_global_stream_env,
            poll_workers_env,
            cooperative_first_stream_workers_env,
            connection_workers_env,
            connection_admission_threads_env,
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
    defer server.deinit();

    var counters = Counters{};
    var start = std.atomic.Value(bool).init(false);
    var start_generation = std.atomic.Value(u32).init(0);
    var abort_setup = std.atomic.Value(bool).init(false);
    var release_clients = std.atomic.Value(bool).init(false);
    var release_generation = std.atomic.Value(u32).init(0);
    const expected_ops: u32 = worker_count * ops_per_worker;
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
            .counters = &counters,
            .start = &start,
            .start_generation = &start_generation,
            .abort_setup = &abort_setup,
            .release_clients = &release_clients,
            .release_generation = &release_generation,
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

    // CANARY: REQ=REQ-QUIC-HC-072; FEATURE="QUIC High-Concurrency Setup"; ASPECT=TimeoutEdgeReadySettle; STATUS=IMPL; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-28
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
    wakeWorkloadStart(&start, &start_generation, worker_count, request_stagger_us);

    const workload_deadline_ns = workload_start_ns + (@as(u64, execute_timeout_secs) + 30) * @as(u64, @max(ops_per_worker, 1)) * std.time.ns_per_s;
    while (counters.ok.load(.acquire) + counters.failed.load(.acquire) < expected_ops and monoNs() < workload_deadline_ns) {
        sleepNs(10 * std.time.ns_per_ms);
    }
    const workload_elapsed_ns = monoNs() -| workload_start_ns;

    const failures = counters.failed.load(.acquire);
    if (failures != 0) {
        std.debug.print("high-concurrency QUIC E2E worker failures={d}\n", .{failures});
        std.debug.print(
            "high-concurrency QUIC E2E phases connected={d} hello_ok={d} ready={d} ops_started={d} ok={d}\n",
            .{
                counters.connected.load(.acquire),
                counters.hello_ok.load(.acquire),
                counters.ready.load(.acquire),
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
        releaseAllClients(&release_clients, &release_generation);
        for (threads) |*thread| thread.join();
        return error.WorkerFailures;
    }
    const observed_ops = counters.ok.load(.acquire);
    if (observed_ops != expected_ops) {
        std.debug.print(
            "high-concurrency QUIC E2E ok={d} expected={d} failed={d} ops_started={d} elapsed_ms={d} execute_attempts={d} execute_retries={d} execute_reconnects={d}\n",
            .{
                observed_ops,
                expected_ops,
                counters.failed.load(.acquire),
                counters.ops_started.load(.acquire),
                workload_elapsed_ns / std.time.ns_per_ms,
                counters.execute_attempts.load(.acquire),
                counters.execute_retries.load(.acquire),
                counters.execute_reconnects.load(.acquire),
            },
        );
        releaseAllClients(&release_clients, &release_generation);
        for (threads) |*thread| thread.join();
        return error.MissingSuccessfulOperations;
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
    // CANARY: REQ=REQ-QUIC-HC-103; FEATURE="QUIC High-Concurrency Requests"; ASPECT=RetryTailRegressionCounters; STATUS=IMPL; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-27
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
        if (counters.verify_done.load(.acquire) == 0 or counters.verify_failed.load(.acquire) != 0 or counters.failed.load(.acquire) != 0) {
            releaseAllClients(&release_clients, &release_generation);
            for (threads) |*thread| thread.join();
            return error.MutationCountMismatch;
        }
    }

    releaseAllClients(&release_clients, &release_generation);
    for (threads) |*thread| thread.join();
}
