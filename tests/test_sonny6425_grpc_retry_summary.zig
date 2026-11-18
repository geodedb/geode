// SONNY-6425 item 6 (the remainder of SONNY-6384 item 6).
//
// `geode query --grpc --file`: when the server rejects a chunk, the CLI
// retries its statements one at a time (`retryChunkStatementByStatement`).
// A retried statement whose connection fails after it was sent (or whose
// client times out) must stop the run, not be sent again, and still print
// the chunked-execution summary, as a chunk does since SONNY-6384. The retry's
// gRPC branch called `executeGrpcQuery` without `return_unknown_outcome`, so
// it exited the process there: no summary, and no word on how many
// statements were not run.
//
// The server, the CLI and the wire protocol are real; the SONNY-6377 relay
// answers the first Execute (the rejected chunk) and resets the client's
// connection once the second (the first retried statement) reached the
// server.
//
// CANARY: REQ=REQ-SONNY-6425-GRPC-RETRY-SUMMARY; FEATURE="ChunkedExecution"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6425_grpc_retry_summary.zig; OWNER=cli; UPDATED=2026-11-12

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const h = @import("test_sonny6377_query_no_resend.zig");

test "SONNY-6425 item 6: a retried statement whose gRPC connection fails after it was sent stops the run and prints the summary" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try h.skipWithoutBinary();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const dir = try h.freshDir(aa, "grpc-retry-summary");
    defer h.removeDir(dir);
    const grpc_port = try util.getRandomPort();
    var s = try h.Server.start(testing.allocator, dir, grpc_port);
    defer s.stop(testing.allocator);

    const proxy = try h.ResetProxy.start(testing.allocator, grpc_port);
    defer proxy.stop();
    // The chunk's Execute is answered (rejected); the next one is reset.
    proxy.pass_executes = 1;
    const proxy_addr = try std.fmt.allocPrint(aa, "127.0.0.1:{d}", .{proxy.port});

    // One 32 KiB chunk whose last statement does not parse, so the server
    // rejects the chunk and the CLI retries it statement by statement.
    const chunk = try h.buildChunk(aa, "Sonny6425Retry");
    const content = try std.mem.concat(aa, u8, &.{ chunk, "CREATE (n:Sonny6425Retry {i: });\n" });
    const path = try std.fmt.allocPrint(aa, "{s}/chunks.gql", .{dir});
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = content });

    const r = try h.runGeode(aa, &.{ h.binary_path, "query", "--grpc", "--server", proxy_addr, "--insecure", "--no-saved-session", "--format", "json", "-U", h.admin_user, "-P", h.admin_pw, "--file", path }, 300_000);

    if (!h.contains(r.output, "using chunked execution")) {
        std.debug.print("fixture did not chunk:\n{s}\n", .{r.output});
        return error.FixtureDidNotChunk;
    }
    if (!h.contains(r.output, "retrying its")) {
        std.debug.print("fixture: the chunk was not retried statement by statement:\n{s}\n", .{r.output});
        return error.FixtureNoRetry;
    }

    var violations: usize = 0;
    const executes = proxy.executes.load(.acquire);
    if (executes != 2) {
        std.debug.print("VIOLATION: the server received {d} Execute requests; expected 2 (the chunk, then the first retried statement, after which the run stops)\n", .{executes});
        violations += 1;
    }
    if (!h.contains(r.output, "may or may not have executed")) {
        std.debug.print("VIOLATION: the client did not say the statement may have executed\n", .{});
        violations += 1;
    }
    if (!h.contains(r.output, "Chunked execution complete")) {
        std.debug.print("VIOLATION: no chunked-execution summary was printed\n", .{});
        violations += 1;
    }
    if (!h.contains(r.output, "were not executed")) {
        std.debug.print("VIOLATION: the run did not say the statements after it were not executed\n", .{});
        violations += 1;
    }
    if (r.code != 1) {
        std.debug.print("VIOLATION: exited {d}; expected 1 (general_error)\n", .{r.code});
        violations += 1;
    }
    if (violations > 0) {
        std.debug.print("transcript:\n{s}\n", .{r.output});
        return error.RetrySummaryMissing;
    }
}
