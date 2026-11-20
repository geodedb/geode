// CANARY: REQ=REQ-SONNY-6564-IDENTIFIER-WORDS; FEATURE="GQLParser"; ASPECT=ReservedWords; STATUS=TESTED; TEST=tests/test_sonny6564_identifier_words.zig; OWNER=parser; UPDATED=2026-11-15
//! ISO/IEC 39075:2024 21.3 <token>, <separator>, and <identifier>: the two
//! keyword lists and the rule that separates them (SONNY-6564).
//!
//! 21.3 Format: <keyword> ::= <reserved word> | <non-reserved word>, and
//! <reserved word> ::= <pre-reserved word> | ABS | ACOS | ... (printed pages
//! 438-440). 21.3 Syntax Rule 18: "The case-normal form of a
//! <non-delimited identifier> shall not be equal ... to any <reserved word>";
//! SR 17 defines the case-normal form (each lower-case or title-case
//! character replaced by its upper-case sequence). A <delimited identifier>
//! (21.3: <double quoted character sequence> or <accent quoted character
//! sequence>) is not subject to SR 18, so any word may be written that way.
//!
//! A non-reserved word (TYPE, PROPERTY, NODE, EDGE, ...) is a keyword only
//! where the grammar names it and a valid identifier everywhere else.
//!
//! Geode-only keywords (MERGE, UNWIND, SHOW, EXPLAIN, ...) are in neither
//! list, so 21.3 does not reserve them: they are valid identifiers too.
const std = @import("std");
const unicode = @import("../unicode/unicode_tables.zig");

/// 21.3 <reserved word>, without the <pre-reserved word>s.
pub const reserved_words = [_][]const u8{
    "ABS",               "ACOS",             "ALL",                 "ALL_DIFFERENT",  "AND",                    "ANY",             "ARRAY",
    "AS",                "ASC",              "ASCENDING",           "ASIN",           "AT",                     "ATAN",            "AVG",
    "BIG",               "BIGINT",           "BINARY",              "BOOL",           "BOOLEAN",                "BOTH",            "BTRIM",
    "BY",                "BYTE_LENGTH",      "BYTES",               "CALL",           "CARDINALITY",            "CASE",            "CAST",
    "CEIL",              "CEILING",          "CHAR",                "CHAR_LENGTH",    "CHARACTER_LENGTH",       "CHARACTERISTICS", "CLOSE",
    "COALESCE",          "COLLECT_LIST",     "COMMIT",              "COPY",           "COS",                    "COSH",            "COT",
    "COUNT",             "CREATE",           "CURRENT_DATE",        "CURRENT_GRAPH",  "CURRENT_PROPERTY_GRAPH", "CURRENT_SCHEMA",  "CURRENT_TIME",
    "CURRENT_TIMESTAMP", "DATE",             "DATETIME",            "DAY",            "DEC",                    "DECIMAL",         "DEGREES",
    "DELETE",            "DESC",             "DESCENDING",          "DETACH",         "DISTINCT",               "DOUBLE",          "DROP",
    "DURATION",          "DURATION_BETWEEN", "ELEMENT_ID",          "ELSE",           "END",                    "EXCEPT",          "EXISTS",
    "EXP",               "FALSE",            "FILTER",              "FINISH",         "FLOAT",                  "FLOAT16",         "FLOAT32",
    "FLOAT64",           "FLOAT128",         "FLOAT256",            "FLOOR",          "FOR",                    "FROM",            "GROUP",
    "HAVING",            "HOME_GRAPH",       "HOME_PROPERTY_GRAPH", "HOME_SCHEMA",    "HOUR",                   "IF",              "IMPLIES",
    "IN",                "INSERT",           "INT",                 "INTEGER",        "INT8",                   "INTEGER8",        "INT16",
    "INTEGER16",         "INT32",            "INTEGER32",           "INT64",          "INTEGER64",              "INT128",          "INTEGER128",
    "INT256",            "INTEGER256",       "INTERSECT",           "INTERVAL",       "IS",                     "LEADING",         "LEFT",
    "LET",               "LIKE",             "LIMIT",               "LIST",           "LN",                     "LOCAL",           "LOCAL_DATETIME",
    "LOCAL_TIME",        "LOCAL_TIMESTAMP",  "LOG",                 "LOG10",          "LOWER",                  "LTRIM",           "MATCH",
    "MAX",               "MIN",              "MINUTE",              "MOD",            "MONTH",                  "NEXT",            "NODETACH",
    "NORMALIZE",         "NOT",              "NOTHING",             "NULL",           "NULLS",                  "NULLIF",          "OCTET_LENGTH",
    "OF",                "OFFSET",           "OPTIONAL",            "OR",             "ORDER",                  "OTHERWISE",       "PARAMETER",
    "PARAMETERS",        "PATH",             "PATH_LENGTH",         "PATHS",          "PERCENTILE_CONT",        "PERCENTILE_DISC", "POWER",
    "PRECISION",         "PROPERTY_EXISTS",  "RADIANS",             "REAL",           "RECORD",                 "REMOVE",          "REPLACE",
    "RESET",             "RETURN",           "RIGHT",               "ROLLBACK",       "RTRIM",                  "SAME",            "SCHEMA",
    "SECOND",            "SELECT",           "SESSION",             "SESSION_USER",   "SET",                    "SIGNED",          "SIN",
    "SINH",              "SIZE",             "SKIP",                "SMALL",          "SMALLINT",               "SQRT",            "START",
    "STDDEV_POP",        "STDDEV_SAMP",      "STRING",              "SUM",            "TAN",                    "TANH",            "THEN",
    "TIME",              "TIMESTAMP",        "TRAILING",            "TRIM",           "TRUE",                   "TYPED",           "UBIGINT",
    "UINT",              "UINT8",            "UINT16",              "UINT32",         "UINT64",                 "UINT128",         "UINT256",
    "UNION",             "UNKNOWN",          "UNSIGNED",            "UPPER",          "USE",                    "USMALLINT",       "VALUE",
    "VARBINARY",         "VARCHAR",          "VARIABLE",            "WHEN",           "WHERE",                  "WITH",            "XOR",
    "YEAR",              "YIELD",            "ZONED",               "ZONED_DATETIME", "ZONED_TIME",
};

/// 21.3 <pre-reserved word>: reserved for future editions; a <reserved word>
/// already (<reserved word> ::= <pre-reserved word> | ...).
pub const pre_reserved_words = [_][]const u8{
    "ABSTRACT",     "AGGREGATE",    "AGGREGATES",  "ALTER",     "CATALOG", "CLEAR",   "CLONE",     "CONSTRAINT",
    "CURRENT_ROLE", "CURRENT_USER", "DATA",        "DIRECTORY", "DRYRUN",  "EXACT",   "EXISTING",  "FUNCTION",
    "GQLSTATUS",    "GRANT",        "INSTANT",     "INFINITY",  "NUMBER",  "NUMERIC", "ON",        "OPEN",
    "PARTITION",    "PROCEDURE",    "PRODUCT",     "PROJECT",   "QUERY",   "RECORDS", "REFERENCE", "RENAME",
    "REVOKE",       "SUBSTRING",    "SYSTEM_USER", "TEMPORAL",  "UNIQUE",  "UNIT",    "VALUES",    "WHITESPACE",
};

/// 21.3 <non-reserved word>.
pub const non_reserved_words = [_][]const u8{
    "ACYCLIC",     "BINDING",    "BINDINGS",   "CONNECTING", "DESTINATION", "DIFFERENT", "DIRECTED",     "EDGE",
    "EDGES",       "ELEMENT",    "ELEMENTS",   "FIRST",      "GRAPH",       "GROUPS",    "KEEP",         "LABEL",
    "LABELED",     "LABELS",     "LAST",       "NFC",        "NFD",         "NFKC",      "NFKD",         "NO",
    "NODE",        "NORMALIZED", "ONLY",       "ORDINALITY", "PROPERTY",    "READ",      "RELATIONSHIP", "RELATIONSHIPS",
    "REPEATABLE",  "SHORTEST",   "SIMPLE",     "SOURCE",     "TABLE",       "TEMP",      "TO",           "TRAIL",
    "TRANSACTION", "TYPE",       "UNDIRECTED", "VERTEX",     "WALK",        "WITHOUT",   "WRITE",        "ZONE",
};

const reserved_set = blk: {
    @setEvalBranchQuota(20_000);
    var kvs: [reserved_words.len + pre_reserved_words.len]struct { []const u8 } = undefined;
    for (reserved_words, 0..) |w, i| kvs[i] = .{w};
    for (pre_reserved_words, 0..) |w, i| kvs[reserved_words.len + i] = .{w};
    break :blk std.StaticStringMap(void).initComptime(kvs);
};

const non_reserved_set = blk: {
    @setEvalBranchQuota(5_000);
    var kvs: [non_reserved_words.len]struct { []const u8 } = undefined;
    for (non_reserved_words, 0..) |w, i| kvs[i] = .{w};
    break :blk std.StaticStringMap(void).initComptime(kvs);
};

/// SONNY-6564: the reserved words Geode still takes as an unquoted variable,
/// alias or parameter name: a documented non-conformance with 21.3 SR 18
/// (docs/GQL_COMPLIANCE.md "Reserved words"). Each is a column Geode's own
/// procedures yield, so `YIELD` binds it: PATH (`algo.bfs.stream`,
/// `algo.dfs.stream`, `algo.shortestPath.dijkstra`, the recursive path
/// procedures; src/execution/algo_dispatch.zig, recursion_handler.zig),
/// VALUE and AVG (`geode.ts.range` / `last` / `sample_by`, `bucket_avg`;
/// src/execution/ts_dispatch.zig), COUNT (src/execution/rls_dispatch.zig,
/// storage_dispatch.zig) and TIMESTAMP (storage_dispatch.zig). They are also
/// the words most used that way: of 14,410 queries in Geode's tests, docs
/// and the integration specs, 123 of the 260 a strict rule refused used one
/// (PATH 56, VALUE 41, COUNT 20, AVG 4, TIMESTAMP 2). Each stays
/// unambiguous: a call needs `(`, `COUNT { }` and `VALUE { }` a brace, a
/// typed literal a string, and a path search prefix never starts with PATH.
pub const geode_binding_extension = [_][]const u8{ "AVG", "COUNT", "PATH", "TIMESTAMP", "VALUE" };

/// The longest keyword, CURRENT_PROPERTY_GRAPH.
const max_keyword_len: usize = 22;

/// The case-normal form (21.3 SR 17) of `word` in `buf`, or null when it is
/// longer than any keyword (and so equals none).
fn caseNormalForm(word: []const u8, buf: *[max_keyword_len]u8) ?[]const u8 {
    var n: usize = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = word, .i = 0 };
    while (it.nextCodepoint()) |cp| {
        const upper = unicode.toUpperCase(cp);
        // Every keyword is ASCII; a character whose upper case is not
        // cannot be part of one.
        if (upper > 0x7f) return null;
        if (n == max_keyword_len) return null;
        buf[n] = @intCast(upper);
        n += 1;
    }
    return buf[0..n];
}

/// 21.3 SR 18: `word`, written as a <non-delimited identifier>, is a
/// <reserved word> (or a <pre-reserved word>) and so is not an identifier.
pub fn isReservedWord(word: []const u8) bool {
    var buf: [max_keyword_len]u8 = undefined;
    const cnf = caseNormalForm(word, &buf) orelse return false;
    return reserved_set.has(cnf);
}

/// `word` is a 21.3 <non-reserved word>: a keyword only where the grammar
/// names it, an identifier everywhere else.
pub fn isNonReservedWord(word: []const u8) bool {
    var buf: [max_keyword_len]u8 = undefined;
    const cnf = caseNormalForm(word, &buf) orelse return false;
    return non_reserved_set.has(cnf);
}

/// SONNY-6564: `word`, unquoted, cannot name a variable, alias or parameter:
/// a 21.3 reserved word Geode does not keep (`geode_binding_extension`).
pub fn isRefusedBindingName(word: []const u8) bool {
    var buf: [max_keyword_len]u8 = undefined;
    const cnf = caseNormalForm(word, &buf) orelse return false;
    if (!reserved_set.has(cnf)) return false;
    for (geode_binding_extension) |w| {
        if (std.mem.eql(u8, cnf, w)) return false;
    }
    return true;
}
