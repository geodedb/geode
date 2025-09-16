const std = @import("std");

// Local SchemaCol definition for testing
const SchemaCol = struct { name: []const u8, type: []const u8 };

/// Text formatter for consistent multi-format outputs
pub const TextFormatter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TextFormatter {
        return .{ .allocator = allocator };
    }

    pub fn formatSchema(self: *TextFormatter, cols: []const SchemaCol) ![]u8 {
        var buf = std.ArrayList(u8).initCapacity(self.allocator, 0) catch return error.OutOfMemory;
        defer buf.deinit(self.allocator);

        const writer = buf.writer(self.allocator);

        // Header
        try writer.writeAll("Schema:\n");
        try writer.writeAll("--------\n");

        for (cols, 0..) |col, i| {
            try writer.print("{d}. {s} ({s})\n", .{ i + 1, col.name, col.type });
        }

        if (cols.len == 0) {
            try writer.writeAll("(no columns)\n");
        }

        return buf.toOwnedSlice(self.allocator);
    }

    pub fn formatBindings(self: *TextFormatter, rows_json: []const u8, ordered: bool, order_keys: []const []const u8) ![]u8 {
        var buf = std.ArrayList(u8).initCapacity(self.allocator, 0) catch return error.OutOfMemory;
        defer buf.deinit(self.allocator);

        const writer = buf.writer(self.allocator);

        // Parse JSON rows for text formatting
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, rows_json, .{}) catch {
            try writer.writeAll("Error parsing JSON data\n");
            return buf.toOwnedSlice(self.allocator);
        };
        defer parsed.deinit();

        if (parsed.value != .array) {
            try writer.writeAll("Invalid data format\n");
            return buf.toOwnedSlice(self.allocator);
        }

        const rows = parsed.value.array.items;

        // Header info
        if (ordered) {
            try writer.writeAll("Ordered result");
            if (order_keys.len > 0) {
                try writer.writeAll(" (ordered by: ");
                for (order_keys, 0..) |key, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.writeAll(key);
                }
                try writer.writeAll(")");
            }
            try writer.writeAll("\n");
        } else {
            try writer.writeAll("Unordered result\n");
        }

        try writer.print("Rows: {d}\n", .{rows.len});
        try writer.writeAll("--------\n");

        if (rows.len == 0) {
            try writer.writeAll("(no rows)\n");
            return buf.toOwnedSlice(self.allocator);
        }

        // Extract column names from first row
        var column_names = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch return error.OutOfMemory;
        defer column_names.deinit(self.allocator);

        if (rows[0] == .object) {
            var iter = rows[0].object.iterator();
            while (iter.next()) |entry| {
                try column_names.append(self.allocator, entry.key_ptr.*);
            }
        }

        // Calculate column widths
        var col_widths = try self.allocator.alloc(usize, column_names.items.len);
        defer self.allocator.free(col_widths);

        // Initialize with header widths
        for (column_names.items, 0..) |name, i| {
            col_widths[i] = name.len;
        }

        // Check data widths
        for (rows) |row| {
            if (row == .object) {
                for (column_names.items, 0..) |col_name, i| {
                    if (row.object.get(col_name)) |value| {
                        const value_str = try self.jsonValueToString(value);
                        defer self.allocator.free(value_str);
                        col_widths[i] = @max(col_widths[i], value_str.len);
                    }
                }
            }
        }

        // Print header
        for (column_names.items, 0..) |name, i| {
            if (i > 0) try writer.writeAll(" | ");
            try writer.print("{s}", .{name});

            // Pad to width
            const padding = col_widths[i] - name.len;
            var p: usize = 0;
            while (p < padding) : (p += 1) {
                try writer.writeAll(" ");
            }
        }
        try writer.writeAll("\n");

        // Print separator
        for (column_names.items, 0..) |_, i| {
            if (i > 0) try writer.writeAll("-+-");
            var w: usize = 0;
            while (w < col_widths[i]) : (w += 1) {
                try writer.writeAll("-");
            }
        }
        try writer.writeAll("\n");

        // Print data rows
        for (rows) |row| {
            if (row == .object) {
                for (column_names.items, 0..) |col_name, i| {
                    if (i > 0) try writer.writeAll(" | ");

                    if (row.object.get(col_name)) |value| {
                        const value_str = try self.jsonValueToString(value);
                        defer self.allocator.free(value_str);
                        try writer.print("{s}", .{value_str});

                        // Pad to width
                        const padding = col_widths[i] - value_str.len;
                        var p: usize = 0;
                        while (p < padding) : (p += 1) {
                            try writer.writeAll(" ");
                        }
                    } else {
                        try writer.writeAll("NULL");
                        const padding = col_widths[i] - 4;
                        var p: usize = 0;
                        while (p < padding) : (p += 1) {
                            try writer.writeAll(" ");
                        }
                    }
                }
                try writer.writeAll("\n");
            }
        }

        return buf.toOwnedSlice(self.allocator);
    }

    pub fn formatError(self: *TextFormatter, code: []const u8, message: []const u8, anchor: []const u8) ![]u8 {
        var buf = std.ArrayList(u8).initCapacity(self.allocator, 0) catch return error.OutOfMemory;
        defer buf.deinit(self.allocator);

        const writer = buf.writer(self.allocator);

        try writer.writeAll("ERROR: ");
        try writer.writeAll(message);
        try writer.writeAll("\n");
        try writer.print("Code: {s}\n", .{code});

        if (anchor.len > 0) {
            try writer.print("Reference: ISO/IEC 39075 §{s}\n", .{anchor});
        }

        return buf.toOwnedSlice(self.allocator);
    }

    pub fn formatExplain(self: *TextFormatter, json_payload: []const u8) ![]u8 {
        var buf = std.ArrayList(u8).initCapacity(self.allocator, 0) catch return error.OutOfMemory;
        defer buf.deinit(self.allocator);

        const writer = buf.writer(self.allocator);

        try writer.writeAll("Query Plan:\n");
        try writer.writeAll("-----------\n");

        // Parse and format the explain JSON
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_payload, .{}) catch {
            try writer.writeAll("Error parsing explain data\n");
            return buf.toOwnedSlice(self.allocator);
        };
        defer parsed.deinit();

        if (parsed.value == .object) {
            if (parsed.value.object.get("logical")) |logical| {
                if (logical == .array) {
                    for (logical.array.items, 0..) |op, i| {
                        try writer.print("{d}. ", .{i + 1});
                        if (op == .object) {
                            if (op.object.get("op")) |op_name| {
                                if (op_name == .string) {
                                    try writer.print("{s}", .{op_name.string});

                                    // Add additional details if available
                                    if (op.object.get("mode")) |mode| {
                                        if (mode == .string) {
                                            try writer.print(" ({s})", .{mode.string});
                                        }
                                    }
                                }
                            }
                        }
                        try writer.writeAll("\n");
                    }
                }
            }

            // Add properties section
            if (parsed.value.object.get("properties")) |props| {
                try writer.writeAll("\nProperties:\n");
                if (props == .object) {
                    var iter = props.object.iterator();
                    while (iter.next()) |entry| {
                        try writer.print("  {s}: ", .{entry.key_ptr.*});
                        const prop_str = try self.jsonValueToString(entry.value_ptr.*);
                        defer self.allocator.free(prop_str);
                        try writer.print("{s}\n", .{prop_str});
                    }
                }
            }
        }

        return buf.toOwnedSlice(self.allocator);
    }

    pub fn formatProfile(self: *TextFormatter, json_payload: []const u8) ![]u8 {
        var buf = std.ArrayList(u8).initCapacity(self.allocator, 0) catch return error.OutOfMemory;
        defer buf.deinit(self.allocator);

        const writer = buf.writer(self.allocator);

        try writer.writeAll("Query Profile:\n");
        try writer.writeAll("==============\n\n");

        // Parse the profile JSON
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_payload, .{}) catch {
            try writer.writeAll("Error parsing profile data\n");
            return buf.toOwnedSlice(self.allocator);
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            try writer.writeAll("Invalid profile format\n");
            return buf.toOwnedSlice(self.allocator);
        }

        const root = parsed.value.object;

        // Profile version and metadata
        try self.formatProfileHeader(&writer, root);
        
        // Timing and performance metrics
        try self.formatProfileMetrics(&writer, root);
        
        // Memory information with detailed breakdown
        try self.formatProfileMemory(&writer, root);
        
        // Spill information
        try self.formatProfileSpills(&writer, root);
        
        // Operator tree with enhanced details
        try self.formatProfileOperators(&writer, root);
        
        // Peak memory contributors
        try self.formatProfileMemoryContributors(&writer, root);
        
        // Estimates vs actuals (if available)
        try self.formatProfileEstimates(&writer, root);
        
        // WAL and storage metrics
        try self.formatProfileStorage(&writer, root);
        
        // Transaction information
        try self.formatProfileTransactions(&writer, root);

        return buf.toOwnedSlice(self.allocator);
    }
    
    fn formatProfileHeader(self: *TextFormatter, writer: anytype, root: std.json.ObjectMap) !void {
        _ = self;
        
        // Profile version
        if (root.get("profile_version")) |ver| {
            if (ver == .integer) {
                try writer.print("Profile Version: {d}\n", .{ver.integer});
            }
        }
        
        // Query text (if available)
        if (root.get("query_text")) |query| {
            if (query == .string) {
                try writer.print("Query: {s}\n", .{query.string});
            }
        }
        
        // Execution timestamp
        if (root.get("execution_timestamp")) |ts| {
            if (ts == .integer) {
                try writer.print("Executed: {d}\n", .{ts.integer});
            }
        }
        
        try writer.writeAll("\n");
    }
    
    fn formatProfileMetrics(self: *TextFormatter, writer: anytype, root: std.json.ObjectMap) !void {
        _ = self;
        
        try writer.writeAll("Performance Metrics:\n");
        try writer.writeAll("-------------------\n");
        
        // Timing information
        if (root.get("total_time_ns")) |time| {
            if (time == .integer) {
                const ms = @as(f64, @floatFromInt(time.integer)) / 1_000_000.0;
                try writer.print("Total Time: {d:.2} ms\n", .{ms});
            }
        }
        
        // CPU time breakdown
        if (root.get("cpu_time_ns")) |cpu_time| {
            if (cpu_time == .integer) {
                const ms = @as(f64, @floatFromInt(cpu_time.integer)) / 1_000_000.0;
                try writer.print("CPU Time: {d:.2} ms\n", .{ms});
            }
        }
        
        // I/O wait time
        if (root.get("io_wait_ns")) |io_time| {
            if (io_time == .integer) {
                const ms = @as(f64, @floatFromInt(io_time.integer)) / 1_000_000.0;
                try writer.print("I/O Wait: {d:.2} ms\n", .{ms});
            }
        }
        
        // Rows processed
        if (root.get("rows_processed")) |rows| {
            if (rows == .integer) {
                try writer.print("Rows Processed: {d}\n", .{rows.integer});
            }
        }
        
        // Throughput
        if (root.get("total_time_ns")) |time| {
            if (root.get("rows_processed")) |rows| {
                if (time == .integer and rows == .integer and time.integer > 0) {
                    const seconds = @as(f64, @floatFromInt(time.integer)) / 1_000_000_000.0;
                    const throughput = @as(f64, @floatFromInt(rows.integer)) / seconds;
                    try writer.print("Throughput: {d:.0} rows/sec\n", .{throughput});
                }
            }
        }
        
        try writer.writeAll("\n");
    }
    
    fn formatProfileMemory(self: *TextFormatter, writer: anytype, root: std.json.ObjectMap) !void {
        _ = self;
        
        try writer.writeAll("Memory Usage:\n");
        try writer.writeAll("-------------\n");
        
        // Peak memory
        if (root.get("peak_memory_bytes")) |mem| {
            if (mem == .integer) {
                const mb = @as(f64, @floatFromInt(mem.integer)) / (1024.0 * 1024.0);
                try writer.print("Peak Memory: {d:.2} MB\n", .{mb});
            }
        }
        
        // Current memory
        if (root.get("current_memory_bytes")) |mem| {
            if (mem == .integer) {
                const mb = @as(f64, @floatFromInt(mem.integer)) / (1024.0 * 1024.0);
                try writer.print("Current Memory: {d:.2} MB\n", .{mb});
            }
        }
        
        // Memory efficiency
        if (root.get("memory_efficiency")) |eff| {
            if (eff == .float) {
                try writer.print("Memory Efficiency: {d:.1}%\n", .{eff.float * 100.0});
            }
        }
        
        // Fragmentation
        if (root.get("memory_fragmentation")) |frag| {
            if (frag == .float) {
                try writer.print("Memory Fragmentation: {d:.1}%\n", .{frag.float * 100.0});
            }
        }
        
        try writer.writeAll("\n");
    }
    
    fn formatProfileSpills(self: *TextFormatter, writer: anytype, root: std.json.ObjectMap) !void {
        _ = self;
        
        var has_spills = false;
        
        // Check for any spill information
        const spill_types = [_][]const u8{ "sort_spills", "hashagg_spills", "join_spills", "index_spills" };
        
        for (spill_types) |spill_type| {
            if (root.get(spill_type)) |spills| {
                if (spills == .integer and spills.integer > 0) {
                    if (!has_spills) {
                        try writer.writeAll("Spill Information:\n");
                        try writer.writeAll("-----------------\n");
                        has_spills = true;
                    }
                    
                    const display_name = if (std.mem.eql(u8, spill_type, "sort_spills")) "Sort Spills"
                        else if (std.mem.eql(u8, spill_type, "hashagg_spills")) "HashAgg Spills"
                        else if (std.mem.eql(u8, spill_type, "join_spills")) "Join Spills"
                        else if (std.mem.eql(u8, spill_type, "index_spills")) "Index Spills"
                        else spill_type;
                    
                    try writer.print("{s}: {d}\n", .{ display_name, spills.integer });
                }
            }
        }
        
        // Spill bytes
        if (root.get("total_spill_bytes")) |bytes| {
            if (bytes == .integer and bytes.integer > 0) {
                if (!has_spills) {
                    try writer.writeAll("Spill Information:\n");
                    try writer.writeAll("-----------------\n");
                    has_spills = true;
                }
                const mb = @as(f64, @floatFromInt(bytes.integer)) / (1024.0 * 1024.0);
                try writer.print("Total Spill Size: {d:.2} MB\n", .{mb});
            }
        }
        
        if (!has_spills) {
            try writer.writeAll("Spill Information: None\n");
        }
        
        try writer.writeAll("\n");
    }
    
    fn formatProfileOperators(self: *TextFormatter, writer: anytype, root: std.json.ObjectMap) !void {
        try writer.writeAll("Operator Tree:\n");
        try writer.writeAll("--------------\n");

        // Process operators
        if (root.get("ops")) |ops| {
            if (ops == .array) {
                for (ops.array.items) |op| {
                    if (op == .object) {
                        try self.formatOperatorDetailed(writer, op.object, 0);
                    }
                }
            }
        }
        
        try writer.writeAll("\n");
    }
    
    fn formatProfileMemoryContributors(self: *TextFormatter, writer: anytype, root: std.json.ObjectMap) !void {
        _ = self;
        
        // Peak memory contributors
        if (root.get("peak_memory_contributors")) |contributors| {
            if (contributors == .array and contributors.array.items.len > 0) {
                try writer.writeAll("Peak Memory Contributors:\n");
                try writer.writeAll("------------------------\n");
                for (contributors.array.items, 0..) |contrib, i| {
                    if (contrib == .object) {
                        if (contrib.object.get("name")) |name| {
                            if (name == .string) {
                                try writer.print("{d}. {s}", .{ i + 1, name.string });
                                if (contrib.object.get("bytes")) |bytes| {
                                    if (bytes == .integer) {
                                        const kb = @as(f64, @floatFromInt(bytes.integer)) / 1024.0;
                                        try writer.print(" ({d:.1} KB)", .{kb});
                                    }
                                }
                                if (contrib.object.get("percentage")) |pct| {
                                    if (pct == .float) {
                                        try writer.print(" - {d:.1}%", .{pct.float * 100.0});
                                    }
                                }
                                try writer.writeAll("\n");
                            }
                        }
                    }
                }
                try writer.writeAll("\n");
            }
        }
    }
    
    fn formatProfileEstimates(self: *TextFormatter, writer: anytype, root: std.json.ObjectMap) !void {
        _ = self;
        
        if (root.get("estimate_accuracy")) |accuracy| {
            try writer.writeAll("Estimate Accuracy:\n");
            try writer.writeAll("------------------\n");
            
            if (accuracy == .object) {
                if (accuracy.object.get("row_count_accuracy")) |row_acc| {
                    if (row_acc == .float) {
                        try writer.print("Row Count Estimates: {d:.1}% accurate\n", .{row_acc.float * 100.0});
                    }
                }
                
                if (accuracy.object.get("selectivity_accuracy")) |sel_acc| {
                    if (sel_acc == .float) {
                        try writer.print("Selectivity Estimates: {d:.1}% accurate\n", .{sel_acc.float * 100.0});
                    }
                }
                
                if (accuracy.object.get("cost_accuracy")) |cost_acc| {
                    if (cost_acc == .float) {
                        try writer.print("Cost Estimates: {d:.1}% accurate\n", .{cost_acc.float * 100.0});
                    }
                }
            }
            
            try writer.writeAll("\n");
        }
    }
    
    fn formatProfileStorage(self: *TextFormatter, writer: anytype, root: std.json.ObjectMap) !void {
        _ = self;
        
        var has_storage_info = false;
        
        // WAL information
        if (root.get("wal_writes")) |wal_writes| {
            if (wal_writes == .integer and wal_writes.integer > 0) {
                if (!has_storage_info) {
                    try writer.writeAll("Storage & WAL:\n");
                    try writer.writeAll("--------------\n");
                    has_storage_info = true;
                }
                try writer.print("WAL Writes: {d}\n", .{wal_writes.integer});
            }
        }
        
        if (root.get("wal_bytes")) |wal_bytes| {
            if (wal_bytes == .integer and wal_bytes.integer > 0) {
                if (!has_storage_info) {
                    try writer.writeAll("Storage & WAL:\n");
                    try writer.writeAll("--------------\n");
                    has_storage_info = true;
                }
                const kb = @as(f64, @floatFromInt(wal_bytes.integer)) / 1024.0;
                try writer.print("WAL Bytes Written: {d:.1} KB\n", .{kb});
            }
        }
        
        // Page I/O
        if (root.get("pages_read")) |pages_read| {
            if (pages_read == .integer and pages_read.integer > 0) {
                if (!has_storage_info) {
                    try writer.writeAll("Storage & WAL:\n");
                    try writer.writeAll("--------------\n");
                    has_storage_info = true;
                }
                try writer.print("Pages Read: {d}\n", .{pages_read.integer});
            }
        }
        
        if (root.get("pages_written")) |pages_written| {
            if (pages_written == .integer and pages_written.integer > 0) {
                if (!has_storage_info) {
                    try writer.writeAll("Storage & WAL:\n");
                    try writer.writeAll("--------------\n");
                    has_storage_info = true;
                }
                try writer.print("Pages Written: {d}\n", .{pages_written.integer});
            }
        }
        
        if (has_storage_info) {
            try writer.writeAll("\n");
        }
    }
    
    fn formatProfileTransactions(self: *TextFormatter, writer: anytype, root: std.json.ObjectMap) !void {
        _ = self;
        
        var has_txn_info = false;
        
        if (root.get("transaction_id")) |txn_id| {
            if (txn_id == .integer) {
                if (!has_txn_info) {
                    try writer.writeAll("Transaction Information:\n");
                    try writer.writeAll("-----------------------\n");
                    has_txn_info = true;
                }
                try writer.print("Transaction ID: {d}\n", .{txn_id.integer});
            }
        }
        
        if (root.get("isolation_level")) |iso_level| {
            if (iso_level == .string) {
                if (!has_txn_info) {
                    try writer.writeAll("Transaction Information:\n");
                    try writer.writeAll("-----------------------\n");
                    has_txn_info = true;
                }
                try writer.print("Isolation Level: {s}\n", .{iso_level.string});
            }
        }
        
        if (root.get("locks_acquired")) |locks| {
            if (locks == .integer and locks.integer > 0) {
                if (!has_txn_info) {
                    try writer.writeAll("Transaction Information:\n");
                    try writer.writeAll("-----------------------\n");
                    has_txn_info = true;
                }
                try writer.print("Locks Acquired: {d}\n", .{locks.integer});
            }
        }
        
        if (has_txn_info) {
            try writer.writeAll("\n");
        }
    }

    fn formatOperatorDetailed(self: *TextFormatter, writer: anytype, op: std.json.ObjectMap, indent: usize) !void {
        // Indentation
        var i: usize = 0;
        while (i < indent) : (i += 1) {
            try writer.writeAll("  ");
        }

        // Operator name with enhanced details
        if (op.get("op")) |op_name| {
            if (op_name == .string) {
                try writer.print("→ {s}", .{op_name.string});

                // Special handling for different operator types
                if (std.mem.eql(u8, op_name.string, "NodeIndexScan") or std.mem.eql(u8, op_name.string, "NodeScan")) {
                    try self.formatScanOperator(writer, op);
                } else if (std.mem.eql(u8, op_name.string, "HashJoin") or std.mem.eql(u8, op_name.string, "NestedLoopJoin")) {
                    try self.formatJoinOperator(writer, op);
                } else if (std.mem.eql(u8, op_name.string, "Sort")) {
                    try self.formatSortOperator(writer, op);
                } else if (std.mem.eql(u8, op_name.string, "HashAgg")) {
                    try self.formatAggregateOperator(writer, op);
                }
            }
        }

        // Row counts with estimates vs actuals
        try self.formatRowCounts(writer, op);

        // Timing information
        try self.formatOperatorTiming(writer, op);

        // Memory usage
        try self.formatOperatorMemory(writer, op);
        
        // Cost information
        try self.formatOperatorCost(writer, op);

        try writer.writeAll("\n");
    }
    
    fn formatScanOperator(self: *TextFormatter, writer: anytype, op: std.json.ObjectMap) !void {
        _ = self;
        
        if (op.get("index_name")) |idx_name| {
            if (idx_name == .string) {
                try writer.print(" [index: {s}", .{idx_name.string});
                
                if (op.get("selectivity_est")) |sel| {
                    if (sel == .float) {
                        try writer.print(", selectivity: {d:.4}", .{sel.float});
                    } else if (sel == .number_string) {
                        try writer.print(", selectivity: {s}", .{sel.number_string});
                    }
                }
                
                if (op.get("index_condition")) |cond| {
                    if (cond == .string) {
                        try writer.print(", condition: {s}", .{cond.string});
                    }
                }
                
                try writer.writeAll("]");
            }
        }
        
        if (op.get("table_name")) |table| {
            if (table == .string) {
                try writer.print(" [table: {s}]", .{table.string});
            }
        }
    }
    
    fn formatJoinOperator(self: *TextFormatter, writer: anytype, op: std.json.ObjectMap) !void {
        _ = self;
        
        if (op.get("join_type")) |join_type| {
            if (join_type == .string) {
                try writer.print(" [{s}]", .{join_type.string});
            }
        }
        
        if (op.get("join_condition")) |condition| {
            if (condition == .string) {
                try writer.print(" [on: {s}]", .{condition.string});
            }
        }
        
        if (op.get("build_side")) |build| {
            if (build == .string) {
                try writer.print(" [build: {s}]", .{build.string});
            }
        }
    }
    
    fn formatSortOperator(self: *TextFormatter, writer: anytype, op: std.json.ObjectMap) !void {
        _ = self;
        
        if (op.get("sort_keys")) |keys| {
            if (keys == .array) {
                try writer.writeAll(" [keys: ");
                for (keys.array.items, 0..) |key, i| {
                    if (i > 0) try writer.writeAll(", ");
                    if (key == .string) {
                        try writer.writeAll(key.string);
                    }
                }
                try writer.writeAll("]");
            }
        }
        
        if (op.get("spilled")) |spilled| {
            if (spilled == .bool and spilled.bool) {
                try writer.writeAll(" [SPILLED]");
            }
        }
    }
    
    fn formatAggregateOperator(self: *TextFormatter, writer: anytype, op: std.json.ObjectMap) !void {
        _ = self;
        
        if (op.get("group_keys")) |keys| {
            if (keys == .array) {
                try writer.writeAll(" [group by: ");
                for (keys.array.items, 0..) |key, i| {
                    if (i > 0) try writer.writeAll(", ");
                    if (key == .string) {
                        try writer.writeAll(key.string);
                    }
                }
                try writer.writeAll("]");
            }
        }
        
        if (op.get("aggregate_functions")) |funcs| {
            if (funcs == .array) {
                try writer.writeAll(" [aggs: ");
                for (funcs.array.items, 0..) |func, i| {
                    if (i > 0) try writer.writeAll(", ");
                    if (func == .string) {
                        try writer.writeAll(func.string);
                    }
                }
                try writer.writeAll("]");
            }
        }
        
        if (op.get("hash_buckets")) |buckets| {
            if (buckets == .integer) {
                try writer.print(" [buckets: {d}]", .{buckets.integer});
            }
        }
    }
    
    fn formatRowCounts(self: *TextFormatter, writer: anytype, op: std.json.ObjectMap) !void {
        _ = self;
        
        var has_rows = false;
        
        if (op.get("input_rows")) |in_rows| {
            if (in_rows == .integer) {
                try writer.print(" (in: {d}", .{in_rows.integer});
                has_rows = true;
                
                // Show estimate vs actual for input
                if (op.get("input_rows_est")) |in_est| {
                    if (in_est == .integer and in_est.integer != in_rows.integer) {
                        const accuracy = @as(f64, @floatFromInt(in_rows.integer)) / @as(f64, @floatFromInt(in_est.integer)) * 100.0;
                        try writer.print(" est:{d} {d:.0}%", .{ in_est.integer, accuracy });
                    }
                }
            }
        }
        
        if (op.get("rows")) |out_rows| {
            if (out_rows == .integer) {
                if (has_rows) {
                    try writer.print(", out: {d}", .{out_rows.integer});
                } else {
                    try writer.print(" (rows: {d}", .{out_rows.integer});
                    has_rows = true;
                }
                
                // Show estimate vs actual for output
                if (op.get("rows_est")) |out_est| {
                    if (out_est == .integer and out_est.integer != out_rows.integer) {
                        const accuracy = @as(f64, @floatFromInt(out_rows.integer)) / @as(f64, @floatFromInt(out_est.integer)) * 100.0;
                        try writer.print(" est:{d} {d:.0}%", .{ out_est.integer, accuracy });
                    }
                }
            }
        }
        
        if (has_rows) {
            try writer.writeAll(")");
        }
    }
    
    fn formatOperatorTiming(self: *TextFormatter, writer: anytype, op: std.json.ObjectMap) !void {
        _ = self;
        
        if (op.get("time_ns")) |time| {
            if (time == .integer and time.integer > 0) {
                const ms = @as(f64, @floatFromInt(time.integer)) / 1_000_000.0;
                try writer.print(" [{d:.2}ms", .{ms});
                
                // Show percentage of total time if available
                if (op.get("time_percent")) |pct| {
                    if (pct == .float) {
                        try writer.print(" {d:.1}%", .{pct.float * 100.0});
                    }
                }
                
                try writer.writeAll("]");
            }
        }
    }
    
    fn formatOperatorMemory(self: *TextFormatter, writer: anytype, op: std.json.ObjectMap) !void {
        _ = self;
        
        if (op.get("bytes_alloc")) |bytes| {
            if (bytes == .integer and bytes.integer > 0) {
                const kb = @as(f64, @floatFromInt(bytes.integer)) / 1024.0;
                try writer.print(" [mem: {d:.1}KB", .{kb});
                
                // Show peak memory if different
                if (op.get("bytes_peak")) |peak| {
                    if (peak == .integer and peak.integer != bytes.integer) {
                        const peak_kb = @as(f64, @floatFromInt(peak.integer)) / 1024.0;
                        try writer.print(", peak: {d:.1}KB", .{peak_kb});
                    }
                }
                
                try writer.writeAll("]");
            }
        }
    }
    
    fn formatOperatorCost(self: *TextFormatter, writer: anytype, op: std.json.ObjectMap) !void {
        _ = self;
        
        if (op.get("cost_estimate")) |cost| {
            if (cost == .float) {
                try writer.print(" [cost: {d:.1}", .{cost.float});
                
                if (op.get("cost_actual")) |actual| {
                    if (actual == .float and actual.float != cost.float) {
                        const accuracy = cost.float / actual.float * 100.0;
                        try writer.print(", actual: {d:.1} {d:.0}%", .{ actual.float, accuracy });
                    }
                }
                
                try writer.writeAll("]");
            }
        }
    }

    fn jsonValueToString(self: *TextFormatter, value: std.json.Value) ![]u8 {
        var buf = std.ArrayList(u8).initCapacity(self.allocator, 0) catch return error.OutOfMemory;
        defer buf.deinit(self.allocator);

        const writer = buf.writer(self.allocator);

        switch (value) {
            .null => try writer.writeAll("NULL"),
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .integer => |i| try writer.print("{d}", .{i}),
            .float => |f| try writer.print("{d:.2}", .{f}),
            .number_string => |s| try writer.writeAll(s),
            .string => |s| try writer.writeAll(s),
            .array => try writer.writeAll("[array]"),
            .object => try writer.writeAll("[object]"),
        }

        return buf.toOwnedSlice(self.allocator);
    }
};

test "text formatter schema" {
    var formatter = TextFormatter.init(std.testing.allocator);

    const cols = [_]SchemaCol{
        .{ .name = "id", .type = "INT" },
        .{ .name = "name", .type = "STRING" },
    };

    const result = try formatter.formatSchema(&cols);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Schema:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "id (INT)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "name (STRING)") != null);
}

test "text formatter bindings" {
    var formatter = TextFormatter.init(std.testing.allocator);

    const rows_json = "[{\"id\":1,\"name\":\"Alice\"},{\"id\":2,\"name\":\"Bob\"}]";
    const order_keys = [_][]const u8{"id"};

    const result = try formatter.formatBindings(rows_json, true, &order_keys);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Ordered result") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Bob") != null);
}
