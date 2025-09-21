const std = @import("std");

// CANARY: REQ=REQ-GQL-010; FEATURE="RealityDocs"; ASPECT=ImplementationRealityDeltaTool; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_ImplementationRealityDeltaTool; OWNER=tooling; UPDATED=2025-09-21

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    var args = std.process.args();
    _ = args.next(); // prog
    const status_path = args.next() orelse "status.json";
    const out_path = args.next() orelse "docs/IMPLEMENTATION_REALITY.md";
    const prev_path = args.next() orelse "docs/.implementation_reality_prev.json";

    const curr_json = try readFile(ally, status_path);
    defer ally.free(curr_json);
    var prev_json: []u8 = &[_]u8{};
    const prev_exists = std.fs.cwd().access(prev_path, .{}) catch |err| switch (err) {
        error.FileNotFound => false,
        else => false,
    };
    if (prev_exists) prev_json = try readFile(ally, prev_path);
    defer if (prev_json.len > 0) ally.free(prev_json);

    var curr = try std.json.parseFromSlice(std.json.Value, ally, curr_json, .{});
    defer curr.deinit();
    var prev = if (prev_exists) try std.json.parseFromSlice(std.json.Value, ally, prev_json, .{}) else undefined;
    defer if (prev_exists) prev.deinit();

    const now_ts = std.time.timestamp();
    var added = std.ArrayList([]const u8).init(ally);
    defer added.deinit();
    var promoted = std.ArrayList([]const u8).init(ally);
    defer promoted.deinit();

    const curr_arr = curr.value.object.get("aspects").?; // expects scanner schema
    const prev_arr = if (prev_exists) prev.value.object.get("aspects").? else undefined;

    if (curr_arr.array.items.len > 0) {
        for (curr_arr.array.items) |row| {
            const key = row.object.get("key").?.string;
            const status = row.object.get("status").?.string;
            var prior_status: []const u8 = "";
            if (prev_exists) {
                for (prev_arr.array.items) |prow| {
                    if (std.mem.eql(u8, prow.object.get("key").?.string, key)) {
                        prior_status = prow.object.get("status").?.string;
                        break;
                    }
                }
            }
            if (prior_status.len == 0) {
                try added.append(key);
            } else if (!std.mem.eql(u8, prior_status, status)) {
                const promo_line = try std.fmt.allocPrint(ally, "{s}:{s}->{s}", .{ key, prior_status, status });
                try promoted.append(promo_line);
            }
        }
    }

    // Append delta section
    var out_file = try std.fs.cwd().createFile(out_path, .{ .read = true, .truncate = false, .mode = 0o666 });
    defer out_file.close();
    try out_file.seekFromEnd(0);
    const w = out_file.writer();
    try w.print("\n\n## Delta {d}\n", .{now_ts});
    try w.print("Added: {d}\n", .{added.items.len});
    for (added.items) |a| try w.print("+ {s}\n", .{a});
    try w.print("Promotions: {d}\n", .{promoted.items.len});
    for (promoted.items) |p| try w.print("* {s}\n", .{p});

    // Persist current snapshot as prev
    var prev_file = try std.fs.cwd().createFile(prev_path, .{ .read = true, .truncate = true });
    defer prev_file.close();
    _ = try prev_file.write(curr_json);
}

fn readFile(ally: std.mem.Allocator, path: []const u8) ![]u8 {
    const data = try std.fs.cwd().readFileAlloc(ally, path, 10_000_000);
    return data;
}

test "TestCANARY_REQ_GQL_010_ImplementationRealityDeltaTool" {
    // smoke: create minimal status json structure
    const sample = "{\n  \"aspects\": [ { \"key\": \"REQ-GQL-000/Feature/Aspect\", \"status\": \"TESTED\" } ]\n}";
    var tmp = try std.fs.cwd().createFile("status.json", .{ .read = true, .truncate = true });
    defer tmp.close();
    _ = try tmp.write(sample);
    try main();
}
