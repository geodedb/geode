const std = @import("std");
const geode = @import("geode");
const registry_mod = geode.multitenancy.registry;

// CANARY: REQ=REQ-GQL-050; FEATURE="Multi-Tenancy"; ASPECT=TenantRegistryVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_050_TenantRegistryVarianceEnvelope; OWNER=dist; UPDATED=2025-09-21

fn simulateTenantOps(iterations: usize, alloc: std.mem.Allocator) u64 {
    var reg = registry_mod.Registry.init(alloc);
    defer reg.deinit();
    var work: u64 = 0;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // Alternate create and get
        if ((i % 3) == 0) {
            const name = if ((i & 1) == 0) "alpha" else "beta";
            const info = reg.createTenant(name) catch continue; // ignore OOM transient
            _ = info;
            work +%= 50; // creation cost
        } else {
            const tid: registry_mod.TenantId = @intCast((i / 3) + 1);
            _ = reg.get(tid);
            work +%= 20; // get cost
        }
    }
    return work;
}

test "BenchmarkCANARY_REQ_GQL_050_TenantRegistryVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const Runs = 24;
    var samples: [Runs]u64 = undefined;
    var r: usize = 0;
    while (r < Runs) : (r += 1) {
        const start = std.time.nanoTimestamp();
        _ = simulateTenantOps(4_000, alloc);
        const end = std.time.nanoTimestamp();
        samples[r] = @intCast(end - start);
    }

    var sum: f128 = 0;
    for (samples) |s| sum += @as(f128, @floatFromInt(s));
    const mean = sum / @as(f128, samples.len);
    var var_acc: f128 = 0;
    for (samples) |s| {
        const dv = @as(f128, @floatFromInt(s)) - mean;
        var_acc += dv * dv;
    }
    const stddev = std.math.sqrt(var_acc / @as(f128, samples.len));
    const cv = stddev / mean;
    var sorted: [Runs]u64 = undefined;
    for (samples, 0..) |s, i| sorted[i] = s;
    std.sort.heap(u64, &sorted, {}, comptime std.sort.asc(u64));
    const p95 = sorted[@min(sorted.len - 1, (sorted.len * 95) / 100)];

    // Tenant registry basic ops quite stable: CV < 0.16, p95 < 2.2x mean
    try std.testing.expect(cv < 0.16);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 2.2);

    const stderr = std.io.getStdErr().writer();
    try stderr.print("{\"benchmark\":\"tenant_registry_variance\",\"mean_ns\":{d},\"cv\":{d:.4},\"p95_ns\":{d}}\n", .{ @as(u64, @intFromFloat(mean)), cv, p95 });
}
