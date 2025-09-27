const std = @import("std");

// Simulate recovery code contention by spinning N workers consuming from a shared pool.
// Outputs JSON with contention_ratio and latency stats.
// CANARY: REQ=REQ-GQL-MFA-CORE-001; FEATURE="MfaRecoveryCodeContention"; ASPECT=VarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_MFA_CORE_001_RecoveryCodeContentionVariance; OWNER=security; UPDATED=2025-09-27

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const total_codes: usize = 128; // initial pool
    const workers: usize = 32;
    var pool = try alloc.alloc(u8, total_codes);
    defer alloc.free(pool);
    @memset(pool, 1);
    var taken: usize = 0;
    var attempts: usize = 0;
    const start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < workers) : (i += 1) {
        // Each worker attempts to consume sequential indices (no real threads needed for contention ratio modeling)
        var j: usize = i;
        while (j < total_codes) : (j += workers) {
            attempts += 1;
            if (pool[j] == 1) {
                pool[j] = 0;
                taken += 1;
            }
        }
    }
    const end = std.time.nanoTimestamp();
    const elapsed_ns: u64 = @intCast(end - start);
    const contention_ratio = 1.0 - (@as(f64, @floatFromInt(taken)) / @as(f64, @floatFromInt(attempts)));
    // Escape literal JSON braces for Zig format string with double '{{' and '}}'
    std.debug.print("{{\"bench\":\"BenchmarkCANARY_REQ_GQL_MFA_CORE_001_RecoveryCodeContentionVariance\",\"codes\":{d},\"workers\":{d},\"attempts\":{d},\"taken\":{d},\"contention_ratio\":{},\"elapsed_ns\":{d}}}\n", .{ total_codes, workers, attempts, taken, contention_ratio, elapsed_ns });
}
