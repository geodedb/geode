const std = @import("std");

// CANARY: REQ=REQ-GQL-010; FEATURE="RealityDocs"; ASPECT=ImplementationRealityDeltaTool; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_ImplementationRealityDeltaTool; OWNER=tooling; UPDATED=2025-09-21

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    
    const args_list = try std.process.argsAlloc(ally);
    defer std.process.argsFree(ally, args_list);
    
    const status_path = if (args_list.len > 1) args_list[1] else "status.json";
    const out_path = if (args_list.len > 2) args_list[2] else "docs/IMPLEMENTATION_REALITY.md";
    const prev_path = if (args_list.len > 3) args_list[3] else "docs/.implementation_reality_prev.json";

    const curr_json = try readFile(ally, status_path);
    defer ally.free(curr_json);
    var prev_json: []u8 = &[_]u8{};
    var prev_exists = true;
    std.fs.cwd().access(prev_path, .{}) catch |err| switch (err) {
        error.FileNotFound => prev_exists = false,
        else => prev_exists = false,
    };
    if (prev_exists) prev_json = try readFile(ally, prev_path);
    defer if (prev_json.len > 0) ally.free(prev_json);

    var curr = try std.json.parseFromSlice(std.json.Value, ally, curr_json, .{});
    defer curr.deinit();
    var prev = if (prev_exists) try std.json.parseFromSlice(std.json.Value, ally, prev_json, .{}) else undefined;
    defer if (prev_exists) prev.deinit();

    const curr_rows = try collectRows(&curr.value, ally);
    defer ally.free(curr_rows);
    const prev_rows = if (prev_exists) try collectRows(&prev.value, ally) else &[_]Row{};
    if (prev_exists) {
        defer ally.free(prev_rows);
    }

    const now_ts = std.time.timestamp();
    var added_idx = std.ArrayListUnmanaged(usize){};
    defer if (added_idx.items.len > 0) added_idx.deinit(ally);
    var promo_idx = std.ArrayListUnmanaged(usize){};
    defer if (promo_idx.items.len > 0) promo_idx.deinit(ally);
    var promo_prior = std.ArrayListUnmanaged([]const u8){};
    defer if (promo_prior.items.len > 0) promo_prior.deinit(ally);

    for (curr_rows, 0..) |row, ci| {
        var prior_status: []const u8 = "";
        if (prev_exists) {
            for (prev_rows) |prow| {
                if (std.mem.eql(u8, prow.id, row.id) and std.mem.eql(u8, prow.feature, row.feature) and std.mem.eql(u8, prow.aspect, row.aspect)) {
                    prior_status = prow.status;
                    break;
                }
            }
        }
        if (prior_status.len == 0) {
            try added_idx.append(ally, ci);
        } else if (!std.mem.eql(u8, prior_status, row.status)) {
            try promo_idx.append(ally, ci);
            try promo_prior.append(ally, prior_status);
        }
    }

    // Append delta section
    var out_file = try std.fs.cwd().createFile(out_path, .{ .read = true, .truncate = false, .mode = 0o666 });
    defer out_file.close();
    try out_file.seekFromEnd(0);
    const line = try std.fmt.allocPrint(ally, "\n\n## Delta {d}\nAdded: {d}\n", .{ now_ts, added_idx.items.len });
    defer ally.free(line);
    try out_file.writeAll(line);
    if (added_idx.items.len > 0) {
        for (added_idx.items) |ai| {
            const r = curr_rows[ai];
            const key_line = try std.fmt.allocPrint(ally, "+ {s}/{s}/{s}\n", .{ r.id, r.feature, r.aspect });
            defer ally.free(key_line);
            try out_file.writeAll(key_line);
        }
    }
    const promo_hdr = try std.fmt.allocPrint(ally, "Promotions: {d}\n", .{promo_idx.items.len});
    defer ally.free(promo_hdr);
    try out_file.writeAll(promo_hdr);
    if (promo_idx.items.len > 0) {
        var i: usize = 0;
        while (i < promo_idx.items.len) : (i += 1) {
            const r = curr_rows[promo_idx.items[i]];
            const prior = promo_prior.items[i];
            const l2 = try std.fmt.allocPrint(ally, "* {s}/{s}/{s}:{s}->{s}\n", .{ r.id, r.feature, r.aspect, prior, r.status });
            defer ally.free(l2);
            try out_file.writeAll(l2);
        }
    }

    // Persist simplified snapshot with aspects array for future fast diff
    var prev_file = try std.fs.cwd().createFile(prev_path, .{ .read = true, .truncate = true });
    defer prev_file.close();
    try prev_file.writeAll("{\n  \"aspects\": [\n");
    var first = true;
    for (curr_rows) |r| {
        if (!first) try prev_file.writeAll(",\n") else first = false;
        const line_json = try std.fmt.allocPrint(ally, "    {{ \"key\": \"{s}/{s}/{s}\", \"status\": \"{s}\" }}", .{ r.id, r.feature, r.aspect, r.status });
        defer ally.free(line_json);
        try prev_file.writeAll(line_json);
    }
    try prev_file.writeAll("\n  ]\n}\n");
}

fn readFile(ally: std.mem.Allocator, path: []const u8) ![]u8 {
    const data = try std.fs.cwd().readFileAlloc(ally, path, 10_000_000);
    return data;
}

const Row = struct { id: []const u8, feature: []const u8, aspect: []const u8, status: []const u8 };

fn collectRows(v: *std.json.Value, ally2: std.mem.Allocator) ![]Row {
    // Prefer existing simplified snapshot schema { "aspects": [ { key, status } ] }
    if (v.*.object.get("aspects")) |aspects_val| {
        const cnt = aspects_val.array.items.len;
        var out = try ally2.alloc(Row, cnt);
        var i: usize = 0;
        while (i < cnt) : (i += 1) {
            const item = aspects_val.array.items[i];
            const key_full = item.object.get("key").?.string;
            var it = std.mem.splitScalar(u8, key_full, '/');
            const part1 = it.next() orelse key_full;
            const part2 = it.next() orelse "";
            const part3 = it.next() orelse "";
            out[i] = Row{ .id = part1, .feature = part2, .aspect = part3, .status = item.object.get("status").?.string };
        }
        return out;
    }
    // New primary schema: { requirements: [ { id, features: [ { feature, aspect, status } ] } ] }
    if (v.*.object.get("requirements")) |reqs| {
        // First pass: count features
        var total: usize = 0;
        for (reqs.array.items) |req| {
            if (req.object.get("features")) |features| total += features.array.items.len;
        }
        var out = try ally2.alloc(Row, total);
        var idx: usize = 0;
        for (reqs.array.items) |req| {
            const id = req.object.get("id").?.string;
            if (req.object.get("features")) |features| {
                for (features.array.items) |feat| {
                    out[idx] = Row{
                        .id = id,
                        .feature = feat.object.get("feature").?.string,
                        .aspect = feat.object.get("aspect").?.string,
                        .status = feat.object.get("status").?.string,
                    };
                    idx += 1;
                }
            }
        }
        return out[0..idx];
    }
    // Fallback empty
    return try ally2.alloc(Row, 0);
}

test "TestCANARY_REQ_GQL_010_ImplementationRealityDeltaTool" {
    // smoke: create status.json in new schema (requirements/features)
    const sample = "{\n  \"requirements\": [ { \"id\": \"REQ-GQL-000\", \"features\": [ { \"feature\": \"Feature\", \"aspect\": \"Aspect\", \"status\": \"TESTED\" } ] } ]\n}";
    var tmp = try std.fs.cwd().createFile("status.json", .{ .read = true, .truncate = true });
    defer tmp.close();
    _ = try tmp.write(sample);
    // Ensure prev snapshot removed
    std.fs.cwd().deleteFile("docs/.implementation_reality_prev.json") catch {};
    try main();
}
