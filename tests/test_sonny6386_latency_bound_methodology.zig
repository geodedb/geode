// CANARY: REQ=REQ-SONNY-6386-LATENCY-BOUND-METHODOLOGY; FEATURE="Perf Gates"; ASPECT=JsonAndSchedulerLatencyBoundsBatched; STATUS=TESTED; TEST=tests/test_sonny6386_latency_bound_methodology.zig; OWNER=performance; UPDATED=2026-11-12
//
// SONNY-6386 (6): the latency bounds SONNY-2439 left open.
// src/performance/test_json_optimization.zig ("JSON processing performance
// benchmark", "Large result set streaming performance", "CANARY:
// REQ=REQ-PERF-JSON-001") and tests/test_performance_optimizations.zig
// ("Performance: scheduler overhead") claimed a latency from one timed run on
// std.testing.allocator (DebugAllocator bookkeeping inside the timed region),
// read with their own clock helpers (compat_getNanos, compat_nanoTimestamp,
// or the mean inside json_optimized_fixed.benchmarkJsonProcessing).
//
// The contract, the same SONNY-2439 applied to the canary suites: every
// gated test block of those two files samples through tests/perf_gate.zig
// (sampleBatches / interleavedAB / nowNs; batched, each result passed to
// doNotOptimizeAway, CLOCK_MONOTONIC), allocates from
// perf_gate.bench_allocator, never std.testing.allocator or DebugAllocator,
// takes no reading from its own clock, and claims on robust statistics
// (perf_gate.robust: the median), with a robust variance envelope.
const std = @import("std");
const options = @import("sonny6386_lb_options");

const testing = std.testing;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn readRepoFile(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    const abs = try std.fs.path.join(allocator, &.{ options.repo_root, rel });
    defer allocator.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(io(), abs, allocator, .limited(64 << 20));
}

/// The `test "..." { ... }` blocks of `src` that make a gated perf claim.
fn gatedBlocks(allocator: std.mem.Allocator, src: []const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, src, at, "\ntest \"")) |start| {
        const end = std.mem.indexOfPos(u8, src, start + 1, "\n}\n") orelse src.len;
        const block = src[start..end];
        at = end;
        if (std.mem.indexOf(u8, block, "perf_gate.check(") != null or
            std.mem.indexOf(u8, block, "perf_gate.envelope(") != null or
            std.mem.indexOf(u8, block, "perf_gate.robustEnvelope(") != null)
        {
            try out.append(allocator, block);
        }
    }
    return out;
}

const files = [_]struct { path: []const u8, min_blocks: usize }{
    .{ .path = "src/performance/test_json_optimization.zig", .min_blocks = 3 },
    .{ .path = "tests/test_performance_optimizations.zig", .min_blocks = 1 },
};

test "SONNY-6386 (6) the JSON and scheduler latency bounds sample batches from the production allocator through perf_gate and claim on the median" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    for (files) |f| {
        const src = try readRepoFile(allocator, f.path);
        defer allocator.free(src);
        var blocks = try gatedBlocks(allocator, src);
        defer blocks.deinit(allocator);
        if (blocks.items.len < f.min_blocks) {
            bad += 1;
            std.debug.print("SONNY-6386 (6): {s}: {d} gated benchmark blocks, expected at least {d}\n", .{ f.path, blocks.items.len, f.min_blocks });
        }
        for (blocks.items) |block| {
            const name_end = std.mem.indexOfScalarPos(u8, block, 7, '"') orelse block.len;
            const name = block[@min(7, block.len)..name_end];
            for ([_][]const u8{ "DebugAllocator", "testing.allocator" }) |needle| {
                if (std.mem.indexOf(u8, block, needle) != null) {
                    bad += 1;
                    std.debug.print("SONNY-6386 (6): {s} \"{s}\": allocates from {s}, not perf_gate.bench_allocator\n", .{ f.path, name, needle });
                }
            }
            for ([_][]const u8{ "compat_getNanos(", "compat_nanoTimestamp(", "compat_microTimestamp(", "compat_milliTimestamp(", "benchmarkJsonProcessing(" }) |needle| {
                if (std.mem.indexOf(u8, block, needle) != null) {
                    bad += 1;
                    std.debug.print("SONNY-6386 (6): {s} \"{s}\": times with its own clock ({s}), not perf_gate\n", .{ f.path, name, needle });
                }
            }
            const helper = std.mem.indexOf(u8, block, "perf_gate.sampleBatches(") != null or
                std.mem.indexOf(u8, block, "perf_gate.interleavedAB(") != null;
            if (!helper) {
                bad += 1;
                std.debug.print("SONNY-6386 (6): {s} \"{s}\": not batched through perf_gate.sampleBatches / interleavedAB\n", .{ f.path, name });
            }
            if (std.mem.indexOf(u8, block, "perf_gate.robust(") == null or std.mem.indexOf(u8, block, ".median") == null) {
                bad += 1;
                std.debug.print("SONNY-6386 (6): {s} \"{s}\": the claim is not on the median of perf_gate.robust\n", .{ f.path, name });
            }
            if (std.mem.indexOf(u8, block, "perf_gate.robustEnvelope(") == null) {
                bad += 1;
                std.debug.print("SONNY-6386 (6): {s} \"{s}\": no robust variance envelope\n", .{ f.path, name });
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}
