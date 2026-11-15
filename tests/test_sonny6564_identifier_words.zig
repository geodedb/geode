//! SONNY-6564: the parser applies ISO/IEC 39075:2024 21.3's identifier rule
//! the right way round.
//!
//! 21.3 <keyword> ::= <reserved word> | <non-reserved word> (printed pages
//! 438-440: 222 reserved words, 40 pre-reserved words, which are reserved
//! words, and 48 non-reserved words). SR 18: "The case-normal form of a
//! <non-delimited identifier> shall not be equal ... to any <reserved
//! word>"; a <delimited identifier> (`...`) is not subject to it.
//!
//! 1. A non-reserved word (TYPE, PROPERTY, NODE, ...) names a variable
//!    wherever one binds or is referenced: SET and REMOVE took only plain
//!    identifiers, so `MATCH (type:T) SET type.x = 1` was a parse error.
//! 2. A reserved word does not: `MATCH (match:X) RETURN match` ran and
//!    `RETURN MATCH` parsed. Refused (42000), naming the delimited form;
//!    `match` (backquoted) names it. Variables, aliases and parameters
//!    follow 21.3, except five reserved words Geode's own procedures yield
//!    as columns (PATH, VALUE, COUNT, AVG, TIMESTAMP), which stay names.
//!    Labels, relationship types, property names and property keys keep
//!    accepting any word. Both are documented non-conformances
//!    (docs/GQL_COMPLIANCE.md).
//! 3. 16.11 <graph pattern quantifier> after an edge pattern (Feature G036):
//!    `-[:R]->{1,2}`, `{n}`, `{m,}`, `{,n}`, `+` and `*` read into the same
//!    length bounds as `-[:R*1..2]->`, and run on the same expansion.
const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");
const ast = geode.gql.ast;

fn parse(arena: *std.heap.ArenaAllocator, q: []const u8) !geode.ParseOutcome {
    return geode.parseGqlOutcome(q, arena.allocator(), .{});
}

fn parses(q: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    return switch (try parse(&arena, q)) {
        .Ok => true,
        .Err => |e| blk: {
            std.debug.print("refused: {s}\n  {s}\n", .{ q, e.msg });
            break :blk false;
        },
    };
}

/// The query is refused as a reserved word used as a name, and the message
/// names the word and its delimited form.
fn refusedAsReserved(q: []const u8, word: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    switch (try parse(&arena, q)) {
        .Ok => {
            std.debug.print("accepted: {s}\n", .{q});
            return false;
        },
        .Err => |e| {
            const quoted = try std.fmt.allocPrint(arena.allocator(), "`{s}`", .{word});
            if (std.mem.indexOf(u8, e.msg, "reserved word") == null or std.mem.indexOf(u8, e.msg, quoted) == null) {
                std.debug.print("refused, but not as the reserved word {s}: {s}\n  {s}\n", .{ word, q, e.msg });
                return false;
            }
            return true;
        },
    }
}

// The 21.3 lists, as the standard prints them (printed pages 438-440),
// typed here independently of src/gql/identifier_words.zig: the parser is
// checked against the standard, not against its own table.
const iso_reserved = [_][]const u8{
    "ABS",             "ACOS",            "ALL",                    "ALL_DIFFERENT",  "AND",          "ANY",               "ARRAY",        "AS",           "ASC",             "ASCENDING",           "ASIN",
    "AT",              "ATAN",            "AVG",                    "BIG",            "BIGINT",       "BINARY",            "BOOL",         "BOOLEAN",      "BOTH",            "BTRIM",               "BY",
    "BYTE_LENGTH",     "BYTES",           "CALL",                   "CARDINALITY",    "CASE",         "CAST",              "CEIL",         "CEILING",      "CHAR",            "CHAR_LENGTH",         "CHARACTER_LENGTH",
    "CHARACTERISTICS", "CLOSE",           "COALESCE",               "COLLECT_LIST",   "COMMIT",       "COPY",              "COS",          "COSH",         "COT",             "COUNT",               "CREATE",
    "CURRENT_DATE",    "CURRENT_GRAPH",   "CURRENT_PROPERTY_GRAPH", "CURRENT_SCHEMA", "CURRENT_TIME", "CURRENT_TIMESTAMP", "DATE",         "DATETIME",     "DAY",             "DEC",                 "DECIMAL",
    "DEGREES",         "DELETE",          "DESC",                   "DESCENDING",     "DETACH",       "DISTINCT",          "DOUBLE",       "DROP",         "DURATION",        "DURATION_BETWEEN",    "ELEMENT_ID",
    "ELSE",            "END",             "EXCEPT",                 "EXISTS",         "EXP",          "FALSE",             "FILTER",       "FINISH",       "FLOAT",           "FLOAT16",             "FLOAT32",
    "FLOAT64",         "FLOAT128",        "FLOAT256",               "FLOOR",          "FOR",          "FROM",              "GROUP",        "HAVING",       "HOME_GRAPH",      "HOME_PROPERTY_GRAPH", "HOME_SCHEMA",
    "HOUR",            "IF",              "IMPLIES",                "IN",             "INSERT",       "INT",               "INTEGER",      "INT8",         "INTEGER8",        "INT16",               "INTEGER16",
    "INT32",           "INTEGER32",       "INT64",                  "INTEGER64",      "INT128",       "INTEGER128",        "INT256",       "INTEGER256",   "INTERSECT",       "INTERVAL",            "IS",
    "LEADING",         "LEFT",            "LET",                    "LIKE",           "LIMIT",        "LIST",              "LN",           "LOCAL",        "LOCAL_DATETIME",  "LOCAL_TIME",          "LOCAL_TIMESTAMP",
    "LOG",             "LOG10",           "LOWER",                  "LTRIM",          "MATCH",        "MAX",               "MIN",          "MINUTE",       "MOD",             "MONTH",               "NEXT",
    "NODETACH",        "NORMALIZE",       "NOT",                    "NOTHING",        "NULL",         "NULLS",             "NULLIF",       "OCTET_LENGTH", "OF",              "OFFSET",              "OPTIONAL",
    "OR",              "ORDER",           "OTHERWISE",              "PARAMETER",      "PARAMETERS",   "PATH",              "PATH_LENGTH",  "PATHS",        "PERCENTILE_CONT", "PERCENTILE_DISC",     "POWER",
    "PRECISION",       "PROPERTY_EXISTS", "RADIANS",                "REAL",           "RECORD",       "REMOVE",            "REPLACE",      "RESET",        "RETURN",          "RIGHT",               "ROLLBACK",
    "RTRIM",           "SAME",            "SCHEMA",                 "SECOND",         "SELECT",       "SESSION",           "SESSION_USER", "SET",          "SIGNED",          "SIN",                 "SINH",
    "SIZE",            "SKIP",            "SMALL",                  "SMALLINT",       "SQRT",         "START",             "STDDEV_POP",   "STDDEV_SAMP",  "STRING",          "SUM",                 "TAN",
    "TANH",            "THEN",            "TIME",                   "TIMESTAMP",      "TRAILING",     "TRIM",              "TRUE",         "TYPED",        "UBIGINT",         "UINT",                "UINT8",
    "UINT16",          "UINT32",          "UINT64",                 "UINT128",        "UINT256",      "UNION",             "UNKNOWN",      "UNSIGNED",     "UPPER",           "USE",                 "USMALLINT",
    "VALUE",           "VARBINARY",       "VARCHAR",                "VARIABLE",       "WHEN",         "WHERE",             "WITH",         "XOR",          "YEAR",            "YIELD",               "ZONED",
    "ZONED_DATETIME",  "ZONED_TIME",
};

const iso_pre_reserved = [_][]const u8{
    "ABSTRACT",     "AGGREGATE",    "AGGREGATES",  "ALTER",     "CATALOG", "CLEAR",   "CLONE",     "CONSTRAINT",
    "CURRENT_ROLE", "CURRENT_USER", "DATA",        "DIRECTORY", "DRYRUN",  "EXACT",   "EXISTING",  "FUNCTION",
    "GQLSTATUS",    "GRANT",        "INSTANT",     "INFINITY",  "NUMBER",  "NUMERIC", "ON",        "OPEN",
    "PARTITION",    "PROCEDURE",    "PRODUCT",     "PROJECT",   "QUERY",   "RECORDS", "REFERENCE", "RENAME",
    "REVOKE",       "SUBSTRING",    "SYSTEM_USER", "TEMPORAL",  "UNIQUE",  "UNIT",    "VALUES",    "WHITESPACE",
};

const iso_non_reserved = [_][]const u8{
    "ACYCLIC",     "BINDING",    "BINDINGS",   "CONNECTING", "DESTINATION", "DIFFERENT", "DIRECTED",     "EDGE",
    "EDGES",       "ELEMENT",    "ELEMENTS",   "FIRST",      "GRAPH",       "GROUPS",    "KEEP",         "LABEL",
    "LABELED",     "LABELS",     "LAST",       "NFC",        "NFD",         "NFKC",      "NFKD",         "NO",
    "NODE",        "NORMALIZED", "ONLY",       "ORDINALITY", "PROPERTY",    "READ",      "RELATIONSHIP", "RELATIONSHIPS",
    "REPEATABLE",  "SHORTEST",   "SIMPLE",     "SOURCE",     "TABLE",       "TEMP",      "TO",           "TRAIL",
    "TRANSACTION", "TYPE",       "UNDIRECTED", "VERTEX",     "WALK",        "WITHOUT",   "WRITE",        "ZONE",
};

test "SONNY-6564: a non-reserved word names a variable in every position a variable binds or is read" {
    var failed: usize = 0;
    // Every 21.3 non-reserved word, bound by MATCH, written by SET and
    // REMOVE, read by RETURN.
    for (iso_non_reserved) |w| {
        var buf: [256]u8 = undefined;
        const q = try std.fmt.bufPrint(&buf, "MATCH ({s}:T) SET {s}.x = 1 REMOVE {s}.y RETURN {s}, {s}.x", .{ w, w, w, w, w });
        if (!try parses(q)) failed += 1;
    }
    for ([_][]const u8{
        // The ticket's shapes (SONNY-6548).
        "MATCH (type:TypeInfo) SET type.x = 1",
        "MATCH (type:TypeInfo) REMOVE type.temporary",
        "MATCH (property:Metadata) SET property.x = 1",
        "MATCH (property:Metadata) REMOVE property:Old",
        "MATCH p = (c:Counter)-[:HAS_TYPE]->(type:TypeInfo) SET type.property = 1",
        // Every other binding position.
        "MATCH (a)-[type:R]->(b) RETURN type",
        "MATCH type = (a)->(b) RETURN type",
        "MATCH (type:T) DETACH DELETE type",
        "MATCH (n) RETURN n.k AS type ORDER BY type",
        "FOR type IN [1, 2] RETURN type",
        "FOR node IN [1] WITH ORDINALITY edge RETURN node, edge",
        "WITH 1 AS one UNWIND [1] AS type RETURN type",
        "RETURN $type",
        "RETURN [type IN [1, 2] WHERE type > 1 | type * 2] AS l",
        "RETURN any(type IN [1] WHERE type = 1) AS b",
        "VALUES (1) AS (type) RETURN type",
        "RETURN no",
        // 21.3 does not list Geode's own keywords: identifiers.
        "MATCH (merge:T) RETURN merge",
        "MATCH (unwind:T) RETURN unwind",
    }) |q| {
        if (!try parses(q)) failed += 1;
    }
    try testing.expectEqual(@as(usize, 0), failed);
}

test "SONNY-6564: a reserved word is refused wherever a variable, alias or parameter binds or is read, naming the delimited form" {
    var failed: usize = 0;
    // Every 21.3 reserved and pre-reserved word as a node variable, but the
    // five Geode keeps (the test below).
    try testing.expectEqual(@as(usize, 222), iso_reserved.len);
    try testing.expectEqual(@as(usize, 40), iso_pre_reserved.len);
    var refused_words: usize = 0;
    for ([_][]const []const u8{ &iso_reserved, &iso_pre_reserved }) |list| {
        for (list) |w| {
            if (isGeodeExtension(w)) continue;
            refused_words += 1;
            var buf: [128]u8 = undefined;
            const lower = std.ascii.lowerString(buf[64..], w);
            const q = try std.fmt.bufPrint(buf[0..64], "MATCH ({s}:T) RETURN 1", .{lower});
            if (!try refusedAsReserved(q, lower)) failed += 1;
        }
    }
    try testing.expectEqual(@as(usize, 257), refused_words);
    const Case = struct { q: []const u8, word: []const u8 };
    for ([_]Case{
        .{ .q = "RETURN MATCH", .word = "MATCH" },
        .{ .q = "MATCH (match:X) RETURN match", .word = "match" },
        .{ .q = "MATCH (return:X) RETURN return", .word = "return" },
        .{ .q = "MATCH (n:X) RETURN match", .word = "match" },
        .{ .q = "MATCH ()-[match:R]->() RETURN 1", .word = "match" },
        .{ .q = "MATCH list = (a)->(b) RETURN 1", .word = "list" },
        .{ .q = "MATCH (n) RETURN n AS sum", .word = "sum" },
        .{ .q = "MATCH (n) RETURN n.k AS data ORDER BY data", .word = "data" },
        .{ .q = "MATCH (n) WITH n AS list RETURN 1", .word = "list" },
        .{ .q = "MATCH (n) SET match.x = 1", .word = "match" },
        .{ .q = "MATCH (n) REMOVE match.x", .word = "match" },
        .{ .q = "MATCH (n) DELETE match", .word = "match" },
        .{ .q = "FOR year IN [1] RETURN 1", .word = "year" },
        .{ .q = "FOR x IN [1] WITH ORDINALITY size RETURN x", .word = "size" },
        .{ .q = "WITH 1 AS one UNWIND [1] AS upper RETURN 1", .word = "upper" },
        .{ .q = "RETURN $limit", .word = "limit" },
        .{ .q = "MATCH (n) WHERE n.k > $from RETURN n", .word = "from" },
        .{ .q = "VALUES (1) AS (number) RETURN 1", .word = "number" },
        .{ .q = "RETURN [min IN [1] | min] AS l", .word = "min" },
        .{ .q = "CALL geode.ts.range(1, 'm', 0, 10) YIELD ts, value AS max RETURN ts", .word = "max" },
        // SR 17: the case-normal form decides, not the spelling's case.
        .{ .q = "MATCH (MaTcH:X) RETURN 1", .word = "MaTcH" },
    }) |c| {
        if (!try refusedAsReserved(c.q, c.word)) failed += 1;
    }
    try testing.expectEqual(@as(usize, 0), failed);
}

const geode_extension = [_][]const u8{ "AVG", "COUNT", "PATH", "TIMESTAMP", "VALUE" };

fn isGeodeExtension(w: []const u8) bool {
    for (geode_extension) |e| if (std.ascii.eqlIgnoreCase(e, w)) return true;
    return false;
}

test "SONNY-6564: the five reserved words Geode's procedures yield stay binding names (documented non-conformance)" {
    var failed: usize = 0;
    for ([_][]const u8{
        // algo.* yield `path`; a path variable named path.
        "MATCH (n:Person) CALL algo.bfs.stream(n, {maxDepth: 2}) YIELD path RETURN path",
        "MATCH path = (a)->(b) RETURN length(path) AS hops",
        "MATCH (path:Person) RETURN path.name",
        // geode.ts.* yield `value` and `avg`.
        "CALL geode.ts.range(1, 'm', 0, 10) YIELD ts, value RETURN ts, value",
        "CALL geode.ts.bucket_avg(1, 'm', 0, 10, 5) YIELD bucket_ts, avg RETURN bucket_ts, avg",
        // count and timestamp columns.
        "MATCH (n) RETURN count(n) AS count ORDER BY count",
        "RETURN 1 AS timestamp",
    }) |q| {
        if (!try parses(q)) failed += 1;
    }
    try testing.expectEqual(@as(usize, 0), failed);
}

test "SONNY-6564: a delimited identifier names anything; reserved words keep their constructs; names-only positions take any word" {
    var failed: usize = 0;
    for ([_][]const u8{
        // Delimited identifiers (21.3 <accent quoted character sequence>).
        "MATCH (`match`:X) RETURN `match`",
        "MATCH (`path`)-[`count`:R]->(b) RETURN `path`, `count`",
        "MATCH `path` = (a)->(b) RETURN `path`",
        "MATCH (n) RETURN n AS `count` ORDER BY `count`",
        "MATCH (`match`) SET `match`.x = 1 REMOVE `match`.y",
        "FOR `value` IN [1] RETURN `value`",
        "RETURN $`limit`",
        "CALL geode.ts.range(1, 'm', 0, 10) YIELD ts, `value` RETURN ts, `value`",
        "RETURN 1 AS `a``b`",
        "MATCH (n:`Order`) RETURN n.`value`",
        // A reserved word that starts a construct is that construct.
        "MATCH (n) RETURN count(*)",
        "RETURN abs(-1), upper('a'), size([1]), coalesce(NULL, 1)",
        "MATCH (n) RETURN count { MATCH (n)->() } AS c",
        "RETURN CURRENT_DATE",
        // Labels, types, property names and keys: any word (extension).
        "MATCH (n:Order)-[r:VALUE]->(m:Product) RETURN n.value, n.count, m.data",
        "CREATE (:Product {value: 1, data: 2, count: 3, path: 'p'})",
        "MATCH (n) WHERE n:Order RETURN n { .value, .count }",
    }) |q| {
        if (!try parses(q)) failed += 1;
    }
    // An empty or unterminated delimited identifier is no identifier.
    for ([_][]const u8{ "RETURN ``", "RETURN `abc" }) |q| {
        if (try parsesQuiet(q)) {
            std.debug.print("accepted: {s}\n", .{q});
            failed += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failed);
}

fn parsesQuiet(q: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    return (try parse(&arena, q)) == .Ok;
}

fn firstRel(arena: *std.heap.ArenaAllocator, q: []const u8) !ast.RelPattern {
    return switch (try parse(arena, q)) {
        .Ok => |res| res.program.statements[0].Query.match.chains[0].hops[0].rel,
        .Err => |e| {
            std.debug.print("refused: {s}\n  {s}\n", .{ q, e.msg });
            return error.ParseFailed;
        },
    };
}

test "SONNY-6564: 16.11 graph pattern quantifiers read into the bounds the Cypher form sets" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Case = struct { iso: []const u8, min: ?u32, max: ?u32, dir: ast.RelDir };
    for ([_]Case{
        .{ .iso = "MATCH (a)-[:R]->{1,2}(b) RETURN b", .min = 1, .max = 2, .dir = .right },
        .{ .iso = "MATCH (a)-[:R]->{2}(b) RETURN b", .min = 2, .max = 2, .dir = .right },
        .{ .iso = "MATCH (a)-[:R]->{1,}(b) RETURN b", .min = 1, .max = null, .dir = .right },
        .{ .iso = "MATCH (a)-[:R]->{,3}(b) RETURN b", .min = 0, .max = 3, .dir = .right },
        .{ .iso = "MATCH (a)-[:R]->+(b) RETURN b", .min = 1, .max = null, .dir = .right },
        .{ .iso = "MATCH (a)-[:R]->*(b) RETURN b", .min = 0, .max = null, .dir = .right },
        .{ .iso = "MATCH (a)<-[:R]-{1,2}(b) RETURN b", .min = 1, .max = 2, .dir = .left },
        .{ .iso = "MATCH (a)-[:R]-{1,2}(b) RETURN b", .min = 1, .max = 2, .dir = .undirected },
        .{ .iso = "MATCH (a)->{1,2}(b) RETURN b", .min = 1, .max = 2, .dir = .right },
        .{ .iso = "MATCH (a)<-{1,2}(b) RETURN b", .min = 1, .max = 2, .dir = .left },
        .{ .iso = "MATCH (a)-{1,2}(b) RETURN b", .min = 1, .max = 2, .dir = .undirected },
    }) |c| {
        const rel = try firstRel(&arena, c.iso);
        try testing.expectEqual(c.min, rel.min_len);
        try testing.expectEqual(c.max, rel.max_len);
        try testing.expectEqual(c.dir, rel.dir);
    }
    // `*1..2` in the brackets sets the same bounds.
    const cypher = try firstRel(&arena, "MATCH (a)-[:R*1..2]->(b) RETURN b");
    const iso = try firstRel(&arena, "MATCH (a)-[:R]->{1,2}(b) RETURN b");
    try testing.expectEqual(cypher.min_len, iso.min_len);
    try testing.expectEqual(cypher.max_len, iso.max_len);
    // SR 3 a: the upper bound is above 0 and not below the lower; one
    // quantifier per edge; `{}` is neither form.
    var failed: usize = 0;
    for ([_][]const u8{
        "MATCH (a)-[:R]->{0}(b) RETURN b",
        "MATCH (a)-[:R]->{0,0}(b) RETURN b",
        "MATCH (a)-[:R]->{3,1}(b) RETURN b",
        "MATCH (a)-[:R]->{}(b) RETURN b",
        "MATCH (a)-[:R*1..2]->{1,2}(b) RETURN b",
    }) |q| {
        if (try parsesQuiet(q)) {
            std.debug.print("accepted: {s}\n", .{q});
            failed += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failed);
}

// ---------------------------------------------------------------------------
// A real geode serve, QUIC and gRPC.
// ---------------------------------------------------------------------------

const Server = struct {
    handle: util.ServerHandle,
    quic_addr: []u8,
    grpc_addr: []u8,
    quic: util.QuicProtoClient,

    fn start(a: std.mem.Allocator) !Server {
        const quic_port = try util.getRandomPort();
        var grpc_port = try util.getRandomTcpPort();
        while (grpc_port == quic_port) grpc_port = try util.getRandomTcpPort();
        const quic_addr = try util.formatAddr(a, quic_port);
        errdefer a.free(quic_addr);
        const grpc_addr = try util.formatAddr(a, grpc_port);
        errdefer a.free(grpc_addr);
        var handle = try util.spawnServer(a, &.{ geode_test_bin.geode_exe, "serve", "--listen", quic_addr, "--listen-grpc", grpc_addr }, util.TestEnv.grpcPlaintext());
        errdefer handle.deinit();
        try util.waitForServerReady(a, quic_addr, 10000);
        var quic = try util.QuicProtoClient.connect(a, quic_addr);
        errdefer quic.deinit();
        var hq = try quic.hello(a, util.defaultUsername(), util.defaultPassword());
        hq.deinit(a);
        return .{ .handle = handle, .quic_addr = quic_addr, .grpc_addr = grpc_addr, .quic = quic };
    }

    fn stop(self: *Server, a: std.mem.Allocator) void {
        self.quic.deinit();
        self.handle.deinit();
        a.free(self.quic_addr);
        a.free(self.grpc_addr);
    }

    const Transport = enum { quic, grpc };

    fn exec(self: *Server, a: std.mem.Allocator, t: Transport, q: []const u8) !util.ExecResult {
        switch (t) {
            .quic => return self.quic.executeAndCollect(a, q, util.emptyParams(), 100),
            .grpc => {
                // One streamed query per test-client HTTP/2 connection.
                var grpc = try util.GrpcProtoClient.connect(a, self.grpc_addr);
                defer grpc.deinit();
                var hg = try grpc.hello(a, util.defaultUsername(), util.defaultPassword());
                hg.deinit(a);
                return grpc.executeAndCollect(a, q, util.emptyParams(), 100);
            },
        }
    }

    fn ok(self: *Server, a: std.mem.Allocator, q: []const u8) !void {
        var r = try self.exec(a, .quic, q);
        defer r.deinit(a);
        if (r.error_code) |code| {
            std.debug.print("{s}: {s} {s}\n", .{ q, code, r.error_message orelse "" });
            return error.QueryFailed;
        }
    }
};

/// The first column's integers, in row order (null for a NULL).
fn ints(a: std.mem.Allocator, r: *const util.ExecResult) ![]?i64 {
    const out = try a.alloc(?i64, r.rows.len);
    for (r.rows, out) |row, *o| o.* = switch (row[0]) {
        .int => |i| i,
        else => null,
    };
    return out;
}

fn expectInts(want: []const ?i64, got: []const ?i64) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqual(w, g);
}

test "SONNY-6564: over QUIC and gRPC, non-reserved-word variables write and read, reserved ones are 42000, ISO quantifiers expand like *m..n" {
    const a = testing.allocator;
    var s = try Server.start(a);
    defer s.stop(a);
    try s.ok(a, "CREATE (:S6564T {k: 1, temporary: 'x'})");
    // A chain 0 -> 1 -> 2 -> 3 of :R edges.
    try s.ok(a, "CREATE (:S6564Q {k: 0})-[:R]->(:S6564Q {k: 1})-[:R]->(:S6564Q {k: 2})-[:R]->(:S6564Q {k: 3})");

    for ([_]Server.Transport{ .quic, .grpc }) |t| {
        // 1. Non-reserved words write and read (the ticket's SET/REMOVE).
        {
            var r = try s.exec(a, t, "MATCH (type:S6564T) SET type.x = 7 RETURN type.x AS x");
            defer r.deinit(a);
            try testing.expect(r.error_code == null);
            const got = try ints(a, &r);
            defer a.free(got);
            try expectInts(&.{7}, got);
        }
        {
            var r = try s.exec(a, t, "MATCH (property:S6564T) REMOVE property.x RETURN property.x AS x, property.k AS k");
            defer r.deinit(a);
            try testing.expect(r.error_code == null);
            try testing.expectEqual(@as(usize, 1), r.rows.len);
            try testing.expect(r.rows[0][0] == .null);
        }
        // 2. A reserved word is a syntax error (42000) naming the fix; the
        // delimited form runs.
        for ([_][]const u8{ "MATCH (match:S6564T) RETURN match", "RETURN MATCH", "MATCH (n:S6564T) RETURN n.k AS sum" }) |q| {
            var r = try s.exec(a, t, q);
            defer r.deinit(a);
            if (r.error_code == null or !std.mem.eql(u8, r.error_code.?, "42000") or std.mem.indexOf(u8, r.error_message orelse "", "reserved word") == null) {
                std.debug.print("{s} [{s}]: {?s} {?s}\n", .{ q, @tagName(t), r.error_code, r.error_message });
                return error.ReservedWordNotRefused;
            }
        }
        {
            var r = try s.exec(a, t, "MATCH (`match`:S6564T) RETURN `match`.k AS `count`");
            defer r.deinit(a);
            try testing.expect(r.error_code == null);
            try testing.expectEqualStrings("count", r.columns[0]);
            const got = try ints(a, &r);
            defer a.free(got);
            try expectInts(&.{1}, got);
        }
        // 3. ISO quantifiers return what the Cypher form returns.
        const Pair = struct { iso: []const u8, cypher: []const u8, want: []const ?i64 };
        for ([_]Pair{
            .{ .iso = "MATCH (a:S6564Q {k: 0})-[:R]->{1,2}(b) RETURN b.k AS k ORDER BY k", .cypher = "MATCH (a:S6564Q {k: 0})-[:R*1..2]->(b) RETURN b.k AS k ORDER BY k", .want = &.{ 1, 2 } },
            .{ .iso = "MATCH (a:S6564Q {k: 0})-[:R]->{2}(b) RETURN b.k AS k ORDER BY k", .cypher = "MATCH (a:S6564Q {k: 0})-[:R*2]->(b) RETURN b.k AS k ORDER BY k", .want = &.{2} },
            .{ .iso = "MATCH (a:S6564Q {k: 0})-[:R]->{1,}(b) RETURN b.k AS k ORDER BY k", .cypher = "MATCH (a:S6564Q {k: 0})-[:R*1..]->(b) RETURN b.k AS k ORDER BY k", .want = &.{ 1, 2, 3 } },
            .{ .iso = "MATCH (a:S6564Q {k: 0})-[:R]->+(b) RETURN b.k AS k ORDER BY k", .cypher = "MATCH (a:S6564Q {k: 0})-[:R*1..]->(b) RETURN b.k AS k ORDER BY k", .want = &.{ 1, 2, 3 } },
            .{ .iso = "MATCH (a:S6564Q {k: 0})-[:R]->{,2}(b) RETURN b.k AS k ORDER BY k", .cypher = "MATCH (a:S6564Q {k: 0})-[:R*0..2]->(b) RETURN b.k AS k ORDER BY k", .want = &.{ 0, 1, 2 } },
            .{ .iso = "MATCH (a:S6564Q {k: 3})<-[:R]-{1,2}(b) RETURN b.k AS k ORDER BY k", .cypher = "MATCH (a:S6564Q {k: 3})<-[:R*1..2]-(b) RETURN b.k AS k ORDER BY k", .want = &.{ 1, 2 } },
        }) |p| {
            var ri = try s.exec(a, t, p.iso);
            defer ri.deinit(a);
            var rc = try s.exec(a, t, p.cypher);
            defer rc.deinit(a);
            if (ri.error_code != null or rc.error_code != null) {
                std.debug.print("{s} [{s}]: {?s} {?s} / {?s}\n", .{ p.iso, @tagName(t), ri.error_code, ri.error_message, rc.error_code });
                return error.QueryFailed;
            }
            const gi = try ints(a, &ri);
            defer a.free(gi);
            const gc = try ints(a, &rc);
            defer a.free(gc);
            expectInts(p.want, gi) catch |err| {
                std.debug.print("{s} [{s}]: {any}\n", .{ p.iso, @tagName(t), gi });
                return err;
            };
            try expectInts(p.want, gc);
        }
    }
}
