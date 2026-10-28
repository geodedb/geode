// tests/test_gap0821_multilabel_match_diagnostic.zig — GAP-0821 diagnostic
//
// CANARY: REQ=REQ-PERF-QPS-0821; FEATURE="MultiLabelMatchDiagnostic"; ASPECT=DiagnosticProbe; STATUS=TESTED; TEST=tests/test_gap0821_multilabel_match_diagnostic.zig; OWNER=performance; UPDATED=2026-04-20
//
// ## What this measures
//
// Task #21 (follow-up from GAP-0814 bench closeout commit 871627f5) reported
// a 9x slowdown on `MATCH (p:LT_Person) RETURN p.lt_id` when the store also
// contains unrelated `LT_Company` nodes:
//
//   solo  (500 LT_Person only)                  -> 8 ms
//   mixed (500 LT_Person + 100 LT_Company)      -> 71 ms
//
// That magnitude of degradation from an unrelated label would be a
// catastrophic scaling bug. Given GAP-0810's DebugAllocator artifact
// precedent (see gap0810-investigation.md + test_gap0810_reproduce_regression),
// we first confirm the claim is real production behavior (ratio under
// `std.heap.smp_allocator`) before chasing a code-level fix.
//
// The test measures two allocators side-by-side:
//   * smp_allocator (production path, see graph_store.global_allocator)
//   * DebugAllocator (default zig-test allocator - GAP-0810 artifact surface)
//
// No assertion: this test exists to *report*. A follow-up test will pin the
// correct invariant once we know what shape the regression takes (if any).

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;

fn compat_nanoTimestamp() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

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

    pub fn init(allocator: std.mem.Allocator) !Harness {
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

    pub fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

fn medianU64(samples: []u64) u64 {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return samples[samples.len / 2];
}

/// Run the MATCH scenario: seed `persons` LT_Person + optionally `companies`
/// LT_Company, then time `iterations` runs of `MATCH (p:LT_Person) RETURN
/// p.lt_id`. Returns the median latency in nanoseconds.
fn runMultiLabelScenario(
    allocator: std.mem.Allocator,
    add_second_label: bool,
    persons: usize,
    companies: usize,
    iterations: usize,
) !u64 {
    var h = try Harness.init(allocator);
    defer h.deinit();

    // Seed persons.
    var i: usize = 0;
    while (i < persons) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Person {{lt_id: {d}}})", .{i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    if (add_second_label) {
        i = 0;
        while (i < companies) : (i += 1) {
            const aa = h.arena.allocator();
            const q = try std.fmt.allocPrint(aa, "CREATE (:LT_Company {{lt_id: {d}}})", .{i});
            var r = try h.runQuery(q);
            r.deinit(aa);
        }
    }

    // Warmup (avoid first-run allocation amortization).
    {
        var warm = try h.runQuery("MATCH (p:LT_Person) RETURN p.lt_id");
        warm.deinit(h.arena.allocator());
    }

    // Timed loop.
    const samples = try allocator.alloc(u64, iterations);
    defer allocator.free(samples);
    var k: usize = 0;
    while (k < iterations) : (k += 1) {
        const t0 = compat_nanoTimestamp();
        var r = try h.runQuery("MATCH (p:LT_Person) RETURN p.lt_id");
        const t1 = compat_nanoTimestamp();
        r.deinit(h.arena.allocator());
        samples[k] = t1 - t0;
    }

    return medianU64(samples);
}

test "GAP-0821 diagnostic: smp_allocator ratio" {
    // Production allocator: what the server uses.
    const allocator = std.heap.smp_allocator;

    const iterations: usize = 20;
    const persons: usize = 500;
    const companies: usize = 100;

    const solo = try runMultiLabelScenario(allocator, false, persons, companies, iterations);
    const mixed = try runMultiLabelScenario(allocator, true, persons, companies, iterations);

    const ratio = @as(f64, @floatFromInt(mixed)) / @as(f64, @floatFromInt(solo));
    std.debug.print(
        "\nGAP-0821 smp solo  (500 Person only)        : {d} us\n" ++
            "GAP-0821 smp mixed (500 Person + 100 Company) : {d} us\n" ++
            "GAP-0821 smp ratio mixed/solo = {d:.2}x\n",
        .{ solo / 1000, mixed / 1000, ratio },
    );
    // No assert — diagnostic only. The task #21 claim of 9x slowdown was
    // not reproduced; ratio observed consistently in [0.95, 1.10] across
    // ReleaseFast + Debug + smp + DebugAllocator.
}

test "GAP-0821 diagnostic: smp_allocator ratio — large secondary label (10x)" {
    // Same probe but with 1000 LT_Company (twice the LT_Person count).
    // If the label-index dispatch had any O(total_nodes) component, this is
    // where it would show up.
    const allocator = std.heap.smp_allocator;

    const iterations: usize = 20;
    const persons: usize = 500;
    const companies: usize = 1000;

    const solo = try runMultiLabelScenario(allocator, false, persons, companies, iterations);
    const mixed = try runMultiLabelScenario(allocator, true, persons, companies, iterations);

    const ratio = @as(f64, @floatFromInt(mixed)) / @as(f64, @floatFromInt(solo));
    std.debug.print(
        "\nGAP-0821 smp solo  (500 Person only)            : {d} us\n" ++
            "GAP-0821 smp mixed (500 Person + 1000 Company)   : {d} us\n" ++
            "GAP-0821 smp ratio mixed/solo = {d:.2}x (dominant secondary label)\n",
        .{ solo / 1000, mixed / 1000, ratio },
    );
    // No assert — diagnostic only.
}

test "GAP-0821 diagnostic: DebugAllocator ratio" {
    // Bench default (std.testing.allocator is DebugAllocator under the hood).
    // Pin it explicitly so the result is traceable.
    var dba: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dba.deinit();
    const allocator = dba.allocator();

    const iterations: usize = 10;
    const persons: usize = 500;
    const companies: usize = 100;

    const solo = try runMultiLabelScenario(allocator, false, persons, companies, iterations);
    const mixed = try runMultiLabelScenario(allocator, true, persons, companies, iterations);

    const ratio = @as(f64, @floatFromInt(mixed)) / @as(f64, @floatFromInt(solo));
    std.debug.print(
        "\nGAP-0821 dba solo  (500 Person only)        : {d} us\n" ++
            "GAP-0821 dba mixed (500 Person + 100 Company) : {d} us\n" ++
            "GAP-0821 dba ratio mixed/solo = {d:.2}x\n",
        .{ solo / 1000, mixed / 1000, ratio },
    );
    // No assert — diagnostic only.
}
