// SONNY-6547 (2): SHOW GRAPHS fails when its graph listing fails; it does
// not answer a short or empty graph list.
//
// `statement_handlers.executeShow` listed the graphs with
// `read_store.listGraphNames(allocator) catch null` and answered no rows when
// the listing failed: a successful and wrong answer (the defect SONNY-6541
// item 4 fixed for SHOW TABLES).
//
// A real listing failure, in process: SHOW GRAPHS runs through the executor
// with every allocation the request makes counted, and allocation number k
// fails (`std.testing.FailingAllocator`), for every k until a run makes no
// failing allocation. Each run must either fail or list every graph.
//
// CANARY: REQ=REQ-SONNY-6547-SHOW-GRAPHS-ERRORS; FEATURE="SHOW GRAPHS"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6547_show_graphs_errors.zig; OWNER=execution; UPDATED=2026-11-14

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const query_arena = geode.query_arena;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn run(allocator: std.mem.Allocator, session: *execution.SessionState, q: []const u8) !usize {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const prev_scratch = query_arena.pushScratchAllocator(scratch.allocator());
    defer query_arena.popScratchAllocator(prev_scratch);
    var parsed = try geode.parseGql(q, allocator);
    defer parsed.deinit();
    const catalog = try execution.ensureCatalogInstance(std.testing.allocator);
    var result = try execution.executeProgramWithContext(allocator, &parsed.program, .{ .catalog = catalog, .session_state = session });
    defer result.deinit(allocator);
    return result.rows.len;
}

test "SONNY-6547 (2): SHOW GRAPHS fails when its graph listing fails" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    _ = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();
    defer execution.cleanupCatalogInstance();
    var session = execution.SessionState.init(allocator);
    defer session.deinit();
    _ = try run(allocator, &session, "CREATE GRAPH ga6547");
    _ = try run(allocator, &session, "CREATE GRAPH gb6547");
    _ = try run(allocator, &session, "CREATE (:N6547 {k: 1})");
    const all = try run(allocator, &session, "SHOW GRAPHS");
    try std.testing.expect(all >= 3);

    // The failing runs may leave what they allocated before the failure
    // behind (an error path of the executor, not this listing): counted
    // against the page allocator, which checks no leak.
    var wrong: usize = 0;
    var failed: usize = 0;
    var k: usize = 0;
    while (k < 4096) : (k += 1) {
        var fa = std.testing.FailingAllocator.init(std.heap.page_allocator, .{ .fail_index = k });
        const rows = run(fa.allocator(), &session, "SHOW GRAPHS") catch {
            failed += 1;
            continue;
        };
        if (!fa.has_induced_failure) break;
        if (rows != all) {
            wrong += 1;
            std.debug.print("SONNY-6547 (2): allocation {d} failed, and SHOW GRAPHS answered {d} row(s) of {d} instead of failing\n", .{ k, rows, all });
        }
    }
    std.debug.print("SONNY-6547 (2): {d} failing allocation(s) tried; {d} failed the statement, {d} answered wrongly\n", .{ k, failed, wrong });
    try std.testing.expect(k < 4096);
    try std.testing.expectEqual(@as(usize, 0), wrong);
}
