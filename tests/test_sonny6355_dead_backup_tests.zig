// SONNY-6355 item 4: dead backup tests and stale canaryscan rows.
//
// tests/e2e_s3_backup_restore.zig and tests/test_s3_backup.zig exercised a
// mock S3 client, were imported only by tests/all_tests.zig (which nothing
// compiles) and were in no build step: they never ran, and the binary has no
// object-storage backup path (SONNY-6290). tools/canaryscan/status.csv, the
// scanner's committed output, still listed CANARY rows from files deleted
// long ago (the backup API tests at rows 476, 1754 and 3429 among them), so
// the scanner's report claimed evidence that no longer existed.
//
// Checked here: neither mock test exists or is imported, every file
// tests/all_tests.zig imports exists, and every row of
// tools/canaryscan/status.csv names a source file that exists.
//
// CANARY: REQ=REQ-SONNY-6355-DEAD-BACKUP-TESTS; FEATURE="Test Hygiene"; ASPECT=NoDeadBackupTestsOrStaleCanaryRows; STATUS=TESTED; TEST=tests/test_sonny6355_dead_backup_tests.zig; OWNER=storage; UPDATED=2026-11-12
const std = @import("std");
const options = @import("sonny6355_options");

const testing = std.testing;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn readRepoFile(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    const abs = try std.fs.path.join(allocator, &.{ options.repo_root, rel });
    defer allocator.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(io(), abs, allocator, .limited(64 << 20));
}

fn repoFileExists(allocator: std.mem.Allocator, rel: []const u8) !bool {
    const abs = try std.fs.path.join(allocator, &.{ options.repo_root, rel });
    defer allocator.free(abs);
    std.Io.Dir.cwd().access(io(), abs, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

test "SONNY-6355 (4) the mock S3 backup tests are gone and all_tests.zig imports only files that exist" {
    const allocator = testing.allocator;
    var failures: usize = 0;
    for ([_][]const u8{ "tests/e2e_s3_backup_restore.zig", "tests/test_s3_backup.zig" }) |dead| {
        if (try repoFileExists(allocator, dead)) {
            std.debug.print("SONNY-6355: {s} (mock S3, built by nothing) still exists\n", .{dead});
            failures += 1;
        }
    }

    const src = try readRepoFile(allocator, "tests/all_tests.zig");
    defer allocator.free(src);
    var pos: usize = 0;
    var imports: usize = 0;
    while (std.mem.indexOfPos(u8, src, pos, "@import(\"")) |at| {
        pos = at + "@import(\"".len;
        const end = std.mem.indexOfScalarPos(u8, src, pos, '"') orelse break;
        const name = src[pos..end];
        if (!std.mem.endsWith(u8, name, ".zig")) continue;
        imports += 1;
        const rel = try std.fs.path.join(allocator, &.{ "tests", name });
        defer allocator.free(rel);
        if (!try repoFileExists(allocator, rel)) {
            std.debug.print("SONNY-6355: tests/all_tests.zig imports {s}, which does not exist\n", .{rel});
            failures += 1;
        }
        if (std.mem.indexOf(u8, name, "s3_backup") != null) {
            std.debug.print("SONNY-6355: tests/all_tests.zig imports the mock S3 test {s}\n", .{name});
            failures += 1;
        }
    }
    try testing.expect(imports > 50);
    try testing.expectEqual(@as(usize, 0), failures);
}

/// Field `index` of a CSV line (RFC 4180 quoting; a quoted field is
/// returned with its quotes when it contains a doubled quote, which no file
/// path does).
fn csvField(line: []const u8, index: usize) ?[]const u8 {
    var i: usize = 0;
    var field: usize = 0;
    while (i <= line.len) {
        var start = i;
        var end = i;
        if (i < line.len and line[i] == '"') {
            var j = i + 1;
            while (j < line.len) : (j += 1) {
                if (line[j] == '"') {
                    if (j + 1 < line.len and line[j + 1] == '"') {
                        j += 1;
                        continue;
                    }
                    break;
                }
            }
            start = i + 1;
            end = @min(j, line.len);
            i = @min(j + 1, line.len);
        } else {
            while (i < line.len and line[i] != ',') i += 1;
            end = i;
        }
        if (field == index) return line[start..end];
        field += 1;
        if (i >= line.len) return null;
        i += 1; // the comma
    }
    return null;
}

test "SONNY-6355 (4) csvField reads quoted and plain fields" {
    const line = "REQ-X,\"feature, with comma\",Aspect,TESTED,src/a.zig,\"\"\"quoted\"\"\",,own,2026";
    try testing.expectEqualStrings("REQ-X", csvField(line, 0).?);
    try testing.expectEqualStrings("feature, with comma", csvField(line, 1).?);
    try testing.expectEqualStrings("src/a.zig", csvField(line, 4).?);
    try testing.expectEqualStrings("", csvField(line, 6).?);
    try testing.expectEqualStrings("2026", csvField(line, 8).?);
    try testing.expect(csvField(line, 9) == null);
}

test "SONNY-6355 (4) every canaryscan status row names a source file that exists" {
    const allocator = testing.allocator;
    const csv = try readRepoFile(allocator, "tools/canaryscan/status.csv");
    defer allocator.free(csv);

    var lines = std.mem.splitScalar(u8, csv, '\n');
    const header = lines.next() orelse return error.EmptyStatusCsv;
    try testing.expect(std.mem.startsWith(u8, header, "req,feature,aspect,status,file,"));

    var rows: usize = 0;
    var stale: usize = 0;
    var line_no: usize = 1;
    while (lines.next()) |line| {
        line_no += 1;
        if (line.len == 0) continue;
        rows += 1;
        const file = csvField(line, 4) orelse continue;
        if (file.len == 0) continue;
        if (!try repoFileExists(allocator, file)) {
            if (stale < 20) std.debug.print("SONNY-6355: tools/canaryscan/status.csv:{d}: {s} does not exist\n", .{ line_no, file });
            stale += 1;
        }
    }
    try testing.expect(rows > 1000);
    if (stale != 0) std.debug.print("SONNY-6355: {d} canaryscan rows name a file that does not exist (regenerate: go build -o bin/canaryscan ./tools/canaryscan && bin/canaryscan --root . --out tools/canaryscan/status.json --csv tools/canaryscan/status.csv)\n", .{stale});
    try testing.expectEqual(@as(usize, 0), stale);
}
