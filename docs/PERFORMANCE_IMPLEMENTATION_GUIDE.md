# Performance Optimization Implementation Guide
**Quick Reference for Developers**

---

## Quick Start

This guide provides step-by-step implementation instructions for the performance optimizations identified in `PERFORMANCE_REVIEW_OCTOBER_2025.md`.

---

## Phase 1: Quick Wins (Start Here)

### Task 1.1: Replace allocPrint with Stack Buffers

**Files to modify**: `src/execution.zig`
**Estimated time**: 2-3 hours
**Impact**: 40-60% allocation reduction

**Pattern to find**:
```bash
grep -n "std.fmt.allocPrint" src/execution.zig
```

**Before**:
```zig
const op = try std.fmt.allocPrint(allocator, "IndexSeek (cost: {})", .{index_cost});
```

**After**:
```zig
var buf: [256]u8 = undefined; // Adjust size as needed
const op_str = try std.fmt.bufPrint(&buf, "IndexSeek (cost: {})", .{index_cost});
const op = try allocator.dupe(u8, op_str);
```

**Testing**:
```bash
zig build test
make verify-fast
```

---

### Task 1.2: Pre-size ArrayList Capacities

**Files to modify**: `src/execution.zig` (lines 2008, 2098, 2150)
**Estimated time**: 1 hour
**Impact**: 50-70% fewer reallocations

**Pattern to find**:
```bash
grep -n "initCapacity(allocator, 0)" src/execution.zig
```

**Before**:
```zig
var result_rows = try std.ArrayList([]eval.Value).initCapacity(allocator, 0);
```

**After**:
```zig
// Use known size or reasonable estimate
const estimated_size = items.items.len; // or another heuristic
var result_rows = try std.ArrayList([]eval.Value).initCapacity(allocator, estimated_size);
```

**Testing**:
```bash
zig build test
# Run specific execution tests
zig test src/execution.zig
```

---

### Task 1.3: SIMD for Cosine/Dot Distance

**Files to modify**: `src/index/hnsw.zig` (lines 120-147)
**Estimated time**: 3-4 hours
**Impact**: 3-4x faster ML queries

**Implementation**:
```zig
fn distanceSimd(self: *const Hnsw, a: []const f32, b: []const f32, metric: DistanceMetric) f64 {
    // Check alignment and size
    if (a.len != b.len or a.len % 4 != 0) {
        return self.distance(a, b, metric); // Fallback
    }

    const VecType = @Vector(4, f32);
    const n_vecs = a.len / 4;

    switch (metric) {
        .l2 => {
            // Existing SIMD implementation
            // ...
        },
        .cosine => {
            var dot_vec: VecType = @splat(0);
            var norm_a_vec: VecType = @splat(0);
            var norm_b_vec: VecType = @splat(0);

            var i: usize = 0;
            while (i < n_vecs) : (i += 1) {
                const a_vec: VecType = a[i * 4 ..][0..4].*;
                const b_vec: VecType = b[i * 4 ..][0..4].*;
                dot_vec += a_vec * b_vec;
                norm_a_vec += a_vec * a_vec;
                norm_b_vec += b_vec * b_vec;
            }

            const dot: f32 = @reduce(.Add, dot_vec);
            const norm_a: f32 = @sqrt(@reduce(.Add, norm_a_vec));
            const norm_b: f32 = @sqrt(@reduce(.Add, norm_b_vec));

            if (norm_a == 0 or norm_b == 0) return 1.0;
            const similarity = dot / (norm_a * norm_b);
            return 1.0 - similarity;
        },
        .dot => {
            var sum_vec: VecType = @splat(0);
            var i: usize = 0;
            while (i < n_vecs) : (i += 1) {
                const a_vec: VecType = a[i * 4 ..][0..4].*;
                const b_vec: VecType = b[i * 4 ..][0..4].*;
                sum_vec += a_vec * b_vec;
            }
            return -@reduce(.Add, sum_vec);
        },
        else => return self.distance(a, b, metric),
    }
}
```

**Testing**:
```bash
# Run HNSW tests
zig test src/index/hnsw.zig

# Benchmark vector operations
# (Add benchmark in test section)
```

---

### Task 1.4: Cache IndexInfo Structures

**Files to modify**: `src/server/index_optimizer.zig` (line 295)
**Estimated time**: 2 hours
**Impact**: 40-50% faster query planning

**Implementation**:
```zig
// Add to IndexOptimizer struct
pub const IndexOptimizer = struct {
    allocator: std.mem.Allocator,
    index_info_cache: std.StringHashMap(IndexInfo),

    pub fn init(allocator: std.mem.Allocator) IndexOptimizer {
        return .{
            .allocator = allocator,
            .index_info_cache = std.StringHashMap(IndexInfo).init(allocator),
        };
    }

    pub fn deinit(self: *IndexOptimizer) void {
        // Free cached index info
        var it = self.index_info_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.name) |name| {
                self.allocator.free(name);
            }
        }
        self.index_info_cache.deinit();
    }

    fn findBestIndexForProperty(...) ?*const IndexInfo {
        // Build cache key
        var cache_key_buf: [512]u8 = undefined;
        const cache_key_str = std.fmt.bufPrint(&cache_key_buf, "{s}.{s}", .{label, property}) catch return null;

        // Check cache
        if (self.index_info_cache.getPtr(cache_key_str)) |cached| {
            return cached;
        }

        // Build IndexInfo (existing code)
        const index_info = IndexInfo{
            .name = try self.allocator.dupe(u8, index_name),
            // ...
        };

        // Cache it
        const cache_key_owned = try self.allocator.dupe(u8, cache_key_str);
        try self.index_info_cache.put(cache_key_owned, index_info);

        return self.index_info_cache.getPtr(cache_key_owned);
    }
};
```

**Testing**:
```bash
zig test src/server/index_optimizer.zig
make test
```

---

## Phase 2: Storage Optimization

### Task 2.1: Implement Write Batching

**Files to modify**: `src/storage/page_manager.zig` (lines 401-432)
**Estimated time**: 1 week
**Impact**: 13-20x bulk write throughput
**Risk**: MEDIUM - requires careful testing

**Implementation approach**:

1. **Add dirty page tracking**:
```zig
pub const PageManager = struct {
    // ... existing fields
    dirty_pages: std.ArrayList(u32),
    dirty_page_threshold: usize = 64,

    pub fn markDirty(self: *PageManager, page_id: u32) !void {
        try self.dirty_pages.append(page_id);
        if (self.dirty_pages.items.len >= self.dirty_page_threshold) {
            try self.flushDirtyPages();
        }
    }
};
```

2. **Implement batch flush**:
```zig
fn flushDirtyPages(self: *PageManager) !void {
    if (self.dirty_pages.items.len == 0) return;

    // Sort pages for sequential I/O
    std.mem.sort(u32, self.dirty_pages.items, {}, comptime std.sort.asc(u32));

    // Write all pages
    for (self.dirty_pages.items) |page_id| {
        const page = self.pages.get(page_id) orelse continue;
        try self.writePageNoBatch(page_id, page);
    }

    // Single fsync for all pages
    try self.data_file.sync();

    self.dirty_pages.clearRetainingCapacity();
}
```

3. **Add feature flag**:
```zig
const enable_batching = @import("builtin").mode == .ReleaseFast;

pub fn writePage(self: *PageManager, page_id: u32, page: *Page) !void {
    if (enable_batching) {
        try self.markDirty(page_id);
    } else {
        try self.writePageNoBatch(page_id, page);
        try self.data_file.sync();
    }
}
```

**Testing**:
```bash
# Run with and without batching
zig build -Doptimize=ReleaseFast test
# Run geodetestlab suite
python3 extended_test_runner.py
```

---

### Task 2.2: Dirty Page Checksum Optimization

**Files to modify**: `src/storage/page_manager.zig` (lines 68-101, 409)
**Estimated time**: 2-3 hours
**Impact**: 70-90% fewer checksum computations

**Implementation**:
```zig
pub const Page = struct {
    buf: []u8,
    checksum_valid: bool = false,
    cached_checksum: u32 = 0,

    pub fn markDirty(self: *Page) void {
        self.checksum_valid = false;
    }

    pub fn markClean(self: *Page) void {
        self.checksum_valid = true;
    }

    fn recomputeChecksum(self: *Page) void {
        if (self.checksum_valid) {
            // Write cached checksum
            std.mem.writeInt(u32, self.buf[ChecksumOffset .. ChecksumOffset + 4],
                            self.cached_checksum, .little);
            return;
        }

        // Compute new checksum
        std.mem.writeInt(u32, self.buf[ChecksumOffset .. ChecksumOffset + 4], 0, .little);
        const cs = adler32(self.buf);
        std.mem.writeInt(u32, self.buf[ChecksumOffset .. ChecksumOffset + 4], cs, .little);

        self.cached_checksum = cs;
        self.checksum_valid = true;
    }
};
```

**Usage pattern**:
```zig
// When modifying page data
page.markDirty();
page.buf[offset] = value;

// When flushing
page.recomputeChecksum(); // Only recomputes if dirty
```

**Testing**:
```bash
zig test src/storage/page_manager.zig
```

---

### Task 2.3: Pre-compute Encryption Keys

**Files to modify**: `src/storage/crypto.zig` (line 140)
**Estimated time**: 3-4 hours
**Impact**: 5-10x faster for hot pages

**Implementation**:
```zig
pub const StorageEncryption = struct {
    master_key: EncryptionKey,
    data_keys: std.AutoHashMap(u32, EncryptionKey),
    key_cache: [1024]EncryptionKey, // First 1024 pages
    cache_initialized: bool = false,

    pub fn init(allocator: std.mem.Allocator, master_key: EncryptionKey) !Self {
        var self = Self{
            .master_key = master_key,
            .data_keys = std.AutoHashMap(u32, EncryptionKey).init(allocator),
            .key_cache = undefined,
            .cache_initialized = false,
        };

        // Pre-derive common page keys
        for (0..1024) |page_id| {
            self.key_cache[page_id] = try derivePageKey(master_key, @intCast(page_id));
        }
        self.cache_initialized = true;

        return self;
    }

    fn getDataKey(self: *Self, page_id: u32) !EncryptionKey {
        // Fast path: cached pages
        if (page_id < 1024) {
            return self.key_cache[page_id];
        }

        // Slow path: HashMap lookup
        if (self.data_keys.get(page_id)) |key| {
            return key;
        }

        // Derive and cache
        const key = try derivePageKey(self.master_key, page_id);
        try self.data_keys.put(page_id, key);
        return key;
    }
};
```

**Testing**:
```bash
zig test src/storage/crypto.zig
# Run encryption benchmarks
```

---

### Task 2.4: Optimize Adler32

**Files to modify**: `src/storage/page_manager.zig` (lines 19-27)
**Estimated time**: 1 hour
**Impact**: 2-3x faster checksums

**Implementation**: (See detailed code in main review document)

**Testing**:
```bash
# Add test to verify correctness
test "adler32 optimization correctness" {
    const data = "The quick brown fox jumps over the lazy dog";
    const expected: u32 = 0x5bdc0fda; // Known checksum

    const result = adler32(data);
    try testing.expectEqual(expected, result);
}
```

---

## Phase 3: Concurrency & Memory

### Task 3.1: Replace Catalog Mutex with RWLock

**Files to modify**: `src/execution.zig` (lines 15-16, 52-90, 2247-2262)
**Estimated time**: 4-6 hours
**Impact**: Eliminates concurrent query planning contention

**Implementation**:
```zig
// Replace
var catalog_mutex = std.Thread.Mutex{};

// With
var catalog_rwlock = std.Thread.RwLock{};

// Update all usage sites
// Read operations (most common)
catalog_rwlock.lockShared();
defer catalog_rwlock.unlockShared();

// Write operations (CREATE INDEX, etc.)
catalog_rwlock.lock();
defer catalog_rwlock.unlock();
```

**Testing**:
```bash
# Run concurrent query tests
# Add test with multiple threads doing reads
```

---

### Task 3.2: Implement Value Object Pooling

**Files to modify**: `src/eval.zig` (lines 103-119, 299-400)
**Estimated time**: 1-2 weeks
**Impact**: 2-3x faster nested expressions
**Risk**: MEDIUM - lifecycle management complexity

**Note**: This is a complex refactor requiring careful design. Consider starting with a prototype.

---

## Verification Checklist

After each phase, verify:

- ✅ All tests pass: `make test`
- ✅ GQL compliance maintained: Check geodetestlab results
- ✅ No memory leaks: Run with GPA in debug mode
- ✅ Performance improved: Run benchmarks
- ✅ Documentation updated

---

## Performance Benchmarking

### Setup Baseline

Before starting optimizations:

```bash
# Run current performance baseline
zig build -Doptimize=ReleaseFast

# Run geodetestlab with timing
python3 extended_test_runner.py --timing > baseline_results.txt

# Create benchmark suite
zig test src/benchmarks.zig
```

### Measure Improvements

After each phase:

```bash
# Run optimized build
zig build -Doptimize=ReleaseFast

# Compare results
python3 extended_test_runner.py --timing > phase1_results.txt
diff baseline_results.txt phase1_results.txt
```

---

## Need Help?

**Documentation**:
- Main review: `docs/PERFORMANCE_REVIEW_OCTOBER_2025.md`
- Zig performance guide: https://zig.guide/standard-library/allocators
- SIMD guide: https://zig.news/sobeston/simd-in-zig-easy-intel-avx-512-4ee8

**Testing**:
```bash
# Run all tests
make test

# Run specific file
zig test src/path/to/file.zig

# Build with optimizations
zig build -Doptimize=ReleaseFast
```

---

**Last Updated**: October 16, 2025
**Status**: Ready for Implementation
