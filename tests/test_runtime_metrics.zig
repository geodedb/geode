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
