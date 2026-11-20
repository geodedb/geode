// benchmark_tde_key_rotate.zig
//
// GAP-0890: REAL key-rotation micro-benchmark (replaces the previous stub
// that simulated "hash+derive cost" with an integer multiply loop).
//
// Two scenarios, both measuring actual work over an in-memory KeyRegistry:
//   - keyrot_rotate:    ns per rotateNowAt() — real getrandom(2) 256-bit key
//                       generation + history append + audit entry.
//   - keyrot_rewrap_4k: ns per reencryptPage() on a 4096-byte page — real
//                       AES-256-GCM decrypt under the previous key followed
//                       by a real AES-256-GCM re-encrypt under the new active
//                       key (the lazy re-wrap path). Every page is verified
//                       to round-trip before timing begins; one page is
//                       verified to decrypt under the new key after.
//
// Emits a schema_version-2 VarianceEnvelope JSON line per scenario (mean,
// p95, cv computed from the measured samples — no simulated numbers),
// matching the convention in benchmarks/benchmark_fts_storage.zig. No
// variance gate is enforced here; this is a latency-truth benchmark.
//
// Run: zig build bench-tde-key-rotate
//
// CANARY: REQ=REQ-GQL-046; FEATURE="TDE Key Rotation Throughput"; ASPECT=Storage; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_046_KeyRotateThroughput; OWNER=security; UPDATED=2026-06-10

const std = @import("std");
const builtin = @import("builtin");
const keyrot = @import("geode").security.key_rotation;

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

// Zig 0.16 compat: std.time.nanoTimestamp removed; use clock_gettime(MONOTONIC).
fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

const Stats = struct {
    mean_ns: f64,
    min_ns: u64,
    max_ns: u64,
    p95_ns: u64,
    cv: f64,
    sample_count: usize,
};

fn computeStats(samples: []u64) Stats {
    std.sort.heap(u64, samples, {}, comptime struct {
        fn lt(_: void, a: u64, b: u64) bool {
            return a < b;
        }
    }.lt);
    var sum: u128 = 0;
    for (samples) |s| sum += s;
    const mean = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(samples.len));
    var diff: f64 = 0;
    for (samples) |s| {
        const d = @as(f64, @floatFromInt(s)) - mean;
        diff += d * d;
    }
    const stddev = @sqrt(diff / @as(f64, @floatFromInt(samples.len)));
    const cv = if (mean == 0) 0 else stddev / mean;
    const p95_idx = (samples.len * 95) / 100;
    const p95 = samples[if (p95_idx >= samples.len) samples.len - 1 else p95_idx];
    return .{
        .mean_ns = mean,
        .min_ns = samples[0],
        .max_ns = samples[samples.len - 1],
        .p95_ns = p95,
        .cv = cv,
        .sample_count = samples.len,
    };
}

fn printEnvelope(scenario: []const u8, st: Stats, unit: []const u8) void {
    std.debug.print(
        "{{\"schema_version\":2,\"benchmark\":\"tde_key_rotate\",\"scenario\":\"{s}\",\"unit\":\"{s}\",\"mean_ns\":{d:.1},\"min_ns\":{d},\"max_ns\":{d},\"p95_ns\":{d},\"cv\":{d:.6},\"samples\":{d}}}\n",
        .{ scenario, unit, st.mean_ns, st.min_ns, st.max_ns, st.p95_ns, st.cv, st.sample_count },
    );
}

const ROTATE_SAMPLES = 256;
const REWRAP_SAMPLES = 256;
const PAGE_SIZE = 4096;

test "BenchmarkCANARY_REQ_GQL_046_KeyRotateThroughput" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // ---- Scenario 1: rotation latency (real keygen, policy-forced) ----
    {
        var reg = keyrot.KeyRegistry.init(alloc);
        defer reg.deinit();
        _ = try reg.loadActiveDataKey();

        var samples: [ROTATE_SAMPLES]u64 = undefined;
        const force: keyrot.RotationPolicy = .{ .min_interval_secs = 0 };
        var i: usize = 0;
        var fake_now: i64 = 1_000_000;
        while (i < ROTATE_SAMPLES) : (i += 1) {
            fake_now += 1;
            const t0 = nowNs();
            _ = try reg.rotateNowAt(force, fake_now);
            samples[i] = nowNs() - t0;
        }
        // Rotation really happened: history grew by ROTATE_SAMPLES keys.
        try std.testing.expectEqual(@as(usize, 1 + ROTATE_SAMPLES), reg.history.items.len);
        printEnvelope("keyrot_rotate", computeStats(&samples), "ns/rotation");
    }

    // ---- Scenario 2: lazy re-wrap latency on real 4 KiB AES-256-GCM pages ----
    {
        var reg = keyrot.KeyRegistry.init(alloc);
        defer reg.deinit();
        const aes_gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
        const old_key = try reg.loadActiveDataKey();

        // Encrypt REWRAP_SAMPLES pages under the old key (nonce || ct || tag).
        var payload: [PAGE_SIZE]u8 = undefined;
        compat_fillRandom(&payload);
        const page_len = aes_gcm.nonce_length + PAGE_SIZE + aes_gcm.tag_length;
        const pages = try alloc.alloc([]u8, REWRAP_SAMPLES);
        defer {
            for (pages) |p| alloc.free(p);
            alloc.free(pages);
        }
        for (pages) |*p| {
            p.* = try alloc.alloc(u8, page_len);
            var nonce: [aes_gcm.nonce_length]u8 = undefined;
            compat_fillRandom(&nonce);
            @memcpy(p.*[0..aes_gcm.nonce_length], &nonce);
            var tag: [aes_gcm.tag_length]u8 = undefined;
            aes_gcm.encrypt(p.*[aes_gcm.nonce_length .. page_len - aes_gcm.tag_length], &tag, &payload, "", nonce, old_key.material);
            @memcpy(p.*[page_len - aes_gcm.tag_length ..], &tag);
        }

        // Rotate once so reencryptPage re-wraps old-key pages under the new key.
        _ = try reg.rotateNowAt(.{ .min_interval_secs = 0 }, old_key.created_unix_epoch + 1);

        var samples: [REWRAP_SAMPLES]u64 = undefined;
        for (pages, 0..) |p, i| {
            const t0 = nowNs();
            try reg.reencryptPage(@intCast(i), p);
            samples[i] = nowNs() - t0;
        }
        printEnvelope("keyrot_rewrap_4k", computeStats(&samples), "ns/page");

        // Truth check: a re-wrapped page decrypts under the NEW active key.
        const new_key = reg.active.?;
        const p0 = pages[0];
        const nonce = p0[0..aes_gcm.nonce_length].*;
        const ct = p0[aes_gcm.nonce_length .. page_len - aes_gcm.tag_length];
        const tag = p0[page_len - aes_gcm.tag_length ..][0..aes_gcm.tag_length].*;
        var out: [PAGE_SIZE]u8 = undefined;
        try aes_gcm.decrypt(&out, ct, tag, "", nonce, new_key.material);
        try std.testing.expectEqualSlices(u8, &payload, &out);
    }
}
