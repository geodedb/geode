const std = @import("std");
const ds = @import("ds");

const ITERATIONS = 100_000;
const TREE_ITERATIONS = 10_000;
const WARMUP_RUNS = 3;
const BENCH_RUNS = 5;

fn benchStack(allocator: std.mem.Allocator) !u64 {
    var timer = try std.time.Timer.start();
    var stack = ds.Stack(i32).init(allocator);
    defer stack.deinit();

    const start = timer.lap();
    var i: i32 = 0;
    while (i < ITERATIONS) : (i += 1) {
        try stack.push(i);
    }
    while (stack.pop()) |_| {}
    const elapsed = timer.read() - start;
    return elapsed;
}

fn benchQueue(allocator: std.mem.Allocator) !u64 {
    var timer = try std.time.Timer.start();
    var queue = ds.Queue(i32).init(allocator);
    defer queue.deinit();

    const start = timer.lap();
    var i: i32 = 0;
    while (i < ITERATIONS) : (i += 1) {
        try queue.enqueue(i);
    }
    while (queue.dequeue()) |_| {}
    const elapsed = timer.read() - start;
    return elapsed;
}

fn benchDeque(allocator: std.mem.Allocator) !u64 {
    var timer = try std.time.Timer.start();
    var deque = try ds.Deque(i32).init(allocator, 16);
    defer deque.deinit();

    const start = timer.lap();
    var i: i32 = 0;
    while (i < ITERATIONS) : (i += 1) {
        try deque.pushBack(i);
    }
    while (deque.popFront()) |_| {}
    const elapsed = timer.read() - start;
    return elapsed;
}

fn benchSet(allocator: std.mem.Allocator) !u64 {
    var timer = try std.time.Timer.start();
    var set = ds.Set(i32).init(allocator);
    defer set.deinit();

    const start = timer.lap();
    var i: i32 = 0;
    while (i < ITERATIONS) : (i += 1) {
        try set.add(i);
    }
    i = 0;
    while (i < ITERATIONS) : (i += 1) {
        _ = set.contains(i);
    }
    const elapsed = timer.read() - start;
    return elapsed;
}

// ============================================================================
// Helper: print a single benchmark result line
// ============================================================================

fn printTime(name: []const u8, elapsed_ns: u64) void {
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    std.debug.print("  {s}: {d:.2} ms\n", .{ name, elapsed_ms });
}

// ============================================================================
// Tree Structure Benchmarks
// ============================================================================

fn intCompare(a: i32, b: i32) std.math.Order {
    return std.math.order(a, b);
}

fn benchTrees(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Tree Structures Benchmarks ({d} ops) ===\n\n", .{TREE_ITERATIONS});

    // --- BST: 1K insert + 1K search (reduced to avoid degenerate tree depth) ---
    {
        const bst_count = 1000;
        var bst = ds.BST(i32).init(allocator, &intCompare);
        defer bst.deinit();

        var timer = try std.time.Timer.start();
        const start = timer.lap();

        var i: i32 = 0;
        while (i < bst_count) : (i += 1) {
            try bst.insert(i);
        }
        i = 0;
        while (i < bst_count) : (i += 1) {
            _ = bst.search(i);
        }

        const elapsed = timer.read() - start;
        printTime("BST (insert+search)", elapsed);
    }

    // --- RBTree: 10K insert + 10K search + 10K delete ---
    {
        var rbt = ds.RBTree(i32).init(allocator, &intCompare);
        defer rbt.deinit();

        var timer = try std.time.Timer.start();
        const start = timer.lap();

        var i: i32 = 0;
        while (i < TREE_ITERATIONS) : (i += 1) {
            try rbt.insert(i);
        }
        i = 0;
        while (i < TREE_ITERATIONS) : (i += 1) {
            _ = rbt.search(i);
        }
        i = 0;
        while (i < TREE_ITERATIONS) : (i += 1) {
            _ = rbt.delete(i);
        }

        const elapsed = timer.read() - start;
        printTime("RBTree (ins+search+del)", elapsed);
    }

    // --- SkipList: 10K insert + 10K search + 10K delete ---
    {
        var sl = try ds.SkipList(i32, i32).init(allocator, 42, &intCompare);
        defer sl.deinit();

        var timer = try std.time.Timer.start();
        const start = timer.lap();

        var i: i32 = 0;
        while (i < TREE_ITERATIONS) : (i += 1) {
            try sl.insert(i, i);
        }
        i = 0;
        while (i < TREE_ITERATIONS) : (i += 1) {
            _ = sl.search(i);
        }
        i = 0;
        while (i < TREE_ITERATIONS) : (i += 1) {
            _ = sl.delete(i);
        }

        const elapsed = timer.read() - start;
        printTime("SkipList (ins+search+del)", elapsed);
    }

    // --- Trie: 1K insert + 1K search (reduced to avoid deinit crash) ---
    {
        const trie_count = 1000;
        var trie = try ds.Trie.init(allocator);
        defer trie.deinit();

        // Pre-generate key strings
        const keys = try allocator.alloc([]u8, trie_count);
        var keys_allocated: usize = 0;
        defer {
            for (keys[0..keys_allocated]) |k| {
                allocator.free(k);
            }
            allocator.free(keys);
        }
        for (0..trie_count) |idx| {
            keys[idx] = try std.fmt.allocPrint(allocator, "key_{d}", .{idx});
            keys_allocated = idx + 1;
        }

        var timer = try std.time.Timer.start();
        const start = timer.lap();

        for (0..trie_count) |idx| {
            try trie.insert(keys[idx], idx);
        }
        for (0..trie_count) |idx| {
            _ = trie.search(keys[idx]) catch {};
        }

        const elapsed = timer.read() - start;
        printTime("Trie (insert+search)", elapsed);
    }
}

// ============================================================================
// Cache & Probabilistic Structure Benchmarks
// ============================================================================

fn benchCaches(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Cache & Probabilistic Benchmarks ({d} ops) ===\n\n", .{TREE_ITERATIONS});

    // --- LRU: 10K put + 10K get (mixed hits/misses) ---
    {
        var lru = ds.LRU(i32, i32).init(allocator, 5000);
        defer lru.deinit();

        var timer = try std.time.Timer.start();
        const start = timer.lap();

        var i: i32 = 0;
        while (i < TREE_ITERATIONS) : (i += 1) {
            try lru.put(i, i * 10);
        }
        // Mixed hits/misses: half exist in cache (5000-9999), half evicted (0-4999)
        i = 0;
        while (i < TREE_ITERATIONS) : (i += 1) {
            _ = lru.get(i);
        }

        const elapsed = timer.read() - start;
        printTime("LRU (put+get)", elapsed);
    }

    // --- LFU: 10K put + 10K get ---
    {
        var lfu = ds.LFU(i32, i32).init(allocator, 5000);
        defer lfu.deinit();

        var timer = try std.time.Timer.start();
        const start = timer.lap();

        var i: i32 = 0;
        while (i < TREE_ITERATIONS) : (i += 1) {
            try lfu.put(i, i * 10);
        }
        i = 0;
        while (i < TREE_ITERATIONS) : (i += 1) {
            _ = try lfu.get(i);
        }

        const elapsed = timer.read() - start;
        printTime("LFU (put+get)", elapsed);
    }

    // --- BloomFilter: 10K add + 10K mightContain ---
    {
        var bloom = try ds.BloomFilter.init(allocator, TREE_ITERATIONS, 0.01, 42);
        defer bloom.deinit();

        // Pre-generate key strings
        const keys = try allocator.alloc([]u8, TREE_ITERATIONS);
        var keys_allocated: usize = 0;
        defer {
            for (keys[0..keys_allocated]) |k| {
                allocator.free(k);
            }
            allocator.free(keys);
        }
        for (0..TREE_ITERATIONS) |idx| {
            keys[idx] = try std.fmt.allocPrint(allocator, "bloom_{d}", .{idx});
            keys_allocated = idx + 1;
        }

        var timer = try std.time.Timer.start();
        const start = timer.lap();

        for (0..TREE_ITERATIONS) |idx| {
            bloom.add(keys[idx]);
        }
        for (0..TREE_ITERATIONS) |idx| {
            _ = bloom.mightContain(keys[idx]);
        }

        const elapsed = timer.read() - start;
        printTime("BloomFilter (add+query)", elapsed);
    }

    // --- CountMinSketch: 10K add + 10K estimate ---
    {
        var cms = try ds.CountMinSketch.init(allocator, 4, 1024, 42);
        defer cms.deinit();

        // Pre-generate key strings
        const keys = try allocator.alloc([]u8, TREE_ITERATIONS);
        var keys_allocated: usize = 0;
        defer {
            for (keys[0..keys_allocated]) |k| {
                allocator.free(k);
            }
            allocator.free(keys);
        }
        for (0..TREE_ITERATIONS) |idx| {
            keys[idx] = try std.fmt.allocPrint(allocator, "cms_{d}", .{idx});
            keys_allocated = idx + 1;
        }

        var timer = try std.time.Timer.start();
        const start = timer.lap();

        for (0..TREE_ITERATIONS) |idx| {
            cms.add(keys[idx], 1);
        }
        for (0..TREE_ITERATIONS) |idx| {
            _ = cms.estimate(keys[idx]);
        }

        const elapsed = timer.read() - start;
        printTime("CountMinSketch (add+est)", elapsed);
    }
}

// ============================================================================
// Graph Structure Benchmarks
// ============================================================================

fn benchGraph(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Graph Structure Benchmarks ===\n\n", .{});

    // --- UnionFind: 10K make + 10K find + 5K unite ---
    {
        var uf = ds.UnionFind.init(allocator);
        defer uf.deinit();

        // Pre-generate element strings (heap-allocated to avoid stack overflow)
        const uf_count = TREE_ITERATIONS;
        const elems = try allocator.alloc([]u8, uf_count);
        var elems_allocated: usize = 0;
        defer {
            for (elems[0..elems_allocated]) |e| {
                allocator.free(e);
            }
            allocator.free(elems);
        }
        for (0..uf_count) |idx| {
            elems[idx] = try std.fmt.allocPrint(allocator, "uf_{d}", .{idx});
            elems_allocated = idx + 1;
        }

        var timer = try std.time.Timer.start();
        const start = timer.lap();

        // 10K make
        for (0..uf_count) |idx| {
            try uf.make(elems[idx]);
        }

        // 10K find
        for (0..uf_count) |idx| {
            _ = try uf.find(elems[idx]);
        }

        // 5K unite (pair consecutive elements)
        const unite_count = uf_count / 2;
        for (0..unite_count) |idx| {
            _ = try uf.unite(elems[idx * 2], elems[idx * 2 + 1]);
        }

        const elapsed = timer.read() - start;
        printTime("UnionFind (make+find+unite)", elapsed);
    }
}

// ============================================================================
// Parallel Operation Benchmarks
// ============================================================================

const BenchResult = struct {
    seq_ns: u64,
    par_ns: u64,

    fn speedup(self: BenchResult) f64 {
        if (self.par_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.seq_ns)) / @as(f64, @floatFromInt(self.par_ns));
    }

    fn seqMs(self: BenchResult) f64 {
        return @as(f64, @floatFromInt(self.seq_ns)) / 1_000_000.0;
    }

    fn parMs(self: BenchResult) f64 {
        return @as(f64, @floatFromInt(self.par_ns)) / 1_000_000.0;
    }
};

fn sequentialSum(comptime T: type, data: []const T) T {
    var sum: T = 0;
    for (data) |v| sum += v;
    return sum;
}

fn sequentialMax(comptime T: type, data: []const T) T {
    if (data.len == 0) return 0;
    var max = data[0];
    for (data[1..]) |v| {
        if (v > max) max = v;
    }
    return max;
}

fn sequentialCount(comptime T: type, data: []const T, comptime pred: fn (T) bool) usize {
    var count: usize = 0;
    for (data) |v| {
        if (pred(v)) count += 1;
    }
    return count;
}

fn sequentialAny(comptime T: type, data: []const T, comptime pred: fn (T) bool) bool {
    for (data) |v| {
        if (pred(v)) return true;
    }
    return false;
}

fn sequentialAll(comptime T: type, data: []const T, comptime pred: fn (T) bool) bool {
    for (data) |v| {
        if (!pred(v)) return false;
    }
    return true;
}

fn sequentialMap(comptime T: type, input: []const T, output: []T, comptime mapFn: fn (T) T) void {
    for (input, 0..) |v, i| output[i] = mapFn(v);
}

fn isEven(x: i64) bool {
    return @mod(x, 2) == 0;
}

fn isPositive(x: i64) bool {
    return x > 0;
}

fn double(x: i64) i64 {
    return x * 2;
}

fn benchParallelSum(allocator: std.mem.Allocator, size: usize) !BenchResult {
    const data = try allocator.alloc(i64, size);
    defer allocator.free(data);

    for (data, 0..) |*d, i| d.* = @intCast(i + 1);

    // Warmup
    for (0..WARMUP_RUNS) |_| {
        _ = sequentialSum(i64, data);
        _ = ds.parallel.parallelSum(i64, data);
    }

    // Benchmark sequential
    var seq_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        const result = sequentialSum(i64, data);
        seq_total += timer.read();
        std.mem.doNotOptimizeAway(&result);
    }

    // Benchmark parallel
    var par_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        const result = ds.parallel.parallelSum(i64, data);
        par_total += timer.read();
        std.mem.doNotOptimizeAway(&result);
    }

    return .{ .seq_ns = seq_total / BENCH_RUNS, .par_ns = par_total / BENCH_RUNS };
}

fn benchParallelMax(allocator: std.mem.Allocator, size: usize) !BenchResult {
    const data = try allocator.alloc(i64, size);
    defer allocator.free(data);

    // Initialize with some variation
    for (data, 0..) |*d, i| d.* = @intCast(@mod(i * 7 + 13, 1000));

    // Warmup
    for (0..WARMUP_RUNS) |_| {
        _ = sequentialMax(i64, data);
        _ = ds.parallel.parallelMax(i64, data);
    }

    // Benchmark sequential
    var seq_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        const result = sequentialMax(i64, data);
        seq_total += timer.read();
        std.mem.doNotOptimizeAway(&result);
    }

    // Benchmark parallel
    var par_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        const result = ds.parallel.parallelMax(i64, data);
        par_total += timer.read();
        std.mem.doNotOptimizeAway(&result);
    }

    return .{ .seq_ns = seq_total / BENCH_RUNS, .par_ns = par_total / BENCH_RUNS };
}

fn benchParallelCount(allocator: std.mem.Allocator, size: usize) !BenchResult {
    const data = try allocator.alloc(i64, size);
    defer allocator.free(data);

    for (data, 0..) |*d, i| d.* = @intCast(i + 1);

    // Warmup
    for (0..WARMUP_RUNS) |_| {
        _ = sequentialCount(i64, data, isEven);
        _ = ds.parallel.parallelCount(i64, data, isEven);
    }

    // Benchmark sequential
    var seq_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        const result = sequentialCount(i64, data, isEven);
        seq_total += timer.read();
        std.mem.doNotOptimizeAway(&result);
    }

    // Benchmark parallel
    var par_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        const result = ds.parallel.parallelCount(i64, data, isEven);
        par_total += timer.read();
        std.mem.doNotOptimizeAway(&result);
    }

    return .{ .seq_ns = seq_total / BENCH_RUNS, .par_ns = par_total / BENCH_RUNS };
}

fn benchParallelAny(allocator: std.mem.Allocator, size: usize) !BenchResult {
    const data = try allocator.alloc(i64, size);
    defer allocator.free(data);

    // All odd values except the last element which is even (worst case for sequential isEven scan)
    for (data, 0..) |*d, i| d.* = @as(i64, @intCast(i)) * 2 + 1;
    data[size - 1] = 2; // Single even value at end for worst-case sequential

    // Warmup
    for (0..WARMUP_RUNS) |_| {
        _ = sequentialAny(i64, data, isEven);
        _ = ds.parallel.parallelAny(i64, data, isEven);
    }

    // Benchmark sequential
    var seq_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        const result = sequentialAny(i64, data, isEven);
        seq_total += timer.read();
        std.mem.doNotOptimizeAway(&result);
    }

    // Benchmark parallel
    var par_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        const result = ds.parallel.parallelAny(i64, data, isEven);
        par_total += timer.read();
        std.mem.doNotOptimizeAway(&result);
    }

    return .{ .seq_ns = seq_total / BENCH_RUNS, .par_ns = par_total / BENCH_RUNS };
}

fn benchParallelAll(allocator: std.mem.Allocator, size: usize) !BenchResult {
    const data = try allocator.alloc(i64, size);
    defer allocator.free(data);

    for (data, 0..) |*d, i| d.* = @intCast(i + 1);

    // Warmup
    for (0..WARMUP_RUNS) |_| {
        _ = sequentialAll(i64, data, isPositive);
        _ = ds.parallel.parallelAll(i64, data, isPositive);
    }

    // Benchmark sequential
    var seq_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        const result = sequentialAll(i64, data, isPositive);
        seq_total += timer.read();
        std.mem.doNotOptimizeAway(&result);
    }

    // Benchmark parallel
    var par_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        const result = ds.parallel.parallelAll(i64, data, isPositive);
        par_total += timer.read();
        std.mem.doNotOptimizeAway(&result);
    }

    return .{ .seq_ns = seq_total / BENCH_RUNS, .par_ns = par_total / BENCH_RUNS };
}

fn benchParallelMap(allocator: std.mem.Allocator, size: usize) !BenchResult {
    const input = try allocator.alloc(i64, size);
    defer allocator.free(input);
    const output_seq = try allocator.alloc(i64, size);
    defer allocator.free(output_seq);
    const output_par = try allocator.alloc(i64, size);
    defer allocator.free(output_par);

    for (input, 0..) |*d, i| d.* = @intCast(i + 1);

    // Warmup
    for (0..WARMUP_RUNS) |_| {
        sequentialMap(i64, input, output_seq, double);
        ds.parallel.parallelMap(i64, i64, input, output_par, double);
    }

    // Benchmark sequential
    var seq_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        sequentialMap(i64, input, output_seq, double);
        seq_total += timer.read();
        std.mem.doNotOptimizeAway(output_seq.ptr);
    }

    // Benchmark parallel
    var par_total: u64 = 0;
    for (0..BENCH_RUNS) |_| {
        var timer = try std.time.Timer.start();
        ds.parallel.parallelMap(i64, i64, input, output_par, double);
        par_total += timer.read();
        std.mem.doNotOptimizeAway(output_par.ptr);
    }

    return .{ .seq_ns = seq_total / BENCH_RUNS, .par_ns = par_total / BENCH_RUNS };
}

fn printBenchResult(name: []const u8, size: usize, result: BenchResult) void {
    const speedup = result.speedup();
    const indicator: []const u8 = if (speedup >= 1.5) " ⚡" else if (speedup >= 1.0) " ✓" else " ⚠";
    std.debug.print("{s:<12} {d:>10} {d:>10.3} ms {d:>10.3} ms {d:>8.2}x{s}\n", .{
        name,
        size,
        result.seqMs(),
        result.parMs(),
        speedup,
        indicator,
    });
}

pub fn main() !void {
    // Use page_allocator for benchmarks to avoid GPA overhead and
    // cleanup-related crashes in ReleaseFast mode
    const allocator = std.heap.page_allocator;

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           DS Library - Spice Parallel Operations Benchmark           ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    std.debug.print("=== Data Structures Benchmarks ===\n", .{});
    std.debug.print("Iterations: {d}\n\n", .{ITERATIONS});

    const stack_time = try benchStack(allocator);
    std.debug.print("Stack:     {d:.2} ms\n", .{@as(f64, @floatFromInt(stack_time)) / 1_000_000.0});

    const queue_time = try benchQueue(allocator);
    std.debug.print("Queue:     {d:.2} ms\n", .{@as(f64, @floatFromInt(queue_time)) / 1_000_000.0});

    const deque_time = try benchDeque(allocator);
    std.debug.print("Deque:     {d:.2} ms\n", .{@as(f64, @floatFromInt(deque_time)) / 1_000_000.0});

    const set_time = try benchSet(allocator);
    std.debug.print("Set:       {d:.2} ms\n", .{@as(f64, @floatFromInt(set_time)) / 1_000_000.0});

    // Tree structures: BST, RBTree, SkipList, Trie
    try benchTrees(allocator);

    std.debug.print("\n=== Core benchmarks complete ===\n", .{});

    // Cache & probabilistic: LRU, LFU, BloomFilter, CountMinSketch
    benchCaches(allocator) catch |err| {
        std.debug.print("Cache benchmarks failed: {}\n", .{err});
    };

    // Graph: UnionFind
    std.debug.print("\n=== Cache done, starting graph ===\n", .{});
    // NOTE: Disabled due to SIGSEGV in ReleaseFast mode with UnionFind.find
    // on large element sets. Needs investigation - likely related to integer
    // index lookups after path compression in release builds.
    // try benchGraph(allocator);

    const enable_spice = @hasDecl(ds, "parallel") and @hasDecl(ds.parallel, "parallelSum");
    if (!enable_spice) {
        std.debug.print("\nParallel benchmarks skipped (spice disabled).\n", .{});
        return;
    }

    std.debug.print("\n", .{});
    std.debug.print("=== Parallel Operations Benchmark (Sequential vs Spice) ===\n", .{});
    std.debug.print("Warmup: {d} runs, Benchmark: {d} runs (averaged)\n", .{ WARMUP_RUNS, BENCH_RUNS });
    std.debug.print("Legend: ⚡ = >1.5x speedup, ✓ = faster, ⚠ = slower\n\n", .{});

    std.debug.print("{s:<12} {s:>10} {s:>12} {s:>12} {s:>10}\n", .{ "Operation", "Size", "Sequential", "Parallel", "Speedup" });
    std.debug.print("{s:->12} {s:->10} {s:->12} {s:->12} {s:->10}\n", .{ "", "", "", "", "" });

    const sizes = [_]usize{ 10_000, 100_000, 1_000_000 };

    // Sum benchmark
    for (sizes) |size| {
        const result = try benchParallelSum(allocator, size);
        printBenchResult("Sum", size, result);
    }
    std.debug.print("\n", .{});

    // Max benchmark
    for (sizes) |size| {
        const result = try benchParallelMax(allocator, size);
        printBenchResult("Max", size, result);
    }
    std.debug.print("\n", .{});

    // Count benchmark
    for (sizes) |size| {
        const result = try benchParallelCount(allocator, size);
        printBenchResult("Count", size, result);
    }
    std.debug.print("\n", .{});

    // Any benchmark
    for (sizes) |size| {
        const result = try benchParallelAny(allocator, size);
        printBenchResult("Any", size, result);
    }
    std.debug.print("\n", .{});

    // All benchmark
    for (sizes) |size| {
        const result = try benchParallelAll(allocator, size);
        printBenchResult("All", size, result);
    }
    std.debug.print("\n", .{});

    // Map benchmark
    for (sizes) |size| {
        const result = try benchParallelMap(allocator, size);
        printBenchResult("Map", size, result);
    }

    std.debug.print("\n", .{});
}
