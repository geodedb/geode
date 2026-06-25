const std = @import("std");
const build_options = @import("build_options");
const crypto_zig = @import("quic_crypto");
const tp = @import("thread_pool");

// CANARY: REQ=REQ-QUIC-HC-029; FEATURE="QUIC High-Concurrency Requests"; ASPECT=BoundedParallelCrypto; STATUS=IMPL; TEST=test_quic_parallel_facade; OWNER=transport; UPDATED=2026-05-26
//
// The upstream QUIC package defaults to a hidden global parallel pool backed by
// page_allocator. Geode cannot use that in production, but the serial fallback
// leaves packet crypto and recovery scans on the poll thread during handshake
// storms. This facade preserves QUIC's parallel API while owning a bounded pool
// backed by smp_allocator.

const MAX_CHUNKS = 64;

var global_pool: ?tp.ThreadPool = null;
var pool_mutex: std.Io.Mutex = std.Io.Mutex.init;

fn envUsize(name: [*:0]const u8, default_value: usize) usize {
    const raw = std.c.getenv(name) orelse return default_value;
    const value = std.mem.span(raw);
    if (value.len == 0) return default_value;
    return std.fmt.parseUnsigned(usize, value, 10) catch default_value;
}

fn boundedWorkerCount() usize {
    const configured = envUsize("GEODE_QUIC_PARALLEL_WORKERS", 0);
    if (configured == 0) return 0;
    return @min(configured, 64);
}

fn boundedQueueCapacity() usize {
    return @max(@as(usize, 64), envUsize("GEODE_QUIC_PARALLEL_QUEUE_CAPACITY", 4096));
}

pub fn getPool() ?*tp.ThreadPool {
    pool_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer pool_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (global_pool == null) {
        global_pool = tp.ThreadPool.init(std.heap.smp_allocator, .{
            .max_threads = boundedWorkerCount(),
            .queue_capacity = boundedQueueCapacity(),
            .local_queue_capacity = 256,
            .inject_batch_size = 32,
            .idle_park_after_ns = 100_000,
            .idle_purge_after_ns = 10_000_000,
            .deinit_timeout_ns = 5 * std.time.ns_per_s,
        }) catch return null;
    }
    return &global_pool.?;
}

pub fn deinitPool() void {
    pool_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer pool_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (global_pool) |*pool| {
        pool.deinit();
        global_pool = null;
    }
}

pub const AeadEncryptInput = struct {
    key: []const u8,
    iv: []const u8,
    packet_number: u64,
    aad: []const u8,
    plaintext: []const u8,
};

pub const AeadEncryptResult = struct {
    success: bool,
    length: usize,
};

const AeadEncryptChunk = struct {
    suite: crypto_zig.AeadSuite,
    inputs: []const AeadEncryptInput,
    outputs: [][]u8,
    results: []AeadEncryptResult,
};

fn aeadEncryptOne(suite: crypto_zig.AeadSuite, input: AeadEncryptInput, output: []u8) AeadEncryptResult {
    const len = crypto_zig.aeadEncrypt(
        suite,
        input.key,
        input.iv,
        input.packet_number,
        input.aad,
        input.plaintext,
        output,
    ) catch return .{ .success = false, .length = 0 };
    return .{ .success = true, .length = len };
}

fn aeadEncryptChunkFn(ctx: *anyopaque, _: *tp.TaskContext) void {
    const chunk: *AeadEncryptChunk = @ptrCast(@alignCast(ctx));
    for (chunk.inputs, 0..) |input, i| {
        chunk.results[i] = aeadEncryptOne(chunk.suite, input, chunk.outputs[i]);
    }
}

fn aeadEncryptSequential(
    suite: crypto_zig.AeadSuite,
    inputs: []const AeadEncryptInput,
    outputs: [][]u8,
    results: []AeadEncryptResult,
) void {
    for (inputs, 0..) |input, i| {
        results[i] = aeadEncryptOne(suite, input, outputs[i]);
    }
}

pub fn parallelAeadEncrypt(
    suite: crypto_zig.AeadSuite,
    inputs: []const AeadEncryptInput,
    outputs: [][]u8,
    results: []AeadEncryptResult,
) void {
    std.debug.assert(inputs.len == outputs.len);
    std.debug.assert(inputs.len == results.len);

    const pool = if (inputs.len >= 4) getPool() else null;
    if (pool == null or inputs.len < 4) {
        aeadEncryptSequential(suite, inputs, outputs, results);
        return;
    }

    const n_chunks = @min(inputs.len, MAX_CHUNKS);
    var chunks: [MAX_CHUNKS]AeadEncryptChunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    const chunk_size = (inputs.len + n_chunks - 1) / n_chunks;

    var n: usize = 0;
    var start: usize = 0;
    while (start < inputs.len) : (n += 1) {
        const end = @min(start + chunk_size, inputs.len);
        chunks[n] = .{
            .suite = suite,
            .inputs = inputs[start..end],
            .outputs = outputs[start..end],
            .results = results[start..end],
        };
        batch[n] = .{ .task_fn = aeadEncryptChunkFn, .ctx = &chunks[n] };
        start = end;
    }

    var wg = pool.?.waitGroup();
    _ = pool.?.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        // CANARY: REQ=REQ-QUIC-HC-060; FEATURE="QUIC High-Concurrency Requests"; ASPECT=PartialSubmitWaitGroup; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-26
        // submitBatch may fail after accepting a partial batch. Wait before
        // falling back so worker tasks cannot call done() on a returned stack
        // WaitGroup.
        wg.wait();
        aeadEncryptSequential(suite, inputs, outputs, results);
        return;
    };
    wg.wait();
}

pub const AeadDecryptInput = struct {
    key: []const u8,
    iv: []const u8,
    packet_number: u64,
    aad: []const u8,
    ciphertext_and_tag: []const u8 = &.{},
    ciphertext: []const u8 = &.{},

    fn bytes(self: AeadDecryptInput) []const u8 {
        if (self.ciphertext_and_tag.len != 0) return self.ciphertext_and_tag;
        return self.ciphertext;
    }
};

pub const AeadDecryptResult = struct {
    success: bool,
    length: usize,
    auth_failed: bool = false,
};

const AeadDecryptChunk = struct {
    suite: crypto_zig.AeadSuite,
    inputs: []const AeadDecryptInput,
    outputs: [][]u8,
    results: []AeadDecryptResult,
};

fn aeadDecryptOne(suite: crypto_zig.AeadSuite, input: AeadDecryptInput, output: []u8) AeadDecryptResult {
    const len = crypto_zig.aeadDecrypt(
        suite,
        input.key,
        input.iv,
        input.packet_number,
        input.aad,
        input.bytes(),
        output,
    ) catch |err| return .{
        .success = false,
        .length = 0,
        .auth_failed = err == error.AuthenticationFailed,
    };
    return .{ .success = true, .length = len, .auth_failed = false };
}

fn aeadDecryptChunkFn(ctx: *anyopaque, _: *tp.TaskContext) void {
    const chunk: *AeadDecryptChunk = @ptrCast(@alignCast(ctx));
    for (chunk.inputs, 0..) |input, i| {
        chunk.results[i] = aeadDecryptOne(chunk.suite, input, chunk.outputs[i]);
    }
}

fn aeadDecryptSequential(
    suite: crypto_zig.AeadSuite,
    inputs: []const AeadDecryptInput,
    outputs: [][]u8,
    results: []AeadDecryptResult,
) void {
    for (inputs, 0..) |input, i| {
        results[i] = aeadDecryptOne(suite, input, outputs[i]);
    }
}

pub fn parallelAeadDecrypt(
    suite: crypto_zig.AeadSuite,
    inputs: []const AeadDecryptInput,
    outputs: [][]u8,
    results: []AeadDecryptResult,
) void {
    std.debug.assert(inputs.len == outputs.len);
    std.debug.assert(inputs.len == results.len);

    const pool = if (inputs.len >= 4) getPool() else null;
    if (pool == null or inputs.len < 4) {
        aeadDecryptSequential(suite, inputs, outputs, results);
        return;
    }

    const n_chunks = @min(inputs.len, MAX_CHUNKS);
    var chunks: [MAX_CHUNKS]AeadDecryptChunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    const chunk_size = (inputs.len + n_chunks - 1) / n_chunks;

    var n: usize = 0;
    var start: usize = 0;
    while (start < inputs.len) : (n += 1) {
        const end = @min(start + chunk_size, inputs.len);
        chunks[n] = .{
            .suite = suite,
            .inputs = inputs[start..end],
            .outputs = outputs[start..end],
            .results = results[start..end],
        };
        batch[n] = .{ .task_fn = aeadDecryptChunkFn, .ctx = &chunks[n] };
        start = end;
    }

    var wg = pool.?.waitGroup();
    _ = pool.?.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        wg.wait();
        aeadDecryptSequential(suite, inputs, outputs, results);
        return;
    };
    wg.wait();
}

pub const HeaderProtectInput = struct {
    hp_key: []const u8,
    sample: [16]u8,
};

const HeaderProtectChunk = struct {
    suite: crypto_zig.AeadSuite,
    inputs: []const HeaderProtectInput,
    masks: [][5]u8,
};

fn generateHeaderMask(suite: crypto_zig.AeadSuite, hp_key: []const u8, sample: [16]u8) [5]u8 {
    var mask: [5]u8 = [_]u8{0} ** 5;

    switch (suite) {
        .aes_128_gcm => {
            if (hp_key.len >= 16) {
                const aes = std.crypto.core.aes.Aes128.initEnc(hp_key[0..16].*);
                var block: [16]u8 = undefined;
                aes.encrypt(&block, &sample);
                @memcpy(&mask, block[0..5]);
            }
        },
        .aes_256_gcm => {
            if (hp_key.len >= 32) {
                const aes = std.crypto.core.aes.Aes256.initEnc(hp_key[0..32].*);
                var block: [16]u8 = undefined;
                aes.encrypt(&block, &sample);
                @memcpy(&mask, block[0..5]);
            }
        },
        .chacha20_poly1305 => {
            // FIPS fail-close: ChaCha20 header protection is not approved under FIPS 140-3.
            // Under FIPS, only AES cipher suites are negotiated, so this branch is unreachable
            // in production. Gate it defensively to prevent silent fallback.
            // CANARY: REQ=REQ-FIPS-CHACHA-FAILCLOSE-003; FEATURE="FIPSFailClose"; ASPECT=QUICHeaderProtect; STATUS=IMPL; OWNER=security; UPDATED=2026-06-24
            if (comptime build_options.fips) {
                @panic("FIPS: ChaCha20 header protection is not permitted under FIPS 140-3; only AES cipher suites are approved");
            }
            if (hp_key.len >= 32) {
                const counter = std.mem.readInt(u32, sample[0..4], .little);
                var nonce: [12]u8 = undefined;
                @memcpy(&nonce, sample[4..16]);
                var key32: [32]u8 = undefined;
                @memcpy(&key32, hp_key[0..32]);
                std.crypto.stream.chacha.ChaCha20IETF.xor(&mask, &[_]u8{0} ** 5, counter, key32, nonce);
            }
        },
    }

    return mask;
}

fn headerProtectChunkFn(ctx: *anyopaque, _: *tp.TaskContext) void {
    const chunk: *HeaderProtectChunk = @ptrCast(@alignCast(ctx));
    for (chunk.inputs, 0..) |input, i| {
        chunk.masks[i] = generateHeaderMask(chunk.suite, input.hp_key, input.sample);
    }
}

pub fn parallelHeaderProtect(
    suite: crypto_zig.AeadSuite,
    inputs: []const HeaderProtectInput,
    masks: [][5]u8,
) void {
    std.debug.assert(inputs.len == masks.len);

    const pool = if (inputs.len >= 8) getPool() else null;
    if (pool == null or inputs.len < 8) {
        for (inputs, 0..) |input, i| {
            masks[i] = generateHeaderMask(suite, input.hp_key, input.sample);
        }
        return;
    }

    const n_chunks = @min(inputs.len, MAX_CHUNKS);
    var chunks: [MAX_CHUNKS]HeaderProtectChunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    const chunk_size = (inputs.len + n_chunks - 1) / n_chunks;

    var n: usize = 0;
    var start: usize = 0;
    while (start < inputs.len) : (n += 1) {
        const end = @min(start + chunk_size, inputs.len);
        chunks[n] = .{
            .suite = suite,
            .inputs = inputs[start..end],
            .masks = masks[start..end],
        };
        batch[n] = .{ .task_fn = headerProtectChunkFn, .ctx = &chunks[n] };
        start = end;
    }

    var wg = pool.?.waitGroup();
    _ = pool.?.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        wg.wait();
        for (inputs, 0..) |input, i| {
            masks[i] = generateHeaderMask(suite, input.hp_key, input.sample);
        }
        return;
    };
    wg.wait();
}

pub const SentPacketInfo = struct {
    packet_number: u64,
    size: usize,
    time_sent_ns: u64,
    ack_eliciting: bool,
    declared_lost: bool,
};

pub const LossDetectResult = struct {
    lost_count: usize,
    bytes_lost: usize,
};

const LossDetectChunk = struct {
    sent_packets: []SentPacketInfo,
    largest_acked: u64,
    packet_threshold: u64,
    time_threshold_ns: u64,
    now_ns: u64,
    lost_count: usize = 0,
    bytes_lost: usize = 0,
};

fn lossDetectSequential(
    sent_packets: []SentPacketInfo,
    largest_acked: u64,
    packet_threshold: u64,
    time_threshold_ns: u64,
    now_ns: u64,
) LossDetectResult {
    var lost_count: usize = 0;
    var bytes_lost: usize = 0;

    for (sent_packets) |*sp| {
        if (sp.declared_lost) continue;
        if (sp.packet_number + packet_threshold <= largest_acked) {
            sp.declared_lost = true;
            lost_count += 1;
            bytes_lost += sp.size;
            continue;
        }
        const deadline = sp.time_sent_ns + time_threshold_ns;
        if (now_ns >= deadline and sp.packet_number < largest_acked) {
            sp.declared_lost = true;
            lost_count += 1;
            bytes_lost += sp.size;
        }
    }

    return .{ .lost_count = lost_count, .bytes_lost = bytes_lost };
}

fn lossDetectChunkFn(ctx: *anyopaque, _: *tp.TaskContext) void {
    const chunk: *LossDetectChunk = @ptrCast(@alignCast(ctx));
    const result = lossDetectSequential(
        chunk.sent_packets,
        chunk.largest_acked,
        chunk.packet_threshold,
        chunk.time_threshold_ns,
        chunk.now_ns,
    );
    chunk.lost_count = result.lost_count;
    chunk.bytes_lost = result.bytes_lost;
}

pub fn parallelLossDetect(
    sent_packets: []SentPacketInfo,
    largest_acked: u64,
    packet_threshold: u64,
    time_threshold_ns: u64,
    now_ns: u64,
) LossDetectResult {
    const pool = if (sent_packets.len >= 64) getPool() else null;
    if (pool == null or sent_packets.len < 64) {
        return lossDetectSequential(sent_packets, largest_acked, packet_threshold, time_threshold_ns, now_ns);
    }

    const n_chunks = @min(sent_packets.len, MAX_CHUNKS);
    var chunks: [MAX_CHUNKS]LossDetectChunk = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    const chunk_size = (sent_packets.len + n_chunks - 1) / n_chunks;

    var n: usize = 0;
    var start: usize = 0;
    while (start < sent_packets.len) : (n += 1) {
        const end = @min(start + chunk_size, sent_packets.len);
        chunks[n] = .{
            .sent_packets = sent_packets[start..end],
            .largest_acked = largest_acked,
            .packet_threshold = packet_threshold,
            .time_threshold_ns = time_threshold_ns,
            .now_ns = now_ns,
        };
        batch[n] = .{ .task_fn = lossDetectChunkFn, .ctx = &chunks[n] };
        start = end;
    }

    var wg = pool.?.waitGroup();
    _ = pool.?.submitBatch(batch[0..n], .{ .wait_group = &wg }) catch {
        wg.wait();
        return lossDetectSequential(sent_packets, largest_acked, packet_threshold, time_threshold_ns, now_ns);
    };
    wg.wait();

    var total = LossDetectResult{ .lost_count = 0, .bytes_lost = 0 };
    for (chunks[0..n]) |*chunk| {
        total.lost_count += chunk.lost_count;
        total.bytes_lost += chunk.bytes_lost;
    }
    return total;
}
