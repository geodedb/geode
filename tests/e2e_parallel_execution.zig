const std = @import("std");
const parallel = @import("geode").parallel_exec_stub;

fn sampleJob(ctx: ?*anyopaque) void {
    _ = ctx; // no-op
}

test "Parallel pool inert when disabled" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var pool = try parallel.Pool.init(gpa.allocator(), 2);
    defer pool.deinit();
    // Submitting while disabled should error
    try std.testing.expectError(error.FeatureDisabled, pool.submit(.{ .func = sampleJob, .ctx = null }));
}

test "Parallel ordered barrier deterministic" {
    var jobs = [_]parallel.Job{ .{ .func = sampleJob, .ctx = null }, .{ .func = sampleJob, .ctx = null } };
    parallel.orderedBarrier(&jobs);
    try std.testing.expect(true);
}

test "Parallel pool executes jobs when enabled via test override" {
    parallel.enableForTests();
    defer parallel.disableForTests();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var pool = try parallel.Pool.init(gpa.allocator(), 2);
    defer pool.deinit();
    var counter: usize = 0;
    const incr = struct {
        fn run(ctx: ?*anyopaque) void {
            const p: *usize = @ptrCast(@alignCast(ctx.?));
            p.* += 1;
        }
    }.run;
    try pool.submit(.{ .func = incr, .ctx = &counter });
    try pool.submit(.{ .func = incr, .ctx = &counter });
    pool.waitIdle();
    try std.testing.expect(counter == 2);
}

test "parallelMap produces deterministic ordered output" {
    parallel.enableForTests();
    defer parallel.disableForTests();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var pool = try parallel.Pool.init(gpa.allocator(), 4);
    defer pool.deinit();
    const N: usize = 8;
    const elem_size: usize = 8; // store u64
    const worker = struct {
        fn run(index: usize, dst: []u8, _: ?*anyopaque) void {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, @as(u64, @intCast(index * index + 1)), .little);
            @memcpy(dst, &buf);
        }
    }.run;
    const res = try parallel.parallelMap(gpa.allocator(), &pool, elem_size, N, worker, null);
    defer gpa.allocator().free(res.items);
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const slice = res.items[i * elem_size .. i * elem_size + elem_size];
        var arr: [8]u8 = undefined;
        @memcpy(&arr, slice);
        const got = std.mem.readInt(u64, &arr, .little);
        try std.testing.expect(got == i * i + 1);
    }
}
