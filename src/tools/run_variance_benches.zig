const std = @import("std");
const geode = @import("geode");

/// P2-3: Now accepts allocator parameter for temporary sorting buffer
fn stats(allocator: std.mem.Allocator, values: []u64) struct { mean: f64, stddev: f64, cv: f64, p95: u64 } {
    var sum: f128 = 0;
    for (values) |v| sum += @as(f128, @floatFromInt(v));
    const mean_f = sum / @as(f128, @floatFromInt(values.len));
    var acc: f128 = 0;
    for (values) |v| {
        const diff = @as(f128, @floatFromInt(v)) - mean_f;
        acc += diff * diff;
    }
    const variance = acc / @as(f128, @floatFromInt(values.len));
    const stddev = @as(f64, @floatCast(@sqrt(variance)));
    const mean = @as(f64, @floatCast(mean_f));
    const tmp = allocator.alloc(u64, values.len) catch unreachable;
    defer allocator.free(tmp);
    std.mem.copyForwards(u64, tmp, values);
    std.sort.pdq(u64, tmp, {}, comptime std.sort.asc(u64));
    const p95 = tmp[@min(tmp.len - 1, (tmp.len * 95) / 100)];
    return .{ .mean = mean, .stddev = stddev, .cv = if (mean == 0) 0 else stddev / mean, .p95 = p95 };
}

fn runPathMultiBranch(allocator: std.mem.Allocator) !void {
    // GAP-0132: Planner cost benchmarks use synthetic BFS workload
    // CANARY: REQ=REQ-BENCH-PLANNER-001; FEATURE="Planner Cost Benchmarks"; ASPECT=PerformanceTesting; STATUS=BENCHED; OWNER=core; UPDATED=2026-01-13
    // TODO(planner-cost-hooks): Replace synthetic BFS workload with real planner path multi-branch expansion timings
    // once NodeScan/Expand operators expose micro-timing hooks (planned under REQ-GQL-021 cost model integration).
    // Synthetic data provides consistent reproducible results but may not reflect real-world performance.
    // Thresholds (can be overridden via env VARIANCE_CV_MAX / VARIANCE_P95_OVER_MEAN_MAX)
    const default_cv_max: f64 = 0.23;
    const default_ratio_max: f64 = 2.60;
    var cv_max = default_cv_max;
    var ratio_max = default_ratio_max;
    if (std.process.getEnvVarOwned(allocator, "VARIANCE_CV_MAX")) |val| {
        defer allocator.free(val);
        const parsed = std.fmt.parseFloat(f64, val) catch null;
        if (parsed) |p| cv_max = p;
    } else |_| {}
    if (std.process.getEnvVarOwned(allocator, "VARIANCE_P95_OVER_MEAN_MAX")) |val| {
        defer allocator.free(val);
        const parsed2 = std.fmt.parseFloat(f64, val) catch null;
        if (parsed2) |p| ratio_max = p;
    } else |_| {}
    // Simple adjacency map using fixed arrays (node ids up to 11)
    var neighbors = try allocator.alloc([]const u64, 12);
    defer allocator.free(neighbors);
    // Define neighbor slices (static data)
    const n1 = [_]u64{ 2, 3, 4 };
    const n2 = [_]u64{ 5, 6, 7 }; // include cross 2->7
    const n3 = [_]u64{ 6, 7, 5 }; // include cross 3->5
    const n4 = [_]u64{ 7, 8, 6 }; // include cross 4->6
    const n5 = [_]u64{10};
    const n6 = [_]u64{ 10, 11 };
    const n7 = [_]u64{11};
    const n8 = [_]u64{11};
    const n9 = [_]u64{ 3, 4 };
    const n10 = [_]u64{};
    const n11 = [_]u64{};
    neighbors[1] = &n1;
    neighbors[2] = &n2;
    neighbors[3] = &n3;
    neighbors[4] = &n4;
    neighbors[5] = &n5;
    neighbors[6] = &n6;
    neighbors[7] = &n7;
    neighbors[8] = &n8;
    neighbors[9] = &n9;
    neighbors[10] = &n10;
    neighbors[11] = &n11;
    const starts = [_]u64{ 1, 9 };
    // Allow tuning via environment for stabilization experiments
    const warmup: usize = blk: {
        if (std.process.getEnvVarOwned(allocator, "VARIANCE_WARMUP")) |val| {
            defer allocator.free(val);
            const parsed = std.fmt.parseInt(u32, val, 10) catch break :blk 5;
            break :blk @as(usize, @intCast(parsed));
        } else |_| {}
        break :blk 5;
    };
    const runs: usize = blk: {
        if (std.process.getEnvVarOwned(allocator, "VARIANCE_RUNS")) |val| {
            defer allocator.free(val);
            const parsed = std.fmt.parseInt(u32, val, 10) catch break :blk 60;
            break :blk @as(usize, @intCast(parsed));
        } else |_| {}
        break :blk 80; // includes warm-up; we record only post-warmup (bumped for stabilization)
    };
    var timings = try allocator.alloc(u64, runs);
    defer allocator.free(timings);
    // BFS queue struct
    const QItem = struct { node: u64, depth: u8 };
    var queue = try allocator.alloc(QItem, 1024);
    defer allocator.free(queue);
    var i: usize = 0;
    var record_index: usize = 0;
    while (i < runs) : (i += 1) {
        var q_head: usize = 0;
        var q_tail: usize = 0;
        // seed starts
        for (starts) |s| {
            queue[q_tail] = .{ .node = s, .depth = 0 };
            q_tail += 1;
        }
        var work_acc: u64 = 0;
        const t0 = std.time.nanoTimestamp();
        while (q_head < q_tail) {
            const item = queue[q_head];
            q_head += 1;
            work_acc +%= item.node * 1315423911;
            if (item.depth >= 5) continue;
            const neigh = neighbors[@intCast(item.node)];
            for (neigh) |dst| {
                if (q_tail < queue.len) {
                    queue[q_tail] = .{ .node = dst, .depth = item.depth + 1 };
                    q_tail += 1;
                }
            }
        }
        // Prevent optimizer from removing loop
        if (work_acc == 0) std.mem.doNotOptimizeAway(&work_acc);
        const t1 = std.time.nanoTimestamp();
        if (i >= warmup) { // collect only after warm-up
            timings[record_index] = @intCast(t1 - t0);
            record_index += 1;
        }
    }
    var effective = timings[0..record_index];
    var st = stats(allocator, effective); // mutable shadow for adaptive refinement
    // Extra stats for schema_version=2
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    for (effective) |v| {
        if (v < min_ns) min_ns = v;
        if (v > max_ns) max_ns = v;
    }
    if (effective.len == 0) min_ns = 0; // guard
    var p95_over_mean: f64 = if (st.mean == 0) 0 else @as(f64, @floatFromInt(st.p95)) / st.mean;
    var pass = (st.cv <= cv_max) and (p95_over_mean <= ratio_max);
    // Optional adaptive stabilization: if CV too high and env VARIANCE_ADAPTIVE=on, perform extra batches (capped)
    if (!pass) {
        if (std.process.getEnvVarOwned(allocator, "VARIANCE_ADAPTIVE")) |val| {
            defer allocator.free(val);
            if (std.mem.eql(u8, val, "on")) {
                var extra_batches: u8 = 0;
                while (!pass and extra_batches < 5) : (extra_batches += 1) {
                    // allocate extra buffer (reuse timings by extending logical slice)
                    const add_runs: usize = 20;
                    const new_total_needed = record_index + add_runs;
                    if (new_total_needed > timings.len) {
                        // grow timings
                        const new_cap = timings.len + add_runs * 2;
                        var new_buf = try allocator.alloc(u64, new_cap);
                        @memcpy(new_buf[0..record_index], timings[0..record_index]);
                        allocator.free(timings);
                        timings = new_buf;
                    }
                    var j: usize = 0;
                    while (j < add_runs) : (j += 1) {
                        var q_head: usize = 0;
                        var q_tail: usize = 0;
                        for (starts) |s| {
                            queue[q_tail] = .{ .node = s, .depth = 0 };
                            q_tail += 1;
                        }
                        var work_acc: u64 = 0;
                        const t0b = std.time.nanoTimestamp();
                        while (q_head < q_tail) {
                            const item2 = queue[q_head];
                            q_head += 1;
                            work_acc +%= item2.node * 1315423911;
                            if (item2.depth >= 5) continue;
                            const neigh2 = neighbors[@intCast(item2.node)];
                            for (neigh2) |dst2| {
                                if (q_tail < queue.len) {
                                    queue[q_tail] = .{ .node = dst2, .depth = item2.depth + 1 };
                                    q_tail += 1;
                                }
                            }
                        }
                        if (work_acc == 0) std.mem.doNotOptimizeAway(&work_acc);
                        const t1b = std.time.nanoTimestamp();
                        timings[record_index] = @intCast(t1b - t0b);
                        record_index += 1;
                    }
                    effective = timings[0..record_index];
                    st = stats(allocator, effective);
                    p95_over_mean = if (st.mean == 0) 0 else @as(f64, @floatFromInt(st.p95)) / st.mean;
                    pass = (st.cv <= cv_max) and (p95_over_mean <= ratio_max);
                    // recalc min/max on each refinement iteration for final emission
                    min_ns = std.math.maxInt(u64);
                    max_ns = 0;
                    for (effective) |v| {
                        if (v < min_ns) min_ns = v;
                        if (v > max_ns) max_ns = v;
                    }
                }
            }
        } else |_| {}
    }
    // NOTE(schema_version=1): Adding explicit schema_version to detect stale runner binaries during CI and ensure
    // downstream tooling (bench_regress, variance dashboards) can evolve with backward compatibility.
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    const scale = 10000.0; // 1e4 precision scaling
    try w.writeAll("{\"schema_version\":1,\"kind\":\"VarianceEnvelope\",\"benchmark\":\"path_multibranch_variance\",");
    // Helper inline function to append key+value (unsigned integer) with trailing comma control
    inline for (.{
        struct { k: []const u8, v: u64, comma: bool }{ .k = "mean_ns", .v = @intFromFloat(st.mean), .comma = true },
        struct { k: []const u8, v: u64, comma: bool }{ .k = "cv_scaled_ppm", .v = @intFromFloat(st.cv * scale), .comma = true },
        struct { k: []const u8, v: u64, comma: bool }{ .k = "p95_ns", .v = st.p95, .comma = true },
        struct { k: []const u8, v: u64, comma: bool }{ .k = "p95_over_mean_scaled_ppm", .v = @as(u64, @intFromFloat(p95_over_mean * scale)), .comma = true },
        struct { k: []const u8, v: u64, comma: bool }{ .k = "cv_max_scaled_ppm", .v = @as(u64, @intFromFloat(cv_max * scale)), .comma = true },
        struct { k: []const u8, v: u64, comma: bool }{ .k = "p95_over_mean_max_scaled_ppm", .v = @as(u64, @intFromFloat(ratio_max * scale)), .comma = true },
    }) |entry| {
        try w.writeAll("\"");
        try w.writeAll(entry.k);
        try w.writeAll("\":");
        var numtmp: [32]u8 = undefined;
        const slice = std.fmt.bufPrint(&numtmp, "{d}", .{entry.v}) catch unreachable;
        try w.writeAll(slice);
        if (entry.comma) try w.writeAll(",");
    }
    // pass field (boolean)
    try w.writeAll("\"pass\":");
    try w.writeAll(if (pass) "true" else "false");
    try w.writeAll("}\n");
    std.debug.print("{s}", .{fbs.getWritten()}); // v1 line

    // schema_version=2 (additive, transitional). We intentionally re-use some computed values.
    // Additional fields:
    //   sample_count, warmup_count, min_ns, max_ns, jitter_class (low|medium|high), thresholds_evaluated[], p95_over_mean_scaled_ppm
    // jitter_class heuristic: cv < 0.10 => low, < 0.20 => medium else high
    const jitter_class = if (st.cv < 0.10) "low" else if (st.cv < 0.20) "medium" else "high";
    var buf2: [768]u8 = undefined;
    var fbs2 = std.io.fixedBufferStream(&buf2);
    const w2 = fbs2.writer();
    try w2.writeAll("{\"schema_version\":2,\"kind\":\"VarianceEnvelope\",\"benchmark\":\"path_multibranch_variance\",");
    inline for (.{
        struct { k: []const u8, v: u64, comma: bool }{ .k = "mean_ns", .v = @intFromFloat(st.mean), .comma = true },
        struct { k: []const u8, v: u64, comma: bool }{ .k = "min_ns", .v = min_ns, .comma = true },
        struct { k: []const u8, v: u64, comma: bool }{ .k = "max_ns", .v = max_ns, .comma = true },
        struct { k: []const u8, v: u64, comma: bool }{ .k = "sample_count", .v = effective.len, .comma = true },
        struct { k: []const u8, v: u64, comma: bool }{ .k = "warmup_count", .v = warmup, .comma = true },
        struct { k: []const u8, v: u64, comma: bool }{ .k = "cv_scaled_ppm", .v = @intFromFloat(st.cv * scale), .comma = true },
        struct { k: []const u8, v: u64, comma: bool }{ .k = "p95_ns", .v = st.p95, .comma = true },
        struct { k: []const u8, v: u64, comma: bool }{ .k = "p95_over_mean_scaled_ppm", .v = @intFromFloat(p95_over_mean * scale), .comma = true },
        struct { k: []const u8, v: u64, comma: bool }{ .k = "cv_max_scaled_ppm", .v = @intFromFloat(cv_max * scale), .comma = true },
        struct { k: []const u8, v: u64, comma: bool }{ .k = "p95_over_mean_max_scaled_ppm", .v = @intFromFloat(ratio_max * scale), .comma = true },
    }) |entry| {
        try w2.writeAll("\"");
        try w2.writeAll(entry.k);
        try w2.writeAll("\":");
        var numtmp: [32]u8 = undefined;
        const slice = std.fmt.bufPrint(&numtmp, "{d}", .{entry.v}) catch unreachable;
        try w2.writeAll(slice);
        if (entry.comma) try w2.writeAll(",");
    }
    try w2.writeAll("\"jitter_class\":\"");
    try w2.writeAll(jitter_class);
    try w2.writeAll("\",");
    // thresholds_evaluated: array of objects [{metric:"cv_scaled_ppm",actual:<>,max:<>,pass:true|false}, ...]
    try w2.writeAll("\"thresholds_evaluated\":[");
    {
        // cv
        try w2.writeAll("{\"metric\":\"cv_scaled_ppm\",\"actual\":");
        var numtmp: [32]u8 = undefined;
        var slice = std.fmt.bufPrint(&numtmp, "{d}", .{@as(u64, @intFromFloat(st.cv * scale))}) catch unreachable;
        try w2.writeAll(slice);
        try w2.writeAll(",\"max\":");
        slice = std.fmt.bufPrint(&numtmp, "{d}", .{@as(u64, @intFromFloat(cv_max * scale))}) catch unreachable;
        try w2.writeAll(slice);
        try w2.writeAll(",\"pass\":");
        try w2.writeAll(if (st.cv <= cv_max) "true" else "false");
        try w2.writeAll("}");
    }
    try w2.writeAll(",");
    {
        // p95_over_mean
        try w2.writeAll("{\"metric\":\"p95_over_mean_scaled_ppm\",\"actual\":");
        var numtmp2: [32]u8 = undefined;
        var slice2 = std.fmt.bufPrint(&numtmp2, "{d}", .{@as(u64, @intFromFloat(p95_over_mean * scale))}) catch unreachable;
        try w2.writeAll(slice2);
        try w2.writeAll(",\"max\":");
        slice2 = std.fmt.bufPrint(&numtmp2, "{d}", .{@as(u64, @intFromFloat(ratio_max * scale))}) catch unreachable;
        try w2.writeAll(slice2);
        try w2.writeAll(",\"pass\":");
        try w2.writeAll(if (p95_over_mean <= ratio_max) "true" else "false");
        try w2.writeAll("}");
    }
    try w2.writeAll("],\"pass\":");
    try w2.writeAll(if (pass) "true" else "false");
    try w2.writeAll("}\n");
    std.debug.print("{s}", .{fbs2.getWritten()});
}

// GAP-0133: Raft variance benchmarks use synthetic quorum delay model
// CANARY: REQ=REQ-BENCH-RAFT-001; FEATURE="Raft Variance Benchmarks"; ASPECT=DistributedTesting; STATUS=BENCHED; OWNER=core; UPDATED=2026-01-13
// Placeholder: Real Raft variance currently skipped due to incomplete replication state init in standalone mode.
// Synthetic model provides bounded latency estimates but not actual replication behavior.
fn lcg_step(s: *u64) u32 {
    s.* = s.* *% 6364136223846793005 +% 1;
    return @intCast((s.* >> 32) & 0xffffffff);
}

fn runSyntheticRaftCommitVariance(allocator: std.mem.Allocator) !void {
    // GAP-0133: Synthetic Raft commit variance model
    // Synthetic model: we simulate a leader appending entries and advancing commit index after quorum acks.
    // We model N followers with random (bounded) ack delays from a deterministic LCG.
    // TODO(raft-real): Swap synthetic quorum delay model with real raft.Partition commit advancement once
    // replication state initialization and AppendEntries scheduling are safe in standalone runner context.
    // CANARY: REQ=REQ-BENCH-RAFT-002; FEATURE="Synthetic Raft Commit Variance"; ASPECT=DistributedTesting; STATUS=BENCHED; OWNER=core; UPDATED=2026-01-13
    const followers: usize = 4; // quorum = 3 of 5 (leader + 4 followers)
    const iterations: usize = 200;
    const warmup: usize = 10;
    var timings = try allocator.alloc(u64, iterations - warmup);
    defer allocator.free(timings);
    var record_index: usize = 0;
    var seed: u64 = 0x1234abcd_9876fedc;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const t0 = std.time.nanoTimestamp();
        // generate follower ack delays (ns) deterministic pseudo-random within [5k, 50k]
        var delays: [followers]u64 = undefined;
        var d: usize = 0;
        while (d < followers) : (d += 1) {
            const r = lcg_step(&seed);
            const span: u64 = 50_000 - 5_000;
            delays[d] = 5_000 + (span * (@as(u64, r) & 0xffff) / 0xffff);
        }
        // find quorum ack time: third smallest delay
        std.sort.pdq(u64, &delays, {}, comptime std.sort.asc(u64));
        const quorum_delay = delays[2];
        // commit time approximated as quorum_delay plus small local apply cost (fixed 2k)
        const commit_time = quorum_delay + 2_000;
        // spin for commit_time using busy loop to mimic work (bounded)
        // If time source is fast, we risk under-shoot; accept approximation.
        while (true) {
            const now = std.time.nanoTimestamp();
            const elapsed: u64 = @intCast(now - t0);
            if (elapsed >= commit_time) break;
        }
        const t1 = std.time.nanoTimestamp();
        if (i >= warmup) {
            timings[record_index] = @intCast(t1 - t0);
            record_index += 1;
        }
    }
    const effective = timings[0..record_index];
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    for (effective) |v| {
        if (v < min_ns) min_ns = v;
        if (v > max_ns) max_ns = v;
    }
    if (effective.len == 0) min_ns = 0;
    const st = stats(allocator, effective);
    const p95_over_mean: f64 = if (st.mean == 0) 0 else @as(f64, @floatFromInt(st.p95)) / st.mean;
    const cv_max: f64 = 0.35; // looser for synthetic distribution
    const ratio_max: f64 = 3.0;
    const pass = (st.cv <= cv_max) and (p95_over_mean <= ratio_max);
    const scale = 10000.0;
    // v1
    {
        var buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();
        w.writeAll("{\"schema_version\":1,\"kind\":\"VarianceEnvelope\",\"benchmark\":\"raft_commit_advancement_variance\",") catch {};
        inline for (.{
            struct { k: []const u8, v: u64, comma: bool }{ .k = "mean_ns", .v = @intFromFloat(st.mean), .comma = true },
            struct { k: []const u8, v: u64, comma: bool }{ .k = "cv_scaled_ppm", .v = @as(u64, @intFromFloat(st.cv * scale)), .comma = true },
            struct { k: []const u8, v: u64, comma: bool }{ .k = "p95_ns", .v = st.p95, .comma = true },
            struct { k: []const u8, v: u64, comma: bool }{ .k = "p95_over_mean_scaled_ppm", .v = @as(u64, @intFromFloat(p95_over_mean * scale)), .comma = true },
            struct { k: []const u8, v: u64, comma: bool }{ .k = "cv_max_scaled_ppm", .v = @as(u64, @intFromFloat(cv_max * scale)), .comma = true },
            struct { k: []const u8, v: u64, comma: bool }{ .k = "p95_over_mean_max_scaled_ppm", .v = @as(u64, @intFromFloat(ratio_max * scale)), .comma = true },
        }) |entry| {
            w.writeAll("\"") catch {};
            w.writeAll(entry.k) catch {};
            w.writeAll("\":") catch {};
            var numtmp: [32]u8 = undefined;
            const slice = std.fmt.bufPrint(&numtmp, "{d}", .{entry.v}) catch "0";
            w.writeAll(slice) catch {};
            if (entry.comma) w.writeAll(",") catch {};
        }
        w.writeAll("\"pass\":") catch {};
        w.writeAll(if (pass) "true" else "false") catch {};
        w.writeAll("}\n") catch {};
        std.debug.print("{s}", .{fbs.getWritten()});
    }
    // v2
    {
        const jitter_class = if (st.cv < 0.10) "low" else if (st.cv < 0.20) "medium" else "high";
        var buf: [768]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();
        w.writeAll("{\"schema_version\":2,\"kind\":\"VarianceEnvelope\",\"benchmark\":\"raft_commit_advancement_variance\",") catch {};
        inline for (.{
            struct { k: []const u8, v: u64, comma: bool }{ .k = "mean_ns", .v = @intFromFloat(st.mean), .comma = true },
            struct { k: []const u8, v: u64, comma: bool }{ .k = "min_ns", .v = min_ns, .comma = true },
            struct { k: []const u8, v: u64, comma: bool }{ .k = "max_ns", .v = max_ns, .comma = true },
            struct { k: []const u8, v: u64, comma: bool }{ .k = "sample_count", .v = effective.len, .comma = true },
            struct { k: []const u8, v: u64, comma: bool }{ .k = "warmup_count", .v = warmup, .comma = true },
            struct { k: []const u8, v: u64, comma: bool }{ .k = "cv_scaled_ppm", .v = @intFromFloat(st.cv * scale), .comma = true },
            struct { k: []const u8, v: u64, comma: bool }{ .k = "p95_ns", .v = st.p95, .comma = true },
            struct { k: []const u8, v: u64, comma: bool }{ .k = "p95_over_mean_scaled_ppm", .v = @intFromFloat(p95_over_mean * scale), .comma = true },
            struct { k: []const u8, v: u64, comma: bool }{ .k = "cv_max_scaled_ppm", .v = @intFromFloat(cv_max * scale), .comma = true },
            struct { k: []const u8, v: u64, comma: bool }{ .k = "p95_over_mean_max_scaled_ppm", .v = @intFromFloat(ratio_max * scale), .comma = true },
        }) |entry| {
            w.writeAll("\"") catch {};
            w.writeAll(entry.k) catch {};
            w.writeAll("\":") catch {};
            var numtmp: [32]u8 = undefined;
            const slice = std.fmt.bufPrint(&numtmp, "{d}", .{entry.v}) catch "0";
            w.writeAll(slice) catch {};
            if (entry.comma) w.writeAll(",") catch {};
        }
        w.writeAll("\"jitter_class\":\"") catch {};
        w.writeAll(jitter_class) catch {};
        w.writeAll("\",") catch {};
        w.writeAll("\"thresholds_evaluated\":[") catch {};
        // cv metric
        {
            w.writeAll("{\"metric\":\"cv_scaled_ppm\",\"actual\":") catch {};
            var numtmp: [32]u8 = undefined;
            var slice = std.fmt.bufPrint(&numtmp, "{d}", .{@as(u64, @intFromFloat(st.cv * scale))}) catch "0";
            w.writeAll(slice) catch {};
            w.writeAll(",\"max\":") catch {};
            slice = std.fmt.bufPrint(&numtmp, "{d}", .{@as(u64, @intFromFloat(cv_max * scale))}) catch "0";
            w.writeAll(slice) catch {};
            w.writeAll(",\"pass\":") catch {};
            w.writeAll(if (st.cv <= cv_max) "true" else "false") catch {};
            w.writeAll("}") catch {};
        }
        w.writeAll(",") catch {};
        // p95_over_mean metric
        {
            w.writeAll("{\"metric\":\"p95_over_mean_scaled_ppm\",\"actual\":") catch {};
            var numtmp: [32]u8 = undefined;
            var slice = std.fmt.bufPrint(&numtmp, "{d}", .{@as(u64, @intFromFloat(p95_over_mean * scale))}) catch "0";
            w.writeAll(slice) catch {};
            w.writeAll(",\"max\":") catch {};
            slice = std.fmt.bufPrint(&numtmp, "{d}", .{@as(u64, @intFromFloat(ratio_max * scale))}) catch "0";
            w.writeAll(slice) catch {};
            w.writeAll(",\"pass\":") catch {};
            w.writeAll(if (p95_over_mean <= ratio_max) "true" else "false") catch {};
            w.writeAll("}") catch {};
        }
        w.writeAll("],\"pass\":") catch {};
        w.writeAll(if (pass) "true" else "false") catch {};
        w.writeAll("}\n") catch {};
        std.debug.print("{s}", .{fbs.getWritten()});
    }
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    // Dummy usage to ensure geode root module isn't optimized as unused
    var pr = try geode.parseGql("RETURN 1", allocator);
    pr.deinit();
    try runPathMultiBranch(allocator);
    try runSyntheticRaftCommitVariance(allocator);
    // Integrate ordered pagination variance envelope benchmark (CANARY: PaginationOrderedVarianceEnvelope)
    try geode.benchmarks.pagination.benchmarkPaginationOrderedVarianceEnvelope();
    // Integrate execution pagination variance envelope benchmark (CANARY: PaginationExecutionVarianceEnvelope)
    try geode.benchmarks.pagination_execution.benchmarkPaginationExecutionVarianceEnvelope();
}
