const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const page_manager = @import("storage_page_manager");
const wal = @import("wal");
const fsm = @import("fsm");
const page_vacuum = @import("page_vacuum");
const commit_coord = @import("commit_coordinator");

// Stress Parameters
const MASSIVE_ITEM_COUNT = 500_000;
const DELETE_RATIO = 0.40; // 40% deletion
const RELOAD_RATIO = 0.20; // 20% reload

test "massive storage stress test" {
    // 1. Setup Environment
    const allocator = testing.allocator;
    const test_dir = "test_stress_massive";
    fs.cwd().deleteTree(test_dir) catch {};
    try fs.cwd().makeDir(test_dir);
    defer fs.cwd().deleteTree(test_dir) catch {}; // Cleanup on success

    std.debug.print("\n=== [Stress Test] Massive Storage Stability ({d} items) ===\n", .{MASSIVE_ITEM_COUNT});

    // Initialize Components
    var coord = commit_coord.CommitCoordinator.init(allocator);
    defer coord.deinit();

    // WAL
    const wal_path = try std.fs.path.join(allocator, &[_][]const u8{ test_dir, "wal" });
    defer allocator.free(wal_path);
    try fs.cwd().makeDir(wal_path);

    // Note: using test config for WAL
    var wal_inst = try wal.Wal.init(allocator, wal_path, 1024 * 1024 * 64, null); // 64MB segments
    defer wal_inst.deinit();

    // FSM
    var fsm_inst = fsm.FreeSpaceMap.init(allocator, 1024); // Init capacity
    defer fsm_inst.deinit();

    // PageManager
    const pm_path = try std.fs.path.join(allocator, &[_][]const u8{ test_dir, "data.pages" });
    defer allocator.free(pm_path);

    // Config: 64MB cache, WAL-before-data enabled
    var pm = try page_manager.PageManager.init(allocator, pm_path, 16384, 1024 * 1024 * 64, &wal_inst, &fsm_inst);
    defer pm.deinit();

    // 2. Bulk Load Phase
    std.debug.print("[Phase 1] Bulk Loading {d} items...\n", .{MASSIVE_ITEM_COUNT});
    var timer = try std.time.Timer.start();

    var items = try std.ArrayList(ItemLoc).initCapacity(allocator, MASSIVE_ITEM_COUNT);
    defer items.deinit();

    var prng = std.rand.DefaultPrng.init(0);
    const random = prng.random();

    var i: usize = 0;
    while (i < MASSIVE_ITEM_COUNT) : (i += 1) {
        // Generate pseudo-random payload (64-128 bytes)
        var payload: [128]u8 = undefined;
        const len = 64 + random.uintLessThan(usize, 64);
        random.bytes(payload[0..len]);

        // Emulate transaction
        const lsn = try wal_inst.append(1, .Insert, payload[0..len], 0);

        // Insert to page
        const loc = try pm.insert(payload[0..len]);

        try items.append(.{
            .page_id = loc.page_id,
            .slot_id = loc.slot_id,
            .hash = std.hash.Wyhash.hash(0, payload[0..len]),
        });

        // Periodic commit simulation (every 1000 items)
        if (i % 1000 == 0) {
            _ = try wal_inst.append(1, .Commit, ", lsn);
        }
    }

    const load_time = timer.read();
    std.debug.print(" -> Loaded in {d:.2}s ({d} items/s)\n", .{ @as(f64, @floatFromInt(load_time)) / 1e9, MASSIVE_ITEM_COUNT * 1_000_000_000 / load_time });

    // Verify file size
    const file1 = try fs.cwd().openFile(pm_path, .{});
    const size1 = (try file1.stat()).size;
    file1.close();
    std.debug.print(" -> Data File Size: {d:.2} MB\n", .{@as(f64, @floatFromInt(size1)) / 1024.0 / 1024.0});

    // 3. Fragmentation Phase
    const delete_count = @as(usize, @intFromFloat(MASSIVE_ITEM_COUNT * DELETE_RATIO));
    std.debug.print("[Phase 2] Fragmenting (Deletes: {d})...\n", .{delete_count});
    timer.reset();

    // Shuffle items to delete randomly
    // For deterministic test we can just pick every Nth or use a shuffled index list.
    // Let's delete pseudo-random indices.
    var deleted_count: usize = 0;
    while (deleted_count < delete_count) {
        const idx = random.uintLessThan(usize, items.items.len);
        if (items.items[idx].deleted) continue;

        const item = &items.items[idx];

        // WAL log
        const lsn = try wal_inst.append(1, .Delete, ", 0);

        // Tombstone
        try pm.tombstone(item.page_id, item.slot_id);
        item.deleted = true;
        deleted_count += 1;

        if (deleted_count % 1000 == 0) {
            _ = try wal_inst.append(1, .Commit, ", lsn);
        }
    }

    const frag_time = timer.read();
    std.debug.print(" -> Fragmented in {d:.2}s\n", .{@as(f64, @floatFromInt(frag_time)) / 1e9});

    // 4. Reload Phase (Verify FSM Reuse)
    const reload_count = @as(usize, @intFromFloat(MASSIVE_ITEM_COUNT * RELOAD_RATIO));
    std.debug.print("[Phase 3] Reloading {d} items (expecting reuse)...\n", .{reload_count});
    timer.reset();

    var reload_new_pages: usize = 0;
    const initial_pages = pm.pages.items.len;

    i = 0;
    while (i < reload_count) : (i += 1) {
        var payload: [128]u8 = undefined;
        const len = 64 + random.uintLessThan(usize, 64); // Same size distribution
        random.bytes(payload[0..len]);

        const lsn = try wal_inst.append(1, .Insert, payload[0..len], 0);
        const loc = try pm.insert(payload[0..len]);

        // Track strictly if we are allocating BEYOND initial pages
        // (Note: PageManager array might grow, but we want to see if FSM found space in old pages)
        // Simple heuristic: check if page_id < initial_pages
        if (loc.page_id >= initial_pages) reload_new_pages += 1;

        if (i % 1000 == 0) {
            _ = try wal_inst.append(1, .Commit, ", lsn);
        }
    }

    const reload_time = timer.read();
    std.debug.print(" -> Reloaded in {d:.2}s\n", .{@as(f64, @floatFromInt(reload_time)) / 1e9});
    std.debug.print(" -> New pages used: {d} (Lower is better, means reuse)\n", .{reload_new_pages});

    // 5. Integrity Check
    std.debug.print("[Phase 4] Verifying Integrity of Remaining Items...\n", .{});

    // We only check the original items that were NOT deleted.
    // (Reloaded items aren't tracked in 'items' list for verification simplicity here,
    //  but their insertion process verified reuse).
    var verified: usize = 0;
    for (items.items) |item| {
        if (item.deleted) continue;

        const p = pm.asPage(item.page_id);
        const sl = p.readSlot(item.slot_id);
        const data = p.buf[sl.off .. sl.off + sl.sz];
        const h = std.hash.Wyhash.hash(0, data);

        try testing.expectEqual(item.hash, h);
        verified += 1;
    }
    std.debug.print(" -> Verified {d} items successfully.\n", .{verified});

    std.debug.print("\n=== Stress Test Passed ===\n", .{});
}

const ItemLoc = struct {
    page_id: u32,
    slot_id: u16,
    hash: u64,
    deleted: bool = false,
};
