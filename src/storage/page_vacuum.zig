const std = @import("std");
const storage = @import("storage_page_manager");
const wal = @import("wal");

pub const VacuumResult = struct {
    compacted: bool,
    free_end_before: u16,
    free_end_after: u16,
};

/// Compacter performs in-place garbage collection within a single page.
/// It moves all "live" tuples to the top of the page (contiguous), eliminates fragmentation,
/// and updates slot offsets. Slot IDs are preserved (their offsets change).
pub fn compactIfNeeded(pm: *storage.PageManager, page_id: u32, wal_ptr: *wal.Wal, cfg_vacuum_min_bytes: u16, cfg_vacuum_min_ratio: u8) !VacuumResult {
    _ = cfg_vacuum_min_ratio; // Future use or different metric
    if (page_id >= pm.pages.items.len) return error.InvalidPageId;
    var page = pm.asPage(page_id);

    // Simplified fragmentation metric:
    // Ideally calculate (total_free - contiguous_free).
    // For now we trust the caller (or opportunistic trigger) regarding checks.
    // If we can't easily measure fragmentation without scan, we proceed if triggered.

    // Let's analyze page to determine if compaction is worth it.
    const sc = page.slotCount();
    var used_bytes: usize = 0;
    var max_off: u16 = 0;
    var min_off: u16 = @intCast(page.buf.len);

    var slot_map = std.ArrayList(wal.PageCompactSlot).init(pm.allocator);
    defer slot_map.deinit();

    for (0..sc) |i| {
        const idx: u16 = @intCast(i);
        const s = page.readSlot(idx);
        if (s.sz > 0) {
            used_bytes += s.sz;
            if (s.off + s.sz > max_off) max_off = s.off + s.sz;
            if (s.off < min_off) min_off = s.off;
        }
    }

    // Unused debug vars for now
    // const logical_free_end = min_off;
    // const current_free_end = page.freeEnd();
    // const theoretical_free_end = storage.Page.HeaderSize + (sc * 4); // The bottom of slot array
    // const actual_used_data_top = min_off;

    const current_free_end = page.freeEnd();

    // Gap analysis:
    // Contiguous free space is between end of slots and `free_end`.
    // Fragmentation exists if there are deleted slots whose space is "above" free_end (higher address, since growing down)
    // but not reclaimed.
    // Actually, `free_end` points to the *lowest* allocated byte.
    // So valid data is in [free_end, buf.len].
    // If we deleted something, we just marked slot size=0. That space is still "behind" free_end.
    // To confirm fragmentation:
    // If we have deleted slots (sz=0) but free_end hasn't moved up, that's lost space.
    // Also if we have live slots, their data is scattered.

    // We can just calculating packed size.
    const packed_data_size = used_bytes;
    const packed_free_end = @as(u16, @intCast(page.buf.len - packed_data_size));

    const recoverable = packed_free_end - current_free_end;

    if (recoverable < cfg_vacuum_min_bytes) {
        return VacuumResult{ .compacted = false, .free_end_before = current_free_end, .free_end_after = current_free_end };
    }

    // DO COMPACTION

    // 1. Create a temporary buffer for the packed data
    var compact_buf = try pm.allocator.alloc(u8, page.buf.len);
    defer pm.allocator.free(compact_buf);
    @memset(compact_buf, 0);

    // Copy Header
    @memcpy(compact_buf[0..storage.Page.HeaderSize], page.buf[0..storage.Page.HeaderSize]);

    // We will place records starting from top (buf.len) downwards.
    var cursor = page.buf.len;

    for (0..sc) |i| {
        const idx: u16 = @intCast(i);
        const s = page.readSlot(idx);

        if (s.sz > 0) {
            cursor -= s.sz;
            const new_off: u16 = @intCast(cursor);
            // Copy data to new location
            const data = page.buf[s.off .. s.off + s.sz];
            @memcpy(compact_buf[new_off .. new_off + s.sz], data);

            // Record mapping for WAL
            try slot_map.append(.{ .slot_id = idx, .old_off = s.off, .new_off = new_off, .len = s.sz });

            // Update slot in temp buf
            // We need to write slot `idx` in compact_buf
            const base = storage.Page.HeaderSize + @as(usize, idx) * 4;
            std.mem.writeInt(u16, compact_buf[base .. base + 2][0..2], new_off, .little);
            std.mem.writeInt(u16, compact_buf[base + 2 .. base + 4][0..2], s.sz, .little);
        } else {
            // Tombstone remains, offset 0 size 0
            const base = storage.Page.HeaderSize + @as(usize, idx) * 4;
            std.mem.writeInt(u16, compact_buf[base .. base + 2][0..2], 0, .little);
            std.mem.writeInt(u16, compact_buf[base + 2 .. base + 4][0..2], 0, .little);
        }
    }

    // Update free_end in header
    std.mem.writeInt(u16, compact_buf[storage.Page.FreeEndOffset .. storage.Page.FreeEndOffset + 2], @intCast(cursor), .little);

    // 2. Log to WAL BEFORE applying to page
    const mapping = try wal_ptr.allocator.dupe(wal.PageCompactSlot, slot_map.items);
    defer wal_ptr.allocator.free(mapping); // Wal struct might consume it? No, encode needs it.

    // Encode payload
    const payload = try wal_ptr.encodePageCompact(pm.allocator, page_id, @intCast(cursor), mapping);
    defer pm.allocator.free(payload);

    // Append to WAL
    // We assume this is a "System Transaction" or part of current txn?
    // Spec says "no undo required (treat as a system transaction)".
    // We can use txn_id=0 or a special one. Let's use 0 for system ops.
    const lsn = try wal_ptr.append(0, .PageCompact, payload, 0);

    // 3. Flush WAL
    try wal_ptr.flushUpTo(lsn.value);

    // 4. Apply to Page
    @memcpy(page.buf, compact_buf);
    page.setLsn(lsn.value);

    return VacuumResult{
        .compacted = true,
        .free_end_before = current_free_end,
        .free_end_after = @intCast(cursor),
    };
}
