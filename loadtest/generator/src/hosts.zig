// CANARY: REQ=REQ-LOADTEST-GENERATOR-001; FEATURE="StreamingDataGenerator"; ASPECT=Hosts; STATUS=IMPL; OWNER=tooling; UPDATED=2026-01-03
//! Host Generator
//! Expands subnets into individual hosts with realistic service profiles

const std = @import("std");
const topology = @import("topology.zig");

/// Host type classification
pub const HostType = enum {
    server,
    workstation,
    router,
    firewall,
    load_balancer,
    database,
    web_server,
    mail_server,
    dns_server,
    iot_device,

    pub fn toStr(self: HostType) []const u8 {
        return @tagName(self);
    }
};

/// Operating system type
pub const OSType = enum {
    linux,
    windows,
    macos,
    bsd,
    ios,
    android,
    embedded,
    unknown,

    pub fn toStr(self: OSType) []const u8 {
        return @tagName(self);
    }
};

/// Host representation
pub const Host = struct {
    ip: u32,
    host_type: HostType,
    os: OSType,
    asn: u32,
    prefix_network: u32,
    prefix_mask: u8,
    port_count: u8,

    pub fn ipToStr(self: Host, buf: []u8) []const u8 {
        const a = @as(u8, @truncate(self.ip >> 24));
        const b = @as(u8, @truncate(self.ip >> 16));
        const c = @as(u8, @truncate(self.ip >> 8));
        const d = @as(u8, @truncate(self.ip));
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ a, b, c, d }) catch buf[0..0];
    }
};

/// Port/service on a host
pub const Port = struct {
    number: u16,
    protocol: Protocol,
    service: Service,
    state: State,

    pub const Protocol = enum { tcp, udp };
    pub const State = enum { open, filtered, closed };

    pub const Service = enum {
        ssh,
        http,
        https,
        ftp,
        smtp,
        dns,
        mysql,
        postgresql,
        mongodb,
        redis,
        elasticsearch,
        rdp,
        telnet,
        snmp,
        ntp,
        ldap,
        smb,
        unknown,

        pub fn toStr(self: Service) []const u8 {
            return @tagName(self);
        }
    };
};

/// Common port to service mapping
pub const CommonPorts = struct {
    pub const ssh: u16 = 22;
    pub const http: u16 = 80;
    pub const https: u16 = 443;
    pub const ftp: u16 = 21;
    pub const smtp: u16 = 25;
    pub const dns: u16 = 53;
    pub const mysql: u16 = 3306;
    pub const postgresql: u16 = 5432;
    pub const mongodb: u16 = 27017;
    pub const redis: u16 = 6379;
    pub const elasticsearch: u16 = 9200;
    pub const rdp: u16 = 3389;

    pub fn getService(port: u16) Port.Service {
        return switch (port) {
            22 => .ssh,
            80 => .http,
            443 => .https,
            21 => .ftp,
            25 => .smtp,
            53 => .dns,
            3306 => .mysql,
            5432 => .postgresql,
            27017 => .mongodb,
            6379 => .redis,
            9200 => .elasticsearch,
            3389 => .rdp,
            23 => .telnet,
            161 => .snmp,
            123 => .ntp,
            389 => .ldap,
            445 => .smb,
            else => .unknown,
        };
    }
};

/// Host profile for generation
pub const HostProfile = struct {
    host_type: HostType,
    os_weights: [8]f32, // Weights for each OS type
    common_ports: []const u16,
    port_open_probability: f32,

    pub const server_profile = HostProfile{
        .host_type = .server,
        .os_weights = .{ 0.7, 0.2, 0.02, 0.05, 0.0, 0.0, 0.03, 0.0 }, // linux heavy
        .common_ports = &[_]u16{ 22, 80, 443, 3306, 5432, 6379, 9200 },
        .port_open_probability = 0.6,
    };

    pub const workstation_profile = HostProfile{
        .host_type = .workstation,
        .os_weights = .{ 0.15, 0.7, 0.1, 0.02, 0.0, 0.0, 0.03, 0.0 }, // windows heavy
        .common_ports = &[_]u16{ 22, 3389, 445 },
        .port_open_probability = 0.2,
    };

    pub const web_server_profile = HostProfile{
        .host_type = .web_server,
        .os_weights = .{ 0.85, 0.1, 0.02, 0.03, 0.0, 0.0, 0.0, 0.0 },
        .common_ports = &[_]u16{ 22, 80, 443, 8080, 8443 },
        .port_open_probability = 0.9,
    };

    pub const database_profile = HostProfile{
        .host_type = .database,
        .os_weights = .{ 0.8, 0.15, 0.0, 0.05, 0.0, 0.0, 0.0, 0.0 },
        .common_ports = &[_]u16{ 22, 3306, 5432, 27017, 6379, 9200 },
        .port_open_probability = 0.7,
    };

    pub const iot_profile = HostProfile{
        .host_type = .iot_device,
        .os_weights = .{ 0.3, 0.0, 0.0, 0.0, 0.1, 0.2, 0.4, 0.0 },
        .common_ports = &[_]u16{ 80, 443, 23, 161 },
        .port_open_probability = 0.4,
    };
};

/// Host expander - generates hosts within subnets
pub const HostExpander = struct {
    rng: std.Random,
    allocator: std.mem.Allocator,

    // Host type distribution weights
    const type_weights: [10]f32 = .{
        0.30, // server
        0.25, // workstation
        0.10, // router
        0.05, // firewall
        0.03, // load_balancer
        0.08, // database
        0.10, // web_server
        0.02, // mail_server
        0.02, // dns_server
        0.05, // iot_device
    };

    pub fn init(allocator: std.mem.Allocator, seed: u64) HostExpander {
        var prng = std.Random.DefaultPrng.init(seed);
        return .{
            .rng = prng.random(),
            .allocator = allocator,
        };
    }

    pub fn initWithRng(allocator: std.mem.Allocator, rng: std.Random) HostExpander {
        return .{
            .rng = rng,
            .allocator = allocator,
        };
    }

    /// Generate a host at a specific IP within a prefix
    pub fn generateHost(self: *HostExpander, ip: u32, prefix: topology.Prefix) Host {
        const host_type = self.selectHostType();
        const profile = self.getProfile(host_type);
        const os = self.selectOS(profile.os_weights);
        const port_count = self.calculatePortCount(profile);

        return Host{
            .ip = ip,
            .host_type = host_type,
            .os = os,
            .asn = prefix.asn,
            .prefix_network = prefix.network,
            .prefix_mask = prefix.mask,
            .port_count = port_count,
        };
    }

    fn selectHostType(self: *HostExpander) HostType {
        const r = self.rng.float(f32);
        var cumulative: f32 = 0.0;
        for (type_weights, 0..) |weight, i| {
            cumulative += weight;
            if (r < cumulative) {
                return @enumFromInt(i);
            }
        }
        return .server;
    }

    fn selectOS(self: *HostExpander, weights: [8]f32) OSType {
        const r = self.rng.float(f32);
        var cumulative: f32 = 0.0;
        for (weights, 0..) |weight, i| {
            cumulative += weight;
            if (r < cumulative) {
                return @enumFromInt(i);
            }
        }
        return .linux;
    }

    fn getProfile(_: *HostExpander, host_type: HostType) HostProfile {
        return switch (host_type) {
            .server => HostProfile.server_profile,
            .workstation => HostProfile.workstation_profile,
            .web_server => HostProfile.web_server_profile,
            .database => HostProfile.database_profile,
            .iot_device => HostProfile.iot_profile,
            else => HostProfile.server_profile,
        };
    }

    fn calculatePortCount(self: *HostExpander, profile: HostProfile) u8 {
        var count: u8 = 0;
        for (profile.common_ports) |_| {
            if (self.rng.float(f32) < profile.port_open_probability) {
                count += 1;
            }
        }
        return count;
    }

    /// Generate ports for a host
    pub fn generatePorts(self: *HostExpander, host: Host) PortIterator {
        return PortIterator.init(self, host);
    }
};

/// Iterator for hosts in a subnet
pub const SubnetHostIterator = struct {
    expander: *HostExpander,
    prefix: topology.Prefix,
    current_offset: u32,
    max_hosts: u32,
    density: f32,

    pub fn init(expander: *HostExpander, prefix: topology.Prefix, density: f32) SubnetHostIterator {
        const subnet_size = prefix.getSize();
        const max_hosts = @as(u32, @intFromFloat(@as(f32, @floatFromInt(subnet_size)) * density));
        return .{
            .expander = expander,
            .prefix = prefix,
            .current_offset = 1, // Skip network address
            .max_hosts = @max(1, max_hosts),
            .density = density,
        };
    }

    pub fn next(self: *SubnetHostIterator) ?Host {
        const subnet_size = self.prefix.getSize();
        while (self.current_offset < subnet_size - 1) { // Skip broadcast
            const offset = self.current_offset;
            self.current_offset += 1;

            // Apply density - skip some IPs
            if (self.expander.rng.float(f32) > self.density) {
                continue;
            }

            const ip = self.prefix.network + offset;
            return self.expander.generateHost(ip, self.prefix);
        }
        return null;
    }

    pub fn reset(self: *SubnetHostIterator) void {
        self.current_offset = 1;
    }
};

/// Iterator for ports on a host
pub const PortIterator = struct {
    expander: *HostExpander,
    host: Host,
    profile: HostProfile,
    current_index: usize,

    pub fn init(expander: *HostExpander, host: Host) PortIterator {
        return .{
            .expander = expander,
            .host = host,
            .profile = expander.getProfile(host.host_type),
            .current_index = 0,
        };
    }

    pub fn next(self: *PortIterator) ?Port {
        while (self.current_index < self.profile.common_ports.len) {
            const port_num = self.profile.common_ports[self.current_index];
            self.current_index += 1;

            if (self.expander.rng.float(f32) < self.profile.port_open_probability) {
                return Port{
                    .number = port_num,
                    .protocol = if (port_num == 53 or port_num == 123 or port_num == 161) .udp else .tcp,
                    .service = CommonPorts.getService(port_num),
                    .state = .open,
                };
            }
        }
        return null;
    }
};

test "HostExpander generates valid hosts" {
    var expander = HostExpander.init(std.testing.allocator, 12345);
    const prefix = topology.Prefix{ .network = 0x0A000000, .mask = 24, .asn = 64512 };

    const host = expander.generateHost(0x0A000001, prefix);
    try std.testing.expect(host.ip == 0x0A000001);
    try std.testing.expect(host.asn == 64512);
}

test "SubnetHostIterator respects density" {
    var expander = HostExpander.init(std.testing.allocator, 12345);
    const prefix = topology.Prefix{ .network = 0x0A000000, .mask = 28, .asn = 64512 }; // /28 = 16 IPs

    var iter = SubnetHostIterator.init(&expander, prefix, 0.5);
    var count: u32 = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    // With 50% density on 14 usable IPs, expect roughly 7 hosts (with some variance)
    try std.testing.expect(count > 0 and count <= 14);
}
