// CANARY: REQ=REQ-LOADTEST-GENERATOR-001; FEATURE="StreamingDataGenerator"; ASPECT=Main; STATUS=IMPL; OWNER=tooling; UPDATED=2026-01-03
//! Geode Load Test Data Generator
//! High-performance streaming data generator for IPv4 network simulation

const std = @import("std");
const builtin = @import("builtin");
const topology = @import("topology.zig");
const hosts = @import("hosts.zig");
const connections = @import("connections.zig");
const output = @import("output.zig");

// Zig 0.15 compatibility for std file handles
fn getStdOut() std.fs.File {
    return if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDOUT_FILENO };
}

fn getStdErr() std.fs.File {
    return if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDERR_FILENO };
}

pub const Config = struct {
    // Generation targets
    target_nodes: u64 = 1_000_000,
    target_edges: u64 = 10_000_000,

    // Topology parameters
    asn_count: u32 = 1000,
    prefixes_per_asn: u32 = 10,
    host_density: f32 = 0.1, // 10% of IPs in use

    // Connection parameters
    connections_per_host: u32 = 10,
    traffic_pattern: connections.TrafficPattern = .web_traffic,

    // Output
    format: output.OutputFormat = .gql,
    output_path: ?[]const u8 = null, // null = stdout

    // Determinism
    seed: u64 = 12345,
    shard_id: u32 = 0,
    total_shards: u32 = 1,

    // Performance
    batch_size: u32 = 10000,
    show_progress: bool = true,
};

pub const Generator = struct {
    allocator: std.mem.Allocator,
    config: Config,
    rng: std.Random,
    topology_seeder: topology.TopologySeeder,
    host_expander: hosts.HostExpander,
    connection_gen: connections.ConnectionGenerator,

    pub fn init(allocator: std.mem.Allocator, config: Config) Generator {
        // Create deterministic seed based on config
        const effective_seed = config.seed +% @as(u64, config.shard_id) *% 0x9E3779B97F4A7C15;
        var prng = std.Random.DefaultPrng.init(effective_seed);
        const rng = prng.random();

        return .{
            .allocator = allocator,
            .config = config,
            .rng = rng,
            .topology_seeder = topology.TopologySeeder.initWithRng(allocator, rng),
            .host_expander = hosts.HostExpander.initWithRng(allocator, rng),
            .connection_gen = connections.ConnectionGenerator.initWithRng(allocator, rng),
        };
    }

    /// Run the full generation pipeline
    pub fn run(self: *Generator) !void {
        // Open output file/stdout
        const out_file = if (self.config.output_path) |path|
            try std.fs.cwd().createFile(path, .{})
        else
            getStdOut();
        defer if (self.config.output_path != null) out_file.close();

        var stats = output.OutputStats.init();
        var progress = output.ProgressReporter.init(&stats, self.config.target_nodes, self.config.target_edges);

        // Generate based on format
        switch (self.config.format) {
            .gql => try self.generateGql(out_file, &stats, &progress),
            .csv => try self.generateCsv(out_file, &stats, &progress),
            .binary => try self.generateBinary(out_file, &stats, &progress),
            .json => try self.generateJson(out_file, &stats, &progress),
            .cypher => try self.generateGql(out_file, &stats, &progress), // Same as GQL
        }

        if (self.config.show_progress) {
            progress.finish();
        }
    }

    fn generateGql(
        self: *Generator,
        file: std.fs.File,
        stats: *output.OutputStats,
        progress: *output.ProgressReporter,
    ) !void {
        var formatter = output.GqlFormatter.init(file, stats);

        // Generate ASNs
        var asn_iter = topology.ASNIterator.init(&self.topology_seeder, self.config.asn_count);
        var asn_list = try std.ArrayList(topology.ASN).initCapacity(self.allocator, self.config.asn_count);
        defer asn_list.deinit(self.allocator);

        while (asn_iter.next()) |asn| {
            try formatter.writeASN(asn);
            try asn_list.append(self.allocator, asn);
            if (self.config.show_progress) progress.maybeReport();
        }

        // Generate prefixes and hosts
        var base_network: u32 = self.getShardBaseNetwork();
        var host_list = try std.ArrayList(hosts.Host).initCapacity(self.allocator, 1024);
        defer host_list.deinit(self.allocator);

        for (asn_list.items) |asn| {
            var prefix_iter = topology.PrefixIterator.init(&self.topology_seeder, asn, base_network);
            while (prefix_iter.next()) |prefix| {
                try formatter.writePrefix(prefix);

                // Generate hosts in this prefix
                var host_iter = hosts.SubnetHostIterator.init(&self.host_expander, prefix, self.config.host_density);
                while (host_iter.next()) |host| {
                    if (stats.nodes_written >= self.config.target_nodes) break;
                    try formatter.writeHost(host);
                    try host_list.append(self.allocator, host);
                    if (self.config.show_progress) progress.maybeReport();
                }

                base_network +%= prefix.getSize();
            }
            if (stats.nodes_written >= self.config.target_nodes) break;
        }

        // Generate connections
        try self.generateConnectionsGql(&formatter, host_list.items, stats, progress);
    }

    fn generateConnectionsGql(
        self: *Generator,
        formatter: *output.GqlFormatter,
        host_list: []hosts.Host,
        stats: *output.OutputStats,
        progress: *output.ProgressReporter,
    ) !void {
        if (host_list.len < 2) return;

        // Use random connection generator for efficiency
        var rand_conn = connections.RandomConnectionGenerator.init(
            &self.connection_gen,
            self.config.traffic_pattern,
            self.config.target_edges,
            host_list[0].ip,
            @intCast(host_list.len),
            host_list[host_list.len / 2].ip,
            @intCast(host_list.len / 2),
        );

        while (rand_conn.next()) |conn| {
            try formatter.writeConnection(conn);
            if (self.config.show_progress) progress.maybeReport();
        }
        _ = stats;
    }

    fn generateCsv(
        self: *Generator,
        file: std.fs.File,
        stats: *output.OutputStats,
        progress: *output.ProgressReporter,
    ) !void {
        var formatter = output.CsvFormatter.init(file, stats, true);

        // Generate hosts
        var base_network: u32 = self.getShardBaseNetwork();
        var asn_iter = topology.ASNIterator.init(&self.topology_seeder, self.config.asn_count);

        while (asn_iter.next()) |asn| {
            var prefix_iter = topology.PrefixIterator.init(&self.topology_seeder, asn, base_network);
            while (prefix_iter.next()) |prefix| {
                var host_iter = hosts.SubnetHostIterator.init(&self.host_expander, prefix, self.config.host_density);
                while (host_iter.next()) |host| {
                    if (stats.nodes_written >= self.config.target_nodes) break;
                    try formatter.writeHost(host);
                    if (self.config.show_progress) progress.maybeReport();
                }
                base_network +%= prefix.getSize();
            }
            if (stats.nodes_written >= self.config.target_nodes) break;
        }
    }

    fn generateBinary(
        self: *Generator,
        file: std.fs.File,
        stats: *output.OutputStats,
        progress: *output.ProgressReporter,
    ) !void {
        var formatter = output.BinaryFormatter.init(file, stats);

        // Write magic header
        try formatter.writeHeader();

        var base_network: u32 = self.getShardBaseNetwork();
        var asn_iter = topology.ASNIterator.init(&self.topology_seeder, self.config.asn_count);

        while (asn_iter.next()) |asn| {
            try formatter.writeASN(asn);

            var prefix_iter = topology.PrefixIterator.init(&self.topology_seeder, asn, base_network);
            while (prefix_iter.next()) |prefix| {
                try formatter.writePrefix(prefix);

                var host_iter = hosts.SubnetHostIterator.init(&self.host_expander, prefix, self.config.host_density);
                while (host_iter.next()) |host| {
                    if (stats.nodes_written >= self.config.target_nodes) break;
                    try formatter.writeHost(host);
                    if (self.config.show_progress) progress.maybeReport();
                }
                base_network +%= prefix.getSize();
            }
            if (stats.nodes_written >= self.config.target_nodes) break;
        }
    }

    fn generateJson(
        self: *Generator,
        file: std.fs.File,
        stats: *output.OutputStats,
        progress: *output.ProgressReporter,
    ) !void {
        var formatter = output.JsonFormatter.init(file, stats);
        try formatter.writeHeader();

        var base_network: u32 = self.getShardBaseNetwork();
        var asn_iter = topology.ASNIterator.init(&self.topology_seeder, self.config.asn_count);

        while (asn_iter.next()) |asn| {
            var prefix_iter = topology.PrefixIterator.init(&self.topology_seeder, asn, base_network);
            while (prefix_iter.next()) |prefix| {
                var host_iter = hosts.SubnetHostIterator.init(&self.host_expander, prefix, self.config.host_density);
                while (host_iter.next()) |host| {
                    if (stats.nodes_written >= self.config.target_nodes) break;
                    try formatter.writeHost(host);
                    if (self.config.show_progress) progress.maybeReport();
                }
                base_network +%= prefix.getSize();
            }
            if (stats.nodes_written >= self.config.target_nodes) break;
        }

        try formatter.writeFooter();
    }

    fn getShardBaseNetwork(self: *Generator) u32 {
        if (self.config.total_shards <= 1) return 0x0A000000; // 10.0.0.0

        // Divide address space among shards
        const shard_size = 0xFFFFFFFF / self.config.total_shards;
        return self.config.shard_id * shard_size;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var config = Config{};
    _ = &config; // Mark as potentially mutated

    // Skip program name
    _ = args.skip();

    // Parse arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--nodes") or std.mem.eql(u8, arg, "-n")) {
            if (args.next()) |val| {
                config.target_nodes = try std.fmt.parseInt(u64, val, 10);
            }
        } else if (std.mem.eql(u8, arg, "--edges") or std.mem.eql(u8, arg, "-e")) {
            if (args.next()) |val| {
                config.target_edges = try std.fmt.parseInt(u64, val, 10);
            }
        } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
            if (args.next()) |val| {
                config.format = std.meta.stringToEnum(output.OutputFormat, val) orelse .gql;
            }
        } else if (std.mem.eql(u8, arg, "--seed") or std.mem.eql(u8, arg, "-s")) {
            if (args.next()) |val| {
                config.seed = try std.fmt.parseInt(u64, val, 10);
            }
        } else if (std.mem.eql(u8, arg, "--shard")) {
            if (args.next()) |val| {
                config.shard_id = try std.fmt.parseInt(u32, val, 10);
            }
        } else if (std.mem.eql(u8, arg, "--total-shards")) {
            if (args.next()) |val| {
                config.total_shards = try std.fmt.parseInt(u32, val, 10);
            }
        } else if (std.mem.eql(u8, arg, "--asns")) {
            if (args.next()) |val| {
                config.asn_count = try std.fmt.parseInt(u32, val, 10);
            }
        } else if (std.mem.eql(u8, arg, "--density")) {
            if (args.next()) |val| {
                config.host_density = try std.fmt.parseFloat(f32, val);
            }
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            config.output_path = args.next();
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            config.show_progress = false;
        } else if (std.mem.eql(u8, arg, "--pattern") or std.mem.eql(u8, arg, "-p")) {
            if (args.next()) |val| {
                config.traffic_pattern = std.meta.stringToEnum(connections.TrafficPattern, val) orelse .web_traffic;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            return;
        }
    }

    var gen = Generator.init(allocator, config);
    _ = &gen; // Mark as potentially mutated
    try gen.run();
}

fn printHelp() !void {
    const help =
        \\Geode Load Test Data Generator
        \\
        \\Usage: geode-loadgen [OPTIONS]
        \\
        \\Options:
        \\  -n, --nodes <N>       Target number of nodes (default: 1000000)
        \\  -e, --edges <N>       Target number of edges (default: 10000000)
        \\  -f, --format <FMT>    Output format: gql, csv, binary, json (default: gql)
        \\  -s, --seed <N>        Random seed for deterministic generation
        \\  -o, --output <PATH>   Output file (default: stdout)
        \\  -p, --pattern <PAT>   Traffic pattern: web_traffic, enterprise, p2p, scan, botnet
        \\  -q, --quiet           Suppress progress output
        \\      --shard <N>       Shard ID for distributed generation
        \\      --total-shards <N> Total number of shards
        \\      --asns <N>        Number of ASNs to generate
        \\      --density <F>     Host density (0.0-1.0, default: 0.1)
        \\  -h, --help            Show this help
        \\
        \\Examples:
        \\  # Generate 1M nodes to stdout
        \\  geode-loadgen -n 1000000 -f gql
        \\
        \\  # Generate with specific seed for reproducibility
        \\  geode-loadgen -n 10000 -s 42 -o data.gql
        \\
        \\  # Sharded generation for distributed loading
        \\  geode-loadgen -n 1000000000 --shard 0 --total-shards 10 -o shard-0.bin
        \\
    ;
    const stdout_file = getStdOut();
    try stdout_file.writeAll(help);
}

test "Generator creates valid output" {
    const allocator = std.testing.allocator;
    const config = Config{
        .target_nodes = 10,
        .target_edges = 5,
        .asn_count = 2,
        .show_progress = false,
    };

    const gen = Generator.init(allocator, config);
    _ = gen;
    // Would need file mock for full test
}
