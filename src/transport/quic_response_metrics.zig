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
// CANARY: REQ=REQ-QUIC-HC-157; FEATURE="QUIC High-Concurrency Diagnostics"; ASPECT=FirstStreamSchedulerLatency; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-29
//
// The 4096/250 us ceiling tail now reaches the server before timing out, so
// response-write metrics alone are not enough. These counters split cooperative
// first-stream ready queue delay from packet processing time.
pub var first_stream_ready_enqueued_total = std.atomic.Value(u64).init(0);
pub var first_stream_ready_dequeued_total = std.atomic.Value(u64).init(0);
pub var first_stream_ready_queue_wait_ns_total = std.atomic.Value(u64).init(0);
pub var first_stream_ready_queue_wait_max_ns = std.atomic.Value(u64).init(0);
pub var first_stream_packets_started_total = std.atomic.Value(u64).init(0);
pub var first_stream_packets_completed_total = std.atomic.Value(u64).init(0);
pub var first_stream_packet_process_ns_total = std.atomic.Value(u64).init(0);
pub var first_stream_packet_process_max_ns = std.atomic.Value(u64).init(0);
pub var first_stream_mutation_deferrals_total = std.atomic.Value(u64).init(0);
// CANARY: REQ=REQ-QUIC-HC-169; FEATURE="QUIC High-Concurrency Diagnostics"; ASPECT=FirstStreamPhaseLatency; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-29
//
// Split first-stream packet processing into prepare, execution, and response
// send phases. The aggregate packet-process metric is useful for alerting, but
// 4096x8 diagnostics need to distinguish query-cache/parse work, storage
// execution, and protobuf+QUIC response delivery.
pub var first_stream_query_prepare_samples_total = std.atomic.Value(u64).init(0);
pub var first_stream_query_prepare_ns_total = std.atomic.Value(u64).init(0);
pub var first_stream_query_prepare_max_ns = std.atomic.Value(u64).init(0);
pub var first_stream_query_execute_samples_total = std.atomic.Value(u64).init(0);
pub var first_stream_query_execute_ns_total = std.atomic.Value(u64).init(0);
pub var first_stream_query_execute_max_ns = std.atomic.Value(u64).init(0);
pub var first_stream_response_send_samples_total = std.atomic.Value(u64).init(0);
pub var first_stream_response_send_ns_total = std.atomic.Value(u64).init(0);
pub var first_stream_response_send_max_ns = std.atomic.Value(u64).init(0);

threadlocal var first_stream_phase_sample_depth: u32 = 0;

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

pub fn recordFirstStreamReadyEnqueued() void {
    _ = first_stream_ready_enqueued_total.fetchAdd(1, .monotonic);
}

pub fn recordFirstStreamReadyDequeued(wait_ns: u64) void {
    _ = first_stream_ready_dequeued_total.fetchAdd(1, .monotonic);
    _ = first_stream_ready_queue_wait_ns_total.fetchAdd(wait_ns, .monotonic);
    recordMax(&first_stream_ready_queue_wait_max_ns, wait_ns);
}

pub fn recordFirstStreamPacketStart() void {
    _ = first_stream_packets_started_total.fetchAdd(1, .monotonic);
}

pub fn recordFirstStreamPacketComplete(elapsed_ns: u64) void {
    _ = first_stream_packets_completed_total.fetchAdd(1, .monotonic);
    _ = first_stream_packet_process_ns_total.fetchAdd(elapsed_ns, .monotonic);
    recordMax(&first_stream_packet_process_max_ns, elapsed_ns);
}

pub fn recordFirstStreamMutationDeferral() void {
    _ = first_stream_mutation_deferrals_total.fetchAdd(1, .monotonic);
}

pub fn beginFirstStreamPhaseSample() void {
    first_stream_phase_sample_depth +|= 1;
}

pub fn endFirstStreamPhaseSample() void {
    if (first_stream_phase_sample_depth > 0) first_stream_phase_sample_depth -= 1;
}

fn firstStreamPhaseSampleActive() bool {
    return first_stream_phase_sample_depth > 0;
}

pub fn recordFirstStreamQueryPrepare(elapsed_ns: u64) void {
    if (!firstStreamPhaseSampleActive()) return;
    _ = first_stream_query_prepare_samples_total.fetchAdd(1, .monotonic);
    _ = first_stream_query_prepare_ns_total.fetchAdd(elapsed_ns, .monotonic);
    recordMax(&first_stream_query_prepare_max_ns, elapsed_ns);
}

pub fn recordFirstStreamQueryExecute(elapsed_ns: u64) void {
    if (!firstStreamPhaseSampleActive()) return;
    _ = first_stream_query_execute_samples_total.fetchAdd(1, .monotonic);
    _ = first_stream_query_execute_ns_total.fetchAdd(elapsed_ns, .monotonic);
    recordMax(&first_stream_query_execute_max_ns, elapsed_ns);
}

pub fn recordFirstStreamResponseSend(elapsed_ns: u64) void {
    if (!firstStreamPhaseSampleActive()) return;
    _ = first_stream_response_send_samples_total.fetchAdd(1, .monotonic);
    _ = first_stream_response_send_ns_total.fetchAdd(elapsed_ns, .monotonic);
    recordMax(&first_stream_response_send_max_ns, elapsed_ns);
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
    try registry.register("quic_first_stream_ready_enqueued_total", &first_stream_ready_enqueued_total);
    try registry.register("quic_first_stream_ready_dequeued_total", &first_stream_ready_dequeued_total);
    try registry.register("quic_first_stream_ready_queue_wait_ns_total", &first_stream_ready_queue_wait_ns_total);
    try registry.register("quic_first_stream_ready_queue_wait_max_ns", &first_stream_ready_queue_wait_max_ns);
    try registry.register("quic_first_stream_packets_started_total", &first_stream_packets_started_total);
    try registry.register("quic_first_stream_packets_completed_total", &first_stream_packets_completed_total);
    try registry.register("quic_first_stream_packet_process_ns_total", &first_stream_packet_process_ns_total);
    try registry.register("quic_first_stream_packet_process_max_ns", &first_stream_packet_process_max_ns);
    try registry.register("quic_first_stream_mutation_deferrals_total", &first_stream_mutation_deferrals_total);
    try registry.register("quic_first_stream_query_prepare_samples_total", &first_stream_query_prepare_samples_total);
    try registry.register("quic_first_stream_query_prepare_ns_total", &first_stream_query_prepare_ns_total);
    try registry.register("quic_first_stream_query_prepare_max_ns", &first_stream_query_prepare_max_ns);
    try registry.register("quic_first_stream_query_execute_samples_total", &first_stream_query_execute_samples_total);
    try registry.register("quic_first_stream_query_execute_ns_total", &first_stream_query_execute_ns_total);
    try registry.register("quic_first_stream_query_execute_max_ns", &first_stream_query_execute_max_ns);
    try registry.register("quic_first_stream_response_send_samples_total", &first_stream_response_send_samples_total);
    try registry.register("quic_first_stream_response_send_ns_total", &first_stream_response_send_ns_total);
    try registry.register("quic_first_stream_response_send_max_ns", &first_stream_response_send_max_ns);
}
