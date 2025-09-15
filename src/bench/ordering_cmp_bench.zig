const std = @import("std");

// Micro-benchmark for ordering comparator: previous vs index-based
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const N = 100000;

    // Generate random data
    var rng = std.rand.DefaultPrng.init(0);
    var data_old = try allocator.alloc(i32, N);
    var data_new = try allocator.alloc(i32, N);
    defer allocator.free(data_old);
    defer allocator.free(data_new);

    for (var i: usize = 0; i < N; i += 1) {
        data_old[i] = @intCast(i32, rng.random().int(i32));
        data_new[i] = data_old[i];
    }

    // Old comparator benchmark
    var old_count: usize = 0;
    const old_cmp = struct {
        pub var count_ptr: *usize;
        pub fn cmp(self: *const @This(), a: i32, b: i32) bool {
            self.count_ptr.* += 1;
            return a < b;
        }
    }{ .count_ptr = &old_count };

    const start_old = std.time.mono();
    std.sort.sort(i32, data_old, &old_cmp.cmp);
    const dur_old = std.time.mono().(std.time.Duration) - start_old;

    // New comparator benchmark (index-based)
    var new_count: usize = 0;
    const new_cmp = struct {
        pub var count_ptr: *usize;
        pub fn cmp(self: *const @This(), a: i32, b: i32) bool {
            self.count_ptr.* += 1;
            // simulate index-based comparator (identical logic)
            return a < b;
        }
    }{ .count_ptr = &new_count };

    const start_new = std.time.mono();
    std.sort.sort(i32, data_new, &new_cmp.cmp);
    const dur_new = std.time.mono().(std.time.Duration) - start_new;

    // Print results
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Old comparator: calls = {d}, time = {d} ns\n", .{old_count, dur_old.nano()});
    try stdout.print("New comparator: calls = {d}, time = {d} ns\n", .{new_count, dur_new.nano()});
}
