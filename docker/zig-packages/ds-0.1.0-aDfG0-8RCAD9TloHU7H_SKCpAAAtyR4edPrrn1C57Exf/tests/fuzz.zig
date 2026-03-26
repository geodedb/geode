// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

// Property-based fuzz tests for ds data structures.
//
// Runs randomized invariant checks for Stack, Queue, BST, Set,
// LRU cache, BloomFilter, and Trie.  Uses a fixed seed so results
// are reproducible; memory-leak detection via GeneralPurposeAllocator.

const std = @import("std");
const ds = @import("ds");
const Order = std.math.Order;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const fixed_seed: u64 = 0xDEAD_BEEF_CAFE_BABE;

fn makeRng(extra: u64) std.Random.DefaultPrng {
    return std.Random.DefaultPrng.init(fixed_seed ^ extra);
}

fn reportResult(
    name: []const u8,
    ok: bool,
    passed: *usize,
    failed: *usize,
) void {
    if (ok) {
        passed.* += 1;
        std.debug.print("  PASS: {s}\n", .{name});
    } else {
        failed.* += 1;
        std.debug.print("  FAIL: {s}\n", .{name});
    }
}

// ---------------------------------------------------------------------------
// 1. Stack push/pop invariant
// ---------------------------------------------------------------------------

fn fuzzStackLifo(iterations: usize, passed: *usize, failed: *usize) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            std.debug.print("  LEAK detected in fuzzStackLifo\n", .{});
            failed.* += 1;
        }
    }
    const allocator = gpa.allocator();

    var ok = true;

    for (0..iterations) |iter| {
        var prng = makeRng(iter);
        const random = prng.random();

        var stack = ds.Stack(u32).init(allocator);
        defer stack.deinit();

        const n = random.intRangeAtMost(u32, 1, 200);
        var expected: std.ArrayListUnmanaged(u32) = .{};
        defer expected.deinit(allocator);

        // Push n random values
        for (0..n) |_| {
            const v = random.int(u32);
            stack.push(v) catch {
                ok = false;
                break;
            };
            expected.append(allocator, v) catch {
                ok = false;
                break;
            };
        }

        // Pop all and verify LIFO order
        var i: usize = expected.items.len;
        while (i > 0) {
            i -= 1;
            const popped = stack.pop();
            if (popped == null or popped.? != expected.items[i]) {
                ok = false;
                break;
            }
        }

        if (stack.pop() != null) {
            ok = false;
        }
    }

    reportResult("Stack LIFO ordering", ok, passed, failed);
}

fn fuzzStackLenConsistency(iterations: usize, passed: *usize, failed: *usize) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            std.debug.print("  LEAK detected in fuzzStackLenConsistency\n", .{});
            failed.* += 1;
        }
    }
    const allocator = gpa.allocator();

    var ok = true;

    for (0..iterations) |iter| {
        var prng = makeRng(iter +% 0x1111);
        const random = prng.random();

        var stack = ds.Stack(u32).init(allocator);
        defer stack.deinit();

        var expected_len: usize = 0;
        const ops = random.intRangeAtMost(u32, 10, 300);

        for (0..ops) |_| {
            const do_push = random.boolean();
            if (do_push or expected_len == 0) {
                stack.push(random.int(u32)) catch {
                    ok = false;
                    break;
                };
                expected_len += 1;
            } else {
                _ = stack.pop();
                expected_len -= 1;
            }
            if (stack.len() != expected_len) {
                ok = false;
                break;
            }
        }
    }

    reportResult("Stack length consistency", ok, passed, failed);
}

// ---------------------------------------------------------------------------
// 2. Queue enqueue/dequeue invariant
// ---------------------------------------------------------------------------

fn fuzzQueueFifo(iterations: usize, passed: *usize, failed: *usize) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            std.debug.print("  LEAK detected in fuzzQueueFifo\n", .{});
            failed.* += 1;
        }
    }
    const allocator = gpa.allocator();

    var ok = true;

    for (0..iterations) |iter| {
        var prng = makeRng(iter +% 0x2222);
        const random = prng.random();

        var queue = ds.Queue(u32).init(allocator);
        defer queue.deinit();

        const n = random.intRangeAtMost(u32, 1, 200);
        var expected: std.ArrayListUnmanaged(u32) = .{};
        defer expected.deinit(allocator);

        for (0..n) |_| {
            const v = random.int(u32);
            queue.enqueue(v) catch {
                ok = false;
                break;
            };
            expected.append(allocator, v) catch {
                ok = false;
                break;
            };
        }

        // Dequeue all and verify FIFO order
        for (expected.items) |exp| {
            const dequeued = queue.dequeue();
            if (dequeued == null or dequeued.? != exp) {
                ok = false;
                break;
            }
        }

        if (queue.dequeue() != null) {
            ok = false;
        }
    }

    reportResult("Queue FIFO ordering", ok, passed, failed);
}

// ---------------------------------------------------------------------------
// 3. BST ordering invariant
// ---------------------------------------------------------------------------

fn compareU32(a: u32, b: u32) Order {
    if (a < b) return .lt;
    if (a > b) return .gt;
    return .eq;
}

fn fuzzBstOrdering(iterations: usize, passed: *usize, failed: *usize) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            std.debug.print("  LEAK detected in fuzzBstOrdering\n", .{});
            failed.* += 1;
        }
    }
    const allocator = gpa.allocator();

    var ok = true;

    for (0..iterations) |iter| {
        var prng = makeRng(iter +% 0x3333);
        const random = prng.random();

        var bst = ds.BST(u32).init(allocator, compareU32);
        defer bst.deinit();

        const n = random.intRangeAtMost(u32, 1, 200);
        for (0..n) |_| {
            bst.insert(random.int(u32)) catch {
                ok = false;
                break;
            };
        }

        // Collect in-order traversal
        const Ctx = struct {
            list: *std.ArrayListUnmanaged(u32),
            alloc: std.mem.Allocator,
            err: bool,
        };

        var values: std.ArrayListUnmanaged(u32) = .{};
        defer values.deinit(allocator);

        var ctx = Ctx{ .list = &values, .alloc = allocator, .err = false };

        bst.inOrder(&ctx, struct {
            fn collect(c: *Ctx, value: u32) bool {
                c.list.append(c.alloc, value) catch {
                    c.err = true;
                    return false;
                };
                return true;
            }
        }.collect);

        if (ctx.err) {
            ok = false;
            continue;
        }

        // Verify sorted
        if (values.items.len > 1) {
            for (0..values.items.len - 1) |i| {
                if (values.items[i] > values.items[i + 1]) {
                    ok = false;
                    break;
                }
            }
        }
    }

    reportResult("BST in-order sorted", ok, passed, failed);
}

// ---------------------------------------------------------------------------
// 4. Set uniqueness invariant
// ---------------------------------------------------------------------------

fn fuzzSetUniqueness(iterations: usize, passed: *usize, failed: *usize) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            std.debug.print("  LEAK detected in fuzzSetUniqueness\n", .{});
            failed.* += 1;
        }
    }
    const allocator = gpa.allocator();

    var ok = true;

    for (0..iterations) |iter| {
        var prng = makeRng(iter +% 0x4444);
        const random = prng.random();

        var set = ds.Set(u16).init(allocator);
        defer set.deinit();

        // Use u16 range to force duplicates
        const n = random.intRangeAtMost(u32, 1, 500);

        // Track unique values with a separate std hash set
        var reference = std.AutoHashMap(u16, void).init(allocator);
        defer reference.deinit();

        for (0..n) |_| {
            const v = random.int(u16);
            set.add(v) catch {
                ok = false;
                break;
            };
            reference.put(v, {}) catch {
                ok = false;
                break;
            };
        }

        if (set.len() != reference.count()) {
            ok = false;
        }
    }

    reportResult("Set uniqueness count", ok, passed, failed);
}

// ---------------------------------------------------------------------------
// 5. LRU eviction invariant
// ---------------------------------------------------------------------------

fn fuzzLruEviction(iterations: usize, passed: *usize, failed: *usize) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            std.debug.print("  LEAK detected in fuzzLruEviction\n", .{});
            failed.* += 1;
        }
    }
    const allocator = gpa.allocator();

    var ok = true;

    for (0..iterations) |iter| {
        var prng = makeRng(iter +% 0x5555);
        const random = prng.random();

        const capacity = random.intRangeAtMost(usize, 2, 50);
        var lru = ds.LRU(u32, u32).init(allocator, capacity);
        defer lru.deinit();

        // Fill cache to capacity with keys 0..capacity-1
        for (0..capacity) |i| {
            const key: u32 = @intCast(i);
            lru.put(key, key *% 10) catch {
                ok = false;
                break;
            };
        }

        if (lru.len() != capacity) {
            ok = false;
            continue;
        }

        // Access a subset of existing keys to make them recently used.
        // We access keys 1..capacity-1, leaving key 0 as the LRU.
        for (1..capacity) |i| {
            const key: u32 = @intCast(i);
            _ = lru.get(key);
        }

        // Insert one new key -- should evict key 0 (the LRU)
        const new_key: u32 = @intCast(capacity);
        lru.put(new_key, 999) catch {
            ok = false;
            continue;
        };

        // Capacity should still match
        if (lru.len() != capacity) {
            ok = false;
            continue;
        }

        // Key 0 should have been evicted
        if (lru.get(0) != null) {
            ok = false;
            continue;
        }

        // The new key should be present
        if (lru.get(new_key) == null) {
            ok = false;
            continue;
        }
    }

    reportResult("LRU eviction of least-recently-used", ok, passed, failed);
}

// ---------------------------------------------------------------------------
// 6. BloomFilter no-false-negatives
// ---------------------------------------------------------------------------

fn fuzzBloomNoFalseNegatives(iterations: usize, passed: *usize, failed: *usize) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            std.debug.print("  LEAK detected in fuzzBloomNoFalseNegatives\n", .{});
            failed.* += 1;
        }
    }
    const allocator = gpa.allocator();

    var ok = true;

    for (0..iterations) |iter| {
        var prng = makeRng(iter +% 0x6666);
        const random = prng.random();

        // Use a generously sized filter to keep the test fast
        var bloom = ds.BloomFilter.init(allocator, 8192, 0.01, iter) catch {
            ok = false;
            continue;
        };
        defer bloom.deinit();

        const n = random.intRangeAtMost(u32, 1, 100);

        // Collect all inserted byte strings so we can verify later
        var inserted: std.ArrayListUnmanaged([8]u8) = .{};
        defer inserted.deinit(allocator);

        for (0..n) |_| {
            var buf: [8]u8 = undefined;
            random.bytes(&buf);
            bloom.add(&buf);
            inserted.append(allocator, buf) catch {
                ok = false;
                break;
            };
        }

        // Every inserted item must be reported as possibly present
        for (inserted.items) |*item| {
            if (!bloom.mightContain(item)) {
                ok = false;
                break;
            }
        }
    }

    reportResult("BloomFilter no false negatives", ok, passed, failed);
}

// ---------------------------------------------------------------------------
// 7. Trie prefix consistency
// ---------------------------------------------------------------------------

fn fuzzTriePrefixConsistency(iterations: usize, passed: *usize, failed: *usize) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            std.debug.print("  LEAK detected in fuzzTriePrefixConsistency\n", .{});
            failed.* += 1;
        }
    }
    const allocator = gpa.allocator();

    var ok = true;

    // Each iteration builds a trie with several random ASCII strings
    // and checks that every prefix of every inserted string returns
    // true from startsWith.
    const alphabet = "abcdefghijklmnopqrstuvwxyz";

    for (0..iterations) |iter| {
        var prng = makeRng(iter +% 0x7777);
        const random = prng.random();

        var trie = ds.Trie.init(allocator) catch {
            ok = false;
            continue;
        };
        defer trie.deinit();

        const n = random.intRangeAtMost(u32, 1, 30);

        var strings: std.ArrayListUnmanaged([]u8) = .{};
        defer {
            for (strings.items) |s| allocator.free(s);
            strings.deinit(allocator);
        }

        for (0..n) |idx| {
            const str_len = random.intRangeAtMost(usize, 1, 12);
            const buf = allocator.alloc(u8, str_len) catch {
                ok = false;
                break;
            };
            for (buf) |*ch| {
                ch.* = alphabet[random.uintLessThan(usize, alphabet.len)];
            }
            trie.insert(buf, idx) catch {
                allocator.free(buf);
                ok = false;
                break;
            };
            strings.append(allocator, buf) catch {
                allocator.free(buf);
                ok = false;
                break;
            };
        }

        // Verify all prefixes of every inserted string
        for (strings.items) |s| {
            for (1..s.len + 1) |prefix_len| {
                if (!(trie.startsWith(s[0..prefix_len]) catch false)) {
                    ok = false;
                    break;
                }
            }
            // Also check empty prefix (should always be true since root exists)
            if (!(trie.startsWith("") catch false)) {
                ok = false;
            }
        }
    }

    reportResult("Trie prefix consistency", ok, passed, failed);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() !void {
    const iterations: usize = 1000;
    var passed: usize = 0;
    var failed: usize = 0;

    std.debug.print("Running fuzz tests ({d} iterations each)...\n", .{iterations});

    fuzzStackLifo(iterations, &passed, &failed);
    fuzzStackLenConsistency(iterations, &passed, &failed);
    fuzzQueueFifo(iterations, &passed, &failed);
    fuzzBstOrdering(iterations, &passed, &failed);
    fuzzSetUniqueness(iterations, &passed, &failed);
    fuzzLruEviction(iterations, &passed, &failed);
    fuzzBloomNoFalseNegatives(iterations, &passed, &failed);
    fuzzTriePrefixConsistency(iterations, &passed, &failed);

    std.debug.print("\nFuzz results: {d} passed, {d} failed\n", .{ passed, failed });
    if (failed > 0) std.process.exit(1);
}
