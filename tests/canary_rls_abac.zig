const std = @import("std");
const testing = std.testing;
const bo = @import("build_options");

// Placeholder minimal policy structures (mirroring expected future interfaces). For now we simulate catalog + cache behavior.

pub const Policy = struct {
    id: []const u8,
    expr: []const u8, // simple allow expression pattern (node_label=... AND attr=...)
};

const PolicyCatalog = struct {
    allocator: std.mem.Allocator,
    policies: std.StringHashMap(Policy),

    fn init(a: std.mem.Allocator) PolicyCatalog {
        return .{ .allocator = a, .policies = std.StringHashMap(Policy).init(a) };
    }
    fn deinit(self: *PolicyCatalog) void {
        self.policies.deinit();
    }
    fn add(self: *PolicyCatalog, p: Policy) !void {
        try self.policies.put(p.id, p);
    }
    fn get(self: *PolicyCatalog, id: []const u8) ?Policy {
        return self.policies.get(id);
    }
};

const PolicyCache = struct {
    allocator: std.mem.Allocator,
    hits: usize = 0,
    misses: usize = 0,
    store: std.StringHashMap(Policy),
    fn init(a: std.mem.Allocator) PolicyCache {
        return .{ .allocator = a, .store = std.StringHashMap(Policy).init(a) };
    }
    fn deinit(self: *PolicyCache) void {
        self.store.deinit();
    }
    fn getOrLoad(self: *PolicyCache, catalog: *PolicyCatalog, id: []const u8) ?Policy {
        if (self.store.get(id)) |p| {
            self.hits += 1;
            return p;
        }
        if (catalog.get(id)) |p| {
            self.misses += 1;
            self.store.put(id, p) catch return null;
            return p;
        }
        self.misses += 1;
        return null;
    }
};

fn enforce(policies: []const Policy, label: []const u8, attr: []const u8) bool {
    // Very naive: allow if any policy expr exactly matches pattern label=...;attr=...
    var buf: [128]u8 = undefined;
    const needed = std.fmt.bufPrint(&buf, "label={s};attr={s}", .{ label, attr }) catch return false;
    for (policies) |p| if (std.mem.eql(u8, p.expr, needed)) return true;
    return false;
}

pub fn TestCANARY_REQ_GQL_080_PolicyCatalog() !void {
    if (!bo.feature_rls_abac) return;
    var catalog = PolicyCatalog.init(testing.allocator);
    defer catalog.deinit();
    try catalog.add(.{ .id = "p1", .expr = "label=Person;attr=region:eu" });
    try catalog.add(.{ .id = "p2", .expr = "label=Account;attr=tier:gold" });
    try testing.expect(catalog.get("p1") != null);
    try testing.expect(catalog.get("missing") == null);
}

pub fn TestCANARY_REQ_GQL_080_EnforcementHook() !void {
    if (!bo.feature_rls_abac) return;
    const pols = [_]Policy{
        .{ .id = "p1", .expr = "label=Person;attr=region:eu" },
        .{ .id = "p2", .expr = "label=Account;attr=tier:gold" },
    };
    try testing.expect(enforce(&pols, "Person", "region:eu"));
    try testing.expect(!enforce(&pols, "Person", "region:us"));
    try testing.expect(enforce(&pols, "Account", "tier:gold"));
}

pub fn TestCANARY_REQ_GQL_080_PolicyCache() !void {
    if (!bo.feature_rls_abac) return;
    var catalog = PolicyCatalog.init(testing.allocator);
    defer catalog.deinit();
    try catalog.add(.{ .id = "p1", .expr = "label=Person;attr=region:eu" });
    var cache = PolicyCache.init(testing.allocator);
    defer cache.deinit();
    const p_first = cache.getOrLoad(&catalog, "p1") orelse return error.TestExpectedFound;
    _ = p_first;
    const p_second = cache.getOrLoad(&catalog, "p1") orelse return error.TestExpectedFound;
    _ = p_second;
    try testing.expectEqual(@as(usize, 1), cache.hits);
    try testing.expectEqual(@as(usize, 1), cache.misses); // first load miss, second hit
}
