// SONNY-6543: the GQLSTATUS codes Geode sends where ISO/IEC 39075:2024
// clause 23 (Table 8) defines the condition.
//
// - An invalid reference (a GROUP BY key, a HAVING or a WHERE after RETURN,
//   or knn()'s property naming nothing in scope) is "syntax error or access
//   rule violation - invalid reference", 42002. Geode sent 42703, the
//   PostgreSQL undefined_column code (a '7' subclass is implementation
//   defined in class 42, 23.1), although Table 8 defines 42002 and 23.2 GR 2
//   d) ties the INVALID_REFERENCE diagnostic to it. BREAKING for a client
//   that matched 42703.
// - A UNION whose parts have different column counts violates a Syntax
//   Rule; with no explicit condition for it, 4.7.3 step 4 e) raises "syntax
//   error or access rule violation" (42000), the code every other Syntax
//   Rule refusal of Geode sends. It sent the PostgreSQL 42601. BREAKING too.
// - The CDC_DIAGNOSTICS / CDC_CONTROL Admin refusal is 42501 on QUIC and
//   gRPC, as every other privilege refusal (fixed by SONNY-6561; pinned).
//
// The codes are read where both transports read them (`proto_util.mapError`
// and `execution.CdcRefusal`), and for statements the executor refuses; no
// mapping of the server's error table sends 42703 or 42601 any more.
//
// CANARY: REQ=REQ-SONNY-6543-ISO-STATUS-CODES; FEATURE="GQLStatus"; ASPECT=Table8InvalidReference; STATUS=TESTED; TEST=tests/test_sonny6543_iso_status_codes.zig; OWNER=server; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const vs = @import("value_semantics_harness.zig");

const mapError = geode.proto_util.mapError;

test "SONNY-6543: an invalid reference is 42002 (ISO/IEC 39075 Table 8), not 42703" {
    try testing.expectEqualStrings("42002", mapError(error.UnknownGroupKey).code);
    try testing.expectEqualStrings("42002", mapError(error.UnknownHavingReference).code);
    try testing.expectEqualStrings("42002", mapError(error.UnknownProperty).code);
}

test "SONNY-6543: a UNION column-count mismatch is the Syntax Rule refusal 42000, not 42601" {
    try testing.expectEqualStrings("42000", mapError(error.UnionColumnCountMismatch).code);
}

test "SONNY-6543: the CDC Admin refusal is 42501 like every other privilege refusal" {
    try testing.expectEqualStrings("42501", geode.execution.CdcRefusal.not_admin.sqlstate());
    try testing.expectEqualStrings("28000", geode.execution.CdcRefusal.unauthenticated.sqlstate());
}

test "SONNY-6543: no error the server maps is sent as 42703 or 42601" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = try std.Io.Dir.cwd().readFileAlloc(io, "src/server/proto_util.zig", testing.allocator, .limited(4 << 20));
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, ".code = \"42703\"") == null);
    try testing.expect(std.mem.indexOf(u8, text, ".code = \"42601\"") == null);
}

fn checkExecuted(s: *vs.Session, f: *vs.Failures) !void {
    try s.exec("CREATE (:St6543 {k: 1}), (:St6543 {k: 2})", &.{});
    const cases = [_]struct { q: []const u8, err: anyerror, code: []const u8 }{
        // A name nothing binds is refused first by the statement's scope
        // check (SONNY-6525), a Syntax Rule refusal: 42000.
        .{ .q = "MATCH (n:St6543) RETURN n.k AS k, count(*) AS c GROUP BY nosuch", .err = error.VariableNotInScope, .code = "42000" },
        .{ .q = "MATCH (n:St6543) RETURN n.k AS k UNION MATCH (n:St6543) RETURN n.k AS k, n.k AS j", .err = error.UnionColumnCountMismatch, .code = "42000" },
    };
    for (cases) |c| {
        if (s.run(c.q, &.{})) |ok| {
            var r = ok;
            r.deinit(s.arena.allocator());
            try f.add("[{s}] {s}: expected {s}, got rows", .{ @tagName(s.mode), c.q, @errorName(c.err) });
        } else |err| {
            if (err != c.err) {
                try f.add("[{s}] {s}: expected {s}, got {s}", .{ @tagName(s.mode), c.q, @errorName(c.err), @errorName(err) });
            } else if (!std.mem.eql(u8, mapError(err).code, c.code)) {
                try f.add("[{s}] {s}: {s} is sent as {s}, expected {s}", .{ @tagName(s.mode), c.q, @errorName(err), mapError(err).code, c.code });
            }
        }
    }
}

test "SONNY-6543: the executor's own refusals reach the wire with the ISO codes" {
    try vs.inModes("ISO status codes", &vs.eval_modes, checkExecuted);
}
