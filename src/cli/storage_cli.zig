const std = @import("std");
const stdio_util = @import("../utils/stdio.zig");

// CANARY: REQ=REQ-QUALITY-GAP-406-005; FEATURE="SafeStdioHandles"; ASPECT=ErrorHandling; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30
fn getStdOut() error{StdioUnavailable}!std.Io.File {
    return stdio_util.getStdout() catch error.StdioUnavailable;
}

fn printTo(file: std.Io.File, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const slice = try std.fmt.bufPrint(&buf, fmt, args);
    try file.writeAll(slice);
}

const geode = @import("geode");
const graph_store = geode.graph_store;
// const commit_coord = @import("commit_coord"); // Not used directly in sanity check logic yet

pub const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    usage_error = 2,
};

// ... (existing imports/setup)

pub fn cmdStorage(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    if (start_idx >= argv.len) {
        printStorageUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    const subcmd = argv[start_idx];

    if (std.mem.eql(u8, subcmd, "-h") or std.mem.eql(u8, subcmd, "--help")) {
        printStorageUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    } else if (std.mem.eql(u8, subcmd, "verify")) {
        try cmdStorageVerify(allocator, argv, start_idx + 1);
    } else {
        std.debug.print("Error: unknown storage subcommand '{s}'\n", .{subcmd});
        printStorageUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
}

fn printStorageUsage() void {
    std.debug.print("geode storage - Storage engine management and verification\n" ++
        "\n" ++
        "Usage: geode storage <subcommand> [args...]\n" ++
        "\n" ++
        "Subcommands:\n" ++
        "  verify              Run GraphStore persistence checks\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode storage verify\n" ++
        "\n", .{});
}

fn cmdStorageVerify(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var check_filter: ?[]const u8 = null;

    var i = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--check") and i + 1 < argv.len) {
            check_filter = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print("Usage: geode storage verify [--check <name>]\nChecks: graph_store\n", .{});
            std.process.exit(0);
        }
    }

    // If specific check requested, run only that and output JSON (compatibility with sanity tool)
    if (check_filter) |check| {
        try runCheck(allocator, check, true);
        return;
    }

    // Otherwise run all checks in verbose mode
    std.debug.print("Running GraphStore persistence verification...\n", .{});
    std.debug.print("[*] Checking GraphStore snapshot... ", .{});
    runCheck(allocator, "graph_store", false) catch |err| {
        std.debug.print("FAIL ({any})\n", .{err});
    };
    std.debug.print("\nVerification complete.\n", .{});
}

fn runCheck(allocator: std.mem.Allocator, check_name: []const u8, json_output: bool) !void {
    const stdout = getStdOut() catch return error.StdioUnavailable;

    if (std.mem.eql(u8, check_name, "graph_store")) {
        const store = graph_store.getGlobalStore(allocator);
        const node_count = store.getNodeCount();
        // Checkpoint via adapter (no more graph_store.dat)
        store.saveToFile() catch |err| {
            if (json_output) {
                try printTo(stdout, "{{\"graph_store_ok\":false,\"error\":\"{s}\"}}\n", .{@errorName(err)});
            } else {
                std.debug.print("FAIL ({any})\n", .{err});
            }
            return err;
        };
        if (json_output) {
            try printTo(stdout, "{{\"graph_store_ok\":true,\"node_count\":{}}}\n", .{@as(u64, @intCast(node_count))});
        } else {
            std.debug.print("PASS\n", .{});
        }
        return;
    }

    return error.UnknownCheck;
}
