const std = @import("std");
const builtin = @import("builtin");

fn getStdOut() std.fs.File {
    if (builtin.os.tag == .windows) {
        return std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable };
    } else {
        return std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    }
}
const fs = std.fs;
const geode = @import("geode");
const page_manager = geode.storage.page_manager;
const wal = geode.storage.wal;
const fsm = @import("fsm");
const page_vacuum = @import("page_vacuum");
const commit_coord = @import("commit_coord");

pub const StressConfig = struct {
    item_count: usize = 100_000,
    delete_ratio: f64 = 0.40,
    reload_ratio: f64 = 0.20,
    work_dir: []const u8,
    verbose: bool = false,
};

pub fn run(allocator: std.mem.Allocator, config: StressConfig) !void {
    const stdout = getStdOut().writer();

    if (config.verbose) try stdout.print("\n=== Storage Stress Test ({d} items) ===\n", .{config.item_count});
    if (config.verbose) try stdout.print("Work Dir: {s}\n", .{config.work_dir});

    // Cleanup first
    fs.cwd().deleteTree(config.work_dir) catch {};
    try fs.cwd().makePath(config.work_dir);
    // defer fs.cwd().deleteTree(config.work_dir) catch {}; // Keep for inspection if manual, or optional cleanup

    // Initialize Components
    var coord = commit_coord.CommitCoordinator.init(allocator);
    defer coord.deinit();

    // WAL
    const wal_path = try std.fs.path.join(allocator, &[_][]const u8{ config.work_dir, "wal" });
    defer allocator.free(wal_path);
    try fs.cwd().makeDir(wal_path);

    // Config: 64MB segments
    var wal_inst = try wal.Wal.init(allocator, wal_path, 1024 * 1024 * 64, null);
    defer wal_inst.deinit();

    // FSM
    var fsm_inst = fsm.FreeSpaceMap.init(allocator, 1024);
    defer fsm_inst.deinit();

    // PageManager
    const pm_path = try std.fs.path.join(allocator, &[_][]const u8{ config.work_dir, "data.pages" });
    defer allocator.free(pm_path);

    var pm = try page_manager.PageManager.init(allocator, pm_path, 16384, 1024 * 1024 * 64, &wal_inst, &fsm_inst);
    defer pm.deinit();

    // 1. Bulk Load
    if (config.verbose) try stdout.print("[1/4] Bulk Loading...\n", .{});
    var timer = try std.time.Timer.start();

    var items = try std.ArrayList(ItemLoc).initCapacity(allocator, config.item_count);
    defer items.deinit();

    var prng = std.rand.DefaultPrng.init(0);
    const random = prng.random();

    var i: usize = 0;
    while (i < config.item_count) : (i += 1) {
        var payload: [128]u8 = undefined;
        const len = 64 + random.uintLessThan(usize, 64);
        random.bytes(payload[0..len]);

        const lsn = try wal_inst.append(1, .Insert, payload[0..len], 0);
        const loc = try pm.insert(payload[0..len]);

        try items.append(.{
            .page_id = loc.page_id,
            .slot_id = loc.slot_id,
            .hash = std.hash.Wyhash.hash(0, payload[0..len]),
        });

        if (i % 1000 == 0) {
            _ = try wal_inst.append(1, .Commit, "", lsn);
        }
    }

    const load_time = timer.read();
    if (config.verbose) try stdout.print(" -> {d:.2}s ({d} ops/s)\n", .{ @as(f64, @floatFromInt(load_time)) / 1e9, config.item_count * 1_000_000_000 / load_time });

    // 2. Fragmentation
    const delete_count = @as(usize, @intFromFloat(@as(f64, @floatFromInt(config.item_count)) * config.delete_ratio));
    if (config.verbose) try stdout.print("[2/4] Fragmenting (Delete {d})...\n", .{delete_count});
    timer.reset();

    var deleted_count: usize = 0;
    while (deleted_count < delete_count) {
        const idx = random.uintLessThan(usize, items.items.len);
        if (items.items[idx].deleted) continue;

        const item = &items.items[idx];
        const lsn = try wal_inst.append(1, .Delete, "", 0);
        try pm.tombstone(item.page_id, item.slot_id);
        item.deleted = true;
        deleted_count += 1;

        if (deleted_count % 1000 == 0) {
            _ = try wal_inst.append(1, .Commit, "", lsn);
        }
    }

    const frag_time = timer.read();
    if (config.verbose) try stdout.print(" -> {d:.2}s\n", .{@as(f64, @floatFromInt(frag_time)) / 1e9});

    // 3. Reload
    const reload_count = @as(usize, @intFromFloat(@as(f64, @floatFromInt(config.item_count)) * config.reload_ratio));
    if (config.verbose) try stdout.print("[3/4] Reloading {d} items...\n", .{reload_count});
    timer.reset();

    var reload_new_pages: usize = 0;
    const initial_pages = pm.pages.items.len;

    i = 0;
    while (i < reload_count) : (i += 1) {
        var payload: [128]u8 = undefined;
        const len = 64 + random.uintLessThan(usize, 64);
        random.bytes(payload[0..len]);

        const lsn = try wal_inst.append(1, .Insert, payload[0..len], 0);
        const loc = try pm.insert(payload[0..len]);

        if (loc.page_id >= initial_pages) reload_new_pages += 1;

        if (i % 1000 == 0) {
            _ = try wal_inst.append(1, .Commit, "", lsn);
        }
    }
    const reload_time = timer.read();
    if (config.verbose) try stdout.print(" -> {d:.2}s\n", .{@as(f64, @floatFromInt(reload_time)) / 1e9});
    if (config.verbose) try stdout.print(" -> Expansion: {d} pages (reuse efficiency: {d}%)\n", .{ reload_new_pages, (1.0 - @as(f64, @floatFromInt(reload_new_pages)) / @as(f64, @floatFromInt(reload_count))) * 100.0 });

    // 4. Integrity
    if (config.verbose) try stdout.print("[4/4] Verifying Integrity...\n", .{});
    var verified: usize = 0;
    for (items.items) |item| {
        if (item.deleted) continue;
        const p = pm.asPage(item.page_id);
        const sl = p.readSlot(item.slot_id);
        const data = p.buf[sl.off .. sl.off + sl.sz];
        const h = std.hash.Wyhash.hash(0, data);
        if (item.hash != h) return error.DataCorruption;
        verified += 1;
    }
    if (config.verbose) try stdout.print(" -> Verified {d} items OK.\n", .{verified});
}

const ItemLoc = struct {
    page_id: u32,
    slot_id: u16,
    hash: u64,
    deleted: bool = false,
};
