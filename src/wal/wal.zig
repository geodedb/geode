const std = @import("std");
const storage = @import("../storage/page_manager.zig");

// Log Sequence Number (LSN) wrapper. Future: encode epoch or segment.
pub const Lsn = struct {
    value: u64,
};

pub const RecordType = enum { Begin, Insert, Delete, Commit, Abort, CLR, Checkpoint };

pub const UpdatePayload = struct { page: u32, slot: u16, data: []const u8 };

pub const DeletePayload = struct { page: u32, slot: u16 };

pub const ClrPayload = struct { page: u32, slot: u16, undo_next: u64 };

pub const Record = struct {
    lsn: Lsn,
    prev_lsn: u64 = 0,
    txn_id: u64 = 0,
    typ: RecordType,
    // Only one of the below used depending on typ; for simplicity store as raw bytes in file.
    payload: []const u8 = &.{},
    checksum: u32 = 0, // adler32 over header(with zeroed checksum) + payload
};

pub const Wal = struct {
    ally: std.mem.Allocator,
    next_lsn: u64 = 1,
    buf: std.ArrayList(Record),
    file: ?std.fs.File = null,

    pub fn init(ally: std.mem.Allocator) Wal {
        const list = std.ArrayList(Record).initCapacity(ally, 0) catch @panic("OOM WAL init");
        return .{ .ally = ally, .buf = list };
    }

    pub fn openFile(self: *Wal, path: []const u8) !void {
        const dir = std.fs.cwd();
        self.file = try dir.createFile(path, .{ .read = true, .truncate = false, .exclusive = false });
    }

    pub fn deinit(self: *Wal) void {
        if (self.file) |*f| f.close();
        self.buf.deinit(self.ally);
    }

    fn adler32(data: []const u8) u32 {
        var a: u32 = 1;
        var b: u32 = 0;
        for (data) |c| {
            a = (a + c) % 65521;
            b = (b + a) % 65521;
        }
        return (b << 16) | a;
    }

    fn diskWrite(self: *Wal, rec: Record) !void {
        if (self.file) |f| {
            var header: [1 + 8 + 4 + 8 + 8 + 4]u8 = undefined; // + checksum
            header[0] = @intFromEnum(rec.typ);
            std.mem.writeInt(u64, header[1..9], rec.txn_id, .little);
            std.mem.writeInt(u32, header[9..13], @intCast(rec.payload.len), .little);
            std.mem.writeInt(u64, header[13..21], rec.lsn.value, .little);
            std.mem.writeInt(u64, header[21..29], rec.prev_lsn, .little);
            // zero checksum field before computing
            std.mem.writeInt(u32, header[29..33], 0, .little);
            var cs_buf = std.ArrayList(u8).init(std.heap.page_allocator);
            defer cs_buf.deinit();
            cs_buf.appendSlice(header[0..]) catch {};
            cs_buf.appendSlice(rec.payload) catch {};
            const cs = adler32(cs_buf.items);
            std.mem.writeInt(u32, header[29..33], cs, .little);
            try f.writeAll(header[0..]);
            if (rec.payload.len > 0) try f.writeAll(rec.payload);
        }
    }

    pub fn append(self: *Wal, txn_id: u64, typ: RecordType, payload: []const u8, prev_lsn: u64) !Lsn {
        const lsn_val = self.next_lsn;
        self.next_lsn += 1;
        const rec_lsn: Lsn = .{ .value = lsn_val };
        const rec = Record{ .lsn = lsn_val, .txn_id = txn_id, .typ = typ, .payload = payload, .prev_lsn = prev_lsn };
        try self.buf.append(self.ally, rec);
        try self.diskWrite(rec);
        return rec_lsn;
    }

    // Structured payload encoders -------------------------------------------------
    pub fn encodeInsert(ally: std.mem.Allocator, page: u32, slot: u16, data: []const u8) ![]u8 {
        var buf = try ally.alloc(u8, 8 + data.len);
        std.mem.writeInt(u32, buf[0..4], page, .little);
        std.mem.writeInt(u16, buf[4..6], slot, .little);
        std.mem.writeInt(u16, buf[6..8], @intCast(data.len), .little);
        @memcpy(buf[8..], data);
        return buf;
    }

    pub fn encodeDelete(ally: std.mem.Allocator, page: u32, slot: u16) ![]u8 {
        var buf = try ally.alloc(u8, 6);
        std.mem.writeInt(u32, buf[0..4], page, .little);
        std.mem.writeInt(u16, buf[4..6], slot, .little);
        return buf;
    }

    // Delete with before-image: [page(4)|slot(2)|len(2)|data]
    pub fn encodeDeleteBefore(ally: std.mem.Allocator, page: u32, slot: u16, data: []const u8) ![]u8 {
        var buf = try ally.alloc(u8, 8 + data.len);
        std.mem.writeInt(u32, buf[0..4], page, .little);
        std.mem.writeInt(u16, buf[4..6], slot, .little);
        std.mem.writeInt(u16, buf[6..8], @intCast(data.len), .little);
        @memcpy(buf[8..], data);
        return buf;
    }

    pub fn decodeDeleteBefore(payload: []const u8) ?struct { page: u32, slot: u16, len: u16, data: []const u8 } {
        if (payload.len < 8) return null;
        const page = std.mem.readInt(u32, payload[0..4], .little);
        const slot = std.mem.readInt(u16, payload[4..6], .little);
        const dlen = std.mem.readInt(u16, payload[6..8], .little);
        if (payload.len < 8 + dlen) return null;
        return .{ .page = page, .slot = slot, .len = dlen, .data = payload[8 .. 8 + dlen] };
    }

    pub fn decodeInsert(payload: []const u8) ?struct { page: u32, slot: u16, len: u16, data: []const u8 } {
        if (payload.len < 8) return null;
        const page = std.mem.readInt(u32, payload[0..4], .little);
        const slot = std.mem.readInt(u16, payload[4..6], .little);
        const dlen = std.mem.readInt(u16, payload[6..8], .little);
        if (payload.len < 8 + dlen) return null;
        return .{ .page = page, .slot = slot, .len = dlen, .data = payload[8 .. 8 + dlen] };
    }

    pub fn decodeDelete(payload: []const u8) ?struct { page: u32, slot: u16 } {
        if (payload.len < 6) return null;
        return .{ .page = std.mem.readInt(u32, payload[0..4], .little), .slot = std.mem.readInt(u16, payload[4..6], .little) };
    }

    pub fn fsync(self: *Wal) !void {
        if (self.file) |f| try f.sync();
    }

    pub fn writeCheckpoint(self: *Wal) !void {
        _ = try self.append(0, .Checkpoint, &.{}, 0);
        try self.fsync();
    }

    /// Live rollback: walk backward via prev_lsn producing CLR records for each undone Insert.
    pub fn rollback(self: *Wal, txn_id: u64) !void {
        // Find last record for txn
        var last: ?*const Record = null;
        for (self.buf.items) |*r| {
            if (r.txn_id == txn_id) last = r;
        }
        var cursor = last;
        while (cursor) |rec| {
            switch (rec.typ) {
                .Insert => {
                    // generate CLR tombstoning same slot
                    if (decodeInsert(rec.payload)) |ins| {
                        const clr_payload = try encodeDelete(self.ally, ins.page, ins.slot);
                        _ = try self.append(txn_id, .CLR, clr_payload, rec.lsn.value);
                    }
                },
                else => {},
            }
            // follow prev_lsn
            var prev: ?*const Record = null;
            for (self.buf.items) |*r2| {
                if (r2.lsn.value == rec.prev_lsn and r2.txn_id == txn_id) {
                    prev = r2;
                    break;
                }
            }
            cursor = prev;
        }
        // finally emit Abort
        _ = try self.append(txn_id, .Abort, &.{}, 0);
        try self.fsync();
    }

    pub fn iter(self: *Wal) WalIter {
        return .{ .wal = self, .idx = 0 };
    }

    /// ARIES-style recovery (simplified): redo committed (or loser updates needed), then undo losers.
    pub fn recover(self: *Wal, pm: *storage.PageManager, path: []const u8) !usize {
        const dir = std.fs.cwd();
        var f = dir.openFile(path, .{}) catch return 0; // nothing to recover
        defer f.close();
        const HeaderLen = 1 + 8 + 4 + 8 + 8 + 4;
        // txn table
        var txn_map = std.AutoHashMap(u64, struct { committed: bool, last_lsn: u64 }).init(self.ally);
        defer txn_map.deinit();
        var records = std.ArrayList(Record).init(self.ally);
        defer records.deinit();
        var buf: [HeaderLen]u8 = undefined;
        // Find last checkpoint offset (linear scan; future: index).
        var last_ckpt: usize = 0;
        var last_ckpt_lsn: u64 = 0;
        try f.seekTo(0);
        while (true) {
            const n = f.readAll(&buf) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (n == 0) break;
            if (n != buf.len) break; // tolerate partial tail
            const typ: RecordType = @enumFromInt(buf[0]);
            const txn_id = std.mem.readInt(u64, buf[1..9], .little);
            const plen = std.mem.readInt(u32, buf[9..13], .little);
            const lsn_v = std.mem.readInt(u64, buf[13..21], .little);
            if (typ == .Checkpoint) {
                last_ckpt = try f.getPos();
                last_ckpt_lsn = lsn_v;
            }
            const prev_lsn_v = std.mem.readInt(u64, buf[21..29], .little);
            const file_cs = std.mem.readInt(u32, buf[29..33], .little);
            var payload_slice: []u8 = &.{};
            if (plen > 0) {
                payload_slice = try self.ally.alloc(u8, plen);
                const got = f.readAll(payload_slice) catch |err| switch (err) {
                    error.EndOfStream => 0,
                    else => return err,
                };
                if (got != plen) {
                    self.ally.free(payload_slice);
                    break;
                }
            }
            // verify checksum (reconstruct header with zeroed checksum)
            var verify_header: [HeaderLen]u8 = undefined;
            @memcpy(verify_header[0..HeaderLen], buf[0..HeaderLen]);
            std.mem.writeInt(u32, verify_header[29..33], 0, .little);
            var cs_buf2 = std.ArrayList(u8).init(self.ally);
            defer cs_buf2.deinit();
            cs_buf2.appendSlice(verify_header[0..HeaderLen]) catch {};
            cs_buf2.appendSlice(payload_slice) catch {};
            const calc_cs = adler32(cs_buf2.items);
            if (calc_cs != file_cs) {
                // stop recovery at first checksum failure (truncate tail)
                if (payload_slice.len > 0) self.ally.free(payload_slice);
                break;
            }
            var entry = try txn_map.getOrPut(txn_id);
            if (!entry.found_existing) entry.value_ptr.* = .{ .committed = false, .last_lsn = 0 };
            entry.value_ptr.last_lsn = lsn_v;
            if (typ == .Commit) entry.value_ptr.committed = true;
            try records.append(.{ .lsn = .{ .value = lsn_v }, .txn_id = txn_id, .typ = typ, .payload = payload_slice, .prev_lsn = prev_lsn_v });
        }

        // REDO pass (forward): starting at last checkpoint if present.
        var start_index: usize = 0;
        if (last_ckpt_lsn != 0) {
            // binary search could be used; linear fine for now
            var idx: usize = 0;
            while (idx < records.items.len) : (idx += 1) {
                if (records.items[idx].lsn.value >= last_ckpt_lsn) {
                    start_index = idx;
                    break;
                }
            }
        }
        // Simplified: We reapply blindly because pageLSN not persisted beyond process (placeholder).
        var applied: usize = 0;
        for (records.items[start_index..]) |rec| {
            switch (rec.typ) {
                .Insert => {
                    if (decodeInsert(rec.payload)) |ins| {
                        while (ins.page >= pm.pages.items.len) try pm.newPage();
                        var p = pm.asPage(ins.page);
                        if (p.lsn() >= rec.lsn.value) continue; // already applied
                        if (ins.slot >= p.slotCount()) {
                            _ = p.insert(ins.data) catch {};
                        }
                        p.setLsn(rec.lsn.value);
                        applied += 1;
                    }
                },
                .Delete, .CLR => {
                    if (decodeDelete(rec.payload)) |del| {
                        if (del.page < pm.pages.items.len) {
                            var p = pm.asPage(del.page);
                            if (p.lsn() >= rec.lsn.value) continue;
                            p.tombstone(del.slot) catch {};
                            p.setLsn(rec.lsn.value);
                            applied += 1;
                        }
                    }
                },
                else => {},
            }
        }
        // UNDO pass: traverse loser txns backwards emitting CLRs (not persisted here, in-memory only).
        // Collect loser last LSNs.
        var losers = std.AutoHashMap(u64, u64).init(self.ally);
        defer losers.deinit();
        var it_l = txn_map.iterator();
        while (it_l.next()) |e| {
            if (!e.value_ptr.committed) try losers.put(e.key_ptr.*, e.value_ptr.last_lsn);
        }
        // Backward scan records for losers; on Insert we perform compensating Delete; on Delete we could re-insert (omitted placeholder).
        var i: isize = @as(isize, @intCast(records.items.len)) - 1;
        while (i >= 0) : (i -= 1) {
            const rec = records.items[@intCast(i)];
            if (!losers.contains(rec.txn_id)) continue;
            switch (rec.typ) {
                .Insert => {
                    // undo by tombstoning inserted slot if present
                    if (rec.payload.len >= 8) {
                        const page = std.mem.readInt(u32, rec.payload[0..4], .little);
                        const slot = std.mem.readInt(u16, rec.payload[4..6], .little);
                        if (page < pm.pages.items.len) {
                            var p = pm.asPage(page);
                            p.tombstone(slot) catch {};
                        }
                        // persist CLR describing compensating delete
                        if (self.file != null) {
                            const clr_payload = try encodeDelete(self.ally, page, slot);
                            defer self.ally.free(clr_payload);
                            _ = try self.append(rec.txn_id, .CLR, clr_payload, rec.lsn.value);
                        }
                    }
                },
                .Delete => {
                    if (decodeDeleteBefore(rec.payload)) |delb| {
                        while (delb.page >= pm.pages.items.len) try pm.newPage();
                        var p = pm.asPage(delb.page);
                        if (delb.slot >= p.slotCount()) {
                            // slot beyond count: fresh insert (may get different slot id; acceptable fallback)
                            _ = p.insert(delb.data) catch {};
                        } else {
                            // try to reuse original slot if tombstoned (size==0)
                            const slot_meta = p.readSlot(delb.slot);
                            if (slot_meta.sz == 0 and @as(usize, slot_meta.off) + delb.len <= p.buf.len) {
                                // write data back into the old space if it still exists
                                @memcpy(p.buf[slot_meta.off .. slot_meta.off + delb.len], delb.data);
                                // update size
                                p.writeSlot(delb.slot, slot_meta.off, delb.len);
                            } else if (slot_meta.sz == 0) {
                                // fallback: normal insert
                                _ = p.insert(delb.data) catch {};
                            }
                        }
                        if (self.file != null) {
                            // For delete undo (reinsertion), a CLR can be a synthetic Insert; we use Insert encoding.
                            const clr_ins = try encodeInsert(self.ally, delb.page, delb.slot, delb.data);
                            defer self.ally.free(clr_ins);
                            _ = try self.append(rec.txn_id, .CLR, clr_ins, rec.lsn.value);
                        }
                    }
                },
                else => {},
            }
        }
        return applied;
    }
};

pub const WalIter = struct {
    wal: *Wal,
    idx: usize,
    pub fn next(self: *WalIter) ?Record {
        if (self.idx >= self.wal.buf.items.len) return null;
        const r = self.wal.buf.items[self.idx];
        self.idx += 1;
        return r;
    }
};
