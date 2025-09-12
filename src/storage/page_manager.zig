const std = @import("std");
const iface = @import("interface.zig");

// Phase‑0 slotted page + in‑memory PageManager (no WAL / persistence yet).
// Layout (page_size = 4096 default):
// [Header|Slot array growing upward][free space][records growing downward]
// Header: slot_count(u16), free_end(u16). free_end is first byte after last record.
// Each slot entry: offset(u16), size(u16).

pub const Page = struct {
    buf: []u8,
    pub const HeaderSize: usize = 4; // slot_count + free_end

    fn slotCount(self: *const Page) u16 {
        return std.mem.readInt(u16, self.buf[0..2], .little);
    }
    fn setSlotCount(self: *Page, n: u16) void {
        std.mem.writeInt(u16, self.buf[0..2], n, .little);
    }
    fn freeEnd(self: *const Page) u16 {
        return std.mem.readInt(u16, self.buf[2..4], .little);
    }
    fn setFreeEnd(self: *Page, off: u16) void {
        std.mem.writeInt(u16, self.buf[2..4], off, .little);
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

    pub fn init(buf: []u8) Page {
        std.debug.assert(buf.len >= 512); // minimal sanity
        var p = Page{ .buf = buf };
        @memset(buf, 0);
        p.setSlotCount(0);
        p.setFreeEnd(@intCast(buf.len));
        return p;
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
        return sc; // slot id
    }

    pub fn read(self: *const Page, slot_id: u16) ![]const u8 {
        if (slot_id >= self.slotCount()) return error.InvalidSlot;
        const s = self.readSlot(slot_id);
        if (@as(usize, s.off) + s.sz > self.buf.len) return error.Corrupt;
        return self.buf[s.off .. s.off + s.sz];
    }
};

pub const PageManager = struct {
    allocator: std.mem.Allocator,
    pages: std.ArrayList([]u8),
    page_size: usize = 4096,

    pub fn init(ally: std.mem.Allocator, page_size: usize) PageManager {
        return .{ .allocator = ally, .pages = std.ArrayList([]u8).init(ally), .page_size = page_size };
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
    }
    fn asPage(self: *PageManager, idx: usize) Page {
        return Page{ .buf = self.pages.items[idx] };
    }

    pub fn insert(self: *PageManager, bytes: []const u8) !iface.RecordId {
        var i = try self.ensurePage();
        var p = self.asPage(i);
        if (p.insert(bytes)) |slot| {
            return .{ .page = @intCast(i), .slot = slot };
        } else |e| switch (e) {
            error.NoSpace => {
                try self.newPage();
                i = self.pages.items.len - 1;
                var p2 = self.asPage(i);
                const s2 = try p2.insert(bytes);
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
};

test "page_manager: insert/read & free space monotonic" {
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
}
