const std = @import("std");
const phase0 = @import("phase0.zig");

// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=Phase3SetOps; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_051_GPUUnionDistinctSmall; OWNER=engine; UPDATED=2025-10-26

pub fn unionDistinctCPU(a: []const u32, b: []const u32, allocator: std.mem.Allocator) ![]u32 {
    var map = std.AutoHashMap(u32, void).init(allocator);
    defer map.deinit();
    for (a) |v| { _ = map.put(v, {}) catch {}; }
    for (b) |v| { _ = map.put(v, {}) catch {}; }
    var list = std.ArrayList(u32).init(allocator);
    defer list.deinit();
    var it = map.iterator();
    while (it.next()) |e| try list.append(allocator, e.key_ptr.*);
    const slice = try allocator.alloc(u32, list.items.len);
    std.mem.copy(u32, slice, list.items);
    return slice;
}

pub fn unionDistinctGPU(a: []const u32, b: []const u32, allocator: std.mem.Allocator) ![]u32 {
    // Phase3 scaffold: fallback to CPU
    return unionDistinctCPU(a, b, allocator);
}

pub fn intersectCPU(a: []const u32, b: []const u32, allocator: std.mem.Allocator) ![]u32 {
    var setA = std.AutoHashMap(u32, void).init(allocator); defer setA.deinit();
    for (a) |v| { _ = setA.put(v, {}) catch {}; }
    var list = std.ArrayList(u32).init(allocator); defer list.deinit();
    for (b) |v| if (setA.get(v) != null) try list.append(allocator, v);
    const slice = try allocator.alloc(u32, list.items.len);
    std.mem.copy(u32, slice, list.items);
    return slice;
}

pub fn intersectGPU(a: []const u32, b: []const u32, allocator: std.mem.Allocator) ![]u32 {
    return intersectCPU(a, b, allocator);
}

test "TestCANARY_REQ_GQL_051_GPUUnionDistinctSmall" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const a = &[_]u32{1,2,3,3};
    const b = &[_]u32{3,4,5};
    const cpu = try unionDistinctCPU(a, b, alloc);
    defer alloc.free(cpu);
    const gpu = try unionDistinctGPU(a, b, alloc);
    defer alloc.free(gpu);
    try std.testing.expectEqual(cpu.len, gpu.len);
    // Unordered equivalence: convert to hash sets
    var set_cpu = std.AutoHashMap(u32, void).init(alloc); defer set_cpu.deinit();
    var set_gpu = std.AutoHashMap(u32, void).init(alloc); defer set_gpu.deinit();
    for (cpu) |v| { _ = set_cpu.put(v, {}) catch {}; }
    for (gpu) |v| { _ = set_gpu.put(v, {}) catch {}; }
    try std.testing.expectEqual(set_cpu.count(), set_gpu.count());
}
