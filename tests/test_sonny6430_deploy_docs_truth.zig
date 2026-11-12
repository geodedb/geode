// CANARY: REQ=REQ-SONNY-6430-DEPLOY-DOCS-TRUTH; FEATURE="Docs"; ASPECT=NoUnreadDeployConfig; STATUS=TESTED; TEST=tests/test_sonny6430_deploy_docs_truth.zig; OWNER=docs; UPDATED=2026-11-12
//
// SONNY-6430 (9): deployment config and docs that described settings the
// server does not have:
//   - docker-compose.yml, docker-compose.dev.yml and docker-compose.gpu.yml
//     passed S3_ENDPOINT / S3_ACCESS_KEY / S3_SECRET_KEY / S3_BUCKET to the
//     geode service, which reads none of them (backups are local files);
//   - docs/SERVER_FEATURES.md 1.3 gave the disk key as GEODE_DISK_KEY_HEX
//     (read by nothing; the key is GEODE_TDE_KEY), a hierarchical key
//     derivation, Vault / AWS KMS integration and automatic key rotation,
//     none of which the server has;
//   - docs/NIX_DEPLOYMENT.md configured `services.geode.federation`, from a
//     NixOS module that was removed with the rest of the Nix packaging;
//   - docs/audit/security-phase1-inventory.md gave GEODE_WAL_KEY as the WAL
//     key (the WAL is encrypted with GEODE_TDE_KEY; GEODE_WAL_KEY refuses
//     startup).
//
// The contract: none of these files makes those claims.
const std = @import("std");
const options = @import("sonny6430_dd_options");

const testing = std.testing;

fn readRepoFile(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    const abs = try std.fs.path.join(allocator, &.{ options.repo_root, rel });
    defer allocator.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), abs, allocator, .limited(64 << 20));
}

const Claim = struct { file: []const u8, text: []const u8 };

const false_claims = [_]Claim{
    .{ .file = "docker-compose.yml", .text = "- S3_ENDPOINT=" },
    .{ .file = "docker-compose.yml", .text = "- S3_BUCKET=" },
    .{ .file = "docker-compose.dev.yml", .text = "- S3_ENDPOINT=" },
    .{ .file = "docker-compose.dev.yml", .text = "- S3_BUCKET=" },
    .{ .file = "docker-compose.gpu.yml", .text = "- S3_ENDPOINT=" },
    .{ .file = "docker-compose.gpu.yml", .text = "- S3_BUCKET=" },
    .{ .file = "docs/SERVER_FEATURES.md", .text = "Master key from environment: `GEODE_DISK_KEY_HEX`" },
    .{ .file = "docs/SERVER_FEATURES.md", .text = "- `GEODE_DISK_KEY_HEX`: Master encryption key" },
    .{ .file = "docs/SERVER_FEATURES.md", .text = "Integration with HashiCorp Vault and AWS KMS" },
    .{ .file = "docs/SERVER_FEATURES.md", .text = "Automatic key rotation support" },
    .{ .file = "docs/SERVER_FEATURES.md", .text = "Hierarchical key derivation for data, WAL, and backup keys" },
    .{ .file = "docs/SERVER_FEATURES.md", .text = "**Implementation**: `/src/storage/disk.zig`" },
    .{ .file = "docs/NIX_DEPLOYMENT.md", .text = "federation = {" },
    .{ .file = "docs/NIX_DEPLOYMENT.md", .text = "federation.enable = true;" },
    .{ .file = "docs/audit/security-phase1-inventory.md", .text = "| `GEODE_WAL_KEY` (hex) |" },
    .{ .file = "docs/audit/security-phase1-inventory.md", .text = "env `GEODE_WAL_KEY`, KMS" },
};

test "SONNY-6430 (9) deployment config and docs do not describe S3_* variables, a disk key, KMS integration, rotation, a Nix federation block or a WAL key the server does not have" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    for (false_claims) |c| {
        const text = try readRepoFile(allocator, c.file);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, c.text) != null) {
            std.debug.print("SONNY-6430 (9): {s} still says \"{s}\"\n", .{ c.file, c.text });
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-6430 (9) docs/NIX_DEPLOYMENT.md says the Nix packaging is not in this repository" {
    const allocator = testing.allocator;
    const text = try readRepoFile(allocator, "docs/NIX_DEPLOYMENT.md");
    defer allocator.free(text);
    // The repository has no flake.nix; the guide must say so up front.
    const head = text[0..@min(text.len, 2000)];
    try testing.expect(std.mem.indexOf(u8, head, "not in this repository") != null);
}
