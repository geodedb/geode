// SONNY-6452 (1): stores written with page encryption by graph_storage
// <= 0.4.11 (SONNY-6441) lost the last 16 bytes of every encrypted page
// body: the pager wrote the AES-GCM tag over them. graph_storage 0.4.12
// reads such a page (it has no `PageFlags.encrypted` envelope flag) and
// zeroes that tail, so at geode's 8 KiB pages:
//   - every node in slot 169 of a node page lost `label_count`, `flags` and
//     `txn_stamp`: it reads back live with label_count 0 (a deleted one
//     reappears); a node with nothing else in its record (no labels,
//     properties or edges) reads back as an empty slot, i.e. it is gone;
//   - the last two heads of every `adj_in_dir` page read as "no head": the
//     incoming edges of those destination nodes are invisible.
//
// The contract (operator surface, the built geode binary):
//   - `geode storage verify --check tde-page-tail` reads the store files
//     without opening the store and reports, per graph and shard, the pages
//     still in the old envelope and the records they damaged; it exits 1
//     while anything is damaged and changes nothing (two runs agree);
//   - `geode storage repair --tde-page-tail` refuses without
//     `--i-have-a-backup` and without the key; with them it restores what
//     is derivable (label_count from the node's label block, txn_stamp,
//     the incoming-edge directory rebuilt from the outgoing edges), names
//     what is not (liveness of slot-169 nodes, nodes whose whole record was
//     the lost tail), rewrites the pages in the current envelope, and a
//     verify afterwards is clean.
//
// The old on-disk format is produced exactly as graph_storage's own
// regression (tests/tde_page_tail.zig at v0.4.12) does: each page is read
// through the current pager and written back in the legacy envelope
// (`PageEncryption.encryptPage`: write_count + 1, tag over the body tail),
// which is byte for byte what a 0.4.11 pager wrote.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const gs = @import("graph_storage");
const logging = @import("logging");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const StorageAdapter = geode.graph_storage_adapter.StorageAdapter;
const geode_binary = geode_test_bin.geode_exe;

const tde_key = [_]u8{0x52} ** 32;
const tde_key_hex = "52" ** 32;
const graph = "sonny6452";
const page_size: u32 = 8192;
/// Node records per 8 KiB page; slot 169 ends at the page end.
const nodes_per_page: u64 = 170;
/// Incoming-edge directory heads per 8 KiB page; heads 1018 and 1019 end at the page end.
const heads_per_page: u64 = 1020;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Env = struct { name: []const u8, value: []const u8 };

const Run = struct {
    code: ?u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }

    fn says(self: Run, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.stdout, needle) != null or std.mem.indexOf(u8, self.stderr, needle) != null;
    }

    fn dump(self: Run, what: []const u8) void {
        std.debug.print("SONNY-6452 {s}: exit={?d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ what, self.code, self.stdout, self.stderr });
    }
};

fn runGeode(argv: []const []const u8, cwd: []const u8, extra: []const Env) !Run {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("HOME", cwd);
    for (extra) |e| try env.put(e.name, e.value);
    const result = try std.process.run(testing.allocator, threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(16 << 20),
        .stderr_limit = .limited(16 << 20),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(600), .clock = .awake } },
    });
    const code: ?u8 = switch (result.term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .code = code, .stdout = result.stdout, .stderr = result.stderr };
}

/// What the seeded store holds.
const Seed = struct {
    /// Every node id created (sorted).
    ids: []u64,
    /// The source of the three edges (to 1017, 1018 and 1019).
    src: u64,
    /// A slot-169 node with labels N and B and a property.
    labelled: u64 = 169,
    /// A slot-169 node that was labelled and then deleted.
    deleted: u64 = 339,
    /// A slot-169 node with nothing but the lost tail in its record.
    bare: u64 = 509,

    fn deinit(self: Seed) void {
        testing.allocator.free(self.ids);
    }

    fn has(self: Seed, id: u64) bool {
        return std.sort.binarySearch(u64, self.ids, id, orderU64) != null;
    }
};

fn orderU64(a: u64, b: u64) std.math.Order {
    return std.math.order(a, b);
}

fn openAdapter(data_dir: []const u8, key: ?[32]u8) !*StorageAdapter {
    return StorageAdapter.init(testing.allocator, data_dir, .{
        .data_dir = data_dir,
        .encryption_key = key,
        .sync_mode = .deferred,
    });
}

/// Seed a store through geode's StorageAdapter (the engine the server
/// opens): bare nodes until ids 169, 339, 509, 1017, 1018 and 1019 exist,
/// then label every node N except the bare one, give 169 a second label and
/// a property, delete 339, and connect one source to 1017, 1018 and 1019.
fn seedStore(data_dir: []const u8, key: ?[32]u8) !Seed {
    const allocator = testing.allocator;
    const adapter = try openAdapter(data_dir, key);
    defer adapter.deinit();
    var ids: std.ArrayList(u64) = .empty;
    errdefer ids.deinit(allocator);
    const wanted = [_]u64{ 169, 339, 509, 1017, 1018, 1019 };
    var guard: usize = 0;
    while (true) : (guard += 1) {
        if (guard > 8000) return error.SeedIdsNotReached;
        var all = true;
        for (wanted) |w| {
            if (std.mem.indexOfScalar(u64, ids.items, w) == null) all = false;
        }
        if (all) break;
        try ids.append(allocator, try adapter.createNode(graph, &.{}));
    }
    std.mem.sort(u64, ids.items, {}, std.sort.asc(u64));
    var seed: Seed = .{ .ids = try ids.toOwnedSlice(allocator), .src = 0 };
    errdefer seed.deinit();
    for (seed.ids) |id| {
        if (id == seed.bare) continue;
        try adapter.addNodeLabel(graph, id, "N");
    }
    try adapter.addNodeLabel(graph, seed.labelled, "B");
    try adapter.setNodeProperty(graph, seed.labelled, "name", .{ .String = "slot-169" });
    try adapter.deleteNode(graph, seed.deleted);
    // A source that is none of the interesting nodes.
    seed.src = for (seed.ids) |id| {
        if (id % nodes_per_page != nodes_per_page - 1 and id != 1017 and id != 1018 and id != 1019) break id;
    } else return error.NoSource;
    for ([_]u64{ 1017, 1018, 1019 }) |dst| _ = try adapter.createEdge(graph, seed.src, dst, "E");
    try adapter.checkpointAll();
    return seed;
}

/// The store files a page-encrypting pager writes.
const paged_files = [_]gs.FileId{ .nodes, .adj_out, .adj_in, .props, .var_store, .in_idx, .in_dir };

/// Rewrite every written page of every store file under `data_dir` in the
/// pre-0.4.12 envelope, as a graph_storage 0.4.11 pager would have flushed
/// the same frame: the tag over the last 16 body bytes.
fn rewriteInLegacyEnvelope(data_dir: []const u8, key: [32]u8) !usize {
    const allocator = testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(fsIo(), data_dir, .{ .iterate = true });
    defer dir.close(fsIo());
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var shard_dirs: std.ArrayList([]u8) = .empty;
    defer {
        for (shard_dirs.items) |d| allocator.free(d);
        shard_dirs.deinit(allocator);
    }
    while (try walker.next(fsIo())) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, entry.basename, "nodes.store")) continue;
        const parent = std.fs.path.dirname(entry.path) orelse continue;
        try shard_dirs.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, parent }));
    }
    var rewritten: usize = 0;
    const enc = gs.encryption.PageEncryption.init(key);
    for (shard_dirs.items) |shard_dir| {
        for (paged_files) |fid| {
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ shard_dir, gs.file_manager.FILE_NAMES[@intFromEnum(fid)] });
            defer allocator.free(path);
            const file = std.Io.Dir.cwd().openFile(fsIo(), path, .{ .mode = .read_write }) catch |e| switch (e) {
                error.FileNotFound => continue,
                else => return e,
            };
            defer file.close(fsIo());
            var pager = gs.pager.Pager.init(file, page_size);
            pager.encryption = enc;
            pager.file_id = fid;
            const pages = (try file.stat(fsIo())).size / page_size;
            var raw: [page_size]u8 = undefined;
            var frame: [page_size]u8 = undefined;
            var pid: u64 = 0;
            while (pid < pages) : (pid += 1) {
                _ = try file.readPositionalAll(fsIo(), &raw, pid * page_size);
                if (std.mem.allEqual(u8, &raw, 0)) continue;
                try pager.readPage(pid, &frame);
                const wc = gs.page.readWriteCount(&frame) + 1;
                gs.page.writeWriteCount(&frame, wc);
                enc.encryptPage(&frame, pid, @intFromEnum(fid), wc);
                try file.writePositionalAll(fsIo(), &frame, pid * page_size);
                rewritten += 1;
            }
        }
    }
    return rewritten;
}

/// Copy the regular files of `src` into `dst` (same relative paths).
fn copyTree(src: []const u8, dst: []const u8) !void {
    const allocator = testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(fsIo(), src, .{ .iterate = true });
    defer dir.close(fsIo());
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(fsIo())) |entry| {
        const to = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dst, entry.path });
        defer allocator.free(to);
        switch (entry.kind) {
            .directory => try std.Io.Dir.cwd().createDirPath(fsIo(), to),
            .file => {
                if (std.fs.path.dirname(to)) |p| try std.Io.Dir.cwd().createDirPath(fsIo(), p);
                const data = try dir.readFileAlloc(fsIo(), entry.path, allocator, .limited(1 << 30));
                defer allocator.free(data);
                try std.Io.Dir.cwd().writeFile(fsIo(), .{ .sub_path = to, .data = data });
            },
            else => {},
        }
    }
}

/// The ids under `field` across every shard of every graph of a report.
fn reportIds(allocator: std.mem.Allocator, report: std.json.Value, field: []const u8) ![]u64 {
    var out: std.ArrayList(u64) = .empty;
    errdefer out.deinit(allocator);
    const graphs = report.object.get("graphs") orelse return error.ReportHasNoGraphs;
    for (graphs.array.items) |g| {
        const shards = g.object.get("shards") orelse return error.ReportHasNoShards;
        for (shards.array.items) |s| {
            const list = s.object.get(field) orelse return error.ReportFieldMissing;
            for (list.array.items) |v| try out.append(allocator, @intCast(v.integer));
        }
    }
    std.mem.sort(u64, out.items, {}, std.sort.asc(u64));
    return out.toOwnedSlice(allocator);
}

/// The report's verdict; a report without one fails the test.
fn reportOk(report: std.json.Value) !bool {
    if (report != .object) return error.ReportNotAnObject;
    const v = report.object.get("tde_page_tail_ok") orelse return error.ReportHasNoVerdict;
    return v.bool;
}

/// The number of entries under `field` across every shard of every graph.
fn reportCount(report: std.json.Value, field: []const u8) !u64 {
    var total: u64 = 0;
    const graphs = report.object.get("graphs") orelse return error.ReportHasNoGraphs;
    for (graphs.array.items) |g| {
        for ((g.object.get("shards") orelse return error.ReportHasNoShards).array.items) |s| {
            total += (s.object.get(field) orelse return error.ReportFieldMissing).array.items.len;
        }
    }
    return total;
}

/// Old-envelope pages of file `name` summed over every shard of every graph.
fn reportOldPages(report: std.json.Value, name: []const u8) !u64 {
    var total: u64 = 0;
    const graphs = report.object.get("graphs") orelse return error.ReportHasNoGraphs;
    for (graphs.array.items) |g| {
        for ((g.object.get("shards") orelse return error.ReportHasNoShards).array.items) |s| {
            const pages = s.object.get("old_format_pages") orelse return error.ReportFieldMissing;
            total += @intCast((pages.object.get(name) orelse return error.ReportFieldMissing).integer);
        }
    }
    return total;
}

fn expectIds(what: []const u8, got: []const u64, want: []const u64) !void {
    if (!std.mem.eql(u64, got, want)) {
        std.debug.print("SONNY-6452 {s}: got {any}, want {any}\n", .{ what, got, want });
        return error.TestExpectedEqual;
    }
}

/// Parse the single JSON document a command printed on stdout.
fn parseStdout(r: Run, what: []const u8) !std.json.Parsed(std.json.Value) {
    const start = std.mem.indexOfScalar(u8, r.stdout, '{') orelse {
        r.dump(what);
        return error.NoJsonOnStdout;
    };
    return std.json.parseFromSlice(std.json.Value, testing.allocator, std.mem.trimEnd(u8, r.stdout[start..], " \r\n"), .{}) catch |e| {
        r.dump(what);
        return e;
    };
}

fn verify(root: []const u8, data_dir: []const u8, key: bool) !Run {
    const env: []const Env = if (key) &.{.{ .name = "GEODE_TDE_KEY", .value = tde_key_hex }} else &.{};
    return runGeode(&.{ geode_binary, "storage", "verify", "--check", "tde-page-tail", "--data-dir", data_dir }, root, env);
}

test "SONNY-6452 (1) geode storage verify --check tde-page-tail finds the records an old-envelope store lost, and repair --tde-page-tail restores what is derivable" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    logging.init(.{ .level = .fatal });
    logging.setLevel(.fatal);
    var root = try test_scratch.ScratchDir.create("sonny6452-page-tail");
    defer root.remove();
    const data_dir = try std.fmt.allocPrint(allocator, "{s}/data", .{root.path()});
    defer allocator.free(data_dir);
    const control_dir = try std.fmt.allocPrint(allocator, "{s}/control", .{root.path()});
    defer allocator.free(control_dir);

    const seed = try seedStore(data_dir, tde_key);
    defer seed.deinit();
    try testing.expect(seed.has(seed.labelled) and seed.has(seed.deleted) and seed.has(seed.bare));
    const rewritten = try rewriteInLegacyEnvelope(data_dir, tde_key);
    try testing.expect(rewritten > 0);
    try copyTree(data_dir, control_dir);

    // The fixture reproduces the defect: opened by the current engine with
    // no repair, the slot-169 nodes lost their label count, the deleted one
    // is back, the bare one is gone, and the incoming edges to 1018 and
    // 1019 are invisible (1017's, whose head is not in the tail, are not).
    {
        const adapter = try openAdapter(control_dir, tde_key);
        defer adapter.deinit();
        const mg = try adapter.getOrCreateGraph(graph);
        const rec = (try mg.engine.getNode(seed.labelled)) orelse return error.LabelledNodeMissing;
        try testing.expectEqual(@as(u16, 0), rec.label_count);
        try testing.expect((try mg.engine.getNode(seed.deleted)) != null);
        try testing.expect((try mg.engine.getNode(seed.bare)) == null);
        for ([_]u64{ 1017, 1018, 1019 }, [_]bool{ true, false, false }) |dst, visible| {
            const in = try adapter.getIncomingEdges(graph, dst, allocator);
            defer allocator.free(in);
            var found = false;
            for (in) |e| found = found or e.neighbor == seed.src;
            try testing.expectEqual(visible, found);
        }
    }

    // Expected damage: every created slot-169 node but the bare one has an
    // unknown liveness; the bare one is lost; directory heads 1018/1019.
    var unknown_want: std.ArrayList(u64) = .empty;
    defer unknown_want.deinit(allocator);
    for (seed.ids) |id| {
        if (id % nodes_per_page == nodes_per_page - 1 and id != seed.bare) try unknown_want.append(allocator, id);
    }
    const lost_want = [_]u64{seed.bare};
    const heads_want = [_]u64{ heads_per_page - 2, heads_per_page - 1 };

    // verify, twice: the same report, exit 1, nothing changed.
    var first_report: []u8 = &.{};
    defer allocator.free(first_report);
    for (0..2) |round| {
        const r = try verify(root.path(), data_dir, true);
        defer r.deinit();
        if (r.code != @as(?u8, 1)) r.dump("verify an old-envelope store");
        try testing.expectEqual(@as(?u8, 1), r.code);
        const parsed = try parseStdout(r, "verify an old-envelope store");
        defer parsed.deinit();
        const rep = parsed.value;
        try testing.expect(!(try reportOk(rep)));
        try testing.expect(try reportOldPages(rep, "nodes") > 0);
        try testing.expect(try reportOldPages(rep, "in_dir") > 0);
        const unknown = try reportIds(allocator, rep, "nodes_liveness_unknown");
        defer allocator.free(unknown);
        try expectIds("verify: nodes with unknown liveness", unknown, unknown_want.items);
        const lost = try reportIds(allocator, rep, "nodes_lost");
        defer allocator.free(lost);
        try expectIds("verify: lost nodes", lost, &lost_want);
        const heads = try reportIds(allocator, rep, "in_dir_lost_heads");
        defer allocator.free(heads);
        try expectIds("verify: lost incoming-edge directory heads", heads, &heads_want);
        // geode's 8 KiB v2/v3 chain blocks end before the tail.
        try testing.expectEqual(@as(u64, 0), try reportCount(rep, "adjacency_entries"));
        if (round == 0) {
            first_report = try allocator.dupe(u8, r.stdout);
        } else if (!std.mem.eql(u8, first_report, r.stdout)) {
            std.debug.print("SONNY-6452: verify is not read-only, the second report differs:\n{s}\n---\n{s}\n", .{ first_report, r.stdout });
            return error.VerifyChangedTheStore;
        }
    }

    // Without the key the records cannot be read: refuse, name the key.
    {
        const r = try verify(root.path(), data_dir, false);
        defer r.deinit();
        const ok = r.code == @as(?u8, 1) and r.says("GEODE_TDE_KEY");
        if (!ok) r.dump("verify without the key");
        try testing.expect(ok);
    }

    // repair without the backup acknowledgement, or without the key: refused,
    // nothing written (the verify report is unchanged).
    {
        const env = [_]Env{.{ .name = "GEODE_TDE_KEY", .value = tde_key_hex }};
        const no_ack = try runGeode(&.{ geode_binary, "storage", "repair", "--tde-page-tail", "--data-dir", data_dir }, root.path(), &env);
        defer no_ack.deinit();
        const ok1 = no_ack.code == @as(?u8, 2) and no_ack.says("--i-have-a-backup");
        if (!ok1) no_ack.dump("repair without --i-have-a-backup");
        try testing.expect(ok1);
        const no_key = try runGeode(&.{ geode_binary, "storage", "repair", "--tde-page-tail", "--i-have-a-backup", "--data-dir", data_dir }, root.path(), &.{});
        defer no_key.deinit();
        const ok2 = no_key.code == @as(?u8, 1) and no_key.says("GEODE_TDE_KEY");
        if (!ok2) no_key.dump("repair without the key");
        try testing.expect(ok2);
        const r = try verify(root.path(), data_dir, true);
        defer r.deinit();
        try testing.expectEqualStrings(first_report, r.stdout);
    }

    // repair: exit 0, names what it could not recover, verify is clean after.
    {
        const env = [_]Env{.{ .name = "GEODE_TDE_KEY", .value = tde_key_hex }};
        const r = try runGeode(&.{ geode_binary, "storage", "repair", "--tde-page-tail", "--i-have-a-backup", "--data-dir", data_dir }, root.path(), &env);
        defer r.deinit();
        if (r.code != @as(?u8, 0)) r.dump("repair");
        try testing.expectEqual(@as(?u8, 0), r.code);
        const parsed = try parseStdout(r, "repair");
        defer parsed.deinit();
        const repaired = parsed.value.object.get("repaired") orelse return error.RepairReportMissing;
        try testing.expectEqual(@as(i64, @intCast(unknown_want.items.len)), (repaired.object.get("nodes_repaired") orelse return error.RepairReportMissing).integer);
        const before = parsed.value.object.get("before") orelse return error.RepairReportMissing;
        const unknown = try reportIds(allocator, before, "nodes_liveness_unknown");
        defer allocator.free(unknown);
        try expectIds("repair: nodes with unknown liveness", unknown, unknown_want.items);
        const lost = try reportIds(allocator, before, "nodes_lost");
        defer allocator.free(lost);
        try expectIds("repair: lost nodes", lost, &lost_want);
        const after = parsed.value.object.get("after") orelse return error.RepairReportMissing;
        try testing.expect(try reportOk(after));
    }
    {
        const r = try verify(root.path(), data_dir, true);
        defer r.deinit();
        if (r.code != @as(?u8, 0)) r.dump("verify after repair");
        try testing.expectEqual(@as(?u8, 0), r.code);
        const parsed = try parseStdout(r, "verify after repair");
        defer parsed.deinit();
        try testing.expect(try reportOk(parsed.value));
        try testing.expectEqual(@as(u64, 0), try reportOldPages(parsed.value, "in_dir"));
    }

    // The repaired store, opened by the engine.
    {
        const adapter = try openAdapter(data_dir, tde_key);
        defer adapter.deinit();
        const mg = try adapter.getOrCreateGraph(graph);
        const rec = (try mg.engine.getNode(seed.labelled)) orelse return error.LabelledNodeMissing;
        try testing.expectEqual(@as(u16, 2), rec.label_count);
        try testing.expectEqual(@as(u64, 1), rec.txn_stamp);
        // Liveness is not derivable: the deleted node stays live (reported,
        // never guessed); the bare node stays gone.
        try testing.expect((try mg.engine.getNode(seed.deleted)) != null);
        try testing.expect((try mg.engine.getNode(seed.bare)) == null);
        for ([_]u64{ 1017, 1018, 1019 }) |dst| {
            const in = try adapter.getIncomingEdges(graph, dst, allocator);
            defer allocator.free(in);
            var found = false;
            for (in) |e| found = found or e.neighbor == seed.src;
            if (!found) std.debug.print("SONNY-6452: incoming edge {d} -> {d} still invisible after repair\n", .{ seed.src, dst });
            try testing.expect(found);
        }
        // Every other node keeps its label.
        for (seed.ids) |id| {
            if (id == seed.bare or id == seed.deleted) continue;
            const labels = try adapter.getNodeLabels(graph, id, allocator);
            defer {
                for (labels) |l| allocator.free(l);
                allocator.free(labels);
            }
            var has_n = false;
            for (labels) |l| has_n = has_n or std.mem.eql(u8, l, "N");
            if (!has_n) std.debug.print("SONNY-6452: node {d} lost label N\n", .{id});
            try testing.expect(has_n);
        }
    }
}

test "SONNY-6452 (1) a plaintext store has nothing to check and needs no key" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    logging.init(.{ .level = .fatal });
    logging.setLevel(.fatal);
    var root = try test_scratch.ScratchDir.create("sonny6452-plain");
    defer root.remove();
    const data_dir = try std.fmt.allocPrint(allocator, "{s}/data", .{root.path()});
    defer allocator.free(data_dir);
    const seed = try seedStore(data_dir, null);
    defer seed.deinit();
    const r = try verify(root.path(), data_dir, false);
    defer r.deinit();
    if (r.code != @as(?u8, 0)) r.dump("verify a plaintext store");
    try testing.expectEqual(@as(?u8, 0), r.code);
    const parsed = try parseStdout(r, "verify a plaintext store");
    defer parsed.deinit();
    try testing.expect(try reportOk(parsed.value));
    try testing.expectEqual(@as(u64, 0), try reportOldPages(parsed.value, "nodes"));
}
