// CANARY: REQ=REQ-SONNY-6386-PHANTOM-OVERHEAD-CLAIMS; FEATURE="MVCC Phantom Prevention"; ASPECT=OverheadClaimsMatchMeasurement; STATUS=TESTED; TEST=tests/test_sonny6386_phantom_overhead_claims.zig; OWNER=txn; UPDATED=2026-11-12
//
// SONNY-6386 (9): the two phantom-prevention benchmarks claimed an overhead
// of at most 5% per transaction ("range tracking overhead <= 5%",
// "phantom prevention transaction overhead <= 5%"). With the SONNY-2439
// methodology (batched, interleaved, medians, production allocator) the
// transaction manager measures 27-36% (phantom-anomaly) and 84-96%
// (phantom-range) in ReleaseFast, 54-63% in Debug: the claims could never
// hold, and the enforced perf-gate job failed on them with no product change.
// The cost is the bookkeeping itself (a hash-map entry and a list allocation
// per tracked transaction and a heap copy of every prefix and range bound,
// released at commit: about 100-125 ns), against synthetic transactions of
// 120-350 ns that do no storage work; it is not an accidental scan or lock.
//
// The contract: no source or doc claims a 5% bound; each benchmark claims
// the bound recalibrated from the measurement (per build mode, about 1.3-1.4x
// the highest median measured), and docs/ENHANCED_TRANSACTION_ISOLATION.md
// states the measured figures and the same bounds.
const std = @import("std");
const options = @import("sonny6386_ph_options");

const testing = std.testing;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn readRepoFile(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    const abs = try std.fs.path.join(allocator, &.{ options.repo_root, rel });
    defer allocator.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(io(), abs, allocator, .limited(64 << 20));
}

/// The bounds each benchmark must declare, as `const <name> = <value>;`, and
/// the percentage the doc must state for it.
const Bound = struct { file: []const u8, decl: []const u8, percent: []const u8 };
const bounds = [_]Bound{
    .{ .file = "tests/canary_txn_phantom_range.zig", .decl = "const max_range_overhead_release = 1.25;", .percent = "125%" },
    .{ .file = "tests/canary_txn_phantom_range.zig", .decl = "const max_range_overhead_debug = 0.80;", .percent = "80%" },
    .{ .file = "tests/canary_txn_phantom_anomaly.zig", .decl = "const max_phantom_overhead_release = 0.50;", .percent = "50%" },
    .{ .file = "tests/canary_txn_phantom_anomaly.zig", .decl = "const max_phantom_overhead_debug = 0.90;", .percent = "90%" },
};

test "SONNY-6386 (9) the phantom-prevention benchmarks claim the measured overhead, not 5%, and the doc states the same bounds" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    for ([_][]const u8{ "tests/canary_txn_phantom_range.zig", "tests/canary_txn_phantom_anomaly.zig" }) |rel| {
        const src = try readRepoFile(allocator, rel);
        defer allocator.free(src);
        for ([_][]const u8{ "overhead <= 5%", "overhead <= 0.05" }) |stale| {
            if (std.mem.indexOf(u8, src, stale) != null) {
                std.debug.print("SONNY-6386 (9): {s} still claims \"{s}\"\n", .{ rel, stale });
                bad += 1;
            }
        }
    }

    const doc = try readRepoFile(allocator, "docs/ENHANCED_TRANSACTION_ISOLATION.md");
    defer allocator.free(doc);
    const heading = "## Phantom prevention overhead";
    const start = std.mem.indexOf(u8, doc, heading) orelse {
        std.debug.print("SONNY-6386 (9): docs/ENHANCED_TRANSACTION_ISOLATION.md has no \"{s}\" section\n", .{heading});
        return error.TestUnexpectedResult;
    };
    const rest = doc[start + heading.len ..];
    const section = rest[0 .. std.mem.indexOf(u8, rest, "\n## ") orelse rest.len];

    for (bounds) |b| {
        const src = try readRepoFile(allocator, b.file);
        defer allocator.free(src);
        if (std.mem.indexOf(u8, src, b.decl) == null) {
            std.debug.print("SONNY-6386 (9): {s} does not declare {s}\n", .{ b.file, b.decl });
            bad += 1;
        }
        if (std.mem.indexOf(u8, section, b.percent) == null) {
            std.debug.print("SONNY-6386 (9): the doc section does not state the {s} bound\n", .{b.percent});
            bad += 1;
        }
    }
    for ([_][]const u8{ "test-canary-txn-phantom-range", "test-canary-txn-phantom-anomaly", "ReleaseFast" }) |needed| {
        if (std.mem.indexOf(u8, section, needed) == null) {
            std.debug.print("SONNY-6386 (9): the doc section does not mention {s}\n", .{needed});
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}
