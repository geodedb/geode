// CANARY: REQ=REQ-SONNY-6422-BACKUP-DOCS-TRUTH; FEATURE="Docs"; ASPECT=NoObjectStorageOrRemovedTestClaims; STATUS=TESTED; TEST=tests/test_sonny6422_backup_docs_truth.zig; OWNER=docs; UPDATED=2026-11-12
//
// SONNY-6422 (9): docs still presented `src/storage/s3_backup.zig` / S3 /
// DigitalOcean Spaces as a working backup target, which it is not: no
// command reaches object storage (SONNY-6290; real support is SONNY-6356).
// `geode backup create` writes a local file and refuses an s3:// output.
// A spec also pointed at `tde_kms_integration.zig` as current code, which
// was never compiled and was removed (SONNY-6298).
//
// The contract: none of these docs claims an object-storage backup target,
// a backup option or variable that does not exist, or the removed TDE-KMS
// file as current code.
const std = @import("std");
const options = @import("sonny6422_bd_options");

const testing = std.testing;

fn readRepoFile(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    const abs = try std.fs.path.join(allocator, &.{ options.repo_root, rel });
    defer allocator.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), abs, allocator, .limited(64 << 20));
}

const Claim = struct { file: []const u8, text: []const u8 };

const false_claims = [_]Claim{
    .{ .file = "docs/TODO.md", .text = "S3 Cloud Backup**: Production-ready" },
    .{ .file = "docs/GQL_COMPLIANCE.md", .text = "S3 / DigitalOcean Spaces upload" },
    .{ .file = "docs/SERVER_FEATURES.md", .text = "### 1.4 S3 Cloud Backup" },
    .{ .file = "docs/SERVER_FEATURES.md", .text = "Upload to S3 with metadata" },
    .{ .file = "docs/SERVER_FEATURES.md", .text = "Multipart upload: 50-100MB/s" },
    .{ .file = "docs/DOCKER_OVERVIEW.md", .text = "S3-compatible backup endpoint" },
    .{ .file = "docs/DOCKER_OVERVIEW.md", .text = "S3 bucket for backups" },
    .{ .file = "docs/NIX_DEPLOYMENT.md", .text = "s3Bucket" },
    .{ .file = "specs/security/field-level-enc-research-report-pqc-PR.md", .text = "see current TDE usage at `tde_kms_integration.zig`" },
    .{ .file = "specs/security/field-level-enc-research-report-pqc-PR.md", .text = "TDE already has canary tests; see `tests/test_tde_kms_integration.zig`" },
};

test "SONNY-6422 (9) no doc presents S3 / Spaces as a working backup target or the removed TDE-KMS integration as current code" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    for (false_claims) |c| {
        const text = try readRepoFile(allocator, c.file);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, c.text) != null) {
            std.debug.print("SONNY-6422 (9): {s} still says \"{s}\"\n", .{ c.file, c.text });
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}
