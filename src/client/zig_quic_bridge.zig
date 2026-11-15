// CANARY: REQ=REQ-CLI-DNS-5077; FEATURE="CLI QUIC hostname resolution"; ASPECT=HostnameResolution; STATUS=TESTED; TEST=tests/test_sonny6494_ipv6_query.zig; OWNER=cli; UPDATED=2026-11-13

const std = @import("std");
pub const zig_client = @import("geode_client_zig");
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

/// What a CLI client is and how long it waits (geode-client-zig v0.3.18
/// applies both through `initFromConfig`).
pub const ClientOptions = struct {
    /// How long `connect` waits for the QUIC handshake and `sendHello` for
    /// the HELLO answer, 1..3600000 ms (`connect` refuses anything else with
    /// `error.InvalidTimeout`). The library's query, begin, commit, rollback
    /// and ping wait a fixed 30 s whatever this is.
    timeout_ms: u32 = zig_client.config.DEFAULT_TIMEOUT_MS,
    /// The HELLO `client_name` (`client_version` is geode's version).
    hello_name: []const u8 = cli_hello_name,
};

/// The HELLO `client_name` of `geode query`, `shell` and `auth login`.
pub const cli_hello_name = "geode-cli";

/// `seconds` as a client timeout, within geode-client-zig's 1..3600000 ms.
pub fn timeoutMsFromSeconds(seconds: u32) u32 {
    const max_ms: u32 = 3_600_000;
    const ms = std.math.mul(u32, @max(seconds, 1), std.time.ms_per_s) catch max_ms;
    return @min(ms, max_ms);
}

fn initClientWithInsecureSetting(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    tls_config: TlsConfig,
    username: ?[]const u8,
    password: ?[]const u8,
    insecure: bool,
    opts: ClientOptions,
) !zig_client.GeodeClient {
    // SONNY-6494: geode-client-zig (v0.3.16) resolves the host itself: an
    // address literal is dialled as written (IPv6 bracketed, from a [::]:0
    // endpoint), and a name prefers its first IPv4 address and falls back to
    // IPv6, through the system resolver (hosts file and DNS, SONNY-5077).
    // The TLS server name below stays the host as given.
    try refuseIpv6Zone(host);
    var cfg = zig_client.config.Config.initWithTransport(host, port, .quic);
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
    // SONNY-6589 / SONNY-6606 (4): applied by initFromConfig since
    // geode-client-zig v0.3.18. Static strings: cfg does not own them.
    cfg.timeout_ms = opts.timeout_ms;
    cfg.hello_name = opts.hello_name;
    cfg.hello_ver = @import("build_options").version;

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
/// SONNY-6494: so is port 0 here. The grammar accepts it because a listener
/// takes 0 as "any free port", but no server can be dialled on it (the send
/// failed with a bare `Unexpected`).
/// SONNY-6569: an `@` is `error.UnencodedCredentialDelimiter`: a `--server
/// pw@host:3141` (or REPL `\connect pw@host:3141`) dialled a host named
/// `pw@host`, sending the credential to the resolver and the TLS server
/// name. The grammar refuses any other byte a host name cannot hold.
pub fn parseHostPort(addr: []const u8, default_port: u16) (host_port.Error || error{UnencodedCredentialDelimiter})!HostPort {
    if (std.mem.indexOfScalar(u8, addr, '@') != null) return error.UnencodedCredentialDelimiter;
    const hp = try host_port.split(addr, default_port);
    if (hp.port == 0) return error.InvalidPort;
    return .{
        .host = if (hp.host.len == 0) "127.0.0.1" else hp.host,
        .port = hp.port,
    };
}

/// SONNY-6494/6531: what is wrong with a server address or endpoint DSN, in
/// words a user can act on; null when `err` is not about the address. The
/// one mapping for every client entry point: `geode mcp` (tools, resources,
/// `--endpoint` at startup, through `src/mcp/client.zig`) and the CLI's
/// `--server` / `--dsn` (`geode query`, `shell`, `auth login`, `backup
/// create`, `restore`, `migrate run`). It covers geode-client-zig's DSN
/// errors (v0.3.17 parses with geode's grammar and credential rules,
/// docs/DSN.md), the shared grammar's own (`parseHostPort`:
/// `InvalidAddress`, and `InvalidPort` including port 0, and an `@` in a
/// `--server` address), the strict parser's (`dsn_params.parse`: a
/// fragment, an unknown or malformed parameter) and the dial-time refusals. The address itself is never
/// part of the message: a DSN may carry a password.
pub fn endpointErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InvalidDSN, error.InvalidAddress => "Invalid Geode endpoint DSN: the host must be a name, an IPv4 address or a bracketed IPv6 address ([::1]), optionally followed by :port (docs/DSN.md)",
        error.InvalidPort => "Invalid Geode endpoint DSN: the port must be 1-65535, written as 1-5 digits; port 0 cannot be dialled (docs/DSN.md)",
        error.UnsupportedScheme => "Invalid Geode endpoint DSN: unsupported scheme; use quic:// or grpc:// (docs/DSN.md)",
        error.InputTooLong => "Invalid Geode endpoint DSN: a credential or parameter value is too long",
        // SONNY-6544/6550: the userinfo, the graph path and every query
        // value are strictly percent-decoded (geode-client-zig config.redact).
        error.InvalidPercentEncoding => "Invalid Geode endpoint DSN: a % must start a %XX escape of two hex digits (in the user name, password, graph name or a parameter value); write a literal % as %25",
        error.UnencodedCredentialDelimiter => "Invalid Geode endpoint DSN: an @ follows the host; a user name or password holding /, ? or # must percent-encode it (%2F, %3F, %23), and an @ in a graph name or parameter as %40; a --server address takes no user name or password (use -U with --password, or --dsn)",
        // SONNY-6550: geode-client-zig refuses a fragment with its generic
        // InvalidDSN; `dsn_params.parse` names it.
        error.DsnFragment => "Invalid Geode endpoint DSN: a fragment (#...) is not allowed; a user name, password or graph name holding # must percent-encode it as %23",
        error.TimeoutOutOfRange => "Invalid Geode endpoint DSN: the timeout is out of range; connect_timeout takes 1-3600 seconds and timeout_ms 1-3600000",
        // SONNY-6554/6569: dsn_params.parse, the one strict parser; and
        // (SONNY-6589) geode-client-zig's connect, for a timeout_ms outside
        // 1..3600000.
        error.InvalidTimeout => "Invalid Geode endpoint DSN: a timeout must be a whole number; connect_timeout takes 1-3600 seconds and timeout_ms 1-3600000",
        error.InvalidPageSize, error.PageSizeOutOfRange => "Invalid Geode endpoint DSN: page_size takes a whole number 1-100000",
        error.UnknownDsnParameter => "Invalid Geode endpoint DSN: unknown query parameter; the parameters are page_size, hello_name, hello_ver, conformance, graph, username (user), password (pass), tls, insecure_tls_skip_verify (insecure, skip_verify), ca (ca_cert), cert (client_cert), key (client_key), server_name, connect_timeout (timeout), timeout_ms, tenant (tenant_id) and role (docs/DSN.md)",
        error.MalformedDsnParameter => "Invalid Geode endpoint DSN: a query parameter must be name=value, joined by &",
        error.InvalidDsnBoolean => "Invalid Geode endpoint DSN: a boolean parameter (insecure_tls_skip_verify, insecure, skip_verify, tls) takes true, false, 1, 0, yes, no, on or off",
        error.Ipv6ZoneUnsupported => "Invalid Geode endpoint DSN: an IPv6 address with a zone (%eth0) cannot be dialled; use a global or loopback IPv6 address, an IPv4 address or a host name",
        error.InsecureTlsRefused => "Refused: the endpoint DSN sets insecure=true under production posture (release build or GEODE_ENV=production); give the DSN a ca= bundle, or set GEODE_ALLOW_INSECURE_TLS=1 to accept the risk",
        else => null,
    };
}

/// SONNY-6531: print `endpointErrorMessage(err)` as a CLI error line on
/// stderr (a generic line for an error the mapping does not know).
pub fn printEndpointError(err: anyerror) void {
    const why = endpointErrorMessage(err) orelse "Invalid Geode server address (docs/DSN.md)";
    std.debug.print("Error: {s}\n", .{why});
}

const isIpv6Literal = host_port.isIpv6Literal;

/// An IPv6 literal with a `%zone`, bracketed or not.
pub fn isZonedIpv6(host: []const u8) bool {
    const bare = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host[1 .. host.len - 1] else host;
    return isIpv6Literal(bare) and std.mem.indexOfScalar(u8, bare, '%') != null;
}

/// SONNY-6494: the grammar accepts an IPv6 zone (`[fe80::1%eth0]:3141`), but
/// the quic dialler cannot parse one, so geode-client-zig refuses it with
/// `error.Ipv6ZoneUnsupported` when it connects. Refuse it here, before a
/// client is built, and say why.
fn refuseIpv6Zone(host: []const u8) error{Ipv6ZoneUnsupported}!void {
    if (!isZonedIpv6(host)) return;
    if (!@import("builtin").is_test) std.debug.print(
        "Error: '{s}' is an IPv6 address with a zone; the CLI's QUIC client cannot dial a " ++
            "zoned address. Use a global or loopback IPv6 address, an IPv4 address, or a host name.\n",
        .{host},
    );
    return error.Ipv6ZoneUnsupported;
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
        .{},
    );
}

pub fn initClientStrictTls(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    tls_config: TlsConfig,
    username: ?[]const u8,
    password: ?[]const u8,
    opts: ClientOptions,
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
        opts,
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
