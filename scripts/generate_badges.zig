const std = @import("std");
const builtin = @import("builtin");

fn append(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    try list.appendSlice(allocator, data);
}

fn appendFmt(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype, tmp_buf: []u8) !void {
    const rendered = try std.fmt.bufPrint(tmp_buf, fmt, args);
    try list.appendSlice(allocator, rendered);
}

// Simple SVG badge generator reading status.csv to produce counts badge.
// Usage: zig run scripts/generate_badges.zig -- --status status.csv --out badges/evidence.svg
// Produces a Shields.io style flat badge with TOTAL / TESTED / BENCHED counts.
// Future: color thresholds (green when 100% coverage) and stale detection colorization.
fn getStdOut() std.fs.File {
    return if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDOUT_FILENO };
}

fn getStdErr() std.fs.File {
    return if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDERR_FILENO };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args_iter = try std.process.argsWithAllocator(alloc);
    defer args_iter.deinit();

    var status_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--status")) {
            if (args_iter.next()) |p| status_path = p else return error.MissingStatusPath;
        } else if (std.mem.eql(u8, arg, "--out")) {
            if (args_iter.next()) |p| out_path = p else return error.MissingOutPath;
        }
    }

    if (status_path == null or out_path == null) {
        const stderr_file = getStdErr();
        try stderr_file.writeAll("Usage: --status <status.csv> --out <badge.svg>\n");
        return error.InvalidArgs;
    }

    const sp = status_path.?;
    const op = out_path.?;

    var file = try std.fs.cwd().openFile(sp, .{});
    defer file.close();

    var read_buf: [8 * 1024]u8 = undefined;
    var reader = file.reader(&read_buf);
    var line_accum = std.ArrayListUnmanaged(u8){};
    defer line_accum.deinit(alloc);

    var total: usize = 0;
    var tested: usize = 0;
    var benched: usize = 0;

    // Skip header (assume first line contains REQ-GQL header token)
    var first = true;
    while (true) {
        const n = reader.read(&read_buf) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (n == 0) break; // EOF
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const c = read_buf[i];
            if (c == '\n') {
                const line = std.mem.trim(u8, line_accum.items[0..line_accum.items.len], "\r\n");
                if (line.len != 0) {
                    if (first) {
                        first = false;
                    } else {
                        total += 1;
                        if (std.mem.indexOf(u8, line, ",BENCHED,")) |_| benched += 1;
                        if (std.mem.indexOf(u8, line, ",TESTED,")) |_| tested += 1;
                    }
                }
                line_accum.clearRetainingCapacity();
            } else {
                line_accum.append(alloc, c) catch return error.OutOfMemory;
            }
        }
    }
    // Handle last line if file didn't end with newline
    if (line_accum.items.len > 0) {
        const line = std.mem.trim(u8, line_accum.items[0..line_accum.items.len], "\r\n");
        if (line.len != 0) {
            if (first) {
                first = false;
            } else {
                total += 1;
                if (std.mem.indexOf(u8, line, ",BENCHED,")) |_| benched += 1;
                if (std.mem.indexOf(u8, line, ",TESTED,")) |_| tested += 1;
            }
        }
    }

    const covered = tested + benched;
    const coverage: f64 = if (total == 0) 0 else @as(f64, @floatFromInt(covered)) / @as(f64, @floatFromInt(total));

    const color = blk: {
        if (coverage >= 0.999) break :blk "4c1"; // bright green
        if (coverage >= 0.95) break :blk "97CA00";
        if (coverage >= 0.85) break :blk "dfb317";
        if (coverage >= 0.70) break :blk "fe7d37";
        break :blk "e05d44"; // red
    };

    // Compose badge label and message
    var svg_buf = std.ArrayListUnmanaged(u8){};
    defer svg_buf.deinit(alloc);
    var tmp: [512]u8 = undefined;

    // Very small inline SVG (no external fonts) similar to Shields layout.
    try appendFmt(&svg_buf, alloc, "<svg xmlns='http://www.w3.org/2000/svg' width='220' height='20' role='img' aria-label='evidence:{}/{}/{}'>", .{ total, tested, benched }, &tmp);
    try append(&svg_buf, alloc, "<linearGradient id='s' x2='0' y2='100%'><stop offset='0' stop-color='#bbb' stop-opacity='.1'/><stop offset='1' stop-opacity='.1'/></linearGradient>");
    try append(&svg_buf, alloc, "<clipPath id='r'><rect width='220' height='20' rx='3' fill='#fff'/></clipPath>");
    try appendFmt(&svg_buf, alloc, "<g clip-path='url(#r)'><rect width='85' height='20' fill='#555'/><rect x='85' width='135' height='20' fill='#{s}'/><rect width='220' height='20' fill='url(#s)'/></g>", .{color}, &tmp);
    try appendFmt(&svg_buf, alloc, "<g fill='#fff' text-anchor='middle' font-family='Verdana,Geneva,DejaVu Sans,sans-serif' font-size='11'><text x='43' y='14'>evidence</text><text x='151' y='14'>{}/{}/{}" ++ "</text></g>", .{ total, tested, benched }, &tmp);
    try append(&svg_buf, alloc, "</svg>");

    // Ensure output directory exists.
    const cwd = std.fs.cwd();
    var path_it = std.mem.tokenizeAny(u8, op, "/");
    var partial = std.ArrayListUnmanaged(u8){};
    defer partial.deinit(alloc);
    while (path_it.next()) |seg| {
        if (seg.len == 0) continue;
        if (partial.items.len > 0) partial.append(alloc, '/') catch return error.OutOfMemory;
        partial.appendSlice(alloc, seg) catch return error.OutOfMemory;
        // If not last segment treat as dir
        if (path_it.peek()) |_| {
            _ = cwd.makePath(partial.items[0..partial.items.len]) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
        }
    }

    var out_file = try cwd.createFile(op, .{ .truncate = true });
    defer out_file.close();
    try out_file.writeAll(svg_buf.items[0..svg_buf.items.len]);

    const stdout_file = getStdOut();
    var msg_buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "generated badge: total={} tested={} benched={} coverage={d:.2}% -> {s}\n", .{ total, tested, benched, coverage * 100.0, op });
    try stdout_file.writeAll(msg);
}

pub const GenBadgeError = error{
    MissingStatusPath,
    MissingOutPath,
    InvalidArgs,
};
