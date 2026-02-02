const std = @import("std");
const page_manager = @import("../page_manager.zig");
const Page = page_manager.Page;

pub const AdjacencyPage = struct {
    page: *Page,

    // Adjacency Blocks come in two flavors: Base and Delta.
    // We differentiate them via a header byte in the record.

    pub const BlockType = enum(u8) {
        Base = 0,
        Delta = 1,
    };

    // Edge Entry (Compact): 16 bytes
    // [0..8) Target Node ID
    // [8..16) Edge ID | Type ID (Composite)
    pub const EdgeEntry = struct {
        target_id: u64,
        edge_id: u64,
        // type_id stored in edge_id high bits or separate?
        // For simplicity, let's assume edge_id is pure, we store type separately if needed
        // But for research alignment: (target_rid, edge_rid, type_id)

        // Let's use a dense 24-byte layout for memory/disk if we want full fidelity
        // [0..8] target
        // [8..16] edge_id
        // [16..20] type_id
        // [20..24] props_ptr
        type_id: u32,
        props_ptr: u32,
    };

    // Base Block Header:
    // [0..1] Type (0)
    // [1..3] Count
    // [3..11] Next Block Ptr
    // [11..] EdgeEntries...

    // Delta Block Header:
    // [0..1] Type (1)
    // [1..3] Count
    // [3..11] Next Block Ptr
    // [11..] DeltaEntries...

    // Delta Entry:
    // [0..1] Op (Insert/Delete)
    // [1..9] Txn ID (Begin)
    // [9..17] Txn ID (End)
    // [17..41] EdgeEntry (24 bytes)

    pub const DeltaOp = enum(u8) {
        Insert = 0,
        Delete = 1,
    };

    pub const DeltaEntry = struct {
        op: DeltaOp,
        min_txn: u64,
        max_txn: u64,
        edge: EdgeEntry,
    };

    pub fn init(page: *Page) AdjacencyPage {
        if (page.pageType() == .Unused) {
            page.setPageType(.Adjacency);
        }
        std.debug.assert(page.pageType() == .Adjacency);
        return AdjacencyPage{ .page = page };
    }

    pub fn createBaseBlock(self: *AdjacencyPage, next_ptr: u64, edges: []const EdgeEntry) !u16 {
        // Calculate size: 11 bytes header + (24 * count)
        const size = 11 + (edges.len * 24);
        if (size > self.page.freeSpace()) return error.NoSpace; // Should allocate new page in real engine

        // Ideally we write directly to the page buffer
        // But Page interface expects a slice. We'll alloc temp.
        // TODO: Enhance Page interface for direct writer to avoid alloc
        var buf = try std.heap.page_allocator.alloc(u8, size);
        defer std.heap.page_allocator.free(buf);

        buf[0] = @intFromEnum(BlockType.Base);
        std.mem.writeInt(u16, buf[1..3], @intCast(edges.len), .little);
        std.mem.writeInt(u64, buf[3..11], next_ptr, .little);

        var offset: usize = 11;
        for (edges) |e| {
            std.mem.writeInt(u64, buf[offset .. offset + 8][0..8], e.target_id, .little);
            std.mem.writeInt(u64, buf[offset + 8 .. offset + 16][0..8], e.edge_id, .little);
            std.mem.writeInt(u32, buf[offset + 16 .. offset + 20][0..4], e.type_id, .little);
            std.mem.writeInt(u32, buf[offset + 20 .. offset + 24][0..4], e.props_ptr, .little);
            offset += 24;
        }

        return self.page.insert(buf);
    }

    pub fn createDeltaBlock(self: *AdjacencyPage, next_ptr: u64) !u16 {
        // Create an empty delta block with space for X entries?
        // Or just one entry?
        // Research suggests "Delta Chains". We can start with a block holding 1 entry and resize,
        // or a block with some capacity.
        // For simplicity: each Delta Block holds EXACTLY ONE entry (linked list style)
        // OR a small array. A small array (e.g. 4 entries) reduces pointer chasing.
        // Let's implement capacity=4.

        const capacity = 4;
        const size = 11 + (capacity * 41); // 41 bytes per delta entry

        // We initialize with count=0
        var buf = try std.heap.page_allocator.alloc(u8, size);
        defer std.heap.page_allocator.free(buf);

        @memset(buf, 0); // Zero out
        buf[0] = @intFromEnum(BlockType.Delta);
        std.mem.writeInt(u16, buf[1..3], 0, .little); // Count = 0
        std.mem.writeInt(u64, buf[3..11], next_ptr, .little);

        return self.page.insert(buf);
    }

    pub fn appendToDeltaBlock(self: *AdjacencyPage, slot_id: u16, entry: DeltaEntry) !bool {
        // Read block header
        const slot = self.page.readSlot(slot_id);
        const base_off = slot.off;

        const count = std.mem.readInt(u16, self.page.buf[base_off + 1 ..][0..2], .little);
        const capacity = 4; // Hardcoded matches createDeltaBlock

        if (count >= capacity) return false; // Full

        // Calculate offset
        const entry_off = base_off + 11 + (@as(usize, count) * 41);

        // Write entry
        self.page.buf[entry_off] = @intFromEnum(entry.op);
        std.mem.writeInt(u64, self.page.buf[entry_off + 1 ..][0..8], entry.min_txn, .little);
        std.mem.writeInt(u64, self.page.buf[entry_off + 9 ..][0..8], entry.max_txn, .little);

        // Edge data
        std.mem.writeInt(u64, self.page.buf[entry_off + 17 ..][0..8], entry.edge.target_id, .little);
        std.mem.writeInt(u64, self.page.buf[entry_off + 25 ..][0..8], entry.edge.edge_id, .little);
        std.mem.writeInt(u32, self.bufStart(entry_off + 33)[0..4], entry.edge.type_id, .little);
        std.mem.writeInt(u32, self.bufStart(entry_off + 37)[0..4], entry.edge.props_ptr, .little);

        // Update count
        std.mem.writeInt(u16, self.page.buf[base_off + 1 ..][0..2], count + 1, .little);
        self.page.markDirty();

        return true;
    }

    fn bufStart(self: *AdjacencyPage, off: usize) []u8 {
        return self.page.buf[off..];
    }

    // Iterate entries in a block
    pub const Iterator = struct {
        page: *AdjacencyPage,
        base_off: u16,
        count: u16,
        current: u16,
        block_type: BlockType,

        pub fn nextBase(self: *Iterator) ?EdgeEntry {
            if (self.block_type != .Base) return null;
            if (self.current >= self.count) return null;

            const offset = self.base_off + 11 + (@as(usize, self.current) * 24);
            const buf = self.page.page.buf;

            const e = EdgeEntry{
                .target_id = std.mem.readInt(u64, buf[offset .. offset + 8][0..8], .little),
                .edge_id = std.mem.readInt(u64, buf[offset + 8 .. offset + 16][0..8], .little),
                .type_id = std.mem.readInt(u32, buf[offset + 16 .. offset + 20][0..4], .little),
                .props_ptr = std.mem.readInt(u32, buf[offset + 20 .. offset + 24][0..4], .little),
            };
            self.current += 1;
            return e;
        }

        pub fn nextDelta(self: *Iterator) ?DeltaEntry {
            if (self.block_type != .Delta) return null;
            if (self.current >= self.count) return null;

            const offset = self.base_off + 11 + (@as(usize, self.current) * 41);
            const buf = self.page.page.buf;

            const op_byte = buf[offset];
            const e = DeltaEntry{
                .op = std.meta.intToEnum(DeltaOp, op_byte) catch .Insert,
                .min_txn = std.mem.readInt(u64, buf[offset + 1 .. offset + 9][0..8], .little),
                .max_txn = std.mem.readInt(u64, buf[offset + 9 .. offset + 17][0..8], .little),
                .edge = EdgeEntry{
                    .target_id = std.mem.readInt(u64, buf[offset + 17 .. offset + 25][0..8], .little),
                    .edge_id = std.mem.readInt(u64, buf[offset + 25 .. offset + 33][0..8], .little),
                    .type_id = std.mem.readInt(u32, buf[offset + 33 .. offset + 37][0..4], .little),
                    .props_ptr = std.mem.readInt(u32, buf[offset + 37 .. offset + 41][0..4], .little),
                },
            };
            self.current += 1;
            return e;
        }
    };

    pub fn iterator(self: *AdjacencyPage, slot_id: u16) !Iterator {
        const slot = self.page.readSlot(slot_id);
        const base_off = slot.off;

        const type_byte = self.page.buf[base_off];
        const count = std.mem.readInt(u16, self.page.buf[base_off + 1 ..][0..2], .little);

        return Iterator{
            .page = self,
            .base_off = base_off,
            .count = count,
            .current = 0,
            .block_type = std.meta.intToEnum(BlockType, type_byte) catch return error.CorruptBlock,
        };
    }
};

test "adjacency page operations" {
    var raw_buf: [8192]u8 = undefined;
    var page = Page.init(&raw_buf);
    var adj_page = AdjacencyPage.init(&page);

    // Test 1: Create Base Block
    const edges = [_]AdjacencyPage.EdgeEntry{
        .{ .target_id = 10, .edge_id = 100, .type_id = 1, .props_ptr = 0 },
        .{ .target_id = 20, .edge_id = 200, .type_id = 1, .props_ptr = 0 },
    };
    const base_slot = try adj_page.createBaseBlock(0, &edges);

    var it = try adj_page.iterator(base_slot);
    const e1 = it.nextBase().?;
    try std.testing.expectEqual(@as(u64, 10), e1.target_id);
    const e2 = it.nextBase().?;
    try std.testing.expectEqual(@as(u64, 20), e2.target_id);
    try std.testing.expect(it.nextBase() == null);

    // Test 2: Create Delta Block & Append
    const delta_slot = try adj_page.createDeltaBlock(base_slot); // Points to base

    const delta1 = AdjacencyPage.DeltaEntry{ .op = .Insert, .min_txn = 101, .max_txn = 0, .edge = .{ .target_id = 30, .edge_id = 300, .type_id = 1, .props_ptr = 0 } };

    const appended = try adj_page.appendToDeltaBlock(delta_slot, delta1);
    try std.testing.expect(appended);

    var it_d = try adj_page.iterator(delta_slot);
    const d1 = it_d.nextDelta().?;
    try std.testing.expectEqual(@as(u64, 30), d1.edge.target_id);
    try std.testing.expectEqual(@as(u64, 101), d1.min_txn);
}
