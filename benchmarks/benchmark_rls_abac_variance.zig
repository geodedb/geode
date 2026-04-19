const std = @import("std");
const rls_tests = @import("tests/canary_rls_abac.zig");

// RLS/ABAC enforcement latency variance benchmark
// Measures latency variability of repeated enforcement calls over mixed allowed/denied predicates.
// We reuse simple policy objects from test module (import side-effects acceptable for benchmark scope).
//
// Deterministic data generation: alternating labels/attrs, with allowed ratio ~0.5.
// Compute mean, p95, coefficient of variation (cv), and trimmed cv (5% each tail).
// Threshold target (General): cv<=0.35, p95/mean<=3.0 (initial non-enforced unless RLS_ABAC_ENFORCE=1).
//
// CANARY: REQ=REQ-GQL-080; FEATURE="RlsAbac"; ASPECT=VarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_080_RlsAbacVarianceEnvelope; OWNER=security; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-080; FEATURE="RlsAbac"; ASPECT=TailLatencyP999Envelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_080_RlsAbacTailP999; OWNER=security; UPDATED=2025-09-26

// Zig 0.16 compat: std.time.nanoTimestamp removed; use clock_gettime(MONOTONIC).
fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

const Policy = rls_tests.Policy;

fn buildPolicies(allocator: std.mem.Allocator) ![]Policy {
    var pols = try allocator.alloc(Policy, 2);
    pols[0] = .{ .id = "p1", .expr = "label=Person;attr=region:eu" };
    pols[1] = .{ .id = "p2", .expr = "label=Account;attr=tier:gold" };
    return pols;
}

fn enforce(policies: []const Policy, label: []const u8, attr: []const u8) bool {
    var buf: [128]u8 = undefined;
    const needed = std.fmt.bufPrint(&buf, "label={s};attr={s}", .{ label, attr }) catch return false;
    for (policies) |p| if (std.mem.eql(u8, p.expr, needed)) return true;
    return false;
}

const Metrics = struct { iterations: usize, mean_ns: f128, p95_ns: u64, p999_ns: u64, cv: f128, trim_cv: f128, p95_mean_ratio: f128, p999_mean_ratio: f128 };

fn sample(allocator: std.mem.Allocator, policies: []const Policy, iterations: usize) ![]u64 {
    var times = try allocator.alloc(u64, iterations);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const label = if (i % 2 == 0) "Person" else "Account";
        const attr = if (i % 4 == 0) "region:eu" else if (i % 4 == 1) "region:us" else if (i % 4 == 2) "tier:gold" else "tier:silver";
        const start = nowNs();
        _ = enforce(policies, label, attr);
        const end = nowNs();
        times[i] = end - start;
    }
    return times;
}

fn computeMetrics(samples: []u64) Metrics {
    std.sort.heap(u64, samples, {}, comptime struct {
        fn lt(_: void, a: u64, b: u64) bool {
            return a < b;
        }
    }.lt);
    var sum: u128 = 0;
    for (samples) |s| sum += s;
    const mean_f = @as(f128, @floatFromInt(sum)) / @as(f128, @floatFromInt(samples.len));
    var diff: f128 = 0;
    for (samples) |s| {
        const sf = @as(f128, @floatFromInt(s));
        const d = sf - mean_f;
        diff += d * d;
    }
    const variance = diff / @as(f128, @floatFromInt(samples.len));
    const stdev = std.math.sqrt(variance);
    const cv = stdev / mean_f;
    const p95_idx = (samples.len * 95) / 100;
    const p999_idx = (samples.len * 999) / 1000;
    const p95 = samples[if (p95_idx == 0) 0 else p95_idx - 1];
    const p999 = samples[if (p999_idx == 0) 0 else p999_idx - 1];
    const p95_mean_ratio = @as(f128, @floatFromInt(p95)) / mean_f;
    const p999_mean_ratio = @as(f128, @floatFromInt(p999)) / mean_f;

    const trim_each = samples.len * 5 / 100;
    const start = trim_each;
    const end = samples.len - trim_each;
    var trim_sum: u128 = 0;
    var trim_count: usize = 0;
    var i: usize = start;
    while (i < end) : (i += 1) {
        trim_sum += samples[i];
        trim_count += 1;
    }
    const trim_mean = @as(f128, @floatFromInt(trim_sum)) / @as(f128, @floatFromInt(trim_count));
    var trim_diff: f128 = 0;
    i = start;
    while (i < end) : (i += 1) {
        const sf = @as(f128, @floatFromInt(samples[i]));
        const d = sf - trim_mean;
        trim_diff += d * d;
    }
    const trim_var = trim_diff / @as(f128, @floatFromInt(trim_count));
    const trim_std = std.math.sqrt(trim_var);
    const trim_cv = trim_std / trim_mean;

    return Metrics{ .iterations = samples.len, .mean_ns = mean_f, .p95_ns = p95, .p999_ns = p999, .cv = cv, .trim_cv = trim_cv, .p95_mean_ratio = p95_mean_ratio, .p999_mean_ratio = p999_mean_ratio };
}

pub fn runRlsAbacVariance() !void {
    // Zig 0.16 compat: GeneralPurposeAllocator renamed to DebugAllocator.
    var dbg_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg_alloc.deinit();
    const allocator: std.mem.Allocator = if (@import("builtin").mode == .Debug)
        dbg_alloc.allocator()
    else
        std.heap.smp_allocator;
    const policies = try buildPolicies(allocator);
    defer allocator.free(policies);
    const iterations: usize = 4000;
    const samples = try sample(allocator, policies, iterations);
    defer allocator.free(samples);
    const m = computeMetrics(samples);
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    try w.writeAll("{\"bench\":\"BenchmarkCANARY_REQ_GQL_080_RlsAbacVarianceEnvelope\",");
    try w.print("\"iterations\":{},", .{m.iterations});
    try w.print("\"mean_ns\":{d},", .{m.mean_ns});
    try w.print("\"p95_ns\":{},", .{m.p95_ns});
    try w.print("\"p999_ns\":{},", .{m.p999_ns});
    try w.print("\"p95_mean_ratio\":{d:.4},", .{m.p95_mean_ratio});
    try w.print("\"cv\":{d:.6},", .{m.cv});
    try w.print("\"p999_mean_ratio\":{d:.4},", .{m.p999_mean_ratio});
    try w.print("\"trim_cv\":{d:.6}", .{m.trim_cv});
    try w.writeAll("}\n");
    const line = fbs.getWritten();
    _ = try std.posix.write(std.posix.STDOUT_FILENO, line);
    if (m.cv > 0.35 or m.p95_mean_ratio > 3.0) {
        if (std.posix.getenv("RLS_ABAC_ENFORCE")) |v| if (v.len > 0 and v[0] == '1') return error.RlsAbacVarianceEnvelopeBreached;
    }
}

pub fn main() !void {
    try runRlsAbacVariance();
}

test "BenchmarkCANARY_REQ_GQL_080_RlsAbacVarianceEnvelope_Run" {
    try runRlsAbacVariance();
}
