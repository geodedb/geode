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
    } else if (std.mem.eql(u8, subcmd, "repair")) {
        try cmdStorageRepair(allocator, argv, start_idx + 1);
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
        "  repair              Repair a store (--tde-page-tail: pages written by graph_storage <= 0.4.11)\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode storage verify --data-dir /var/lib/geode\n" ++
        "  geode storage verify --check tde-page-tail --data-dir /var/lib/geode\n" ++
        "\n", .{});
}

const verify_usage =
    "Usage: geode storage verify [--data-dir <dir>] [--check <name>]\n" ++
    "Checks: graph_store, tde-page-tail\n" ++
    "  tde-page-tail reads the store files without opening the store and\n" ++
    "  reports, as JSON, the pages still in the page-encryption envelope of\n" ++
    "  graph_storage <= 0.4.11 (AES-GCM tag over the last 16 page bytes) and\n" ++
    "  the records they lost. Needs GEODE_TDE_KEY to list the records. Exit 1\n" ++
    "  while any record is damaged (see geode storage repair --tde-page-tail).\n" ++
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

    // SONNY-6452: reads the store files only. Opening the store first could
    // move a damaged page to the new envelope before it is reported.
    if (check_filter) |check| {
        if (std.mem.eql(u8, check, "tde-page-tail")) {
            const ok = runTdePageTailCheck(allocator, data_dir);
            lock.release();
            std.process.exit(if (ok) @intFromEnum(ExitCode.success) else @intFromEnum(ExitCode.general_error));
        }
    }

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

const tde_page_tail = geode.tde_page_tail;

fn loadTdeKeyOrExit(allocator: std.mem.Allocator, what: []const u8) ?[32]u8 {
    return geode.tde_file_encryption.loadKey(allocator) catch |err| {
        std.debug.print("Error: GEODE_TDE_KEY is not a valid key ({s}); {s}\n", .{ @errorName(err), what });
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
}

fn writeStdout(bytes: []const u8) void {
    const stdout = getStdOut() catch return;
    stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), bytes) catch {};
}

// CANARY: REQ=REQ-SONNY-6452-TDE-PAGE-TAIL-VERIFY; FEATURE="Storage CLI"; ASPECT=ReportsOldEnvelopePageDamage; STATUS=TESTED; TEST=tests/test_sonny6452_tde_page_tail_repair.zig; OWNER=storage; UPDATED=2026-11-13
/// `geode storage verify --check tde-page-tail`: the JSON report on stdout.
/// True when no record is damaged.
fn runTdePageTailCheck(allocator: std.mem.Allocator, data_dir: []const u8) bool {
    const key = loadTdeKeyOrExit(allocator, "nothing was verified.");
    var report = tde_page_tail.scan(allocator, data_dir, key) catch |err| {
        std.debug.print("Error: cannot read the store files in {s} ({s}); nothing was verified.\n", .{ data_dir, @errorName(err) });
        return false;
    };
    defer report.deinit();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    report.writeJson(&aw.writer, data_dir) catch return false;
    aw.writer.writeByte('\n') catch return false;
    writeStdout(aw.written());
    if (report.needs_key) {
        std.debug.print("Error: pages in the graph_storage <= 0.4.11 envelope were found; set GEODE_TDE_KEY to list the records they lost.\n", .{});
    } else if (!report.ok()) {
        std.debug.print("Records were lost from pages written by graph_storage <= 0.4.11 (SONNY-6441); see geode storage repair --tde-page-tail.\n", .{});
    }
    return report.ok();
}

const repair_usage =
    "Usage: geode storage repair --tde-page-tail --i-have-a-backup [--data-dir <dir>]\n" ++
    "Repairs a page-encrypted store written by graph_storage <= 0.4.11, whose\n" ++
    "pager wrote the AES-GCM tag over the last 16 bytes of every page:\n" ++
    "  - node records in the last slot of a page get their label count back\n" ++
    "    (from the node's label block) and their creation stamp; whether such a\n" ++
    "    node had been deleted is not recorded anywhere else, so it stays as the\n" ++
    "    engine reads it (present) and is listed as liveness unknown;\n" ++
    "  - a node whose whole record was the lost tail is listed as lost;\n" ++
    "  - the incoming-edge directory is rebuilt from the outgoing edges.\n" ++
    "Repaired pages are rewritten in the current envelope: a geode built on\n" ++
    "graph_storage <= 0.4.11 cannot read them. Offline: stop the server (repair\n" ++
    "takes the data directory's lock). Needs GEODE_TDE_KEY. Prints JSON: the\n" ++
    "report before, what was repaired, the report after. Keep that output.\n" ++
    "--i-have-a-backup confirms a backup of the data directory exists.\n";

// CANARY: REQ=REQ-SONNY-6452-TDE-PAGE-TAIL-REPAIR; FEATURE="Storage CLI"; ASPECT=RepairsDerivableOldEnvelopeDamage; STATUS=TESTED; TEST=tests/test_sonny6452_tde_page_tail_repair.zig; OWNER=storage; UPDATED=2026-11-13
fn cmdStorageRepair(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var data_dir_flag: ?[]const u8 = null;
    var page_tail = false;
    var acknowledged = false;
    var i = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--tde-page-tail")) {
            page_tail = true;
        } else if (std.mem.eql(u8, argv[i], "--i-have-a-backup")) {
            acknowledged = true;
        } else if (std.mem.eql(u8, argv[i], "--data-dir") and i + 1 < argv.len) {
            data_dir_flag = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print(repair_usage, .{});
            std.process.exit(0);
        } else {
            std.debug.print("Error: unknown argument '{s}'\n{s}", .{ argv[i], repair_usage });
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
    }
    if (!page_tail) {
        std.debug.print("Error: name the repair to run (--tde-page-tail); nothing was changed.\n{s}", .{repair_usage});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
    if (!acknowledged) {
        std.debug.print("Error: repair rewrites store pages; back up the data directory first and pass --i-have-a-backup. Nothing was changed.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    const data_dir = cli_auth.resolveCliDataDir(allocator, data_dir_flag) catch |err| {
        std.debug.print("Error: cannot resolve the data directory ({s}); nothing was changed.\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer allocator.free(data_dir);
    const key = loadTdeKeyOrExit(allocator, "nothing was changed.") orelse {
        std.debug.print("Error: repair --tde-page-tail needs GEODE_TDE_KEY (the store's page-encryption key; a store without page encryption has nothing to repair). Nothing was changed.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    var lock = data_dir_lock.DataDirLock.acquireWithTimeout(allocator, data_dir, data_dir_lock.timeoutFromEnv()) catch |err| {
        if (err == error.DataDirLocked) {
            const holder = data_dir_lock.readHolderPid(allocator, data_dir) orelse -1;
            std.debug.print("Error: data directory is locked by pid {d} ({s}); stop the server and retry. Nothing was changed.\n", .{ holder, data_dir });
        } else {
            std.debug.print("Error: cannot lock the data directory {s} ({s}); nothing was changed.\n", .{ data_dir, @errorName(err) });
        }
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    const ok = runTdePageTailRepair(allocator, data_dir, key);
    lock.release();
    std.process.exit(if (ok) @intFromEnum(ExitCode.success) else @intFromEnum(ExitCode.general_error));
}

/// Scan (before opening anything), repair, scan again; print
/// {"before":..,"repaired":..,"after":..}. True when the after-scan is clean.
fn runTdePageTailRepair(allocator: std.mem.Allocator, data_dir: []const u8, key: [32]u8) bool {
    var before = tde_page_tail.scan(allocator, data_dir, key) catch |err| {
        std.debug.print("Error: cannot read the store files in {s} ({s}); nothing was changed.\n", .{ data_dir, @errorName(err) });
        return false;
    };
    defer before.deinit();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("{\"before\":") catch return false;
    before.writeJson(w, data_dir) catch return false;
    // Printed first, so the record of what was damaged survives a failure.
    writeStdout(aw.written());
    aw.clearRetainingCapacity();

    var summary: tde_page_tail.RepairSummary = .{};
    var repair_err: ?anyerror = null;
    if (!before.ok()) {
        const adapter = graph_store.openDetachedAdapter(allocator, data_dir) catch |err| {
            std.debug.print("\nError: cannot open the store in {s} ({s}); nothing was repaired.\n", .{ data_dir, @errorName(err) });
            return false;
        };
        summary = tde_page_tail.repair(allocator, adapter, &before) catch |err| blk: {
            repair_err = err;
            break :blk summary;
        };
        adapter.checkpointAll() catch |err| {
            if (repair_err == null) repair_err = err;
        };
        adapter.deinit();
    }
    w.writeAll(",\"repaired\":") catch return false;
    summary.writeJson(w) catch return false;
    if (repair_err) |err| {
        w.print(",\"error\":\"{s}\"}}\n", .{@errorName(err)}) catch return false;
        writeStdout(aw.written());
        std.debug.print("Error: the repair failed ({s}); restore the backup.\n", .{@errorName(err)});
        return false;
    }
    var after = tde_page_tail.scan(allocator, data_dir, key) catch |err| {
        w.writeAll("}\n") catch {};
        writeStdout(aw.written());
        std.debug.print("Error: cannot re-read the store files in {s} ({s}).\n", .{ data_dir, @errorName(err) });
        return false;
    };
    defer after.deinit();
    w.writeAll(",\"after\":") catch return false;
    after.writeJson(w, data_dir) catch return false;
    w.writeAll("}\n") catch return false;
    writeStdout(aw.written());
    if (!after.ok()) std.debug.print("Some damage is not repairable (see \"after\").\n", .{});
    return after.ok();
}
