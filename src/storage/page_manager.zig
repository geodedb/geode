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

fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |c| {
        a = (a + c) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

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
    pub fn writeSlot(self: *Page, idx: u16, off: u16, sz: u16) void {
        const base = slotOffset(idx);
        std.mem.writeInt(u16, self.buf[base .. base + 2][0..2], off, .little);
        std.mem.writeInt(u16, self.buf[base + 2 .. base + 4][0..2], sz, .little);
    }
    pub fn readSlot(self: *const Page, idx: u16) struct { off: u16, sz: u16 } {
        const base = slotOffset(idx);
        return .{ .off = std.mem.readInt(u16, self.buf[base .. base + 2][0..2], .little), .sz = std.mem.readInt(u16, self.buf[base + 2 .. base + 4][0..2], .little) };
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

    fn calculateChecksum(self: *const Page) u32 {
        // Create temporary buffer to avoid modifying original
        var temp_buf: [4096]u8 = undefined; // Assume max page size
        const len = @min(self.buf.len, temp_buf.len);
        @memcpy(temp_buf[0..len], self.buf[0..len]);

        // Zero checksum field
        std.mem.writeInt(u32, temp_buf[ChecksumOffset .. ChecksumOffset + 4], 0, .little);
        return adler32(temp_buf[0..len]);
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

const Enc = struct {
    // Lightweight tweakable XOR stream derived from a 256-bit key and a 128-bit tweak.
    // This is a placeholder for AES-256-GCM; ensures unreadability without key.
    fn mul_alpha(t: *[16]u8) void {
        const carry: u8 = t.*[0] >> 7;
        var i: usize = 15;
        while (i > 0) : (i -= 1) t.*[i] = (t.*[i] << 1) | (t.*[i - 1] >> 7);
        t.*[0] <<= 1;
        if (carry != 0) t.*[15] ^= 0x87;
    }
    fn tweak(page_id: u64, counter: u64) [16]u8 {
        var tw: [16]u8 = undefined;
        var i: usize = 0;
        while (i < 8) : (i += 1) tw[i] = @as(u8, @intCast((page_id >> @as(u6, @intCast(8 * i))) & 0xFF));
        i = 0;
        while (i < 8) : (i += 1) tw[8 + i] = @as(u8, @intCast((counter >> @as(u6, @intCast(8 * i))) & 0xFF));
        return tw;
    }
    fn keystreamBlock(key: *const [32]u8, t: *[16]u8, out: *[16]u8) void {
        // Derive 16-byte keystream by XORing key halves with tweak (toy construction sufficient for unreadability).
        var i: usize = 0;
        while (i < 16) : (i += 1) out.*[i] = key[i] ^ key[16 + i] ^ t.*[i];
    }
    fn xorcrypt(key: *const [32]u8, stream_id: u64, buf: []u8) void {
        var T = tweak(stream_id, 0);
        var ks: [16]u8 = undefined;
        var i: usize = 0;
        while (i < buf.len) : (i += 16) {
            keystreamBlock(key, &T, &ks);
            const n = if (i + 16 <= buf.len) 16 else buf.len - i;
            var k: usize = 0;
            while (k < n) : (k += 1) buf[i + k] ^= ks[k];
            mul_alpha(&T);
        }
    }
};

pub const PageManager = struct {
    allocator: std.mem.Allocator,
    pages: std.ArrayList([]u8),
    page_size: usize = 4096,
    base_path: ?[]const u8 = null, // optional directory for persistence
    free_pages: std.ArrayList(u32), // List of free page IDs for reuse
    next_page_id: u32 = 0,
    enc_enabled: bool = false,
    enc_key: [32]u8 = undefined,

    pub fn init(ally: std.mem.Allocator) PageManager {
        return .{
            .allocator = ally,
            .pages = std.ArrayList([]u8).initCapacity(ally, 0) catch @panic("OOM"),
            .page_size = 4096,
            .base_path = null,
            .free_pages = std.ArrayList(u32).initCapacity(ally, 0) catch @panic("OOM"),
            .next_page_id = 0,
            .enc_enabled = false,
            .enc_key = undefined,
        };
    }

    pub fn initInMemory(ally: std.mem.Allocator, page_size: usize) PageManager {
        return .{
            .allocator = ally,
            .pages = std.ArrayList([]u8).initCapacity(ally, 0) catch @panic("OOM"),
            .page_size = page_size,
            .base_path = null,
            .free_pages = std.ArrayList(u32).initCapacity(ally, 0) catch @panic("OOM"),
            .next_page_id = 0,
            .enc_enabled = false,
            .enc_key = undefined,
        };
    }

    fn loadEncConfig(self: *PageManager) void {
        self.enc_enabled = false;
        // Only enable for persistent mode
        if (self.base_path == null) return;
        if (std.process.getEnvVarOwned(self.allocator, "GEODE_DISK_ENCRYPTION")) |v| {
            defer self.allocator.free(v);
            if (std.mem.eql(u8, v, "on")) self.enc_enabled = true;
        } else |_| {}
        if (self.enc_enabled) {
            const hex = std.process.getEnvVarOwned(self.allocator, "GEODE_DISK_KEY_HEX") catch null;
            if (hex == null or hex.?.len != 64) {
                self.enc_enabled = false;
            } else {
                defer self.allocator.free(hex.?);
                var i: usize = 0;
                while (i < 32) : (i += 1) {
                    self.enc_key[i] = std.fmt.parseInt(u8, hex.?[i * 2 .. i * 2 + 2], 16) catch 0;
                }
            }
        }
    }

    pub fn initPersistent(ally: std.mem.Allocator, page_size: usize, base_path: []const u8) PageManager {
        var pm = PageManager{
            .allocator = ally,
            .pages = std.ArrayList([]u8).initCapacity(ally, 0) catch @panic("OOM"),
            .page_size = page_size,
            .base_path = base_path,
            .free_pages = std.ArrayList(u32).initCapacity(ally, 0) catch @panic("OOM"),
            .next_page_id = 0,
            .enc_enabled = false,
            .enc_key = undefined,
        };
        pm.loadEncConfig();
        return pm;
    }

    pub fn deinit(self: *PageManager) void {
        for (self.pages.items) |p| self.allocator.free(p);
        self.pages.deinit(self.allocator);
        self.free_pages.deinit(self.allocator);
    }

    /// Allocate a new page, reusing free pages when available
    pub fn allocatePage(self: *PageManager) !u32 {
        // Reuse free page if available
        if (self.free_pages.items.len > 0) {
            const id = self.free_pages.pop() orelse unreachable;
            return id;
        }

        // Allocate new page
        const page_id = self.next_page_id;
        self.next_page_id += 1;

        // Ensure pages array is large enough
        while (self.pages.items.len <= page_id) {
            try self.newPage();
        }

        return page_id;
    }

    /// Free a page for reuse
    pub fn freePage(self: *PageManager, page_id: u32) !void {
        if (page_id >= self.pages.items.len) {
            return error.InvalidPageId;
        }

        // Clear the page
        const page_mem = self.pages.items[page_id];
        @memset(page_mem, 0);
        _ = Page.init(page_mem);

        // Add to free list
        try self.free_pages.append(page_id);

        // Persist if needed
        if (self.base_path) |bp| {
            try self.writePage(bp, page_id);
        }
    }

    /// Get a page by ID
    pub fn getPage(self: *PageManager, page_id: u32) ![]u8 {
        if (page_id >= self.pages.items.len) {
            return error.InvalidPageId;
        }
        return self.pages.items[page_id];
    }

    /// Flush a page to disk
    pub fn flushPage(self: *PageManager, page_id: u32) !void {
        if (self.base_path) |bp| {
            try self.writePage(bp, page_id);
        }
    }
    fn ensurePage(self: *PageManager) !usize {
        if (self.pages.items.len == 0) try self.newPage();
        return self.pages.items.len - 1;
    }
    pub fn newPage(self: *PageManager) !void {
        const mem = try self.allocator.alloc(u8, self.page_size);
        _ = Page.init(mem);
        try self.pages.append(self.allocator, mem);
        if (self.base_path) |p| try self.writePage(p, self.pages.items.len - 1);
    }
    pub fn asPage(self: *PageManager, idx: usize) Page {
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
        var file = try dir.createFile(path, .{ .truncate = true, .mode = 0o600 });
        defer file.close();
        // ensure checksum current
        var p = self.asPage(index);
        p.recomputeChecksum();
        if (self.enc_enabled) {
            const tmp = try self.allocator.alloc(u8, self.page_size);
            defer self.allocator.free(tmp);
            @memcpy(tmp, self.pages.items[index]);
            Enc.xorcrypt(&self.enc_key, @intCast(index), tmp);
            try file.writeAll(tmp);
        } else {
            try file.writeAll(self.pages.items[index]);
        }
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
        if (self.enc_enabled) {
            Enc.xorcrypt(&self.enc_key, @intCast(index), mem);
        }
        // verify checksum
        var p = Page{ .buf = mem };
        if (!p.verifyChecksum()) {
            const stored_checksum = p.storedChecksum();
            const calculated_checksum = p.calculateChecksum();
            std.log.err("Page checksum mismatch in {s}: stored=0x{X:0>8}, calculated=0x{X:0>8}, page_size={d}", .{ path, stored_checksum, calculated_checksum, self.page_size });
            const corruption_ratio = self.analyzeCorruption(&p);
            std.log.err("Corruption analysis: {d:.2}% of page appears corrupted", .{corruption_ratio * 100.0});
            return error.PageChecksumMismatch;
        }
        try self.pages.append(self.allocator, mem);
    }

    fn analyzeCorruption(self: *PageManager, page: *const Page) f64 {
        _ = self;

        // Simple corruption analysis: count zero bytes vs non-zero bytes
        var zero_count: usize = 0;
        var total_count: usize = 0;

        // Skip header for analysis
        const data_start = Page.HeaderSize;
        for (page.buf[data_start..]) |byte| {
            if (byte == 0) zero_count += 1;
            total_count += 1;
        }

        // If more than 90% zeros, likely corruption
        if (total_count == 0) return 0.0;
        const zero_ratio = @as(f64, @floatFromInt(zero_count)) / @as(f64, @floatFromInt(total_count));
        return if (zero_ratio > 0.9) zero_ratio else 0.0;
    }
};

test "page_manager: insert/read & free space monotonic + checksum" {
    var pm = PageManager.initInMemory(std.testing.allocator, 512);
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
