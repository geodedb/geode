const std = @import("std");
pub const zig_client = @import("geode_client_zig");
const endpoint_host = @import("quic_endpoint_host.zig");

pub const TlsConfig = struct {
    insecure: bool = false,
    ca_cert_path: ?[]const u8 = null,
    client_cert_path: ?[]const u8 = null,
    client_key_path: ?[]const u8 = null,
};

pub const HostPort = struct {
    host: []const u8,
    port: u16,
};

fn initClientWithInsecureSetting(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    tls_config: TlsConfig,
    username: ?[]const u8,
    password: ?[]const u8,
    insecure: bool,
) !zig_client.GeodeClient {
    const transport_host = try endpoint_host.resolveAlloc(allocator, host);
    defer allocator.free(transport_host);
    var cfg = zig_client.config.Config.initWithTransport(transport_host, port, .quic);
    defer cfg.deinit(allocator);

    cfg.insecure = insecure;

    if (username) |user| {
        _ = try cfg.withCredentials(allocator, user, password orelse "");
    }
    if (tls_config.ca_cert_path) |path| {
        cfg.ca_cert = try allocator.dupe(u8, path);
    }
    if (tls_config.client_cert_path) |path| {
        cfg.client_cert = try allocator.dupe(u8, path);
    }
    if (tls_config.client_key_path) |path| {
        cfg.client_key = try allocator.dupe(u8, path);
    }
    cfg.server_name = try allocator.dupe(u8, host);

    return try zig_client.GeodeClient.initFromConfig(allocator, cfg);
}

pub fn parseHostPort(addr: []const u8, default_port: u16) !HostPort {
    const colon_idx = std.mem.lastIndexOf(u8, addr, ":") orelse {
        return .{ .host = addr, .port = default_port };
    };
    const host = addr[0..colon_idx];
    const port = try std.fmt.parseInt(u16, addr[colon_idx + 1 ..], 10);
    return .{
        .host = if (host.len == 0) "127.0.0.1" else host,
        .port = port,
    };
}

/// How `initClient` treats the server's certificate (SONNY-6448).
pub const Verification = enum {
    /// Verify the chain (against the --ca-cert bundle) and the server name.
    verify,
    /// --insecure-tls-skip-verify / --insecure: the flag parser has already
    /// run the production-posture gate and printed its warning.
    skip_by_flag,
    /// No CA, no mTLS material, no flag: the dev default. Unverified, and
    /// says so on stderr.
    skip_no_trust_material,
};

/// A supplied CA bundle or mTLS material always means verification; it is
/// skipped only on the explicit flag or when there is nothing to verify with.
pub fn verificationPolicy(tls_config: TlsConfig) Verification {
    if (tls_config.insecure) return .skip_by_flag;
    const has_trust_material = tls_config.ca_cert_path != null or
        tls_config.client_cert_path != null or tls_config.client_key_path != null;
    return if (has_trust_material) .verify else .skip_no_trust_material;
}

/// SONNY-6453: may a connection skip server verification that the caller
/// did not ask to skip by flag (no --ca-cert, no client certificate, no
/// --insecure-tls-skip-verify), or a DSN `insecure=true`?
pub const InsecurePosture = enum {
    /// Debug build outside GEODE_ENV=production, or GEODE_ALLOW_INSECURE_TLS=1:
    /// allowed, with a stderr warning.
    warn,
    /// Release build or GEODE_ENV=production: refused.
    refuse,
};

/// The same rule as `src/cli/insecure_tls_gate.zig` (SEC-CLI-01) and
/// `geode auth`: production posture refuses unless the operator sets
/// GEODE_ALLOW_INSECURE_TLS=1. Pure, so it is testable from a Debug binary.
pub fn insecurePosture(is_release: bool, env_production: bool, allow_override: bool) InsecurePosture {
    if (allow_override) return .warn;
    return if (is_release or env_production) .refuse else .warn;
}

fn getenvSlice(name: [*:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

/// `insecurePosture` for this process: build mode, GEODE_ENV and
/// GEODE_ALLOW_INSECURE_TLS ("1", "true", "yes", "on").
pub fn liveInsecurePosture() InsecurePosture {
    const env_production = if (getenvSlice("GEODE_ENV")) |v| std.ascii.eqlIgnoreCase(v, "production") else false;
    const allow_override = if (getenvSlice("GEODE_ALLOW_INSECURE_TLS")) |v|
        std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true") or
            std.ascii.eqlIgnoreCase(v, "yes") or std.ascii.eqlIgnoreCase(v, "on")
    else
        false;
    return insecurePosture(@import("builtin").mode != .Debug, env_production, allow_override);
}

fn printImplicitInsecureRefusal() void {
    if (@import("builtin").is_test) return;
    std.debug.print(
        "SECURITY: refusing to connect without TLS certificate verification: no --ca-cert " ++
            "was given (release build or GEODE_ENV=production). Pass --ca-cert <path> to verify " ++
            "the server, or --insecure-tls-skip-verify with GEODE_ALLOW_INSECURE_TLS=1 to " ++
            "explicitly accept the risk.\n",
        .{},
    );
}

var implicit_insecure_warned = std.atomic.Value(bool).init(false);

fn warnImplicitInsecureOnce() void {
    if (@import("builtin").is_test) return; // stderr output fails a zig test step
    if (implicit_insecure_warned.swap(true, .monotonic)) return;
    std.debug.print(
        "WARNING: TLS server certificate NOT verified (no --ca-cert given). " ++
            "Pass --ca-cert <path> to verify the server.\n",
        .{},
    );
}

pub fn initClient(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    tls_config: TlsConfig,
    username: ?[]const u8,
    password: ?[]const u8,
) !zig_client.GeodeClient {
    const policy = verificationPolicy(tls_config);
    if (policy == .skip_no_trust_material) {
        // SONNY-6453: the geode auth rule for every CLI command.
        if (liveInsecurePosture() == .refuse) {
            printImplicitInsecureRefusal();
            return error.ImplicitInsecureTlsRefused;
        }
        warnImplicitInsecureOnce();
    }
    return try initClientWithInsecureSetting(
        allocator,
        host,
        port,
        tls_config,
        username,
        password,
        policy != .verify,
    );
}

pub fn initClientStrictTls(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    tls_config: TlsConfig,
    username: ?[]const u8,
    password: ?[]const u8,
) !zig_client.GeodeClient {
    // SONNY-6453: with nothing to verify against, a verified connection can
    // only fail its handshake; under production posture say why up front.
    if (verificationPolicy(tls_config) == .skip_no_trust_material and liveInsecurePosture() == .refuse) {
        printImplicitInsecureRefusal();
        return error.ImplicitInsecureTlsRefused;
    }
    return try initClientWithInsecureSetting(
        allocator,
        host,
        port,
        tls_config,
        username,
        password,
        tls_config.insecure,
    );
}

pub fn initClientFromAddr(
    allocator: std.mem.Allocator,
    addr: []const u8,
    default_port: u16,
    tls_config: TlsConfig,
    username: ?[]const u8,
    password: ?[]const u8,
) !zig_client.GeodeClient {
    const parsed = try parseHostPort(addr, default_port);
    return try initClient(allocator, parsed.host, parsed.port, tls_config, username, password);
}
