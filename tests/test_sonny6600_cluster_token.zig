//! SONNY-6600 item 1: the cluster token comparison.
//!
//! `cluster_auth.tokenEqlConstantTime` copied both tokens into 256-byte
//! zero-padded buffers and compared those, so two tokens longer than 256
//! bytes that share their first 256 bytes compared equal: a peer that knew
//! a 256-byte prefix of a long GEODE_CLUSTER_TOKEN (from a truncated log
//! line, say) was accepted as a cluster member. Nothing checked the
//! configured token either: GEODE_CLUSTER_TOKEN=t turned cluster mode on
//! with a one-byte shared secret.
//!
//! Driven here: the validator itself (`validateTokenWithRotation`), the
//! startup check of the configured tokens, a real two-node in-process
//! cluster (a cluster RPC whose token shares the right token's first 256
//! bytes is refused by the receiving node), and a spawned `geode serve`
//! with a too-short GEODE_CLUSTER_TOKEN (refuses to start, says why).
//! No token used here is a real secret.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const cluster_auth = geode.distributed.cluster_auth;
const ClusterCoordinator = geode.distributed.cluster.ClusterCoordinator;
const surface = geode.distributed.cluster.testing_surface;
const linux = std.os.linux;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// A 300-byte token and one that differs from it only after byte 256.
const long_a = "sonny6600-" ++ "a" ** 290;
const long_b = long_a[0..256] ++ "b" ** 44;
comptime {
    std.debug.assert(long_a.len == 300 and long_b.len == 300);
}

test "SONNY-6600 (1): tokens equal in the first 256 bytes and different after are refused" {
    try testing.expect(std.mem.eql(u8, long_a[0..256], long_b[0..256]));
    try testing.expect(!std.mem.eql(u8, long_a, long_b));
    if (cluster_auth.validateTokenWithRotation(long_b, long_a, null)) {
        std.debug.print("SONNY-6600 (1): a token sharing only the first 256 bytes of GEODE_CLUSTER_TOKEN was accepted\n", .{});
        return error.LongTokenPrefixAccepted;
    }
    // The same through the rotation's previous token.
    try testing.expect(!cluster_auth.validateTokenWithRotation(long_b, "sonny6600-primary-token", long_a));
    // The right long token is accepted, as primary and as previous.
    try testing.expect(cluster_auth.validateTokenWithRotation(long_a, long_a, null));
    try testing.expect(cluster_auth.validateTokenWithRotation(long_a, "sonny6600-primary-token", long_a));
}

test "SONNY-6600 (1): tokens of different lengths are refused, a prefix and an extension included" {
    const tok = "sonny6600-short-token-value";
    try testing.expect(cluster_auth.validateTokenWithRotation(tok, tok, null));
    try testing.expect(!cluster_auth.validateTokenWithRotation(tok[0 .. tok.len - 1], tok, null));
    try testing.expect(!cluster_auth.validateTokenWithRotation(tok ++ "x", tok, null));
    try testing.expect(!cluster_auth.validateTokenWithRotation(tok ++ "\x00", tok, null));
    try testing.expect(!cluster_auth.validateTokenWithRotation(long_a[0..256], long_a, null));
    try testing.expect(!cluster_auth.validateTokenWithRotation(long_a, long_a[0..256], null));
    try testing.expect(!cluster_auth.validateTokenWithRotation("", tok, null));
    try testing.expect(!cluster_auth.validateTokenWithRotation(tok, "", null));
}

test "SONNY-6600 (1): the configured cluster tokens are checked: at least 16 bytes" {
    if (comptime !@hasDecl(cluster_auth, "validateTokenConfig")) {
        std.debug.print("SONNY-6600 (1): nothing checks GEODE_CLUSTER_TOKEN; a one-byte token turns cluster mode on\n", .{});
        return error.NoClusterTokenCheck;
    } else {
        // Unset: standalone, nothing to check.
        try cluster_auth.validateTokenConfig(null, null);
        try cluster_auth.validateTokenConfig("0123456789abcdef", null);
        try cluster_auth.validateTokenConfig(long_a, "0123456789abcdef");
        try testing.expectError(error.ClusterTokenTooShort, cluster_auth.validateTokenConfig("", null));
        try testing.expectError(error.ClusterTokenTooShort, cluster_auth.validateTokenConfig("t", null));
        try testing.expectError(error.ClusterTokenTooShort, cluster_auth.validateTokenConfig("0123456789abcde", null));
        try testing.expectError(error.ClusterTokenPreviousTooShort, cluster_auth.validateTokenConfig(long_a, "old"));
        try testing.expectError(error.ClusterTokenPreviousTooShort, cluster_auth.validateTokenConfig(long_a, ""));
        // PREVIOUS alone is not cluster mode (it never authenticates
        // anything on its own); a short one is still a misconfiguration.
        try testing.expectError(error.ClusterTokenPreviousTooShort, cluster_auth.validateTokenConfig(null, "old"));
    }
}

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

test "SONNY-6600 (1): a two-node cluster refuses a cluster RPC whose token shares only the first 256 bytes" {
    // As tests/test_cluster_forward_to_shard.zig: Debug-only insecure peer
    // TLS on loopback, Linux, and listener certificates the CI runner does
    // not generate.
    if (comptime builtin.mode != .Debug) return error.SkipZigTest;
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    if (std.c.getenv("CI") != null) return error.SkipZigTest;

    const a = testing.allocator;
    if (setenv("GEODE_CLUSTER_INSECURE", "1", 1) != 0) return error.SetEnvFailed;
    defer _ = unsetenv("GEODE_CLUSTER_INSECURE");
    if (setenv("GEODE_CLUSTER_TOKEN", long_a, 1) != 0) return error.SetEnvFailed;
    defer _ = unsetenv("GEODE_CLUSTER_TOKEN");
    _ = unsetenv("GEODE_CLUSTER_TOKEN_PREVIOUS");

    const port_a: u16 = 23660;
    const port_b: u16 = 23661;
    const peers_a = [_]ClusterCoordinator.PeerConfig{.{ .id = 2, .address = "127.0.0.1", .port = port_b }};
    const peers_b = [_]ClusterCoordinator.PeerConfig{.{ .id = 1, .address = "127.0.0.1", .port = port_a }};

    const coord_a = try a.create(ClusterCoordinator);
    coord_a.* = try ClusterCoordinator.init(a, 1, .{
        .peers = peers_a[0..],
        .listen_address = "127.0.0.1",
        .cluster_port = port_a,
        .cluster_token = long_a,
        .cluster_name = "sonny6600-cluster",
        .election_timeout_ms = 60_000,
    });
    var a_alive = true;
    errdefer if (a_alive) {
        coord_a.deinit();
        a.destroy(coord_a);
    };
    const coord_b = try a.create(ClusterCoordinator);
    coord_b.* = try ClusterCoordinator.init(a, 2, .{
        .peers = peers_b[0..],
        .listen_address = "127.0.0.1",
        .cluster_port = port_b,
        .cluster_token = long_a,
        .cluster_name = "sonny6600-cluster",
        .election_timeout_ms = 60_000,
    });
    var b_alive = true;
    errdefer if (b_alive) {
        coord_b.deinit();
        a.destroy(coord_b);
    };
    try coord_a.start();
    try coord_b.start();
    defer {
        coord_b.deinit();
        a.destroy(coord_b);
        coord_a.deinit();
        a.destroy(coord_a);
        a_alive = false;
        b_alive = false;
    }
    sleepMs(500);

    // Shard 66 lives on node 2: coord A forwards the RPC to coord B, which
    // checks the message's token against its GEODE_CLUSTER_TOKEN.
    try coord_a.cluster_state.shards.append(a, .{
        .id = 66,
        .primary_node = 2,
        .replica_nodes = try a.alloc(u64, 0),
        .key_range = .{ .start = "", .end = "" },
        .size_bytes = 0,
        .record_count = 0,
    });

    // The right token: served by node 2.
    {
        var resp = try surface.forwardToShard(coord_a, 66, .{ .msg_type = .READ, .key = "k1", .client_id = "sonny6600", .data = null, .auth_token = long_a });
        defer resp.deinit(a);
        try testing.expectEqual(surface.ResponseStatus.OK, resp.status);
        try testing.expectEqualStrings("executed:2:k1", resp.data orelse "");
    }
    // The right first 256 bytes, then different: refused.
    {
        var resp = try surface.forwardToShard(coord_a, 66, .{ .msg_type = .READ, .key = "k2", .client_id = "sonny6600", .data = null, .auth_token = long_b });
        defer resp.deinit(a);
        if (resp.status == surface.ResponseStatus.OK) {
            std.debug.print("SONNY-6600 (1): node 2 served a cluster RPC whose token matched GEODE_CLUSTER_TOKEN only in its first 256 bytes ({?s})\n", .{resp.data});
            return error.LongTokenPrefixAccepted;
        }
        try testing.expectEqual(surface.ResponseStatus.ERR, resp.status);
    }
    // The token truncated to 256 bytes: refused.
    {
        var resp = try surface.forwardToShard(coord_a, 66, .{ .msg_type = .READ, .key = "k3", .client_id = "sonny6600", .data = null, .auth_token = long_a[0..256] });
        defer resp.deinit(a);
        try testing.expectEqual(surface.ResponseStatus.ERR, resp.status);
    }
}

const Run = struct {
    code: ?u8,
    killed: bool,
    err: []u8,
};

/// `geode serve` with `token` (and `previous`) as the cluster tokens.
/// Waits up to 30 s for it to exit; a server still running then is killed.
fn serveWithTokens(root: *const test_scratch.ScratchDir, token: []const u8, previous: ?[]const u8) !Run {
    const a = testing.allocator;
    const fio = std.Io.Threaded.global_single_threaded.io();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    const data_dir = try std.fmt.allocPrint(a, "{s}/data", .{root.path()});
    defer a.free(data_dir);
    try env.put("HOME", root.path());
    try env.put("GEODE_DATA_DIR", data_dir);
    try env.put("GEODE_ADMIN_USERNAME", "admin");
    try env.put("GEODE_ADMIN_PASSWORD", "Sonny6600 Test Admin Passphrase");
    try env.put("GEODE_LSP_PORT", "0");
    try env.put("GEODE_CLUSTER_TOKEN", token);
    if (previous) |p| try env.put("GEODE_CLUSTER_TOKEN_PREVIOUS", p);

    const err_path = try std.fmt.allocPrint(a, "{s}/serve-{d}.err", .{ root.path(), token.len });
    defer a.free(err_path);
    const errf = try std.Io.Dir.cwd().createFile(fio, err_path, .{ .read = true, .truncate = true });
    defer errf.close(fio);

    const child = try std.process.spawn(io, .{
        .argv = &.{ geode_test_bin.geode_exe, "serve", "--listen", "127.0.0.1:0" },
        .environ_map = &env,
        .cwd = .{ .path = root.path() },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .{ .file = errf },
    });
    const pid = child.id.?;
    var status: u32 = 0;
    var exited = false;
    var waited_ms: u64 = 0;
    while (waited_ms < 30_000) : (waited_ms += 50) {
        if (linux.waitpid(pid, &status, linux.W.NOHANG) == @as(usize, @intCast(pid))) {
            exited = true;
            break;
        }
        sleepMs(50);
    }
    if (!exited) {
        std.posix.kill(pid, .KILL) catch {};
        _ = linux.waitpid(pid, &status, 0);
    }
    const code: ?u8 = if (exited and linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else null;
    const stderr = try std.Io.Dir.cwd().readFileAlloc(fio, err_path, a, .limited(4 << 20));
    return .{ .code = code, .killed = !exited, .err = stderr };
}

test "SONNY-6600 (1): geode serve refuses to start with a GEODE_CLUSTER_TOKEN shorter than 16 bytes, and says why" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var root = try test_scratch.ScratchDir.create("sonny6600-token");
    defer root.remove();

    const cases = [_]struct { token: []const u8, previous: ?[]const u8, needle: []const u8 }{
        .{ .token = "t", .previous = null, .needle = "GEODE_CLUSTER_TOKEN is 1 bytes" },
        .{ .token = "0123456789abcdef-primary", .previous = "old", .needle = "GEODE_CLUSTER_TOKEN_PREVIOUS is 3 bytes" }, // gitleaks:allow
    };
    for (cases) |c| {
        const r = try serveWithTokens(&root, c.token, c.previous);
        defer testing.allocator.free(r.err);
        const named = std.mem.indexOf(u8, r.err, c.needle) != null;
        if (r.code != @as(?u8, 1) or !named) {
            std.debug.print("SONNY-6600 (1): geode serve with GEODE_CLUSTER_TOKEN of {d} bytes (previous {?s}): exit={?d} killed_after_30s={} stderr names \"{s}\": {}\n--- stderr (tail) ---\n{s}\n", .{
                c.token.len, c.previous, r.code, r.killed, c.needle, named, r.err[r.err.len -| 2000..],
            });
            return error.ShortClusterTokenAccepted;
        }
    }
}
