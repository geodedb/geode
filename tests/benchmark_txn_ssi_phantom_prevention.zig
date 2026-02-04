const std = @import("std");
const txn_mod = @import("txn");

// CANARY: REQ=REQ-GQL-013; FEATURE="Transactions"; ASPECT=SSIPhantomPreventionVariance; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_013_SSIPhantomPrevention; OWNER=txn; UPDATED=2025-09-21

fn Stats(comptime N: usize) type {
    return struct { samples: [N]u64 = undefined, i: usize = 0 };
}

test "BenchmarkCANARY_REQ_GQL_013_SSIPhantomPrevention" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var rnd = std.rand.DefaultPrng.init(0xdeadbeef);
    const r = rnd.random();

    var manager = try txn_mod.Manager.init(allocator, .{});
    defer manager.deinit();

    var keys = std.ArrayList([]const u8).init(allocator);
    defer keys.deinit();
    try keys.append("acct:1");
    try keys.append("acct:2");

    var st = Stats(64){};
    var iter: usize = 0;
    while (iter < st.samples.len) : (iter += 1) {
        // Randomly add noise keys non-matching to simulate workload
        const noise_n = r.intRangeAtMost(u8, 0, 4);
        var n: u8 = 0;
        while (n < noise_n) : (n += 1) {
            const val = try std.fmt.allocPrint(allocator, "noise:{d}:{d}", .{ iter, n });
            defer allocator.free(val);
            try keys.append(val);
        }

        var t1 = manager.begin();
        var t2 = manager.begin();
        // Time predicate scan + phantom insertion commit + re-scan
        const start = std.time.nanoTimestamp();
        var count_initial: usize = 0;
        for (keys.items) |k| {
            if (std.mem.startsWith(u8, k, "acct:")) count_initial += 1;
        }
        const new_key = try std.fmt.allocPrint(allocator, "acct:new:{d}", .{iter});
        defer allocator.free(new_key);
        try keys.append(new_key);
        try manager.commit(&t2);
        var count_rescan: usize = 0;
        for (keys.items) |k| {
            if (std.mem.startsWith(u8, k, "acct:")) count_rescan += 1;
        }
        // Expect snapshot semantics (logical) => unchanged count
        if (count_initial != count_rescan) return error.PhotonCountChanged; // force failure path
        try manager.commit(&t1);
        const end = std.time.nanoTimestamp();
        st.samples[iter] = @as(u64, @intCast(end - start));
    }

    // Compute mean & p95
    var sum: f128 = 0;
    for (st.samples) |v| sum += @as(f128, @floatFromInt(v));
    const mean = sum / @as(f128, st.samples.len);
    // variance
    var var_sum: f128 = 0;
    for (st.samples) |v| {
        const dv = @as(f128, @floatFromInt(v)) - mean;
        var_sum += dv * dv;
    }
    const stddev = std.math.sqrt(var_sum / @as(f128, st.samples.len));
    const cv = stddev / mean;

    // p95 using partial selection (copy & sort small array) for simplicity
    var tmp: [st.samples.len]u64 = undefined;
    for (st.samples, 0..) |v, i| tmp[i] = v;
    std.sort.heap(u64, &tmp, {}, comptime std.sort.asc(u64));
    const p95 = tmp[@min(tmp.len - 1, (tmp.len * 95) / 100)];

    // Basic variance guard (placeholder threshold) CV should be < 0.35 and p95 < 5x mean
    try std.testing.expect(cv < 0.35);
    try std.testing.expect(@as(f128, @floatFromInt(p95)) < mean * 5.0);

    const stderr = std.io.getStdErr().writer();
    try stderr.print("{s}\n", .{try std.fmt.allocPrint(allocator", "{\"benchmark\":\"txn_ssi_phantom_prevention\",\"mean_ns\":{d},\"cv\":{d:.3},\"p95_ns\":{d}}", .{ @as(u64, @intFromFloat(mean)), cv, p95 })});
}
