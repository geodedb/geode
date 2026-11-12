// SONNY-6375 (found by `test-startup-lazy-hydrate-tsan` under real TSan):
// `graph_store.getCurrentGlobalStore` tested `global_store != null` on the
// `?GraphStore` value, which copies the stored GraphStore's bytes (its live
// mutexes included) to compare the optional. A checkpoint reached from one
// graph's hydration called it while another thread locked
// `hydration_build_mutex`: a read of 8 bytes against an atomic write inside
// them. The persistence loop and `flushForCleanShutdown` did the same.
//
// One thread locks and unlocks a store mutex while another asks for the
// current global store; built with ThreadSanitizer in
// `test-sonny6375-global-store-race-tsan`, uninstrumented in the aggregate.
//
// CANARY: REQ=REQ-SONNY-6375-GLOBAL-STORE-NO-COPY; FEATURE="GraphStore"; ASPECT=GlobalStorePointerCheck; STATUS=TESTED; TEST=tests/test_sonny6375_global_store_race.zig; OWNER=storage; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;

const Locker = struct {
    store: *graph_store.GraphStore,
    stop: std.atomic.Value(bool) = .init(false),

    fn run(self: *Locker) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        var i: usize = 0;
        while (i < 20_000 and !self.stop.load(.acquire)) : (i += 1) {
            self.store.hydration_build_mutex.lockUncancelable(io);
            self.store.hydration_build_mutex.unlock(io);
        }
    }
};

test "SONNY-6375: getCurrentGlobalStore does not copy the store while another thread locks its mutexes" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const store = try graph_store.initGlobalStore(allocator, path);
    defer graph_store.deinitGlobalStore();

    var locker = Locker{ .store = store };
    const t = try std.Thread.spawn(.{}, Locker.run, .{&locker});
    var i: usize = 0;
    while (i < 20_000) : (i += 1) {
        const cur = graph_store.getCurrentGlobalStore() orelse {
            locker.stop.store(true, .release);
            t.join();
            return error.TestUnexpectedResult;
        };
        try testing.expect(cur == store);
    }
    locker.stop.store(true, .release);
    t.join();
}
