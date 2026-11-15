// SONNY-6374 items 3-8: server and test residuals found during
// SONNY-6332/6320/6328.
//
//   (3) `geode serve --help` gave `--listen-grpc 0.0.0.0:3142` as the
//       example, the port the embedded LSP listener takes by default, and
//       did not mention `--lsp-port` at all.
//   (4) GEODE_ENABLE_ABAC logged "ABAC enforcement enabled" although no
//       request path enforces ABAC (SONNY-6376 tracks enforcement).
//   (5) verifyPasswordArgon2id narrowed the parsed `p` with @intCast into
//       Argon2's u24: a corrupt stored hash with p above 2^24-1 panicked a
//       safe build (and was undefined behaviour in a release build).
//   (6) the GAP-0193 batch 2 security and testing suites asserted
//       `... or true` and were compiled by no build step.
//   (7) CANARY TEST= tokens named test files that do not exist.
//   (8) modules nothing imports: src/performance/async_io_simple.zig, and
//       src/distributed/federation_latency_aggregate.zig outside its own
//       tests (which no build step compiled either).
//
// The canaryscan row order (item 7, first half) is covered by
// tools/canaryscan/scan_test.go (`go test` in tools/canaryscan).
//
// CANARY: REQ=REQ-SONNY-6374-SERVER-RESIDUALS; FEATURE="Server Hygiene"; ASPECT=HelpAbacArgonCanaryDeadCode; STATUS=TESTED; TEST=tests/test_sonny6374_server_residuals.zig; OWNER=server; UPDATED=2026-11-12
const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const geode_test_bin = @import("geode_test_bin");
const options = @import("sonny6374_options");
const build_options = @import("build_options");

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

// ---------------------------------------------------------------------------
// (3) serve --help
// ---------------------------------------------------------------------------

test "SONNY-6374 (3) serve --help does not give the LSP default port as the gRPC example and documents --lsp-port" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const result = try std.process.run(allocator, threaded.io(), .{
        .argv = &.{ geode_test_bin.geode_exe, "serve", "--help" },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const text = try std.mem.concat(allocator, u8, &.{ result.stdout, result.stderr });
    defer allocator.free(text);

    var bad: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "--listen-grpc") == null) continue;
        if (std.mem.indexOf(u8, line, ":3142") != null) {
            bad += 1;
            std.debug.print("SONNY-6374 (3): gRPC example on the LSP default port 3142: {s}\n", .{line});
        }
    }
    if (std.mem.indexOf(u8, text, "--lsp-port") == null) {
        bad += 1;
        std.debug.print("SONNY-6374 (3): serve --help does not mention --lsp-port\n", .{});
    }
    if (bad != 0) std.debug.print("serve --help:\n{s}\n", .{text});
    try testing.expectEqual(@as(usize, 0), bad);
}

// ---------------------------------------------------------------------------
// (4) the ABAC startup log
// ---------------------------------------------------------------------------

test "SONNY-6374 (4) no startup log claims ABAC is enforced" {
    const allocator = testing.allocator;
    const src = try readRepoFile(allocator, "src/server/server_init.zig");
    defer allocator.free(src);
    for ([_][]const u8{ "ABAC enforcement enabled", "ABAC enforcement disabled" }) |claim| {
        if (std.mem.indexOf(u8, src, claim) != null) {
            std.debug.print("SONNY-6374 (4): src/server/server_init.zig logs \"{s}\"; no request path enforces ABAC (SONNY-6376)\n", .{claim});
            return error.TestUnexpectedResult;
        }
    }
}

// ---------------------------------------------------------------------------
// (5) a corrupt Argon2id parallelism parameter
// ---------------------------------------------------------------------------

const salt_hex = "000102030405060708090a0b0c0d0e0f";
const hash_hex = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

fn phc(buf: []u8, params: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "$argon2id$v=19${s}${s}${s}", .{ params, salt_hex, hash_hex });
}

test "SONNY-6374 (5) verifyPasswordArgon2id refuses a stored hash whose parameters are out of range" {
    if (build_options.fips) return error.SkipZigTest;
    const allocator = testing.allocator;
    var buf: [256]u8 = undefined;
    // p above Argon2's u24 lanes limit: @intCast panicked here.
    for ([_][]const u8{
        "m=19456,t=2,p=4294967295",
        "m=19456,t=2,p=16777216",
        "m=19456,t=2,p=0",
        // An unparseable parameter used to fall back to the default value.
        "m=19456,t=2,p=x",
        "m=x,t=2,p=1",
        "m=19456,t=-1,p=1",
    }) |params| {
        const s = try phc(&buf, params);
        // SONNY-6598: refused as an unusable hash (an error), not a mismatch.
        try testing.expectError(error.InvalidHashFormat, geode.auth.verifyPasswordArgon2id(allocator, "password", s));
    }
}

// ---------------------------------------------------------------------------
// (6) always-true assertions
// ---------------------------------------------------------------------------

test "SONNY-6374 (6) the GAP-0193 batch 2 security and testing suites assert nothing always-true and are built" {
    const allocator = testing.allocator;
    const build_src = try readRepoFile(allocator, "build.zig");
    defer allocator.free(build_src);
    var bad: usize = 0;
    for ([_][]const u8{ "tests/test_gap_0193_batch2_security.zig", "tests/test_gap_0193_batch2_testing.zig" }) |rel| {
        const src = try readRepoFile(allocator, rel);
        defer allocator.free(src);
        var lines = std.mem.splitScalar(u8, src, '\n');
        var n: usize = 0;
        while (lines.next()) |line| {
            n += 1;
            if (std.mem.indexOf(u8, line, "or true)") != null) {
                bad += 1;
                std.debug.print("SONNY-6374 (6): {s}:{d}: always-true assertion: {s}\n", .{ rel, n, std.mem.trim(u8, line, " ") });
            }
        }
        const reg = try std.fmt.allocPrint(allocator, "b.path(\"{s}\")", .{rel});
        defer allocator.free(reg);
        if (std.mem.indexOf(u8, build_src, reg) == null) {
            bad += 1;
            std.debug.print("SONNY-6374 (6): {s} is compiled by no build step\n", .{rel});
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

// ---------------------------------------------------------------------------
// (7) CANARY TEST= tokens naming files that do not exist
// ---------------------------------------------------------------------------

/// The TEST= value of a CANARY comment line, or null.
fn canaryTestValue(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "//") and !std.mem.startsWith(u8, trimmed, "#")) return null;
    const body = std.mem.trimStart(u8, trimmed, "/# \t");
    if (!std.mem.startsWith(u8, body, "CANARY:")) return null;
    const at = std.mem.indexOf(u8, body, "TEST=") orelse return null;
    const rest = body[at + "TEST=".len ..];
    const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
    return std.mem.trim(u8, rest[0..end], " \t\"");
}

/// A token of a TEST= value that names a repository file, without any
/// `:line` or `:"test name"` suffix, or null.
fn repoPathToken(token: []const u8) ?[]const u8 {
    var t = std.mem.trim(u8, token, " \t\"");
    if (std.mem.indexOfScalar(u8, t, ':')) |colon| t = t[0..colon];
    const dirs = [_][]const u8{ "tests/", "src/", "benchmarks/" };
    const exts = [_][]const u8{ ".zig", ".yml", ".yaml", ".go", ".sh", ".py" };
    var dir_ok = false;
    for (dirs) |d| {
        if (std.mem.startsWith(u8, t, d)) dir_ok = true;
    }
    var ext_ok = false;
    for (exts) |e| {
        if (std.mem.endsWith(u8, t, e)) ext_ok = true;
    }
    if (!dir_ok or !ext_ok or std.mem.indexOfScalar(u8, t, ' ') != null) return null;
    return t;
}

test "SONNY-6374 (7) the CANARY TEST= parser" {
    try testing.expectEqualStrings("tests/a.zig|geodetestlab/specs/b.yml", canaryTestValue("// CANARY: REQ=R; ASPECT=A; STATUS=TESTED; TEST=tests/a.zig|geodetestlab/specs/b.yml; OWNER=o").?);
    try testing.expectEqualStrings("tests/a.zig:1", canaryTestValue("    /// CANARY: REQ=R; TEST=tests/a.zig:1; OWNER=o").?);
    try testing.expect(canaryTestValue("    mustWrite(t, p, `// CANARY: REQ=R; TEST=tests/e2e_cdc.zig`)") == null);
    try testing.expect(canaryTestValue("// CANARY: REQ=R; STATUS=IMPL; OWNER=o") == null);
    try testing.expectEqualStrings("tests/a.zig", repoPathToken("tests/a.zig:\"name\"").?);
    try testing.expect(repoPathToken("geodetestlab/specs/b.yml") == null);
    try testing.expect(repoPathToken("test-gap0927") == null);
}

test "SONNY-6374 (7) every CANARY TEST= token that names a repository file names one that exists" {
    const allocator = testing.allocator;
    var bad: usize = 0;
    var checked: usize = 0;
    for ([_][]const u8{ "src", "tests", "benchmarks" }) |top| {
        const top_abs = try std.fs.path.join(allocator, &.{ options.repo_root, top });
        defer allocator.free(top_abs);
        var dir = try std.Io.Dir.cwd().openDir(io(), top_abs, .{ .iterate = true });
        defer dir.close(io());
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io())) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            const src = dir.readFileAlloc(io(), entry.path, allocator, .limited(64 << 20)) catch continue;
            defer allocator.free(src);
            var lines = std.mem.splitScalar(u8, src, '\n');
            var n: usize = 0;
            while (lines.next()) |line| {
                n += 1;
                const value = canaryTestValue(line) orelse continue;
                var tokens = std.mem.tokenizeAny(u8, value, ",|");
                while (tokens.next()) |tok| {
                    const rel = repoPathToken(tok) orelse continue;
                    checked += 1;
                    if (!try repoFileExists(allocator, rel)) {
                        bad += 1;
                        std.debug.print("SONNY-6374 (7): {s}/{s}:{d}: CANARY TEST= names {s}, which does not exist\n", .{ top, entry.path, n, rel });
                    }
                }
            }
        }
    }
    try testing.expect(checked > 100);
    try testing.expectEqual(@as(usize, 0), bad);
}

// ---------------------------------------------------------------------------
// (8) dead modules
// ---------------------------------------------------------------------------

test "SONNY-6374 (8) the modules nothing imports are gone" {
    const allocator = testing.allocator;
    const build_src = try readRepoFile(allocator, "build.zig");
    defer allocator.free(build_src);
    var bad: usize = 0;
    for ([_][]const u8{
        "src/performance/async_io_simple.zig",
        "src/distributed/federation_latency_aggregate.zig",
        "tests/test_federation_latency_aggregates.zig",
        "tests/benchmark_federation_latency_aggregate_variance.zig",
        "benchmarks/benchmark_federation_latency_aggregate_variance.zig",
    }) |rel| {
        if (try repoFileExists(allocator, rel)) {
            bad += 1;
            std.debug.print("SONNY-6374 (8): {s} still exists (no production importer)\n", .{rel});
        }
        if (std.mem.indexOf(u8, build_src, rel) != null) {
            bad += 1;
            std.debug.print("SONNY-6374 (8): build.zig still names {s}\n", .{rel});
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}
