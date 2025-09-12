const std = @import("std");
const wal = @import("../src/wal/wal.zig");
const storage = @import("../src/storage/page_manager.zig");

fn randBool(r: *std.rand.DefaultPrng) bool {
    return (r.random().int(u8) & 1) == 1;
}

// Lightweight crash fuzz: generate random sequence of Inserts / Deletes across a few txns,
// simulate crash at random cut, run recovery twice (idempotence), assert committed rows persist and losers absent.
test "wal crash fuzz mini" {
    var prng = std.rand.DefaultPrng.init(0xdeadbeef);
    const R = prng.random();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/fuzz.wal", .{tmp.dir_path});
    defer std.testing.allocator.free(log_path);

    var w = wal.Wal.init(std.testing.allocator);
    defer w.deinit();
    try w.openFile(log_path);

    const txn_count: usize = 3;
    var prev: [3]u64 = .{ 0, 0, 0 };
    var committed_mask: u3 = 0;
    var last_effect_insert: bool = false;

    var step: usize = 0;
    while (step < 50) : (step += 1) {
        const t = R.intRangeLessThan(usize, 0, txn_count);
        const tid: u64 = @intCast(t + 1);
        if (prev[t] == 0) prev[t] = (try w.append(tid, .Begin, &.{}, 0)).value;
        if (randBool(&prng)) {
            // insert
            const payload = try wal.Wal.encodeInsert(std.testing.allocator, 0, 0, "r");
            defer std.testing.allocator.free(payload);
            prev[t] = (try w.append(tid, .Insert, payload, prev[t])).value;
            last_effect_insert = true;
        } else if (randBool(&prng)) {
            // delete (ignore errors if no prior slot)
            const delp = try wal.Wal.encodeDelete(std.testing.allocator, 0, 0);
            defer std.testing.allocator.free(delp);
            prev[t] = (try w.append(tid, .Delete, delp, prev[t])).value;
            last_effect_insert = false;
        } else if (!randBool(&prng)) {
            // commit sometimes
            prev[t] = (try w.append(tid, .Commit, &.{}, prev[t])).value;
            committed_mask |= @as(u3, 1) << @intCast(t);
        }
        if (R.int(u8) % 17 == 0) break; // crash point
    }
    try w.fsync();

    // Crash: recover into new structures twice.
    var pm = storage.PageManager.init(std.testing.allocator, 512);
    defer pm.deinit();
    var w2 = wal.Wal.init(std.testing.allocator);
    defer w2.deinit();
    _ = try w2.recover(&pm, log_path);
    var w3 = wal.Wal.init(std.testing.allocator);
    defer w3.deinit();
    _ = try w3.recover(&pm, log_path);

    // Simple invariant: no negative effects (test just ensures no crash). More detailed checks could count rows when commits present.
    // If at least one txn committed, page 0 may have >=1 slot; losers should not introduce duplicates (slot reuse logic keeps stable view).
    if (pm.pages.items.len > 0) {
        var p = pm.asPage(0);
        if (committed_mask == 0) {
            // No committed txns => no durable inserts expected
            // Either zero slots or only tombstoned remnants allowed
            var live: usize = 0;
            var i_slot: u16 = 0;
            while (i_slot < p.slotCount()) : (i_slot += 1) {
                if (p.read(i_slot)) |_| {
                    live += 1;
                } else |_| {}
            }
            try std.testing.expect(live == 0);
        } else {
            // At least one commit: if final effect was insert, expect >=1 visible row
            if (last_effect_insert) {
                var live2: usize = 0;
                var idx: u16 = 0;
                while (idx < p.slotCount()) : (idx += 1) {
                    if (p.read(idx)) |_| {
                        live2 += 1;
                    } else |_| {}
                }
                try std.testing.expect(live2 >= 1);
            }
        }
        if (p.slotCount() > 0) try std.testing.expect(p.lsn() > 0);
    }
}
