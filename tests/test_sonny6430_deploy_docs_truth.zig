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
    "docker-integration/docker-compose.integration.yml", // SONNY-6448 (5)
};
const deploy_docs = [_][]const u8{
    "docs/SERVER_FEATURES.md",
    "docs/DOCKER_OVERVIEW.md",
    "docs/TDE_FILE_LEVEL_ENCRYPTION.md",
    "docs/NIX_DEPLOYMENT.md",
    "docs/DOCKER_LOG_LEVEL_CONFIG.md", // SONNY-6442 (5)
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
        // SONNY-6448 (6): docs/docker/DOCKER_INTEGRATION_TESTS.md documents
        // the variables the integration-test scripts read, and those they
        // export to the client test suites they run.
        .{ .dir = "docker-integration", .ext = ".sh", .prefix = "$GEODE_" },
        .{ .dir = "docker-integration", .ext = ".sh", .prefix = "export GEODE_" },
        .{ .dir = "docker-integration", .ext = ".sh", .prefix = "${GEODE_" },
        .{ .dir = "docker-integration", .ext = ".py", .prefix = "\"GEODE_" },
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
                // A Zig / Python literal must be the whole string: "GEODE_X".
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
    for (deploy_docs) |file| bad += try unreadInDoc(allocator, &read, file);
    try testing.expectEqual(@as(usize, 0), bad);
}

/// GEODE_* names `file` gives that no source file reads, outside a
/// paragraph that says the server does not read them. Printed; returns the
/// count.
fn unreadInDoc(allocator: std.mem.Allocator, read: *const std.StringHashMap(void), file: []const u8) !usize {
    const text = try readRepoFile(allocator, file);
    defer allocator.free(text);
    var bad: usize = 0;
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
                std.debug.print("{s} names {s}, which no source file reads\n", .{ file, name });
                bad += 1;
            }
        }
    }
    return bad;
}

// SONNY-6448 (6): docs/USAGE.md, docs/deployment/DEPLOYMENT.md,
// docs/docker/DOCKER.md and .env.example still gave NODE_ID, NODE_ROLE,
// CLUSTER_NAME, GEODE_DISTRIBUTED, GEODE_SHARD_COUNT,
// GEODE_REPLICATION_FACTOR, GEODE_LOG_LEVEL, GEODE_LOG_FORMAT,
// GEODE_LISTEN_ADDR and other names nothing reads. The same rule as above
// now covers them and every docs/docker/*.md. In .env.example a GEODE_*
// name also counts when a compose file substitutes it (`${GEODE_X}`): that
// is the operator's own compose variable.
test "SONNY-6448 (6) docs/USAGE.md, docs/deployment/DEPLOYMENT.md and docs/docker/*.md name no GEODE_* variable that no source file reads" {
    const allocator = testing.allocator;
    var read = try readVariables(allocator);
    defer freeKeys(allocator, &read);
    // Sanity: the integration-test scripts' variables are found.
    try testing.expect(read.contains("GEODE_HOST"));

    var bad: usize = 0;
    bad += try unreadInDoc(allocator, &read, "docs/USAGE.md");
    bad += try unreadInDoc(allocator, &read, "docs/deployment/DEPLOYMENT.md");
    const io = std.Io.Threaded.global_single_threaded.io();
    const docker_docs = try std.fs.path.join(allocator, &.{ options.repo_root, "docs/docker" });
    defer allocator.free(docker_docs);
    var dir = try std.Io.Dir.cwd().openDir(io, docker_docs, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var seen: usize = 0;
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
        const rel = try std.fmt.allocPrint(allocator, "docs/docker/{s}", .{entry.name});
        defer allocator.free(rel);
        bad += try unreadInDoc(allocator, &read, rel);
        seen += 1;
    }
    try testing.expect(seen > 0);
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-6448 (6) .env.example sets no GEODE_* variable that neither a source file nor a compose file reads" {
    const allocator = testing.allocator;
    var read = try readVariables(allocator);
    defer freeKeys(allocator, &read);
    // Names the compose files substitute.
    var substituted: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (substituted.items) |n| allocator.free(n);
        substituted.deinit(allocator);
    }
    for (compose_files) |file| {
        const text = try readRepoFile(allocator, file);
        defer allocator.free(text);
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, text, at, "${GEODE_")) |i| {
            var end = i + 2;
            while (end < text.len and isVarChar(text[end])) end += 1;
            at = end;
            try substituted.append(allocator, try allocator.dupe(u8, text[i + 2 .. end]));
        }
    }

    const text = try readRepoFile(allocator, ".env.example");
    defer allocator.free(text);
    var bad: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "GEODE_")) continue;
        var end: usize = 0;
        while (end < line.len and isVarChar(line[end])) end += 1;
        const name = line[0..end];
        if (read.contains(name)) continue;
        const is_substituted = for (substituted.items) |n| {
            if (std.mem.eql(u8, n, name)) break true;
        } else false;
        if (!is_substituted) {
            std.debug.print("SONNY-6448 (6): .env.example sets {s}, which no source or compose file reads\n", .{name});
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

// SONNY-6448 (5): docker-compose.distributed.yml (three services) and
// docker-integration/docker-compose.integration.yml set `pids_limit` on a
// service that also has `deploy.resources.limits`; Compose takes the two as
// the same limit and `docker compose config` refuses the file ("can't set
// distinct values on 'pids_limit' and 'deploy.resources.limits.pids'"). The
// contract: no service sets both (the limit goes in
// `deploy.resources.limits.pids` there), and `docker compose config`
// accepts every compose file when docker is on PATH.
test "SONNY-6448 (5) no compose service sets pids_limit next to deploy.resources.limits" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    for (compose_files) |file| {
        const text = try readRepoFile(allocator, file);
        defer allocator.free(text);
        var service: []const u8 = "";
        var pids_limit = false;
        var limits = false;
        var in_deploy = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (true) {
            const next = lines.next();
            const line = next orelse "";
            const trimmed = std.mem.trimStart(u8, line, " ");
            const indent = line.len - trimmed.len;
            if (next != null and (trimmed.len == 0 or trimmed[0] == '#')) continue;
            // A new top-level key or service (or the end) closes the service.
            if (next == null or indent <= 2) {
                if (pids_limit and limits) {
                    std.debug.print("SONNY-6448 (5): {s}: service {s} sets pids_limit and deploy.resources.limits\n", .{ file, service });
                    bad += 1;
                }
                if (next == null) break;
                service = std.mem.trimEnd(u8, trimmed, ": \r");
                pids_limit = false;
                limits = false;
                in_deploy = false;
                continue;
            }
            if (indent == 4) {
                in_deploy = std.mem.startsWith(u8, trimmed, "deploy:");
                if (std.mem.startsWith(u8, trimmed, "pids_limit:")) pids_limit = true;
            } else if (in_deploy and std.mem.startsWith(u8, trimmed, "limits:")) {
                limits = true;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-6448 (5) docker compose config accepts every compose file" {
    const allocator = testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const probe = std.process.run(allocator, io, .{ .argv = &.{ "docker", "compose", "version" } }) catch return error.SkipZigTest;
    allocator.free(probe.stdout);
    allocator.free(probe.stderr);
    if (probe.term != .exited or probe.term.exited != 0) return error.SkipZigTest;

    var bad: usize = 0;
    for (compose_files) |file| {
        const text = try readRepoFile(allocator, file);
        defer allocator.free(text);
        // A `${NAME:?message}` variable must be set; give each a placeholder.
        var env = std.process.Environ.Map.init(allocator);
        defer env.deinit();
        try env.put("PATH", std.mem.span(std.c.getenv("PATH") orelse "/usr/bin:/bin"));
        if (std.c.getenv("HOME")) |home| try env.put("HOME", std.mem.span(home));
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, text, at, "${")) |i| {
            var end = i + 2;
            while (end < text.len and isVarChar(text[end])) end += 1;
            at = end;
            if (end + 1 < text.len and text[end] == ':' and text[end + 1] == '?') try env.put(text[i + 2 .. end], "placeholder");
        }
        const abs = try std.fs.path.join(allocator, &.{ options.repo_root, file });
        defer allocator.free(abs);
        const res = try std.process.run(allocator, io, .{
            .argv = &.{ "docker", "compose", "-f", abs, "config", "-q" },
            .environ_map = &env,
        });
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) {
            std.debug.print("SONNY-6448 (5): docker compose config rejects {s}: {s}\n", .{ file, res.stderr });
            bad += 1;
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

// SONNY-6442 (5): Dockerfile, Dockerfile.prebuilt, Dockerfile.simple and
// Dockerfile.reliable set `ENV LOG_LEVEL=error` (and Dockerfile.base and the
// dev images too), and docs/DOCKER_LOG_LEVEL_CONFIG.md documented it as the
// image's log level, but geode reads no LOG_LEVEL: only the vendored QUIC
// library's own logger does, and its default is already `error`. The server
// ran at its default `info`. docker-integration/Dockerfile.server set
// GEODE_LOG_LEVEL and GEODE_LISTEN, which nothing reads.
//
// The contract: no Dockerfile sets LOG_LEVEL or a GEODE_* variable no source
// file reads, and every image that runs `geode serve` gives its log level
// with --log-level.
const dockerfiles = [_][]const u8{
    "Dockerfile",
    "Dockerfile.base",
    "Dockerfile.ci",
    "Dockerfile.ci.alpine",
    "Dockerfile.ci.gpu",
    "Dockerfile.dev",
    "Dockerfile.devimage",
    "Dockerfile.devimage.fips",
    "Dockerfile.gpu",
    "Dockerfile.prebuilt",
    "Dockerfile.release",
    "Dockerfile.release.alpine",
    "Dockerfile.release.fips",
    "Dockerfile.release.gpu",
    "Dockerfile.reliable",
    "Dockerfile.simple",
    "docker-integration/Dockerfile.server",
};

/// The variable names an `ENV` instruction (with its `\` continuation lines)
/// sets: `ENV A=1 B=2` or the legacy `ENV A 1`.
fn dockerEnvKeys(allocator: std.mem.Allocator, text: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_env = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        var rest: []const u8 = undefined;
        if (std.mem.startsWith(u8, line, "ENV ")) {
            rest = line["ENV ".len..];
            // Legacy form `ENV KEY value`: one key, no '='.
            var first = std.mem.tokenizeScalar(u8, rest, ' ');
            if (first.next()) |tok| if (std.mem.indexOfScalar(u8, tok, '=') == null) {
                try out.append(allocator, tok);
                in_env = false;
                continue;
            };
        } else if (in_env) {
            rest = line;
        } else continue;
        in_env = std.mem.endsWith(u8, line, "\\");
        var toks = std.mem.tokenizeScalar(u8, rest, ' ');
        while (toks.next()) |tok| {
            const eq = std.mem.indexOfScalar(u8, tok, '=') orelse continue;
            var end: usize = 0;
            while (end < eq and isVarChar(tok[end])) end += 1;
            if (end == eq and end > 0) try out.append(allocator, tok[0..eq]);
        }
    }
}

test "SONNY-6442 (5) no Dockerfile sets LOG_LEVEL or a GEODE_* variable no source file reads" {
    const allocator = testing.allocator;
    var read = try readVariables(allocator);
    defer freeKeys(allocator, &read);
    var bad: usize = 0;
    for (dockerfiles) |file| {
        const text = try readRepoFile(allocator, file);
        defer allocator.free(text);
        var keys: std.ArrayListUnmanaged([]const u8) = .empty;
        defer keys.deinit(allocator);
        try dockerEnvKeys(allocator, text, &keys);
        for (keys.items) |k| {
            const unread = std.mem.eql(u8, k, "LOG_LEVEL") or (std.mem.startsWith(u8, k, "GEODE_") and !read.contains(k));
            if (unread) {
                std.debug.print("SONNY-6442 (5): {s} sets {s}, which geode does not read\n", .{ file, k });
                bad += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-6442 (5) every image that runs geode serve gives its log level with --log-level" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    var serving: usize = 0;
    for (dockerfiles) |file| {
        const text = try readRepoFile(allocator, file);
        defer allocator.free(text);
        var runs_serve = false;
        var has_level = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "ENTRYPOINT ") and !std.mem.startsWith(u8, line, "CMD ")) continue;
            if (std.mem.indexOf(u8, line, "\"serve\"") != null) runs_serve = true;
            if (std.mem.indexOf(u8, line, "\"--log-level\"") != null) has_level = true;
        }
        if (!runs_serve) continue;
        serving += 1;
        if (!has_level) {
            std.debug.print("SONNY-6442 (5): {s} runs geode serve without --log-level\n", .{file});
            bad += 1;
        }
    }
    try testing.expect(serving >= 10);
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-6442 (5) docs/DOCKER_LOG_LEVEL_CONFIG.md does not give LOG_LEVEL as the image's log level" {
    const allocator = testing.allocator;
    const text = try readRepoFile(allocator, "docs/DOCKER_LOG_LEVEL_CONFIG.md");
    defer allocator.free(text);
    var bad: usize = 0;
    for ([_][]const u8{
        "Added: `ENV LOG_LEVEL=error`",
        "docker run -e LOG_LEVEL=debug",
        "LOG_LEVEL=debug docker-compose up",
        "Server code respects LOG_LEVEL",
    }) |claim| {
        if (std.mem.indexOf(u8, text, claim) != null) {
            std.debug.print("SONNY-6442 (5): docs/DOCKER_LOG_LEVEL_CONFIG.md still says \"{s}\"\n", .{claim});
            bad += 1;
        }
    }
    try testing.expect(std.mem.indexOf(u8, text, "--log-level") != null);
    try testing.expectEqual(@as(usize, 0), bad);
}

// SONNY-6442 (7): compose hygiene.
//   - docker-compose.example.yml (and docker-compose.distributed.yml)
//     health-checked with `["CMD", "/usr/local/bin/geode query", ...]`:
//     exec form runs its first element as the program, so the check ran a
//     program named "geode query", which does not exist, and never passed;
//   - docker-compose.yml told operators to set QUIC_GO_DISABLE_GSO, a
//     quic-go (Go) variable nothing in geode reads;
//   - the geode services of docker-compose.yml, docker-compose.dev.yml and
//     docker-compose.gpu.yml waited for Vault, MinIO and Redis, which geode
//     never uses, and the dev stack ran all three.
const vault_minio_redis = [_][]const u8{ "vault", "minio", "redis" };

/// The exec-form program of each `healthcheck: test: ["CMD", <program>, ...]`.
fn healthcheckPrograms(allocator: std.mem.Allocator, text: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, "test:")) |i| {
        at = i + "test:".len;
        const open = std.mem.indexOfScalarPos(u8, text, at, '[') orelse continue;
        // The list must start right after `test:` (same or next line).
        if (std.mem.indexOfNone(u8, text[at..open], " \t\r\n") != null) continue;
        const close = std.mem.indexOfScalarPos(u8, text, open, ']') orelse continue;
        var elems = std.mem.splitScalar(u8, text[open + 1 .. close], ',');
        const first = std.mem.trim(u8, elems.next() orelse continue, " \t\r\n'\"");
        if (!std.mem.eql(u8, first, "CMD")) continue;
        const program = std.mem.trim(u8, elems.next() orelse continue, " \t\r\n'\"");
        try out.append(allocator, program);
    }
}

test "SONNY-6442 (7) every compose healthcheck runs a program, not a command line, as its exec-form first argument" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    for (compose_files) |file| {
        const text = try readRepoFile(allocator, file);
        defer allocator.free(text);
        var programs: std.ArrayListUnmanaged([]const u8) = .empty;
        defer programs.deinit(allocator);
        try healthcheckPrograms(allocator, text, &programs);
        for (programs.items) |p| {
            if (std.mem.indexOfScalar(u8, p, ' ') != null) {
                std.debug.print("SONNY-6442 (7): {s} health-checks with the program \"{s}\"\n", .{ file, p });
                bad += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-6442 (7) no compose file names the quic-go QUIC_GO_* variables" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    for (compose_files) |file| {
        const text = try readRepoFile(allocator, file);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, "QUIC_GO_") != null) {
            std.debug.print("SONNY-6442 (7): {s} names a QUIC_GO_* variable\n", .{file});
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-6442 (7) no geode service waits for Vault, MinIO or Redis, and the dev and GPU stacks run none of them" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    for (compose_files) |file| {
        const text = try readRepoFile(allocator, file);
        defer allocator.free(text);
        const stack_without = std.mem.eql(u8, file, "docker-compose.dev.yml") or std.mem.eql(u8, file, "docker-compose.gpu.yml");
        var service: []const u8 = "";
        var in_depends = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimStart(u8, line, " ");
            const indent = line.len - trimmed.len;
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            if (indent == 2 and std.mem.endsWith(u8, std.mem.trimEnd(u8, trimmed, " \r"), ":")) {
                service = std.mem.trimEnd(u8, trimmed, ": \r");
                in_depends = false;
                if (stack_without) for (vault_minio_redis) |name| {
                    if (std.mem.eql(u8, service, name)) {
                        std.debug.print("SONNY-6442 (7): {s} runs a {s} service\n", .{ file, name });
                        bad += 1;
                    }
                };
                continue;
            }
            if (indent == 4) in_depends = std.mem.startsWith(u8, trimmed, "depends_on:");
            if (!in_depends or indent <= 4 or !std.mem.startsWith(u8, service, "geode")) continue;
            const item = std.mem.trimEnd(u8, if (std.mem.startsWith(u8, trimmed, "- ")) trimmed[2..] else trimmed, ": \r");
            for (vault_minio_redis) |name| {
                if (std.mem.eql(u8, item, name)) {
                    std.debug.print("SONNY-6442 (7): {s}: service {s} depends on {s}\n", .{ file, service, name });
                    bad += 1;
                }
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}
