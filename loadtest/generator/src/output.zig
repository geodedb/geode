// CANARY: REQ=REQ-LOADTEST-GENERATOR-001; FEATURE="StreamingDataGenerator"; ASPECT=Output; STATUS=EXEMPT; OWNER=tooling; UPDATED=2026-01-03
//! Output Formatters
//! Streaming output in GQL, CSV, and binary formats

const std = @import("std");
const builtin = @import("builtin");
const topology = @import("topology.zig");
const hosts = @import("hosts.zig");
const connections = @import("connections.zig");

// Zig 0.15 compatibility for std file handles
fn getStdErr() std.fs.File {
    return if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDERR_FILENO };
}

fn getStdOut() std.fs.File {
    return if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDOUT_FILENO };
}

/// Output format types
pub const OutputFormat = enum {
    gql,
    csv,
    binary,
    json,
    cypher,
};

/// Statistics tracker for output progress
pub const OutputStats = struct {
    nodes_written: u64 = 0,
    edges_written: u64 = 0,
    bytes_written: u64 = 0,
    start_time: i64,

    pub fn init() OutputStats {
        return .{
            .start_time = std.time.milliTimestamp(),
        };
    }

    pub fn recordNode(self: *OutputStats, bytes: u64) void {
        self.nodes_written += 1;
        self.bytes_written += bytes;
    }

    pub fn recordEdge(self: *OutputStats, bytes: u64) void {
        self.edges_written += 1;
        self.bytes_written += bytes;
    }

    pub fn getElapsedMs(self: *const OutputStats) i64 {
        return std.time.milliTimestamp() - self.start_time;
    }

    pub fn getNodesPerSecond(self: *const OutputStats) f64 {
        const elapsed = self.getElapsedMs();
        if (elapsed == 0) return 0;
        return @as(f64, @floatFromInt(self.nodes_written)) / (@as(f64, @floatFromInt(elapsed)) / 1000.0);
    }

    pub fn getEdgesPerSecond(self: *const OutputStats) f64 {
        const elapsed = self.getElapsedMs();
        if (elapsed == 0) return 0;
        return @as(f64, @floatFromInt(self.edges_written)) / (@as(f64, @floatFromInt(elapsed)) / 1000.0);
    }

    pub fn getThroughputMBps(self: *const OutputStats) f64 {
        const elapsed = self.getElapsedMs();
        if (elapsed == 0) return 0;
        return @as(f64, @floatFromInt(self.bytes_written)) / (1024.0 * 1024.0) / (@as(f64, @floatFromInt(elapsed)) / 1000.0);
    }
};

/// GQL output formatter
pub const GqlFormatter = struct {
    file: std.fs.File,
    stats: *OutputStats,
    buf: [4096]u8 = undefined,

    pub fn init(file: std.fs.File, stats: *OutputStats) GqlFormatter {
        return .{
            .file = file,
            .stats = stats,
        };
    }

    pub fn writeHost(self: *GqlFormatter, host: hosts.Host) !void {
        var ip_buf: [16]u8 = undefined;
        const ip_str = host.ipToStr(&ip_buf);

        const written = try std.fmt.bufPrint(&self.buf, "CREATE (:Host {{ip: '{s}', ip_int: {d}, type: '{s}', os: '{s}', asn: {d}}})\n", .{
            ip_str,
            host.ip,
            host.host_type.toStr(),
            host.os.toStr(),
            host.asn,
        });

        try self.file.writeAll(written);
        self.stats.recordNode(written.len);
    }

    pub fn writeASN(self: *GqlFormatter, asn: topology.ASN) !void {
        const written = try std.fmt.bufPrint(&self.buf, "CREATE (:ASN {{number: {d}, tier: {d}, prefix_count: {d}}})\n", .{
            asn.number,
            @intFromEnum(asn.tier),
            asn.prefix_count,
        });

        try self.file.writeAll(written);
        self.stats.recordNode(written.len);
    }

    pub fn writePrefix(self: *GqlFormatter, prefix: topology.Prefix) !void {
        var prefix_buf: [24]u8 = undefined;
        const prefix_str = prefix.toStr(&prefix_buf);

        const written = try std.fmt.bufPrint(&self.buf, "CREATE (:Prefix {{cidr: '{s}', network: {d}, mask: {d}, asn: {d}}})\n", .{
            prefix_str,
            prefix.network,
            prefix.mask,
            prefix.asn,
        });

        try self.file.writeAll(written);
        self.stats.recordNode(written.len);
    }

    pub fn writeConnection(self: *GqlFormatter, conn: connections.Connection) !void {
        var src_buf: [16]u8 = undefined;
        var dst_buf: [16]u8 = undefined;
        const src_str = conn.srcIpToStr(&src_buf);
        const dst_str = conn.dstIpToStr(&dst_buf);

        const written = try std.fmt.bufPrint(&self.buf, "MATCH (a:Host {{ip: '{s}'}}), (b:Host {{ip: '{s}'}}) CREATE (a)-[:CONNECTS_TO {{protocol: '{s}', src_port: {d}, dst_port: {d}, bytes: {d}}}]->(b)\n", .{
            src_str,
            dst_str,
            @tagName(conn.protocol),
            conn.src_port,
            conn.dst_port,
            conn.bytes_sent + conn.bytes_recv,
        });

        try self.file.writeAll(written);
        self.stats.recordEdge(written.len);
    }

    pub fn writePeering(self: *GqlFormatter, peering: topology.Peering) !void {
        const written = try std.fmt.bufPrint(&self.buf, "MATCH (a:ASN {{number: {d}}}), (b:ASN {{number: {d}}}) CREATE (a)-[:PEERS_WITH {{relationship: '{s}'}}]->(b)\n", .{
            peering.asn1,
            peering.asn2,
            @tagName(peering.relationship),
        });

        try self.file.writeAll(written);
        self.stats.recordEdge(written.len);
    }
};

/// CSV output formatter
pub const CsvFormatter = struct {
    file: std.fs.File,
    stats: *OutputStats,
    buf: [4096]u8 = undefined,
    include_header: bool,
    header_written: bool = false,

    pub fn init(file: std.fs.File, stats: *OutputStats, include_header: bool) CsvFormatter {
        return .{
            .file = file,
            .stats = stats,
            .include_header = include_header,
        };
    }

    pub fn writeHostHeader(self: *CsvFormatter) !void {
        if (self.include_header and !self.header_written) {
            try self.file.writeAll("ip,ip_int,type,os,asn,prefix_network,prefix_mask\n");
            self.header_written = true;
        }
    }

    pub fn writeHost(self: *CsvFormatter, host: hosts.Host) !void {
        try self.writeHostHeader();

        var ip_buf: [16]u8 = undefined;
        const ip_str = host.ipToStr(&ip_buf);

        const written = try std.fmt.bufPrint(&self.buf, "{s},{d},{s},{s},{d},{d},{d}\n", .{
            ip_str,
            host.ip,
            host.host_type.toStr(),
            host.os.toStr(),
            host.asn,
            host.prefix_network,
            host.prefix_mask,
        });

        try self.file.writeAll(written);
        self.stats.recordNode(written.len);
    }

    pub fn writeConnectionHeader(self: *CsvFormatter) !void {
        if (self.include_header and !self.header_written) {
            try self.file.writeAll("src_ip,dst_ip,src_port,dst_port,protocol,bytes_sent,bytes_recv,packets,duration_ms\n");
            self.header_written = true;
        }
    }

    pub fn writeConnection(self: *CsvFormatter, conn: connections.Connection) !void {
        try self.writeConnectionHeader();

        var src_buf: [16]u8 = undefined;
        var dst_buf: [16]u8 = undefined;
        const src_str = conn.srcIpToStr(&src_buf);
        const dst_str = conn.dstIpToStr(&dst_buf);

        const written = try std.fmt.bufPrint(&self.buf, "{s},{s},{d},{d},{s},{d},{d},{d},{d}\n", .{
            src_str,
            dst_str,
            conn.src_port,
            conn.dst_port,
            @tagName(conn.protocol),
            conn.bytes_sent,
            conn.bytes_recv,
            conn.packets,
            conn.duration_ms,
        });

        try self.file.writeAll(written);
        self.stats.recordEdge(written.len);
    }
};

/// Binary output formatter for fast bulk loading
pub const BinaryFormatter = struct {
    file: std.fs.File,
    stats: *OutputStats,

    pub const RecordType = enum(u8) {
        host = 1,
        asn = 2,
        prefix = 3,
        connection = 4,
        peering = 5,
    };

    pub fn init(file: std.fs.File, stats: *OutputStats) BinaryFormatter {
        return .{
            .file = file,
            .stats = stats,
        };
    }

    pub fn writeHost(self: *BinaryFormatter, host: hosts.Host) !void {
        // Record format: [type:u8][ip:u32][host_type:u8][os:u8][asn:u32][prefix_net:u32][prefix_mask:u8]
        var buf: [18]u8 = undefined;
        buf[0] = @intFromEnum(RecordType.host);
        std.mem.writeInt(u32, buf[1..5], host.ip, .little);
        buf[5] = @intFromEnum(host.host_type);
        buf[6] = @intFromEnum(host.os);
        std.mem.writeInt(u32, buf[7..11], host.asn, .little);
        std.mem.writeInt(u32, buf[11..15], host.prefix_network, .little);
        buf[15] = host.prefix_mask;
        buf[16] = host.port_count;
        buf[17] = 0; // padding

        try self.file.writeAll(&buf);
        self.stats.recordNode(buf.len);
    }

    pub fn writeConnection(self: *BinaryFormatter, conn: connections.Connection) !void {
        // Record format: [type:u8][src_ip:u32][dst_ip:u32][src_port:u16][dst_port:u16][protocol:u8][bytes:u64][packets:u32][duration:u32][flags:u8]
        var buf: [32]u8 = undefined;
        buf[0] = @intFromEnum(RecordType.connection);
        std.mem.writeInt(u32, buf[1..5], conn.src_ip, .little);
        std.mem.writeInt(u32, buf[5..9], conn.dst_ip, .little);
        std.mem.writeInt(u16, buf[9..11], conn.src_port, .little);
        std.mem.writeInt(u16, buf[11..13], conn.dst_port, .little);
        buf[13] = @intFromEnum(conn.protocol);
        std.mem.writeInt(u64, buf[14..22], conn.bytes_sent + conn.bytes_recv, .little);
        std.mem.writeInt(u32, buf[22..26], conn.packets, .little);
        std.mem.writeInt(u32, buf[26..30], conn.duration_ms, .little);
        buf[30] = @as(u8, @bitCast(conn.flags));
        buf[31] = 0; // padding

        try self.file.writeAll(&buf);
        self.stats.recordEdge(buf.len);
    }

    pub fn writeASN(self: *BinaryFormatter, asn: topology.ASN) !void {
        var buf: [10]u8 = undefined;
        buf[0] = @intFromEnum(RecordType.asn);
        std.mem.writeInt(u32, buf[1..5], asn.number, .little);
        buf[5] = @intFromEnum(asn.tier);
        std.mem.writeInt(u16, buf[6..8], asn.prefix_count, .little);
        buf[8] = 0;
        buf[9] = 0;

        try self.file.writeAll(&buf);
        self.stats.recordNode(buf.len);
    }

    pub fn writePrefix(self: *BinaryFormatter, prefix: topology.Prefix) !void {
        var buf: [14]u8 = undefined;
        buf[0] = @intFromEnum(RecordType.prefix);
        std.mem.writeInt(u32, buf[1..5], prefix.network, .little);
        buf[5] = prefix.mask;
        std.mem.writeInt(u32, buf[6..10], prefix.asn, .little);
        buf[10] = 0;
        buf[11] = 0;
        buf[12] = 0;
        buf[13] = 0;

        try self.file.writeAll(&buf);
        self.stats.recordNode(buf.len);
    }

    pub fn writeHeader(self: *BinaryFormatter) !void {
        // Write magic header
        try self.file.writeAll("GEOD");
        var ver_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &ver_buf, 1, .little);
        try self.file.writeAll(&ver_buf);
    }
};

/// JSON output formatter (for small datasets / debugging)
pub const JsonFormatter = struct {
    file: std.fs.File,
    stats: *OutputStats,
    buf: [4096]u8 = undefined,
    first_node: bool = true,
    first_edge: bool = true,

    pub fn init(file: std.fs.File, stats: *OutputStats) JsonFormatter {
        return .{
            .file = file,
            .stats = stats,
        };
    }

    pub fn writeHeader(self: *JsonFormatter) !void {
        try self.file.writeAll("{\"nodes\":[\n");
    }

    pub fn writeEdgeSection(self: *JsonFormatter) !void {
        try self.file.writeAll("\n],\"edges\":[\n");
        self.first_edge = true;
    }

    pub fn writeFooter(self: *JsonFormatter) !void {
        try self.file.writeAll("\n]}\n");
    }

    pub fn writeHost(self: *JsonFormatter, host: hosts.Host) !void {
        var ip_buf: [16]u8 = undefined;
        const ip_str = host.ipToStr(&ip_buf);

        const prefix = if (self.first_node) "" else ",\n";
        self.first_node = false;

        const written = try std.fmt.bufPrint(&self.buf, "{s}{{\"ip\":\"{s}\",\"ip_int\":{d},\"type\":\"{s}\",\"os\":\"{s}\",\"asn\":{d}}}", .{
            prefix,
            ip_str,
            host.ip,
            host.host_type.toStr(),
            host.os.toStr(),
            host.asn,
        });

        try self.file.writeAll(written);
        self.stats.recordNode(written.len);
    }

    pub fn writeConnection(self: *JsonFormatter, conn: connections.Connection) !void {
        var src_buf: [16]u8 = undefined;
        var dst_buf: [16]u8 = undefined;
        const src_str = conn.srcIpToStr(&src_buf);
        const dst_str = conn.dstIpToStr(&dst_buf);

        const prefix = if (self.first_edge) "" else ",\n";
        self.first_edge = false;

        const written = try std.fmt.bufPrint(&self.buf, "{s}{{\"src\":\"{s}\",\"dst\":\"{s}\",\"protocol\":\"{s}\",\"bytes\":{d}}}", .{
            prefix,
            src_str,
            dst_str,
            @tagName(conn.protocol),
            conn.bytes_sent + conn.bytes_recv,
        });

        try self.file.writeAll(written);
        self.stats.recordEdge(written.len);
    }
};

/// Progress reporter for CLI output
pub const ProgressReporter = struct {
    stats: *const OutputStats,
    target_nodes: u64,
    target_edges: u64,
    last_report_time: i64,
    report_interval_ms: i64 = 1000,
    stderr_file: std.fs.File,
    progress_buf: [256]u8 = undefined,

    pub fn init(stats: *const OutputStats, target_nodes: u64, target_edges: u64) ProgressReporter {
        return .{
            .stats = stats,
            .target_nodes = target_nodes,
            .target_edges = target_edges,
            .last_report_time = std.time.milliTimestamp(),
            .stderr_file = getStdErr(),
        };
    }

    pub fn maybeReport(self: *ProgressReporter) void {
        const now = std.time.milliTimestamp();
        if (now - self.last_report_time < self.report_interval_ms) return;
        self.last_report_time = now;
        self.report();
    }

    pub fn report(self: *ProgressReporter) void {
        const node_pct = if (self.target_nodes > 0)
            @as(f64, @floatFromInt(self.stats.nodes_written)) / @as(f64, @floatFromInt(self.target_nodes)) * 100.0
        else
            0.0;

        const edge_pct = if (self.target_edges > 0)
            @as(f64, @floatFromInt(self.stats.edges_written)) / @as(f64, @floatFromInt(self.target_edges)) * 100.0
        else
            0.0;

        const msg = std.fmt.bufPrint(&self.progress_buf, "\rNodes: {d}/{d} ({d:.1}%) | Edges: {d}/{d} ({d:.1}%) | {d:.1} MB/s     ", .{
            self.stats.nodes_written,
            self.target_nodes,
            node_pct,
            self.stats.edges_written,
            self.target_edges,
            edge_pct,
            self.stats.getThroughputMBps(),
        }) catch return;

        self.stderr_file.writeAll(msg) catch {};
    }

    pub fn finish(self: *ProgressReporter) void {
        self.report();
        self.stderr_file.writeAll("\nComplete!\n") catch {};
    }
};

test "OutputStats tracks correctly" {
    var stats = OutputStats.init();
    stats.recordNode(100);
    stats.recordNode(200);
    stats.recordEdge(50);

    try std.testing.expect(stats.nodes_written == 2);
    try std.testing.expect(stats.edges_written == 1);
    try std.testing.expect(stats.bytes_written == 350);
}
