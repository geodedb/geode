const std = @import("std");

// TDE Overhead Published Sync Test
// Keeps every PUBLISHED TDE-overhead claim in sync with the measurement.
// SONNY-6435: the overhead is measured (`zig build
// test-sonny6435-tde-overhead`: +0.7% with the default per-commit fsync,
// about +20% on the commit path without fsync), so the published docs cite
// that step and make neither the unmeasured "<5%" target claim nor a "<1%"
// one. (SONNY-2394: these docs had drifted to "<1%"; SONNY-6430 removed the
// never-compiled threshold test that asserted `true`.)
// CANARY: REQ=REQ-GQL-TDE-OLTP-PERF-001; FEATURE="TDEOlptOverheadValidation"; ASPECT=PublishedSync; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_OLTP_PERF_001_PublishedOverheadClaimPresent; OWNER=perf; UPDATED=2026-11-12

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

        // The measurement is cited...
        if (std.mem.indexOf(u8, data, "test-sonny6435-tde-overhead") == null) {
            std.debug.print("{s}: does not cite the TDE overhead measurement (test-sonny6435-tde-overhead)\n", .{path});
            return error.PublishedClaimMissing;
        }
        // ...and no overhead line makes an unmeasured "<1%" or "<5%" claim.
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (std.ascii.indexOfIgnoreCase(line, "overhead") == null) continue;
            if (std.mem.indexOf(u8, line, "<1%") != null or std.mem.indexOf(u8, line, "<5%") != null) {
                std.debug.print("{s}: unmeasured overhead claim: {s}\n", .{ path, line });
                return error.UnvalidatedOverheadClaim;
            }
        }
    }
}
