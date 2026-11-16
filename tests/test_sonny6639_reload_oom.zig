// SONNY-6639: a reload (`GraphStore.loadFromFile`) that runs out of memory
// fails with the error; it never brings the server down.
//
// `loadFromFile` first resets the store (`clearNodes`), which registers the
// default graph again. Each of those allocations ended in `@panic` on
// OutOfMemory, so a reload under memory pressure crashed the process. Every
// allocation the reset makes is failed in turn (a `FailingAllocator` under a
// real store): the reload must fail with OutOfMemory, or succeed, and the
// store must be whole afterwards (its default graph registered, the node
// written before an aborted reset still there).
//
// `loadFromFile` also resets the lazy-hydration latches of every registered
// graph (`done`, `failed`); it left `needs_reset` (SONNY-6605: the last build
// failed transiently) as it was, so a graph the reload emptied kept the note.
//
// CANARY: REQ=REQ-SONNY-6639-RELOAD-OOM; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6639_reload_oom.zig; OWNER=storage; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;

test "SONNY-6639: a reload that runs out of memory resetting the store fails with OutOfMemory and leaves the store whole" {
    // No adapter in this test binary: the reload is the reset alone.
    try testing.expect(graph_store.getGlobalAdapter() == null);

    var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
    var store = try graph_store.GraphStore.init(fa.allocator());
    defer store.deinit();

    var failed: usize = 0;
    var k: usize = 0;
    while (k < 32) : (k += 1) {
        var labels = [_][]const u8{"R6639"};
        const id = try store.createNodeWithGraph(&labels, "default");

        fa.fail_index = fa.alloc_index + k;
        fa.has_induced_failure = false;
        const result = store.loadFromFile();
        const induced = fa.has_induced_failure;
        fa.fail_index = std.math.maxInt(usize);

        if (result) |_| {
            try testing.expect(!induced);
            try testing.expect(store.getNodePtr(id) == null);
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(induced);
            failed += 1;
            // The reset was refused before it changed anything.
            try testing.expect(store.getNodePtr(id) != null);
        }
        try testing.expect(store.graphExists("default"));
        if (!induced) break;
    }
    // Every allocation of the reset was failed once.
    try testing.expect(failed >= 4);
}

test "SONNY-6639: a reload clears needs_reset with the other hydration latches" {
    try testing.expect(graph_store.getGlobalAdapter() == null);

    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    try store.markPendingHydrationForTest("g6639");
    const entry = store.pending_hydration.get("g6639") orelse return error.TestUnexpectedResult;
    entry.done.store(true, .release);
    entry.failed.store(true, .release);
    entry.needs_reset = true;

    try store.loadFromFile();

    try testing.expect(!entry.done.load(.acquire));
    try testing.expect(!entry.failed.load(.acquire));
    try testing.expect(!entry.needs_reset);
}
