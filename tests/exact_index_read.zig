//! SONNY-6827: an exact-index read that can meet a reopen's background build.
//!
//! An index-served read that finds the exact-index build in flight gets
//! `error.ExactIndexBusy`, and its production callers scan instead
//! (SONNY-6362). A test reading the index straight after a reopen can meet
//! the reopen's background rebuild; it asks again once that is done, as a
//! later read would, bounded at two minutes.

const std = @import("std");

/// `adapter.getCandidateNodesByLabelAndProperty`, retried while the exact
/// index is busy. Caller owns the returned slice.
pub fn candidates(adapter: anytype, graph: []const u8, label: []const u8, key: []const u8, value: anytype, allocator: std.mem.Allocator) ![]u64 {
    var waited_ms: u32 = 0;
    while (true) {
        return adapter.getCandidateNodesByLabelAndProperty(graph, label, key, value, allocator) catch |err| switch (err) {
            error.ExactIndexBusy => {
                if (waited_ms >= 120_000) return err;
                std.Io.Threaded.global_single_threaded.io().sleep(.fromMilliseconds(5), .awake) catch {};
                waited_ms += 5;
                continue;
            },
            else => return err,
        };
    }
}
