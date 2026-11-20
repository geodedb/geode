// CANARY: REQ=REQ-SONNY-6386-DEAD-MOCK-STALE-DOCS; FEATURE="Test Hygiene"; ASPECT=NoMockBackupTestNoStaleArchitectureDocs; STATUS=TESTED; TEST=tests/test_sonny6386_dead_mock_and_stale_docs.zig; OWNER=storage; UPDATED=2026-11-12
//
// SONNY-6386 items 4 and 8.
//
// (4) tests/test_backup_integration.zig redefined BackupConfig, BackupType,
//     BackupMetadata and a backup "manager" inside the test file and tested
//     those copies; no build step compiled it, so it never ran, and its
//     CANARY (REQ-GQL-201, STATUS=TESTED) claimed evidence for code it never
//     touched. The project forbids mocks of engine behaviour: it is removed.
//
// (8) docs/CURRENT_ARCHITECTURE.md described the backup path as
//     "Backup Command -> Backup Manager -> S3 Upload -> Encryption ->
//     Compression" (no command uploads to object storage, SONNY-6290, and the
//     payload is compressed before it is encrypted) and the language as Zig
//     0.15.1+ (build.zig.zon requires 0.16.0). docs/CHANGELOG.md said
//     `test-tde-kms-integration` ran 8/8; that step, its test and
//     src/security/tde_kms_integration.zig do not exist (SONNY-6298).
const std = @import("std");
const options = @import("sonny6386_options");

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

/// `text` with every run of whitespace collapsed to one space. Caller frees.
fn collapseWhitespace(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var in_space = false;
    for (text) |c| {
        if (std.ascii.isWhitespace(c)) {
            if (!in_space) try out.append(allocator, ' ');
            in_space = true;
        } else {
            try out.append(allocator, c);
            in_space = false;
        }
    }
    return out.toOwnedSlice(allocator);
}

const mock_test = "tests/test_backup_integration.zig";

test "SONNY-6386 (4) the self-contained mock backup test is gone and nothing cites it" {
    const allocator = testing.allocator;
    var failures: usize = 0;
    if (try repoFileExists(allocator, mock_test)) {
        std.debug.print("SONNY-6386 (4): {s} (redefines BackupConfig, built by nothing) still exists\n", .{mock_test});
        failures += 1;
    }
    for ([_][]const u8{ "build.zig", "tests/all_tests.zig", "docs/status.csv", "tools/canaryscan/status.csv", "tools/canaryscan/status.json" }) |rel| {
        const text = try readRepoFile(allocator, rel);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, mock_test) != null or std.mem.indexOf(u8, text, "test_backup_integration.zig") != null) {
            std.debug.print("SONNY-6386 (4): {s} still names {s}\n", .{ rel, mock_test });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-6386 (8) docs/CURRENT_ARCHITECTURE.md describes the backup path and Zig version that exist" {
    const allocator = testing.allocator;
    const raw = try readRepoFile(allocator, "docs/CURRENT_ARCHITECTURE.md");
    defer allocator.free(raw);
    const doc = try collapseWhitespace(allocator, raw);
    defer allocator.free(doc);
    var failures: usize = 0;
    for ([_][]const u8{ "S3 Upload", "Zig 0.15" }) |stale| {
        if (std.mem.indexOf(u8, doc, stale) != null) {
            std.debug.print("SONNY-6386 (8): docs/CURRENT_ARCHITECTURE.md still says \"{s}\"\n", .{stale});
            failures += 1;
        }
    }
    for ([_][]const u8{ "Zig 0.16.0+", "GEODE_TDE_KEY", "src/cli/backup_cli.zig", "src/server/backup_manager.zig" }) |needed| {
        if (std.mem.indexOf(u8, doc, needed) == null) {
            std.debug.print("SONNY-6386 (8): docs/CURRENT_ARCHITECTURE.md does not mention {s}\n", .{needed});
            failures += 1;
        }
    }
    // The order the payload is processed in: compressed, then encrypted.
    const comp = std.mem.indexOf(u8, doc, "compress (gzip");
    const enc = std.mem.indexOf(u8, doc, "encrypt (AES-256-GCM");
    if (comp == null or enc == null or comp.? > enc.?) {
        std.debug.print("SONNY-6386 (8): the backup flow must show compression (gzip) before encryption (AES-256-GCM)\n", .{});
        failures += 1;
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-6386 (8) docs/CHANGELOG.md does not claim test-tde-kms-integration runs" {
    const allocator = testing.allocator;
    const raw = try readRepoFile(allocator, "docs/CHANGELOG.md");
    defer allocator.free(raw);
    const doc = try collapseWhitespace(allocator, raw);
    defer allocator.free(doc);
    if (std.mem.indexOf(u8, doc, "`test-tde-kms-integration` 8/8") != null) {
        std.debug.print("SONNY-6386 (8): docs/CHANGELOG.md claims `test-tde-kms-integration` 8/8; no such step exists\n", .{});
        return error.TestUnexpectedResult;
    }
    const build_zig = try readRepoFile(allocator, "build.zig");
    defer allocator.free(build_zig);
    try testing.expect(std.mem.indexOf(u8, build_zig, "\"test-tde-kms-integration\"") == null);
    try testing.expect(!try repoFileExists(allocator, "tests/test_tde_kms_integration.zig"));
    try testing.expect(!try repoFileExists(allocator, "src/security/tde_kms_integration.zig"));
}
