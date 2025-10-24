const std = @import("std");
// CANARY: REQ=REQ-GQL-UNICODE-002; FEATURE="UnicodeTableGenerator"; ASPECT=Tooling; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_UNICODE_002_GeneratorDryRun; OWNER=unicode; UPDATED=2025-09-27
// Minimal Unicode table generator: parses a reduced UCD subset and emits Zig tables.
// This is intentionally lightweight; full UCD integration can extend this tool.

pub const Generated = struct {
    decomp: []const u32, // flattened pairs of (codepoint,count followed by mapping)
};

fn parseUnicodeData(alloc: std.mem.Allocator, data: []const u8) !std.AutoHashMap(u32, []u32) {
    var map = std.AutoHashMap(u32, []u32).init(alloc);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, ';');
        const code_hex = fields.next() orelse continue;
        // Skip name
        _ = fields.next();
        // Category
        _ = fields.next();
        // ccc
        _ = fields.next();
        // bidi
        _ = fields.next();
        const decomp_field = fields.next() orelse "";
        if (decomp_field.len == 0 or decomp_field[0] == '<') continue; // skip tagged or empty
        var d_it = std.mem.tokenizeScalar(u8, decomp_field, ' ');
        var tmp = std.ArrayList(u32).init(alloc);
        while (d_it.next()) |cp_hex| {
            const v = try std.fmt.parseInt(u32, cp_hex, 16);
            try tmp.append(v);
        }
        const cp = try std.fmt.parseInt(u32, code_hex, 16);
        try map.put(cp, try tmp.toOwnedSlice());
    }
    return map;
}

fn writeDecompTable(writer: anytype, map: *const std.AutoHashMap(u32, []u32)) !void {
    try writer.writeAll("pub const decomp = [_]struct{cp:u32; map:[]const u32}{\n");
    var it = map.iterator();
    while (it.next()) |entry| {
        try writer.print("    .{{cp:{}, map:&[_]u32{{", .{entry.key_ptr.*});
        const slice = entry.value_ptr.*;
        for (slice, 0..) |v, idx| {
            if (idx > 0) try writer.writeAll(",");
            try writer.print("{}", .{v});
        }
        try writer.writeAll("}},\n");
    }
    try writer.writeAll("};\n");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var argv = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, argv);
    if (argv.len < 3) {
        std.log.err("usage: gen_unicode_tables <unicode_data_path> <out_dir>", .{});
        return error.InvalidArgs;
    }
    const unicode_path = argv[1];
    const out_dir = argv[2];

    const data = try std.fs.cwd().readFileAlloc(alloc, unicode_path, 1024 * 1024);
    defer alloc.free(data);

    var decomp_map = try parseUnicodeData(alloc, data);
    defer {
        var it = decomp_map.iterator();
        while (it.next()) |e| alloc.free(e.value_ptr.*);
        decomp_map.deinit();
    }

    var out_dir_handle = try std.fs.cwd().openDir(out_dir, .{ .iterate = true });
    defer out_dir_handle.close();

    var file = try out_dir_handle.createFile("decomp.zig", .{ .read = true });
    defer file.close();
    var bw = std.io.bufferedWriter(file.writer());
    const w = bw.writer();
    try w.writeAll("// AUTO-GENERATED: minimal decomposition table\n");
    try w.writeAll("// CANARY: REQ=REQ-GQL-UNICODE-003; FEATURE=\"UnicodeGeneratedTables\"; ASPECT=Decomposition; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_UNICODE_003_DecompLookup; OWNER=unicode; UPDATED=2025-09-27\n");
    try writeDecompTable(w, &decomp_map);
    try bw.flush();
}
