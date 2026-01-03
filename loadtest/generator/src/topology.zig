// CANARY: REQ=REQ-LOADTEST-GENERATOR-001; FEATURE="StreamingDataGenerator"; ASPECT=Topology; STATUS=IMPL; OWNER=tooling; UPDATED=2026-01-03
//! Network Topology Generator
//! Generates hierarchical network structures with realistic ASN and prefix distributions

const std = @import("std");

/// Autonomous System Number with tier classification
pub const ASN = struct {
    number: u32,
    tier: Tier,
    name: []const u8,
    prefix_count: u16,

    pub const Tier = enum(u2) {
        tier1 = 1, // ~20 backbone providers
        tier2 = 2, // ~5000 regional ISPs
        tier3 = 3, // ~95000 access networks
    };

    pub fn format(self: ASN, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("AS{d}", .{self.number});
    }
};

/// IP prefix/subnet
pub const Prefix = struct {
    network: u32, // Network address as integer
    mask: u8, // CIDR mask (8-32)
    asn: u32,

    pub fn getSize(self: Prefix) u32 {
        return @as(u32, 1) << @intCast(32 - self.mask);
    }

    pub fn contains(self: Prefix, ip: u32) bool {
        const mask_bits = if (self.mask == 0) 0 else ~((@as(u32, 1) << @intCast(32 - self.mask)) - 1);
        return (ip & mask_bits) == self.network;
    }

    pub fn toStr(self: Prefix, buf: []u8) []const u8 {
        const a = @as(u8, @truncate(self.network >> 24));
        const b = @as(u8, @truncate(self.network >> 16));
        const c = @as(u8, @truncate(self.network >> 8));
        const d = @as(u8, @truncate(self.network));
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}/{d}", .{ a, b, c, d, self.mask }) catch buf[0..0];
    }
};

/// Peering relationship between ASNs
pub const Peering = struct {
    asn1: u32,
    asn2: u32,
    relationship: Relationship,

    pub const Relationship = enum {
        peer, // Equal peering
        customer, // asn1 is customer of asn2
        provider, // asn1 is provider to asn2
    };
};

/// Power-law distribution for realistic network topology
pub const PowerLawDistribution = struct {
    alpha: f64,
    x_min: f64,

    pub fn init(alpha: f64, x_min: f64) PowerLawDistribution {
        return .{ .alpha = alpha, .x_min = x_min };
    }

    pub fn sample(self: PowerLawDistribution, rng: std.Random) f64 {
        const u = rng.float(f64);
        return self.x_min * std.math.pow(f64, 1.0 - u, -1.0 / (self.alpha - 1.0));
    }
};

/// Log-normal distribution for prefix sizes
pub const LogNormalDistribution = struct {
    mu: f64,
    sigma: f64,

    pub fn init(mu: f64, sigma: f64) LogNormalDistribution {
        return .{ .mu = mu, .sigma = sigma };
    }

    pub fn sample(self: LogNormalDistribution, rng: std.Random) f64 {
        // Box-Muller transform for normal distribution
        const r1 = rng.float(f64);
        const r2 = rng.float(f64);
        const z = @sqrt(-2.0 * @log(r1)) * @cos(2.0 * std.math.pi * r2);
        return @exp(self.mu + self.sigma * z);
    }
};

/// Topology seeder - generates hierarchical network structure
pub const TopologySeeder = struct {
    rng: std.Random,
    asn_distribution: PowerLawDistribution,
    prefix_distribution: LogNormalDistribution,
    allocator: std.mem.Allocator,

    // Tier counts
    tier1_count: u32 = 20,
    tier2_count: u32 = 5000,
    tier3_count: u32 = 95000,

    pub fn init(allocator: std.mem.Allocator, seed: u64) TopologySeeder {
        var prng = std.Random.DefaultPrng.init(seed);
        return .{
            .rng = prng.random(),
            .asn_distribution = PowerLawDistribution.init(2.1, 1.0),
            .prefix_distribution = LogNormalDistribution.init(2.0, 0.5),
            .allocator = allocator,
        };
    }

    pub fn initWithRng(allocator: std.mem.Allocator, rng: std.Random) TopologySeeder {
        return .{
            .rng = rng,
            .asn_distribution = PowerLawDistribution.init(2.1, 1.0),
            .prefix_distribution = LogNormalDistribution.init(2.0, 0.5),
            .allocator = allocator,
        };
    }

    /// Generate ASNs with realistic tier distribution
    pub fn generateASN(self: *TopologySeeder, index: u32) ASN {
        const tier: ASN.Tier = if (index < self.tier1_count)
            .tier1
        else if (index < self.tier1_count + self.tier2_count)
            .tier2
        else
            .tier3;

        const prefix_count: u16 = switch (tier) {
            .tier1 => @intFromFloat(@min(1000.0, self.asn_distribution.sample(self.rng) * 100)),
            .tier2 => @intFromFloat(@min(100.0, self.asn_distribution.sample(self.rng) * 10)),
            .tier3 => @intFromFloat(@min(10.0, self.asn_distribution.sample(self.rng))),
        };

        return ASN{
            .number = 64512 + index, // Start from private ASN range for testing
            .tier = tier,
            .name = "", // Names generated separately if needed
            .prefix_count = @max(1, prefix_count),
        };
    }

    /// Generate peering relationships using Barabási-Albert model
    pub fn generatePeering(self: *TopologySeeder, asn1: ASN, asn2: ASN) ?Peering {
        // Tier 1s peer with each other
        if (asn1.tier == .tier1 and asn2.tier == .tier1) {
            return Peering{ .asn1 = asn1.number, .asn2 = asn2.number, .relationship = .peer };
        }

        // Tier 2s connect to Tier 1s as customers
        if (asn1.tier == .tier2 and asn2.tier == .tier1) {
            if (self.rng.float(f32) < 0.3) { // 30% chance of connection
                return Peering{ .asn1 = asn1.number, .asn2 = asn2.number, .relationship = .customer };
            }
        }

        // Tier 2s peer with each other regionally (low probability)
        if (asn1.tier == .tier2 and asn2.tier == .tier2) {
            if (self.rng.float(f32) < 0.01) {
                return Peering{ .asn1 = asn1.number, .asn2 = asn2.number, .relationship = .peer };
            }
        }

        // Tier 3s connect to Tier 2s as customers
        if (asn1.tier == .tier3 and asn2.tier == .tier2) {
            if (self.rng.float(f32) < 0.05) {
                return Peering{ .asn1 = asn1.number, .asn2 = asn2.number, .relationship = .customer };
            }
        }

        return null;
    }

    /// Generate prefix for an ASN
    pub fn generatePrefix(self: *TopologySeeder, asn: ASN, prefix_index: u16, base_network: u32) Prefix {
        // Realistic prefix sizes based on tier
        const mask: u8 = switch (asn.tier) {
            .tier1 => @intFromFloat(@min(16.0, @max(8.0, 8.0 + self.prefix_distribution.sample(self.rng)))),
            .tier2 => @intFromFloat(@min(22.0, @max(16.0, 16.0 + self.prefix_distribution.sample(self.rng)))),
            .tier3 => @intFromFloat(@min(28.0, @max(22.0, 22.0 + self.prefix_distribution.sample(self.rng)))),
        };

        // Calculate network address offset
        const offset = @as(u32, prefix_index) * (@as(u32, 1) << @intCast(32 - mask));
        const network = base_network +% offset;

        return Prefix{
            .network = network & (~((@as(u32, 1) << @intCast(32 - mask)) - 1)),
            .mask = mask,
            .asn = asn.number,
        };
    }

    /// Get total ASN count
    pub fn getTotalASNCount(self: *const TopologySeeder) u32 {
        return self.tier1_count + self.tier2_count + self.tier3_count;
    }
};

/// Iterator for generating ASNs
pub const ASNIterator = struct {
    seeder: *TopologySeeder,
    current: u32,
    total: u32,

    pub fn init(seeder: *TopologySeeder, count: u32) ASNIterator {
        return .{
            .seeder = seeder,
            .current = 0,
            .total = count,
        };
    }

    pub fn next(self: *ASNIterator) ?ASN {
        if (self.current >= self.total) return null;
        const asn = self.seeder.generateASN(self.current);
        self.current += 1;
        return asn;
    }
};

/// Iterator for generating prefixes for an ASN
pub const PrefixIterator = struct {
    seeder: *TopologySeeder,
    asn: ASN,
    current: u16,
    base_network: u32,

    pub fn init(seeder: *TopologySeeder, asn: ASN, base_network: u32) PrefixIterator {
        return .{
            .seeder = seeder,
            .asn = asn,
            .current = 0,
            .base_network = base_network,
        };
    }

    pub fn next(self: *PrefixIterator) ?Prefix {
        if (self.current >= self.asn.prefix_count) return null;
        const prefix = self.seeder.generatePrefix(self.asn, self.current, self.base_network);
        self.current += 1;
        return prefix;
    }
};

test "TopologySeeder generates valid ASNs" {
    var seeder = TopologySeeder.init(std.testing.allocator, 12345);

    const asn0 = seeder.generateASN(0);
    try std.testing.expect(asn0.tier == .tier1);

    const asn100 = seeder.generateASN(100);
    try std.testing.expect(asn100.tier == .tier2);

    const asn10000 = seeder.generateASN(10000);
    try std.testing.expect(asn10000.tier == .tier3);
}

test "Prefix contains IP correctly" {
    const prefix = Prefix{ .network = 0x0A000000, .mask = 8, .asn = 64512 }; // 10.0.0.0/8
    try std.testing.expect(prefix.contains(0x0A010203)); // 10.1.2.3
    try std.testing.expect(!prefix.contains(0x0B000000)); // 11.0.0.0
}
