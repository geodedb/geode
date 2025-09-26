const std = @import("std");

// security_progress.zig
// Parses docs/SECURITY_PROGRESS.md to:
// 1. Emit machine-readable JSON summary (areas, status, risk, evidence, next)
// 2. Emit badge SVG summarizing tested/partial/pending counts
// 3. Validate transitions: forbid direct STUB -> COMPLETE without TESTED CANARY; ensure TESTED rows have matching CANARY markers with STATUS=TESTED
// Usage:
//   zig-out/bin/security_progress --md docs/SECURITY_PROGRESS.md --json status_security.json --badge badges/security_progress.svg [--prev prev_status_security.json]
// Exit codes:
//   0 success
//   2 validation failure
//   3 parse error
// NOTE: We rely on simple table parsing (pipe table) and code fence CANARY markers.

const AreaStatus = enum { COMPLETE, PARTIAL, PENDING };

const Row = struct {
    area: []const u8,
    status: AreaStatus,
    evidence: []const u8,
    next_action: []const u8,
    risk: []const u8,
};

const Canary = struct {
    req: []const u8,
    feature: []const u8,
    aspect: []const u8,
    status: []const u8,
    test_name: []const u8,
};

fn parseStatus(s: []const u8) !AreaStatus {
    var buf = std.ArrayList(u8).init(std.heap.page_allocator);
    defer buf.deinit();
    try buf.appendSlice(s);
    std.ascii.upperString(buf.items, buf.items);
    const upper = buf.items;
    if (std.mem.eql(u8, upper, "COMPLETE")) return .COMPLETE;
    if (std.mem.eql(u8, upper, "PARTIAL")) return .PARTIAL;
    if (std.mem.eql(u8, upper, "PENDING")) return .PENDING;
    return error.Parse;
}

fn parseTable(alloc: std.mem.Allocator, md: []const u8, rows: *std.ArrayList(Row)) !void {
    var it = std.mem.splitScalar(u8, md, '\n');
    var in_header_pass = false;
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "| Area")) {
            in_header_pass = true;
            continue;
        }
        if (in_header_pass) {
            // Skip separator line of dashes
            if (std.mem.startsWith(u8, line, "| ---")) continue;
            if (line.len == 0) break; // end of table
            if (!std.mem.startsWith(u8, line, "|")) break; // table ended
            // Split columns
            var cols_it = std.mem.splitScalar(u8, line, '|');
            var cols: [10][]const u8 = undefined;
            var col_i: usize = 0;
            while (cols_it.next()) |c| {
                if (col_i >= cols.len) break;
                cols[col_i] = std.mem.trim(u8, c, " ");
                col_i += 1;
            }
            // Expected columns: [empty] Area Status Evidence Next Risk [maybe empty]
            if (col_i < 6) continue; // malformed or blank
            const area = cols[1];
            if (area.len == 0) continue;
            const status = try parseStatus(cols[2]);
            const evidence = cols[3];
            const next_action = cols[4];
            const risk = cols[5];
            try rows.append(.{ .area = area, .status = status, .evidence = evidence, .next_action = next_action, .risk = risk });
        }
    }
}

fn parseCanaries(alloc: std.mem.Allocator, md: []const u8, out: *std.ArrayList(Canary)) !void {
    var line_it = std.mem.splitScalar(u8, md, '\n');
    while (line_it.next()) |line| {
        const key = "CANARY:";
        if (std.mem.indexOf(u8, line, key)) |idx| {
            const slice = line[idx + key.len ..];
            // tokens separated by ';'
            var parts_it = std.mem.splitScalar(u8, slice, ';');
            var req: []const u8 = "";
            var feature: []const u8 = "";
            var aspect: []const u8 = "";
            var status: []const u8 = "";
            var test: []const u8 = "";
            while (parts_it.next()) |part_raw| {
                const part = std.mem.trim(u8, part_raw, " \t");
                if (part.len == 0) continue;
                if (std.mem.startsWith(u8, part, "REQ=")) req = part[4..];
                else if (std.mem.startsWith(u8, part, "FEATURE=")) feature = part[8..];
                else if (std.mem.startsWith(u8, part, "ASPECT=")) aspect = part[7..];
                else if (std.mem.startsWith(u8, part, "STATUS=")) status = part[7..];
                else if (std.mem.startsWith(u8, part, "TEST=")) test = part[5..];
            }
            if (req.len > 0) {
                try out.append(.{ .req = req, .feature = feature, .aspect = aspect, .status = status, .test_name = test });
            }
        }
    }
}

fn badgeColor(total: usize, tested: usize, partial: usize, pending: usize) []const u8 {
    if (pending == 0 and partial == 0) return "#4c1"; // bright green
    if (tested * 2 >= total) return "#97CA00"; // greenish
    if (partial > pending) return "#dfb317"; // yellow
    return "#e05d44"; // red
}

fn writeBadge(alloc: std.mem.Allocator, path: []const u8, total: usize, tested: usize, partial: usize, pending: usize) !void {
    const f = try std.fs.cwd().createFile(path, .{ .truncate = true, .read = false, .mode = 0o644 });
    defer f.close();
    const label = "security";
    const value_buf = try std.fmt.allocPrint(alloc, "{d}T {d}P {d}N", .{ tested, partial, pending });
    defer alloc.free(value_buf);
    const color = badgeColor(total, tested, partial, pending);
    try f.writeAll(
        \u003csvg xmlns='http://www.w3.org/2000/svg' width='150' height='20' role='img' aria-label='security progress'\u003e
        \u003cg shape-rendering='crispEdges'\u003e
        \u003crect x='0' y='0' width='70' height='20' fill='#555'/\u003e
        \u003crect x='70' y='0' width='80' height='20' fill='\
    );
    try f.writeAll(color);
    try f.writeAll(
        \'/\u003e\n\u003c/g\u003e\n\u003cg fill='#fff' text-anchor='middle' font-family='Verdana,Geneva,DejaVu Sans,sans-serif' font-size='11'\u003e\n\u003ctext x='35' y='14'>security\u003c/text>\n\u003ctext x='110' y='14'>
    );
    try f.writeAll(value_buf);
    try f.writeAll("</text>\n</g>\n</svg>");
}

fn writeJson(alloc: std.mem.Allocator, path: []const u8, rows: []const Row, canaries: []const Canary) !void {
    const f = try std.fs.cwd().createFile(path, .{ .truncate = true, .read = false, .mode = 0o644 });
    defer f.close();
    var w = f.writer();
    try w.writeAll("{\n  \"areas\": [\n");
    for (rows, 0..) |r, i| {
        const status_str = switch (r.status) { .COMPLETE => "COMPLETE", .PARTIAL => "PARTIAL", .PENDING => "PENDING" };
        try w.print("    {{\n      \"area\": \"{s}\",\n      \"status\": \"{s}\",\n      \"evidence\": \"{s}\",\n      \"next_action\": \"{s}\",\n      \"risk\": \"{s}\"\n    }}{s}\n", .{ r.area, status_str, r.evidence, r.next_action, r.risk, if (i + 1 == rows.len) "" else "," });
    }
    try w.writeAll("  ],\n  \"canaries\": [\n");
    for (canaries, 0..) |c, i| {
        try w.print("    {{\n      \"req\": \"{s}\",\n      \"feature\": \"{s}\",\n      \"aspect\": \"{s}\",\n      \"status\": \"{s}\",\n      \"test\": \"{s}\"\n    }}{s}\n", .{ c.req, c.feature, c.aspect, c.status, c.test_name, if (i + 1 == canaries.len) "" else "," });
    }
    try w.writeAll("  ]\n}\n");
}

fn findCanaryForFeature(canaries: []const Canary, area: []const u8) ?Canary {
    // Area vs Feature naming not always identical; attempt substring match ignoring spaces
    const normArea = std.mem.filter(u8, area, struct { fn f(c: u8) bool { return c != ' ' and c != '-'; } }.f);
    for (canaries) |c| {
        const normFeat = std.mem.filter(u8, c.feature, struct { fn f(c: u8) bool { return c != ' ' and c != '"' and c != '-'; } }.f);
        if (std.mem.indexOf(u8, normArea, normFeat) != null or std.mem.indexOf(u8, normFeat, normArea) != null) return c;
    }
    return null;
}

fn validate(rows: []const Row, canaries: []const Canary, stderr: anytype) !void {
    var tested_missing: usize = 0;
    for (rows) |r| {
        if (r.status == .COMPLETE) {
            if (findCanaryForFeature(canaries, r.area)) |c| {
                if (!std.mem.eql(u8, c.status, "TESTED") and !std.mem.eql(u8, c.status, "BENCHED")) {
                    try stderr.print("Validation: area '{s}' COMPLETE but CANARY status={s}\n", .{ r.area, c.status });
                    tested_missing += 1;
                }
            } else {
                try stderr.print("Validation: area '{s}' COMPLETE but no CANARY found\n", .{ r.area });
                tested_missing += 1;
            }
        }
    }
    if (tested_missing > 0) return error.ValidationFailed;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var md_path: []const u8 = "docs/SECURITY_PROGRESS.md";
    var json_path: []const u8 = "status_security.json";
    var badge_path: []const u8 = "badges/security_progress.svg";
    var prev_path: ?[]const u8 = null;

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.skip(); // prog
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--md")) md_path = args.next() orelse return error.Parse;
        else if (std.mem.eql(u8, a, "--json")) json_path = args.next() orelse return error.Parse;
        else if (std.mem.eql(u8, a, "--badge")) badge_path = args.next() orelse return error.Parse;
        else if (std.mem.eql(u8, a, "--prev")) prev_path = args.next();
        else if (std.mem.eql(u8, a, "--help")) {
            std.debug.print("security_progress --md <file> --json <out.json> --badge <out.svg> [--prev prev.json]\n", .{});
            return;
        }
    }

    var md_buf = try std.fs.cwd().readFileAlloc(alloc, md_path, 1024 * 1024);
    defer alloc.free(md_buf);

    var rows = std.ArrayList(Row).init(alloc);
    defer rows.deinit();
    try parseTable(alloc, md_buf, &rows);

    var canaries = std.ArrayList(Canary).init(alloc);
    defer canaries.deinit();
    try parseCanaries(alloc, md_buf, &canaries);

    try writeJson(alloc, json_path, rows.items, canaries.items);

    // Stats
    var total: usize = rows.items.len;
    var tested: usize = 0;
    var partial: usize = 0;
    var pending: usize = 0;
    for (rows.items) |r| {
        switch (r.status) {
            .COMPLETE => tested += 1,
            .PARTIAL => partial += 1,
            .PENDING => pending += 1,
        }
    }

    try writeBadge(alloc, badge_path, total, tested, partial, pending);

    // Transition validation (basic) + canary validation
    validate(rows.items, canaries.items, std.io.getStdErr().writer()) catch |e| switch (e) {
        error.ValidationFailed => return std.process.exit(2),
        else => return e,
    };

    // prev_path future: diff JSON to detect illegal transitions; currently placeholder
    if (prev_path) |_| {
        // TODO: Implement STUB->TESTED direct check by loading prev JSON; future enhancement
    }
}
