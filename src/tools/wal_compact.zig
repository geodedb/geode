const std = @import("std");
// Import the WAL module via the build graph alias added in build.zig
const wal_mod = @import("wal");

pub fn main() !void {
    // P2-3: Use GeneralPurposeAllocator for tool main
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    var base: ?[]const u8 = null;
    var durable_lsn: ?u64 = null;
    var auto_mode = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--base") and i + 1 < args.len) {
            base = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--durable-lsn") and i + 1 < args.len) {
            durable_lsn = std.fmt.parseInt(u64, args[i + 1], 10) catch |e| {
                std.debug.print("invalid durable lsn: {s}\n", .{@errorName(e)});
                return error.InvalidArg;
            };
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--auto")) {
            auto_mode = true;
        } else if (std.mem.eql(u8, args[i], "--help")) {
            std.debug.print("Usage: wal_compact --base <path> [--durable-lsn N | --auto]\n", .{});
            return;
        }
    }
    if (base == null) {
        std.debug.print("--base required (prefix path to WAL without .wal.N)\n", .{});
        return error.MissingBase;
    }
    var wal = wal_mod.Wal.init(gpa);
    defer wal.deinit();
    try wal.openFile(base.?);
    // Auto mode: scan for last checkpoint LSN and use that as durable boundary.
    var chosen_lsn: u64 = 0;
    if (auto_mode) {
        const meta = try wal.scanMetadata();
        chosen_lsn = meta.last_checkpoint_lsn;
        if (chosen_lsn == 0) {
            std.debug.print("No checkpoint found; nothing to do.\n", .{});
            return;
        }
    } else if (durable_lsn) |d| {
        chosen_lsn = d;
    } else {
        std.debug.print("Either --auto or --durable-lsn must be supplied.\n", .{});
        return error.MissingDurable;
    }
    try wal.compact(chosen_lsn);
    std.debug.print("Compaction complete (durable_lsn={d}).\n", .{chosen_lsn});
}
