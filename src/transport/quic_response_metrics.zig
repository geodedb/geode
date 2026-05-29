const std = @import("std");

// CANARY: REQ=REQ-QUIC-HC-078; FEATURE="QUIC High-Concurrency Requests"; ASPECT=ResponseWriteMetrics; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-27

pub var response_messages_started_total = std.atomic.Value(u64).init(0);
pub var response_messages_completed_total = std.atomic.Value(u64).init(0);
pub var response_batches_started_total = std.atomic.Value(u64).init(0);
pub var response_batches_completed_total = std.atomic.Value(u64).init(0);
pub var response_encode_bytes_total = std.atomic.Value(u64).init(0);

pub var stream_write_calls_total = std.atomic.Value(u64).init(0);
pub var stream_write_success_total = std.atomic.Value(u64).init(0);
pub var stream_write_errors_total = std.atomic.Value(u64).init(0);
pub var stream_write_timeouts_total = std.atomic.Value(u64).init(0);
pub var stream_write_blocked_retries_total = std.atomic.Value(u64).init(0);
pub var stream_write_flow_blocked_total = std.atomic.Value(u64).init(0);
pub var stream_write_would_block_total = std.atomic.Value(u64).init(0);
pub var stream_write_zero_returns_total = std.atomic.Value(u64).init(0);
pub var stream_write_bytes_requested_total = std.atomic.Value(u64).init(0);
pub var stream_write_bytes_written_total = std.atomic.Value(u64).init(0);
// CANARY: REQ=REQ-QUIC-HC-153; FEATURE="QUIC High-Concurrency Requests"; ASPECT=ResponseWriteLatency; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-29
//
// High-fanout mixed probes need to distinguish slow query execution from slow
// response delivery. These counters measure the server-side stream.writeAll
// critical section used by QUIC response writes.
pub var stream_write_elapsed_ns_total = std.atomic.Value(u64).init(0);
pub var stream_write_elapsed_max_ns = std.atomic.Value(u64).init(0);

fn recordMax(atom: *std.atomic.Value(u64), value: u64) void {
    var observed = atom.load(.acquire);
    while (value > observed) {
        observed = atom.cmpxchgWeak(observed, value, .acq_rel, .acquire) orelse break;
    }
}

pub fn recordStreamWriteStart(bytes: usize) void {
    _ = stream_write_calls_total.fetchAdd(1, .monotonic);
    _ = stream_write_bytes_requested_total.fetchAdd(@intCast(bytes), .monotonic);
}

pub fn recordStreamWriteSuccess(bytes: usize, elapsed_ns: u64) void {
    _ = stream_write_success_total.fetchAdd(1, .monotonic);
    _ = stream_write_bytes_written_total.fetchAdd(@intCast(bytes), .monotonic);
    _ = stream_write_elapsed_ns_total.fetchAdd(elapsed_ns, .monotonic);
    recordMax(&stream_write_elapsed_max_ns, elapsed_ns);
}

pub fn recordStreamWriteBlocked(err: anyerror) void {
    _ = stream_write_blocked_retries_total.fetchAdd(1, .monotonic);
    if (err == error.FlowControlBlocked) {
        _ = stream_write_flow_blocked_total.fetchAdd(1, .monotonic);
    } else if (err == error.WouldBlock) {
        _ = stream_write_would_block_total.fetchAdd(1, .monotonic);
    }
}

pub fn recordStreamWriteZeroReturn() void {
    _ = stream_write_blocked_retries_total.fetchAdd(1, .monotonic);
    _ = stream_write_zero_returns_total.fetchAdd(1, .monotonic);
}

pub fn registerAll(registry: anytype) !void {
    try registry.register("quic_response_messages_started_total", &response_messages_started_total);
    try registry.register("quic_response_messages_completed_total", &response_messages_completed_total);
    try registry.register("quic_response_batches_started_total", &response_batches_started_total);
    try registry.register("quic_response_batches_completed_total", &response_batches_completed_total);
    try registry.register("quic_response_encode_bytes_total", &response_encode_bytes_total);
    try registry.register("quic_stream_write_calls_total", &stream_write_calls_total);
    try registry.register("quic_stream_write_success_total", &stream_write_success_total);
    try registry.register("quic_stream_write_errors_total", &stream_write_errors_total);
    try registry.register("quic_stream_write_timeouts_total", &stream_write_timeouts_total);
    try registry.register("quic_stream_write_blocked_retries_total", &stream_write_blocked_retries_total);
    try registry.register("quic_stream_write_flow_blocked_total", &stream_write_flow_blocked_total);
    try registry.register("quic_stream_write_would_block_total", &stream_write_would_block_total);
    try registry.register("quic_stream_write_zero_returns_total", &stream_write_zero_returns_total);
    try registry.register("quic_stream_write_bytes_requested_total", &stream_write_bytes_requested_total);
    try registry.register("quic_stream_write_bytes_written_total", &stream_write_bytes_written_total);
    try registry.register("quic_stream_write_elapsed_ns_total", &stream_write_elapsed_ns_total);
    try registry.register("quic_stream_write_elapsed_max_ns", &stream_write_elapsed_max_ns);
}
