// SONNY-1319 regression: the index and constraint catalogs are graph-scoped.
//
// The catalog keyed an index `<label>:<name>` and a constraint the same way,
// with no graph, so with two graphs g1 and g2:
//   (a) `CREATE INDEX IF NOT EXISTS i ...` in g2 was a silent no-op when g1
//       already had `i`, and a plain CREATE answered 42P07;
//   (b) `DROP INDEX i` issued in g2 removed g1's `i`;
//   (c) `CREATE CONSTRAINT c ...` in g2 was refused (42710) when g1 had `c`,
//       and SHOW INDEXES / SHOW CONSTRAINTS in a fresh graph listed every
//       other graph's rows.
// Under one-graph-per-tenant isolation that let one tenant drop another's
// indexes by name.
//
// Now every row carries the graph it was created in; CREATE / IF NOT EXISTS /
// DROP / SHOW resolve within the session's graph. Two exceptions, both pinned
// here:
//   * A row whose runtime structure is process-wide and keyed by index name
//     (the HNSW vector and the other advanced indexes — SONNY-1223) cannot
//     have a same-named twin in another graph; that CREATE is refused with
//     IndexNameInUseByOtherGraph, never a silent IF NOT EXISTS no-op.
//   * A row written by the old engine-global catalog (no graph recorded)
//     keeps its old meaning — it applies to every graph — so an upgrade loses
//     no index or constraint.
// Graph scoping survives a restart.
//
// Constraint ENFORCEMENT on CREATE / MERGE / SET is not this ticket's: it is
// SONNY-2846 / SONNY-3358.
//
// Real executor, real persisted store and catalog; no mocks.
//
// CANARY: REQ=REQ-SONNY-1319-GRAPH-SCOPED-CATALOG; FEATURE="SchemaCatalog"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny1319_graph_scoped_catalog.zig; OWNER=catalog; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// The store-level restart harness of tests/test_advanced_index_restart.zig:
/// tear the process-global engine state down and bring it back up against the
/// SAME data dir, so the catalog really is reloaded from `geode_catalog.dat`.
const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);
        const catalog = try execution.ensureCatalogInstance(allocator);

        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .session = execution.SessionState.init(allocator),
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    fn deinit(self: *Harness) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.arena.deinit();
        self.tmp.cleanup();
    }

    /// Tear down; run `between` (if any) while nothing is loaded; come back up.
    fn restartWith(self: *Harness, between: ?*const fn ([]const u8) anyerror!void) !void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();

        if (between) |f| try f(self.data_dir);

        _ = graph_store.getGlobalStore(self.allocator);
        const catalog = try execution.ensureCatalogInstance(self.allocator);
        self.session = execution.SessionState.init(self.allocator);
        self.ctx = execution.ExecutionContext{ .catalog = catalog };
    }

    fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn run(self: *Harness, query: []const u8) !void {
        _ = self.exec(query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
    }

    /// The error `query` was refused with, by name (so the assertion is a
    /// runtime one, and compiles against an engine that has no such error).
    fn refusal(self: *Harness, query: []const u8) ![]const u8 {
        if (self.exec(query)) |_| {
            std.debug.print("{s}: ran; expected a refusal\n", .{query});
            return error.ExpectedRefusal;
        } else |err| return @errorName(err);
    }

    /// How many rows of `show` (SHOW INDEXES / SHOW CONSTRAINTS) name `name`
    /// in column 0, in the session's graph.
    fn listed(self: *Harness, show: []const u8, name: []const u8) !usize {
        const res = try self.exec(show);
        var n: usize = 0;
        for (res.rows) |row| {
            if (row.len == 0) continue;
            switch (row[0]) {
                .Str => |s| if (std.mem.eql(u8, s, name)) {
                    n += 1;
                },
                else => {},
            }
        }
        return n;
    }

    fn indexes(self: *Harness, name: []const u8) !usize {
        return self.listed("SHOW INDEXES", name);
    }

    fn constraints(self: *Harness, name: []const u8) !usize {
        return self.listed("SHOW CONSTRAINTS", name);
    }
};

fn putU32(buf: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try buf.appendSlice(testing.allocator, &b);
}

fn putStr(buf: *std.ArrayList(u8), s: []const u8) !void {
    try putU32(buf, @intCast(s.len));
    try buf.appendSlice(testing.allocator, s);
}

/// A `geode_catalog.dat` exactly as the engine-global catalog wrote it (no
/// graph on any row): one btree index `legacy_idx` on Legacy(k) and one
/// UNIQUE constraint `legacy_u` on Legacy(k). Plaintext: TDE is off here.
fn writeLegacyCatalog(data_dir: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    // Header: schemas, graphs, indexes, constraints.
    try putU32(&buf, 0);
    try putU32(&buf, 0);
    try putU32(&buf, 1);
    try putU32(&buf, 1);
    // Index: name, type, table, columns.
    try putStr(&buf, "legacy_idx");
    try putStr(&buf, "btree");
    try putStr(&buf, "Legacy");
    try putU32(&buf, 1);
    try putStr(&buf, "k");
    // Constraint: name, type byte (unique = 0), label, enforced, properties.
    try putStr(&buf, "legacy_u");
    try buf.append(testing.allocator, 0);
    try putStr(&buf, "Legacy");
    try buf.append(testing.allocator, 1);
    try putU32(&buf, 1);
    try putStr(&buf, "k");

    const path = try std.fmt.allocPrint(testing.allocator, "{s}/geode_catalog.dat", .{data_dir});
    defer testing.allocator.free(path);
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, buf.items);
}

// One harness for every phase: the hnsw library keeps a worker pool alive
// across index lifetimes, so a per-test store re-init tears global state out
// from under parked pool threads (tests/test_eng3912_dim_pinning.zig).
test "SONNY-1319: index and constraint catalogs are graph-scoped (IF NOT EXISTS, DROP, SHOW, CREATE CONSTRAINT, restart, legacy catalog)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.run("CREATE GRAPH g1");
    try h.run("CREATE GRAPH g2");

    // ---- SHOW INDEXES in a fresh graph lists no other graph's index ----
    try h.run("USE GRAPH g1");
    try h.run("CREATE INDEX shared_idx FOR (n:Item) ON (n.k)");
    try testing.expectEqual(@as(usize, 1), try h.indexes("shared_idx"));
    try h.run("USE GRAPH g2");
    try testing.expectEqual(@as(usize, 0), try h.indexes("shared_idx"));
    try h.run("USE GRAPH default");
    try testing.expectEqual(@as(usize, 0), try h.indexes("shared_idx"));

    // ---- (a) IF NOT EXISTS in g2 creates g2's own index ----
    try h.run("USE GRAPH g2");
    try h.run("CREATE INDEX IF NOT EXISTS shared_idx FOR (n:Item) ON (n.k)");
    try testing.expectEqual(@as(usize, 1), try h.indexes("shared_idx"));
    // ...and is a no-op the second time, in the same graph.
    try h.run("CREATE INDEX IF NOT EXISTS shared_idx FOR (n:Item) ON (n.k)");
    try testing.expectEqual(@as(usize, 1), try h.indexes("shared_idx"));
    // A plain duplicate in the same graph is still 42P07.
    try testing.expectEqualStrings("DuplicateIndex", try h.refusal("CREATE INDEX shared_idx FOR (n:Item) ON (n.k)"));

    // ---- (b) DROP INDEX in g1 removes g1's index only ----
    try h.run("USE GRAPH g1");
    try h.run("DROP INDEX shared_idx");
    try testing.expectEqual(@as(usize, 0), try h.indexes("shared_idx"));
    try h.run("USE GRAPH g2");
    try testing.expectEqual(@as(usize, 1), try h.indexes("shared_idx"));
    // g1 no longer has one; g2's is not reachable from g1.
    try h.run("USE GRAPH g1");
    try testing.expectEqualStrings("IndexNotFound", try h.refusal("DROP INDEX shared_idx"));
    try h.run("DROP INDEX IF EXISTS shared_idx");
    try h.run("USE GRAPH g2");
    try testing.expectEqual(@as(usize, 1), try h.indexes("shared_idx"));

    // A plain (no IF NOT EXISTS) same-named CREATE in another graph runs.
    try h.run("USE GRAPH g1");
    try h.run("CREATE INDEX shared_idx FOR (n:Item) ON (n.k)");
    try h.run("USE GRAPH g2");
    try h.run("DROP INDEX shared_idx");
    try testing.expectEqual(@as(usize, 0), try h.indexes("shared_idx"));
    try h.run("USE GRAPH g1");
    try testing.expectEqual(@as(usize, 1), try h.indexes("shared_idx"));

    // ---- (c) constraints: per graph, listed in their graph only ----
    try h.run("USE GRAPH g1");
    try h.run("CREATE CONSTRAINT uniq_k FOR (n:Item) REQUIRE n.k IS UNIQUE");
    try testing.expectEqual(@as(usize, 1), try h.constraints("uniq_k"));
    try h.run("USE GRAPH g2");
    try testing.expectEqual(@as(usize, 0), try h.constraints("uniq_k"));
    try h.run("CREATE CONSTRAINT uniq_k FOR (n:Item) REQUIRE n.k IS UNIQUE");
    try testing.expectEqual(@as(usize, 1), try h.constraints("uniq_k"));
    try testing.expectEqualStrings("ConstraintAlreadyExists", try h.refusal("CREATE CONSTRAINT uniq_k FOR (n:Item) REQUIRE n.k IS UNIQUE"));
    try h.run("CREATE CONSTRAINT IF NOT EXISTS uniq_k FOR (n:Item) REQUIRE n.k IS UNIQUE");
    try h.run("USE GRAPH default");
    try testing.expectEqual(@as(usize, 0), try h.constraints("uniq_k"));

    // ---- a process-wide (name-keyed) runtime index cannot be twinned ----
    // The HNSW index behind `USING HNSW` is one process-wide object per name
    // (SONNY-1223); a second graph's same-named one would share it. That is
    // refused loudly — the IF NOT EXISTS form included — not swallowed.
    try h.run("USE GRAPH g1");
    try h.run("CREATE INDEX vec_1319 ON V1319 (emb) USING HNSW WITH (metric = 'l2')");
    try h.run("USE GRAPH g2");
    try testing.expectEqual(@as(usize, 0), try h.indexes("vec_1319"));
    try testing.expectEqualStrings("IndexNameInUseByOtherGraph", try h.refusal("CREATE INDEX IF NOT EXISTS vec_1319 ON V1319 (emb) USING HNSW WITH (metric = 'l2')"));
    try testing.expectEqualStrings("IndexNameInUseByOtherGraph", try h.refusal("CREATE INDEX vec_1319 FOR (n:Item) ON (n.k)"));
    try testing.expectEqual(@as(usize, 0), try h.indexes("vec_1319"));
    try testing.expectEqualStrings("IndexNotFound", try h.refusal("DROP INDEX vec_1319"));
    try h.run("USE GRAPH g1");
    try testing.expectEqual(@as(usize, 1), try h.indexes("vec_1319"));

    // ---- graph scoping survives a restart ----
    try h.run("CREATE INDEX persist_idx FOR (n:P) ON (n.k)");
    try h.run("USE GRAPH g2");
    try h.run("CREATE INDEX persist_idx FOR (n:P) ON (n.k)");
    try h.restartWith(null);
    try h.run("USE GRAPH g1");
    try testing.expectEqual(@as(usize, 1), try h.indexes("persist_idx"));
    try testing.expectEqual(@as(usize, 1), try h.indexes("vec_1319"));
    try testing.expectEqual(@as(usize, 1), try h.constraints("uniq_k"));
    try h.run("USE GRAPH g2");
    try testing.expectEqual(@as(usize, 1), try h.indexes("persist_idx"));
    try testing.expectEqual(@as(usize, 0), try h.indexes("vec_1319"));
    try testing.expectEqual(@as(usize, 1), try h.constraints("uniq_k"));
    try h.run("DROP INDEX persist_idx");
    try testing.expectEqual(@as(usize, 0), try h.indexes("persist_idx"));
    try h.run("USE GRAPH g1");
    try testing.expectEqual(@as(usize, 1), try h.indexes("persist_idx"));
    try h.run("USE GRAPH default");
    try testing.expectEqual(@as(usize, 0), try h.indexes("persist_idx"));
    try testing.expectEqual(@as(usize, 0), try h.constraints("uniq_k"));

    // ---- a catalog written by the engine-global engine loses nothing ----
    // Its rows recorded no graph; they keep their old meaning (every graph).
    try h.restartWith(writeLegacyCatalog);
    try testing.expectEqual(@as(usize, 1), try h.indexes("legacy_idx"));
    try testing.expectEqual(@as(usize, 1), try h.constraints("legacy_u"));
    try h.run("CREATE GRAPH legacy_g");
    try h.run("USE GRAPH legacy_g");
    try testing.expectEqual(@as(usize, 1), try h.indexes("legacy_idx"));
    try testing.expectEqual(@as(usize, 1), try h.constraints("legacy_u"));
    try h.run("CREATE INDEX IF NOT EXISTS legacy_idx FOR (n:Legacy) ON (n.k)");
    try testing.expectEqualStrings("DuplicateIndex", try h.refusal("CREATE INDEX legacy_idx FOR (n:Legacy) ON (n.k)"));
    try testing.expectEqualStrings("ConstraintAlreadyExists", try h.refusal("CREATE CONSTRAINT legacy_u FOR (n:Legacy) REQUIRE n.k IS UNIQUE"));
    try testing.expectEqual(@as(usize, 1), try h.indexes("legacy_idx"));
    // CREATE GRAPH re-saved the catalog in the current format; the legacy
    // rows keep their every-graph meaning across that restart too.
    try h.restartWith(null);
    try testing.expectEqual(@as(usize, 1), try h.indexes("legacy_idx"));
    try h.run("USE GRAPH legacy_g");
    try testing.expectEqual(@as(usize, 1), try h.indexes("legacy_idx"));
    try testing.expectEqual(@as(usize, 1), try h.constraints("legacy_u"));
}
