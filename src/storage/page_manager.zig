const std = @import("std");
const iface = @import("interface.zig");

// Phase‑0 slotted page + in‑memory PageManager (no WAL / persistence yet).
// Layout (page_size = 4096 default):
// [Header|Slot array growing upward][free space][records growing downward]
// Header (16 bytes total):
//   [0..8)  : u64 page LSN
//   [8..10) : u16 slot_count
//   [10..12): u16 free_end
//   [12..16): u32 checksum (Adler32 over full page with this field zeroed)
// free_end is first byte after last record.
// Each slot entry: offset(u16), size(u16).

pub const Page = struct {
    buf: []u8,
    // Layout:
    // [0..8)  : u64 page LSN
    // [8..10) : u16 slot_count
    // [10..12): u16 free_end
    // [12..16): u32 checksum (Adler32 over page with checksum zeroed)
    // [16..   ): slot directory (offset,size)*
    pub const LsnOffset: usize = 0;
    pub const SlotCountOffset: usize = 8;
    pub const FreeEndOffset: usize = 10;
    pub const ChecksumOffset: usize = 12;
    pub const HeaderSize: usize = 16; // LSN + slot_count + free_end + checksum

    pub fn slotCount(self: *const Page) u16 {
        return std.mem.readInt(u16, self.buf[SlotCountOffset .. SlotCountOffset + 2], .little);
    }
    fn setSlotCount(self: *Page, n: u16) void {
        std.mem.writeInt(u16, self.buf[SlotCountOffset .. SlotCountOffset + 2], n, .little);
    }
    fn freeEnd(self: *const Page) u16 {
        return std.mem.readInt(u16, self.buf[FreeEndOffset .. FreeEndOffset + 2], .little);
    }
    fn setFreeEnd(self: *Page, off: u16) void {
        std.mem.writeInt(u16, self.buf[FreeEndOffset .. FreeEndOffset + 2], off, .little);
    }
    fn slotOffset(i: u16) usize {
        return HeaderSize + @as(usize, i) * 4;
    }
    fn writeSlot(self: *Page, idx: u16, off: u16, sz: u16) void {
        const base = slotOffset(idx);
        std.mem.writeInt(u16, self.buf[base .. base + 2], off, .little);
        std.mem.writeInt(u16, self.buf[base + 2 .. base + 4], sz, .little);
    }
    fn readSlot(self: *const Page, idx: u16) struct { off: u16, sz: u16 } {
        const base = slotOffset(idx);
        return .{ .off = std.mem.readInt(u16, self.buf[base .. base + 2], .little), .sz = std.mem.readInt(u16, self.buf[base + 2 .. base + 4], .little) };
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

    fn recomputeChecksum(self: *Page) void {
        // Zero checksum field then compute over entire page.
        std.mem.writeInt(u32, self.buf[ChecksumOffset .. ChecksumOffset + 4], 0, .little);
        const cs = adler32(self.buf);
        std.mem.writeInt(u32, self.buf[ChecksumOffset .. ChecksumOffset + 4], cs, .little);
    }

    fn storedChecksum(self: *const Page) u32 {
        return std.mem.readInt(u32, self.buf[ChecksumOffset .. ChecksumOffset + 4], .little);
    }

    fn verifyChecksum(self: *const Page) bool {
        const tmp = self.buf; // slice copy (not data copy)
        // Build a scratch copy of header bytes to zero checksum logically during computation.
        // Simpler: temporarily zero then restore.
        const saved: u32 = self.storedChecksum();
        // We cast away const for the temporary write (caller holds mutable reference when verifying after load).
        const mut: *Page = @ptrCast(@constCast(self));
        std.mem.writeInt(u32, mut.buf[ChecksumOffset .. ChecksumOffset + 4], 0, .little);
        const calc = adler32(tmp);
        std.mem.writeInt(u32, mut.buf[ChecksumOffset .. ChecksumOffset + 4], saved, .little);
        return calc == saved;
    }

    pub fn init(buf: []u8) Page {
        std.debug.assert(buf.len >= 512); // minimal sanity
        var p = Page{ .buf = buf };
        @memset(buf, 0);
        p.setSlotCount(0);
        p.setFreeEnd(@intCast(buf.len));
        p.recomputeChecksum();
        return p;
    }

    pub fn setLsn(self: *Page, new_lsn: u64) void {
        std.mem.writeInt(u64, self.buf[LsnOffset .. LsnOffset + 8], new_lsn, .little);
    }
    pub fn lsn(self: *const Page) u64 {
        return std.mem.readInt(u64, self.buf[LsnOffset .. LsnOffset + 8], .little);
    }

    pub fn freeSpace(self: *const Page) usize {
        const slots_bytes = HeaderSize + @as(usize, self.slotCount()) * 4;
        return if (self.freeEnd() <= slots_bytes) 0 else self.freeEnd() - @as(u16, @intCast(slots_bytes));
    }

    pub fn insert(self: *Page, bytes: []const u8) !u16 {
        const need: usize = 4 + bytes.len; // slot + record
        if (need > self.freeSpace()) return error.NoSpace;
        const sc = self.slotCount();
        var free_end = self.freeEnd();
        free_end = @intCast(@as(usize, free_end) - bytes.len);
        @memcpy(self.buf[free_end .. free_end + bytes.len], bytes);
        self.writeSlot(sc, @intCast(free_end), @intCast(bytes.len));
        self.setSlotCount(sc + 1);
        self.setFreeEnd(free_end);
        // NOTE: Caller should invoke setLsn() with the WAL LSN of this insert.
        self.recomputeChecksum();
        return sc; // slot id
    }

    pub fn read(self: *const Page, slot_id: u16) ![]const u8 {
        if (slot_id >= self.slotCount()) return error.InvalidSlot;
        const s = self.readSlot(slot_id);
        if (s.sz == 0) return error.Deleted;
        if (@as(usize, s.off) + s.sz > self.buf.len) return error.Corrupt;
        return self.buf[s.off .. s.off + s.sz];
    }

    pub fn tombstone(self: *Page, slot_id: u16) !void {
        if (slot_id >= self.slotCount()) return error.InvalidSlot;
        const s = self.readSlot(slot_id);
        // zero size marks deleted; leave offset for potential future reuse/GC
        if (s.sz != 0) {
            self.writeSlot(slot_id, s.off, 0);
            self.recomputeChecksum();
        }
    }
};

pub const PageManager = struct {
    allocator: std.mem.Allocator,
    pages: std.ArrayList([]u8),
    page_size: usize = 4096,
    base_path: ?[]const u8 = null, // optional directory for persistence

    pub fn init(ally: std.mem.Allocator, page_size: usize) PageManager {
        return .{ .allocator = ally, .pages = std.ArrayList([]u8).init(ally), .page_size = page_size, .base_path = null };
    }
    pub fn initPersistent(ally: std.mem.Allocator, page_size: usize, base_path: []const u8) PageManager {
        return .{ .allocator = ally, .pages = std.ArrayList([]u8).init(ally), .page_size = page_size, .base_path = base_path };
    }
    pub fn deinit(self: *PageManager) void {
        for (self.pages.items) |p| self.allocator.free(p);
        self.pages.deinit();
    }
    fn ensurePage(self: *PageManager) !usize {
        if (self.pages.items.len == 0) try self.newPage();
        return self.pages.items.len - 1;
    }
    fn newPage(self: *PageManager) !void {
        const mem = try self.allocator.alloc(u8, self.page_size);
        _ = Page.init(mem); // layout initialized
        try self.pages.append(mem);
        if (self.base_path) |p| try self.writePage(p, self.pages.items.len - 1);
    }
    fn asPage(self: *PageManager, idx: usize) Page {
        return Page{ .buf = self.pages.items[idx] };
    }

    pub fn setPageLsn(self: *PageManager, page_index: usize, lsn: u64) void {
        if (page_index >= self.pages.items.len) return;
        var p = self.asPage(page_index);
        p.setLsn(lsn);
        if (self.base_path) |bp| self.writePage(bp, page_index) catch {};
    }

    pub fn insert(self: *PageManager, bytes: []const u8) !iface.RecordId {
        var i = try self.ensurePage();
        var p = self.asPage(i);
        if (p.insert(bytes)) |slot| {
            if (self.base_path) |bp| self.writePage(bp, i) catch {};
            return .{ .page = @intCast(i), .slot = slot };
        } else |e| switch (e) {
            error.NoSpace => {
                try self.newPage();
                i = self.pages.items.len - 1;
                var p2 = self.asPage(i);
                const s2 = try p2.insert(bytes);
                if (self.base_path) |bp| self.writePage(bp, i) catch {};
                return .{ .page = @intCast(i), .slot = s2 };
            },
            else => return e,
        }
    }

    pub fn read(self: *PageManager, rid: iface.RecordId) ![]const u8 {
        if (rid.page >= self.pages.items.len) return error.BadPage;
        var p = self.asPage(@intCast(rid.page));
        return p.read(rid.slot);
    }

    fn pageFileName(self: *PageManager, base: []const u8, index: usize) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/page_{d}.bin", .{ base, index });
    }

    fn writePage(self: *PageManager, base: []const u8, index: usize) !void {
        if (index >= self.pages.items.len) return;
        const dir = std.fs.cwd();
        const path = try self.pageFileName(base, index);
        defer self.allocator.free(path);
        var file = try dir.createFile(path, .{ .truncate = true });
        defer file.close();
        // ensure checksum current
        var p = self.asPage(index);
        p.recomputeChecksum();
        try file.writeAll(self.pages.items[index]);
        try file.sync();
    }

    pub fn loadPage(self: *PageManager, base: []const u8, index: usize) !void {
        const dir = std.fs.cwd();
        const path = try self.pageFileName(base, index);
        defer self.allocator.free(path);
        var file = try dir.openFile(path, .{});
        defer file.close();
        const mem = try self.allocator.alloc(u8, self.page_size);
        const got = try file.readAll(mem);
        if (got != self.page_size) return error.ShortRead;
        // verify checksum
        var p = Page{ .buf = mem };
        if (!p.verifyChecksum()) {
            // Higher layer should translate error.PageChecksumMismatch to diagnostics.StoragePageChecksum.
            return error.PageChecksumMismatch;
        }
        try self.pages.append(mem);
    }
};

test "page_manager: insert/read & free space monotonic + checksum" {
    var pm = PageManager.init(std.testing.allocator, 512);
    defer pm.deinit();
    const r1 = try pm.insert("hello");
    const r2 = try pm.insert("world!!!");
    const r3 = try pm.insert("1234567890");
    try std.testing.expectEqualStrings("hello", try pm.read(r1));
    try std.testing.expectEqualStrings("world!!!", try pm.read(r2));
    try std.testing.expectEqualStrings("1234567890", try pm.read(r3));
    // Free space decreases
    var p = pm.asPage(0);
    const fs_after = p.freeSpace();
    try std.testing.expect(fs_after < 512 - Page.HeaderSize);
    // Corrupt checksum and ensure verify fails
    const orig = std.mem.readInt(u32, p.buf[Page.ChecksumOffset .. Page.ChecksumOffset + 4], .little);
    std.mem.writeInt(u32, p.buf[Page.ChecksumOffset .. Page.ChecksumOffset + 4], orig ^ 0xFFFF_FFFF, .little);
    try std.testing.expect(!p.verifyChecksum());
    // Restore
    std.mem.writeInt(u32, p.buf[Page.ChecksumOffset .. Page.ChecksumOffset + 4], orig, .little);
    try std.testing.expect(p.verifyChecksum());
}
