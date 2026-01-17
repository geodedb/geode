// CANARY: REQ=REQ-LOADTEST-GENERATOR-001; FEATURE="StreamingDataGenerator"; ASPECT=Connections; STATUS=EXEMPT; OWNER=tooling; UPDATED=2026-01-03
//! Connection Generator
//! Generates realistic network traffic patterns between hosts

const std = @import("std");
const hosts = @import("hosts.zig");

/// Traffic pattern types
pub const TrafficPattern = enum {
    web_traffic, // Clients -> CDN/Web servers (many to few)
    enterprise, // Internal services (mesh-like)
    p2p, // Peer-to-peer distributed
    scan, // Port scanning patterns
    botnet, // C2 communication patterns
    database, // App servers -> Database servers
    microservices, // Service mesh patterns

    pub fn toStr(self: TrafficPattern) []const u8 {
        return @tagName(self);
    }
};

/// Connection between two hosts
pub const Connection = struct {
    src_ip: u32,
    dst_ip: u32,
    src_port: u16,
    dst_port: u16,
    protocol: hosts.Port.Protocol,
    bytes_sent: u64,
    bytes_recv: u64,
    packets: u32,
    duration_ms: u32,
    flags: Flags,

    pub const Flags = packed struct {
        syn: bool = false,
        ack: bool = false,
        fin: bool = false,
        rst: bool = false,
        encrypted: bool = false,
        _padding: u3 = 0,
    };

    pub fn srcIpToStr(self: Connection, buf: []u8) []const u8 {
        return ipToStr(self.src_ip, buf);
    }

    pub fn dstIpToStr(self: Connection, buf: []u8) []const u8 {
        return ipToStr(self.dst_ip, buf);
    }

    fn ipToStr(ip: u32, buf: []u8) []const u8 {
        const a = @as(u8, @truncate(ip >> 24));
        const b = @as(u8, @truncate(ip >> 16));
        const c = @as(u8, @truncate(ip >> 8));
        const d = @as(u8, @truncate(ip));
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ a, b, c, d }) catch buf[0..0];
    }
};

/// Pattern-specific configuration
pub const PatternConfig = struct {
    // Web traffic: 80% of connections go to top 1% of servers
    web_server_concentration: f32 = 0.8,
    web_top_server_fraction: f32 = 0.01,

    // Enterprise: average connections per host
    enterprise_avg_connections: u32 = 10,

    // P2P: connections per peer
    p2p_connections_per_peer: u32 = 8,

    // Scan: ports to scan per target
    scan_ports_per_target: u32 = 100,

    // Database: app-to-db ratio
    db_app_to_db_ratio: f32 = 10.0,
};

/// Connection generator
pub const ConnectionGenerator = struct {
    rng: std.Random,
    allocator: std.mem.Allocator,
    config: PatternConfig,

    pub fn init(allocator: std.mem.Allocator, seed: u64) ConnectionGenerator {
        var prng = std.Random.DefaultPrng.init(seed);
        return .{
            .rng = prng.random(),
            .allocator = allocator,
            .config = PatternConfig{},
        };
    }

    pub fn initWithRng(allocator: std.mem.Allocator, rng: std.Random) ConnectionGenerator {
        return .{
            .rng = rng,
            .allocator = allocator,
            .config = PatternConfig{},
        };
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, seed: u64, config: PatternConfig) ConnectionGenerator {
        var prng = std.Random.DefaultPrng.init(seed);
        return .{
            .rng = prng.random(),
            .allocator = allocator,
            .config = config,
        };
    }

    /// Generate a connection between two hosts based on pattern
    pub fn generateConnection(
        self: *ConnectionGenerator,
        src: hosts.Host,
        dst: hosts.Host,
        pattern: TrafficPattern,
    ) Connection {
        const dst_port = self.selectDestPort(dst, pattern);
        const src_port = self.rng.intRangeAtMost(u16, 49152, 65535); // Ephemeral port

        const is_encrypted = dst_port == 443 or dst_port == 22 or dst_port == 993 or dst_port == 995;

        return Connection{
            .src_ip = src.ip,
            .dst_ip = dst.ip,
            .src_port = src_port,
            .dst_port = dst_port,
            .protocol = self.selectProtocol(dst_port),
            .bytes_sent = self.generateBytes(pattern, true),
            .bytes_recv = self.generateBytes(pattern, false),
            .packets = self.generatePackets(pattern),
            .duration_ms = self.generateDuration(pattern),
            .flags = .{
                .syn = true,
                .ack = true,
                .fin = self.rng.float(f32) > 0.1, // 90% complete normally
                .rst = self.rng.float(f32) < 0.02, // 2% reset
                .encrypted = is_encrypted,
            },
        };
    }

    fn selectDestPort(self: *ConnectionGenerator, dst: hosts.Host, pattern: TrafficPattern) u16 {
        return switch (pattern) {
            .web_traffic => if (self.rng.float(f32) < 0.7) @as(u16, 443) else 80,
            .enterprise => self.selectEnterprisePort(dst),
            .database => self.selectDatabasePort(dst),
            .scan => self.rng.intRangeAtMost(u16, 1, 1024),
            .p2p => self.rng.intRangeAtMost(u16, 6881, 6889), // BitTorrent range
            .botnet => if (self.rng.float(f32) < 0.5) @as(u16, 443) else self.rng.intRangeAtMost(u16, 8000, 9000),
            .microservices => self.rng.intRangeAtMost(u16, 8080, 8090),
        };
    }

    fn selectEnterprisePort(self: *ConnectionGenerator, dst: hosts.Host) u16 {
        return switch (dst.host_type) {
            .web_server => if (self.rng.float(f32) < 0.7) @as(u16, 443) else 80,
            .database => self.selectDatabasePort(dst),
            .mail_server => 25,
            .dns_server => 53,
            else => 22,
        };
    }

    fn selectDatabasePort(_: *ConnectionGenerator, dst: hosts.Host) u16 {
        // Select port based on OS (as a proxy for DB type)
        return switch (dst.os) {
            .linux => 5432, // PostgreSQL common on Linux
            .windows => 1433, // SQL Server
            else => 3306, // MySQL default
        };
    }

    fn selectProtocol(_: *ConnectionGenerator, port: u16) hosts.Port.Protocol {
        return switch (port) {
            53, 123, 161, 162, 514, 69 => .udp,
            else => .tcp,
        };
    }

    fn generateBytes(self: *ConnectionGenerator, pattern: TrafficPattern, is_sent: bool) u64 {
        const base: u64 = switch (pattern) {
            .web_traffic => if (is_sent) 500 else 50000, // Small request, large response
            .enterprise => 2000,
            .database => if (is_sent) 200 else 10000,
            .scan => 64, // Tiny packets
            .p2p => 16384, // Chunk size
            .botnet => 256, // Small C2 messages
            .microservices => 1024,
        };

        // Add variance (0.5x to 2x)
        const multiplier = 0.5 + self.rng.float(f64) * 1.5;
        return @intFromFloat(@as(f64, @floatFromInt(base)) * multiplier);
    }

    fn generatePackets(self: *ConnectionGenerator, pattern: TrafficPattern) u32 {
        const base: u32 = switch (pattern) {
            .web_traffic => 50,
            .enterprise => 20,
            .database => 30,
            .scan => 3,
            .p2p => 100,
            .botnet => 5,
            .microservices => 15,
        };

        return base + self.rng.intRangeAtMost(u32, 0, base);
    }

    fn generateDuration(self: *ConnectionGenerator, pattern: TrafficPattern) u32 {
        const base_ms: u32 = switch (pattern) {
            .web_traffic => 500,
            .enterprise => 100,
            .database => 50,
            .scan => 10,
            .p2p => 60000, // Long-lived
            .botnet => 200,
            .microservices => 30,
        };

        return base_ms + self.rng.intRangeAtMost(u32, 0, base_ms * 2);
    }

    /// Check if two hosts should connect based on pattern
    pub fn shouldConnect(self: *ConnectionGenerator, src: hosts.Host, dst: hosts.Host, pattern: TrafficPattern) bool {
        if (src.ip == dst.ip) return false;

        return switch (pattern) {
            .web_traffic => dst.host_type == .web_server and src.host_type == .workstation,
            .enterprise => src.asn == dst.asn, // Same organization
            .database => (src.host_type == .web_server or src.host_type == .server) and dst.host_type == .database,
            .scan => self.rng.float(f32) < 0.001, // Very sparse
            .p2p => self.rng.float(f32) < 0.01,
            .botnet => dst.host_type == .server and self.rng.float(f32) < 0.005,
            .microservices => src.asn == dst.asn and self.rng.float(f32) < 0.1,
        };
    }
};

/// Batch connection iterator for efficient generation
pub const ConnectionBatchIterator = struct {
    generator: *ConnectionGenerator,
    src_hosts: []const hosts.Host,
    dst_hosts: []const hosts.Host,
    pattern: TrafficPattern,
    src_index: usize,
    dst_index: usize,
    connections_per_src: u32,
    current_connection: u32,

    pub fn init(
        generator: *ConnectionGenerator,
        src_hosts: []const hosts.Host,
        dst_hosts: []const hosts.Host,
        pattern: TrafficPattern,
        connections_per_src: u32,
    ) ConnectionBatchIterator {
        return .{
            .generator = generator,
            .src_hosts = src_hosts,
            .dst_hosts = dst_hosts,
            .pattern = pattern,
            .src_index = 0,
            .dst_index = 0,
            .connections_per_src = connections_per_src,
            .current_connection = 0,
        };
    }

    pub fn next(self: *ConnectionBatchIterator) ?Connection {
        while (self.src_index < self.src_hosts.len) {
            const src = self.src_hosts[self.src_index];

            while (self.dst_index < self.dst_hosts.len) {
                const dst = self.dst_hosts[self.dst_index];
                self.dst_index += 1;

                if (self.generator.shouldConnect(src, dst, self.pattern)) {
                    self.current_connection += 1;
                    if (self.current_connection >= self.connections_per_src) {
                        self.current_connection = 0;
                        self.src_index += 1;
                        self.dst_index = 0;
                    }
                    return self.generator.generateConnection(src, dst, self.pattern);
                }
            }

            self.src_index += 1;
            self.dst_index = 0;
            self.current_connection = 0;
        }

        return null;
    }
};

/// Random connection generator (for large-scale without full host list)
pub const RandomConnectionGenerator = struct {
    generator: *ConnectionGenerator,
    pattern: TrafficPattern,
    remaining: u64,

    // IP ranges for generation
    src_base: u32,
    src_range: u32,
    dst_base: u32,
    dst_range: u32,

    pub fn init(
        generator: *ConnectionGenerator,
        pattern: TrafficPattern,
        count: u64,
        src_base: u32,
        src_range: u32,
        dst_base: u32,
        dst_range: u32,
    ) RandomConnectionGenerator {
        return .{
            .generator = generator,
            .pattern = pattern,
            .remaining = count,
            .src_base = src_base,
            .src_range = src_range,
            .dst_base = dst_base,
            .dst_range = dst_range,
        };
    }

    pub fn next(self: *RandomConnectionGenerator) ?Connection {
        if (self.remaining == 0) return null;
        self.remaining -= 1;

        // Generate random source and destination
        const src_offset = self.generator.rng.intRangeLessThan(u32, 0, self.src_range);
        const dst_offset = self.generator.rng.intRangeLessThan(u32, 0, self.dst_range);

        const src = hosts.Host{
            .ip = self.src_base + src_offset,
            .host_type = .workstation,
            .os = .windows,
            .asn = 64512,
            .prefix_network = self.src_base,
            .prefix_mask = 16,
            .port_count = 0,
        };

        const dst = hosts.Host{
            .ip = self.dst_base + dst_offset,
            .host_type = .web_server,
            .os = .linux,
            .asn = 64513,
            .prefix_network = self.dst_base,
            .prefix_mask = 16,
            .port_count = 5,
        };

        return self.generator.generateConnection(src, dst, self.pattern);
    }
};

test "ConnectionGenerator creates valid connections" {
    var gen = ConnectionGenerator.init(std.testing.allocator, 12345);

    const src = hosts.Host{
        .ip = 0x0A000001,
        .host_type = .workstation,
        .os = .windows,
        .asn = 64512,
        .prefix_network = 0x0A000000,
        .prefix_mask = 24,
        .port_count = 0,
    };

    const dst = hosts.Host{
        .ip = 0xC0A80001,
        .host_type = .web_server,
        .os = .linux,
        .asn = 64513,
        .prefix_network = 0xC0A80000,
        .prefix_mask = 24,
        .port_count = 5,
    };

    const conn = gen.generateConnection(src, dst, .web_traffic);
    try std.testing.expect(conn.src_ip == src.ip);
    try std.testing.expect(conn.dst_ip == dst.ip);
    try std.testing.expect(conn.dst_port == 443 or conn.dst_port == 80);
}
