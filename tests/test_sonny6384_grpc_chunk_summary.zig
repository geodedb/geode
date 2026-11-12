// SONNY-6384 item 6 regression (found during SONNY-6377).
//
// `geode query --grpc --file` on a file that is chunked: when a chunk's
// connection fails after the chunk was sent (or the client times out on it),
// the run stops there and the chunk is not sent again (SONNY-6377), and it
// must still print the chunked-execution summary, as the QUIC path does.
// `executeGrpcQuery` exited the process itself on those failures, so the
// chunked driver never got to print it.
//
// The server, the CLI and the wire protocol are real; the relay from the
// SONNY-6377 test resets the client's connection once the Execute request has
// reached the server.
//
// CANARY: REQ=REQ-SONNY-6384-GRPC-CHUNK-SUMMARY; FEATURE="ChunkedExecution"; ASPECT=GrpcSummaryOnUnknownOutcome; STATUS=TESTED; TEST=tests/test_sonny6384_grpc_chunk_summary.zig; OWNER=cli; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const h = @import("test_sonny6377_query_no_resend.zig");

test "SONNY-6384 item 6: a gRPC chunk whose connection fails after it was sent stops the run and prints the chunked summary" {
    try h.skipWithoutBinary();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const dir = try h.freshDir(aa, "grpc-chunk-summary");
    defer h.removeDir(dir);
    const grpc_port = try util.getRandomPort();
    var s = try h.Server.start(testing.allocator, dir, grpc_port);
    defer s.stop(testing.allocator);

    const proxy = try h.ResetProxy.start(testing.allocator, grpc_port);
    defer proxy.stop();
    const proxy_addr = try std.fmt.allocPrint(aa, "127.0.0.1:{d}", .{proxy.port});

    // Two 32 KiB chunks.
    const first = try h.buildChunk(aa, "Sonny6384First");
    const second = try h.buildChunk(aa, "Sonny6384Second");
    const content = try std.mem.concat(aa, u8, &.{ first, second });
    const path = try std.fmt.allocPrint(aa, "{s}/chunks.gql", .{dir});
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = content });

    const r = try h.runGeode(aa, &.{ h.binary_path, "query", "--grpc", "--server", proxy_addr, "--insecure", "--no-saved-session", "--format", "json", "-U", h.admin_user, "-P", h.admin_pw, "--file", path }, 300_000);

    if (!h.contains(r.output, "using chunked execution")) {
        std.debug.print("fixture did not chunk:\n{s}\n", .{r.output});
        return error.FixtureDidNotChunk;
    }
    const executes = proxy.executes.load(.acquire);
    if (executes == 0) {
        std.debug.print("the chunk never reached the server through the relay:\n{s}\n", .{r.output});
        return error.FixtureNoExecute;
    }

    var violations: usize = 0;
    if (executes != 1) {
        std.debug.print("VIOLATION: the server received {d} Execute requests; expected 1 (the run stops at the failed chunk)\n", .{executes});
        violations += 1;
    }
    if (!h.contains(r.output, "may or may not have executed")) {
        std.debug.print("VIOLATION: the client did not say the chunk may have executed\n", .{});
        violations += 1;
    }
    if (!h.contains(r.output, "Chunked execution complete")) {
        std.debug.print("VIOLATION: no chunked-execution summary was printed\n", .{});
        violations += 1;
    }
    if (!h.contains(r.output, "were not executed")) {
        std.debug.print("VIOLATION: the run did not say the statements after the chunk were not executed\n", .{});
        violations += 1;
    }
    if (r.code != 1) {
        std.debug.print("VIOLATION: exited {d}; expected 1 (general_error)\n", .{r.code});
        violations += 1;
    }
    if (violations > 0) {
        std.debug.print("transcript:\n{s}\n", .{r.output});
        return error.ChunkSummaryMissing;
    }
}
