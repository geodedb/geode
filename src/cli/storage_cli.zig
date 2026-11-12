const std = @import("std");
const stdio_util = @import("../utils/stdio.zig");

// CANARY: REQ=REQ-QUALITY-GAP-406-005; FEATURE="SafeStdioHandles"; ASPECT=ErrorHandling; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30
fn getStdOut() error{StdioUnavailable}!std.Io.File {
    return stdio_util.getStdout() catch error.StdioUnavailable;
}

fn printTo(file: std.Io.File, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const slice = try std.fmt.bufPrint(&buf, fmt, args);
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), slice);
}

const geode = @import("geode");
const graph_store = geode.graph_store;
const cli_auth = @import("cli_auth_helpers.zig");
const data_dir_lock = @import("data_dir_lock");
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
        "  verify              Open the data directory and run GraphStore persistence checks\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode storage verify --data-dir /var/lib/geode\n" ++
        "\n", .{});
}

const verify_usage =
    "Usage: geode storage verify [--data-dir <dir>] [--check <name>]\n" ++
    "Checks: graph_store\n" ++
    "The data directory is the one `geode serve` opens: --data-dir, else\n" ++
    "GEODE_DATA_DIR, else the per-user default (created if missing, as the\n" ++
    "server does). A directory that cannot be opened is an error (exit 1).\n" ++
    "Stop the server first: verify takes the data directory's lock.\n";

fn cmdStorageVerify(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var check_filter: ?[]const u8 = null;
    var data_dir_flag: ?[]const u8 = null;

    var i = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--check") and i + 1 < argv.len) {
            check_filter = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--data-dir") and i + 1 < argv.len) {
            data_dir_flag = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print(verify_usage, .{});
            std.process.exit(0);
        } else {
            std.debug.print("Error: unknown argument '{s}'\n{s}", .{ argv[i], verify_usage });
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
    }

    // CANARY: REQ=REQ-SONNY-6430-STORAGE-VERIFY-DATA-DIR; FEATURE="Storage CLI"; ASPECT=VerifiesTheServersDataDir; STATUS=TESTED; TEST=tests/test_sonny6430_cli_fail_closed.zig; OWNER=storage; UPDATED=2026-11-12
    // SONNY-6430: the directory the server opens (the offline auth CLI's
    // resolver). It used `getGlobalStore`, an empty in-memory store with no
    // GEODE_DATA_DIR (--data-dir was not accepted), and reported PASS; the
    // verbose form also exited 0 when the check failed.
    const data_dir = cli_auth.resolveCliDataDir(allocator, data_dir_flag) catch |err| {
        std.debug.print("Error: cannot resolve the data directory ({s}); nothing was verified.\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer allocator.free(data_dir);
    std.debug.print("Verifying the data directory {s}\n", .{data_dir});
    // As `geode serve` does (GAP-0909): create it, so the lock file can be.
    std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), data_dir) catch |err| {
        std.debug.print("Error: cannot open the data directory {s} ({s}); nothing was verified.\n", .{ data_dir, @errorName(err) });
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };

    // The checkpoint writes the store: never beside a running server.
    var lock = data_dir_lock.DataDirLock.acquireWithTimeout(allocator, data_dir, data_dir_lock.timeoutFromEnv()) catch |err| {
        if (err == error.DataDirLocked) {
            const holder = data_dir_lock.readHolderPid(allocator, data_dir) orelse -1;
            std.debug.print("Error: data directory is locked by pid {d} ({s}); stop the server and retry. Nothing was verified.\n", .{ holder, data_dir });
        } else {
            std.debug.print("Error: cannot lock the data directory {s} ({s}); nothing was verified.\n", .{ data_dir, @errorName(err) });
        }
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer lock.release();

    const store = graph_store.initGlobalStore(allocator, data_dir) catch |err| {
        std.debug.print("Error: cannot open the data directory {s} ({s}); nothing was verified.\n", .{ data_dir, @errorName(err) });
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer graph_store.deinitGlobalStore();

    // If specific check requested, run only that and output JSON (compatibility with sanity tool)
    if (check_filter) |check| {
        runCheck(store, check, true) catch std.process.exit(@intFromEnum(ExitCode.general_error));
        return;
    }

    // Otherwise run all checks in verbose mode
    std.debug.print("Running GraphStore persistence verification of {s}...\n", .{data_dir});
    std.debug.print("[*] Checking GraphStore snapshot... ", .{});
    var failed = false;
    runCheck(store, "graph_store", false) catch |err| {
        std.debug.print("FAIL ({any})\n", .{err});
        failed = true;
    };
    std.debug.print("\nVerification complete.\n", .{});
    if (failed) {
        graph_store.deinitGlobalStore();
        lock.release();
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }
}

fn runCheck(store: *graph_store.GraphStore, check_name: []const u8, json_output: bool) !void {
    const stdout = getStdOut() catch return error.StdioUnavailable;

    if (std.mem.eql(u8, check_name, "graph_store")) {
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
            std.debug.print("PASS ({d} nodes)\n", .{node_count});
        }
        return;
    }

    if (json_output) {
        try printTo(stdout, "{{\"{s}_ok\":false,\"error\":\"UnknownCheck\"}}\n", .{check_name});
    }
    return error.UnknownCheck;
}
