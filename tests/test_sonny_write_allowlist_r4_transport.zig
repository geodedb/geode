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
//
// CANARY: REQ=REQ-SONNY-3139-WRITE-SHAPES; FEATURE="WriteShapeValidator"; ASPECT=TransportProfile; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4_transport.zig; OWNER=engine; UPDATED=2026-09-28

const std = @import("std");
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

const P = struct { name: []const u8, value: []const u8 };

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
    // I8.
    .{ .name = "I8 nesting", .steps = &.{
        .{ .query = "WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a WITH 1 AS a RETURN a", .code = "54001" },
        .{ .query = "WITH 1 AS a WITH 1 AS a WITH 1 AS a RETURN a", .want = "1" },
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
        for (params) |p| try ps.append(ga, try util.makeStringParam(ga, p.name, p.value));
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
/// 1 answered 54001, 2 answered another error, 9 setup failed; null crashed.
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
        std.c._exit(if (std.mem.eql(u8, code, "54001")) 1 else 2);
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
    for (params) |p| try ps.append(gpa, try util.makeStringParam(gpa, p.name, p.value));
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
    var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--data-dir", data_dir }, util.TestEnv.standard());
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
    // I8: more than 1024 statements (54000).
    var many: std.ArrayList(u8) = .empty;
    for (0..1025) |_| try many.appendSlice(aa, "RETURN 1;");
    const got = try quicAnswer(aa, &client, many.items, &.{});
    try check(aa, &failures, "quic", "I8 statements", .{ .query = "", .code = "54000" }, "RETURN 1; x1025", got);
    // The server serves on.
    try check(aa, &failures, "quic", "alive", .{ .query = "", .want = "1" }, "RETURN 1", try quicAnswer(aa, &client, "RETURN 1 AS one", &.{}));
    try finish(failures.items, "round 4a (QUIC)");
}
