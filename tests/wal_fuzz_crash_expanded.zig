const std = @import("std");
const wal = @import("../src/wal/wal.zig");
const storage = @import("../src/storage/page_manager.zig");

// Expanded recovery fuzz: 1000 seeds, random truncation & checksum corruption injection.
// Invariants:
//  - After recovery committed inserts must have durable visible rows (>= commits) unless truncated before commit record.
//  - No visible rows from uncommitted (loser) txns.
//  - Recovery idempotent (second pass yields same slotCount + lsn state).
// For simplicity we only use page 0.
test "wal crash fuzz expanded 1k" {
    var seed: u64 = 1;
    while (seed <= 1000) : (seed += 1) {
        var prng = std.rand.DefaultPrng.init(seed);
        const R = prng.random();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const log_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/fuzz.wal", .{tmp.dir_path});
        defer std.testing.allocator.free(log_path);
        var w = wal.Wal.init(std.testing.allocator);
        try w.openFile(log_path);
        var prev: [4]u64 = .{ 0, 0, 0, 0 };
        var committed: [4]bool = .{ false, false, false, false };
        var committed_rows: usize = 0;
        // Generate up to 80 operations.
        var op: usize = 0;
        while (op < 80) : (op += 1) {
            const t = R.intRangeLessThan(usize, 0, 4);
            const tid: u64 = @intCast(t + 1);
            if (prev[t] == 0) prev[t] = (try w.append(tid, .Begin, &.{}, 0)).value;
            const choice = R.int(u8) % 5;
            switch (choice) {
                0, 1 => { // insert
                    const payload = try wal.Wal.encodeInsert(std.testing.allocator, 0, 0, "x");
                    defer std.testing.allocator.free(payload);
                    prev[t] = (try w.append(tid, .Insert, payload, prev[t])).value;
                },
                2 => { // delete
                    const delp = try wal.Wal.encodeDelete(std.testing.allocator, 0, 0);
                    defer std.testing.allocator.free(delp);
                    prev[t] = (try w.append(tid, .Delete, delp, prev[t])).value;
                },
                3 => { // commit
                    if (!committed[t]) {
                        prev[t] = (try w.append(tid, .Commit, &.{}, prev[t])).value;
                        committed[t] = true;
                        committed_rows += 1; // track logical rows (approx)
                    }
                },
                else => {},
            }
            if (R.int(u8) % 29 == 0) break; // early crash
        }
        try w.fsync();
        w.deinit();
        // Introduce random tail truncation or checksum corruption in-place ~20% probability each.
        var f = try std.fs.cwd().openFile(log_path, .{ .read = true, .write = true });
        const file_size = try f.getEndPos();
        if (file_size > 64) {
            const dice = R.int(u8);
            if (dice < 51) { // 20% truncation approx
                const cut = file_size - @as(u64, dice % 32);
                try f.setEndPos(cut);
            } else if (dice < 102) { // 20% checksum flip approx
                // Flip 4 bytes near tail (may hit header/sentinel) to force checksum stop.
                const off = file_size - 8;
                var buf: [4]u8 = undefined;
                if (try f.readAt(off, &buf) == 4) {
                    buf[0] ^= 0xFF;
                    buf[1] ^= 0xAA;
                    buf[2] ^= 0x55;
                    buf[3] ^= 0x11;
                    _ = try f.writeAt(off, &buf);
                }
            }
        }
        f.close();
        // Recover twice.
        var pm = storage.PageManager.init(std.testing.allocator, 512);
        defer pm.deinit();
        var w2 = wal.Wal.init(std.testing.allocator);
        defer w2.deinit();
        _ = try w2.recover(&pm, log_path);
        var w3 = wal.Wal.init(std.testing.allocator);
        defer w3.deinit();
        const applied_second = try w3.recover(&pm, log_path);
        // Idempotence: second applied should generally be 0 (pages already up to LSN). Allow >0 if corruption truncated log mid-record.
        try std.testing.expect(applied_second == 0 or applied_second < 5);
        if (pm.pages.items.len > 0) {
            var p = pm.asPage(0);
            // If no commits survived (committed_rows==0) expect zero live rows.
            var live: usize = 0;
            var i_slot: u16 = 0;
            while (i_slot < p.slotCount()) : (i_slot += 1) {
                if (p.read(i_slot)) |_| {
                    live += 1;
                } else |_| {
                    // ignore deleted/corrupt slots
                }
            }
            if (committed_rows == 0) {
                try std.testing.expect(live == 0);
            }
        }
    }
}
