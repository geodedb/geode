// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Process-wide counters for `BufferedProtoReader.nextMessage` —
//! the server's single read-side QUIC entry point. These are
//! monotonic-increment counters (not gauges); deltas between
//! periodic emits give the per-interval rate.

const std = @import("std");

pub var messages_delivered_total = std.atomic.Value(u64).init(0);
pub var would_block_loop_iterations_total = std.atomic.Value(u64).init(0);
pub var bytes_read_total = std.atomic.Value(u64).init(0);
pub var eof_total = std.atomic.Value(u64).init(0);

/// Called from main.zig after the registry is created.
pub fn registerAll(registry: anytype) !void {
    try registry.register("proto_reader_messages_delivered_total", &messages_delivered_total);
    try registry.register("proto_reader_would_block_loop_iterations_total", &would_block_loop_iterations_total);
    try registry.register("proto_reader_bytes_read_total", &bytes_read_total);
    try registry.register("proto_reader_eof_total", &eof_total);
}
