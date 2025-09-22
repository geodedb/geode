const std = @import("std");

// Simple freshness checker for docs/NEXT.md
// CANARY: REQ=REQ-GQL-010; FEATURE="Governance"; ASPECT=NextPlanFreshnessGuard; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_NextPlanFreshnessGuard; OWNER=tooling; UPDATED=2025-09-22
// Policy: The Generated date header line must be within 1 day of current UTC date.
// Exits 2 if stale.

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const cwd = std.fs.cwd();
    var file = try cwd.openFile("docs/NEXT.md", .{ .mode = .read_only });
    defer file.close();

    var line_buf: [4096]u8 = undefined;
    var filled: usize = 0;
    var found = false;
    var generated_date: []const u8 = "";
    const token1 = "Regenerated ";
    const token2 = "Generated ";
    while (true) {
        var one: [1]u8 = undefined;
        const n = try file.read(&one);
        if (n == 0) {
            if (filled > 0) { // process last line
                const line = line_buf[0..filled];
                if (std.mem.indexOf(u8, line, token1) != null or std.mem.indexOf(u8, line, token2) != null) {
                    const tok = if (std.mem.indexOf(u8, line, token1) != null) token1 else token2;
                    const idx = std.mem.indexOf(u8, line, tok) orelse continue;
                    const date_slice = line[idx + tok.len ..];
                    if (date_slice.len >= 10) {
                        generated_date = date_slice[0..10];
                        found = true;
                    }
                }
            }
            break;
        }
        if (one[0] == '\n' or filled + 1 >= line_buf.len) {
            const line = line_buf[0..filled];
            if (std.mem.indexOf(u8, line, token1) != null or std.mem.indexOf(u8, line, token2) != null) {
                const tok = if (std.mem.indexOf(u8, line, token1) != null) token1 else token2;
                const idx = std.mem.indexOf(u8, line, tok) orelse continue;
                const date_slice = line[idx + tok.len ..];
                if (date_slice.len >= 10) {
                    generated_date = date_slice[0..10];
                    found = true;
                }
                break;
            }
            filled = 0;
        } else {
            line_buf[filled] = one[0];
            filled += 1;
        }
    }

    if (!found or generated_date.len != 10) {
        std.log.err("NEXT freshness: could not locate Generated date line", .{});
        std.process.exit(2);
    }

    const now = std.time.timestamp();
    // Parse YYYY-MM-DD
    var year: i32 = 0;
    var month: i32 = 0;
    var day: i32 = 0;
    if (std.fmt.parseInt(i32, generated_date[0..4], 10)) |y| year = y else |_| {}
    if (std.fmt.parseInt(i32, generated_date[5..7], 10)) |m| month = m else |_| {}
    if (std.fmt.parseInt(i32, generated_date[8..10], 10)) |d| day = d else |_| {}

    if (year == 0) {
        std.log.err("NEXT freshness: invalid date format: {s}", .{generated_date});
        std.process.exit(2);
    }

    // Compute naive days since epoch by constructing date and using std.time
    // Use civil time conversion for accuracy.
    const epoch_secs_per_day: i64 = 86400;
    // Convert generated date to epoch days using simple Gregorian to days algorithm (Rata Die style)
    const y = @as(i64, year);
    const m = @as(i64, month);
    const d = @as(i64, day);
    // Shift months so March=3..January=13 of previous year formula
    var adj_y = y;
    var adj_m = m;
    if (adj_m <= 2) {
        adj_m += 12;
        adj_y -= 1;
    }
    // Gregorian days count (valid 1600+)
    const epoch_day_generated = (365 * adj_y) + (@divTrunc(adj_y, 4)) - (@divTrunc(adj_y, 100)) + (@divTrunc(adj_y, 400)) + (@divTrunc((153 * (adj_m - 3) + 2), 5)) + d - 719469; // 1970-01-01 offset
    const epoch_day_now = @divTrunc(now, epoch_secs_per_day);

    const diff_days = epoch_day_now - epoch_day_generated;
    if (diff_days > 1 or diff_days < 0) {
        std.log.err("NEXT freshness: STALE (generated {s})", .{generated_date});
        std.process.exit(2);
    }

    var stdout_file: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    // Write message manually (File.Writer in this Zig version lacks print, emulate)
    const msg_prefix = "NEXT freshness OK (generated ";
    _ = try stdout_file.write(msg_prefix);
    _ = try stdout_file.write(generated_date);
    _ = try stdout_file.write(")\n");
}
