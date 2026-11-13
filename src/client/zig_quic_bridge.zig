const std = @import("std");
pub const zig_client = @import("geode_client_zig");
const endpoint_host = @import("quic_endpoint_host.zig");
const host_port = @import("host_port.zig");

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
    const transport_host = endpoint_host.resolveAlloc(allocator, host) catch |err| {
        if (err == error.Ipv6EndpointUnsupported) printIpv6Unsupported(host);
        return err;
    };
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

/// Split a client address (`--server`, the host part of `--dsn`) into host
/// and port. Grammar (docs/DSN.md, "Host Specification"):
///   host | host:port | :port (127.0.0.1) | [ipv6] | [ipv6]:port
/// where `ipv6` may carry a zone, `[fe80::1%eth0]`. The brackets are
/// stripped from the returned host. SONNY-6484: an unbracketed host with
/// more than one colon (a bare IPv6 literal such as `::1`) is refused with
/// `error.InvalidAddress`; splitting it on the last colon read `::1` as
/// host `:` port 1.
/// SONNY-6487: the grammar is `host_port.split` (shared by every address
/// parser); a port that is not 1-5 digits is `error.InvalidPort`.
pub fn parseHostPort(addr: []const u8, default_port: u16) host_port.Error!HostPort {
    const hp = try host_port.split(addr, default_port);
    return .{
        .host = if (hp.host.len == 0) "127.0.0.1" else hp.host,
        .port = hp.port,
    };
}

const isIpv6Literal = host_port.isIpv6Literal;

/// SONNY-6487: geode-client-zig binds its QUIC endpoint to 0.0.0.0:0 and
/// formats the dial address without brackets, so it cannot reach an IPv6
/// server. Say so instead of failing later with a bare InvalidAddress.
fn printIpv6Unsupported(host: []const u8) void {
    if (@import("builtin").is_test) return;
    std.debug.print(
        "Error: '{s}' is an IPv6 address or has only IPv6 addresses; the CLI's QUIC client " ++
            "(geode-client-zig) binds an IPv4-only endpoint and cannot reach an IPv6 server yet. " ++
            "Use an IPv4 address or a name with an IPv4 address.\n",
        .{host},
    );
}

/// SONNY-6484: refuse a DSN whose host is an unbracketed IPv6 literal
/// (`::1`, `quic://2001:db8::1/g`) or has malformed brackets, before it
/// reaches geode-client-zig's `parseDSN`, which splits an unbracketed host
/// on its last colon (`::1` became host `:` port 1). The host part is
/// located the way `parseDSN` locates it: after `scheme://` and, with a
/// scheme, after the first `@`; up to the first `?`, then the first `/`
/// outside brackets. A bracketed host must be an IPv6 literal (zone
/// allowed) followed by nothing or `:port`.
pub fn checkDsnHost(dsn: []const u8) error{InvalidAddress}!void {
    var rest = dsn;
    if (std.mem.indexOf(u8, rest, "://")) |scheme_end| {
        rest = rest[scheme_end + 3 ..];
        if (std.mem.indexOfScalar(u8, rest, '@')) |at| rest = rest[at + 1 ..];
    }
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| rest = rest[0..q];
    if (rest.len > 0 and rest[0] == '[') {
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return error.InvalidAddress;
        if (!isIpv6Literal(rest[1..close])) return error.InvalidAddress;
        const after = rest[close + 1 ..];
        const port_end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
        if (port_end != 0 and after[0] != ':') return error.InvalidAddress;
        return;
    }
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| rest = rest[0..slash];
    if (std.mem.count(u8, rest, ":") > 1) return error.InvalidAddress;
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
