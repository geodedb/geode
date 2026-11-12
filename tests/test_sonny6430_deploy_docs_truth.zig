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

// SONNY-6435 (5): the compose files and the deployment docs named variables
// and KMS providers the server never reads. A name counts as read when a
// source file reads it: a quoted literal in src/**/*.zig, or `$NAME` in the
// image's shell scripts (docker/*.sh). Every GEODE_* name these files give
// must be one. Compose files are checked on their `environment:` keys only
// (a `${GEODE_X}` interpolation is the operator's own variable); docs on
// every GEODE_* name, except in a paragraph that says the server does not
// read it ("reads none of", "does not read", "there is no").
const compose_files = [_][]const u8{
    "docker-compose.yml",
    "docker-compose.dev.yml",
    "docker-compose.distributed.yml",
    "docker-compose.example.yml",
    "docker-compose.gpu.yml",
    "docker-compose.otel.yml",
    "docker-compose.override.yml",
};
const deploy_docs = [_][]const u8{
    "docs/SERVER_FEATURES.md",
    "docs/DOCKER_OVERVIEW.md",
    "docs/TDE_FILE_LEVEL_ENCRYPTION.md",
    "docs/NIX_DEPLOYMENT.md",
};

fn isVarChar(c: u8) bool {
    return std.ascii.isUpper(c) or std.ascii.isDigit(c) or c == '_';
}

/// Every GEODE_* variable a source file reads (see above).
fn readVariables(allocator: std.mem.Allocator) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(allocator);
    errdefer freeKeys(allocator, &set);
    const io = std.Io.Threaded.global_single_threaded.io();
    for ([_]struct { dir: []const u8, ext: []const u8, prefix: []const u8 }{
        .{ .dir = "src", .ext = ".zig", .prefix = "\"GEODE_" },
        .{ .dir = "docker", .ext = ".sh", .prefix = "$GEODE_" },
        .{ .dir = "docker", .ext = ".sh", .prefix = "${GEODE_" },
    }) |scan| {
        const root = try std.fs.path.join(allocator, &.{ options.repo_root, scan.dir });
        defer allocator.free(root);
        var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, scan.ext)) continue;
            const text = try dir.readFileAlloc(io, entry.path, allocator, .limited(64 << 20));
            defer allocator.free(text);
            var at: usize = 0;
            while (std.mem.indexOfPos(u8, text, at, scan.prefix)) |i| {
                const start = i + scan.prefix.len - "GEODE_".len;
                var end = start + "GEODE_".len;
                while (end < text.len and isVarChar(text[end])) end += 1;
                at = end;
                // A Zig literal must be the whole string: "GEODE_X".
                if (scan.prefix[0] == '"' and (end >= text.len or text[end] != '"')) continue;
                if (set.contains(text[start..end])) continue;
                try set.put(try allocator.dupe(u8, text[start..end]), {});
            }
        }
    }
    return set;
}

fn freeKeys(allocator: std.mem.Allocator, set: *std.StringHashMap(void)) void {
    var it = set.keyIterator();
    while (it.next()) |k| allocator.free(k.*);
    set.deinit();
}

/// The `environment:` keys a compose file gives (`- NAME=` or `NAME:`).
fn composeEnvKeys(allocator: std.mem.Allocator, text: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var in_env = false;
    var env_indent: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " ");
        const indent = line.len - trimmed.len;
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (std.mem.startsWith(u8, trimmed, "environment:")) {
            in_env = true;
            env_indent = indent;
            continue;
        }
        if (!in_env) continue;
        if (indent <= env_indent) {
            in_env = false;
            continue;
        }
        const item = if (std.mem.startsWith(u8, trimmed, "- ")) trimmed[2..] else trimmed;
        var end: usize = 0;
        while (end < item.len and isVarChar(item[end])) end += 1;
        if (end > 0 and end < item.len and (item[end] == '=' or item[end] == ':')) try out.append(allocator, item[0..end]);
    }
}

test "SONNY-6435 (5) the compose files and the deployment docs name no GEODE_* variable that no source file reads" {
    const allocator = testing.allocator;
    var read = try readVariables(allocator);
    defer freeKeys(allocator, &read);
    // Sanity: the scan finds variables the server does read.
    for ([_][]const u8{ "GEODE_TDE_KEY", "GEODE_DATA_DIR", "GEODE_MASTER_KEY", "GEODE_HEALTH_PORT" }) |known| {
        try testing.expect(read.contains(known));
    }

    var bad: usize = 0;
    for (compose_files) |file| {
        const text = try readRepoFile(allocator, file);
        defer allocator.free(text);
        var keys: std.ArrayListUnmanaged([]const u8) = .empty;
        defer keys.deinit(allocator);
        try composeEnvKeys(allocator, text, &keys);
        for (keys.items) |k| {
            if (std.mem.startsWith(u8, k, "GEODE_") and !read.contains(k)) {
                std.debug.print("SONNY-6435 (5): {s} passes {s}, which no source file reads\n", .{ file, k });
                bad += 1;
            }
        }
    }
    for (deploy_docs) |file| {
        const text = try readRepoFile(allocator, file);
        defer allocator.free(text);
        var paragraphs = std.mem.splitSequence(u8, text, "\n\n");
        while (paragraphs.next()) |para| {
            if (std.mem.indexOf(u8, para, "reads none of") != null or std.mem.indexOf(u8, para, "does not read") != null or
                std.ascii.indexOfIgnoreCase(para, "there is no") != null) continue;
            var at: usize = 0;
            while (std.mem.indexOfPos(u8, para, at, "GEODE_")) |i| {
                var end = i + "GEODE_".len;
                while (end < para.len and isVarChar(para[end])) end += 1;
                at = end;
                if (i > 0 and isVarChar(para[i - 1])) continue;
                const name = para[i..end];
                if (!read.contains(name)) {
                    std.debug.print("SONNY-6435 (5): {s} names {s}, which no source file reads\n", .{ file, name });
                    bad += 1;
                }
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

// The non-GEODE_* names and the KMS providers geode never reads, as the
// compose files gave them to a geode service and the docs listed them.
const unread_claims = [_]Claim{
    .{ .file = "docker-compose.yml", .text = "- REDIS_URL=" },
    .{ .file = "docker-compose.yml", .text = "- VAULT_TOKEN=" },
    .{ .file = "docker-compose.yml", .text = "- LOG_LEVEL=" },
    .{ .file = "docker-compose.dev.yml", .text = "- REDIS_URL=" },
    .{ .file = "docker-compose.dev.yml", .text = "- FIPS_MODE=" },
    .{ .file = "docker-compose.dev.yml", .text = "- RUST_BACKTRACE=" },
    .{ .file = "docker-compose.dev.yml", .text = "- LOG_LEVEL=" },
    .{ .file = "docker-compose.gpu.yml", .text = "- REDIS_URL=" },
    .{ .file = "docker-compose.gpu.yml", .text = "- FIPS_MODE=" },
    .{ .file = "docker-compose.gpu.yml", .text = "- GPU_ENABLED=" },
    .{ .file = "docker-compose.gpu.yml", .text = "- LOG_LEVEL=" },
    .{ .file = "docker-compose.gpu.yml", .text = "- VAULT_TOKEN=" },
    .{ .file = "docker-compose.distributed.yml", .text = "- NODE_ID=" },
    .{ .file = "docker-compose.distributed.yml", .text = "- NODE_ROLE=" },
    .{ .file = "docker-compose.distributed.yml", .text = "- CLUSTER_NAME=" },
    .{ .file = "docker-compose.distributed.yml", .text = "- RAFT_PORT=" },
    .{ .file = "docker-compose.distributed.yml", .text = "- RAFT_PEERS=" },
    .{ .file = "docker-compose.distributed.yml", .text = "- RAFT_JOIN=" },
    .{ .file = "docker-compose.distributed.yml", .text = "- CLUSTER_NODES=" },
    .{ .file = "docker-compose.distributed.yml", .text = "- LOG_LEVEL=" },
    .{ .file = "docker-compose.distributed.yml", .text = "--raft-bind" },
    .{ .file = "docker-compose.distributed.yml", .text = "--bootstrap-expect" },
    .{ .file = "docker-compose.distributed.yml", .text = "--log-json" },
    .{ .file = "docker-compose.example.yml", .text = "- LOG_LEVEL=" },
    .{ .file = "docker-compose.override.yml", .text = "- LOG_LEVEL=" },
    .{ .file = "docker-compose.override.yml", .text = "- RUST_BACKTRACE=" },
    .{ .file = "docker-compose.otel.yml", .text = "LOG_LEVEL: " },
    .{ .file = "docs/SERVER_FEATURES.md", .text = "**HashiCorp Vault**: Enterprise production" },
    .{ .file = "docs/SERVER_FEATURES.md", .text = "**AWS KMS**: Cloud deployments" },
    .{ .file = "docs/SERVER_FEATURES.md", .text = "**Azure Key Vault**: Azure cloud" },
    .{ .file = "docs/SERVER_FEATURES.md", .text = "**GCP KMS**: Google Cloud" },
    .{ .file = "docs/SERVER_FEATURES.md", .text = "VaultKMSProvider.init(allocator, vault_config)" },
    .{ .file = "docs/SERVER_FEATURES.md", .text = "- `CDC_ENABLED`: Enable change data capture" },
    .{ .file = "docs/SERVER_FEATURES.md", .text = "kms_provider = \"vault\"" },
    .{ .file = "docs/SERVER_FEATURES.md", .text = "**Page-Level**: XTS-AES-256 for storage pages" },
    .{ .file = "docs/DOCKER_OVERVIEW.md", .text = "| `VAULT_ADDR` | - | HashiCorp Vault address |" },
    .{ .file = "docs/DOCKER_OVERVIEW.md", .text = "| `REDIS_URL` | - | Redis cache connection string |" },
    .{ .file = "docs/DOCKER_OVERVIEW.md", .text = "| `FIPS_MODE` | - | Enable FIPS 140-2 compliant cryptography |" },
    .{ .file = "docs/DOCKER_OVERVIEW.md", .text = "| `LOG_LEVEL` | `error` | Logging verbosity" },
    .{ .file = "docs/DOCKER_OVERVIEW.md", .text = "- VAULT_TOKEN=${VAULT_TOKEN}" },
    .{ .file = "docs/DOCKER_OVERVIEW.md", .text = "- GPU_ENABLED=true" },
    .{ .file = "docs/TDE_FILE_LEVEL_ENCRYPTION.md", .text = "for automated key rotation support" },
};

test "SONNY-6435 (5) the compose files and the deployment docs give geode no REDIS_*, VAULT_*, FIPS_MODE, GPU_ENABLED, LOG_LEVEL, NODE_*, RAFT_* or CLUSTER_* setting, cluster option or KMS provider it does not have" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    for (unread_claims) |c| {
        const text = try readRepoFile(allocator, c.file);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, c.text) != null) {
            std.debug.print("SONNY-6435 (5): {s} still says \"{s}\"\n", .{ c.file, c.text });
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
