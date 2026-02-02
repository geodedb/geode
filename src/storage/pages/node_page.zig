const std = @import("std");
const page_manager = @import("../page_manager.zig");
const Page = page_manager.Page;
const interface = @import("interface");

pub const NodePage = struct {
    page: *Page,

    // Node Record Layout:
    // [0..8)   : u64 id (internal node id / sequence)
    // [8..16)  : u64 labels_ptr (msgpack or bitset of labels)
    // [16..24) : u64 props_ptr (pointer to properties page/slot)
    // [24..32) : u64 adj_out_head (head of adjacency chain)
    // [32..40) : u64 adj_in_head (head of adjacency chain)
    // [40..48) : u64 next_version (MVCC chain)
    // [48..56) : u64 min_txn (MVCC)
    // [56..64) : u64 max_txn (MVCC)
    // [64..66) : u16 flags
    // Total: 66 bytes

    pub const RecordSize = 66;

    pub const NodeRecord = struct {
        id: u64,
        labels_ptr: u64,
        props_ptr: u64,
        adj_out_head: u64,
        adj_in_head: u64,
        next_version: u64,
        min_txn: u64,
        max_txn: u64,
        flags: u16,
    };

    pub fn init(page: *Page) NodePage {
        if (page.pageType() == .Unused) {
            page.setPageType(.Node);
        }
        std.debug.assert(page.pageType() == .Node);
        return NodePage{ .page = page };
    }

    pub fn insertNode(self: *NodePage, record: NodeRecord) !u16 {
        var buf: [RecordSize]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], record.id, .little);
        std.mem.writeInt(u64, buf[8..16], record.labels_ptr, .little);
        std.mem.writeInt(u64, buf[16..24], record.props_ptr, .little);
        std.mem.writeInt(u64, buf[24..32], record.adj_out_head, .little);
        std.mem.writeInt(u64, buf[32..40], record.adj_in_head, .little);
        std.mem.writeInt(u64, buf[40..48], record.next_version, .little);
        std.mem.writeInt(u64, buf[48..56], record.min_txn, .little);
        std.mem.writeInt(u64, buf[56..64], record.max_txn, .little);
        std.mem.writeInt(u16, buf[64..66], record.flags, .little);

        return self.page.insert(&buf);
    }

    pub fn getNode(self: *const NodePage, slot_id: u16) !NodeRecord {
        const bytes = try self.page.read(slot_id);
        if (bytes.len != RecordSize) return error.CorruptRecord;

        return NodeRecord{
            .id = std.mem.readInt(u64, bytes[0..8], .little),
            .labels_ptr = std.mem.readInt(u64, bytes[8..16], .little),
            .props_ptr = std.mem.readInt(u64, bytes[16..24], .little),
            .adj_out_head = std.mem.readInt(u64, bytes[24..32], .little),
            .adj_in_head = std.mem.readInt(u64, bytes[32..40], .little),
            .next_version = std.mem.readInt(u64, bytes[40..48], .little),
            .min_txn = std.mem.readInt(u64, bytes[48..56], .little),
            .max_txn = std.mem.readInt(u64, bytes[56..64], .little),
            .flags = std.mem.readInt(u16, bytes[64..66], .little),
        };
    }

    // Helper to update adjacency head safely (common operation)
    pub fn setAdjacencyHead(self: *NodePage, slot_id: u16, direction: enum { Out, In }, new_head: u64) !void {
        // We need to mutate the page buffer in place.
        // Page.read returns const slice. But we know the offset from readSlot.
        const slot = self.page.readSlot(slot_id);
        const offset = slot.off;

        // Offset within record: Out=24, In=32
        var field_off: usize = 24;
        if (direction == .In) field_off = 32;

        const abs_off = @as(usize, offset) + field_off;

        std.mem.writeInt(u64, self.page.buf[abs_off..][0..8], new_head, .little);
        self.page.markDirty();
    }
};

test "node page operations" {
    var raw_buf: [8192]u8 = undefined;
    var page = Page.init(&raw_buf);
    var node_page = NodePage.init(&page);

    const r = NodePage.NodeRecord{
        .id = 1,
        .labels_ptr = 0,
        .props_ptr = 0,
        .adj_out_head = 0,
        .adj_in_head = 0,
        .next_version = 0,
        .min_txn = 100,
        .max_txn = 0, // infinity
        .flags = 0,
    };

    const slot = try node_page.insertNode(r);
    const read_back = try node_page.getNode(slot);
    try std.testing.expectEqual(r.id, read_back.id);
    try std.testing.expectEqual(r.min_txn, read_back.min_txn);

    try node_page.setAdjacencyHead(slot, .Out, 9999);
    const updated = try node_page.getNode(slot);
    try std.testing.expectEqual(@as(u64, 9999), updated.adj_out_head);
}
