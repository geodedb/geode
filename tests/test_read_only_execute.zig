// Task 5 (hybrid-RAG audit spec, "authorization must be enforced below the
// LLM"): per-REQUEST hard read-only floor on ExecuteRequest, independent of
// the principal's role. This pins:
//
//   1. ExecuteRequest.read_only (field 6) round-trips through the SAME
//      protobuf encode/decode helpers the QUIC and gRPC transports use, and
//      defaults to false when absent from the wire (backward compatible with
//      pre-field-6 clients).
//   2. The exact classifier (query_traits.isMutatingProgram) the QUIC/gRPC
//      gates consult to decide "is this program a mutation" — the gate at
//      quic_connection_handler.zig and grpc_server.zig inherits whatever this
//      classifier says, including its documented fail-open scope for
//      SHOW/FOR-style statements.
//
// CANARY: REQ=REQ-EXEC-READ-ONLY-REQUEST-001; FEATURE="ReadOnlyExecute"; ASPECT=Test; STATUS=TESTED; TEST=tests/test_read_only_execute.zig; OWNER=engine; UPDATED=2026-08-28

const std = @import("std");
const testing = std.testing;
const protobuf = @import("protobuf");
const schema = @import("schema");
const geode = @import("geode");

const query_traits = geode.query_traits;
const Parser = geode.gql.parser.Parser;
const Lexer = geode.gql.lexer.Lexer;
const ast = geode.gql.ast;

fn encodeToBytes(allocator: std.mem.Allocator, msg: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, 4096) catch return error.OutOfMemory;
    errdefer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, msg);
    const result = try allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
    aw.deinit();
    return result;
}

test "ExecuteRequest read_only round-trips through protobuf encode/decode" {
    const allocator = testing.allocator;

    var params = std.ArrayList(schema.Param).empty;
    defer params.deinit(allocator);

    const req = schema.ExecuteRequest{
        .session_id = "session-ro-1",
        .query = "CREATE (n:X)",
        .params = params,
        .read_only = true,
    };

    const encoded = try encodeToBytes(allocator, req);
    defer allocator.free(encoded);

    var reader: std.Io.Reader = .fixed(encoded);
    var decoded = try protobuf.decode(schema.ExecuteRequest, &reader, allocator);
    defer decoded.deinit(allocator);

    try testing.expectEqualStrings("session-ro-1", decoded.session_id);
    try testing.expectEqualStrings("CREATE (n:X)", decoded.query);
    try testing.expect(decoded.read_only == true);
}

test "ExecuteRequest.read_only defaults to false when absent from the wire" {
    const allocator = testing.allocator;

    var params = std.ArrayList(schema.Param).empty;
    defer params.deinit(allocator);

    // A pre-field-6 client never sets read_only; field 6 stays absent from
    // the encoded wire frame entirely (proto3 default-value omission), and
    // the receiving decode must default to false — never crash, never trip
    // the gate.
    const req = schema.ExecuteRequest{
        .session_id = "session-legacy",
        .query = "RETURN 1",
        .params = params,
    };

    const encoded = try encodeToBytes(allocator, req);
    defer allocator.free(encoded);

    var reader: std.Io.Reader = .fixed(encoded);
    var decoded = try protobuf.decode(schema.ExecuteRequest, &reader, allocator);
    defer decoded.deinit(allocator);

    try testing.expect(decoded.read_only == false);
}

fn parseProgram(src: []const u8) !struct { ast.Program, std.heap.ArenaAllocator } {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    return .{ program, arena };
}

test "read-only classification refuses mutating programs" {
    // MERGE is a mutation — the read-only gate must refuse it.
    var mutating = try parseProgram("MERGE (n:X {k:1})");
    defer mutating[1].deinit();
    try testing.expect(query_traits.isMutatingProgram(&mutating[0]));

    // RETURN 1 is a pure read — the read-only gate must allow it.
    var reading = try parseProgram("RETURN 1");
    defer reading[1].deinit();
    try testing.expect(!query_traits.isMutatingProgram(&reading[0]));
}

// Finding 1 (whole-branch review, CRITICAL): `MATCH ... CALL <procedure>`
// and `CALL { ... } WITH ... RETURN ...` were not consulted by
// isQueryMutating, so a mutating procedure invoked through either shape
// bypassed the read-only floor. geode.ts.insert / geode.fts.rebuild are
// both classified .mutating by procedure_access.classifyCallProcedure
// (insert is a write-verb not on the read-only allowlist; rebuild drops
// and rebuilds the fulltext engine).
test "read-only classification refuses MATCH...CALL with a mutating procedure" {
    var mutating = try parseProgram("MATCH (n:Device) CALL geode.ts.insert(1, 'temp', 100, 42) YIELD inserted RETURN inserted");
    defer mutating[1].deinit();
    try testing.expect(query_traits.isMutatingProgram(&mutating[0]));
}

test "read-only classification refuses MATCH...CALL geode.fts.rebuild" {
    var mutating = try parseProgram("MATCH (n:Doc) CALL geode.fts.rebuild('idx') YIELD indexed RETURN indexed");
    defer mutating[1].deinit();
    try testing.expect(query_traits.isMutatingProgram(&mutating[0]));
}

test "read-only classification refuses CALL{}...SET inline subquery" {
    var mutating = try parseProgram("CALL { MATCH (n:X) SET n.k = 1 RETURN n } WITH n RETURN n");
    defer mutating[1].deinit();
    try testing.expect(query_traits.isMutatingProgram(&mutating[0]));
}

test "read-only classification still allows a read-only wrapped CALL procedure" {
    var reading = try parseProgram("MATCH (n:Doc) CALL geode.fts.search('idx', 'query') YIELD node, score RETURN node, score");
    defer reading[1].deinit();
    try testing.expect(!query_traits.isMutatingProgram(&reading[0]));
}
