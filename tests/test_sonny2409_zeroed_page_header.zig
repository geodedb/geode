// SONNY-2409: a damaged store page must fail a read closed, never read as a
// fresh (empty) page.
//
// The ticket's four cases, each against a cold store (clean shutdown, files
// damaged, reopened):
//   (a) a page whose 32-byte header alone is zeroed: graph_storage's pager
//       skipped its CRC32C when the header was all zero, so damage in the
//       rest of the page went undetected (graph_storage <= 0.4.11);
//   (b) whole pages zeroed, with the derived-index snapshots invalidated (the
//       reopen rebuilds them from the node store, as after a crash);
//   (c) page 0 included (node ids 0 .. nodes_per_page-1 live there);
//   (d) an UNLABELED scan, which reads the engine directly.
// Every read must fail with a typed corruption error; none may answer OK
// with partial data. A count may instead answer the full count: it is served
// from the durable live-node counts, not by reading the damaged records.
//
// CANARY: REQ=REQ-SONNY-2409-ZEROED-PAGE-FAIL-CLOSED; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2409_zeroed_page_header.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const query_arena = geode.query_arena;

const PAGE_SIZE: u64 = 8192;
const PAGE_HEADER_SIZE: u64 = 32;
const NODES: usize = 300;

const Damage = enum {
    /// Zero the 32-byte header only; the body (records + its CRC input) stays.
    zero_header,
    /// Zero the whole page, header included.
    zero_page,
};

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn seedCleanStore(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();
    const labels = [_][]const u8{"Person"};
    for (0..NODES) |i| {
        const id = try store.createNode(&labels);
        var buf: [32]u8 = undefined;
        try store.setNodeProperty(id, "name", .{ .String = try std.fmt.bufPrint(&buf, "person-{d:0>5}", .{i}) });
    }
}

/// Damage every written page (non-zero header) of every `file_name`, page 0
/// included (case c). Returns the number of pages damaged.
fn damageFiles(data_dir: []const u8, file_name: []const u8, damage: Damage) !usize {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(std.testing.allocator);
    defer walker.deinit();
    var damaged: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, entry.basename, file_name)) continue;
        var file = try entry.dir.openFile(io, entry.basename, .{ .mode = .read_write });
        defer file.close(io);
        const len = try file.length(io);
        var page: u64 = 0;
        while ((page + 1) * PAGE_SIZE <= len) : (page += 1) {
            var header: [PAGE_HEADER_SIZE]u8 = undefined;
            _ = try file.readPositionalAll(io, &header, page * PAGE_SIZE);
            if (std.mem.allEqual(u8, &header, 0)) continue; // never written
            const n: usize = switch (damage) {
                .zero_header => PAGE_HEADER_SIZE,
                .zero_page => PAGE_SIZE,
            };
            const zeros = [_]u8{0} ** PAGE_SIZE;
            try file.writePositionalAll(io, zeros[0..n], page * PAGE_SIZE);
            damaged += 1;
        }
    }
    return damaged;
}

/// Delete geode's loop2 hydration snapshots and empty the engine's
/// `labels.idx`, so the reopen rebuilds the derived indexes from the node
/// store (case b).
fn invalidateDerivedIndexSnapshots(data_dir: []const u8) !usize {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(std.testing.allocator);
    defer walker.deinit();
    var invalidated: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.basename, "labels.idx")) {
            var file = try entry.dir.openFile(io, entry.basename, .{ .mode = .read_write });
            defer file.close(io);
            try file.setLength(io, 0);
            invalidated += 1;
            continue;
        }
        if (!std.mem.startsWith(u8, entry.basename, "hydration_") or !std.mem.endsWith(u8, entry.basename, ".snap")) continue;
        try entry.dir.deleteFile(io, entry.basename);
        invalidated += 1;
    }
    return invalidated;
}

/// `count`: the first cell of a one-row integer result (a count query).
const Outcome = union(enum) { rows: struct { n: usize, count: ?i64 }, failed: anyerror };

fn reopenAndRun(allocator: std.mem.Allocator, data_dir: []const u8, query: []const u8) !Outcome {
    const store = try graph_store.initGlobalStore(allocator, data_dir);
    // Crash-style teardown: never checkpoint over the damaged pages.
    defer graph_store.deinitGlobalStoreForTestCrash();
    defer execution.cleanupCatalogInstance();
    try store.loadFromFile();

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const prev_scratch = query_arena.pushScratchAllocator(scratch.allocator());
    defer query_arena.popScratchAllocator(prev_scratch);

    var parsed = try geode.parseGql(query, allocator);
    defer parsed.deinit();
    const catalog = try execution.ensureCatalogInstance(allocator);
    const ctx = execution.ExecutionContext{ .catalog = catalog };
    var result = execution.executeProgramWithContext(allocator, &parsed.program, ctx) catch |err| return .{ .failed = err };
    defer result.deinit(allocator);
    const count: ?i64 = if (result.rows.len == 1 and result.rows[0].len == 1) switch (result.rows[0][0]) {
        .Int => |v| v,
        else => null,
    } else null;
    return .{ .rows = .{ .n = result.rows.len, .count = count } };
}

fn isTypedCorruptionError(err: anyerror) bool {
    return err == error.ChecksumMismatch or err == error.DataCorruption or err == error.InvalidData or
        err == error.GraphQuarantined or err == error.DecryptionFailed;
}

const queries = [_][]const u8{
    "MATCH (n:Person) RETURN n.name AS name",
    "MATCH (n) RETURN n.name AS name", // (d) unlabeled
    "MATCH (n) RETURN count(n) AS c",
};

const Case = struct { file: []const u8, damage: Damage, invalidate: bool };

const cases = [_]Case{
    .{ .file = "nodes.store", .damage = .zero_header, .invalidate = false }, // (a)
    .{ .file = "props.store", .damage = .zero_header, .invalidate = false }, // (a)
    .{ .file = "nodes.store", .damage = .zero_header, .invalidate = true }, // (a)+(b)
    .{ .file = "nodes.store", .damage = .zero_page, .invalidate = false }, // (c)+(d)
    .{ .file = "nodes.store", .damage = .zero_page, .invalidate = true }, // (b)
};

test "SONNY-2409: zeroed page headers and zeroed pages fail reads closed, labeled and unlabeled" {
    const allocator = std.testing.allocator;
    var silent: usize = 0;
    for (cases) |c| {
        for (queries) |q| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
            defer allocator.free(data_dir);
            defer graph_store.setDataDirOverride(allocator, null);

            try seedCleanStore(allocator, data_dir);
            try std.testing.expect(try damageFiles(data_dir, c.file, c.damage) > 0);
            if (c.invalidate) try std.testing.expect(try invalidateDerivedIndexSnapshots(data_dir) > 0);

            switch (try reopenAndRun(allocator, data_dir, q)) {
                .rows => |r| {
                    if (r.count) |cnt| if (cnt == NODES) continue;
                    std.debug.print("SILENTLY ACCEPTED: {s} {s} (snapshots {s}): '{s}' returned OK with {d} row(s), count {?d}\n", .{ c.file, @tagName(c.damage), if (c.invalidate) "rebuilt" else "kept", q, r.n, r.count });
                    silent += 1;
                },
                .failed => |err| if (!isTypedCorruptionError(err)) {
                    std.debug.print("{s} {s}: '{s}': unexpected error.{s}\n", .{ c.file, @tagName(c.damage), q, @errorName(err) });
                    return err;
                },
            }
        }
    }
    if (silent > 0) return error.CorruptionSilentlyAccepted;
}
