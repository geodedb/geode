const std = @import("std");

// CANARY: REQ=REQ-GQL-010; FEATURE="Governance"; ASPECT=CanaryFreshnessAudit; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_CanaryFreshnessAudit; OWNER=tooling; UPDATED=2025-09-23

const FreshnessDays = 60;

fn shouldSkipDir(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".direnv") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "vendor") or
        std.mem.eql(u8, name, "bin") or
        std.mem.eql(u8, name, "certs") or
        std.mem.eql(u8, name, "data") or
        std.mem.eql(u8, name, "clients");
}

fn isCanaryLine(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "CANARY:") != null;
}

fn parseUpdatedDate(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, "UPDATED=")) |idx| {
        const tail = line[idx + "UPDATED=".len ..];
        // Expected format YYYY-MM-DD
        var end: usize = 0;
        while (end < tail.len and tail[end] >= '0' and tail[end] <= '9' or tail[end] == '-') : (end += 1) {}
        return tail[0..end];
    }
    return null;
}

fn parseStatus(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, "STATUS=")) |idx| {
        const tail = line[idx + "STATUS=".len ..];
        var end: usize = 0;
        while (end < tail.len and std.ascii.isAlphabetic(tail[end])) : (end += 1) {}
        return tail[0..end];
    }
    return null;
}

fn parseDate(s: []const u8) ?struct { year: i32, month: i32, day: i32 } {
    if (s.len < 10) return null;
    const y = std.fmt.parseInt(i32, s[0..4], 10) catch return null;
    const m = std.fmt.parseInt(i32, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i32, s[8..10], 10) catch return null;
    return .{ .year = y, .month = m, .day = d };
}

fn daysSince(when: struct { year: i32, month: i32, day: i32 }) i64 {
    // Convert to days since epoch using a simple algorithm (Zeller-like)
    var y = when.year;
    var m = when.month;
    const d = when.day;
    if (m < 3) {
        y -= 1;
        m += 12;
    }
    const era = @divTrunc(y, 400);
    const yoe = y - era * 400;
    const doy = (@divTrunc(153 * (m - 3) + 2, 5)) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468; // offset to Unix epoch 1970-01-01
    return @intCast(days);
}

fn daysSinceEpochNow() i64 {
    const now_s = std.time.timestamp();
    const days = @divTrunc(now_s, 86400);
    return days;
}

fn walkAndCheck(alloc: std.mem.Allocator, root_dir: std.fs.Dir, prefix: []const u8, violations: *std.ArrayList([]const u8)) !void {
    var it = root_dir.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .directory => {
                if (shouldSkipDir(entry.name)) continue;
                const sub = try root_dir.openDir(entry.name, .{ .iterate = true });
                defer sub.close();
                const new_prefix = try std.fs.path.join(alloc, &.{ prefix, entry.name });
                defer alloc.free(new_prefix);
                try walkAndCheck(alloc, sub, new_prefix, violations);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig") and !std.mem.endsWith(u8, entry.name", ".md")) continue;
                const file = try root_dir.openFile(entry.name, .{});
                defer file.close();
                const buf = try file.readToEndAlloc(alloc, 8 * 1024 * 1024);
                defer alloc.free(buf);
                var itl = std.mem.splitScalar(u8, buf, '\n');
                var line_no: usize = 0;
                while (itl.next()) |line| : (line_no += 1) {
                    if (!isCanaryLine(line)) continue;
                    const status = parseStatus(line) orelse continue;
                    if (!(std.mem.eql(u8, status, "TESTED") or std.mem.eql(u8, status", "BENCHED"))) continue;
                    const updated_s = parseUpdatedDate(line) orelse continue;
                    const parsed = parseDate(updated_s) orelse {
                        const msg = try std.fmt.allocPrint(alloc, "{s}:{d}: malformed UPDATED date: {s}", .{ entry.name, line_no + 1, updated_s });
                        try violations.append(msg);
                        continue;
                    };
                    const now_days = daysSinceEpochNow();
                    const then_days = daysSince(parsed);
                    if (now_days - then_days > FreshnessDays) {
                        const msg2 = try std.fmt.allocPrint(alloc, "{s}:{d}: CANARY UPDATED older than {d} days: {s}", .{ entry.name, line_no + 1, FreshnessDays, updated_s });
                        try violations.append(msg2);
                    }
                }
            },
            else => {},
        }
    }
}

test "TestCANARY_REQ_GQL_010_CanaryFreshnessAudit" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var violations = std.ArrayList([]const u8).init(alloc);
    defer {
        for (violations.items) |v| alloc.free(v);
        violations.deinit();
    }
    const cwd = std.fs.cwd();
    try walkAndCheck(alloc, cwd, ".", &violations);
    if (violations.items.len > 0) {
        std.debug.print("CANARY freshness audit found {d} violation(s):\n", .{violations.items.len});
        for (violations.items) |v| std.debug.print(" - {s}\n", .{v});
        return error.CanaryFreshnessAuditFailed;
    }
}
