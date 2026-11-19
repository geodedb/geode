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

pub fn initClient(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    tls_config: TlsConfig,
    username: ?[]const u8,
    password: ?[]const u8,
) !zig_client.GeodeClient {
    const using_client_certs = tls_config.client_cert_path != null or tls_config.client_key_path != null;

    // Preserve the CLI's long-standing behavior: QUIC connections default to
    // trusting local/dev certificates unless the caller is explicitly using
    // mutual TLS material.
    return try initClientWithInsecureSetting(
        allocator,
        host,
        port,
        tls_config,
        username,
        password,
        if (using_client_certs) tls_config.insecure else true,
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
