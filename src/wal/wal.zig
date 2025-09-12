const std = @import("std");
// Page manager imported via build alias to avoid relative path escaping module root.
const storage = @import("storage_page_manager");

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
    base_path: []const u8 = &.{},
    segment_index: u32 = 0,
    segment_bytes: usize = 0,
    segment_limit: usize = 1 * 1024 * 1024, // 1MB default rollover threshold (tunable later)
    // Sparse page LSN index built during recovery for fast redo start seeking.
    // Maps page id -> highest LSN seen in log (used to skip earlier segments/records).
    page_lsn_index: ?std.AutoHashMap(u32, u64) = null,
    // Metrics captured on last recovery run (for PROFILE / tests).
    last_skip_count: usize = 0,
    last_total_records: usize = 0,

    pub fn init(ally: std.mem.Allocator) Wal {
        const list = std.ArrayList(Record).initCapacity(ally, 0) catch @panic("OOM WAL init");
        return .{ .ally = ally, .buf = list };
    }

    fn openSegment(self: *Wal) !void {
        // Close previous if open
        if (self.file) |*f| f.close();
        const dir = std.fs.cwd();
        const path = try std.fmt.allocPrint(self.ally, "{s}.wal.{d}", .{ self.base_path, self.segment_index });
        defer self.ally.free(path);
        self.file = try dir.createFile(path, .{ .read = true, .truncate = false, .exclusive = false });
        self.segment_bytes = 0;
    }

    pub fn openFile(self: *Wal, base_path: []const u8) !void {
        self.base_path = try self.ally.dupe(u8, base_path);
        self.segment_index = 0;
        try self.openSegment();
    }

    pub fn deinit(self: *Wal) void {
        if (self.file) |*f| f.close();
        self.buf.deinit(self.ally);
        if (self.page_lsn_index) |*m| m.deinit();
    }

    pub fn skipRatio(self: *const Wal) f64 {
        if (self.last_total_records == 0) return 0.0;
        return @as(f64, @floatFromInt(self.last_skip_count)) / @as(f64, @floatFromInt(self.last_total_records));
    }

    /// Compact WAL segments whose maximum LSN is strictly less than durable_lsn.
    /// Keeps current open segment even if old (safety); caller should checkpoint+rotate first for deeper reclaim.
    pub fn compact(self: *Wal, durable_lsn: u64) !void {
        if (self.base_path.len == 0) return; // not opened
        const dir = std.fs.cwd();
        var arena = std.heap.ArenaAllocator.init(self.ally);
        defer arena.deinit();
        const a = arena.allocator();
        // Enumerate sequential segment indices until a gap; stop at first missing.
        var seg_index: u32 = 0;
        while (seg_index <= self.segment_index + 64) : (seg_index += 1) { // hard cap scan window
            const seg_path = try std.fmt.allocPrint(a, "{s}.wal.{d}", .{ self.base_path, seg_index });
            const maybe_file = dir.openFile(seg_path, .{ .mode = .read_only }) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (maybe_file) |f| {
                defer f.close();
                // Skip active segment (never delete the one currently open for append).
                if (seg_index == self.segment_index) continue;
                // Scan headers computing max lsn.
                const HeaderLen = 1 + 8 + 4 + 8 + 8 + 4; // with checksum
                var buf: [HeaderLen]u8 = undefined;
                var max_lsn: u64 = 0;
                try f.seekTo(0);
                while (true) {
                    const n = f.readAll(&buf) catch {
                        break; // treat any short read as end
                    };
                    if (n != buf.len) break;
                    const plen = std.mem.readInt(u32, buf[9..13], .little);
                    const lsn_v = std.mem.readInt(u64, buf[13..21], .little);
                    if (lsn_v > max_lsn) max_lsn = lsn_v;
                    // skip payload + sentinel
                    if (plen > 0) try f.seekBy(@as(i64, plen));
                    // attempt to read sentinel (4 bytes) and discard (ignore mismatch here)
                    var sentinel: [4]u8 = undefined;
                    const sn = f.readAll(&sentinel) catch 0;
                    if (sn != 4) break;
                }
                if (max_lsn < durable_lsn and max_lsn != 0) {
                    // Safe to delete.
                    dir.deleteFile(seg_path) catch |errd| switch (errd) {
                        error.FileNotFound => {},
                        else => return errd,
                    };
                }
            } else if (seg_index > self.segment_index) break; // gap beyond active -> stop
        }
    }

    /// Scan segments (read-only) to discover last checkpoint LSN and highest segment present.
    pub fn scanMetadata(self: *Wal) !struct { last_checkpoint_lsn: u64, max_segment: u32 } {
        if (self.base_path.len == 0) return .{ .last_checkpoint_lsn = 0, .max_segment = 0 };
        const dir = std.fs.cwd();
        var seg_index: u32 = 0;
        var last_ckpt: u64 = 0;
        var highest: u32 = 0;
        const HeaderLen = 1 + 8 + 4 + 8 + 8 + 4;
        while (seg_index <= self.segment_index + 128) : (seg_index += 1) {
            const path = try std.fmt.allocPrint(self.ally, "{s}.wal.{d}", .{ self.base_path, seg_index });
            defer self.ally.free(path);
            const f = dir.openFile(path, .{ .mode = .read_only }) catch |err| switch (err) {
                error.FileNotFound => break,
                else => return err,
            };
            defer f.close();
            highest = seg_index;
            var buf: [HeaderLen]u8 = undefined;
            try f.seekTo(0);
            while (true) {
                const n = f.readAll(&buf) catch {
                    // Treat partial read as end-of-segment for tools that import with reduced error set.
                    break;
                };
                if (n != buf.len) break;
                const typ: RecordType = @enumFromInt(buf[0]);
                if (typ == .Checkpoint) {
                    const lsn_v = std.mem.readInt(u64, buf[13..21], .little);
                    if (lsn_v > last_ckpt) last_ckpt = lsn_v;
                }
                const plen = std.mem.readInt(u32, buf[9..13], .little);
                if (plen > 0) try f.seekBy(@as(i64, plen));
                var sentinel: [4]u8 = undefined;
                const sn = f.readAll(&sentinel) catch 0;
                if (sn != 4) break;
            }
        }
        return .{ .last_checkpoint_lsn = last_ckpt, .max_segment = highest };
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
            const HeaderLen: usize = 1 + 8 + 4 + 8 + 8 + 4; // + checksum field (zeroed for calc)
            var header: [1 + 8 + 4 + 8 + 8 + 4]u8 = undefined;
            header[0] = @intFromEnum(rec.typ);
            std.mem.writeInt(u64, header[1..9], rec.txn_id, .little);
            std.mem.writeInt(u32, header[9..13], @intCast(rec.payload.len), .little);
            std.mem.writeInt(u64, header[13..21], rec.lsn.value, .little);
            std.mem.writeInt(u64, header[21..29], rec.prev_lsn, .little);
            std.mem.writeInt(u32, header[29..33], 0, .little); // zero before checksum
            var cs_buf = std.ArrayList(u8).init(std.heap.page_allocator);
            defer cs_buf.deinit();
            cs_buf.appendSlice(header[0..]) catch {};
            cs_buf.appendSlice(rec.payload) catch {};
            const cs = adler32(cs_buf.items);
            std.mem.writeInt(u32, header[29..33], cs, .little);
            // Rollover check: if writing header+payload+sentinel would exceed limit, rotate segment first.
            const needed = HeaderLen + rec.payload.len + 4; // add sentinel size
            if (self.segment_bytes + needed > self.segment_limit) {
                self.segment_index += 1;
                try self.openSegment();
            }
            try f.writeAll(header[0..]);
            if (rec.payload.len > 0) try f.writeAll(rec.payload);
            // Torn-write sentinel magic (GEODE) 0xEC0DDBAD
            var sentinel: [4]u8 = undefined;
            std.mem.writeInt(u32, sentinel[0..4], 0xEC0DDBAD, .little);
            try f.writeAll(&sentinel);
            self.segment_bytes += needed;
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

    pub fn writeCheckpoint(self: *Wal) !Lsn {
        const lsn = try self.append(0, .Checkpoint, &.{}, 0);
        try self.fsync();
        return lsn;
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
        const HeaderLen = 1 + 8 + 4 + 8 + 8 + 4; // w/ checksum
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
        // Build sparse page->lsn index while scanning headers (payload needed for page id extraction on Insert/Delete/CLR).
        if (self.page_lsn_index == null) {
            self.page_lsn_index = std.AutoHashMap(u32, u64).init(self.ally);
        } else {
            // clear previous
            var it_clear = self.page_lsn_index.?.iterator();
            while (it_clear.next()) |_| {}
        }
        const idx_map_ptr = &self.page_lsn_index.?;
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
            // Read and validate torn-write sentinel (4 bytes). If mismatch, treat as torn tail and stop.
            var sentinel_buf: [4]u8 = undefined;
            const sn = f.readAll(&sentinel_buf) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return err,
            };
            if (sn != 4) break; // partial sentinel -> torn tail
            const sent_val = std.mem.readInt(u32, &sentinel_buf, .little);
            if (sent_val != 0xEC0DDBAD) break; // torn write or corruption
            var entry = try txn_map.getOrPut(txn_id);
            if (!entry.found_existing) entry.value_ptr.* = .{ .committed = false, .last_lsn = 0 };
            entry.value_ptr.last_lsn = lsn_v;
            if (typ == .Commit) entry.value_ptr.committed = true;
            try records.append(.{ .lsn = .{ .value = lsn_v }, .txn_id = txn_id, .typ = typ, .payload = payload_slice, .prev_lsn = prev_lsn_v });
            // Populate sparse index for data-bearing records.
            switch (typ) {
                .Insert, .Delete, .CLR => {
                    if (payload_slice.len >= 6) {
                        const page_id = std.mem.readInt(u32, payload_slice[0..4], .little);
                        const ie = try idx_map_ptr.getOrPut(page_id);
                        if (!ie.found_existing or ie.value_ptr.* < lsn_v) ie.value_ptr.* = lsn_v;
                    }
                },
                else => {},
            }
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
        // Fast-seek optimization: if pageLSN index exists, compute fraction of records we can skip
        // by checking the earliest record whose LSN >= min(page_lsn of any page needing redo). For now
        // we approximate by finding minimum of index values (since pages without changes won't appear).
        var skip_count: usize = 0;
        self.last_skip_count = 0; // reset metrics
        self.last_total_records = records.items.len;
        if (self.page_lsn_index) |m| {
            var min_lsn: u64 = std.math.maxInt(u64);
            var itp = m.iterator();
            while (itp.next()) |e| {
                if (e.value_ptr.* < min_lsn) min_lsn = e.value_ptr.*;
            }
            if (min_lsn != std.math.maxInt(u64)) {
                // binary search records for min_lsn
                var lo: isize = @intCast(start_index);
                var hi: isize = @as(isize, @intCast(records.items.len)) - 1;
                var target_idx: isize = @intCast(start_index);
                while (lo <= hi) {
                    const mid: isize = (lo + hi) / 2;
                    const mid_lsn = records.items[@intCast(mid)].lsn.value;
                    if (mid_lsn < min_lsn) {
                        lo = mid + 1;
                        target_idx = lo;
                    } else {
                        hi = mid - 1;
                        target_idx = mid;
                    }
                }
                if (target_idx > @as(isize, @intCast(start_index)) and target_idx < @as(isize, @intCast(records.items.len))) {
                    skip_count = @as(usize, @intCast(target_idx)) - start_index;
                    start_index = @as(usize, @intCast(target_idx));
                }
            }
        }
        // NOTE: A test will compute skip percentage = skip_count / total_records.
        self.last_skip_count = skip_count;
        self.last_total_records = records.items.len;
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
        // CLR chain validation (basic): ensure each CLR.prev_lsn references a prior record for same txn.
        // (Phase 3 hardening: surface diagnostic or log; here we just perform consistency scan.)
        var clr_ok: bool = true;
        var ci: usize = 0;
        while (ci < records.items.len) : (ci += 1) {
            const r = records.items[ci];
            if (r.typ == .CLR) {
                var found_prev = false;
                var sj: usize = 0;
                while (sj < ci) : (sj += 1) {
                    const pr = records.items[sj];
                    if (pr.lsn.value == r.prev_lsn and pr.txn_id == r.txn_id) {
                        found_prev = true;
                        break;
                    }
                }
                if (!found_prev) {
                    clr_ok = false;
                    break;
                }
            }
        }
        if (!clr_ok) {
            // Future: emit diagnostic frame; for now return applied count (recovery succeeded with warning).
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
