// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Unit test for `runtime_metrics`: register counters, emit a snapshot
//! string, verify the format includes every registered name + value.

// CANARY: REQ=REQ-PERF-DIAG-RUNTIME-METRICS; FEATURE="RuntimeMetricsHelper"; ASPECT=CounterRegistry; STATUS=TESTED; TEST=tests/test_runtime_metrics.zig; OWNER=perf; UPDATED=2026-04-25

const std = @import("std");
const geode = @import("geode");
const runtime_metrics = geode.runtime_metrics;

test "register + snapshot emits all counters" {
    const allocator = std.testing.allocator;
    var registry = try runtime_metrics.Registry.init(allocator);
    defer registry.deinit();

    var ops = std.atomic.Value(u64).init(7);
    var batches = std.atomic.Value(u64).init(2);
    try registry.register("apply_ops_total", &ops);
    try registry.register("apply_batches_total", &batches);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try registry.snapshotInto(allocator, &buf);

    const out = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "apply_ops_total=7") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "apply_batches_total=2") != null);
}

test "registerGauge: snapshot emits gauge value after counters" {
    const allocator = std.testing.allocator;
    var registry = try runtime_metrics.Registry.init(allocator);
    defer registry.deinit();

    // Counter (existing path).
    var counter_atomic = std.atomic.Value(u64).init(7);
    try registry.register("test_counter", &counter_atomic);

    // Gauge (new path) with a static-context callback.
    const GaugeFn = struct {
        fn read(ctx_ptr: *anyopaque) u64 {
            _ = ctx_ptr;
            return 42;
        }
    };
    var dummy_ctx: u8 = 0;
    try registry.registerGauge("test_gauge", GaugeFn.read, @ptrCast(&dummy_ctx));

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try registry.snapshotInto(allocator, &buf);

    const out = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "test_counter=7") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "test_gauge=42") != null);
    // snapshotInto contract: counters first, then gauges.
    const counter_pos = std.mem.indexOf(u8, out, "test_counter=").?;
    const gauge_pos = std.mem.indexOf(u8, out, "test_gauge=").?;
    try std.testing.expect(counter_pos < gauge_pos);
    // Pairs are space-separated.
    try std.testing.expect(std.mem.indexOf(u8, out, "test_counter=7 test_gauge=42") != null);
}
