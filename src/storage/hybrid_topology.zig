const std = @import("std");
const page_manager = @import("page_manager.zig");
const node_page = @import("pages/node_page.zig");
const adjacency_page = @import("pages/adjacency_page.zig");
const NodePage = node_page.NodePage;
const AdjacencyPage = adjacency_page.AdjacencyPage;

pub const HybridTopology = struct {
    pub const NodeLocation = struct { page: u32, slot: u16 };

    allocator: std.mem.Allocator,
    page_manager: *page_manager.PageManager,

    // Map of Node ID -> {page_id, slot_id}
    // In a real system, this is an Index. For prototype, we use a Hashmap in memory
    // or we assume Node ID maps somehow to Page ID (e.g. ID >> X).
    // Let's implement a simple in-memory index for now.
    node_index: std.AutoHashMap(u64, NodeLocation),

    // Helper to find free page of a certain type
    // Optimally we'd have Free Lists per PageType.

    pub fn init(allocator: std.mem.Allocator, pm: *page_manager.PageManager) HybridTopology {
        return .{
            .allocator = allocator,
            .page_manager = pm,
            .node_index = std.AutoHashMap(u64, NodeLocation).init(allocator),
        };
    }

    pub fn deinit(self: *HybridTopology) void {
        self.node_index.deinit();
    }

    pub fn createNode(self: *HybridTopology, id: u64) !void {
        // 1. Allocate space on a Node Page
        // Simple strategy: Try last page, else new page.
        var page_id: u32 = 0;
        var new_alloc = false;

        if (self.page_manager.pages.items.len > 0) {
            page_id = @intCast(self.page_manager.pages.items.len - 1);
            _ = try self.page_manager.getPage(page_id);
            // Check if page is Node type or unused
            // Need cast to Page
            // This is hacky access to generic page
            // Ideally PageManager creates Typed Pages
        } else {
            page_id = try self.page_manager.allocatePage();
            new_alloc = true;
        }

        // Load Page
        var raw_slice = try self.page_manager.getPage(page_id);
        // We need mutable pointer to the buffer inside PageManager...
        // page_manager.getPage returns []u8, which is mutable in Zig if ArrayList owns it.
        // Wait, PageManager.getPage returns `![]u8`.

        // Wrap
        var p = page_manager.Page{ .buf = raw_slice };

        // If reusing page, check type
        if (!new_alloc and p.pageType() != .Unused and p.pageType() != .Node) {
            // Allocated page is wrong type, get a new one
            page_id = try self.page_manager.allocatePage();
            raw_slice = try self.page_manager.getPage(page_id);
            p = page_manager.Page{ .buf = raw_slice };
        }

        var np = NodePage.init(&p);

        const record = NodePage.NodeRecord{
            .id = id,
            .labels_ptr = 0,
            .props_ptr = 0,
            .adj_out_head = 0, // No adjacency yet
            .adj_in_head = 0,
            .next_version = 0,
            .min_txn = 1, // Visible from txn 1
            .max_txn = 0,
            .flags = 0,
        };

        const slot = try np.insertNode(record);

        // Save to index
        try self.node_index.put(id, .{ .page = page_id, .slot = slot });

        // Mark dirty
        try self.page_manager.flushPage(page_id);
    }

    pub fn addEdge(self: *HybridTopology, src_id: u64, dst_id: u64, edge_id: u64, type_id: u32, txn_id: u64) !void {
        // 1. Lookup Source Node
        const location = self.node_index.get(src_id) orelse return error.NodeNotFound;

        // 2. Load Node Page
        const raw_slice = try self.page_manager.getPage(location.page);
        var p = page_manager.Page{ .buf = raw_slice };
        var np = NodePage.init(&p);

        const node = try np.getNode(location.slot);

        // 3. Find/Create Adjacency Delta Block
        // We look at adj_out_head.
        // If 0, create new Delta Block.
        // If non-0, check if it's a Delta Block with space.

        var head_ptr = node.adj_out_head;
        var head_page_id: u32 = 0;
        var head_slot_id: u16 = 0;

        // Pointer format: We need a way to store {page_id, slot_id} in u64.
        // Let's assume u64 = (page_id << 16) | slot_id.
        // Max page_id = 2^48 (plenty), Max slot_id = 65535.

        if (head_ptr == 0) {
            // Create new Delta Block
            const new_page_id = try self.page_manager.allocatePage();
            const new_raw = try self.page_manager.getPage(new_page_id);
            var new_p = page_manager.Page{ .buf = new_raw };
            var new_ap = AdjacencyPage.init(&new_p);

            const slot = try new_ap.createDeltaBlock(0); // Next=0

            // Encode ptr
            const new_ptr = (@as(u64, new_page_id) << 16) | slot;

            // Update Node
            try np.setAdjacencyHead(location.slot, .Out, new_ptr);

            head_ptr = new_ptr;
            head_page_id = new_page_id;
            head_slot_id = slot;
        } else {
            head_page_id = @intCast(head_ptr >> 16);
            head_slot_id = @intCast(head_ptr & 0xFFFF);
        }

        // 4. Append to Delta Block
        // Loop retry if block full
        while (true) {
            const adj_raw = try self.page_manager.getPage(head_page_id);
            var adj_p = page_manager.Page{ .buf = adj_raw };
            var ap = AdjacencyPage.init(&adj_p);

            const entry = AdjacencyPage.DeltaEntry{ .op = .Insert, .min_txn = txn_id, .max_txn = 0, .edge = .{ .target_id = dst_id, .edge_id = edge_id, .type_id = type_id, .props_ptr = 0 } };

            if (try ap.appendToDeltaBlock(head_slot_id, entry)) {
                // Success
                try self.page_manager.flushPage(head_page_id);
                break;
            } else {
                // Block full. Create new Delta Block pointing to old head.
                const new_page_id = try self.page_manager.allocatePage();
                const new_raw = try self.page_manager.getPage(new_page_id);
                var new_p = page_manager.Page{ .buf = new_raw };
                var new_ap = AdjacencyPage.init(&new_p);

                const slot = try new_ap.createDeltaBlock(head_ptr); // Point to old head

                // Update Node to point to NEW head
                const new_ptr = (@as(u64, new_page_id) << 16) | slot;
                try np.setAdjacencyHead(location.slot, .Out, new_ptr);

                head_ptr = new_ptr;
                head_page_id = new_page_id;
                head_slot_id = slot;
                // Loop will retry append on new block (which is empty)
            }
        }
    }

    pub const NeighborIterator = struct {
        topology: *HybridTopology,
        // Current Block State
        curr_page_id: u32,
        curr_slot_id: u16,
        curr_idx: u16,
        block_count: u16,
        block_type: AdjacencyPage.BlockType,
        next_block_ptr: u64,
        txn_id: u64,
        initialized: bool = false,

        fn loadBlock(self: *NeighborIterator) !void {
            const raw = try self.topology.page_manager.getPage(self.curr_page_id);
            var p = page_manager.Page{ .buf = raw };
            const slot = p.readSlot(self.curr_slot_id);
            const base_off = slot.off;

            self.block_type = std.meta.intToEnum(AdjacencyPage.BlockType, p.buf[base_off]) catch return error.CorruptBlock;
            self.block_count = std.mem.readInt(u16, p.buf[base_off + 1 ..][0..2], .little);
            self.next_block_ptr = std.mem.readInt(u64, p.buf[base_off + 3 ..][0..8], .little);
            self.curr_idx = 0;
            self.initialized = true;
        }

        pub fn next(self: *NeighborIterator) !?u64 {
            if (!self.initialized) {
                // Check if valid start
                if (self.curr_page_id == 0 and self.curr_slot_id == 0) return null;
                try self.loadBlock();
            }

            while (true) {
                // Check if block exhausted
                if (self.curr_idx >= self.block_count) {
                    if (self.next_block_ptr == 0) return null;

                    // Move to next block
                    self.curr_page_id = @intCast(self.next_block_ptr >> 16);
                    self.curr_slot_id = @intCast(self.next_block_ptr & 0xFFFF);
                    try self.loadBlock();
                    continue;
                }

                // Read current entry
                const raw = try self.topology.page_manager.getPage(self.curr_page_id);
                var p = page_manager.Page{ .buf = raw };
                const slot = p.readSlot(self.curr_slot_id);
                const base_off = slot.off;

                if (self.block_type == .Base) {
                    const offset = base_off + 11 + (@as(usize, self.curr_idx) * 24);
                    const target_id = std.mem.readInt(u64, raw[offset .. offset + 8][0..8], .little);
                    self.curr_idx += 1;
                    return target_id;
                } else {
                    const offset = base_off + 11 + (@as(usize, self.curr_idx) * 41);
                    const op = std.meta.intToEnum(AdjacencyPage.DeltaOp, raw[offset]) catch .Insert;
                    const min_txn = std.mem.readInt(u64, raw[offset + 1 .. offset + 9][0..8], .little);
                    const max_txn = std.mem.readInt(u64, raw[offset + 9 .. offset + 17][0..8], .little);
                    const target_id = std.mem.readInt(u64, raw[offset + 17 .. offset + 25][0..8], .little);

                    self.curr_idx += 1;

                    // Visibility Check
                    const visible = (min_txn <= self.txn_id) and (max_txn == 0 or max_txn > self.txn_id);
                    if (visible and op == .Insert) {
                        return target_id;
                    }
                    // Skip if deleted or invisible
                }
            }
        }
    };

    pub fn getNeighbors(self: *HybridTopology, node_id: u64, txn_id: u64) !NeighborIterator {
        const location = self.node_index.get(node_id) orelse return error.NodeNotFound;

        // Read Node adj_out_head
        const raw_slice = try self.page_manager.getPage(location.page);
        var p = page_manager.Page{ .buf = raw_slice };
        var np = NodePage.init(&p);
        const node = try np.getNode(location.slot);

        return NeighborIterator{
            .topology = self,
            .curr_page_id = @intCast(node.adj_out_head >> 16),
            .curr_slot_id = @intCast(node.adj_out_head & 0xFFFF),
            .curr_idx = 0,
            .block_count = 0,
            .block_type = .Base, // Default, will overwrite
            .next_block_ptr = 0,
            .txn_id = txn_id,
            .initialized = false, // Trigger load on first next()
        };
    }
};
