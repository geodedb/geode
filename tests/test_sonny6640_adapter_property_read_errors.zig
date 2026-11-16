// SONNY-6640: the storage adapter's engine-direct property reads report a
// read error as the error; they never take it for an absent property.
//
// Three adapter paths read one node property straight from the engine
// (`StorageAdapter.getNodeProperty`) and swallowed its error:
//   - `lookupNodeIdByLabelAndAllProps` (the bulk relationship-MERGE endpoint
//     resolver, engine slot ids): `catch null`, so the candidate "did not
//     match" and the endpoint was reported missing (the edge was skipped);
//   - `publicNodeFilterMatchesNoHydrate`, behind
//     `lookupPublicNodeIdByLabelAndAllProps` (public ids): `catch null`, the
//     same;
//   - `probeOrderedColumnClass` (the ORDER BY ... LIMIT ordered-index gate):
//     `catch return false`, so the column was declined as if a value broke it.
//
// A real store with a data directory and the real executor in process. The
// adapter's allocator is wrapped in a `FailingAllocator` that fails from the
// k-th allocation on, for every k up to the first call that needs none: the
// property exists and cannot be read. Each call must answer the healthy
// answer or fail with an error; the "missing" answer (or a declined column)
// is the defect.
//
// CANARY: REQ=REQ-SONNY-6640-ADAPTER-PROPERTY-READ-ERRORS; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6640_adapter_property_read_errors.zig; OWNER=storage; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const graph_storage_adapter = geode.graph_storage_adapter;
const PropKV = graph_storage_adapter.StorageAdapter.PropKV;
const G = graph_store.DEFAULT_GRAPH_NAME;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
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
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    fn run(self: *Harness, query: []const u8) !void {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        var r = try execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
        r.deinit(aa);
    }
};

/// The adapter's allocator, failing from the k-th allocation on while armed.
const AllocFault = struct {
    adapter: *graph_storage_adapter.StorageAdapter,
    real: std.mem.Allocator,
    fa: std.testing.FailingAllocator,

    /// `self` must not move while armed (the adapter points into it).
    fn init(self: *AllocFault, adapter: *graph_storage_adapter.StorageAdapter) void {
        self.* = .{ .adapter = adapter, .real = adapter.allocator, .fa = std.testing.FailingAllocator.init(adapter.allocator, .{}) };
    }

    fn armFrom(self: *AllocFault, k: usize) void {
        self.fa.fail_index = self.fa.alloc_index + k;
        self.fa.has_induced_failure = false;
        self.adapter.allocator = self.fa.allocator();
    }

    /// Restores the real allocator; whether a failure was induced.
    fn off(self: *AllocFault) bool {
        self.adapter.allocator = self.real;
        self.fa.fail_index = std.math.maxInt(usize);
        return self.fa.has_induced_failure;
    }
};

const missing = error.EndpointMissing6640;

fn seed(h: *Harness) !void {
    try h.run("MERGE (n:P6640 {k: 'key-one'}) SET n.s = 'alpha'");
    try h.run("MERGE (n:P6640 {k: 'key-two'}) SET n.s = 'beta'");
}

const Lookup = enum { slot, public };

fn lookup(adapter: *graph_storage_adapter.StorageAdapter, which: Lookup, filters: []const PropKV) !u64 {
    return switch (which) {
        .slot => adapter.lookupNodeIdByLabelAndAllProps(G, "P6640", filters, missing),
        .public => adapter.lookupPublicNodeIdByLabelAndAllProps(G, "P6640", filters, missing),
    };
}

fn sweepLookup(adapter: *graph_storage_adapter.StorageAdapter, which: Lookup) !usize {
    const filters = [_]PropKV{
        .{ .key = "k", .value = .{ .String = "key-one" } },
        .{ .key = "s", .value = .{ .String = "alpha" } },
    };
    const healthy = try lookup(adapter, which, &filters);

    var fault: AllocFault = undefined;
    fault.init(adapter);
    var wrong: usize = 0;
    var k: usize = 0;
    while (k < 64) : (k += 1) {
        fault.armFrom(k);
        const result = lookup(adapter, which, &filters);
        const induced = fault.off();
        if (result) |id| {
            if (id != healthy) {
                wrong += 1;
                std.debug.print("SONNY-6640 {s}: allocation {d} on failing answered node {d}, not {d}\n", .{ @tagName(which), k, id, healthy });
            }
        } else |err| {
            if (err == missing) {
                wrong += 1;
                std.debug.print("SONNY-6640 {s}: allocation {d} on failing answered \"missing\" for a node that exists\n", .{ @tagName(which), k });
            }
        }
        if (!induced) break;
    }
    // The healthy answer still stands afterwards.
    try testing.expectEqual(healthy, try lookup(adapter, which, &filters));
    return wrong;
}

test "SONNY-6640: the endpoint resolvers report an engine property read error, never a missing node" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seed(&h);
    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    var wrong: usize = 0;
    wrong += try sweepLookup(adapter, .slot);
    wrong += try sweepLookup(adapter, .public);
    try testing.expectEqual(@as(usize, 0), wrong);
}

/// `probeOrderedColumnClass` as an error union (the read error, or the answer).
fn probe(adapter: *graph_storage_adapter.StorageAdapter) !bool {
    return adapter.probeOrderedColumnClass(G, "P6640", "s");
}

test "SONNY-6640: the ordered-index column probe reports an engine property read error, never a declined column" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seed(&h);
    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    try testing.expect(try probe(adapter));

    var fault: AllocFault = undefined;
    fault.init(adapter);
    var wrong: usize = 0;
    var k: usize = 0;
    while (k < 64) : (k += 1) {
        fault.armFrom(k);
        const result = probe(adapter);
        const induced = fault.off();
        if (result) |ok| {
            if (!ok) {
                wrong += 1;
                std.debug.print("SONNY-6640 probe: allocation {d} on failing declined a column every value of which is a canonical STRING\n", .{k});
            }
        } else |_| {}
        if (!induced) break;
    }
    try testing.expect(try probe(adapter));
    try testing.expectEqual(@as(usize, 0), wrong);
}
