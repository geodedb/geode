// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 CodePros
// CANARY: REQ=REQ-SONNY-6554-DSN-PARAMS; FEATURE="DSN parameters"; ASPECT=OneStrictParser; STATUS=TESTED; TEST=tests/test_sonny6554_dsn_params.zig; OWNER=cli; UPDATED=2026-11-15

//! SONNY-6554 / SONNY-6569: the one DSN parser geode's clients use: the
//! CLI's `--dsn` (`geode query`, `geode shell`) and the `geode mcp
//! --endpoint` DSN.
//!
//! geode-client-zig's `parseDSNStrict` reads the scheme, the authority, the
//! graph path and every value, and refuses a malformed or out-of-range
//! `page_size` or timeout. It skips a parameter it does not know, a
//! parameter without `=`, and reads any boolean spelling it does not know as
//! false. docs/DSN.md lists the parameters and the boolean spellings, so
//! this module refuses the rest:
//!
//! - an unknown parameter: `error.UnknownDsnParameter`;
//! - a parameter with no `=` or an empty name: `error.MalformedDsnParameter`;
//! - a boolean (`insecure_tls_skip_verify` and its aliases, `tls`) that is
//!   not `true`/`1`/`yes`/`on`/`false`/`0`/`no`/`off`:
//!   `error.InvalidDsnBoolean`.
//!
//! It also names a fragment (`error.DsnFragment`; the library reports its
//! generic `InvalidDSN`), refuses an IPv6 zone, which parses but cannot be
//! dialled (`error.Ipv6ZoneUnsupported`), and gives a userinfo credential
//! precedence over a `user=` / `pass=` parameter, per field (docs/DSN.md;
//! the library lets the parameter win).

const std = @import("std");
const config = @import("geode_client_zig").config;
const host_port = @import("host_port.zig");

const redact = config.redact;

pub const Error = error{
    UnknownDsnParameter,
    MalformedDsnParameter,
    InvalidDsnBoolean,
    DsnFragment,
    Ipv6ZoneUnsupported,
    InvalidDSN,
};

/// A DSN query parameter, by its docs/DSN.md name.
pub const Param = enum {
    insecure_tls_skip_verify,
    tls,
    page_size,
    connect_timeout,
    timeout_ms,
    username,
    password,
    hello_name,
    hello_ver,
    conformance,
    ca,
    cert,
    key,
    server_name,
    graph,
    tenant,
    role,

    pub fn isBoolean(self: Param) bool {
        return self == .insecure_tls_skip_verify or self == .tls;
    }
};

/// Every spelling geode-client-zig reads, and the parameter it means.
pub const names = [_]struct { name: []const u8, param: Param }{
    .{ .name = "insecure_tls_skip_verify", .param = .insecure_tls_skip_verify },
    .{ .name = "insecure", .param = .insecure_tls_skip_verify },
    .{ .name = "skip_verify", .param = .insecure_tls_skip_verify },
    .{ .name = "tls", .param = .tls },
    .{ .name = "page_size", .param = .page_size },
    .{ .name = "pageSize", .param = .page_size },
    .{ .name = "connect_timeout", .param = .connect_timeout },
    .{ .name = "timeout", .param = .connect_timeout },
    .{ .name = "timeout_ms", .param = .timeout_ms },
    .{ .name = "username", .param = .username },
    .{ .name = "user", .param = .username },
    .{ .name = "password", .param = .password },
    .{ .name = "pass", .param = .password },
    .{ .name = "hello_name", .param = .hello_name },
    .{ .name = "hello_ver", .param = .hello_ver },
    .{ .name = "conformance", .param = .conformance },
    .{ .name = "ca", .param = .ca },
    .{ .name = "ca_cert", .param = .ca },
    .{ .name = "cert", .param = .cert },
    .{ .name = "client_cert", .param = .cert },
    .{ .name = "key", .param = .key },
    .{ .name = "client_key", .param = .key },
    .{ .name = "server_name", .param = .server_name },
    .{ .name = "graph", .param = .graph },
    .{ .name = "tenant", .param = .tenant },
    .{ .name = "tenant_id", .param = .tenant },
    .{ .name = "role", .param = .role },
};

pub fn lookup(name: []const u8) ?Param {
    for (names) |n| {
        if (std.mem.eql(u8, n.name, name)) return n.param;
    }
    return null;
}

/// The boolean spellings of docs/DSN.md ("Boolean Parameter Values"),
/// exactly as geode-client-zig compares them (case-sensitive).
pub fn isBooleanValue(value: []const u8) bool {
    for ([_][]const u8{ "true", "1", "yes", "on", "false", "0", "no", "off" }) |v| {
        if (std.mem.eql(u8, v, value)) return true;
    }
    return false;
}

pub const Parsed = struct {
    config: config.Config,
    /// The parameters the query string sets.
    present: std.EnumSet(Param),

    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        self.config.deinit(allocator);
    }
};

/// `dsn`'s text after its `scheme://` (all of it when it has no scheme)
/// holds a `#`: a fragment, which no Geode DSN may carry.
pub fn hasFragment(dsn: []const u8) bool {
    const start = if (redact.schemeEnd(dsn)) |sep| sep + 3 else 0;
    return std.mem.indexOfScalar(u8, dsn[start..], '#') != null;
}

/// Parse `dsn` (see the module comment). The returned config's host slices
/// `dsn`; the caller deinits the result.
pub fn parse(allocator: std.mem.Allocator, dsn: []const u8) !Parsed {
    if (dsn.len == 0) return error.InvalidDSN;
    var cfg = config.parseDSNStrict(allocator, dsn) catch |err| {
        // The library checks the fragment before the host, so its
        // InvalidDSN on a DSN with a fragment is the fragment.
        if (err == error.InvalidDSN and hasFragment(dsn)) return error.DsnFragment;
        return err;
    };
    errdefer cfg.deinit(allocator);

    const start = if (redact.schemeEnd(dsn)) |sep| sep + 3 else 0;
    const authority = try redact.splitAuthority(dsn[start..]);
    const present = try checkQuery(authority.rest);
    if (isZonedIpv6(cfg.host)) return error.Ipv6ZoneUnsupported;
    if (authority.userinfo) |userinfo| try preferUserinfoCredentials(allocator, &cfg, userinfo);
    return .{ .config = cfg, .present = present };
}

/// The parameters of `rest` (`Authority.rest`: empty, or starting with `/`
/// or `?`), each known and well-formed. An empty query (`host?`) is none.
fn checkQuery(rest: []const u8) Error!std.EnumSet(Param) {
    var present = std.EnumSet(Param).initEmpty();
    const q = std.mem.indexOfScalar(u8, rest, '?') orelse return present;
    const query = rest[q + 1 ..];
    if (query.len == 0) return present;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.MalformedDsnParameter;
        if (eq == 0) return error.MalformedDsnParameter;
        const param = lookup(pair[0..eq]) orelse return error.UnknownDsnParameter;
        if (param.isBoolean() and !isBooleanValue(pair[eq + 1 ..])) return error.InvalidDsnBoolean;
        present.insert(param);
    }
    return present;
}

/// An IPv6 literal with a `%zone`.
fn isZonedIpv6(host: []const u8) bool {
    return host_port.isIpv6Literal(host) and std.mem.indexOfScalar(u8, host, '%') != null;
}

/// docs/DSN.md: per field, a userinfo credential takes precedence over a
/// `user=` / `pass=` query parameter, an empty userinfo user name counting
/// as absent. geode-client-zig (v0.3.17) lets the parameter overwrite the
/// userinfo, so put the userinfo's values back.
fn preferUserinfoCredentials(allocator: std.mem.Allocator, cfg: *config.Config, userinfo: []const u8) !void {
    const creds = try redact.decodeUserinfo(allocator, userinfo);
    if (creds.username.len > 0) {
        replaceSecret(allocator, &cfg.username, creds.username);
    } else {
        allocator.free(creds.username);
    }
    if (creds.password) |p| replaceSecret(allocator, &cfg.password, p);
}

/// Zero and free the secret in `field`, then store `value` (owned).
fn replaceSecret(allocator: std.mem.Allocator, field: *?[]const u8, value: []u8) void {
    if (field.*) |old| {
        std.crypto.secureZero(u8, @constCast(old));
        allocator.free(old);
    }
    field.* = value;
}
