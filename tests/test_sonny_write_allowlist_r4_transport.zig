// Task W fix round 4a (SONNY-738) over the wire: the gRPC handler in process
// and the QUIC handler against a spawned `./zig-out/bin/geode serve` (the
// default server: plain persisted, the write fast paths on).
//
// - C1 (SONNY-3139, 3182, 3184): every PROFILE repro of the round-3 review is
//   refused (0A000) with nothing written: the QUIC and gRPC PROFILE arms ran
//   the statement through the planned runtime with no write-shape check. An
//   allowlisted PROFILE'd write still runs, once.
// - C3 (SONNY-3240): a MERGE's actions and a later chain read the statement's
//   own variables; go/oidc's ClaimJTI replay answers false, a verified TOTP
//   secret is never overwritten.
// - I2 (SONNY-3242): a SET swap swaps, with or without a RETURN.
// - I11 (SONNY-3247): a statement naming a parameter the request does not
//   supply is refused (42P02) before any path runs it, the QUIC MERGE fast
//   path too.
// - I8 (SONNY-3244): the parser's limits answer 54000 / 54001.
// - Round 4b-1 (SONNY-759): a comma pattern binds its node-only chain
//   (SONNY-3318); chained MERGE actions follow the last MERGE clause
//   (SONNY-3320); the node-scan stream serves only the fields it reads
//   (SONNY-3321: a LET, or a WHERE with a FILTER, goes to the executor);
//   SKIP / LIMIT parameters, a repeated SET target (22G03) and LET scope
//   (SONNY-3248).
// - Round 4b-1c (the round 4b-1b re-review): `WITH *` and FOR carry kinds
//   (42000); EXISTS and IN subqueries read the statement's LETs, and a LET
//   shadows a request parameter; a named path walks every type; a comma
//   join's FILTER and WITH stage (SONNY-3386); a node a chained part returns
//   is pulled from the gRPC server, in process and a real one (SONNY-3385);
//   the join's memory and time over gRPC and QUIC (SONNY-3368).
// - Round 4b-1b (the round 4b-1 review): a variable named as two kinds of
//   element is refused (42000; returning one aborted the gRPC server), the
//   streamed comma join and its read budget (53200), every type of an
//   alternation, a repeated SET target refused before anything is written
//   (the QUIC MERGE fast path too), window values (22G03), LET chains and
//   CALL bodies, and a label SET's vector check (22000, QUIC).
//
// CANARY: REQ=REQ-SONNY-3139-WRITE-SHAPES; FEATURE="WriteShapeValidator"; ASPECT=TransportProfile; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4_transport.zig; OWNER=engine; UPDATED=2026-09-28

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const grpc = @import("grpc_impl").impl;
const harness = @import("node_scan_stream_harness.zig");
const util = @import("proto_test_util.zig");

const graph_store = geode.graph_store;
const user_mgmt = geode.user_management;
const gps = geode.security.gps;

// ---------------------------------------------------------------------------
// The cases, one label family per case (`L` is replaced by `L<n>`).

/// A parameter: a string, or an integer when `int` is set.
const P = struct { name: []const u8, value: []const u8 = "", int: ?i64 = null };

fn makeParam(allocator: std.mem.Allocator, p: P) !schema.Param {
    if (p.int) |v| return util.makeIntParam(allocator, p.name, v);
    return util.makeStringParam(allocator, p.name, p.value);
}

const Step = struct {
    query: []const u8,
    params: []const P = &.{},
    /// The error code the step must answer; null: it must run.
    code: ?[]const u8 = null,
    /// The rows it must return, `a|b` per row, sorted, `;`-joined.
    want: ?[]const u8 = null,
};

const Case = struct {
    name: []const u8,
    steps: []const Step,
};

const seed = [_]Step{
    .{ .query = "CREATE (:L {i: 0, g: 'a'}), (:L {i: 1, g: 'a'}), (:L {i: 2, g: 'a'}), (:L {i: 3, g: 'a'}), (:L {i: 4, g: 'a'}), (:L {i: 5, g: 'b'}), (:L {i: 6, g: 'b'}), (:L {i: 7, g: 'b'}), (:L {i: 8, g: 'b'}), (:L {i: 9, g: 'b'})" },
    .{ .query = "CREATE (:LQ {i: 0, name: 'q'}), (:LQ {i: 1, name: 'q'}), (:LQ {i: 2, name: 'q'}), (:LQ {i: 3, name: 'q'})" },
    .{ .query = "MATCH (n:L) RETURN count(n) AS c", .want = "10" },
    .{ .query = "MATCH (q:LQ) RETURN count(q) AS c", .want = "4" },
};

const claim_jti = "MERGE (j:L {tenant_id: 't1', jti: 'j1'}) ON CREATE SET j.expires_at = '2099-01-01T00:00:00.000000000Z', j.first_use = true ON MATCH SET j.first_use = CASE WHEN j.expires_at > '2026-09-28T00:00:00.000000000Z' THEN false ELSE true END, j.expires_at = '2099-01-01T00:00:00.000000000Z' RETURN j.first_use";
const totp_enroll = "MERGE (t:L {tenant_id: 't1', user_id: 'u1', recovery_generation: 0}) ON CREATE SET t.totp_secret_enc = 'enc-1', t.verified = false, t.created_at = 'c1', t.verified_at = '' ON MATCH SET t.totp_secret_enc = CASE WHEN t.verified = true THEN t.totp_secret_enc ELSE 'enc-2' END, t.created_at = CASE WHEN t.verified = true THEN t.created_at ELSE 'c2' END, t.verified_at = CASE WHEN t.verified = true THEN t.verified_at ELSE '' END RETURN t.verified";

/// Nothing written on the case's own nodes (its labels begin `L<n>`).
const nothing_written = Step{ .query = "MATCH (n:L) WHERE n.x IS NOT NULL OR n.y IS NOT NULL OR n.c IS NOT NULL RETURN count(n) AS c", .want = "0" };
const nothing_written_q = Step{ .query = "MATCH (n:LQ) WHERE n.x IS NOT NULL OR n.c IS NOT NULL OR n.name <> 'q' RETURN count(n) AS c", .want = "0" };

const cases = [_]Case{
    // C1: the review's PROFILE repros.
    .{ .name = "C1 SELECT", .steps = &.{
        .{ .query = "PROFILE WITH 1 AS one SELECT 2 AS two MATCH (n:L) WHERE n.i = 5 SET n.x = 1", .code = "0A000" },
        nothing_written,
        nothing_written_q,
    } },
    .{ .name = "C1 IN subquery", .steps = &.{
        .{ .query = "PROFILE MATCH (n:L) WHERE n.i IN (MATCH (q:LQ) SET q.c = coalesce(q.c, 0) + 1 RETURN q.i) RETURN count(*) AS c", .code = "0A000" },
        nothing_written,
        nothing_written_q,
    } },
    .{ .name = "C1 unbound target", .steps = &.{
        .{ .query = "PROFILE MATCH (n:L) SET n.x = 1, nn.y = 2", .code = "0A000" },
        nothing_written,
        nothing_written_q,
    } },
    .{ .name = "C1 MRG3", .steps = &.{
        .{ .query = "PROFILE MATCH (a:L) WHERE a.i = 5 MERGE (a)-[r:T]->(b:LB {k: 1}) ON CREATE SET b.x = 1", .code = "0A000" },
        .{ .query = "MATCH (b:LB) RETURN count(b) AS c", .want = "0" },
        nothing_written,
        nothing_written_q,
    } },
    .{ .name = "C1 nested write", .steps = &.{
        .{ .query = "PROFILE MATCH (n:L) WHERE n.i IN (WITH (1 IN (MATCH (w:LQ) SET w.c = 1 RETURN 1)) AS b MATCH (m:L) RETURN m.i) RETURN count(*) AS c", .code = "0A000" },
        nothing_written,
        nothing_written_q,
    } },
    .{ .name = "C1 allowlisted PROFILE", .steps = &.{
        .{ .query = "PROFILE MATCH (n:L) WHERE n.i = 5 SET n.x = 1" },
        .{ .query = "MATCH (n:L) WHERE n.x = 1 RETURN n.i", .want = "5" },
    } },
    // C3.
    .{ .name = "C3 ON CREATE / ON MATCH", .steps = &.{
        .{ .query = "MERGE (z:LZ {k: 1}) ON CREATE SET z.n = 0 ON MATCH SET z.n = z.n + 1 RETURN z.n AS n", .want = "0" },
        .{ .query = "MERGE (z:LZ {k: 1}) ON CREATE SET z.n = 0 ON MATCH SET z.n = z.n + 1 RETURN z.n AS n", .want = "1" },
        .{ .query = "MERGE (z:LZ {k: 1}) ON CREATE SET z.n = 0 ON MATCH SET z.n = z.n + 1 RETURN z.n AS n", .want = "2" },
    } },
    .{ .name = "C3 trailing SET", .steps = &.{
        .{ .query = "MERGE (z:LZ {k: 1}) SET z.n = coalesce(z.n, -1) + 1" },
        .{ .query = "MERGE (z:LZ {k: 1}) SET z.n = coalesce(z.n, -1) + 1" },
        .{ .query = "MERGE (z:LZ {k: 1}) SET z.n = coalesce(z.n, -1) + 1" },
        .{ .query = "MATCH (z:LZ) RETURN z.n", .want = "2" },
    } },
    .{ .name = "C3 chains", .steps = &.{
        .{ .query = "CREATE (a:LZ {k: 1}), (b:LZ {k: a.k + 1})" },
        .{ .query = "MATCH (z:LZ) RETURN z.k", .want = "1;2" },
        .{ .query = "MERGE (a:LA {k: 1}) MERGE (b:LB {k: a.k + 1})" },
        .{ .query = "MATCH (b:LB) RETURN b.k", .want = "2" },
    } },
    .{ .name = "C3 ClaimJTI", .steps = &.{
        .{ .query = claim_jti, .want = "true" },
        .{ .query = claim_jti, .want = "false" },
        .{ .query = "MATCH (j:L) WHERE j.jti = 'j1' SET j.expires_at = '2000-01-01T00:00:00.000000000Z'" },
        .{ .query = claim_jti, .want = "true" },
        .{ .query = claim_jti, .want = "false" },
    } },
    .{ .name = "C3 TOTP", .steps = &.{
        .{ .query = totp_enroll, .want = "false" },
        .{ .query = "MATCH (t:L {tenant_id: 't1', user_id: 'u1', recovery_generation: 0, totp_secret_enc: 'enc-1'}) SET t.verified = true, t.verified_at = 'v1' RETURN t.user_id", .want = "u1" },
        .{ .query = totp_enroll, .want = "true" },
        .{ .query = "MATCH (t:L) WHERE t.user_id = 'u1' RETURN t.totp_secret_enc, t.created_at, t.verified_at", .want = "enc-1|c1|v1" },
    } },
    // I2.
    .{ .name = "I2 swap", .steps = &.{
        .{ .query = "MATCH (q:LQ {i: 1}) SET q.a = 5, q.b = 7" },
        .{ .query = "MATCH (q:LQ {i: 1}) SET q.a = q.b, q.b = q.a" },
        .{ .query = "MATCH (q:LQ {i: 1}) RETURN q.a, q.b", .want = "7|5" },
        .{ .query = "MATCH (q:LQ {i: 1}) SET q.a = q.b, q.b = q.a RETURN q.a AS a, q.b AS b", .want = "5|7" },
        .{ .query = "MATCH (q:LQ {i: 1}) SET q.a = 1, q.b = q.a RETURN q.a AS a, q.b AS b", .want = "1|5" },
        .{ .query = "MATCH (q:LQ {i: 1}) SET q.a = 2, q.b = q.a" },
        .{ .query = "MATCH (q:LQ {i: 1}) RETURN q.a, q.b", .want = "2|1" },
    } },
    // I11: the QUIC key-resolved MERGE fast path evaluated $nosuch as null.
    .{ .name = "I11", .steps = &.{
        .{ .query = "MERGE (m:LM {g: $nosuch})", .code = "42P02" },
        .{ .query = "MERGE (m:LM {g: $nosuch}) ON CREATE SET m.k = 1", .code = "42P02" },
        .{ .query = "MATCH (m:LM) RETURN count(m) AS c", .want = "0" },
        .{ .query = "MATCH (q:LQ {i: 1}) SET q.name = $nosuch", .code = "42P02" },
        .{ .query = "MATCH (q:LQ) SET q.x = 1 RETURN q.i AS i ORDER BY i LIMIT $nosuch", .code = "42P02" },
        .{ .query = "MATCH (q:LQ) WHERE q.i = $nosuch RETURN q.name", .code = "42P02" },
        .{ .query = "PROFILE MATCH (q:LQ) WHERE q.i = $nosuch RETURN q.name", .code = "42P02" },
        .{ .query = "MATCH (q:LQ) WHERE q.name = 'q' RETURN count(q) AS c", .want = "4" },
        nothing_written,
        .{ .query = "MERGE (m:LM {g: $g})", .params = &.{.{ .name = "g", .value = "a" }} },
        .{ .query = "MATCH (m:LM) RETURN m.g", .want = "a" },
    } },
    // UNWIND ... CREATE (a CREATE query the dispatcher runs once per element).
    .{
        .name = "UNWIND CREATE",
        .steps = &.{
            .{ .query = "WITH 1 AS one UNWIND [0, 1, 2, 3] AS i CREATE (:LU {i: i})" },
            .{ .query = "MATCH (u:LU) RETURN u.i", .want = "0;1;2;3" },
            .{ .query = "WITH 1 AS one UNWIND [4, 5] AS i CREATE (a:LU {i: i}), (b:LU {i: a.i + 10})" },
            .{ .query = "MATCH (u:LU) WHERE u.i >= 4 RETURN u.i", .want = "14;15;4;5" },
            // A statement cannot begin with UNWIND: a syntax error, nothing written.
            .{ .query = "UNWIND [0] AS i CREATE (:LV {i: i})", .code = "42000" },
            .{ .query = "MATCH (v:LV) RETURN count(v) AS c", .want = "0" },
        },
    },
    // Round 4b-1 (SONNY-759).
    // SONNY-3318: a node-only chain after a relationship chain is bound.
    .{ .name = "3318 comma chain", .steps = &.{
        .{ .query = "MATCH (a:L {i: 1}), (b:L {i: 2}) CREATE (a)-[:LR]->(b)" },
        .{ .query = "MATCH (a:L)-[:LR]->(b:L), (q:LQ {i: 2}) RETURN count(q) AS c, count(*) AS n", .want = "1|1" },
        .{ .query = "MATCH (a:L)-[:LR]->(b:L), (q:LQ {i: 2}) SET q.c = 1" },
        .{ .query = "MATCH (a:L)-[:LR]->(b:L), (q:LQ) WHERE q.i = 3 SET q.c = 3 RETURN q.i", .want = "3" },
        .{ .query = "MATCH (q:LQ) WHERE q.c IS NOT NULL RETURN q.i, q.c", .want = "2|1;3|3" },
        .{ .query = "MATCH (a:L {i: 1})-[:LR]->(b:L), (c:L)-[:LR]->(b) RETURN c.i", .want = "1" },
        .{ .query = "MATCH (a:L)-[:LR]->(b:L), (q:LQ {i: 0}) DETACH DELETE q" },
        .{ .query = "MATCH (q:LQ) RETURN count(q) AS c", .want = "3" },
    } },
    // SONNY-3320: chained MERGE actions follow the last MERGE clause.
    .{ .name = "3320 chained MERGE", .steps = &.{
        .{ .query = "CREATE (:LW {k: 1})" },
        .{ .query = "MERGE (v0:LW {k: 1}) MERGE (v1:LW {k: 2}) ON CREATE SET v0.ref = v1.k + v0.k ON MATCH SET v0.m = 1" },
        .{ .query = "MATCH (w:LW) RETURN w.k, w.ref, w.m", .want = "1|3|null;2|null|null" },
        .{ .query = "MERGE (v0:LW {k: 3}) MERGE (v1:LW {k: 2}) ON CREATE SET v0.ref = 9 ON MATCH SET v0.m = 1" },
        .{ .query = "MATCH (w:LW {k: 3}) RETURN w.ref, w.m", .want = "null|1" },
        .{ .query = claim_jti, .want = "true" },
        .{ .query = claim_jti, .want = "false" },
    } },
    // SONNY-3321: the stream path serves only what it reads; the rest runs
    // (or is refused) as the executor runs it.
    .{ .name = "3321 stream allowlist", .steps = &.{
        .{ .query = "LET $x = 1 IN (MATCH (w:LQ) SET w.c = coalesce(w.c, 0) + 1 RETURN 1) MATCH (n:L) RETURN count(*) AS c", .code = "0A000" },
        .{ .query = "LET $x = 1 IN (MATCH (w:LQ) SET w.c = coalesce(w.c, 0) + 1 RETURN 1) MATCH (n:L) WHERE $x RETURN n.i", .code = "0A000" },
        .{ .query = "LET $x = size([1 IN (MATCH (w:LQ) SET w.c = coalesce(w.c, 0) + 1 RETURN 1)]) MATCH (n:L) WHERE n.i = $x RETURN n.i", .code = "0A000" },
        nothing_written_q,
        .{ .query = "LET $x = 2 MATCH (n:L) WHERE n.i = $x RETURN n.i", .want = "2" },
        .{ .query = "LET $x = 3 MATCH (n:L) WHERE n.i > $x RETURN count(*) AS c", .want = "6" },
        .{ .query = "MATCH (n:L) WHERE n.i > 0 FILTER n.i < 3 RETURN n.i", .want = "1;2" },
        .{ .query = "MATCH (n:L) FILTER n.i < 3 RETURN n.i", .want = "0;1;2" },
    } },
    // SONNY-3248 M-1: SKIP / LIMIT parameters.
    .{ .name = "3248 window params", .steps = &.{
        .{ .query = "MATCH (n:L) WHERE n.i < 3 RETURN n.g LIMIT $l", .params = &.{.{ .name = "l", .int = 2 }}, .want = "a;a" },
        .{ .query = "MATCH (n:L) RETURN n.i AS i ORDER BY i LIMIT $l", .params = &.{.{ .name = "l", .int = 2 }}, .want = "0;1" },
        .{ .query = "MATCH (n:L) RETURN n.i AS i ORDER BY i SKIP $s LIMIT $l", .params = &.{ .{ .name = "s", .int = 8 }, .{ .name = "l", .int = 5 } }, .want = "8;9" },
        .{ .query = "MATCH (q:LQ) SET q.x = 1 RETURN q.i AS i ORDER BY i LIMIT $l", .params = &.{.{ .name = "l", .int = 2 }}, .want = "0;1" },
        .{ .query = "MATCH (q:LQ) WHERE q.x = 1 RETURN count(q) AS c", .want = "4" },
        .{ .query = "LET $x = 3 MATCH (n:L) RETURN n.i AS i ORDER BY i LIMIT $x", .want = "0;1;2" },
    } },
    // SONNY-3248 M-2 and M-3.
    .{
        .name = "3248 SET target, LET scope",
        .steps = &.{
            .{ .query = "MATCH (q:LQ {i: 1}) SET q.c = 1, q.c = 2", .code = "22G03" },
            .{ .query = "MATCH (a:LQ {i: 1}), (b:LQ {i: 1}) SET a.c = 1, b.c = 2 RETURN a.c", .code = "22G03" },
            .{ .query = "MATCH (q:LQ) WHERE q.i IN (LET $z = 1 MATCH (k:LQ) WHERE k.i = $z RETURN k.i) RETURN q.i, $z AS z", .code = "42P02" },
            nothing_written_q,
            .{ .query = "MATCH (q:LQ) WHERE q.i IN (LET $z = 1 MATCH (k:LQ) WHERE k.i = $z RETURN k.i) RETURN q.i", .want = "1" },
            // Round 4b-1b (review I-E): an IN subquery reads an outer LET, as
            // an EXISTS body does (it was refused, 42P02, and read null).
            .{ .query = "LET $y = 2 MATCH (q:LQ) WHERE q.i IN (MATCH (k:LQ) WHERE k.i = $y RETURN k.i) RETURN q.i", .want = "2" },
            .{ .query = "LET $y = 2 MATCH (q:LQ) WHERE q.i = $y RETURN q.i", .want = "2" },
            .{ .query = "MATCH (q:LQ {i: 1}) SET q.c = 1 SET q.c = q.c + 1 RETURN q.c", .want = "2" },
        },
    },
    // Round 4b-1b (the round 4b-1 review).
    // SONNY-3367 (C-1): a relationship variable reused as a node pattern
    // bound every node; over gRPC, returning it aborted the server.
    .{ .name = "3367 variable kind", .steps = &.{
        .{ .query = "MATCH (a:L {i: 1}), (b:L {i: 2}) CREATE (a)-[:LR]->(b)" },
        .{ .query = "MATCH (a:L {i: 1})-[r:LR]->(b), (r) RETURN r AS rr LIMIT 2", .code = "42000" },
        .{ .query = "MATCH (a:L {i: 1})-[r:LR]->(b), (r) SET r.x = 1", .code = "42000" },
        .{ .query = "MATCH (a:L {i: 1})-[r:LR]->(b), (r) DETACH DELETE r", .code = "42000" },
        .{ .query = "MATCH (a:L {i: 1})-[:LR]->(b), (c)-[a]->(d) RETURN count(*) AS c", .code = "42000" },
        .{ .query = "MATCH (n:L) RETURN count(n) AS c", .want = "10" },
        .{ .query = "MATCH (a:L)-[r:LR]->(b) RETURN count(r) AS c", .want = "1" },
        nothing_written,
        .{ .query = "RETURN 1 AS alive", .want = "1" },
    } },
    // SONNY-3368 (I-1): the streamed join, with a WHERE on the later chain.
    .{ .name = "3368 join", .steps = &.{
        .{ .query = "MATCH (a:L {i: 1}), (b:L {i: 2}), (c:L {i: 3}), (d:L {i: 4}) CREATE (a)-[:LR]->(b), (c)-[:LR]->(d)" },
        .{ .query = "MATCH (a:L)-[:LR]->(b), (c:L)-[:LR]->(d) WHERE c.i = 3 AND a.i = 1 RETURN a.i, c.i LIMIT 1", .want = "1|3" },
        .{ .query = "MATCH (a:L)-[:LR]->(b), (c:L)-[:LR]->(d) RETURN count(*) AS n", .want = "4" },
        .{ .query = "MATCH (a:L)-[:LR]->(b), (c:L)-[:LR]->(d) RETURN 1 AS one LIMIT 1", .want = "1" },
    } },
    // SONNY-3318 (I-5): every type of an alternation on the first hop.
    .{ .name = "3318 alternation", .steps = &.{
        .{ .query = "MATCH (a:L {i: 1}), (b:L {i: 2}), (c:L {i: 3}) CREATE (a)-[:XR]->(b), (b)-[:XS]->(c)" },
        .{ .query = "MATCH (a:L)-[:XS|XR]->(b), (q:LQ {i: 0}) RETURN count(*) AS n", .want = "2" },
        .{ .query = "MATCH (a:L)-[:XS|XR]->(b)-[:XS]->(c) RETURN a.i, c.i", .want = "1|3" },
        .{ .query = "MATCH (a:L)-[:XR|XS]->(b), (q:LQ {i: 0}) SET b.c = 1" },
        .{ .query = "MATCH (b:L) WHERE b.c = 1 RETURN b.i", .want = "2;3" },
    } },
    // SONNY-3248 (I-2, I-3): refused before anything is written, on the QUIC
    // MERGE fast path too (go/oidc's MERGE shape was last-wins there).
    .{ .name = "3248 repeated SET target", .steps = &.{
        .{ .query = "MERGE (t:LT1 {k: 1}) SET t.a = 1, t.a = 2", .code = "22G03" },
        .{ .query = "MERGE (t:LT2 {k: $k}) ON CREATE SET t.a = $v, t.a = 9", .params = &.{ .{ .name = "k", .int = 5 }, .{ .name = "v", .int = 7 } }, .code = "22G03" },
        .{ .query = "MERGE (t:LT2 {k: $k}) ON CREATE SET t.a = $v ON MATCH SET t.a = 9, t.a = 10", .params = &.{ .{ .name = "k", .int = 5 }, .{ .name = "v", .int = 7 } }, .code = "22G03" },
        .{ .query = "CREATE (z:LT3 {k: 1}) SET z.a = 1, z.a = 2", .code = "22G03" },
        .{ .query = "MATCH (q:LQ {i: 1}) CREATE (z:LT4) SET z.a = 1, z.a = 2", .code = "22G03" },
        .{ .query = "MATCH (t:LT1) RETURN count(t) AS c", .want = "0" },
        .{ .query = "MATCH (t:LT2) RETURN count(t) AS c", .want = "0" },
        .{ .query = "MATCH (t:LT3) RETURN count(t) AS c", .want = "0" },
        .{ .query = "MATCH (t:LT4) RETURN count(t) AS c", .want = "0" },
        .{ .query = "MERGE (t:LT2 {k: $k}) ON CREATE SET t.a = $v", .params = &.{ .{ .name = "k", .int = 5 }, .{ .name = "v", .int = 7 } } },
        .{ .query = "MATCH (t:LT2) RETURN t.k, t.a", .want = "5|7" },
    } },
    // SONNY-3248 (m-2): a SKIP or LIMIT value that is no non-negative integer.
    .{ .name = "3248 window values", .steps = &.{
        .{ .query = "MATCH (n:L) RETURN n.i LIMIT $l", .params = &.{.{ .name = "l", .int = -1 }}, .code = "22G03" },
        .{ .query = "MATCH (n:L) RETURN n.i LIMIT $l", .params = &.{.{ .name = "l", .value = "2" }}, .code = "22G03" },
        .{ .query = "MATCH (n:L) RETURN n.i SKIP $s", .params = &.{.{ .name = "s", .int = -2 }}, .code = "22G03" },
        .{ .query = "MATCH (n:L) WHERE n.i < 3 RETURN n.i LIMIT $l", .params = &.{.{ .name = "l", .int = 0 }}, .want = "" },
    } },
    // SONNY-3248 (I-6): LET chains and a CALL { } body read the LETs before them.
    .{ .name = "3248 LET chain", .steps = &.{
        .{ .query = "LET $a = 2, $b = $a + 1 MATCH (n:L) WHERE n.i = $b RETURN n.i", .want = "3" },
        .{ .query = "LET $x = 2 CALL { MATCH (n:L) WHERE n.i = $x RETURN n.i AS k } RETURN k", .want = "2" },
        .{ .query = "LET $a = $b, $b = 1 MATCH (n:L) WHERE n.i = $a RETURN n.i", .code = "42P02" },
    } },
    // Round 4b-1c (the round 4b-1b re-review).
    // SONNY-3367 (I-A): `WITH *` carries each variable's kind; a value is no
    // element (returning `(r)` after `WITH *` read a node as a relationship).
    .{ .name = "3367 WITH * kinds", .steps = &.{
        .{ .query = "MATCH (a:L {i: 1}), (b:L {i: 2}) CREATE (a)-[:LR {w: 'w'}]->(b)" },
        .{ .query = "MATCH (a:L {i: 1})-[r:LR]->(b) WITH * MATCH (r) RETURN count(*) AS c", .code = "42000" },
        .{ .query = "MATCH (a:L {i: 1})-[r:LR]->(b) WITH * MATCH (r) RETURN r AS rr LIMIT 2", .code = "42000" },
        .{ .query = "MATCH (a:L {i: 1})-[r:LR]->(b) WITH * MATCH (x)-[a]->(y) RETURN count(*) AS c", .code = "42000" },
        .{ .query = "MATCH (a:L {i: 1})-[r:LR]->(b) WITH r.w AS r MATCH (r) RETURN count(*) AS c", .code = "42000" },
        .{ .query = "FOR r IN [1, 2] MATCH (r) RETURN count(*) AS c", .code = "42000" },
        .{ .query = "MATCH (a:L {i: 1})-[r:LR]->(b) WITH * MATCH (r) SET r.x = 1", .code = "42000" },
        .{ .query = "MATCH (n:L) RETURN count(n) AS c", .want = "10" },
        nothing_written,
        .{ .query = "RETURN 1 AS alive", .want = "1" },
    } },
    // SONNY-3248 (I-E): an EXISTS body's WHERE (it read freed names, so it
    // never matched) and an IN subquery read the statement's LETs; a LET
    // shadows a request parameter on every path.
    .{
        .name = "3248 subquery LET, shadowing",
        .steps = &.{
            .{ .query = "MATCH (a:L {i: 1}), (b:L {i: 2}) CREATE (a)-[:LR]->(b)" },
            .{ .query = "MATCH (n:L) WHERE EXISTS { MATCH (k:L) WHERE k.i = 2 } RETURN count(*) AS c", .want = "10" },
            .{ .query = "MATCH (n:L) WHERE EXISTS { MATCH (k:L) WHERE k.i = 99 } RETURN count(*) AS c", .want = "0" },
            .{ .query = "LET $x = 2 MATCH (n:L) WHERE EXISTS { MATCH (k:L) WHERE k.i = $x } RETURN count(*) AS c", .want = "10" },
            .{ .query = "MATCH (n:L) WHERE EXISTS { (n)-[:LR]->(k:L) WHERE k.i = 2 } RETURN n.i", .want = "1" },
            .{ .query = "LET $x = 2 MATCH (n:L) WHERE EXISTS { (n)-[:LR]->(k:L) WHERE k.i = $x } RETURN n.i", .want = "1" },
            .{ .query = "LET $x = 3 MATCH (n:L) WHERE EXISTS { (n)-[:LR]->(k:L) WHERE k.i = $x } RETURN n.i", .want = "" },
            .{ .query = "LET $x = 2 MATCH (n:L) WHERE n.i IN (MATCH (k:L) WHERE k.i = $x RETURN k.i) RETURN n.i", .want = "2" },
            .{ .query = "LET $a = 5 MATCH (n:L) WHERE n.i = $a RETURN n.i", .params = &.{.{ .name = "a", .int = 1 }}, .want = "5" },
            .{ .query = "LET $a = 3 MATCH (n:L) RETURN n.i AS i ORDER BY i LIMIT $a", .params = &.{.{ .name = "a", .int = 1 }}, .want = "0;1;2" },
            .{ .query = "LET $a = 3 MATCH (n:L) WITH n LIMIT $a RETURN count(*) AS c", .params = &.{.{ .name = "a", .int = 1 }}, .want = "3" },
            .{ .query = "LET $a = 3 MATCH (n:L) WHERE EXISTS { MATCH (k:L) WHERE k.i = $a } RETURN count(*) AS c", .params = &.{.{ .name = "a", .int = 99 }}, .want = "10" },
            // m-b: a LET's window value is checked on every path.
            .{ .query = "LET $w = -2 MATCH (n:L) WITH n LIMIT $w RETURN n.i", .code = "22G03" },
            .{ .query = "LET $w = 'x' MATCH (n:L) WITH n SKIP $w RETURN n.i", .code = "22G03" },
            // m-a: a CALL { } body's window.
            .{ .query = "CALL { MATCH (n:L) RETURN n.i AS k ORDER BY k LIMIT $l } RETURN k", .params = &.{.{ .name = "l", .int = 2 }}, .want = "0;1" },
            .{ .query = "CALL { MATCH (n:L) RETURN n.i AS k ORDER BY k SKIP $l LIMIT 1 } RETURN k", .params = &.{.{ .name = "l", .int = 2 }}, .want = "2" },
            // m-c: two MERGEs of one node, one property set through both.
            .{ .query = "MERGE (a:LW {k: 1}) MERGE (b:LW {k: 1}) SET a.x = 1, b.x = 2", .code = "22G03" },
            .{ .query = "MATCH (n:LW) RETURN count(n) AS c", .want = "0" },
        },
    },
    // SONNY-3318 (I-D): a named path walks every type; the multi-chain
    // executor binds it; a shortest path keeps to the hop's types.
    .{ .name = "3318 named path", .steps = &.{
        .{ .query = "MATCH (a:L {i: 1}), (b:L {i: 2}), (c:L {i: 3}) CREATE (a)-[:XR]->(b), (b)-[:XS]->(c)" },
        .{ .query = "MATCH p = (a:L)-[:XS|XR]->(b) RETURN count(*) AS n", .want = "2" },
        .{ .query = "MATCH p = (a:L)-[:XR|XS]->(b) RETURN count(*) AS n", .want = "2" },
        .{ .query = "MATCH p = (a:L)-[:XR]->(b)-[:XS]->(c) RETURN length(p) AS l", .want = "2" },
        .{ .query = "MATCH p = (a:L {i: 1})-[:XS|XR*1..2]->(c) RETURN length(p) AS l", .want = "1;2" },
        .{ .query = "MATCH p = shortestPath((a:L {i: 1})-[:XS|XR*]->(c:L {i: 3})) RETURN length(p) AS l", .want = "2" },
        .{ .query = "MATCH (a:L {i: 1}) OPTIONAL MATCH p = (a)-[:XR]->(x) RETURN count(p) AS c", .code = "0A000" },
    } },
    // SONNY-3386: a comma join's FILTER, and the WITH after it.
    .{ .name = "3386 comma FILTER, WITH", .steps = &.{
        .{ .query = "MATCH (a:L {i: 1}), (b:L {i: 2}), (c:L {i: 3}), (d:L {i: 4}) CREATE (a)-[:LR]->(b), (c)-[:LR]->(d)" },
        .{ .query = "MATCH (a:L)-[:LR]->(b), (q:LQ) FILTER q.i = 3 AND a.i = 3 RETURN a.i", .want = "3" },
        .{ .query = "MATCH (a:L)-[:LR]->(b), (q:LQ) FILTER q.i = 3 RETURN count(*) AS c", .want = "2" },
        .{ .query = "MATCH (a:L)-[:LR]->(b), (q:LQ) WITH a.i AS ai, q.i AS qi ORDER BY ai DESC, qi DESC LIMIT 1 RETURN ai, qi", .want = "3|3" },
        .{ .query = "MATCH (a:L)-[:LR]->(b), (q:LQ) WITH a, q SKIP 7 RETURN count(*) AS c", .want = "1" },
    } },
    // SONNY-3385: a node or relationship a chained part returns is pulled
    // page by page after the request that made it; its labels were in the
    // request's scratch arena, and the Pull aborted the gRPC server.
    .{ .name = "3385 element after WITH", .steps = &.{
        .{ .query = "MATCH (a:L {i: 1}), (b:L {i: 2}) CREATE (a)-[:LR]->(b)" },
        .{ .query = "MATCH (g:L {i: 1}) WITH g MATCH (n:LQ) RETURN n AS nn", .want = "?;?;?;?" },
        .{ .query = "MATCH (g:L {i: 1}) WITH * MATCH (n:LQ) RETURN n AS nn LIMIT 2", .want = "?;?" },
        .{ .query = "MATCH (g:L {i: 1}) WITH g MATCH (a:L)-[e:LR]->(b) RETURN e AS ee, b AS bb", .want = "?|?" },
        .{ .query = "MATCH (g:L {i: 1}) WITH g MATCH p = (a:L)-[:LR]->(b) RETURN p AS pp", .want = "?" },
        .{ .query = "RETURN 1 AS alive", .want = "1" },
    } },
    // I8.
    .{ .name = "I8 nesting", .steps = &.{
        .{ .query = "WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a RETURN a", .code = "54001" },
        .{ .query = "WITH 1 AS a WITH 1 AS a WITH 1 AS a RETURN a", .want = "1" },
    } },
};

/// Cases run over QUIC only. SONNY-3319's creates a vector index, and the
/// in-process gRPC fixture's index manager lives in the fixture's request
/// arena, which the fixture frees before the catalog it registers into (a
/// harness limit: the catalog cleanup then reads freed memory).
const quic_only_cases = [_]Case{
    // SONNY-3319 (I-4): a label SET checks the vectors the node holds.
    .{ .name = "3319 label SET vectors", .steps = &.{
        .{ .query = "CREATE INDEX vk4b_idx ON VK4b (emb) USING HNSW WITH (metric = 'l2')" },
        .{ .query = "CREATE (:VK4b {id: 1, emb: vectorf32('[1.0, 0.0, 0.0, 0.0]')})" },
        .{ .query = "CREATE (:VO4b {id: 5, emb: vectorf32('[8.0, 8.0]')})" },
        .{ .query = "MATCH (n:VO4b) SET n:VK4b", .code = "22000" },
        .{ .query = "CREATE (n:VP4b {id: 3, emb: vectorf32('[9.0, 9.0]')}) SET n:VK4b", .code = "22000" },
        .{ .query = "MATCH (n:VK4b) RETURN n.id", .want = "1" },
        .{ .query = "MATCH (n:VP4b) RETURN count(n) AS c", .want = "0" },
    } },
};

fn labeled(aa: std.mem.Allocator, text: []const u8, n: usize) ![]const u8 {
    // `:L` and `(L` begin every label of the cases: `:L` -> `:L<n>`.
    const tag = try std.fmt.allocPrint(aa, ":L{d}", .{n});
    return std.mem.replaceOwned(u8, aa, text, ":L", tag);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn joinSorted(aa: std.mem.Allocator, rows: [][]const u8) ![]const u8 {
    std.mem.sort([]const u8, rows, {}, lessThan);
    return std.mem.join(aa, ";", rows);
}

/// What a transport answered to one step.
const Answer = struct { code: ?[]const u8, rows: []const u8 };

fn check(aa: std.mem.Allocator, failures: *std.ArrayList([]const u8), transport: []const u8, case: []const u8, step: Step, query: []const u8, got: Answer) !void {
    if (step.code) |code| {
        const c = got.code orelse {
            try failures.append(aa, try std.fmt.allocPrint(aa, "[{s}] {s}: {s}: ran ({s}); expected {s}", .{ transport, case, query, got.rows, code }));
            return;
        };
        if (!std.mem.eql(u8, c, code)) try failures.append(aa, try std.fmt.allocPrint(aa, "[{s}] {s}: {s}: answered {s}; expected {s}", .{ transport, case, query, c, code }));
        return;
    }
    if (got.code) |c| {
        try failures.append(aa, try std.fmt.allocPrint(aa, "[{s}] {s}: {s}: error {s}", .{ transport, case, query, c }));
        return;
    }
    if (step.want) |want| {
        if (!std.mem.eql(u8, got.rows, want)) try failures.append(aa, try std.fmt.allocPrint(aa, "[{s}] {s}: {s}: returned {{{s}}}, expected {{{s}}}", .{ transport, case, query, got.rows, want }));
    }
}

fn finish(failures: []const []const u8, title: []const u8) !void {
    if (failures.len == 0) return;
    std.debug.print("\n{s}: {d} failed check(s):\n", .{ title, failures.len });
    for (failures) |msg| std.debug.print("  {s}\n", .{msg});
    return error.WrongAnswer;
}

// ---------------------------------------------------------------------------
// gRPC, in process.

fn encodeProto(allocator: std.mem.Allocator, msg: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, msg);
    return allocator.dupe(u8, aw.written());
}

fn decodeProto(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !T {
    var reader: std.Io.Reader = .fixed(bytes);
    return protobuf.decode(T, &reader, allocator);
}

const Fixture = struct {
    h: harness.Harness,
    arena: std.heap.ArenaAllocator,
    sessions: grpc.SessionStore,
    auth_was_enabled: bool,
    allow_all_was: bool,

    fn init(self: *Fixture) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        errdefer self.h.deinit();
        _ = graph_store.getGlobalStore(testing.allocator);
        _ = geode.txn_undo_log.getGlobalUndoLog(testing.allocator);
        self.auth_was_enabled = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(false);
        self.allow_all_was = gps.isInsecureAllowAll();
        gps.setInsecureAllowAll(true);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.sessions = grpc.SessionStore.init(self.arena.allocator(), .{});
        grpc.setSessionStore(&self.sessions);
    }

    fn deinit(self: *Fixture) void {
        grpc.setSessionStore(null);
        self.sessions.deinit();
        self.arena.deinit();
        gps.setInsecureAllowAll(self.allow_all_was);
        user_mgmt.setAuthEnabled(self.auth_was_enabled);
        self.h.deinit();
    }

    /// Run `query` over gRPC and pull every row it answers.
    fn run(self: *Fixture, session_id: []const u8, query: []const u8, params: []const P) !Answer {
        const ga = self.arena.allocator();
        var ps = util.emptyParams();
        for (params) |p| try ps.append(ga, try makeParam(ga, p));
        const req = try encodeProto(ga, schema.ExecuteRequest{ .session_id = session_id, .query = query, .params = ps });
        const resp = try decodeProto(schema.ExecutionResponse, ga, try grpc.handleExecute(req, ga, null));
        var rows: std.ArrayList([]const u8) = .empty;
        var page: schema.DataPage = switch (resp.payload orelse return error.MissingPayload) {
            .@"error" => |e| return .{ .code = try ga.dupe(u8, e.code), .rows = "" },
            .page => |pg| pg,
            // The rows follow, page by page.
            .schema => .{ .rows = .empty, .final = false, .order_keys = .empty },
            // A PROFILE or EXPLAIN answers its plan, and no rows.
            else => return .{ .code = null, .rows = "" },
        };
        var pulls: usize = 0;
        while (true) : (pulls += 1) {
            for (page.rows.items) |row| {
                var line: std.ArrayList(u8) = .empty;
                for (row.values.items, 0..) |cell, j| {
                    if (j > 0) try line.append(ga, '|');
                    const kind = cell.kind orelse {
                        try line.appendSlice(ga, "null");
                        continue;
                    };
                    switch (kind) {
                        .int_val => |v| try line.print(ga, "{d}", .{v.value}),
                        .string_val => |v| try line.appendSlice(ga, v.value),
                        .bool_val => |v| try line.appendSlice(ga, if (v) "true" else "false"),
                        .null_val => try line.appendSlice(ga, "null"),
                        else => try line.appendSlice(ga, "?"),
                    }
                }
                try rows.append(ga, try line.toOwnedSlice(ga));
            }
            if (page.final or pulls > 16) break;
            const pull_req = try encodeProto(ga, schema.PullRequest{ .session_id = session_id, .page_size = 64 });
            const pull = try decodeProto(schema.PullResponse, ga, try grpc.handlePull(pull_req, ga));
            const page_resp = pull.response orelse break;
            page = switch (page_resp.payload orelse break) {
                .page => |pg| pg,
                .@"error" => |e| return .{ .code = try ga.dupe(u8, e.code), .rows = "" },
                else => break,
            };
        }
        return .{ .code = null, .rows = try joinSorted(ga, rows.items) };
    }
};

test "round 4a over gRPC: PROFILE repros refused, C3, I2, I11 and I8" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const aa = f.h.arena.allocator();
    var failures: std.ArrayList([]const u8) = .empty;
    const s = try f.sessions.createSession("writer", "", null, null, null, false, 0);
    for (cases, 0..) |c, n| {
        for (seed) |st| {
            const query = try labeled(aa, st.query, n);
            try check(aa, &failures, "grpc", c.name, st, query, try f.run(s, query, &.{}));
        }
        for (c.steps) |st| {
            const query = try labeled(aa, st.query, n);
            try check(aa, &failures, "grpc", c.name, st, query, try f.run(s, query, st.params));
        }
    }
    try finish(failures.items, "round 4a (gRPC)");
}

// CANARY: REQ=REQ-SONNY-3368-BOUNDED-JOIN; FEATURE="MultiChainRelationshipMatch"; ASPECT=ReadBudgetOverGrpc; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4_transport.zig; OWNER=engine; UPDATED=2026-09-28
test "round 4b-1b over gRPC: LIMIT 1 over two 1,500-pair chains answers under a 64 MiB read budget; the whole product answers 53200 (SONNY-3368)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const aa = f.h.arena.allocator();
    var failures: std.ArrayList([]const u8) = .empty;
    const s = try f.sessions.createSession("writer", "", null, null, null, false, 0);
    const name = "3368 read budget";
    try check(aa, &failures, "grpc", name, .{ .query = "" }, "seed", try f.run(s, "FOR i IN range(1, 1500) CREATE (:JP {i: i})-[:JE]->(:JP2 {i: i})", &.{}));
    geode.read_budget.setBudgetBytesForTest(64 << 20);
    defer geode.read_budget.setBudgetBytesForTest(0);
    const cart = "MATCH (a:JP)-[:JE]->(b), (c:JP)-[:JE]->(d)";
    try check(aa, &failures, "grpc", name, .{ .query = "", .want = "1" }, "LIMIT 1", try f.run(s, cart ++ " RETURN 1 AS one LIMIT 1", &.{}));
    try check(aa, &failures, "grpc", name, .{ .query = "", .code = "53200" }, "the whole product", try f.run(s, cart ++ " RETURN a.i, c.i", &.{}));
    try check(aa, &failures, "grpc", name, .{ .query = "", .want = "1" }, "alive", try f.run(s, "RETURN 1 AS one", &.{}));
    try finish(failures.items, "round 4b-1b read budget (gRPC)");
}

// ---------------------------------------------------------------------------
// Round 4b-1c: the join's memory and time over the wire (SONNY-3368, the
// round 4b-1b re-review I-B / I-C). A WHERE that keeps none of the 2.25
// million bindings of two 1,500-pair chains held about 700 MB (a node copy
// per binding, `getNodePtrForScan`), unseen by the read budget.

/// A /proc status field (`VmRSS`, `VmHWM`) of process `pid` (0: this one),
/// in bytes; 0 when unreadable.
fn procStatusBytes(pid: std.posix.pid_t, field: []const u8) usize {
    var path_buf: [64]u8 = undefined;
    const path = (if (pid == 0) std.fmt.bufPrintZ(&path_buf, "/proc/self/status", .{}) else std.fmt.bufPrintZ(&path_buf, "/proc/{d}/status", .{pid})) catch return 0;
    var buf: [8192]u8 = undefined;
    const fd = std.c.open(path, .{});
    if (fd < 0) return 0;
    defer _ = std.c.close(fd);
    const got = std.c.read(fd, &buf, buf.len);
    if (got <= 0) return 0;
    const n: usize = @intCast(got);
    var lines = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, field)) continue;
        var parts = std.mem.tokenizeAny(u8, line[field.len..], " \t:kB");
        const kb = std.fmt.parseInt(usize, parts.next() orelse return 0, 10) catch return 0;
        return kb * 1024;
    }
    return 0;
}

/// Reset process `pid`'s peak resident set (`clear_refs` 5, Linux 4.0+).
fn resetPeak(pid: std.posix.pid_t) void {
    var path_buf: [64]u8 = undefined;
    const path = (if (pid == 0) std.fmt.bufPrintZ(&path_buf, "/proc/self/clear_refs", .{}) else std.fmt.bufPrintZ(&path_buf, "/proc/{d}/clear_refs", .{pid})) catch return;
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY });
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    _ = std.c.write(fd, "5", 1);
}

/// Process `pid`'s CPU time so far (user + system), in clock ticks.
fn procCpuTicks(pid: std.posix.pid_t) u64 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/stat", .{pid}) catch return 0;
    var buf: [1024]u8 = undefined;
    const fd = std.c.open(path, .{});
    if (fd < 0) return 0;
    defer _ = std.c.close(fd);
    const got = std.c.read(fd, &buf, buf.len);
    if (got <= 0) return 0;
    const text = buf[0..@intCast(got)];
    // After the command's closing parenthesis: state is field 3, utime 14,
    // stime 15.
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return 0;
    var fields = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
    var i: usize = 3;
    var total: u64 = 0;
    while (fields.next()) |f| : (i += 1) {
        if (i == 14 or i == 15) total += std.fmt.parseInt(u64, f, 10) catch 0;
        if (i == 15) break;
    }
    return total;
}

fn nowMillis() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

fn sleepMillis(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

const join_cart = "MATCH (a:JP)-[:JE]->(b), (c:JP)-[:JE]->(d)";
const join_seed = "FOR i IN range(1, 1500) CREATE (:JP {i: i})-[:JE]->(:JP2 {i: i})";
/// What a WHERE that keeps nothing may add to the peak resident set.
const join_peak_growth_max: usize = 128 << 20;

const GrpcBoundJob = struct {
    f: *Fixture,
    session: []const u8,
    ok: bool = true,

    fn fail(self: *GrpcBoundJob, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("  [grpc] " ++ fmt ++ "\n", args);
        self.ok = false;
    }

    fn run(self: *GrpcBoundJob) void {
        geode.read_budget.setBudgetBytesForTest(64 << 20);
        defer geode.read_budget.setBudgetBytesForTest(0);
        resetPeak(0);
        const before = procStatusBytes(0, "VmRSS");
        const start = nowMillis();
        const got = self.f.run(self.session, join_cart ++ " WHERE 1 = 2 RETURN a.i", &.{}) catch |err| return self.fail("WHERE 1 = 2: {s}", .{@errorName(err)});
        const took = nowMillis() - start;
        const grew = procStatusBytes(0, "VmHWM") -| before;
        if (got.code) |c| self.fail("WHERE 1 = 2: answered {s}", .{c});
        if (got.rows.len != 0) self.fail("WHERE 1 = 2: returned {s}", .{got.rows});
        if (grew > join_peak_growth_max) self.fail("WHERE 1 = 2: the peak grew {d} MiB", .{grew >> 20});
        if (took > 240_000) self.fail("WHERE 1 = 2: took {d} ms", .{took});
        const s2 = nowMillis();
        const one = self.f.run(self.session, join_cart ++ " RETURN 1 AS one LIMIT 1", &.{}) catch |err| return self.fail("LIMIT 1: {s}", .{@errorName(err)});
        if (one.code != null or !std.mem.eql(u8, one.rows, "1")) self.fail("LIMIT 1: {s}", .{one.rows});
        if (nowMillis() - s2 > 10_000) self.fail("LIMIT 1: took {d} ms", .{nowMillis() - s2});
    }
};

// CANARY: REQ=REQ-SONNY-3368-BOUNDED-JOIN; FEATURE="MultiChainRelationshipMatch"; ASPECT=MemoryOverGrpc; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4_transport.zig; OWNER=engine; UPDATED=2026-09-29
test "round 4b-1c over gRPC: a WHERE that keeps nothing over two 1,500-pair chains holds flat memory; LIMIT 1 answers at once (SONNY-3368)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const s = try f.sessions.createSession("writer", "", null, null, null, false, 0);
    const seeded = try f.run(s, join_seed, &.{});
    try testing.expect(seeded.code == null);
    var job: GrpcBoundJob = .{ .f = &f, .session = s };
    const pid = std.c.fork();
    try testing.expect(pid >= 0);
    if (pid == 0) {
        std.posix.setrlimit(.CORE, .{ .cur = 0, .max = 0 }) catch {};
        _ = std.c.alarm(300);
        job.run();
        std.c._exit(if (job.ok) 0 else 1);
    }
    var status: c_int = 0;
    try testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
    const st: u32 = @bitCast(status);
    if (std.os.linux.W.IFSIGNALED(st)) {
        std.debug.print("the gRPC join was killed (signal {d})\n", .{std.os.linux.W.TERMSIG(st)});
        return error.Crashed;
    }
    try testing.expectEqual(@as(u32, 0), std.os.linux.W.EXITSTATUS(st));
}

// CANARY: REQ=REQ-SONNY-3368-BOUNDED-JOIN; FEATURE="MultiChainRelationshipMatch"; ASPECT=MemoryOverQuic; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4_transport.zig; OWNER=engine; UPDATED=2026-09-29
test "round 4b-1c over QUIC: flat server memory for a WHERE that keeps nothing, 53200 for the product, and a disconnect stops a join that completes nothing (SONNY-3368)" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-wfix4c-{d}", .{port});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);
    var server = try util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir }, &.{"GEODE_READ_EXECUTOR_BUDGET_MB=64"});
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 30000);
    const server_pid: std.posix.pid_t = server.child.id orelse return error.NoServerPid;

    var failures: std.ArrayList([]const u8) = .empty;
    {
        var client = try util.QuicProtoClient.connect(allocator, addr);
        defer client.deinit();
        var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
        hello.deinit(allocator);
        const name = "3368 memory (QUIC)";
        var seeded = try client.executeAndCollectWithTimeout(allocator, join_seed, util.emptyParams(), 1000, 120);
        const seed_err = seeded.error_code;
        seeded.deinit(allocator);
        if (seed_err != null) return error.SeedFailed;
        var seeded_k = try client.executeAndCollectWithTimeout(allocator, "FOR i IN range(1, 400) CREATE (:KP {i: i})-[:KE]->(:KP2 {i: i})", util.emptyParams(), 1000, 60);
        const seed_k_err = seeded_k.error_code != null;
        seeded_k.deinit(allocator);
        if (seed_k_err) return error.SeedFailed;

        resetPeak(server_pid);
        const before = procStatusBytes(server_pid, "VmRSS");
        const start = nowMillis();
        var none = try client.executeAndCollectWithTimeout(allocator, join_cart ++ " WHERE 1 = 2 RETURN a.i", util.emptyParams(), 1000, 300);
        const took = nowMillis() - start;
        const grew = procStatusBytes(server_pid, "VmHWM") -| before;
        if (none.error_code) |c| try failures.append(aa, try std.fmt.allocPrint(aa, "{s}: WHERE 1 = 2 answered {s}", .{ name, c }));
        if (none.rows.len != 0) try failures.append(aa, try std.fmt.allocPrint(aa, "{s}: WHERE 1 = 2 returned {d} rows", .{ name, none.rows.len }));
        none.deinit(allocator);
        if (before == 0) try failures.append(aa, try std.fmt.allocPrint(aa, "{s}: the server's /proc status is unreadable", .{name}));
        if (grew > join_peak_growth_max) try failures.append(aa, try std.fmt.allocPrint(aa, "{s}: the server's peak grew {d} MiB (at most {d})", .{ name, grew >> 20, join_peak_growth_max >> 20 }));
        if (took > 240_000) try failures.append(aa, try std.fmt.allocPrint(aa, "{s}: WHERE 1 = 2 took {d} ms", .{ name, took }));

        const s2 = nowMillis();
        try check(aa, &failures, "quic", name, .{ .query = "", .want = "1" }, "LIMIT 1", try quicAnswer(aa, &client, join_cart ++ " RETURN 1 AS one LIMIT 1", &.{}));
        if (nowMillis() - s2 > 10_000) try failures.append(aa, try std.fmt.allocPrint(aa, "{s}: LIMIT 1 took {d} ms", .{ name, nowMillis() - s2 }));
        var product = try client.executeAndCollectWithTimeout(allocator, join_cart ++ " RETURN a.i, c.i", util.emptyParams(), 1000, 300);
        try check(aa, &failures, "quic", name, .{ .query = "", .code = "53200" }, "the whole product", .{ .code = if (product.error_code) |c| try aa.dupe(u8, c) else null, .rows = "" });
        product.deinit(allocator);
        // An empty last chain ends at once.
        const s3 = nowMillis();
        try check(aa, &failures, "quic", name, .{ .query = "", .want = "0" }, "empty last chain", try quicAnswer(aa, &client, "MATCH (a:KP)-[:KE]->(b), (c:KP), (d:KP), (e:KP {i: -1}) RETURN count(*) AS n", &.{}));
        if (nowMillis() - s3 > 1_000) try failures.append(aa, try std.fmt.allocPrint(aa, "{s}: the empty last chain took {d} ms", .{ name, nowMillis() - s3 }));
    }
    {
        // A join no binding of which completes (64 million steps, about an
        // hour at 1,500 pairs): the client gives up after 1 s and closes its
        // connection. The join polls the stream's cancel at every step, so
        // it stops when the server marks the stream abandoned (its
        // per-connection stall watchdog does at 60 s idle) instead of
        // running to the end: within 100 s the server is idle.
        const name = "3368 abandoned join (QUIC)";
        var client = try util.QuicProtoClient.connect(allocator, addr);
        var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
        hello.deinit(allocator);
        const left = nowMillis();
        if (client.executeAndCollectWithTimeout(allocator, "MATCH (a:KP)-[:KE]->(b), (c:KP), (d:KP)-[:NOPE]->(z) RETURN a.i", util.emptyParams(), 1000, 1)) |r| {
            var res = r;
            res.deinit(allocator);
        } else |_| {}
        client.deinit();
        var idle_after: ?i64 = null;
        var prev = procCpuTicks(server_pid);
        while (nowMillis() - left < 100_000) {
            sleepMillis(1_000);
            const now_t = procCpuTicks(server_pid);
            // Clock ticks are 1/100 s: a join still running spends about
            // 100 a second.
            if (now_t -| prev < 30) {
                idle_after = nowMillis() - left;
                break;
            }
            prev = now_t;
        }
        if (idle_after) |ms| std.debug.print("{s}: the server was idle {d} ms after the client left\n", .{ name, ms }) else try failures.append(aa, try std.fmt.allocPrint(aa, "{s}: the server was still busy 100 s after the client left", .{name}));
        var alive = try util.QuicProtoClient.connect(allocator, addr);
        defer alive.deinit();
        var hello2 = try alive.hello(allocator, util.defaultUsername(), util.defaultPassword());
        hello2.deinit(allocator);
        try check(aa, &failures, "quic", name, .{ .query = "", .want = "1" }, "alive", try quicAnswer(aa, &alive, "RETURN 1 AS one", &.{}));
    }
    try finish(failures.items, "round 4b-1c join bounds (QUIC)");
}

// CANARY: REQ=REQ-SONNY-3385-GRPC-OWNED-ENTITIES; FEATURE="GrpcStreaming"; ASPECT=RealServer; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4_transport.zig; OWNER=transport; UPDATED=2026-09-29
test "round 4b-1c over a real gRPC server: a node a chained part returns is pulled, and the server serves on (SONNY-3385)" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const quic_port = try util.getRandomPort();
    const grpc_port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-wfix4c-grpc-{d}", .{quic_port});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    const quic_addr = try util.formatAddr(allocator, quic_port);
    defer allocator.free(quic_addr);
    const grpc_addr = try util.formatAddr(allocator, grpc_port);
    defer allocator.free(grpc_addr);
    var server = try util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", quic_addr, "--listen-grpc", grpc_addr, "--data-dir", data_dir }, util.TestEnv.grpcPlaintext());
    defer server.deinit();
    try util.waitForServerReady(allocator, quic_addr, 30000);
    const server_pid: std.posix.pid_t = server.child.id orelse return error.NoServerPid;

    var failures: std.ArrayList([]const u8) = .empty;
    const queries = [_]struct { q: []const u8, rows: usize }{
        .{ .q = "CREATE (:RG {i: 1})-[:RR]->(:RG {i: 2}), (:RQ {i: 0}), (:RQ {i: 1}), (:RQ {i: 2}), (:RQ {i: 3})", .rows = 0 },
        .{ .q = "MATCH (g:RG {i: 1}) WITH g MATCH (n:RQ) RETURN n AS nn", .rows = 4 },
        .{ .q = "MATCH (g:RG {i: 1}) WITH g MATCH (n:RQ) RETURN n AS nn LIMIT 2", .rows = 2 },
        .{ .q = "MATCH (g:RG {i: 1}) WITH * MATCH (n:RQ) RETURN n AS nn", .rows = 4 },
        .{ .q = "MATCH (g:RG {i: 1}) WITH g MATCH (a:RG)-[e:RR]->(b) RETURN e AS ee, b AS bb", .rows = 1 },
        .{ .q = "MATCH (g:RG {i: 1}) WITH g MATCH p = (a:RG)-[:RR]->(b) RETURN p AS pp", .rows = 1 },
        .{ .q = "RETURN 1 AS alive", .rows = 1 },
    };
    for (queries) |item| {
        var client = util.GrpcProtoClient.connect(allocator, grpc_addr) catch |err| {
            try failures.append(aa, try std.fmt.allocPrint(aa, "{s}: connect: {s} (the server is gone)", .{ item.q, @errorName(err) }));
            break;
        };
        defer client.deinit();
        // A page of 1 row: every row but the first is pulled after the
        // request that made it ended.
        var res = client.executeAndCollect(allocator, item.q, util.emptyParams(), 1) catch |err| {
            try failures.append(aa, try std.fmt.allocPrint(aa, "{s}: {s}", .{ item.q, @errorName(err) }));
            continue;
        };
        defer res.deinit(allocator);
        if (res.error_code) |c| try failures.append(aa, try std.fmt.allocPrint(aa, "{s}: answered {s}", .{ item.q, c }));
        if (res.rows.len != item.rows) try failures.append(aa, try std.fmt.allocPrint(aa, "{s}: {d} rows, expected {d}", .{ item.q, res.rows.len, item.rows }));
    }
    if (!util.processAlive(server_pid)) try failures.append(aa, "the gRPC server exited");
    try finish(failures.items, "round 4b-1c SONNY-3385 (a real gRPC server)");
}

/// One request run by the gRPC handler on a thread of its own.
const HandlerJob = struct {
    f: *Fixture,
    session: []const u8,
    query: []const u8,
    code: ?[]const u8 = null,
    done: bool = false,

    fn entry(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
        const job: *HandlerJob = @ptrCast(@alignCast(arg.?));
        const answer = job.f.run(job.session, job.query, &.{}) catch return null;
        job.code = answer.code;
        job.done = true;
        return null;
    }
};

/// Run `job` on a thread whose stack is exactly `stack` bytes (a mapping of
/// its own with a guard page; glibc would hand back a larger cached stack),
/// in a child process, so an overflow is reported. Exit status: 0 answered,
/// 1 refused as nested too deep (54001, or 42000 from the stack guard), 2
/// answered another error, 9 setup failed; null crashed.
fn handlerInChild(job: *HandlerJob, stack: usize) ?u8 {
    const pid = std.c.fork();
    if (pid < 0) return 9;
    if (pid == 0) {
        std.posix.setrlimit(.CORE, .{ .cur = 0, .max = 0 }) catch {};
        const page = std.heap.page_size_min;
        const raw = std.c.mmap(null, stack + page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        if (raw == std.c.MAP_FAILED) std.c._exit(9);
        const base: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(raw));
        if (std.c.mprotect(@ptrCast(base), page, .{}) != 0) std.c._exit(9);
        var attr: std.c.pthread_attr_t = undefined;
        if (std.c.pthread_attr_init(&attr) != .SUCCESS) std.c._exit(9);
        if (std.c.pthread_attr_setstack(&attr, @ptrCast(base + page), stack) != .SUCCESS) std.c._exit(9);
        var tid: std.c.pthread_t = undefined;
        if (std.c.pthread_create(&tid, &attr, HandlerJob.entry, job) != .SUCCESS) std.c._exit(9);
        _ = std.c.pthread_join(tid, null);
        if (!job.done) std.c._exit(9);
        const code = job.code orelse std.c._exit(0);
        // 54001: the query nesting limit (SONNY-3244). 42000 "nesting too
        // deep for the parser's stack": the parser's stack guard (SONNY-3133,
        // merged from the r12 line), which in a Debug build can refuse the
        // deepest FOR bodies on an 8 MiB thread just before the limit does.
        // Either is a clean refusal past the limit.
        std.c._exit(if (std.mem.eql(u8, code, "54001") or std.mem.eql(u8, code, "42000")) 1 else 2);
    }
    var status: c_int = 0;
    if (std.c.waitpid(pid, &status, 0) != pid) return 9;
    const st: u32 = @bitCast(status);
    if (std.os.linux.W.IFSIGNALED(st)) return null;
    return @intCast(std.os.linux.W.EXITSTATUS(st));
}

test "round 4a over gRPC: the deepest nesting the parser allows runs on an 8 MiB connection thread; one level more is refused (54001)" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const aa = f.h.arena.allocator();
    const s = try f.sessions.createSession("reader", "", null, null, null, false, 0);
    const Shape = struct { name: []const u8, head: []const u8 = "", open: []const u8, core: []const u8, close: []const u8 = "", ok: usize };
    // `ok`: the deepest nesting that parses (the outer query is a level too;
    // a CALL { } that opens the statement is a statement, not a query level).
    const shapes = [_]Shape{
        .{ .name = "WITH chain", .open = "WITH 1 AS a ", .core = "RETURN a", .ok = 10 },
        .{ .name = "CALL subquery", .open = "CALL { ", .core = "RETURN 1 AS x", .close = " } RETURN x", .ok = 10 },
        .{ .name = "IN subquery", .head = "MATCH (m) WHERE m.i IN (", .open = "MATCH (m) WHERE m.i IN (", .core = "RETURN 1", .close = ") RETURN m.i", .ok = 8 },
        .{ .name = "FOR body", .head = "WITH 1 AS a ", .open = "FOR x IN [1] MATCH (n) WITH n ", .core = "RETURN 1", .ok = 9 },
    };
    var failures: std.ArrayList([]const u8) = .empty;
    for (shapes) |sh| {
        for ([_]usize{ sh.ok, sh.ok + 1, sh.ok + 40 }) |depth| {
            var text: std.ArrayList(u8) = .empty;
            try text.appendSlice(aa, sh.head);
            for (0..depth) |_| try text.appendSlice(aa, sh.open);
            try text.appendSlice(aa, sh.core);
            for (0..depth) |_| try text.appendSlice(aa, sh.close);
            if (sh.head.len != 0 and sh.close.len != 0) try text.appendSlice(aa, ") RETURN m.i");
            var job: HandlerJob = .{ .f = &f, .session = s, .query = text.items };
            const got = handlerInChild(&job, 8 << 20);
            // Within the limit: parsed and run (an answer, or an error of the
            // run's own), never a crash. Past it: 54001.
            const ok = if (got) |g| (if (depth <= sh.ok) (g == 0 or g == 2) else g == 1) else false;
            if (!ok) try failures.append(aa, try std.fmt.allocPrint(aa, "{s} x{d}: {s}", .{ sh.name, depth, if (got == null) "crashed" else switch (got.?) {
                0 => "answered",
                1 => "54001",
                2 => "another error",
                else => "setup failed",
            } }));
        }
    }
    try finish(failures.items, "round 4a (gRPC nesting on 8 MiB)");
}

// ---------------------------------------------------------------------------
// QUIC, against a spawned server.

fn quicAnswer(aa: std.mem.Allocator, client: *util.QuicProtoClient, query: []const u8, params: []const P) !Answer {
    const gpa = testing.allocator;
    var ps = util.emptyParams();
    for (params) |p| try ps.append(gpa, try makeParam(gpa, p));
    var res = try client.executeAndCollect(gpa, query, ps, 1000);
    defer res.deinit(gpa);
    if (res.error_code) |code| return .{ .code = try aa.dupe(u8, code), .rows = "" };
    const rows = try aa.alloc([]const u8, res.rows.len);
    for (res.rows, rows) |row, *out| {
        var line: std.ArrayList(u8) = .empty;
        for (row, 0..) |cell, j| {
            if (j > 0) try line.append(aa, '|');
            switch (cell) {
                .int => |v| try line.print(aa, "{d}", .{v}),
                .string => |v| try line.appendSlice(aa, v),
                .bool => |v| try line.appendSlice(aa, if (v) "true" else "false"),
                .null => try line.appendSlice(aa, "null"),
                else => try line.appendSlice(aa, "?"),
            }
        }
        out.* = try line.toOwnedSlice(aa);
    }
    return .{ .code = null, .rows = try joinSorted(aa, rows) };
}

test "round 4a over QUIC: PROFILE repros refused, C3, I2, I11 (the MERGE fast path too) and I8" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-wfix4a-{d}", .{port});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);
    var server = try util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir }, util.TestEnv.standard());
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 30000);
    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    var failures: std.ArrayList([]const u8) = .empty;
    for (cases, 0..) |c, n| {
        for (seed) |st| {
            const query = try labeled(aa, st.query, n);
            try check(aa, &failures, "quic", c.name, st, query, try quicAnswer(aa, &client, query, &.{}));
        }
        for (c.steps) |st| {
            const query = try labeled(aa, st.query, n);
            const got = try quicAnswer(aa, &client, query, st.params);
            try check(aa, &failures, "quic", c.name, st, query, got);
        }
    }
    for (quic_only_cases, cases.len..) |c, n| {
        for (seed) |st| {
            const query = try labeled(aa, st.query, n);
            try check(aa, &failures, "quic", c.name, st, query, try quicAnswer(aa, &client, query, &.{}));
        }
        for (c.steps) |st| {
            const query = try labeled(aa, st.query, n);
            try check(aa, &failures, "quic", c.name, st, query, try quicAnswer(aa, &client, query, st.params));
        }
    }
    // I8: more than 1024 statements (54000).
    var many: std.ArrayList(u8) = .empty;
    for (0..1025) |_| try many.appendSlice(aa, "RETURN 1;");
    const got = try quicAnswer(aa, &client, many.items, &.{});
    try check(aa, &failures, "quic", "I8 statements", .{ .query = "", .code = "54000" }, "RETURN 1; x1025", got);
    // The server serves on.
    try check(aa, &failures, "quic", "alive", .{ .query = "", .want = "1" }, "RETURN 1", try quicAnswer(aa, &client, "RETURN 1 AS one", &.{}));
    try finish(failures.items, "round 4a (QUIC)");
}
