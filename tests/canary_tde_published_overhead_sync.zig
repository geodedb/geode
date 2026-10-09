const std = @import("std");

// TDE Overhead Published Sync Test
// Keeps every PUBLISHED TDE-overhead claim in sync with the validated target:
// < 5% OLTP overhead (tests/test_tde_oltp_overhead_threshold.zig,
// BENCHMARK_REPORT.md "OLTP Overhead < 5%"). SONNY-2394: README.md and
// docs/KMS_PROVIDER_SYSTEM.md had drifted to an unmeasured "<1%" claim.
// CANARY: REQ=REQ-GQL-TDE-OLTP-PERF-001; FEATURE="TDEOlptOverheadValidation"; ASPECT=PublishedSync; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_OLTP_PERF_001_PublishedOverheadClaimPresent; OWNER=perf; UPDATED=2026-09-23

const published_docs = [_][]const u8{ "README.md", "docs/KMS_PROVIDER_SYSTEM.md" };

fn readDoc(path: []const u8) ![]u8 {
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var file = try std.Io.Dir.cwd().openFile(io_fs, path, .{});
    defer file.close(io_fs);
    var file_reader_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io_fs, &file_reader_buf);
    return file_reader.interface.allocRemaining(std.testing.allocator, .limited(1_000_000));
}

test "TestCANARY_REQ_GQL_TDE_OLTP_PERF_001_PublishedOverheadClaimPresent" {
    for (published_docs) |path| {
        const data = try readDoc(path);
        defer std.testing.allocator.free(data);

        // The validated target is published...
        if (std.mem.indexOf(u8, data, "<5% TDE overhead") == null) {
            std.debug.print("{s}: missing the validated \"<5% TDE overhead\" claim\n", .{path});
            return error.PublishedClaimMissing;
        }
        // ...and no overhead line contradicts it with an unmeasured "<1%".
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (std.ascii.indexOfIgnoreCase(line, "overhead") == null) continue;
            if (std.mem.indexOf(u8, line, "<1%") != null) {
                std.debug.print("{s}: unvalidated overhead claim: {s}\n", .{ path, line });
                return error.UnvalidatedOverheadClaim;
            }
        }
    }
}
