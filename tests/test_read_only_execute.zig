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

// Follow-up to Finding 1 above: isQueryMutating checks q.call_clause and
// q.initial_call_subquery but NOT q.next_query (ast.zig:114), the pointer
// the parser populates for chained-WITH shapes such as
// "MATCH ... WITH ... MATCH ... SET ..." (src/gql/parser.zig ~:2277-2338).
// A mutating clause attached to the TAIL query therefore left the whole
// statement classified non-mutating — the same read-only-floor bypass
// class as MATCH...CALL, just one level of chaining deeper.
//
// Structural precondition: prove the mutating SET clause actually lands on
// next_query (not on the head query's own set_clauses) before trusting the
// mutation assertion below.
test "structural precondition: chained-WITH SET lands on next_query, not head set_clauses" {
    var mutating = try parseProgram("MATCH (n:X) WITH n MATCH (m:Y) SET m.k = 1");
    defer mutating[1].deinit();

    const stmt = &mutating[0].statements[0];
    const head_query = switch (stmt.*) {
        .Query => |*q| q,
        else => return error.UnexpectedStatementKind,
    };

    // The head (pre-WITH) query carries no SET clause of its own.
    try testing.expectEqual(@as(usize, 0), head_query.set_clauses.len);
    // The mutating SET is on the tail query reachable only via next_query.
    try testing.expect(head_query.next_query != null);
    try testing.expect(head_query.next_query.?.set_clauses.len > 0);
}

test "read-only classification refuses chained-WITH tail SET (next_query mutation)" {
    var mutating = try parseProgram("MATCH (n:X) WITH n MATCH (m:Y) SET m.k = 1");
    defer mutating[1].deinit();
    try testing.expect(query_traits.isMutatingProgram(&mutating[0]));
}

test "read-only classification allows a chained-WITH read-only program" {
    var reading = try parseProgram("MATCH (n:X) WITH n MATCH (m:Y) RETURN m");
    defer reading[1].deinit();
    try testing.expect(!query_traits.isMutatingProgram(&reading[0]));
}

// Final-review fix wave (2026-08-29 series, item 3): `isMutatingStatement`'s
// `.Profile => |prof| isMutatingStatement(prof.query),` unwrap
// (query_traits.zig:327) had no dedicated regression — the closest existing
// coverage is the bare MATCH...CALL case above (no PROFILE wrapper) and
// PROFILE's own parse/execute tests elsewhere, but nothing pins that a
// mutating CALL wrapped in PROFILE still reaches isQueryMutating's
// q.call_clause check through that unwrap. `PROFILE` never executes its
// wrapped statement (see the `.Explain => false` sibling case just above the
// `.Profile` arm — PROFILE, unlike EXPLAIN, DOES execute, hence recursing
// into `prof.query` rather than always returning false), so this pins the
// classification is still correct: a PROFILE-wrapped MATCH...CALL of a
// mutating procedure (geode.ts.insert, same shape as the bare MATCH...CALL
// test above) must classify mutating, and a PROFILE-wrapped read-only CALL
// must not.
test "read-only classification refuses PROFILE-wrapped MATCH...CALL with a mutating procedure" {
    var mutating = try parseProgram("PROFILE MATCH (n:Device) CALL geode.ts.insert(1, 'temp', 100, 42) YIELD inserted RETURN inserted");
    defer mutating[1].deinit();

    // Structural precondition: PROFILE really does wrap a .Query statement
    // whose call_clause carries the mutating CALL — otherwise the assertion
    // below would pass for the wrong reason (e.g. a parse fallback that
    // dropped PROFILE entirely).
    const stmt = &mutating[0].statements[0];
    const prof = switch (stmt.*) {
        .Profile => |*p| p,
        else => return error.UnexpectedStatementKind,
    };
    const wrapped_query = switch (prof.query.*) {
        .Query => |*q| q,
        else => return error.UnexpectedStatementKind,
    };
    try testing.expect(wrapped_query.call_clause != null);

    try testing.expect(query_traits.isMutatingProgram(&mutating[0]));
}

test "read-only classification still allows a PROFILE-wrapped read-only CALL" {
    var reading = try parseProgram("PROFILE MATCH (n:Doc) CALL geode.fts.search('idx', 'query') YIELD node, score RETURN node, score");
    defer reading[1].deinit();
    try testing.expect(!query_traits.isMutatingProgram(&reading[0]));
}
