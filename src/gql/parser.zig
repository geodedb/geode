// CANARY: REQ=REQ-0001; FEATURE="Standards & Conformance Requirements"; ASPECT=Compliance; STATUS=TESTED; TEST=tests/e2e_protocol.zig; OWNER=core; UPDATED=2026-01-15
// CANARY: REQ=REQ-0002; FEATURE="Language Surface Requirements"; ASPECT=Compliance; STATUS=TESTED; TEST=tests/e2e_protocol.zig; OWNER=core; UPDATED=2026-01-15
// CANARY: REQ=REQ-GQL-006; FEATURE="GQL Parser"; ASPECT=Parser; STATUS=TESTED; TEST=tests/e2e_protocol.zig; OWNER=parser; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-007; FEATURE="MATCH/OPTIONAL Parsing"; ASPECT=Parser; STATUS=TESTED; TEST=tests/e2e_graph_match.zig; OWNER=parser; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-008; FEATURE="ORDER/LIMIT/OFFSET Parsing"; ASPECT=Parser; STATUS=TESTED; TEST=tests/e2e_protocol.zig; OWNER=parser; UPDATED=2025-09-20

const std = @import("std");
const builtin = @import("builtin");
const tok = @import("gql_lib").token;
const ast = @import("ast.zig");
const temporal = @import("../temporal.zig");
const Lexer = @import("lexer.zig").Lexer;
const stack_guard = @import("../stack_guard.zig");

// CANARY: REQ=REQ-SONNY-3133-PARSER-NESTING; FEATURE="GQLParser"; ASPECT=StackGuard; STATUS=TESTED; TEST=tests/test_sonny3133_parser_nesting.zig; OWNER=parser; UPDATED=2026-09-27
/// SONNY-3133: how much of the calling thread's stack must be left for the
/// parser to go one nesting level deeper: the frames it can descend between
/// two `enterRecursion` calls (a statement and the query it holds, about
/// 0.7 MiB in a Debug build), with room to spare. The nesting limits below
/// hold on the server's 16 MiB QUIC workers (GAP-0333); the gRPC connection
/// threads have 8 MiB, and other callers (the CLI's main thread, a library
/// user's) whatever they have. Measured, a limit cannot overflow any of them.
///
/// SONNY-3191 (N-6): a Debug build's frames are several times a release
/// build's, and a WITH, CALL { } or FOR level costs about 0.2 MiB there: on
/// the gRPC connection threads' 8 MiB a Debug build refuses (42000) such
/// chains past about 25 levels, where a release build takes 128. No margin
/// buys 64 Debug levels on 8 MiB (64 x 0.2 MiB is over 8 MiB), so the limit
/// is Debug-only and documented, not tuned; the QUIC workers' 16 MiB hold
/// about twice as many (tests/test_sonny3191_round13_items.zig pins it).
const stack_reserve_bytes: usize = if (builtin.mode == .Debug) 2 * 1024 * 1024 else 512 * 1024;

/// SONNY-3133: is more than `stack_reserve_bytes` of the calling thread's
/// stack left below this frame? True when the bounds are unknown, or when
/// this frame is not on the thread's stack (a fiber's). SONNY-3181: the
/// bounds lookup is `stack_guard`'s, which the evaluator shares.
fn stackHasRoom() bool {
    return stack_guard.hasRoomBelow(@frameAddress(), stack_reserve_bytes);
}

/// SONNY-3133: statements nested in statements (EXPLAIN, EXPLAIN POLICY FOR,
/// PROFILE, a START TRANSACTION body, a parenthesized statement, a VALUES
/// continuation). A statement's frames are the parser's largest, about
/// 0.3 MiB each in a Debug build: 64 of them overflowed a 16 MiB worker stack
/// (review probe R12-X11).
const max_statement_nesting: u16 = 8;

// CANARY: REQ=REQ-SONNY-3181-EXPR-CHAIN-CAP; FEATURE="GQLParser"; ASPECT=ExprLinkCap; STATUS=TESTED; TEST=tests/test_sonny3181_expr_chain_cap.zig; OWNER=parser; UPDATED=2026-09-27
/// SONNY-3181, SONNY-3189: the most operator links one expression may hold.
/// A link is a binary operator (`OR`, `XOR`, `AND`, a comparison, `+`, `-`,
/// `||`, `*`, `/`, `%`, `^`), a unary prefix (`NOT`, `-`, `+`) or a postfix
/// link (member access, index, slice, call, map projection). The count runs
/// over the whole outermost expression, the expressions nested in it
/// included (list items, arguments, CASE branches, subqueries), and a WHERE
/// that later MATCH clauses extend with AND counts as one expression.
///
/// The loops of the expression grammar build operator and postfix chains as
/// long as the input: `1 + 1 + ... + 1` with N terms is an AST N deep, and
/// the analysis, printing and evaluation that walk it recursed once per link
/// (on the pre-auth request path, too). 100,000 terms, about 400 KB of
/// query, overflowed an 8 MiB thread in ReleaseSafe, 1,000 terms a Debug
/// one. With the cap an expression's AST is at most this many links plus
/// the 128 levels of nesting `enterRecursion` allows, and the walkers that
/// still recurse stay far inside a thread's stack.
///
/// An `IN [...]` list is not a chain: its items are expressions of their
/// own, and literal items have no links. A WHERE of a few hundred OR terms
/// (`n.v = 1 OR n.v = 2 ...`, three links a term) fits; a generated query
/// that needs more splits its predicate into an IN list or parameters.
/// Past the cap the parser answers 42000.
pub const max_expr_links: u32 = 4096;

pub const Parser = struct {
    lx: *Lexer,
    arena: *std.heap.ArenaAllocator,
    cur: tok.Token,
    // Optional: when true, ORDER BY keys must be simple identifiers or member chains.
    strict_order_keys: bool = false,
    // Optional: when true, ORDER BY keys must be identifiers only (no member chains).
    ident_order_only: bool = false,
    // Optional: when true, function calls are forbidden in ORDER BY expressions.
    forbid_orderby_calls: bool = false,
    // Optional: when true, path aliases are forbidden in ORDER BY keys.
    forbid_orderby_paths: bool = false,
    // Track if ordinal sort keys are used
    has_ordinal_sort_key: bool = false,
    // Track if UNWIND (non-standard GQL) syntax is used
    has_unwind: bool = false,
    // TS extensions (SERIES UDFs) allowed when true
    ts_extensions: bool = false,
    // SONNY-3244: statements parsed so far (every one, nested ones too), and
    // how many queries the one being parsed is nested in (`limits`).
    statement_count: usize = 0,
    query_depth: u16 = 0,
    tokens_since_memory_check: u32 = 0,
    parse_memory_exceeded: bool = false,
    // Last error context message (static or source-backed slice).
    last_error: ?[]const u8 = null,
    // Path alias names collected from the last parsed graph pattern (MATCH or pattern comprehension).
    path_aliases: std.ArrayList([]const u8) = undefined,
    // Whether parseGraphPattern should record chain aliases into path_aliases.
    collect_chain_aliases: bool = false,
    // Track nesting depth in pattern comprehensions to handle ambiguous | tokens
    pattern_comp_depth: u32 = 0,
    // Track expression recursion depth to prevent stack overflow from deeply nested input
    recursion_depth: u16 = 0,
    // SONNY-3133: statements nested in the one being parsed.
    statement_depth: u16 = 0,
    // SONNY-3181: operator links in the outermost expression being parsed
    // (`max_expr_links`), and how many expressions deep the parser is (0
    // outside any expression; the count restarts at the next outermost one).
    expr_links: u32 = 0,
    expr_nesting: u32 = 0,

    // GAP-0333: The hard limit is 128 user-visible nested parens.  The internal
    // counter includes the outer parseOrExpr frame invoked by RETURN/MATCH, so
    // 128 parens drives recursion_depth to 129. Allow a small headroom so the
    // user-visible 128-deep input parses successfully; 129+ still errors out.
    //
    // CANARY: REQ=REQ-SONNY-3133-PARSER-NESTING; FEATURE="GQLParser"; ASPECT=DepthGuard; STATUS=TESTED; TEST=tests/test_sonny3133_parser_nesting.zig; OWNER=parser; UPDATED=2026-09-27
    // SONNY-3133: every recursive entry of the parser passes here, not only
    // the expression grammar's: the statements a PROFILE, EXPLAIN, START
    // TRANSACTION body, parenthesized statement or VALUES holds
    // (`parseNestedStatement`), the queries a WITH chain, CALL { } or FOR
    // holds (`parseNestedQuery`), NOT, unary minus and plus, and
    // shortestPath(). And a level is refused when the thread's stack is
    // nearly used up (`stackHasRoom`), whatever the count: the frames differ
    // several-fold between the recursions and between build modes.
    fn enterRecursion(self: *Parser) ParserError!void {
        self.recursion_depth += 1;
        errdefer self.recursion_depth -= 1;
        if (self.recursion_depth > 129) {
            return self.unexpected("nesting depth exceeds maximum (128)");
        }
        if (!stackHasRoom()) {
            return self.unexpected("nesting too deep for the parser's stack");
        }
    }

    fn leaveRecursion(self: *Parser) void {
        self.recursion_depth -= 1;
    }

    /// SONNY-3133: a statement nested in the one being parsed. At most
    /// `max_statement_nesting` deep, and a level of `enterRecursion`.
    fn parseNestedStatement(self: *Parser) ParserError!ast.Statement {
        try self.enterRecursion();
        defer self.leaveRecursion();
        self.statement_depth += 1;
        defer self.statement_depth -= 1;
        if (self.statement_depth > max_statement_nesting) {
            return self.unexpected("statement nesting depth exceeds maximum (8)");
        }
        return self.parseStatement();
    }

    /// SONNY-3133: a query nested in the one being parsed: the next part of a
    /// WITH chain, a CALL { } subquery, a FOR body.
    fn parseNestedQuery(self: *Parser) ParserError!ast.Query {
        // SONNY-3244: the fixed query nesting limit answers first (54001),
        // so the depth refused does not depend on the build's frame sizes;
        // the stack guard below stays the backstop.
        if (self.query_depth >= max_query_nesting) {
            self.last_error = "queries may nest at most 10 deep (WITH chain parts, CALL { }, IN (subquery), FOR bodies, CTE bodies)";
            return error.QueryNestingTooDeep;
        }
        try self.enterRecursion();
        defer self.leaveRecursion();
        return self.parseQuery();
    }

    /// SONNY-3181: an expression starts. The outermost one restarts the
    /// link count (`max_expr_links`). Pair with `leaveExpr`.
    fn enterExpr(self: *Parser) void {
        if (self.expr_nesting == 0) self.expr_links = 0;
        self.expr_nesting += 1;
    }

    fn leaveExpr(self: *Parser) void {
        self.expr_nesting -= 1;
    }

    /// SONNY-3181: one more operator link in the expression being parsed
    /// (`max_expr_links`). Links built outside an expression are not
    /// counted here.
    fn countExprLink(self: *Parser) ParserError!void {
        if (self.expr_nesting == 0) return;
        self.expr_links += 1;
        if (self.expr_links > max_expr_links) {
            return self.unexpected("expression too long: more than 4096 operators in one expression (max_expr_links)");
        }
    }

    fn advance(self: *Parser) void {
        self.cur = self.lx.next();
        // SONNY-3244: every 1024 tokens, the parser's memory
        // (`max_parse_arena_bytes`). Past it, the input ends here: the parse
        // stops at once, and `parseProgram` answers ParseMemoryLimit.
        self.tokens_since_memory_check += 1;
        if (self.tokens_since_memory_check >= 1024) {
            self.tokens_since_memory_check = 0;
            if (self.arena.queryCapacity() > max_parse_arena_bytes) self.parse_memory_exceeded = true;
        }
        if (self.parse_memory_exceeded) self.cur.kind = .eof;
    }

    fn peekToken(self: *Parser) tok.TokenKind {
        // Save lexer state
        const saved_idx = self.lx.idx;
        const saved_line = self.lx.line;
        const saved_col = self.lx.col;

        // Get next token
        const next_token = self.lx.next();

        // Restore lexer state
        self.lx.idx = saved_idx;
        self.lx.line = saved_line;
        self.lx.col = saved_col;

        return next_token.kind;
    }

    fn isKeyword(self: *Parser, kind: tok.TokenKind) bool {
        _ = self;
        // Check if the token kind is a keyword (not a delimiter, literal, or identifier)
        return switch (kind) {
            .MATCH,
            .OPTIONAL,
            .WHERE,
            .RETURN,
            .WITH,
            .CASE,
            .WHEN,
            .THEN,
            .ELSE,
            .END,
            .AND,
            .OR,
            .NOT,
            .IN,
            .IS,
            .STARTS,
            .ENDS,
            .CONTAINS,
            .CALL,
            .YIELD,
            .TRUE,
            .FALSE,
            .NULL,
            .AS,
            .DISTINCT,
            .UNION,
            .INTERSECT,
            .EXCEPT,
            .ALL,
            .SESSION,
            .SET,
            .RESET,
            .CLOSE,
            .INSERT,
            .VALUE,
            .VALUES, // Re-added to allow values() function calls in expression context
            .SCAN,
            .START,
            .TRANSACTION,
            .COMMIT,
            .ROLLBACK,
            .CREATE,
            .DELETE,
            .MERGE,
            .GRAPH,
            .PROPERTY,
            .DROP,
            .ORDER,
            .BY,
            .GROUP,
            .ASC,
            .DESC,
            .LIMIT,
            .OFFSET,
            .SKIP,
            .HAVING,
            .NULLS,
            .FIRST,
            .LAST,
            .ON,
            .UNKNOWN,
            .FILTER,
            .LET,
            .SELECT,
            .FROM,
            .EXISTS,
            .DETACH,
            .REMOVE,
            .FOR,
            .FOREACH,
            .UNWIND,
            .USE,
            .USING,
            .INDEX,
            .JOIN,
            .IF,
            .TO,
            .KEY,
            // .KEYS - Removed from reserved keywords to allow keys() function calls
            .LABELS,
            .LOAD,
            .CSV,
            .PERIODIC,
            .PROPERTIES,
            .RELATIONSHIPS,
            .START_NODE,
            .END_NODE,
            .TYPE,
            .TYPES,
            // Critical missing ISO GQL keywords (avoiding duplicates)
            .ACYCLIC,
            .AGGREGATE,
            .ANY,
            .AVG,
            .CATALOG,
            .CAST,
            .CONSTRAINT,
            .COUNT,
            .CURRENT,
            .DIFFERENT,
            .DURATION,
            .EDGES,
            .ELEMENT,
            .FINISH,
            .HOME,
            .LABELED,
            .LIKE,
            .LIST,
            .MAX,
            .MIN,
            .NEXT,
            .NODE,
            .OF,
            .OTHERWISE,
            .PATH,
            .PATHS,
            .RECORD,
            .REPEATABLE,
            .REPLACE,
            .SCHEMA,
            .SHORTEST,
            .SIMPLE,
            .SUM,
            .TABLE,
            .TRAIL,
            .WALK,
            .XOR,
            .ZONED,
            .ZONE,
            .ORDINALITY,
            // Temporal type keywords - used as function names (e.g., date('2024-01-15'))
            .DATE,
            .TIME,
            .DATETIME,
            .TIMESTAMP,
            // Type name keywords - commonly used as identifiers
            .BOOLEAN,
            .DECIMAL,
            .FLOAT,
            .INTEGER,
            .STRING,
            // Additional keywords that may appear as identifiers
            .ASSERT,
            .BEGIN,
            .BINDING,
            .BINDINGS,
            .EXPLAIN,
            .LOCAL,
            .NO,
            .ONLY,
            .PROFILE,
            .READ,
            .REQUIRE,
            .SHOW,
            .WRITE,
            => true,
            else => false,
        };
    }

    fn peekKind(self: *Parser) tok.TokenKind {
        var tmp = self.lx.*;
        const tkn = tmp.next();
        return tkn.kind;
    }

    fn peek2Kind(self: *Parser) tok.TokenKind {
        var tmp = self.lx.*;
        _ = tmp.next();
        const t2 = tmp.next();
        return t2.kind;
    }

    fn expect(self: *Parser, kind: tok.TokenKind) !tok.Token {
        if (self.cur.kind != kind) {
            self.last_error = std.fmt.allocPrint(
                self.arena.allocator(),
                "expected token '{s}', got '{s}' at line {d} col {d}",
                .{ @tagName(kind), @tagName(self.cur.kind), self.cur.loc.line, self.cur.loc.column },
            ) catch @tagName(kind);
            return error.UnexpectedToken;
        }
        const out = self.cur;
        self.advance();
        return out;
    }

    // Helper function to accept identifiers or keywords as identifiers (for aliases, etc.)
    // CANARY: REQ=REQ-GQL-001; FEATURE="KeywordsAsIdentifiers"; ASPECT=ParserSupport; STATUS=TESTED; OWNER=parser; UPDATED=2025-10-09
    // Per ISO/IEC 39075:2024, keywords can be used as identifiers in most contexts (aliases, variable names, property names, labels)
    fn expectIdentifierOrKeyword(self: *Parser) !tok.Token {
        if (self.cur.kind == .identifier or self.isKeyword(self.cur.kind)) {
            const out = self.cur;
            self.advance();
            return out;
        }
        self.last_error = std.fmt.allocPrint(
            self.arena.allocator(),
            "expected identifier or keyword, got '{s}' at line {d} col {d}",
            .{ @tagName(self.cur.kind), self.cur.loc.line, self.cur.loc.column },
        ) catch "identifier";
        return error.UnexpectedToken;
    }

    // Parser operations can fail due to syntax or allocation issues.
    // We’ll thread a tiny error wrapper with a message alongside generic errors when needed.
    // ENG-3906: `UnknownIndexParameter` — a WITH parameter a vector index does
    // not implement. Distinct from `UnexpectedToken` so the diagnostic can say
    // "this knob does not exist" rather than "syntax error".
    const ParserError = error{ UnexpectedToken, OutOfMemory, Overflow, InvalidCharacter, InvalidIndexType, UnknownIndexParameter, UnknownIndexOption, UnsupportedAggregateFunction, TooManyWriteClauses, TooManyStatements, ParseMemoryLimit, QueryNestingTooDeep };

    // CANARY: REQ=REQ-SONNY-3190-CLAUSE-CAP; FEATURE="WriteClauseCap"; ASPECT=Parser; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist.zig; OWNER=parser; UPDATED=2026-09-27
    /// SONNY-3190: the most SET, REMOVE, CREATE and MERGE clauses one query
    /// part (or one CREATE or MERGE statement) may carry. Each clause is
    /// appended to one list, so parsing stays linear; the cap bounds the
    /// memory a request can make the parser hold before authorization.
    pub const max_write_clauses_per_part: usize = 1024;

    /// SONNY-3190: count one more write clause of the part being parsed.
    fn countWriteClause(self: *Parser, count: *usize) ParserError!void {
        count.* += 1;
        if (count.* > max_write_clauses_per_part) {
            self.last_error = "a query part may carry at most 1024 SET, REMOVE, CREATE and MERGE clauses";
            return error.TooManyWriteClauses;
        }
    }

    // CANARY: REQ=REQ-SONNY-3244-PARSE-LIMITS; FEATURE="ParseLimits"; ASPECT=Parser; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4.zig; OWNER=parser; UPDATED=2026-09-28
    /// SONNY-3244: the most statements one request may carry, counting the
    /// ones nested in others (a transaction body's, the statement a PROFILE
    /// wraps). Parsing runs before authorization: 25,000 `MATCH ... SET ...;`
    /// statements (625 KB) took a 741 MB parser arena, so a 16 MB request
    /// could hold about 19 GB. 54000 (program limit exceeded).
    pub const max_statements_per_request: usize = 1024;

    /// SONNY-3244: the most memory the parser may hold for one request (its
    /// arena's capacity, checked every 1024 tokens, at every statement and
    /// query part, and at the end). The arena grows by whole blocks, so a
    /// request refused here held at most about twice this, briefly, mostly
    /// untouched. 54000 (program limit exceeded).
    pub const max_parse_arena_bytes: usize = 64 * 1024 * 1024;

    /// SONNY-3244: how deep queries may nest in queries: the parts of a WITH
    /// chain (each WITH ... MATCH starts a part inside the last), a CALL { }
    /// subquery, an IN / NOT IN (subquery), a FOR body, a CTE body. Each level
    /// is a parseQuery frame, the parser's largest: 60 chained WITH overflowed
    /// a Debug build (round-3 review I8). Past it: 54001 (statement too
    /// complex). Measured (tests/test_sonny_write_allowlist_r4.zig and the
    /// round 4a report), a fresh thread overflows at these depths:
    ///   Debug,       8 MiB:  FOR body 16, IN (subquery) 19, WITH / CALL { } 22;
    ///   Debug,      16 MiB:  FOR body 35, IN 41, WITH / CALL { } 45;
    ///   ReleaseSafe, 8 MiB:  FOR body 156, WITH / CALL { } 182 (IN stops at
    ///                        the expression depth limit, 128, first);
    ///   ReleaseSafe, 1 MiB:  FOR body 12, IN 11, WITH 15.
    /// 10 holds on the server's request threads (the QUIC workers' 16 MiB, the
    /// gRPC connection threads' 8 MiB) in both builds, with room for the
    /// handler's own frames below the parser. (A 1 MiB QUIC admission thread
    /// overflowed a Debug build on any nesting at all; SONNY-3191 and
    /// SONNY-3253 give those threads 16 MiB in Debug, 8 MiB in a release
    /// build.)
    pub const max_query_nesting: u16 = 10;

    /// SONNY-3244: count one more statement, and check the parser's memory.
    fn countStatement(self: *Parser) ParserError!void {
        self.statement_count += 1;
        if (self.statement_count > max_statements_per_request) {
            self.last_error = "a request may carry at most 1024 statements";
            return error.TooManyStatements;
        }
        try self.checkParseMemory();
    }

    /// SONNY-3244: refuse once the parser's arena holds more than
    /// `max_parse_arena_bytes`.
    fn checkParseMemory(self: *Parser) ParserError!void {
        if (self.parse_memory_exceeded or self.arena.queryCapacity() > max_parse_arena_bytes) {
            self.parse_memory_exceeded = true;
            self.last_error = "parsing the request needs more than 64 MiB";
            return error.ParseMemoryLimit;
        }
    }

    /// SONNY-3244: enter one more level of query nesting.
    fn enterQuery(self: *Parser) ParserError!void {
        self.query_depth += 1;
        if (self.query_depth > max_query_nesting) {
            self.query_depth -= 1;
            self.last_error = "queries may nest at most 10 deep (WITH chain parts, CALL { }, IN (subquery), FOR bodies, CTE bodies)";
            return error.QueryNestingTooDeep;
        }
        self.checkParseMemory() catch |err| {
            self.query_depth -= 1;
            return err;
        };
    }

    /// Read an object name: an identifier or a quoted identifier.
    fn parseName(self: *Parser) ParserError![]const u8 {
        if (self.cur.kind == .quoted_identifier or self.cur.kind == .identifier) {
            const out = self.cur.lexeme;
            self.advance();
            return out;
        }
        return self.unexpected("expected a name (identifier)");
    }

    /// Read a quoted string literal (returns the lexeme per existing lexer behavior).
    fn parseStringLit(self: *Parser) ParserError![]const u8 {
        if (self.cur.kind != .string_lit) return self.unexpected("expected a quoted string literal");
        const out = self.cur.lexeme;
        self.advance();
        return out;
    }

    /// True if the current token is an identifier whose text equals `kw` (case-insensitive).
    fn softKw(self: *Parser, kw: []const u8) bool {
        return self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, kw);
    }

    fn unexpected(self: *Parser, what: []const u8) ParserError {
        // For now, we just return UnexpectedToken; callers like CLI can add context using 'what'.
        self.last_error = what;
        return error.UnexpectedToken;
    }

    // CANARY: REQ=REQ-UNSUPPORTED-AGGREGATE-REJECTION; FEATURE="AggregateSetQuantifier"; ASPECT=UnsupportedAggregateReject; STATUS=TESTED; TEST=tests/test_unsupported_aggregates.zig; OWNER=parser; UPDATED=2026-08-25
    /// Refuse a recognised-but-unimplemented aggregate, quoting the name the
    /// user wrote so the diagnostic is actionable.
    fn unsupportedAggregate(self: *Parser, name: []const u8) ParserError {
        self.last_error = std.fmt.allocPrint(
            self.arena.allocator(),
            "aggregate function '{s}' is not supported: this engine implements count, sum, avg, min, max and collect",
            .{name},
        ) catch "aggregate function is not supported: this engine implements count, sum, avg, min, max and collect";
        return error.UnsupportedAggregateFunction;
    }

    /// Parse a LIMIT or OFFSET value: accepts either an integer literal or a $param reference.
    /// Returns .{ literal_value_or_null, param_name_or_null }.
    fn parseLimitValue(self: *Parser) !struct { value: ?u64, param: ?[]const u8 } {
        if (self.cur.kind == .dollar) {
            self.advance();
            // Accept both named ($param) and positional ($1) parameters
            if (self.cur.kind == .integer_lit) {
                const name = self.cur;
                self.advance();
                return .{ .value = null, .param = name.lexeme };
            }
            const name = try self.expectIdentifierOrKeyword();
            return .{ .value = null, .param = name.lexeme };
        }
        const lim_tok = try self.expect(.integer_lit);
        return .{ .value = try std.fmt.parseInt(u64, lim_tok.lexeme, 10), .param = null };
    }

    fn unescapeString(self: *Parser, raw: []const u8) ![]const u8 {
        // Check if we need to unescape (contains '' or \)
        var needs_unescape = false;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '\\' or (raw[i] == '\'' and i + 1 < raw.len and raw[i + 1] == '\'')) {
                needs_unescape = true;
                break;
            }
        }
        if (!needs_unescape) return raw;

        // Allocate buffer for unescaped string
        var result = try self.arena.allocator().alloc(u8, raw.len);
        var write_idx: usize = 0;
        i = 0;
        while (i < raw.len) {
            if (raw[i] == '\'') {
                // Check for doubled single quote ('')
                if (i + 1 < raw.len and raw[i + 1] == '\'') {
                    result[write_idx] = '\'';
                    write_idx += 1;
                    i += 2; // Skip both quotes
                    continue;
                }
            } else if (raw[i] == '\\' and i + 1 < raw.len) {
                // Handle backslash escapes
                i += 1;
                result[write_idx] = switch (raw[i]) {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    '\\' => '\\',
                    '\'' => '\'',
                    '"' => '"',
                    else => raw[i], // Unknown escape, keep as-is
                };
                write_idx += 1;
                i += 1;
                continue;
            }
            result[write_idx] = raw[i];
            write_idx += 1;
            i += 1;
        }
        return result[0..write_idx];
    }

    /// Result of parsing ORDER BY key modifiers (ASC/DESC, NULLS FIRST/LAST)
    const OrderKeyModifiers = struct {
        desc: bool,
        nulls: ast.OrderBy.NullsPolicy,
    };

    // CANARY: REQ=REQ-NESTING-REFACTOR-025; FEATURE="NestingReduction"; ASPECT=OrderByParsing; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
    /// Parses ORDER BY key modifiers (ASC/DESC and NULLS FIRST/LAST).
    /// Extracted to reduce code duplication and nesting in ORDER BY parsing.
    fn parseOrderKeyModifiers(self: *Parser) ParserError!OrderKeyModifiers {
        var desc = false;
        if (self.cur.kind == .ASC) {
            desc = false;
            self.advance();
        } else if (self.cur.kind == .DESC) {
            desc = true;
            self.advance();
        }

        var nulls: ast.OrderBy.NullsPolicy = .default;
        if (self.cur.kind == .NULLS) {
            self.advance();
            if (self.cur.kind == .FIRST) {
                nulls = .first;
                self.advance();
            } else if (self.cur.kind == .LAST) {
                nulls = .last;
                self.advance();
            } else return self.unexpected("expected FIRST/LAST after NULLS");
        }

        return .{ .desc = desc, .nulls = nulls };
    }

    pub fn parseProgram(self: *Parser) ParserError!ast.Program {
        // SONNY-3244: a parse cut short by `max_parse_arena_bytes` (`advance`)
        // is refused as such, whatever the truncated input parsed as.
        const program = self.parseProgramInner() catch |err| {
            if (self.parse_memory_exceeded) {
                self.last_error = "parsing the request needs more than 64 MiB";
                return error.ParseMemoryLimit;
            }
            return err;
        };
        // The last tokens' allocations, too.
        if (self.parse_memory_exceeded or self.arena.queryCapacity() > max_parse_arena_bytes) {
            self.last_error = "parsing the request needs more than 64 MiB";
            return error.ParseMemoryLimit;
        }
        return program;
    }

    fn parseProgramInner(self: *Parser) ParserError!ast.Program {
        // initialize alias set arraylist
        self.path_aliases = std.ArrayList([]const u8).empty;
        var list = std.ArrayList(ast.Statement).empty;

        // GAP-0082: Parse CTEs if WITH keyword present at program start
        // CANARY: REQ=REQ-GQL-CTE-002; FEATURE="CTEParsing"; ASPECT=ParserProgram; STATUS=TESTED; TEST=geodetestlab/specs/recursive_and_cte.yml; OWNER=parser; UPDATED=2026-01-10
        var cte_list: ?ast.CTEList = null;
        if (self.cur.kind == .WITH) {
            // Check if this is a CTE (WITH name AS (...)) vs projection (WITH expr AS alias)
            // CTEs have: WITH identifier AS ( or WITH RECURSIVE identifier AS (
            // Projections have: WITH function(...) AS alias or WITH expr AS alias
            var tmp = self.lx.*;
            const next_tok = tmp.next();
            const is_recursive = next_tok.kind == .identifier and std.ascii.eqlIgnoreCase(next_tok.lexeme, "RECURSIVE");
            const check_tok = if (is_recursive) tmp.next() else next_tok;

            // Check for CTE pattern: identifier AS ( (not just identifier followed by AS)
            // We need to distinguish:
            //   CTE: WITH cte_name AS (SELECT...) - identifier followed by AS then (
            //   Projection: WITH date('...') AS d - function call followed by AS then identifier
            const is_cte = check_tok.kind == .identifier and blk: {
                const peek = tmp.next();
                if (peek.kind == .AS) {
                    // Check if AS is followed by ( which indicates CTE body
                    const after_as = tmp.next();
                    break :blk after_as.kind == .l_paren;
                } else if (peek.kind == .l_paren) {
                    // Could be CTE with column list: WITH name(col1, col2) AS (...)
                    // Skip to closing paren and check for AS (
                    var depth: u32 = 1;
                    while (depth > 0) {
                        const inner_tok = tmp.next();
                        if (inner_tok.kind == .l_paren) depth += 1;
                        if (inner_tok.kind == .r_paren) depth -= 1;
                        if (inner_tok.kind == .eof) break :blk false;
                    }
                    const after_paren = tmp.next();
                    if (after_paren.kind == .AS) {
                        const after_as = tmp.next();
                        break :blk after_as.kind == .l_paren;
                    }
                    break :blk false;
                } else {
                    break :blk false;
                }
            };

            if (is_cte) {
                cte_list = try self.parseCTEList();
            }
        }

        while (self.cur.kind != .eof) {
            const st = try self.parseStatement();
            // If we parsed CTEs, attach them to Query statements
            if (cte_list) |ctes| {
                switch (st) {
                    .Query => |q| {
                        var q_mut = q;
                        q_mut.cte_list = ctes;
                        q_mut.has_recursive_cte = ctes.has_recursive;
                        try list.append(self.arena.allocator(), .{ .Query = q_mut });
                        try self.endStatement(.eof);
                        // Clear cte_list after attaching to first query
                        cte_list = null;
                        continue;
                    },
                    .Union => |u| {
                        // Attach to union's first query
                        var u_mut = u;
                        var first_mut = u_mut.first;
                        first_mut.cte_list = ctes;
                        first_mut.has_recursive_cte = ctes.has_recursive;
                        u_mut.first = first_mut;
                        try list.append(self.arena.allocator(), .{ .Union = u_mut });
                        try self.endStatement(.eof);
                        cte_list = null;
                        continue;
                    },
                    else => {},
                }
            }
            try list.append(self.arena.allocator(), st);
            // ISO/IEC 39075 §10.3: `USE [GRAPH] g <statement>` is one focused
            // statement; the USE needs no ';' before the statement it scopes.
            if (st == .UseGraph and self.cur.kind != .semicolon) continue;
            try self.endStatement(.eof);
        }
        return .{ .statements = try list.toOwnedSlice(self.arena.allocator()) };
    }

    // CANARY: REQ=REQ-SONNY-3166-STATEMENT-BOUNDARY; FEATURE="StatementBoundary"; ASPECT=Parser; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist.zig; OWNER=parser; UPDATED=2026-09-27
    /// A CREATE or MERGE that continues a query after a WITH, as a query part.
    fn parseWriteContinuation(self: *Parser) ParserError!*ast.Query {
        const next_ptr = try self.arena.allocator().create(ast.Query);
        if (self.cur.kind == .MERGE) {
            const merge_stmt = try self.parseMergeStatement();
            const merge_ptr = try self.arena.allocator().create(ast.MergeStatement);
            merge_ptr.* = merge_stmt.Merge;
            next_ptr.* = .{
                .optional_match = false,
                .match = .{ .chains = &.{} },
                .where_clause = null,
                .with_clause = null,
                .ret = merge_stmt.Merge.return_clause orelse .{ .items = &.{}, .distinct = false },
                .order_by = null,
                .limit = null,
                .offset = null,
                .merge_statement = merge_ptr,
            };
        } else {
            next_ptr.* = try self.parseQuery();
        }
        return next_ptr;
    }

    /// SONNY-3166: a statement ends at a `;` or where its enclosing text ends
    /// (`close`: the end of the request, or the `}` of a transaction body).
    /// Any other token after a statement is a syntax error. The parser split
    /// `MATCH (q) SET q.x = 1 DETACH DELETE q` in two where a clause it did not
    /// take in the first statement began, and ran the rest as a statement of
    /// its own, with the first one's variables unbound: the DELETE was
    /// dropped, `... MATCH (q:Q) DELETE q` deleted every :Q, and a trailing
    /// CREATE created unlinked nodes.
    fn endStatement(self: *Parser, comptime close: tok.TokenKind) ParserError!void {
        if (self.cur.kind == .semicolon) {
            self.advance();
            return;
        }
        if (self.cur.kind == close) return;
        return self.unexpected("a statement ends at ';' or at the end of the request; this clause cannot follow the one before it");
    }

    /// GAP-0082: Parse WITH [RECURSIVE] cte_name [(col1, col2)] AS (query) [, cte_name2 AS (query2)]
    /// CANARY: REQ=REQ-GQL-CTE-003; FEATURE="CTEListParsing"; ASPECT=Parser; STATUS=TESTED; TEST=geodetestlab/specs/recursive_and_cte.yml; OWNER=parser; UPDATED=2026-01-10
    fn parseCTEList(self: *Parser) ParserError!ast.CTEList {
        _ = self.expect(.WITH) catch return error.UnexpectedToken;

        var is_recursive = false;
        // Check for RECURSIVE keyword
        if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "RECURSIVE")) {
            is_recursive = true;
            self.advance();
        }

        var ctes = std.ArrayList(ast.CommonTableExpression).empty;
        const any_recursive = is_recursive;

        // Parse first CTE
        const first_cte = try self.parseSingleCTE(is_recursive);
        try ctes.append(self.arena.allocator(), first_cte);

        // Parse additional CTEs separated by commas
        while (self.cur.kind == .comma) {
            self.advance(); // consume comma
            const cte = try self.parseSingleCTE(is_recursive);
            try ctes.append(self.arena.allocator(), cte);
        }

        return ast.CTEList{
            .ctes = try ctes.toOwnedSlice(self.arena.allocator()),
            .has_recursive = any_recursive,
        };
    }

    /// Parse a single CTE: name [(col1, col2)] AS (query)
    fn parseSingleCTE(self: *Parser, is_recursive_context: bool) ParserError!ast.CommonTableExpression {
        // Parse CTE name
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const cte_name = self.cur.lexeme;
        self.advance();

        // Optional column list: (col1, col2, ...)
        var column_names: ?[]const []const u8 = null;
        if (self.cur.kind == .l_paren) {
            self.advance();
            var cols = std.ArrayList([]const u8).empty;
            if (self.cur.kind == .identifier) {
                try cols.append(self.arena.allocator(), self.cur.lexeme);
                self.advance();
                while (self.cur.kind == .comma) {
                    self.advance();
                    if (self.cur.kind != .identifier) return error.UnexpectedToken;
                    try cols.append(self.arena.allocator(), self.cur.lexeme);
                    self.advance();
                }
            }
            _ = self.expect(.r_paren) catch return error.UnexpectedToken;
            if (cols.items.len > 0) {
                column_names = try cols.toOwnedSlice(self.arena.allocator());
            }
        }

        // Expect AS
        _ = self.expect(.AS) catch return error.UnexpectedToken;

        // Expect opening paren for CTE body
        _ = self.expect(.l_paren) catch return error.UnexpectedToken;

        // Parse the CTE body - this could be a simple query or anchor UNION recursive
        // For recursive CTEs, we need to detect UNION within the body
        const body = try self.parseCTEBody(is_recursive_context, cte_name);

        // Expect closing paren
        _ = self.expect(.r_paren) catch return error.UnexpectedToken;

        return ast.CommonTableExpression{
            .name = cte_name,
            .is_recursive = is_recursive_context and body == .recursive,
            .column_names = column_names,
            .body = body,
        };
    }

    /// Parse CTE body - detect if it's anchor UNION recursive or simple query
    fn parseCTEBody(self: *Parser, is_recursive_context: bool, cte_name: []const u8) ParserError!ast.CommonTableExpression.CTEBody {
        // Parse first query (could be anchor or full query)
        const first_query = try self.parseQueryForCTE();
        const first_ptr = try self.arena.allocator().create(ast.Query);
        first_ptr.* = first_query;

        // Check for UNION (indicates recursive CTE structure)
        if (is_recursive_context and self.cur.kind == .UNION) {
            self.advance(); // consume UNION
            const union_all = self.cur.kind == .ALL;
            if (union_all) self.advance();

            // Parse recursive term
            const recursive_query = try self.parseQueryForCTE();
            const recursive_ptr = try self.arena.allocator().create(ast.Query);
            recursive_ptr.* = recursive_query;
            // Mark recursive term as referencing the CTE
            _ = cte_name; // CTE reference will be resolved during execution

            return .{
                .recursive = .{
                    .anchor = first_ptr,
                    .recursive_term = recursive_ptr,
                    .union_all = union_all,
                },
            };
        }

        return .{ .simple = first_ptr };
    }

    /// Parse a query within CTE context (limited - no outer set operations)
    fn parseQueryForCTE(self: *Parser) ParserError!ast.Query {
        // Use existing query parsing but without set operations at the top level
        // (set operations within CTE body are handled by parseCTEBody for UNION)
        return self.parseQuery();
    }

    // CANARY: REQ=REQ-GQL-VALUES-MATCH-001; FEATURE="ValuesMatchChaining"; ASPECT=Parser; STATUS=TESTED; TEST=TestValuesMatchBasic|TestValuesMatchWhere|TestValuesMatchMultiRow; OWNER=engine; UPDATED=2026-04-17
    fn parseStatement(self: *Parser) ParserError!ast.Statement {
        // SONNY-3244: at most `max_statements_per_request` statements.
        try self.countStatement();
        return switch (self.cur.kind) {
            .VALUES => self.parseValuesStatement(),
            .FOR => self.parseForStatement(),
            .LET => blk_let: {
                const first = try self.parseQuery();
                break :blk_let self.handleQueryResult(first);
            },
            .CREATE => self.parseCreateStatement(),
            .DELETE => self.parseDeleteStatement(),
            .DETACH => self.parseDeleteStatement(),
            .MERGE => self.parseMergeStatement(),
            .DROP => self.parseDropStatement(),
            .SHOW => self.parseShowStatement(),
            .EXPLAIN => self.parseExplainStatement(),
            .PROFILE => self.parseProfileStatement(),
            .USE => self.parseUseStatement(),
            .identifier => blk_ident: {
                // Check for BACKUP and RESTORE keywords
                if (std.ascii.eqlIgnoreCase(self.cur.lexeme, "BACKUP")) {
                    break :blk_ident self.parseBackupStatement();
                } else if (std.ascii.eqlIgnoreCase(self.cur.lexeme, "RESTORE")) {
                    break :blk_ident self.parseRestoreStatement();
                } else if (std.ascii.eqlIgnoreCase(self.cur.lexeme, "ALTER")) {
                    break :blk_ident self.parseAlterStatement();
                } else if (std.ascii.eqlIgnoreCase(self.cur.lexeme, "GRANT")) {
                    break :blk_ident self.parseGrantStatement();
                } else if (std.ascii.eqlIgnoreCase(self.cur.lexeme, "REVOKE")) {
                    break :blk_ident self.parseRevokeStatement();
                }
                return error.UnexpectedToken;
            },
            .INSERT => blk_ins: {
                self.advance();
                // Check if this is INSERT VALUE or INSERT pattern
                if (self.cur.kind == .VALUE) {
                    // Syntax: INSERT VALUE <expr>
                    self.advance();
                    const expr = try self.parseOrExpr();
                    break :blk_ins .{ .InsertValue = .{ .expr = expr } };
                } else {
                    // Syntax: INSERT (pattern) - like CREATE but different semantics
                    const pattern = try self.parseGraphPattern();

                    // Optional RETURN clause
                    var return_clause: ?ast.ReturnClause = null;
                    if (self.cur.kind == .RETURN) {
                        self.advance();
                        const distinct = if (self.cur.kind == .DISTINCT) blk: {
                            self.advance();
                            break :blk true;
                        } else false;
                        var return_items = std.ArrayList(ast.ReturnItem).empty;
                        try self.parseProjectionItems(&return_items);
                        return_clause = .{
                            .items = try return_items.toOwnedSlice(self.arena.allocator()),
                            .distinct = distinct,
                        };
                    }

                    break :blk_ins .{ .Insert = .{
                        .pattern = pattern,
                        .return_clause = return_clause,
                    } };
                }
            },
            .SCAN => blk_scan: {
                self.advance();
                // Syntax: SCAN VALUES; simple keyword VALUES optional
                if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "VALUES")) {
                    self.advance();
                } else if (self.cur.kind == .VALUE) {
                    self.advance();
                }
                break :blk_scan .ScanValues;
            },
            .SELECT => blk_select: {
                // SELECT [DISTINCT] <select_list> maps to RETURN semantics
                self.advance();
                var distinct = false;
                if (self.cur.kind == .DISTINCT) {
                    distinct = true;
                    self.advance();
                }

                // Parse select list (same as RETURN items)
                var items = std.ArrayList(ast.ReturnItem).empty;
                while (true) {
                    const expr = try self.parseOrExpr();
                    var alias: ?[]const u8 = null;
                    if (self.cur.kind == .AS) {
                        self.advance();
                        const al = try self.expectIdentifierOrKeyword();
                        alias = al.lexeme;
                    }
                    try items.append(self.arena.allocator(), .{ .expr = expr, .alias = alias });
                    if (self.cur.kind != .comma) break;
                    self.advance();
                }

                // Create a minimal Query with just the return clause
                // (No FROM clause support yet - maps to current active graph)
                const query = ast.Query{
                    .optional_match = false,
                    .match = .{ .chains = &.{} }, // Empty match pattern
                    .where_clause = null,
                    .with_clause = null,
                    .ret = .{ .items = try items.toOwnedSlice(self.arena.allocator()), .distinct = distinct },
                    .order_by = null,
                    .limit = null,
                    .offset = null,
                    .next_query = null, // No chaining for minimal queries
                };
                break :blk_select .{ .Query = query };
            },
            .MATCH => blk_match: {
                // Check if this is a MATCH...DELETE pattern
                // We need to look ahead after parsing the MATCH pattern
                const saved_pos = self.lx.*;
                const saved_cur = self.cur;

                // Try to detect MATCH...DELETE pattern
                self.advance(); // Skip MATCH
                _ = self.parseGraphPattern() catch {
                    // If pattern parsing fails, restore and parse as query
                    self.lx.* = saved_pos;
                    self.cur = saved_cur;
                    const first = try self.parseQuery();
                    break :blk_match self.handleQueryResult(first);
                };

                // Check for optional WHERE
                if (self.cur.kind == .WHERE) {
                    self.advance();
                    _ = self.parseOrExpr() catch {};
                }

                // Check if DELETE or DETACH DELETE follows
                const is_delete = self.cur.kind == .DELETE or self.cur.kind == .DETACH;

                // Restore position
                self.lx.* = saved_pos;
                self.cur = saved_cur;

                if (is_delete) {
                    // Parse as MATCH...DELETE statement
                    self.advance(); // Skip MATCH
                    const match_pattern = try self.parseGraphPattern();

                    var where_clause: ?ast.Expr = null;
                    if (self.cur.kind == .WHERE) {
                        self.advance();
                        where_clause = try self.parseOrExpr();
                    }

                    // Handle optional DETACH
                    const detach = if (self.cur.kind == .DETACH) blk: {
                        self.advance();
                        break :blk true;
                    } else false;

                    _ = try self.expect(.DELETE);

                    // Parse items to delete
                    // GAP-0220 FIX: Use try for proper error propagation
                    var delete_items = try std.ArrayList(ast.DeleteItem).initCapacity(self.arena.allocator(), 0);

                    // Parse first item
                    const first_item = try self.parseDeleteItem();
                    try delete_items.append(self.arena.allocator(), first_item);

                    // Parse additional items
                    while (self.cur.kind == .comma) {
                        self.advance();
                        const item = try self.parseDeleteItem();
                        try delete_items.append(self.arena.allocator(), item);
                    }

                    // Optional RETURN clause
                    var return_clause: ?ast.ReturnClause = null;
                    if (self.cur.kind == .RETURN) {
                        self.advance();
                        const distinct = if (self.cur.kind == .DISTINCT) blk: {
                            self.advance();
                            break :blk true;
                        } else false;
                        var return_items = std.ArrayList(ast.ReturnItem).empty;
                        try self.parseProjectionItems(&return_items);
                        return_clause = .{
                            .items = try return_items.toOwnedSlice(self.arena.allocator()),
                            .distinct = distinct,
                        };
                    }

                    break :blk_match .{ .Delete = .{
                        .match_clause = match_pattern,
                        .where_clause = where_clause,
                        .detach = detach,
                        .items = try delete_items.toOwnedSlice(self.arena.allocator()),
                        .return_clause = return_clause,
                    } };
                }

                // Otherwise, parse as regular query
                const first = try self.parseQuery();
                break :blk_match self.handleQueryResult(first);
            },
            .OPTIONAL => blk_query: {
                const first = try self.parseQuery();
                break :blk_query self.handleQueryResult(first);
            },
            .WITH => blk_with: {
                // Handle WITH as statement starter: WITH expr AS alias [WITH ...] RETURN ...
                var first = try self.parseQuery();
                if (self.cur.kind == .UNION) {
                    // Move ORDER BY/LIMIT/OFFSET from first query to UNION level
                    var order_by: ?*ast.OrderBy = null;
                    if (first.order_by) |ord| {
                        const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                        order_by_ptr.* = ord;
                        order_by = order_by_ptr;
                    }
                    var limit_val: ?u64 = if (first.limit) |l| @as(u64, @intCast(l)) else null;
                    var offset_val: ?u64 = if (first.offset) |o| @as(u64, @intCast(o)) else null;
                    var limit_param: ?[]const u8 = first.limit_param;
                    var offset_param: ?[]const u8 = first.offset_param;
                    first.order_by = null;
                    first.limit = null;
                    first.offset = null;
                    first.limit_param = null;
                    first.offset_param = null;

                    var parts = std.ArrayList(ast.UnionQuery.Part).empty;
                    while (self.cur.kind == .UNION) {
                        self.advance();
                        var all = false;
                        var distinct = false;
                        if (self.cur.kind == .ALL) {
                            all = true;
                            self.advance();
                        } else if (self.cur.kind == .DISTINCT) {
                            distinct = true;
                            self.advance();
                        }
                        if (self.cur.kind == .ALL or self.cur.kind == .DISTINCT) return self.unexpected("both ALL and DISTINCT specified");
                        var q2 = try self.parseQuery();
                        // If this is the last part, move its ORDER BY/LIMIT/OFFSET to UNION level
                        if (self.cur.kind != .UNION) {
                            if (q2.order_by) |ord| {
                                const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                                order_by_ptr.* = ord;
                                order_by = order_by_ptr;
                            }
                            if (q2.limit) |lim| limit_val = @intCast(lim);
                            if (q2.offset) |off| offset_val = @intCast(off);
                            if (q2.limit_param) |p| limit_param = p;
                            if (q2.offset_param) |p| offset_param = p;
                        }
                        // Strip ORDER BY/LIMIT/OFFSET from tail queries
                        q2.order_by = null;
                        q2.limit = null;
                        q2.offset = null;
                        q2.limit_param = null;
                        q2.offset_param = null;
                        try parts.append(self.arena.allocator(), .{ .all = all, .distinct = distinct, .query = q2 });
                    }

                    // Parse optional ORDER BY, LIMIT, OFFSET after UNION (if not already set)

                    if (self.cur.kind == .ORDER) {
                        self.advance();
                        _ = try self.expect(.BY);
                        var keys = std.ArrayList(ast.OrderBy.OrderKey).empty;
                        while (true) {
                            const key_expr = try self.parseOrExpr();
                            const mods = try self.parseOrderKeyModifiers();
                            try keys.append(self.arena.allocator(), .{ .expr = key_expr, .desc = mods.desc, .nulls = mods.nulls });
                            if (self.cur.kind != .comma) break;
                            self.advance();
                        }
                        const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                        order_by_ptr.* = .{ .keys = try keys.toOwnedSlice(self.arena.allocator()) };
                        order_by = order_by_ptr;
                    }

                    if (self.cur.kind == .LIMIT) {
                        self.advance();
                        const limit_expr = try self.parseOrExpr();
                        if (limit_expr != .Int) return self.unexpected("LIMIT requires integer constant");
                        limit_val = @intCast(limit_expr.Int);
                    }

                    if (self.cur.kind == .OFFSET or self.cur.kind == .SKIP) {
                        self.advance();
                        const offset_expr = try self.parseOrExpr();
                        if (offset_expr != .Int) return self.unexpected("OFFSET/SKIP requires integer constant");
                        offset_val = @intCast(offset_expr.Int);
                    }

                    break :blk_with .{ .Union = .{
                        .first = first,
                        .tails = try parts.toOwnedSlice(self.arena.allocator()),
                        .order_by = order_by,
                        .limit = limit_val,
                        .offset = offset_val,
                        .limit_param = limit_param,
                        .offset_param = offset_param,
                    } };
                }
                break :blk_with self.handleQueryResult(first);
            },
            .RETURN => blk_r: {
                // Parenthesized set expression grouping: (RETURN ... UNION ...)
                if (self.cur.kind == .l_paren) {
                    self.advance();
                    var first = try self.parseQuery();
                    var parts = std.ArrayList(ast.UnionQuery.Part).empty;
                    if (self.cur.kind != .UNION) return error.UnexpectedToken;
                    // Strip ORDER BY/LIMIT/OFFSET from first query - they apply outside the parentheses
                    first.order_by = null;
                    first.limit = null;
                    first.offset = null;

                    while (self.cur.kind == .UNION) {
                        self.advance();
                        var all = false;
                        var distinct = false;
                        if (self.cur.kind == .ALL) {
                            all = true;
                            self.advance();
                        } else if (self.cur.kind == .DISTINCT) {
                            distinct = true;
                            self.advance();
                        }
                        if (self.cur.kind == .ALL or self.cur.kind == .DISTINCT) return self.unexpected("both ALL and DISTINCT specified");
                        var q2 = try self.parseQuery();
                        // Strip ORDER BY/LIMIT/OFFSET from tail queries too
                        q2.order_by = null;
                        q2.limit = null;
                        q2.offset = null;
                        try parts.append(self.arena.allocator(), .{ .all = all, .distinct = distinct, .query = q2 });
                    }
                    _ = try self.expect(.r_paren);
                    // After grouped set expr, allow ORDER/LIMIT/OFFSET handled by outer caller; here we return a Union statement
                    break :blk_r .{ .Union = .{ .first = first, .tails = try parts.toOwnedSlice(self.arena.allocator()) } };
                }
                var first = try self.parseQuery();
                if (self.cur.kind == .UNION) {
                    // Move ORDER BY/LIMIT/OFFSET from first query to UNION level
                    var order_by: ?*ast.OrderBy = null;
                    if (first.order_by) |ord| {
                        const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                        order_by_ptr.* = ord;
                        order_by = order_by_ptr;
                    }
                    var limit_val: ?u64 = if (first.limit) |l| @as(u64, @intCast(l)) else null;
                    var offset_val: ?u64 = if (first.offset) |o| @as(u64, @intCast(o)) else null;
                    var limit_param: ?[]const u8 = first.limit_param;
                    var offset_param: ?[]const u8 = first.offset_param;
                    first.order_by = null;
                    first.limit = null;
                    first.offset = null;
                    first.limit_param = null;
                    first.offset_param = null;

                    var parts = std.ArrayList(ast.UnionQuery.Part).empty;
                    while (self.cur.kind == .UNION) {
                        self.advance();
                        var all = false;
                        var distinct = false;
                        if (self.cur.kind == .ALL) {
                            all = true;
                            self.advance();
                        } else if (self.cur.kind == .DISTINCT) {
                            distinct = true;
                            self.advance();
                        }
                        if (self.cur.kind == .ALL or self.cur.kind == .DISTINCT) return self.unexpected("both ALL and DISTINCT specified");
                        var q2 = try self.parseQuery();
                        // If this is the last part, move its ORDER BY/LIMIT/OFFSET to UNION level
                        if (self.cur.kind != .UNION) {
                            if (q2.order_by) |ord| {
                                const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                                order_by_ptr.* = ord;
                                order_by = order_by_ptr;
                            }
                            if (q2.limit) |lim| limit_val = @intCast(lim);
                            if (q2.offset) |off| offset_val = @intCast(off);
                            if (q2.limit_param) |p| limit_param = p;
                            if (q2.offset_param) |p| offset_param = p;
                        }
                        // Strip ORDER BY/LIMIT/OFFSET from tail queries
                        q2.order_by = null;
                        q2.limit = null;
                        q2.offset = null;
                        q2.limit_param = null;
                        q2.offset_param = null;
                        try parts.append(self.arena.allocator(), .{ .all = all, .distinct = distinct, .query = q2 });
                    }

                    // Parse optional ORDER BY, LIMIT, OFFSET after UNION (if not already set)

                    if (self.cur.kind == .ORDER) {
                        self.advance();
                        _ = try self.expect(.BY);
                        var keys = std.ArrayList(ast.OrderBy.OrderKey).empty;
                        while (true) {
                            const key_expr = try self.parseOrExpr();
                            const mods = try self.parseOrderKeyModifiers();
                            try keys.append(self.arena.allocator(), .{ .expr = key_expr, .desc = mods.desc, .nulls = mods.nulls });
                            if (self.cur.kind != .comma) break;
                            self.advance();
                        }
                        const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                        order_by_ptr.* = .{ .keys = try keys.toOwnedSlice(self.arena.allocator()) };
                        order_by = order_by_ptr;
                    }

                    if (self.cur.kind == .LIMIT) {
                        self.advance();
                        const lim = try self.parseLimitValue();
                        limit_val = lim.value;
                        limit_param = lim.param;
                    }

                    if (self.cur.kind == .OFFSET or self.cur.kind == .SKIP) {
                        self.advance();
                        const off = try self.parseLimitValue();
                        offset_val = off.value;
                        offset_param = off.param;
                    }

                    break :blk_r .{ .Union = .{
                        .first = first,
                        .tails = try parts.toOwnedSlice(self.arena.allocator()),
                        .order_by = order_by,
                        .limit = limit_val,
                        .offset = offset_val,
                        .limit_param = limit_param,
                        .offset_param = offset_param,
                    } };
                }
                if (self.cur.kind == .INTERSECT or self.cur.kind == .EXCEPT) {
                    const kind = self.cur.kind;
                    self.advance();
                    var all = false;
                    var distinct = false;
                    if (self.cur.kind == .ALL) {
                        all = true;
                        self.advance();
                    } else if (self.cur.kind == .DISTINCT) {
                        distinct = true;
                        self.advance();
                    }
                    if (self.cur.kind == .ALL or self.cur.kind == .DISTINCT) return self.unexpected("both ALL and DISTINCT specified");
                    const rhs = try self.parseQuery();
                    if (kind == .INTERSECT) {
                        break :blk_r .{ .Intersect = .{ .left = first, .right = rhs, .all = all, .distinct = distinct } };
                    } else {
                        break :blk_r .{ .Except = .{ .left = first, .right = rhs, .all = all, .distinct = distinct } };
                    }
                }
                break :blk_r .{ .Query = first };
            },
            .SESSION => blk: {
                self.advance();
                if (self.cur.kind == .SET) {
                    break :blk try self.parseSessionSetStatement();
                }
                if (self.cur.kind == .RESET) {
                    break :blk try self.parseSessionResetStatement();
                }
                if (self.cur.kind == .CLOSE) {
                    self.advance();
                    break :blk .SessionClose;
                }
                return error.UnexpectedToken;
            },
            .SET => blk_set: {
                self.advance();
                // Check for SET SESSION syntax (alternative to SESSION SET)
                if (self.cur.kind == .SESSION) {
                    // Don't advance - parseSessionSetStatement expects to see SESSION and consume it
                    // Actually, parseSessionSetStatement expects to see SET, so we need to back up
                    // But we can't back up easily. Instead, let's call a version that skips the SET consumption
                    // For now, let's just inline the logic here
                    self.advance(); // consume SESSION

                    // Inline parseSessionSetStatement logic without the initial SET advance
                    if (self.cur.kind == .SCHEMA) {
                        self.advance();
                        const schema_name = if (self.cur.kind == .identifier or self.cur.kind == .string_lit) blk_schema: {
                            const name = self.cur.lexeme;
                            self.advance();
                            break :blk_schema name;
                        } else {
                            return error.UnexpectedToken;
                        };
                        break :blk_set .{ .SessionSet = .{
                            .clause_type = .{ .Schema = .{ .name = schema_name } },
                        } };
                    } else if (self.cur.kind == .GRAPH or self.cur.kind == .PROPERTY) {
                        const is_property = self.cur.kind == .PROPERTY;
                        if (is_property) self.advance();
                        _ = try self.expect(.GRAPH);

                        if (self.cur.kind == .eq) {
                            self.advance();
                        }

                        const graph_expr = if (self.cur.kind == .identifier or self.cur.kind == .string_lit) blk_graph: {
                            const expr = self.cur.lexeme;
                            self.advance();
                            break :blk_graph expr;
                        } else {
                            return error.UnexpectedToken;
                        };

                        break :blk_set .{ .SessionSet = .{
                            .clause_type = .{ .Graph = .{
                                .property_graph = is_property,
                                .expression = graph_expr,
                            } },
                        } };
                    }
                    return error.UnexpectedToken;
                }
                return error.UnexpectedToken;
            },
            .START => blk2: {
                self.advance();
                if (self.cur.kind == .TRANSACTION) {
                    self.advance();
                    // Parse optional transaction characteristics: READ ONLY | READ WRITE
                    if (self.cur.kind == .READ) {
                        self.advance();
                        if (self.cur.kind == .ONLY) {
                            self.advance();
                        } else if (self.cur.kind == .WRITE) {
                            self.advance();
                        }
                    }

                    // Parse optional transaction body: START TRANSACTION { statements }
                    var body: ?[]ast.Statement = null;
                    if (self.cur.kind == .l_brace) {
                        self.advance();

                        // Parse statements until we hit }
                        var statements = try std.ArrayList(ast.Statement).initCapacity(self.arena.allocator(), 4);
                        while (self.cur.kind != .r_brace and self.cur.kind != .eof) {
                            // SONNY-3133: a nested statement.
                            const stmt = try self.parseNestedStatement();
                            try statements.append(self.arena.allocator(), stmt);

                            // SONNY-3166: statements are separated by ';'
                            // (a USE scopes the statement after it, §10.3).
                            if (stmt == .UseGraph and self.cur.kind != .semicolon) continue;
                            try self.endStatement(.r_brace);
                        }

                        _ = try self.expect(.r_brace);
                        body = try statements.toOwnedSlice(self.arena.allocator());
                    }

                    break :blk2 .{ .StartTransaction = .{ .body = body } };
                }
                return error.UnexpectedToken;
            },
            .BEGIN => {
                self.advance();
                // BEGIN can be standalone or followed by TRANSACTION
                if (self.cur.kind == .TRANSACTION) {
                    self.advance();
                }
                return .{ .StartTransaction = .{ .body = null } };
            },
            .COMMIT => {
                self.advance();
                // COMMIT can be followed by TRANSACTION
                if (self.cur.kind == .TRANSACTION) {
                    self.advance();
                }
                return .Commit;
            },
            .ROLLBACK => {
                self.advance();
                // ROLLBACK can be followed by TRANSACTION
                if (self.cur.kind == .TRANSACTION) {
                    self.advance();
                }
                return .Rollback;
            },
            .CALL => blk_call: {
                self.advance();

                // Check if this is a subquery CALL { ... } or procedure call
                if (self.cur.kind == .l_brace) {
                    // CALL { subquery } syntax - parse as a full query with WITH support
                    self.advance();

                    // GAP-0125: Parse imported variables if WITH clause appears at start of CALL block
                    // CANARY: REQ=REQ-SUBQUERY-IMPORT-001; FEATURE="Subquery Imported Variables"; ASPECT=GQLCompliance; STATUS=TESTED; TEST=geodetestlab/specs/gql_subquery_comprehensive.yml; OWNER=parser; UPDATED=2026-01-25
                    var imported_vars: ?[][]const u8 = null;
                    if (self.cur.kind == .WITH) {
                        // Check if this is a WITH for imported variables (single variable references)
                        // vs a WITH projection clause
                        // Save lexer state to backtrack if needed
                        const saved_idx = self.lx.idx;
                        const saved_line = self.lx.line;
                        const saved_col = self.lx.col;
                        const saved_cur = self.cur;
                        self.advance();

                        // If the next token is a variable or identifier followed by comma or more variables,
                        // this is likely an import list
                        if (self.cur.kind == .dollar) {
                            var imports = std.ArrayList([]const u8).empty;
                            while (true) {
                                if (self.cur.kind == .dollar) {
                                    self.advance();
                                    if (self.cur.kind == .identifier) {
                                        const var_name = self.cur.lexeme;
                                        try imports.append(self.arena.allocator(), var_name);
                                        self.advance();
                                    }
                                }
                                if (self.cur.kind == .comma) {
                                    self.advance();
                                } else {
                                    break;
                                }
                            }
                            if (imports.items.len > 0) {
                                imported_vars = try imports.toOwnedSlice(self.arena.allocator());
                            }
                        } else {
                            // Not an import list, restore lexer position
                            self.lx.idx = saved_idx;
                            self.lx.line = saved_line;
                            self.lx.col = saved_col;
                            self.cur = saved_cur;
                        }
                    }

                    // Parse the query inside CALL { ... }
                    // This allows for queries with WITH clauses, nested CALLs, etc.
                    const query = try self.parseQuery();

                    // Wrap the query in a Statement
                    const stmt = try self.arena.allocator().create(ast.Statement);
                    stmt.* = .{ .Query = query };

                    // Expect closing brace
                    _ = try self.expect(.r_brace);

                    // If there's a WITH clause after the CALL, this needs to be parsed as a Query
                    // not as a standalone Statement.Call
                    if (self.cur.kind == .WITH or self.cur.kind == .WHERE) {
                        // Create a Query with initial_call_subquery set to the inner query
                        const query_ptr = try self.arena.allocator().create(ast.Query);
                        query_ptr.* = query;

                        // Parse the WITH and other clauses
                        // We need to create a new Query that wraps the CALL result
                        var with_clause: ?ast.WithClause = null;
                        var where_clause: ?ast.Expr = null;
                        var ret_clause: ast.ReturnClause = .{ .items = &.{}, .distinct = false };

                        if (self.cur.kind == .WITH) {
                            self.advance();
                            var witems = std.ArrayList(ast.ReturnItem).empty;
                            try self.parseProjectionItems(&witems);
                            with_clause = .{
                                .items = try witems.toOwnedSlice(self.arena.allocator()),
                                .order_by = null,
                                .limit = null,
                                .offset = null,
                            };
                        }

                        if (self.cur.kind == .WHERE) {
                            self.advance();
                            where_clause = try self.parseOrExpr();
                        }

                        if (self.cur.kind == .RETURN) {
                            self.advance();
                            const distinct = if (self.cur.kind == .DISTINCT) blk: {
                                self.advance();
                                break :blk true;
                            } else false;
                            var return_items = std.ArrayList(ast.ReturnItem).empty;
                            try self.parseProjectionItems(&return_items);
                            ret_clause = .{
                                .items = try return_items.toOwnedSlice(self.arena.allocator()),
                                .distinct = distinct,
                            };
                        }

                        // Create a Query with the CALL result as input
                        const wrapper_query = ast.Query{
                            .optional_match = false,
                            .match = .{ .chains = &.{} },
                            .where_clause = where_clause,
                            .with_clause = with_clause,
                            .ret = ret_clause,
                            .order_by = null,
                            .limit = null,
                            .offset = null,
                            .initial_call_subquery = query_ptr,
                        };

                        break :blk_call .{ .Query = wrapper_query };
                    }

                    // CANARY: REQ=REQ-SONNY-3389-CALL-RETURN; FEATURE="CallSubquery"; ASPECT=ParserReturnTail; STATUS=TESTED; TEST=tests/test_sonny3184_optional_match_distinct_call.zig; OWNER=parser; UPDATED=2026-11-11
                    // SONNY-3389: a RETURN after the CALL { } is the rest of
                    // the statement, computed over the body's rows: a query
                    // whose `initial_call_subquery` is the body, with the
                    // RETURN's DISTINCT, GROUP BY, ORDER BY, SKIP and LIMIT.
                    // It was kept as `return_clause`, which nothing applied
                    // (the body's rows were the answer), and an ORDER BY or
                    // LIMIT after it was a syntax error.
                    if (self.cur.kind == .RETURN) {
                        const query_ptr = try self.arena.allocator().create(ast.Query);
                        query_ptr.* = query;
                        var tail = try self.parseQuery();
                        tail.initial_call_subquery = query_ptr;
                        break :blk_call .{ .Query = tail };
                    }

                    // Optional RETURN clause after subquery
                    var return_clause: ?ast.ReturnClause = null;
                    if (self.cur.kind == .RETURN) {
                        self.advance();
                        const distinct = if (self.cur.kind == .DISTINCT) blk: {
                            self.advance();
                            break :blk true;
                        } else false;
                        var return_items = std.ArrayList(ast.ReturnItem).empty;
                        try self.parseProjectionItems(&return_items);
                        return_clause = .{
                            .items = try return_items.toOwnedSlice(self.arena.allocator()),
                            .distinct = distinct,
                        };
                    }

                    break :blk_call .{
                        .Call = .{
                            .Subquery = .{
                                .statement = stmt,
                                .imported_vars = imported_vars, // GAP-0125: Pass imported variables
                                .return_clause = return_clause,
                            },
                        },
                    };
                } else {
                    // Traditional procedure call (e.g., db.labels())
                    const procedure = try self.parseOrExpr();

                    // Optional YIELD clause
                    var yield_items: ?[]ast.ReturnItem = null;
                    if (self.cur.kind == .YIELD) {
                        self.advance();
                        var items = std.ArrayList(ast.ReturnItem).empty;
                        try self.parseProjectionItems(&items);
                        yield_items = try items.toOwnedSlice(self.arena.allocator());
                    }

                    // Optional RETURN clause
                    var return_clause: ?ast.ReturnClause = null;
                    if (self.cur.kind == .RETURN) {
                        self.advance();
                        const distinct = if (self.cur.kind == .DISTINCT) blk: {
                            self.advance();
                            break :blk true;
                        } else false;
                        var return_items = std.ArrayList(ast.ReturnItem).empty;
                        try self.parseProjectionItems(&return_items);
                        return_clause = .{
                            .items = try return_items.toOwnedSlice(self.arena.allocator()),
                            .distinct = distinct,
                        };
                    }

                    // Optional ORDER BY clause (after RETURN)
                    var order_by: ?ast.OrderBy = null;
                    if (return_clause != null and self.cur.kind == .ORDER) {
                        self.advance();
                        _ = try self.expect(.BY);
                        var keys = std.ArrayList(ast.OrderBy.OrderKey).empty;
                        const expr1 = try self.parseOrExpr();
                        const mods1 = try self.parseOrderKeyModifiers();
                        try keys.append(self.arena.allocator(), .{ .expr = expr1, .desc = mods1.desc, .nulls = mods1.nulls });
                        while (self.cur.kind == .comma) {
                            self.advance();
                            const exprk = try self.parseOrExpr();
                            const modsk = try self.parseOrderKeyModifiers();
                            try keys.append(self.arena.allocator(), .{ .expr = exprk, .desc = modsk.desc, .nulls = modsk.nulls });
                        }
                        order_by = .{ .keys = try keys.toOwnedSlice(self.arena.allocator()) };
                    }

                    // Optional LIMIT clause
                    var limit: ?usize = null;
                    var limit_param: ?[]const u8 = null;
                    if (self.cur.kind == .LIMIT) {
                        self.advance();
                        const lim = try self.parseLimitValue();
                        limit = if (lim.value) |v| @as(usize, @intCast(v)) else null;
                        limit_param = lim.param;
                    }

                    // Optional OFFSET/SKIP clause
                    var offset: ?usize = null;
                    var offset_param: ?[]const u8 = null;
                    if (self.cur.kind == .OFFSET or self.cur.kind == .SKIP) {
                        self.advance();
                        const off = try self.parseLimitValue();
                        offset = if (off.value) |v| @as(usize, @intCast(v)) else null;
                        offset_param = off.param;
                    }
                    // SONNY-2779: `SKIP n LIMIT m`, as after any RETURN; a
                    // LIMIT after the SKIP was a syntax error.
                    if (self.cur.kind == .LIMIT and limit == null and limit_param == null) {
                        self.advance();
                        const lim = try self.parseLimitValue();
                        limit = if (lim.value) |v| @as(usize, @intCast(v)) else null;
                        limit_param = lim.param;
                    }

                    break :blk_call .{ .Call = .{ .Procedure = .{
                        .procedure = procedure,
                        .yield_items = yield_items,
                        .return_clause = return_clause,
                        .order_by = order_by,
                        .limit = limit,
                        .offset = offset,
                        .limit_param = limit_param,
                        .offset_param = offset_param,
                    } } };
                }
            },
            .l_paren => blk_paren: {
                // CANARY: REQ=REQ-GQL-085; FEATURE="ParenthesizedSetOperations"; ASPECT=ParserSupport; STATUS=TESTED; OWNER=parser; UPDATED=2025-10-14
                // Parse parenthesized statement: (MATCH ... UNION ...) INTERSECT ...
                self.advance(); // consume (
                // SONNY-3133: a nested statement.
                const inner_stmt = try self.parseNestedStatement();
                _ = try self.expect(.r_paren);

                // Check if this is followed by set operations
                if (self.cur.kind == .UNION or self.cur.kind == .INTERSECT or self.cur.kind == .EXCEPT) {
                    // Extract the first query from the inner statement
                    const first = switch (inner_stmt) {
                        .Query => |q| q,
                        .Union => |u| blk_first: {
                            // Convert Union statement back to a query by wrapping it
                            // For now, we'll just use the first query from the union
                            break :blk_first u.first;
                        },
                        else => return error.UnexpectedToken,
                    };

                    // Parse the rest of the set operations
                    var parts = std.ArrayList(ast.UnionQuery.Part).empty;

                    // If inner_stmt was a Union, add its tails first
                    if (inner_stmt == .Union) {
                        for (inner_stmt.Union.tails) |tail| {
                            try parts.append(self.arena.allocator(), tail);
                        }
                    }

                    // Parse additional set operations
                    while (self.cur.kind == .UNION or self.cur.kind == .INTERSECT or self.cur.kind == .EXCEPT) {
                        const operation = switch (self.cur.kind) {
                            .UNION => ast.SetOperation.union_op,
                            .INTERSECT => ast.SetOperation.intersect,
                            .EXCEPT => ast.SetOperation.except,
                            else => unreachable,
                        };
                        self.advance();
                        var all = false;
                        var distinct = false;
                        if (self.cur.kind == .ALL) {
                            all = true;
                            self.advance();
                        } else if (self.cur.kind == .DISTINCT) {
                            distinct = true;
                            self.advance();
                        }
                        const q = try self.parseQuery();
                        try parts.append(self.arena.allocator(), .{ .operation = operation, .all = all, .distinct = distinct, .query = q });
                    }

                    break :blk_paren .{ .Union = .{
                        .first = first,
                        .tails = try parts.toOwnedSlice(self.arena.allocator()),
                        .order_by = null,
                        .limit = null,
                        .offset = null,
                    } };
                }

                // No set operations, just return the inner statement
                break :blk_paren inner_stmt;
            },
            else => return error.UnexpectedToken,
        };
    }

    fn handleQueryResult(self: *Parser, first: ast.Query) ParserError!ast.Statement {
        if (self.cur.kind == .UNION or self.cur.kind == .INTERSECT or self.cur.kind == .EXCEPT) {
            // CANARY: REQ=REQ-GQL-100; FEATURE="UNION Query Operations"; ASPECT=Parser; STATUS=TESTED; TEST=gql_conformance.T1; OWNER=parser; UPDATED=2025-10-14
            // When we have set operations, individual queries should not have their own ORDER BY/LIMIT/OFFSET
            // Those clauses apply to the entire set operation result
            // If the first query has these, they should be moved to the UNION level
            var first_query = first;
            var order_by: ?*ast.OrderBy = null;
            if (first.order_by) |ord| {
                const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                order_by_ptr.* = ord;
                order_by = order_by_ptr;
            }
            var limit_val: ?u64 = if (first.limit) |l| @as(u64, @intCast(l)) else null;
            var offset_val: ?u64 = if (first.offset) |o| @as(u64, @intCast(o)) else null;
            var limit_param: ?[]const u8 = first.limit_param;
            var offset_param: ?[]const u8 = first.offset_param;
            first_query.order_by = null;
            first_query.limit = null;
            first_query.offset = null;
            first_query.limit_param = null;
            first_query.offset_param = null;

            var parts = std.ArrayList(ast.UnionQuery.Part).empty;
            while (self.cur.kind == .UNION or self.cur.kind == .INTERSECT or self.cur.kind == .EXCEPT) {
                const operation = switch (self.cur.kind) {
                    .UNION => ast.SetOperation.union_op,
                    .INTERSECT => ast.SetOperation.intersect,
                    .EXCEPT => ast.SetOperation.except,
                    else => unreachable,
                };
                self.advance();
                var all = false;
                var distinct = false;
                if (self.cur.kind == .ALL) {
                    all = true;
                    self.advance();
                } else if (self.cur.kind == .DISTINCT) {
                    distinct = true;
                    self.advance();
                }
                // Disallow both modifiers at once
                if (self.cur.kind == .ALL or self.cur.kind == .DISTINCT) return self.unexpected("both ALL and DISTINCT specified");
                var q = try self.parseQuery();
                // If this is the last part and it has ORDER BY/LIMIT/OFFSET, use those for the UNION level
                if (self.cur.kind != .UNION and self.cur.kind != .INTERSECT and self.cur.kind != .EXCEPT) {
                    if (q.order_by) |ord| {
                        const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                        order_by_ptr.* = ord;
                        order_by = order_by_ptr;
                    }
                    if (q.limit) |lim| limit_val = @intCast(lim);
                    if (q.offset) |off| offset_val = @intCast(off);
                    if (q.limit_param) |p| limit_param = p;
                    if (q.offset_param) |p| offset_param = p;
                }
                // Strip ORDER BY/LIMIT/OFFSET from tail queries - they apply at set operation level
                q.order_by = null;
                q.limit = null;
                q.offset = null;
                q.limit_param = null;
                q.offset_param = null;
                try parts.append(self.arena.allocator(), .{ .operation = operation, .all = all, .distinct = distinct, .query = q });
            }

            // Parse optional ORDER BY, LIMIT, OFFSET after set operations (if not already set from last query)

            if (self.cur.kind == .ORDER) {
                self.advance();
                _ = try self.expect(.BY);
                var keys = std.ArrayList(ast.OrderBy.OrderKey).empty;
                while (true) {
                    const key_expr = try self.parseOrExpr();
                    const mods = try self.parseOrderKeyModifiers();
                    try keys.append(self.arena.allocator(), .{ .expr = key_expr, .desc = mods.desc, .nulls = mods.nulls });
                    if (self.cur.kind != .comma) break;
                    self.advance();
                }
                const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                order_by_ptr.* = .{ .keys = try keys.toOwnedSlice(self.arena.allocator()) };
                order_by = order_by_ptr;
            }

            if (self.cur.kind == .LIMIT) {
                self.advance();
                const lim = try self.parseLimitValue();
                limit_val = lim.value;
                limit_param = lim.param;
            }

            if (self.cur.kind == .OFFSET or self.cur.kind == .SKIP) {
                self.advance();
                const off = try self.parseLimitValue();
                offset_val = off.value;
                offset_param = off.param;
            }

            return .{ .Union = .{
                .first = first_query,
                .tails = try parts.toOwnedSlice(self.arena.allocator()),
                .order_by = order_by,
                .limit = limit_val,
                .offset = offset_val,
                .limit_param = limit_param,
                .offset_param = offset_param,
            } };
        }
        return .{ .Query = first };
    }

    fn parseQuery(self: *Parser) ParserError!ast.Query {
        // SONNY-3244: queries nest at most `max_query_nesting` deep.
        try self.enterQuery();
        defer self.query_depth -= 1;
        // SONNY-3190: the SET, REMOVE and CREATE clauses of this part.
        var write_clauses: usize = 0;
        // Parse LET bindings first (LET $var = expr, ...)
        var let_bindings = std.ArrayList(ast.LetBinding).empty;
        if (self.cur.kind == .LET) {
            self.advance();
            while (true) {
                // Parse $variable
                if (self.cur.kind != .dollar) return self.unexpected("expected $ parameter variable after LET");
                self.advance();
                if (self.cur.kind != .identifier) return self.unexpected("expected identifier after $");
                const var_name = self.cur.lexeme;
                self.advance();
                _ = try self.expect(.eq);
                const value_expr = try self.parseOrExpr();
                try let_bindings.append(self.arena.allocator(), .{ .variable = var_name, .value = value_expr });
                // Allow comma for multiple bindings: LET $x = 1, $y = 2
                if (self.cur.kind == .comma) {
                    self.advance();
                    continue;
                }
                break;
            }
        }

        // Optional MATCH/OPTIONAL MATCH/CREATE pattern; allow RETURN-only queries too.
        var optional_match = false;
        var have_match = false;
        var have_create = false;
        var create_pattern: ?ast.GraphPattern = null;
        var merge_statement: ?*ast.MergeStatement = null;

        // Check for WITH at the beginning (for queries like: WITH 5 AS x RETURN x)
        // Parse WITH clause first if present, before MATCH/CREATE
        var initial_with_clause: ?ast.WithClause = null;
        var initial_where_expr: ?ast.Expr = null; // WHERE clause after initial WITH
        if (self.cur.kind == .WITH) {
            self.advance();
            // Support WITH DISTINCT for initial WITH clause
            const with_distinct = if (self.cur.kind == .DISTINCT) blk: {
                self.advance();
                break :blk true;
            } else false;
            var witems = std.ArrayList(ast.ReturnItem).empty;
            try self.parseProjectionItems(&witems);

            // Parse optional ORDER BY, LIMIT, OFFSET after WITH items
            var with_order_by: ?*ast.OrderBy = null;
            var with_limit: ?u64 = null;
            var with_offset: ?u64 = null;
            var with_limit_param: ?[]const u8 = null;
            var with_offset_param: ?[]const u8 = null;

            if (self.cur.kind == .ORDER) {
                self.advance();
                _ = try self.expect(.BY);
                var keys = std.ArrayList(ast.OrderBy.OrderKey).empty;
                while (true) {
                    const key_expr = try self.parseOrExpr();
                    const mods = try self.parseOrderKeyModifiers();
                    try keys.append(self.arena.allocator(), .{ .expr = key_expr, .desc = mods.desc, .nulls = mods.nulls });
                    if (self.cur.kind != .comma) break;
                    self.advance();
                }
                const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                order_by_ptr.* = .{ .keys = try keys.toOwnedSlice(self.arena.allocator()) };
                with_order_by = order_by_ptr;
            }

            if (self.cur.kind == .LIMIT) {
                self.advance();
                const lim = try self.parseLimitValue();
                with_limit = lim.value;
                with_limit_param = lim.param;
            }

            if (self.cur.kind == .OFFSET or self.cur.kind == .SKIP) {
                self.advance();
                const off = try self.parseLimitValue();
                with_offset = off.value;
                with_offset_param = off.param;
            }

            initial_with_clause = .{
                .items = try witems.toOwnedSlice(self.arena.allocator()),
                .distinct = with_distinct,
                .order_by = with_order_by,
                .limit = with_limit,
                .offset = with_offset,
                .limit_param = with_limit_param,
                .offset_param = with_offset_param,
            };

            // CANARY: REQ=REQ-GQL-WITH-WHERE-003; FEATURE="InitialWithWhere"; ASPECT=ParserSupport; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=parser; UPDATED=2025-12-24
            // Allow optional WHERE after initial WITH to filter the projected bindings
            // This is for queries like: WITH 5 AS x WHERE x > 0 RETURN x
            // Or chained: MATCH (n) WITH n.name AS name WITH name WHERE name = 'Alice' RETURN name
            if (self.cur.kind == .WHERE) {
                self.advance();
                initial_where_expr = try self.parseOrExpr();
            }

            // Check for FOR after initial WITH clause
            if (self.cur.kind == .FOR) {
                // Parse FOR statement and store it in the query
                const for_stmt = try self.parseForStatement();
                // Allocate ForStatement on arena
                const for_ptr = try self.arena.allocator().create(ast.ForStatement);
                for_ptr.* = for_stmt.For;

                return ast.Query{
                    .optional_match = false,
                    .match = .{ .chains = &.{} }, // Empty match pattern
                    .create_pattern = null,
                    .where_clause = null,
                    .with_clause = initial_with_clause,
                    .set_clauses = &.{},
                    .remove_clauses = &.{},
                    .ret = for_stmt.For.return_clause orelse .{ .items = &.{}, .distinct = false },
                    .order_by = for_stmt.For.order_by,
                    .offset = for_stmt.For.offset,
                    .limit = for_stmt.For.limit,
                    .next_query = null,
                    .group_by = null,
                    .having = null,
                    .for_statement = for_ptr,
                    // SONNY-3183: the WITH's WHERE, which nothing applies
                    // before a FOR: the write-shape allowlist refuses a FOR
                    // that writes after one.
                    .initial_where = initial_where_expr,
                };
            }

            // CANARY: REQ=REQ-GQL-WITH-CHAIN-003; FEATURE="ConsecutiveWithClauses"; ASPECT=ParserSupport; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=parser; UPDATED=2025-12-24
            // Check for another WITH after initial WITH (chained WITH clauses without MATCH)
            // e.g., WITH 'Alice' AS n WITH n AS n2 RETURN n2
            if (self.cur.kind == .WITH) {
                // Parse the continuation as a new query
                const next_query = try self.parseNestedQuery();
                // Allocate on arena and store pointer
                const next_ptr = try self.arena.allocator().create(ast.Query);
                next_ptr.* = next_query;

                // Return a query with initial_with_clause and next_query
                return ast.Query{
                    .optional_match = false,
                    .match = .{ .chains = &.{} }, // Empty match pattern
                    .create_pattern = null,
                    .where_clause = initial_where_expr,
                    .with_clause = null, // WITH items become ret.items for chaining
                    .set_clauses = &.{},
                    .remove_clauses = &.{},
                    .ret = .{ .items = initial_with_clause.?.items, .distinct = false },
                    .order_by = null,
                    .limit = null,
                    .offset = null,
                    .next_query = next_ptr,
                    .group_by = null,
                    .having = null,
                };
            }

            // GAP #57: Handle MERGE after initial WITH clause (e.g., WITH a MERGE (b) RETURN ...)
            if (self.cur.kind == .MERGE) {
                const merge_stmt = try self.parseMergeStatement();
                const merge_ptr = try self.arena.allocator().create(ast.MergeStatement);
                merge_ptr.* = merge_stmt.Merge;

                return ast.Query{
                    .optional_match = false,
                    .match = .{ .chains = &.{} },
                    .create_pattern = null,
                    .where_clause = initial_where_expr,
                    .with_clause = null,
                    .is_initial_with = true,
                    .set_clauses = &.{},
                    .remove_clauses = &.{},
                    .ret = merge_stmt.Merge.return_clause orelse .{ .items = initial_with_clause.?.items, .distinct = false },
                    .order_by = null,
                    .limit = null,
                    .offset = null,
                    .next_query = null,
                    .group_by = null,
                    .having = null,
                    .merge_statement = merge_ptr,
                    // SONNY-3139: `with_clause` is null here; the MERGE sees
                    // the WITH's items only through these.
                    .initial_with = initial_with_clause,
                    .initial_where = initial_where_expr,
                };
            }
        }

        // Check for SELECT at the beginning (for queries like: SELECT 1 AS x)
        // SELECT maps to RETURN semantics - treat as RETURN to allow variable access
        // When SELECT appears in UNION after CREATE, it should access CREATE variables
        var select_mode = false;
        if (self.cur.kind == .SELECT) {
            select_mode = true;
            self.advance();
            var distinct = false;
            if (self.cur.kind == .DISTINCT) {
                distinct = true;
                self.advance();
            }
            var items = std.ArrayList(ast.ReturnItem).empty;
            try self.parseProjectionItems(&items);

            // Instead of returning immediately, store as initial_with_clause
            // This allows SELECT to access variables from enclosing scope (like CREATE variables in UNION)
            initial_with_clause = .{
                .items = try items.toOwnedSlice(self.arena.allocator()),
                .order_by = null,
                .limit = null,
                .offset = null,
            };
            // Continue parsing - SELECT acts like WITH, making variables available to RETURN
        }

        // Check for UNWIND clause
        // UNWIND list_expr AS variable
        var unwind_clause: ?ast.UnwindClause = null;
        if (self.cur.kind == .UNWIND) {
            self.has_unwind = true;
            self.advance();
            const list_expr = try self.parseOrExpr();
            _ = try self.expect(.AS);
            if (self.cur.kind != .identifier) return self.unexpected("expected identifier after UNWIND ... AS");
            const var_name = self.cur.lexeme;
            self.advance();
            unwind_clause = .{ .list_expr = list_expr, .variable = var_name };
        }

        // Check for CALL { subquery } at the beginning
        var initial_call_subquery: ?*ast.Query = null;
        if (self.cur.kind == .CALL) {
            const peek_ahead = self.peekToken();
            if (peek_ahead == .l_brace) {
                // CALL { subquery } syntax - parse the subquery and continue with WITH/WHERE/RETURN
                self.advance(); // consume CALL
                self.advance(); // consume {

                // Parse the inner query
                const inner_query = try self.parseNestedQuery();

                // Consume closing brace
                _ = try self.expect(.r_brace);

                // Store pointer to inner query for execution
                const inner_query_ptr = try self.arena.allocator().create(ast.Query);
                inner_query_ptr.* = inner_query;
                initial_call_subquery = inner_query_ptr;

                // Continue parsing - don't return yet, let the rest of parseQuery handle
                // any WITH/WHERE/RETURN that follows
            } else {
                // Regular procedure CALL - return empty query for now
                // This will be handled elsewhere in the query body
                const empty_match = ast.GraphPattern{ .chains = &.{} };
                return ast.Query{
                    .optional_match = false,
                    .match = empty_match,
                    .create_pattern = null,
                    .where_clause = null,
                    .with_clause = null,
                    .set_clauses = &.{},
                    .remove_clauses = &.{},
                    .ret = .{ .items = &.{}, .distinct = false },
                    .order_by = null,
                    .limit = null,
                    .offset = null,
                    .next_query = null,
                    .group_by = null,
                    .having = null,
                };
            }
        }

        // Check for CREATE at the beginning - support multiple consecutive CREATE clauses
        // e.g., CREATE (a:Node) CREATE (b:Node) WITH 1 AS x ...
        // CANARY: REQ=REQ-GQL-MULTI-CREATE-001; FEATURE="MultipleConsecutiveCreate"; ASPECT=Parser; STATUS=TESTED; TEST=geodetestlab/specs/gql_data_modification_comprehensive.yml; OWNER=parser; UPDATED=2025-12-27
        if (self.cur.kind == .CREATE) {
            have_create = true;
            var create_chains = std.ArrayList(ast.Chain).empty;
            while (self.cur.kind == .CREATE) {
                try self.countWriteClause(&write_clauses);
                self.advance();
                const cp = try self.parseGraphPattern();
                for (cp.chains) |chain| {
                    try create_chains.append(self.arena.allocator(), chain);
                }
            }
            create_pattern = .{ .chains = try create_chains.toOwnedSlice(self.arena.allocator()) };
        } else if (self.cur.kind == .OPTIONAL) {
            self.advance();
            // Check for OPTIONAL { } block, OPTIONAL (...), or OPTIONAL MATCH
            if (self.cur.kind == .l_brace or self.cur.kind == .l_paren) {
                // OPTIONAL { ... } or OPTIONAL (...) block - treat as optional match without initial MATCH
                optional_match = true;
                have_match = false; // Will parse inside the block
            } else {
                optional_match = true;
                have_match = true;
            }
        }
        if (self.cur.kind == .MATCH and !have_create) {
            have_match = true;
        }
        // Handle OPTIONAL { } or OPTIONAL (...) without preceding MATCH
        if ((self.cur.kind == .l_brace or self.cur.kind == .l_paren) and optional_match and !have_match) {
            have_match = true;
        }
        // Prepare defaults
        // Initialize where_expr from initial_where_expr (from initial WITH clause if present)
        var where_expr: ?ast.Expr = initial_where_expr;
        var with_clause: ?ast.WithClause = null;
        // SONNY-3140: the WHEREs either side of a WITH after the MATCH.
        var pre_with_where: ?ast.Expr = null;
        var with_where: ?ast.Expr = null;
        // SONNY-3184: a WHERE after an OPTIONAL MATCH.
        var optional_where = false;
        // SONNY-3184, SONNY-6337: each MATCH / OPTIONAL MATCH clause and its
        // own WHERE (`ast.Query.match_clauses`).
        var match_clauses = std.ArrayList(ast.MatchClause).empty;
        var group_by: ?ast.GroupBy = null;
        var having_expr: ?ast.Expr = null;
        var path_variable: ?[]const u8 = null;
        const pat: ast.GraphPattern = if (have_match) blk_pat: {
            // Handle OPTIONAL { } at the start
            var all_chains = std.ArrayList(ast.Chain).empty;

            if ((self.cur.kind == .l_brace or self.cur.kind == .l_paren) and optional_match) {
                // OPTIONAL { ... } or OPTIONAL (...) at the start
                const is_paren = self.cur.kind == .l_paren;
                const close_token = if (is_paren) tok.TokenKind.r_paren else tok.TokenKind.r_brace;
                self.advance(); // consume { or (
                // Parse multiple MATCH patterns inside the block
                while (self.cur.kind != close_token and self.cur.kind != .eof) {
                    if (self.cur.kind == .MATCH) {
                        self.advance();
                        const block_gp = try self.parseGraphPattern();
                        for (block_gp.chains) |chain| {
                            try all_chains.append(self.arena.allocator(), chain);
                        }
                        // Optional semicolon separator
                        if (self.cur.kind == .semicolon) {
                            self.advance();
                        }
                    } else {
                        return error.UnexpectedToken;
                    }
                }
                if (is_paren) {
                    _ = try self.expect(.r_paren);
                } else {
                    _ = try self.expect(.r_brace);
                }
                break :blk_pat .{ .chains = try all_chains.toOwnedSlice(self.arena.allocator()) };
            }

            _ = try self.expect(.MATCH);
            // For the top-level MATCH pattern, collect aliases freshly.
            self.collect_chain_aliases = true;
            self.path_aliases.clearRetainingCapacity();

            // Path variable assignment is handled inside parseGraphPattern

            // Parse first MATCH pattern
            const first_gp = try self.parseGraphPattern();

            // Extract path variable from the first named chain
            for (first_gp.chains) |chain| {
                if (chain.name) |name| {
                    path_variable = name;
                    break;
                }
            }
            for (first_gp.chains) |chain| {
                try all_chains.append(self.arena.allocator(), chain);
            }
            // A part that starts with OPTIONAL MATCH (after WITH, or a
            // statement of its own) is one optional clause.
            try match_clauses.append(self.arena.allocator(), .{ .optional = optional_match, .end = all_chains.items.len });

            // Check for additional MATCH or OPTIONAL MATCH clauses and combine their chains
            // CANARY: REQ=REQ-GQL-OPTIONAL-MATCH-002; FEATURE="OptionalMatchParsing"; ASPECT=ChainMarking; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=parser; UPDATED=2025-12-22
            while (self.cur.kind == .MATCH or self.cur.kind == .OPTIONAL) {
                // Track whether current chains are optional (for OPTIONAL MATCH)
                var is_currently_optional = false;
                // Handle OPTIONAL MATCH
                if (self.cur.kind == .OPTIONAL) {
                    self.advance();
                    is_currently_optional = true;
                    // Check for OPTIONAL { ... } or OPTIONAL (...) block syntax
                    if (self.cur.kind == .l_brace or self.cur.kind == .l_paren) {
                        const is_paren = self.cur.kind == .l_paren;
                        const close_token = if (is_paren) tok.TokenKind.r_paren else tok.TokenKind.r_brace;
                        self.advance(); // consume { or (
                        // Parse multiple MATCH patterns inside the block
                        while (self.cur.kind != close_token and self.cur.kind != .eof) {
                            if (self.cur.kind == .MATCH) {
                                self.advance();
                                const block_gp = try self.parseGraphPattern();
                                for (block_gp.chains) |chain| {
                                    // Mark chain as optional
                                    var optional_chain = chain;
                                    optional_chain.is_optional = true;
                                    try all_chains.append(self.arena.allocator(), optional_chain);
                                }
                                // Optional semicolon separator
                                if (self.cur.kind == .semicolon) {
                                    self.advance();
                                }
                            } else {
                                return error.UnexpectedToken;
                            }
                        }
                        if (is_paren) {
                            _ = try self.expect(.r_paren);
                        } else {
                            _ = try self.expect(.r_brace);
                        }
                        optional_match = true;
                        try match_clauses.append(self.arena.allocator(), .{ .optional = true, .end = all_chains.items.len });
                        continue;
                    }
                    if (self.cur.kind != .MATCH) {
                        return error.UnexpectedToken;
                    }
                    // Mark that we have an optional match (this affects the overall query)
                    optional_match = true;
                }
                self.advance(); // consume MATCH
                const additional_gp = try self.parseGraphPattern();
                for (additional_gp.chains) |chain| {
                    // Mark chain as optional if from OPTIONAL MATCH
                    if (is_currently_optional) {
                        var optional_chain = chain;
                        optional_chain.is_optional = true;
                        try all_chains.append(self.arena.allocator(), optional_chain);
                    } else {
                        try all_chains.append(self.arena.allocator(), chain);
                    }
                }
                try match_clauses.append(self.arena.allocator(), .{ .optional = is_currently_optional, .end = all_chains.items.len });
            }

            var combined_gp = ast.GraphPattern{ .chains = try all_chains.toOwnedSlice(self.arena.allocator()) };

            // Keep aliases for ORDER BY checks that follow.
            self.collect_chain_aliases = false;
            // optional WHERE predicate
            if (self.cur.kind == .WHERE) {
                self.advance();
                where_expr = try self.parseOrExpr();
                // SONNY-3184: a WHERE after an OPTIONAL MATCH filters the
                // whole row here, not the optional part.
                for (combined_gp.chains) |chain| {
                    if (chain.is_optional) optional_where = true;
                }
                // It is the last clause's own WHERE.
                if (match_clauses.items.len > 0) match_clauses.items[match_clauses.items.len - 1].where = where_expr;
            }

            // CANARY: REQ=REQ-GQL-OPTIONAL-MATCH-003; FEATURE="OptionalMatchAfterWhere"; ASPECT=ParserSupport; STATUS=TESTED; TEST=tests/test_sonny3184_optional_match_distinct_call.zig; OWNER=parser; UPDATED=2026-11-11
            // CANARY: REQ=REQ-GQL-MATCH-AFTER-WHERE-001; FEATURE="MatchAfterWhere"; ASPECT=ParserSupport; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=parser; UPDATED=2026-11-11
            // More MATCH and OPTIONAL MATCH clauses after a WHERE, each with a
            // WHERE of its own: `MATCH (e) WHERE e.x = 1 OPTIONAL MATCH
            // (e)-[:R]->(m) WHERE m.y = 2 MATCH (d {k: e.k}) WHERE ...`.
            // SONNY-3184: an OPTIONAL MATCH here took no WHERE (a syntax
            // error) and was not followed by a MATCH.
            if (self.cur.kind == .MATCH or self.cur.kind == .OPTIONAL) {
                var post_where_chains = std.ArrayList(ast.Chain).empty;
                // First add the existing chains
                for (combined_gp.chains) |chain| {
                    try post_where_chains.append(self.arena.allocator(), chain);
                }
                // SONNY-3181: each WHERE below is ANDed onto the WHERE so far,
                // one link per MATCH: the conditions count as one expression
                // (`max_expr_links`), whatever the MATCH clauses parse.
                self.enterExpr();
                defer self.leaveExpr();
                while (self.cur.kind == .MATCH or self.cur.kind == .OPTIONAL) {
                    const clause_optional = self.cur.kind == .OPTIONAL;
                    if (clause_optional) {
                        self.advance(); // consume OPTIONAL
                        if (self.cur.kind != .MATCH) return error.UnexpectedToken;
                        optional_match = true;
                    }
                    self.advance(); // consume MATCH
                    const additional_pattern = try self.parseGraphPattern();
                    for (additional_pattern.chains) |additional_chain| {
                        var chain = additional_chain;
                        if (clause_optional) chain.is_optional = true;
                        try post_where_chains.append(self.arena.allocator(), chain);
                    }
                    var clause_where: ?ast.Expr = null;
                    // Check for WHERE clause after this MATCH
                    if (self.cur.kind == .WHERE) {
                        self.advance();
                        // SONNY-3184: as above.
                        for (post_where_chains.items) |chain| {
                            if (chain.is_optional) optional_where = true;
                        }
                        // Combine with existing where_expr using AND
                        const new_where = try self.parseOrExpr();
                        clause_where = new_where;
                        if (where_expr) |existing_where| {
                            where_expr = try self.makeBinary(.And, existing_where, new_where);
                        } else {
                            where_expr = new_where;
                        }
                    }
                    try match_clauses.append(self.arena.allocator(), .{ .optional = clause_optional, .end = post_where_chains.items.len, .where = clause_where });
                }
                combined_gp = .{ .chains = try post_where_chains.toOwnedSlice(self.arena.allocator()) };
            }

            // After MATCH ... WHERE, check for MERGE - support MATCH ... MERGE pattern
            if (self.cur.kind == .MERGE) {
                const merge_stmt = try self.parseMergeStatement();
                const merge_ptr = try self.arena.allocator().create(ast.MergeStatement);
                merge_ptr.* = merge_stmt.Merge;
                merge_statement = merge_ptr;
            }

            // After MATCH ... WHERE, check for CREATE - support multiple CREATE clauses
            // e.g., MATCH (a), (b), (c) CREATE (a)-[:R]->(b) CREATE (a)-[:R]->(c)
            if (self.cur.kind == .CREATE) {
                have_create = true;
                var create_chains = std.ArrayList(ast.Chain).empty;
                while (self.cur.kind == .CREATE) {
                    try self.countWriteClause(&write_clauses);
                    self.advance();
                    const cp = try self.parseGraphPattern();
                    for (cp.chains) |chain| {
                        try create_chains.append(self.arena.allocator(), chain);
                    }
                }
                create_pattern = .{ .chains = try create_chains.toOwnedSlice(self.arena.allocator()) };
            }

            break :blk_pat combined_gp;
        } else if (have_create) blk_create: {
            // CREATE pattern without MATCH: use empty pattern for match
            self.path_aliases.clearRetainingCapacity();
            break :blk_create .{ .chains = &.{} };
        } else blk_empty: {
            // No MATCH or CREATE: use empty pattern, and ensure no stale aliases
            self.path_aliases.clearRetainingCapacity();
            break :blk_empty .{ .chains = &.{} };
        };

        // Parse WHERE clause (for CREATE patterns or after MATCH)
        if (!have_match and where_expr == null and self.cur.kind == .WHERE) {
            self.advance();
            where_expr = try self.parseOrExpr();
        }

        // Parse FILTER clause (ISO/IEC 39075:2024)
        var filter_expr: ?ast.Expr = null;
        if (self.cur.kind == .FILTER) {
            self.advance();
            // FILTER can have optional WHERE keyword: "FILTER WHERE expr" or "FILTER expr"
            if (self.cur.kind == .WHERE) {
                self.advance();
            }
            filter_expr = try self.parseOrExpr();
        }

        // Parse inline LET clause (after MATCH/WHERE/FILTER, before WITH/RETURN)
        // Syntax: MATCH ... LET var1 = expr1, var2 = expr2 RETURN ...
        // Note: These are computed bindings (no $ prefix), different from parameter bindings
        var inline_let_bindings = std.ArrayList(ast.LetBinding).empty;
        if (self.cur.kind == .LET) {
            self.advance();
            while (true) {
                // Parse variable name (no $ prefix for inline LET)
                if (self.cur.kind != .identifier) return self.unexpected("expected identifier after LET");
                const var_name = self.cur.lexeme;
                self.advance();
                _ = try self.expect(.eq);
                const value_expr = try self.parseOrExpr();
                try inline_let_bindings.append(self.arena.allocator(), .{ .variable = var_name, .value = value_expr });
                // Allow comma for multiple bindings: LET x = 1, y = 2
                if (self.cur.kind == .comma) {
                    self.advance();
                    continue;
                }
                break;
            }
        }

        // Optional WITH projection forwarding (works for both MATCH and CREATE)
        // CANARY: REQ=REQ-GQL-CHAIN; FEATURE="Query Chaining via WITH"; ASPECT=Parser; STATUS=TESTED; TEST=graph_algorithms; OWNER=parser; UPDATED=2025-10-10
        var next_query_ptr: ?*ast.Query = null;
        if (have_match and self.cur.kind == .FOR and !have_create and merge_statement == null) {
            // ISO/IEC 39075: a FOR after a MATCH extends each matched row
            // (`MATCH (n) FOR x IN n.list RETURN sum(x)`). It is the chain
            // `MATCH ... WITH <its variables> FOR ...`, whose FOR runs over
            // every row of the MATCH; it was a syntax error.
            with_clause = .{ .items = try self.patternVariableItems(pat) };
            pre_with_where = where_expr;
            next_query_ptr = try self.parseForContinuation();
        } else if (self.cur.kind == .WITH) {
            self.advance();
            // Support WITH DISTINCT for post-MATCH WITH clause
            const post_match_with_distinct = if (self.cur.kind == .DISTINCT) blk: {
                self.advance();
                break :blk true;
            } else false;
            var witems = std.ArrayList(ast.ReturnItem).empty;
            try self.parseProjectionItems(&witems);

            // Parse optional ORDER BY, LIMIT, OFFSET after WITH items
            var with_order_by: ?*ast.OrderBy = null;
            var with_limit: ?u64 = null;
            var with_offset: ?u64 = null;
            var with_limit_param: ?[]const u8 = null;
            var with_offset_param: ?[]const u8 = null;

            if (self.cur.kind == .ORDER) {
                self.advance();
                _ = try self.expect(.BY);
                var keys = std.ArrayList(ast.OrderBy.OrderKey).empty;
                while (true) {
                    const key_expr = try self.parseOrExpr();
                    const mods = try self.parseOrderKeyModifiers();
                    try keys.append(self.arena.allocator(), .{ .expr = key_expr, .desc = mods.desc, .nulls = mods.nulls });
                    if (self.cur.kind != .comma) break;
                    self.advance();
                }
                const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                order_by_ptr.* = .{ .keys = try keys.toOwnedSlice(self.arena.allocator()) };
                with_order_by = order_by_ptr;
            }

            if (self.cur.kind == .LIMIT) {
                self.advance();
                const lim = try self.parseLimitValue();
                with_limit = lim.value;
                with_limit_param = lim.param;
            }

            if (self.cur.kind == .OFFSET or self.cur.kind == .SKIP) {
                self.advance();
                const off = try self.parseLimitValue();
                with_offset = off.value;
                with_offset_param = off.param;
            }

            with_clause = .{
                .items = try witems.toOwnedSlice(self.arena.allocator()),
                .distinct = post_match_with_distinct,
                .order_by = with_order_by,
                .limit = with_limit,
                .offset = with_offset,
                .limit_param = with_limit_param,
                .offset_param = with_offset_param,
            };
            // SONNY-3140: the WHERE before the WITH filters the pattern's rows,
            // the one after it the WITH's rows; `where_clause` joins them.
            pre_with_where = where_expr;
            // Allow an additional WHERE after WITH to filter the projected bindings
            if (self.cur.kind == .WHERE) {
                self.advance();
                const cond2 = try self.parseOrExpr();
                with_where = cond2;
                if (where_expr) |cond1| {
                    where_expr = try self.makeBinary(.And, cond1, cond2);
                } else {
                    where_expr = cond2;
                }
            }

            // CANARY: REQ=REQ-GQL-WITH-CHAIN-001; FEATURE="ChainedWithClauses"; ASPECT=ParserSupport; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=parser; UPDATED=2025-12-24
            // Check for query chaining: WITH ... WITH/MATCH/CREATE/FOR ...
            // If we see WITH, MATCH, CREATE, or FOR after WITH, parse it as a chained query or statement
            // SONNY-6337: and OPTIONAL MATCH (`MATCH (q) WITH q OPTIONAL MATCH
            // (q)-[:S]->(t)`), which was a syntax error.
            if (self.cur.kind == .WITH or self.cur.kind == .MATCH or self.cur.kind == .OPTIONAL or self.cur.kind == .CREATE or self.cur.kind == .FOR or self.cur.kind == .MERGE) {
                if (self.cur.kind == .FOR) {
                    // FOR needs special handling as it's a statement, not a query
                    next_query_ptr = try self.parseForContinuation();
                } else if (self.cur.kind == .MERGE) {
                    // GAP #57: MERGE needs special handling as it's a statement, not a query.
                    // Parse the MERGE and wrap it in a query for chaining.
                    const merge_stmt = try self.parseMergeStatement();
                    const merge_ptr = try self.arena.allocator().create(ast.MergeStatement);
                    merge_ptr.* = merge_stmt.Merge;
                    const next_query = ast.Query{
                        .optional_match = false,
                        .match = .{ .chains = &.{} },
                        .create_pattern = null,
                        .where_clause = null,
                        .with_clause = null,
                        .set_clauses = &.{},
                        .remove_clauses = &.{},
                        .ret = merge_stmt.Merge.return_clause orelse .{ .items = &.{}, .distinct = false },
                        .order_by = null,
                        .limit = null,
                        .offset = null,
                        .next_query = null,
                        .group_by = null,
                        .having = null,
                        .merge_statement = merge_ptr,
                    };
                    const next_ptr = try self.arena.allocator().create(ast.Query);
                    next_ptr.* = next_query;
                    next_query_ptr = next_ptr;
                } else {
                    // Parse the continuation as a new query
                    const next_query = try self.parseNestedQuery();
                    // Allocate on arena and store pointer
                    const next_ptr = try self.arena.allocator().create(ast.Query);
                    next_ptr.* = next_query;
                    next_query_ptr = next_ptr;
                }

                // Current query acts as a WITH-only query (no explicit RETURN needed)
                // The WITH clause serves as an implicit RETURN for passing bindings forward
            }
        }
        // GROUP BY (optional)
        if (self.cur.kind == .GROUP) {
            self.advance();
            _ = try self.expect(.BY);
            var keys_list = std.ArrayList(ast.Expr).empty;
            // one or more expressions separated by commas
            while (true) {
                try keys_list.append(self.arena.allocator(), try self.parseOrExpr());
                if (self.cur.kind != .comma) break;
                self.advance();
            }
            group_by = .{ .keys = try keys_list.toOwnedSlice(self.arena.allocator()) };
            // Optional HAVING predicate directly after GROUP BY
            // Also accept WHERE after GROUP BY as post-aggregation filter (common user expectation)
            if (self.cur.kind == .HAVING or self.cur.kind == .WHERE) {
                self.advance();
                having_expr = try self.parseOrExpr();
            }
            // A CREATE or MERGE after a WITH's GROUP BY / HAVING is a chained
            // part of its own, which the write-shape allowlist refuses (0A000);
            // it was a syntax error (the statement ended at it).
            if (with_clause != null and next_query_ptr == null and (self.cur.kind == .CREATE or self.cur.kind == .MERGE)) {
                next_query_ptr = try self.parseWriteContinuation();
            }
        }

        // Parse SET clauses if present (before RETURN)
        var set_clauses: []ast.SetClause = &.{};
        var set_clause_ends: []const usize = &.{};
        if (self.cur.kind == .SET) {
            // SONNY-3146: consecutive SET clauses are one list, in order
            // (`SET n.x = 1 SET n.y = 2` was a syntax error). SONNY-3190:
            // appended to ONE list (rebuilding it per clause was quadratic),
            // at most `max_write_clauses_per_part` clauses. SONNY-3242: where
            // each clause ends, when there are several (a later clause reads
            // what an earlier one wrote).
            var all = std.ArrayList(ast.SetClause).empty;
            var ends = std.ArrayList(usize).empty;
            while (self.cur.kind == .SET) {
                try self.countWriteClause(&write_clauses);
                self.advance();
                try self.appendSetClauses(&all);
                try ends.append(self.arena.allocator(), all.items.len);
            }
            set_clauses = try all.toOwnedSlice(self.arena.allocator());
            if (ends.items.len > 1) set_clause_ends = try ends.toOwnedSlice(self.arena.allocator());
        }

        // Parse REMOVE clauses if present (before RETURN)
        var remove_clauses: []ast.RemoveClause = &.{};
        if (self.cur.kind == .REMOVE) {
            // SONNY-3146: consecutive REMOVE clauses are one list. A SET
            // after a REMOVE stays a syntax error: the executors apply every
            // SET before every REMOVE. SONNY-3190: one list, capped.
            var all = std.ArrayList(ast.RemoveClause).empty;
            while (self.cur.kind == .REMOVE) {
                try self.countWriteClause(&write_clauses);
                self.advance();
                const more = try self.parseRemoveClauses();
                try all.appendSlice(self.arena.allocator(), more);
            }
            remove_clauses = try all.toOwnedSlice(self.arena.allocator());
        }

        // Parse DELETE clause if present (for CREATE ... WITH ... DELETE ... pattern)
        // CANARY: REQ=REQ-GQL-DELETE; FEATURE="DELETE in Query"; ASPECT=Parser; STATUS=TESTED; TEST=no-id-collision-on-delete-create; OWNER=parser; UPDATED=2025-10-14
        var delete_items: []ast.DeleteItem = &.{};
        var split_create = false;
        // SONNY-3384: and DETACH DELETE. After a SET or a REMOVE the query
        // left `DETACH` unparsed, and the rest (`DELETE x RETURN ...`) ran as
        // a statement of its own: the SET was applied, the delete skipped,
        // and the RETURN answered one row of 0.
        var detach_delete = false;
        if (self.cur.kind == .DETACH) {
            self.advance();
            detach_delete = true;
            if (self.cur.kind != .DELETE) _ = try self.expect(.DELETE);
        }
        if (self.cur.kind == .DELETE) {
            self.advance();
            delete_items = try self.parseDeleteItems();

            // After DELETE, we can have another CREATE pattern
            // This allows queries like: CREATE (n) WITH ... DELETE n CREATE (m) RETURN ...
            // SONNY-3146 (I5): a CREATE here REPLACED a CREATE before the
            // DELETE, which was then never run. Every CREATE clause is kept;
            // a statement with one on both sides of its DELETE is marked, and
            // the write-shape validator refuses it (the executors run all of
            // a statement's CREATE before its DELETE).
            // SONNY-3190: one list, capped.
            if (self.cur.kind == .CREATE) {
                var all = std.ArrayList(ast.Chain).empty;
                if (create_pattern) |earlier| {
                    split_create = true;
                    try all.appendSlice(self.arena.allocator(), earlier.chains);
                }
                while (self.cur.kind == .CREATE) {
                    try self.countWriteClause(&write_clauses);
                    self.advance();
                    const cp = try self.parseGraphPattern();
                    try all.appendSlice(self.arena.allocator(), cp.chains);
                }
                create_pattern = .{ .chains = try all.toOwnedSlice(self.arena.allocator()) };
            }
        }

        // Parse CALL clause if present (for MATCH ... CALL ... YIELD pattern)
        var call_clause: ?ast.CallClause = null;
        if (self.cur.kind == .CALL) {
            self.advance();
            // Parse procedure call expression (e.g., algo.bfs.stream(start, {maxDepth: 3}))
            const procedure = try self.parseOrExpr();

            // YIELD clause is required for MATCH+CALL pattern
            var yield_items: ?[]ast.ReturnItem = null;
            if (self.cur.kind == .YIELD) {
                self.advance();
                var items = std.ArrayList(ast.ReturnItem).empty;
                try self.parseProjectionItems(&items);
                yield_items = try items.toOwnedSlice(self.arena.allocator());
            }

            call_clause = .{
                .procedure = procedure,
                .yield_items = yield_items,
            };
        }

        // RETURN item (, item)* (now after SET/REMOVE/CALL, optional if SET/REMOVE present or query chaining)
        var return_clause: ast.ReturnClause = undefined;
        if (self.cur.kind == .RETURN) {
            self.advance();
            const distinct = if (self.cur.kind == .DISTINCT) blk: {
                self.advance();
                break :blk true;
            } else false;
            var items = std.ArrayList(ast.ReturnItem).empty;
            try self.parseProjectionItems(&items);
            return_clause = .{ .items = try items.toOwnedSlice(self.arena.allocator()), .distinct = distinct };

            // Allow WHERE after RETURN items as post-projection filter
            if (self.cur.kind == .WHERE) {
                self.advance();
                having_expr = try self.parseOrExpr();
            }

            // Allow GROUP BY (and optional HAVING) after RETURN as well
            if (self.cur.kind == .GROUP) {
                self.advance();
                _ = try self.expect(.BY);
                var keys_list2 = std.ArrayList(ast.Expr).empty;
                while (true) {
                    try keys_list2.append(self.arena.allocator(), try self.parseOrExpr());
                    if (self.cur.kind != .comma) break;
                    self.advance();
                }
                group_by = .{ .keys = try keys_list2.toOwnedSlice(self.arena.allocator()) };
                // Also accept WHERE after GROUP BY as post-aggregation filter
                if (self.cur.kind == .HAVING or self.cur.kind == .WHERE) {
                    self.advance();
                    having_expr = try self.parseOrExpr();
                }
            }
        } else if (merge_statement != null) {
            // MERGE with optional RETURN from merge_statement
            if (merge_statement.?.return_clause) |rc| {
                return_clause = rc;
            } else {
                return_clause = .{ .items = &.{}, .distinct = false };
            }
        } else if (set_clauses.len > 0 or remove_clauses.len > 0 or delete_items.len > 0 or create_pattern != null) {
            // SET/REMOVE/DELETE/CREATE without RETURN - create empty return clause
            return_clause = .{ .items = &.{}, .distinct = false };
        } else if (next_query_ptr != null and with_clause != null) {
            // Query chaining: WITH followed by MATCH/CREATE
            // Use WITH items as implicit RETURN to pass bindings forward
            return_clause = .{ .items = with_clause.?.items, .distinct = false };
        } else if (select_mode and initial_with_clause != null) {
            // SELECT was parsed and stored in initial_with_clause
            // Use SELECT items as implicit RETURN
            return_clause = .{ .items = initial_with_clause.?.items, .distinct = false };
        } else if (!have_match and !have_create) {
            // No pattern - check if we have RETURN
            if (self.cur.kind != .RETURN) {
                _ = try self.expect(.RETURN);
                unreachable;
            }
            // RETURN-only query without pattern is allowed
        } else {
            // No SET/REMOVE/CREATE, no chaining, and no RETURN - error
            _ = try self.expect(.RETURN);
            unreachable;
        }

        var ord: ?ast.OrderBy = null;
        if (self.cur.kind == .ORDER) {
            self.advance();
            _ = try self.expect(.BY);
            var keys = std.ArrayList(ast.OrderBy.OrderKey).empty;
            // first expression key - allow expressions now
            const expr1 = try self.parseOrExpr();
            // Parse-time enforcement: forbid function calls inside ORDER BY keys when policy active.
            // We examine the AST recursively; if any call node appears, raise an IllegalOrderKey style error.
            if (self.forbid_orderby_calls and self.containsCall(expr1)) {
                // Message string matched in diagnostics mapping path (server expects substring)
                self.last_error = "function calls in ORDER BY are disabled"; // triggers IllegalOrderKey diagnostic
                return error.UnexpectedToken;
            }
            // Check if it's an ordinal
            if (expr1 == .Int and self.isValidOrdinal(expr1.Int, return_clause.items.len)) {
                self.has_ordinal_sort_key = true;
            }
            const mods1 = try self.parseOrderKeyModifiers();
            try keys.append(self.arena.allocator(), .{ .expr = expr1, .desc = mods1.desc, .nulls = mods1.nulls });
            while (self.cur.kind == .comma) {
                self.advance();
                const exprk = try self.parseOrExpr();
                if (self.forbid_orderby_calls and self.containsCall(exprk)) {
                    self.last_error = "function calls in ORDER BY are disabled";
                    return error.UnexpectedToken;
                }
                // Check if it's an ordinal
                if (exprk == .Int and self.isValidOrdinal(exprk.Int, return_clause.items.len)) {
                    self.has_ordinal_sort_key = true;
                }
                const modsk = try self.parseOrderKeyModifiers();
                try keys.append(self.arena.allocator(), .{ .expr = exprk, .desc = modsk.desc, .nulls = modsk.nulls });
            }
            ord = .{ .keys = try keys.toOwnedSlice(self.arena.allocator()) };
        }

        var limit: ?usize = null;
        var offset: ?usize = null;
        var limit_param: ?[]const u8 = null;
        var offset_param: ?[]const u8 = null;

        // Additional legality enforcement: when ident_order_only policy active, reject any ORDER BY key that is not a bare identifier.
        if (ord) |ob| {
            if (self.ident_order_only) {
                var i_chk: usize = 0;
                while (i_chk < ob.keys.len) : (i_chk += 1) {
                    const ke = ob.keys[i_chk].expr;
                    if (ke != .Ident) {
                        if (self.containsCall(ke)) {
                            self.last_error = "function calls in ORDER BY are disabled";
                        } else {
                            self.last_error = "ORDER BY key must be identifier";
                        }
                        return error.UnexpectedToken;
                    }
                }
            }
        }

        // Parse LIMIT and OFFSET in any order
        // First check for LIMIT
        if (self.cur.kind == .LIMIT) {
            self.advance();
            const lim = try self.parseLimitValue();
            limit = if (lim.value) |v| @as(usize, @intCast(v)) else null;
            limit_param = lim.param;
        }
        // Check for OFFSET/SKIP
        if (self.cur.kind == .OFFSET or self.cur.kind == .SKIP) {
            self.advance();
            const off = try self.parseLimitValue();
            offset = if (off.value) |v| @as(usize, @intCast(v)) else null;
            offset_param = off.param;
        }
        // Check for LIMIT again (in case it comes after OFFSET)
        if (limit == null and limit_param == null and self.cur.kind == .LIMIT) {
            self.advance();
            const lim = try self.parseLimitValue();
            limit = if (lim.value) |v| @as(usize, @intCast(v)) else null;
            limit_param = lim.param;
        }

        // Keep let_bindings and inline_let_bindings separate for proper evaluation timing
        // Parameter bindings (before MATCH) are evaluated once upfront
        // Inline bindings (after MATCH) are evaluated per result row with matched variables in scope

        return .{
            .let_bindings = try let_bindings.toOwnedSlice(self.arena.allocator()),
            .inline_let_bindings = try inline_let_bindings.toOwnedSlice(self.arena.allocator()),
            .optional_match = optional_match,
            .match = pat,
            .create_pattern = create_pattern,
            .where_clause = where_expr,
            .filter_clause = filter_expr,
            .with_clause = if (with_clause) |wc| wc else initial_with_clause,
            .is_initial_with = with_clause == null and initial_with_clause != null,
            // SONNY-3139: the initial WITH (not a SELECT) and its WHERE, kept
            // when a WITH after the MATCH takes `with_clause`.
            .initial_with = if (select_mode) null else initial_with_clause,
            .initial_where = if (select_mode) null else initial_where_expr,
            .select_projection = select_mode,
            .optional_where = optional_where,
            .match_clauses = try match_clauses.toOwnedSlice(self.arena.allocator()),
            .pre_with_where = pre_with_where,
            .with_where = with_where,
            .split_create = split_create,
            .set_clauses = set_clauses,
            .set_clause_ends = set_clause_ends,
            .remove_clauses = remove_clauses,
            .delete_items = delete_items,
            .detach_delete = detach_delete,
            .group_by = group_by,
            .having = having_expr,
            .ret = return_clause,
            .order_by = ord,
            .limit = limit,
            .offset = offset,
            .limit_param = limit_param,
            .offset_param = offset_param,
            .path_variable = path_variable,
            .call_clause = call_clause,
            .next_query = next_query_ptr, // Query chaining support
            .initial_call_subquery = initial_call_subquery,
            .unwind_clause = unwind_clause,
            .merge_statement = merge_statement,
        };
    }
    fn isValidOrdinal(self: *Parser, n: i64, items_len: usize) bool {
        _ = self;
        if (n <= 0) return false;
        const idx: usize = @intCast(n);
        return idx >= 1 and idx <= items_len;
    }

    fn isPathAlias(self: *Parser, e: ast.Expr) bool {
        // True only if expr is an identifier that matches a collected chain alias.
        if (e != .Ident) return false;
        const name = e.Ident;
        for (self.path_aliases.items) |ali| {
            if (std.mem.eql(u8, ali, name)) return true;
        }
        return false;
    }

    fn isProjectedIdent(self: *Parser, name: []const u8, items: []ast.ReturnItem) bool {
        _ = self; // unused
        // An ORDER BY identifier is legal if it's one of the RETURN aliases or simple identifiers
        var i: usize = 0;
        while (i < items.len) : (i += 1) {
            const it = items[i];
            if (it.alias) |al| {
                if (std.mem.eql(u8, al, name)) return true;
            } else if (it.expr == .Ident) {
                if (std.mem.eql(u8, it.expr.Ident, name)) return true;
            }
        }
        return false;
    }

    fn parseGraphPattern(self: *Parser) ParserError!ast.GraphPattern {
        var chains = std.ArrayList(ast.Chain).empty;

        // CANARY: REQ=REQ-GQL-PATH-MODES-003; FEATURE="GQL Path Mode Parsing"; ASPECT=Parser; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=parser; UPDATED=2026-01-08
        // Check for path mode specifier (WALK, TRAIL, ACYCLIC, SIMPLE) before the pattern
        var path_mode: ast.PathMode = .walk;
        var path_mode_explicit = false;
        if (self.cur.kind == .WALK) {
            self.advance();
            path_mode = .walk;
            path_mode_explicit = true;
        } else if (self.cur.kind == .TRAIL) {
            self.advance();
            path_mode = .trail;
            path_mode_explicit = true;
        } else if (self.cur.kind == .ACYCLIC) {
            self.advance();
            path_mode = .acyclic;
            path_mode_explicit = true;
        } else if (self.cur.kind == .SIMPLE) {
            self.advance();
            path_mode = .simple;
            path_mode_explicit = true;
        }

        while (true) {
            // parse a chain with one-or-more hops
            var hops = std.ArrayList(ast.Hop).empty;
            // Optional path alias: ident '=' before a node pattern or shortestPath function
            // CANARY: REQ=REQ-GQL-091; FEATURE="PathAssignmentAfterWITH"; ASPECT=Parser; STATUS=TESTED; TEST=subgraph-isomorphism; OWNER=parser; UPDATED=2025-10-14
            var chain_name: ?[]const u8 = null;
            if ((self.cur.kind == .identifier or self.cur.kind == .PATH or self.isKeyword(self.cur.kind)) and self.peekKind() == .eq) {
                chain_name = self.cur.lexeme;
                self.advance(); // ident, PATH, or keyword
                _ = try self.expect(.eq);

                // Check if this is a shortestPath or allShortestPaths function call
                if (self.cur.kind == .identifier) {
                    const func_name = self.cur.lexeme;
                    if (std.ascii.eqlIgnoreCase(func_name, "shortestPath") or std.ascii.eqlIgnoreCase(func_name, "allShortestPaths")) {
                        // This is a path function - create a special chain with shortestPath marker
                        self.advance(); // consume function name
                        _ = try self.expect(.l_paren);
                        // SONNY-3133: `p = shortestPath(p = shortestPath(...))`
                        // recursed with no limit.
                        try self.enterRecursion();
                        defer self.leaveRecursion();
                        const inner_pattern = try self.parseGraphPattern();
                        _ = try self.expect(.r_paren);

                        // Store the shortestPath pattern as a special chain
                        // The execution engine will handle this specially
                        const is_all = std.ascii.eqlIgnoreCase(func_name, "allShortestPaths");
                        _ = is_all; // Will use this in execution

                        // For now, just return the inner pattern with the path name
                        // Mark as shortestPath so execution can distinguish from regular path assignments
                        for (inner_pattern.chains) |chain| {
                            var modified_chain = chain;
                            modified_chain.name = chain_name;
                            modified_chain.is_shortest = true;
                            modified_chain.path_mode = path_mode;
                            modified_chain.path_mode_explicit = path_mode_explicit;
                            try chains.append(self.arena.allocator(), modified_chain);
                        }

                        // comma-separated chains
                        if (self.cur.kind != .comma) break;
                        self.advance();
                        continue;
                    }
                }
            }
            var left = try self.parseNodePattern();
            while (true) {
                // expect a connector for a hop: '-', '<-', or '->'
                var dir: ast.RelDir = .undirected;
                if (self.cur.kind == .minus) {
                    // Check for bracketless undirected relationship (--)
                    if (self.peekKind() == .minus) {
                        self.advance(); // first -
                        self.advance(); // second -
                        const rel = ast.RelPattern{
                            .name = null,
                            .types = &.{},
                            .props = null,
                            .dir = .undirected,
                            .min_len = null,
                            .max_len = null,
                        };
                        const right = try self.parseNodePattern();
                        try hops.append(self.arena.allocator(), .{ .left = left, .rel = rel, .right = right });
                        left = right;
                        continue;
                    }
                    self.advance();
                } else if (self.cur.kind == .arrow_l) {
                    self.advance();
                    // Check for bracketless left-directed relationship (<-() without bracket)
                    if (self.cur.kind == .l_paren) {
                        dir = .left;
                        const rel = ast.RelPattern{
                            .name = null,
                            .types = &.{},
                            .props = null,
                            .dir = .left,
                            .min_len = null,
                            .max_len = null,
                        };
                        const right = try self.parseNodePattern();
                        try hops.append(self.arena.allocator(), .{ .left = left, .rel = rel, .right = right });
                        left = right;
                        continue;
                    }
                    dir = .left;
                } else if (self.cur.kind == .arrow_r) {
                    self.advance();
                    // Check for bracketless right-directed relationship (->() without bracket)
                    if (self.cur.kind == .l_paren) {
                        dir = .right;
                        const rel = ast.RelPattern{
                            .name = null,
                            .types = &.{},
                            .props = null,
                            .dir = .right,
                            .min_len = null,
                            .max_len = null,
                        };
                        const right = try self.parseNodePattern();
                        try hops.append(self.arena.allocator(), .{ .left = left, .rel = rel, .right = right });
                        left = right;
                        continue;
                    }
                    dir = .right;
                } else {
                    break;
                }
                // Parse the relationship pattern first, then determine final direction from trailing connector
                var rel = try self.parseRelPattern(dir);
                // trailing connector to right node: -, ->, or <-
                // CRITICAL FIX: For patterns like -[*]-> or -[:R*1]->, the direction should come from
                // the TRAILING connector (->), not the leading one (-). Update the direction here.
                if (self.cur.kind == .arrow_r) {
                    rel.dir = .right;
                    self.advance();
                } else if (self.cur.kind == .arrow_l) {
                    rel.dir = .left;
                    self.advance();
                } else if (self.cur.kind == .minus) {
                    // Trailing - means undirected (already the default)
                    self.advance();
                }
                const right = try self.parseNodePattern();
                try hops.append(self.arena.allocator(), .{ .left = left, .rel = rel, .right = right });
                left = right; // chain continues from the right node
            }
            if (self.collect_chain_aliases) {
                if (chain_name) |an| {
                    // record alias name for ORDER BY checks later
                    try self.path_aliases.append(self.arena.allocator(), an);
                }
            }
            // If no hops were parsed, this chain is a single node pattern. Record it in head.
            const owned_hops = try hops.toOwnedSlice(self.arena.allocator());
            var head: ?ast.NodePattern = null;
            if (owned_hops.len == 0) {
                head = left;
            }
            try chains.append(self.arena.allocator(), .{ .name = chain_name, .hops = owned_hops, .head = head, .path_mode = path_mode, .path_mode_explicit = path_mode_explicit });
            // comma-separated chains
            if (self.cur.kind != .comma) break;
            self.advance();
        }
        return .{ .chains = try chains.toOwnedSlice(self.arena.allocator()) };
    }

    fn parseNodePattern(self: *Parser) ParserError!ast.NodePattern {
        _ = try self.expect(.l_paren);
        var name: ?[]const u8 = null;
        // Accept keywords as variable names (e.g., MATCH (create:Person))
        if (self.cur.kind == .identifier or self.isKeyword(self.cur.kind)) {
            name = self.cur.lexeme;
            self.advance();
        }
        var labels = std.ArrayList([]const u8).empty;
        while (self.cur.kind == .colon) {
            self.advance();
            // Accept keywords as label names (e.g., :Property, :Type)
            const l = try self.expectIdentifierOrKeyword();
            try labels.append(self.arena.allocator(), l.lexeme);
        }
        var props: ?[]ast.Property = null;
        if (self.cur.kind == .l_brace) {
            props = try self.parsePropertyMap();
        }
        _ = try self.expect(.r_paren);
        return .{ .name = name, .labels = try labels.toOwnedSlice(self.arena.allocator()), .props = props };
    }

    fn parseRelPattern(self: *Parser, dir: ast.RelDir) ParserError!ast.RelPattern {
        _ = try self.expect(.l_bracket);
        var name: ?[]const u8 = null;
        // Accept keywords as variable names (e.g., MATCH ()-[property:KNOWS]->())
        if (self.cur.kind == .identifier or self.isKeyword(self.cur.kind)) {
            name = self.cur.lexeme;
            self.advance();
        }
        var types = std.ArrayList([]const u8).empty;
        while (self.cur.kind == .colon) {
            self.advance();
            // Accept keywords as relationship type names
            const tkn = try self.expectIdentifierOrKeyword();
            try types.append(self.arena.allocator(), tkn.lexeme);
            while (self.cur.kind == .bar) {
                // If inside pattern comprehension, only consume | if it's followed by a type identifier
                if (self.pattern_comp_depth > 0) {
                    const next = self.peekToken();
                    if (next != .identifier and !self.isKeyword(next)) break;
                }
                self.advance();
                // Accept keywords as alternative relationship type names
                const alt = try self.expectIdentifierOrKeyword();
                try types.append(self.arena.allocator(), alt.lexeme);
            }
        }
        // optional variable-length quantifier: *[min][..[max]]
        var min_len: ?u32 = null;
        var max_len: ?u32 = null;
        if (self.cur.kind == .star) {
            self.advance();
            if (self.cur.kind == .integer_lit) {
                const min_tok = self.cur;
                self.advance();
                min_len = @as(u32, @intCast(try std.fmt.parseInt(u32, min_tok.lexeme, 10)));
                max_len = min_len;
            }
            if (self.cur.kind == .dotdot) {
                self.advance();
                // may have max
                if (self.cur.kind == .integer_lit) {
                    const max_tok = self.cur;
                    self.advance();
                    max_len = @as(u32, @intCast(try std.fmt.parseInt(u32, max_tok.lexeme, 10)));
                } else {
                    // open upper bound
                    max_len = null;
                }
                // if min was integer before dotdot, keep it; else min defaults 0
                if (min_len == null) min_len = 1;
            }
            if (min_len == null and max_len == null) {
                // plain * => 1..∞ (at least one hop per GQL/Cypher convention)
                min_len = 1;
                max_len = null;
            }
            if (min_len != null and max_len != null and min_len.? > max_len.?) {
                return self.unexpected("relationship length min>max");
            }
            // Validate that min and max are not 0 (invalid in GQL)
            if (min_len != null and min_len.? == 0 and max_len != null and max_len.? == 0) {
                return self.unexpected("variable-length relationship with length 0 is invalid");
            }
        }
        var props: ?[]ast.Property = null;
        if (self.cur.kind == .l_brace) {
            props = try self.parsePropertyMap();
        }
        _ = try self.expect(.r_bracket);
        return .{ .name = name, .types = try types.toOwnedSlice(self.arena.allocator()), .props = props, .dir = dir, .min_len = min_len, .max_len = max_len };
    }

    fn parsePropertyMap(self: *Parser) ParserError![]ast.Property {
        _ = try self.expect(.l_brace);
        var list = std.ArrayList(ast.Property).empty;
        if (self.cur.kind != .r_brace) {
            while (true) {
                // Accept identifier, string_lit, or any keyword as property keys
                // This allows {name: 'value'}, {'name': 'value'}, and {value: 1} syntax
                // Keywords like VALUE, RETURN, etc. are valid property names
                const key = if (self.cur.kind == .string_lit)
                    try self.expect(.string_lit)
                else if (self.cur.kind == .identifier or self.isKeyword(self.cur.kind)) blk: {
                    const token = self.cur;
                    self.advance();
                    break :blk token;
                } else return self.unexpected("property key");
                _ = try self.expect(.colon);
                const expr = try self.parseOrExpr();
                const a = self.arena.allocator();
                const ep = try a.create(ast.Expr);
                ep.* = expr;
                const prop = ast.Property{ .key = key.lexeme, .value = ep };
                try list.append(self.arena.allocator(), prop);
                if (self.cur.kind != .comma) break;
                self.advance();
            }
        }
        _ = try self.expect(.r_brace);
        return try list.toOwnedSlice(self.arena.allocator());
    }

    fn parseProjectionItems(self: *Parser, out: *std.ArrayList(ast.ReturnItem)) ParserError!void {
        // Handle RETURN NO BINDINGS to return 0 rows
        if (self.cur.kind == .NO) {
            self.advance();
            if (self.cur.kind == .BINDINGS) {
                self.advance();
                // Return empty list of items - this signals no rows should be returned
                return;
            } else {
                return error.UnexpectedToken;
            }
        }

        // Handle RETURN * to return all bound variables
        if (self.cur.kind == .star) {
            self.advance();
            // Create a special marker using Ident with "*" to signal executor to return all bindings
            const star_expr = ast.Expr{ .Ident = .{ .orig = "*", .cnf = "*" } };
            try out.append(self.arena.allocator(), .{ .expr = star_expr, .alias = null });
            return;
        }

        while (true) {
            const expr = try self.parseOrExpr();
            var alias: ?[]const u8 = null;
            if (self.cur.kind == .AS) {
                self.advance();
                // Accept either identifier/keyword or quoted string literal for alias
                const a = if (self.cur.kind == .string_lit) blk: {
                    const token = self.cur;
                    self.advance();
                    break :blk token;
                } else try self.expectIdentifierOrKeyword();
                alias = a.lexeme;
            }
            try out.append(self.arena.allocator(), .{ .expr = expr, .alias = alias });
            if (self.cur.kind != .comma) break;
            self.advance();
        }
    }

    fn parseOrExpr(self: *Parser) ParserError!ast.Expr {
        try self.enterRecursion();
        defer self.leaveRecursion();
        // SONNY-3181: every expression is parsed from here; the outermost
        // one counts the links of all of them (`max_expr_links`).
        self.enterExpr();
        defer self.leaveExpr();
        var left = try self.parseAndExpr();
        while (self.cur.kind == .OR or self.cur.kind == .XOR) {
            const op_kind = self.cur.kind;
            self.advance();
            const right = try self.parseAndExpr();
            const node = try self.makeBinary(if (op_kind == .OR) .Or else .Xor, left, right);
            left = node;
        }
        return left;
    }

    fn parseAndExpr(self: *Parser) ParserError!ast.Expr {
        var left = try self.parseNotExpr();
        while (self.cur.kind == .AND) {
            self.advance();
            const right = try self.parseNotExpr();
            const node = try self.makeBinary(.And, left, right);
            left = node;
        }
        return left;
    }

    fn parseNotExpr(self: *Parser) ParserError!ast.Expr {
        if (self.cur.kind == .NOT) {
            // Check if this is NOT IN (handled in parseCmpExpr)
            if (self.peekToken() == .IN) {
                // Let parseCmpExpr handle NOT IN
                return self.parseCmpExpr();
            }

            // Check if this is NOT followed by a graph pattern - e.g., NOT (n)--()
            // Patterns start with (identifier or colon or closing paren for anonymous nodes
            if (self.peekToken() == .l_paren) {
                // Look ahead two tokens to see if this looks like a node pattern start
                const saved_lx = self.lx.*;
                const saved_cur = self.cur;

                self.advance(); // consume NOT
                self.advance(); // consume (

                // CANARY: REQ=REQ-GQL-NOT-PAREN-EXPR-001; FEATURE="NotParenExpr"; ASPECT=ParserFix; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=parser; UPDATED=2025-12-28
                // CANARY: REQ=REQ-GQL-HASLABEL-OR-001; FEATURE="HasLabelInBooleanExpr"; ASPECT=NotParenDisambiguation; STATUS=IMPL; TEST=geodetestlab/specs/gql_undirected_multi_hop.yml; OWNER=parser; UPDATED=2026-05-22
                // B10 Fix: Distinguish between NOT (n:Label...) graph pattern and NOT (n.value > 0) expression
                // If we see an identifier followed by a dot, it's a property access expression, not a node pattern
                // Node pattern indicators after identifier: :, ), {, -, <, [
                // Expression indicators after identifier: . (property access)
                //
                // GAP-0336 extension: also distinguish NOT (n:Label OR ...) — a boolean
                // expression mixing HasLabel predicates with OR/AND.  When the
                // tokens after `(ident:Label` are `OR`, `AND`, comparison ops,
                // or `:` continuing a multi-label test, treat as expression.
                var looks_like_pattern = if (self.cur.kind == .identifier)
                    // Identifier followed by . is property access (expression), not node pattern
                    self.peekToken() != .dot
                else
                    // :Label or () patterns
                    (self.cur.kind == .colon or self.cur.kind == .r_paren);

                // GAP-0336: If the lookahead so far still says "pattern", do a
                // deeper probe.  Specifically detect `(ident:Label <BOOL_OP>` —
                // that is unambiguously a HasLabel boolean expression, not a
                // node pattern.
                if (looks_like_pattern and self.cur.kind == .identifier and self.peekToken() == .colon) {
                    // Save the *probe* lexer state so we can rewind after the
                    // deeper lookahead.
                    const probe_lx = self.lx.*;
                    const probe_cur = self.cur;
                    self.advance(); // consume identifier
                    self.advance(); // consume ':'
                    // Skip the label identifier (or keyword used as label name).
                    if (self.cur.kind == .identifier or self.isKeyword(self.cur.kind)) {
                        self.advance();
                        // Now check the token after the label.  Expression
                        // indicators: OR / AND / comparison / arithmetic /
                        // chained `:` (n:A:B is still HasLabel-style).
                        const after_label = self.cur.kind;
                        const is_expr_continuation = switch (after_label) {
                            .OR, .AND, .eq, .ne, .lt, .le, .gt, .ge => true,
                            else => false,
                        };
                        if (is_expr_continuation) {
                            looks_like_pattern = false;
                        }
                    }
                    // Rewind probe.
                    self.lx.* = probe_lx;
                    self.cur = probe_cur;
                }

                // Restore position
                self.lx.* = saved_lx;
                self.cur = saved_cur;

                if (looks_like_pattern) {
                    // Parse as NOT followed by a graph pattern
                    self.advance(); // consume NOT
                    // SONNY-3181: a unary link.
                    try self.countExprLink();
                    const pattern = try self.parseGraphPattern();

                    // Create EXISTS predicate
                    const a = self.arena.allocator();
                    const pattern_ptr = try a.create(ast.GraphPattern);
                    pattern_ptr.* = pattern;
                    const exists_expr = ast.Expr{ .Exists = .{ .pattern = pattern_ptr } };

                    // Wrap in NOT
                    const ep = try a.create(ast.Expr);
                    ep.* = exists_expr;
                    return .{ .Unary = .{ .op = .Not, .expr = ep } };
                }
            }

            self.advance();
            // SONNY-3133: `NOT NOT ... x` recursed with no limit.
            try self.enterRecursion();
            defer self.leaveRecursion();
            // SONNY-3181: and it is a link of the expression.
            try self.countExprLink();
            const e = try self.parseNotExpr();
            const a = self.arena.allocator();
            const ep = try a.create(ast.Expr);
            ep.* = e;
            return .{ .Unary = .{ .op = .Not, .expr = ep } };
        }
        return self.parseCmpExpr();
    }

    fn parseCmpExpr(self: *Parser) ParserError!ast.Expr {
        const left = try self.parseAddExpr();
        // string predicates and regex have higher precedence than boolean but sit with comparisons
        if (self.cur.kind == .STARTS) {
            self.advance();
            _ = try self.expect(.WITH);
            const rhs = try self.parseAddExpr();
            const a = self.arena.allocator();
            const lp = try a.create(ast.Expr);
            const rp = try a.create(ast.Expr);
            lp.* = left;
            rp.* = rhs;
            return .{ .StartsWith = .{ .value = lp, .prefix = rp } };
        }
        if (self.cur.kind == .ENDS) {
            self.advance();
            _ = try self.expect(.WITH);
            const rhs = try self.parseAddExpr();
            const a = self.arena.allocator();
            const lp = try a.create(ast.Expr);
            const rp = try a.create(ast.Expr);
            lp.* = left;
            rp.* = rhs;
            return .{ .EndsWith = .{ .value = lp, .suffix = rp } };
        }
        if (self.cur.kind == .CONTAINS) {
            self.advance();
            const rhs = try self.parseAddExpr();
            const a = self.arena.allocator();
            const lp = try a.create(ast.Expr);
            const rp = try a.create(ast.Expr);
            lp.* = left;
            rp.* = rhs;
            return .{ .Contains = .{ .value = lp, .needle = rp } };
        }
        // Label test: n:Label (only if left is an identifier)
        if (self.cur.kind == .colon and left == .Ident) {
            self.advance();
            const label_token = try self.expectIdentifierOrKeyword();
            return .{ .HasLabel = .{ .node = left.Ident.orig, .label = label_token.lexeme } };
        }
        const op_kind = switch (self.cur.kind) {
            .eq => ast.BinOp.Eq,
            .ne => ast.BinOp.Ne,
            .lt => ast.BinOp.Lt,
            .le => ast.BinOp.Le,
            .gt => ast.BinOp.Gt,
            .ge => ast.BinOp.Ge,
            .regex_match => ast.BinOp.RegexMatch,
            .regex_not_match => ast.BinOp.RegexNotMatch,
            else => {
                if (self.cur.kind == .IN) {
                    self.advance();

                    // CANARY: REQ=REQ-GQL-IN-EXPR-001; FEATURE="InOperator"; ASPECT=ParserSupport; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=parser; UPDATED=2025-12-27
                    // Check if this is IN (subquery), IN [list], or IN <expression>
                    if (self.cur.kind == .l_paren) {
                        // IN (subquery) - parse as subquery
                        self.advance(); // consume (
                        const subquery = try self.parseQuery();
                        _ = try self.expect(.r_paren);

                        const a = self.arena.allocator();
                        const vp = try a.create(ast.Expr);
                        vp.* = left;
                        const qp = try a.create(ast.Query);
                        qp.* = subquery;
                        return .{ .InSubquery = .{ .value = vp, .subquery = qp } };
                    } else if (self.cur.kind == .l_bracket) {
                        // IN [list] - parse as list
                        self.advance(); // consume [
                        var elems = std.ArrayList(*ast.Expr).empty;
                        if (self.cur.kind != .r_bracket) {
                            while (true) {
                                const it = try self.parseOrExpr();
                                const ap = try self.arena.allocator().create(ast.Expr);
                                ap.* = it;
                                try elems.append(self.arena.allocator(), ap);
                                if (self.cur.kind != .comma) break;
                                self.advance();
                            }
                        }
                        _ = try self.expect(.r_bracket);
                        const a = self.arena.allocator();
                        const vp = try a.create(ast.Expr);
                        vp.* = left;
                        return .{ .In = .{ .value = vp, .set = try elems.toOwnedSlice(self.arena.allocator()) } };
                    } else {
                        // CANARY: REQ=REQ-GQL-IN-LISTEXPR-001; FEATURE="InListExpr"; ASPECT=FunctionCall; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=parser; UPDATED=2025-12-27
                        // IN <expression> - expression that evaluates to a list (e.g., labels(n))
                        // Use parsePostfixExpr to handle function calls like labels(n), not just identifiers
                        const list_expr = try self.parsePostfixExpr();
                        const a = self.arena.allocator();
                        const vp = try a.create(ast.Expr);
                        vp.* = left;
                        const lep = try a.create(ast.Expr);
                        lep.* = list_expr;
                        return .{ .InListExpr = .{ .value = vp, .list_expr = lep } };
                    }
                }
                if (self.cur.kind == .NOT) {
                    // NOT IN
                    self.advance();
                    _ = try self.expect(.IN);

                    // CANARY: REQ=REQ-GQL-IN-EXPR-002; FEATURE="NotInOperator"; ASPECT=ParserSupport; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=parser; UPDATED=2025-12-27
                    // Check if this is NOT IN (subquery), NOT IN [list], or NOT IN <expression>
                    if (self.cur.kind == .l_paren) {
                        // NOT IN (subquery)
                        self.advance(); // consume (
                        const subquery = try self.parseQuery();
                        _ = try self.expect(.r_paren);

                        const a = self.arena.allocator();
                        const vp = try a.create(ast.Expr);
                        vp.* = left;
                        const qp = try a.create(ast.Query);
                        qp.* = subquery;
                        return .{ .NotInSubquery = .{ .value = vp, .subquery = qp } };
                    } else if (self.cur.kind == .l_bracket) {
                        // NOT IN [list]
                        self.advance(); // consume [
                        var elems = std.ArrayList(*ast.Expr).empty;
                        if (self.cur.kind != .r_bracket) {
                            while (true) {
                                const it = try self.parseOrExpr();
                                const ap = try self.arena.allocator().create(ast.Expr);
                                ap.* = it;
                                try elems.append(self.arena.allocator(), ap);
                                if (self.cur.kind != .comma) break;
                                self.advance();
                            }
                        }
                        _ = try self.expect(.r_bracket);
                        const a = self.arena.allocator();
                        const vp = try a.create(ast.Expr);
                        vp.* = left;
                        return .{ .NotIn = .{ .value = vp, .set = try elems.toOwnedSlice(self.arena.allocator()) } };
                    } else {
                        // CANARY: REQ=REQ-GQL-IN-LISTEXPR-002; FEATURE="NotInListExpr"; ASPECT=FunctionCall; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=parser; UPDATED=2025-12-27
                        // NOT IN <expression> - expression that evaluates to a list (e.g., labels(n))
                        // Use parsePostfixExpr to handle function calls like labels(n), not just identifiers
                        const list_expr = try self.parsePostfixExpr();
                        const a = self.arena.allocator();
                        const vp = try a.create(ast.Expr);
                        vp.* = left;
                        const lep = try a.create(ast.Expr);
                        lep.* = list_expr;
                        return .{ .NotInListExpr = .{ .value = vp, .list_expr = lep } };
                    }
                }
                if (self.cur.kind == .IS) {
                    self.advance();
                    var neg = false;
                    if (self.cur.kind == .NOT) {
                        neg = true;
                        self.advance();
                    }
                    if (self.cur.kind == .NULL) {
                        self.advance();
                        const a = self.arena.allocator();
                        const tp = try a.create(ast.Expr);
                        tp.* = left;
                        return .{ .IsNull = .{ .target = tp, .negated = neg } };
                    } else if (self.cur.kind == .UNKNOWN) {
                        self.advance();
                        const a = self.arena.allocator();
                        const tp = try a.create(ast.Expr);
                        tp.* = left;
                        return .{ .IsUnknown = .{ .target = tp, .negated = neg } };
                    } else {
                        return self.unexpected("expected NULL or UNKNOWN after IS");
                    }
                }
                return left;
            },
        };
        self.advance();
        var right = try self.parseAddExpr();

        // CANARY: REQ=REQ-GQL-090; FEATURE="ChainedComparisons"; ASPECT=Parser; STATUS=TESTED; OWNER=parser; UPDATED=2025-10-14
        // Handle chained comparisons: a < b < c becomes (a < b) AND (b < c)
        var result = try self.makeBinary(op_kind, left, right);

        // Check if another comparison operator follows
        while (true) {
            const next_op = switch (self.cur.kind) {
                .eq => ast.BinOp.Eq,
                .ne => ast.BinOp.Ne,
                .lt => ast.BinOp.Lt,
                .le => ast.BinOp.Le,
                .gt => ast.BinOp.Gt,
                .ge => ast.BinOp.Ge,
                else => break,
            };

            self.advance();
            const next_right = try self.parseAddExpr();

            // Create the next comparison: right op next_right
            const next_comp = try self.makeBinary(next_op, right, next_right);

            // Combine with AND: result AND next_comp
            result = try self.makeBinary(.And, result, next_comp);

            // Update right for next iteration
            right = next_right;
        }

        return result;
    }

    fn parseAddExpr(self: *Parser) ParserError!ast.Expr {
        var left = try self.parseMulExpr();
        while (self.cur.kind == .plus or self.cur.kind == .minus or self.cur.kind == .concat) {
            const op = switch (self.cur.kind) {
                .plus => ast.BinOp.Add,
                .minus => ast.BinOp.Sub,
                .concat => ast.BinOp.Concat,
                else => unreachable,
            };
            self.advance();
            const right = try self.parseMulExpr();
            left = try self.makeBinary(op, left, right);
        }
        return left;
    }

    fn parseMulExpr(self: *Parser) ParserError!ast.Expr {
        var left = try self.parsePowerExpr();
        while (self.cur.kind == .star or self.cur.kind == .slash or self.cur.kind == .percent) {
            const op = if (self.cur.kind == .star)
                ast.BinOp.Mul
            else if (self.cur.kind == .slash)
                ast.BinOp.Div
            else
                ast.BinOp.Mod;
            self.advance();
            const right = try self.parsePowerExpr();
            left = try self.makeBinary(op, left, right);
        }
        return left;
    }

    // CANARY: REQ=REQ-GQL-POWER-002; FEATURE="PowerOperator"; ASPECT=ParserSupport; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_math_algorithms.yml; OWNER=parser; UPDATED=2025-12-27
    // Power operator has higher precedence than multiplication
    fn parsePowerExpr(self: *Parser) ParserError!ast.Expr {
        var left = try self.parseUnaryExpr();
        while (self.cur.kind == .caret) {
            self.advance();
            // Right-associative: parse right side with same precedence
            const right = try self.parseUnaryExpr();
            left = try self.makeBinary(.Power, left, right);
        }
        return left;
    }

    fn parseUnaryExpr(self: *Parser) ParserError!ast.Expr {
        // NOT is now handled in parseNotExpr at correct precedence level
        if (self.cur.kind == .EXISTS and self.peekToken() == .l_brace) {
            // CANARY: REQ=REQ-GQL-EXISTS-001; FEATURE="ExistsSubquery"; ASPECT=ParserSupport; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=parser; UPDATED=2025-12-24
            // CANARY: REQ=REQ-GQL-EXISTS-002; FEATURE="ExistsSubquery"; ASPECT=WhereClause; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=parser; UPDATED=2025-12-27
            // This is EXISTS { ... } - EXISTS predicate
            // Supports: EXISTS { pattern }, EXISTS { MATCH pattern }, EXISTS { MATCH pattern WHERE condition }
            self.advance(); // consume EXISTS
            _ = try self.expect(.l_brace);

            // Check if this is EXISTS { MATCH pattern } or EXISTS { pattern }
            if (self.cur.kind == .MATCH) {
                self.advance(); // consume MATCH
            }

            const pattern = try self.parseGraphPattern();

            // Parse optional WHERE clause inside EXISTS
            var where_clause: ?*ast.Expr = null;
            if (self.cur.kind == .WHERE) {
                self.advance(); // consume WHERE
                const where_expr = try self.parseOrExpr();
                const a = self.arena.allocator();
                const where_ptr = try a.create(ast.Expr);
                where_ptr.* = where_expr;
                where_clause = where_ptr;
            }

            _ = try self.expect(.r_brace);
            const a = self.arena.allocator();
            const pattern_ptr = try a.create(ast.GraphPattern);
            pattern_ptr.* = pattern;
            return .{ .Exists = .{ .pattern = pattern_ptr, .where = where_clause } };
        }
        if (self.cur.kind == .minus) {
            self.advance();
            // SONNY-3133: `- - ... 1` recursed with no limit.
            try self.enterRecursion();
            defer self.leaveRecursion();
            // SONNY-3181: and it is a link of the expression.
            try self.countExprLink();
            const e = try self.parseUnaryExpr();
            const a = self.arena.allocator();
            const ep = try a.create(ast.Expr);
            ep.* = e;
            return .{ .Unary = .{ .op = .Neg, .expr = ep } };
        }
        if (self.cur.kind == .plus) {
            self.advance();
            // SONNY-3133: as unary minus.
            try self.enterRecursion();
            defer self.leaveRecursion();
            try self.countExprLink();
            const e = try self.parseUnaryExpr();
            const a = self.arena.allocator();
            const ep = try a.create(ast.Expr);
            ep.* = e;
            return .{ .Unary = .{ .op = .Pos, .expr = ep } };
        }
        return self.parsePostfixExpr();
    }

    fn parsePostfixExpr(self: *Parser) ParserError!ast.Expr {
        var base = try self.parsePrimaryExpr();
        // SONNY-3181: every pass that goes on wrapped `base` in one more
        // postfix link (member access, call, index, slice, map projection):
        // `n.a.a.a ...` is as deep as it is long.
        while (true) : (try self.countExprLink()) {
            if (self.cur.kind == .dot) {
                self.advance();
                const field = if (self.cur.kind == .identifier or self.isKeyword(self.cur.kind)) blk: {
                    const token = self.cur;
                    self.advance();
                    break :blk token;
                } else try self.expect(.identifier);
                const a = self.arena.allocator();
                const bp = try a.create(ast.Expr);
                bp.* = base;
                base = .{ .Member = .{ .target = bp, .field = field.lexeme } };
                continue;
            }
            // CANARY: REQ=REQ-GQL-COUNT-001; FEATURE="CountSubquery"; ASPECT=ParserSupport; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=parser; UPDATED=2025-12-28
            // C02 Fix: Check for COUNT { MATCH pattern WHERE expr } subquery syntax
            if (self.cur.kind == .l_brace and base == .Ident and std.ascii.eqlIgnoreCase(base.Ident.orig, "count")) {
                self.advance(); // consume '{'
                // Check if this is COUNT { MATCH pattern } or COUNT { pattern }
                if (self.cur.kind == .MATCH) {
                    self.advance(); // consume MATCH
                }
                const pattern = try self.parseGraphPattern();
                const a = self.arena.allocator();
                const pat_ptr = try a.create(ast.GraphPattern);
                pat_ptr.* = pattern;

                // C02 Fix: Parse optional WHERE clause inside COUNT subquery
                var where_expr: ?*ast.Expr = null;
                if (self.cur.kind == .WHERE) {
                    self.advance(); // consume WHERE
                    const where_e = try self.parseOrExpr();
                    const we_ptr = try a.create(ast.Expr);
                    we_ptr.* = where_e;
                    where_expr = we_ptr;
                }

                _ = try self.expect(.r_brace);
                base = .{ .PatternCount = .{ .pattern = pat_ptr, .where = where_expr } };
                continue;
            }
            if (self.cur.kind == .l_paren) {
                // Check for shortestPath/allShortestPaths or size() with pattern
                if (base == .Ident) {
                    const name = base.Ident.orig;
                    if (std.ascii.eqlIgnoreCase(name, "shortestPath") or std.ascii.eqlIgnoreCase(name, "allShortestPaths")) {
                        const is_all = std.ascii.eqlIgnoreCase(name, "allShortestPaths");
                        self.advance(); // consume '('
                        // CANARY: REQ=REQ-GQL-PATH-NULL-001; FEATURE="ShortestPath"; ASPECT=NullHandling; STATUS=TESTED; TEST=geodetestlab/specs/gap_0087_0089_resolution.yml; OWNER=parser; UPDATED=2026-01-25
                        // Handle NULL input - shortestPath(null) should return NULL
                        if (self.cur.kind == .NULL) {
                            self.advance(); // consume NULL
                            _ = try self.expect(.r_paren);
                            base = .Null;
                            continue;
                        }
                        // Parse graph pattern argument
                        const pattern = try self.parseGraphPattern();
                        _ = try self.expect(.r_paren);
                        const a = self.arena.allocator();
                        const pat_ptr = try a.create(ast.GraphPattern);
                        pat_ptr.* = pattern;
                        base = .{ .ShortestPath = .{ .pattern = pat_ptr, .all = is_all } };
                        continue;
                    }
                    // Check for size() with direct graph pattern: size((n)-[r]->(m))
                    if (std.ascii.eqlIgnoreCase(name, "size")) {
                        // Peek ahead to see if this is size((pattern))
                        if (self.peekToken() == .l_paren) {
                            self.advance(); // consume '('
                            const pattern = try self.parseGraphPattern();
                            _ = try self.expect(.r_paren);
                            const a = self.arena.allocator();
                            const pat_ptr = try a.create(ast.GraphPattern);
                            pat_ptr.* = pattern;
                            base = .{ .PatternCount = .{ .pattern = pat_ptr, .where = null } };
                            continue;
                        }
                        // Otherwise fall through to regular function call handling
                        // This handles size([ pattern | expr ]) and size(expr)
                    }
                }
                // function call: base(args)
                self.advance();

                // CANARY: REQ=REQ-GQL-089; FEATURE="ListComprehension"; ASPECT=Parser; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.ymlEMENTED; OWNER=parser; UPDATED=2025-10-14
                // CANARY: REQ=REQ-FN-DISPATCH-PARITY; FEATURE="ListComprehension"; ASPECT=NoneAndSingleQuantifiers; STATUS=TESTED; TEST=tests/test_fn_dispatch_parity.zig; OWNER=parser; UPDATED=2026-08-25
                // Special handling: all/any/none/single(x IN list WHERE condition)
                // FN-DISPATCH-PARITY: `none` and `single` are advertised as
                // predicate functions by BOTH SHOW FUNCTIONS and
                // src/gql/language_metadata.zig (with the worked examples
                // `none(x IN [1,2,3] WHERE x > 5)` / `single(x IN [1,2,3]
                // WHERE x > 2)`), but this production admitted only `all` and
                // `any`, so the documented spelling was error.UnexpectedToken —
                // the construct could not be written at all. They take the
                // identical `variable IN list [WHERE predicate]` shape and the
                // quantifier semantics are exact, so they are admitted here
                // and evaluated by the same handler.
                if (base == .Ident and (std.ascii.eqlIgnoreCase(base.Ident.orig, "all") or
                    std.ascii.eqlIgnoreCase(base.Ident.orig, "any") or
                    std.ascii.eqlIgnoreCase(base.Ident.orig, "none") or
                    std.ascii.eqlIgnoreCase(base.Ident.orig, "single")) and self.cur.kind == .identifier)
                {
                    // Check if this is a list comprehension: identifier IN ...
                    const saved_idx = self.lx.idx;
                    const saved_line = self.lx.line;
                    const saved_col = self.lx.col;
                    const saved_cur = self.cur;

                    const var_token = self.cur;
                    self.advance(); // Move to token after identifier

                    if (self.cur.kind == .IN) {
                        // This is a list comprehension: all(x IN list WHERE condition)
                        self.advance(); // consume IN

                        const source_expr = try self.parseOrExpr();
                        const a = self.arena.allocator();
                        const sp = try a.create(ast.Expr);
                        sp.* = source_expr;

                        var filter: ?*ast.Expr = null;
                        if (self.cur.kind == .WHERE) {
                            self.advance(); // consume WHERE
                            const filter_expr = try self.parseOrExpr();
                            const fp = try a.create(ast.Expr);
                            fp.* = filter_expr;
                            filter = fp;
                        }

                        _ = try self.expect(.r_paren);

                        // Create ListComprehension node
                        const comp_expr = ast.Expr{ .ListComprehension = .{ .variable = var_token.lexeme, .source = sp, .filter = filter } };

                        // Wrap in Call node with function name as callee
                        const cp = try a.create(ast.Expr);
                        cp.* = base;
                        const comp_ptr = try a.create(ast.Expr);
                        comp_ptr.* = comp_expr;
                        const args_arr = try a.alloc(*ast.Expr, 1);
                        args_arr[0] = comp_ptr;
                        base = .{ .Call = .{ .callee = cp, .args = args_arr } };
                        continue;
                    } else {
                        // Not a list comprehension, restore lexer state and current token
                        self.lx.idx = saved_idx;
                        self.lx.line = saved_line;
                        self.lx.col = saved_col;
                        self.cur = saved_cur;
                    }
                }

                // CANARY: REQ=REQ-UNSUPPORTED-AGGREGATE-REJECTION; FEATURE="AggregateSetQuantifier"; ASPECT=UnsupportedAggregateReject; STATUS=TESTED; TEST=tests/test_unsupported_aggregates.zig; OWNER=parser; UPDATED=2026-08-25
                // UNSUPPORTED-AGGREGATES: refuse the recognised-but-unimplemented aggregates
                // BEFORE the argument list is parsed, so that
                // `collect_list(DISTINCT x)` reports the unsupported function by
                // name instead of tripping over the now-unexpected DISTINCT and
                // reporting a bare syntax error.
                if (base == .Ident) {
                    if (unsupportedAggregateName(base.Ident.orig)) |unsupported| {
                        return self.unsupportedAggregate(unsupported);
                    }
                }

                var args = std.ArrayList(*ast.Expr).empty;
                var saw_distinct = false;
                if (self.cur.kind != .r_paren) {
                    // CANARY: REQ=REQ-GQL-SET-QUANTIFIER-003; FEATURE="AggregateSetQuantifier"; ASPECT=ParserSupport; STATUS=TESTED; TEST=tests/test_bug731_aggregates_vectors.zig; OWNER=parser; UPDATED=2026-07-31
                    // ISO/IEC 39075:2024 <general set function> allows the
                    // <set quantifier> DISTINCT | ALL on EVERY aggregate, not
                    // just COUNT. ALL is the default and parses to no flag.
                    if (base == .Ident and acceptsSetQuantifier(base.Ident.orig)) {
                        if (self.cur.kind == .DISTINCT) {
                            saw_distinct = true;
                            self.advance();
                        } else if (self.cur.kind == .ALL) {
                            self.advance();
                        }
                    }
                    // Special handling: COUNT(*)
                    if (base == .Ident and std.ascii.eqlIgnoreCase(base.Ident.orig, "count") and self.cur.kind == .star) {
                        // Create a special identifier node for "*"
                        const star_token = self.cur;
                        self.advance();
                        const ap = try self.arena.allocator().create(ast.Expr);
                        const unicode = @import("../unicode/unicode_tables.zig");
                        const cnf = unicode.caseFoldToUpper(self.arena.allocator(), star_token.lexeme) catch star_token.lexeme;
                        ap.* = .{ .Ident = .{ .orig = star_token.lexeme, .cnf = cnf } };
                        try args.append(self.arena.allocator(), ap);
                    } else {
                        while (true) {
                            // Parse expression, handling named parameter syntax: identifier => expression
                            // We peek ahead: if we see identifier/keyword followed by =>, skip both and parse value
                            const arg = blk: {
                                // Allow identifiers AND keywords as named parameter names (GQL spec allows keywords)
                                const is_potential_param_name = self.cur.kind == .identifier or
                                    self.cur.kind == .LIMIT or self.cur.kind == .ORDER or
                                    self.cur.kind == .WHERE;

                                if (is_potential_param_name) {
                                    // Save lexer state to check for =>
                                    const saved_idx = self.lx.idx;
                                    const saved_line = self.lx.line;
                                    const saved_col = self.lx.col;

                                    // Try to peek ahead
                                    const next_tok = self.lx.next();

                                    if (next_tok.kind == .double_arrow) {
                                        // This is a named parameter (identifier => value)
                                        // Skip the identifier and => , update current token, then parse value
                                        self.cur = self.lx.next();
                                        break :blk try self.parseOrExpr();
                                    } else {
                                        // Not a named parameter, restore lexer and parse normally
                                        self.lx.idx = saved_idx;
                                        self.lx.line = saved_line;
                                        self.lx.col = saved_col;
                                        break :blk try self.parseOrExpr();
                                    }
                                } else {
                                    break :blk try self.parseOrExpr();
                                }
                            };

                            const ap = try self.arena.allocator().create(ast.Expr);
                            ap.* = arg;
                            try args.append(self.arena.allocator(), ap);
                            if (self.cur.kind != .comma) break;
                            self.advance();
                        }
                    }
                }
                _ = try self.expect(.r_paren);
                const a = self.arena.allocator();
                const cp = try a.create(ast.Expr);
                cp.* = base;
                const args_slice = try args.toOwnedSlice(self.arena.allocator());
                // Simple built-in validation: enforce arity for a few known functions
                if (base == .Ident) {
                    var name = base.Ident;
                    if (saw_distinct and std.ascii.eqlIgnoreCase(name.orig, "count")) {
                        // Rewrite to synthetic function name countDistinct so executor picks it up.
                        name = .{ .orig = "countDistinct", .cnf = "COUNTDISTINCT" };
                        // Allocate new ident expr for callee
                        const np = try a.create(ast.Expr);
                        np.* = .{ .Ident = name };
                        cp.* = np.*;
                    }
                    // Convert []*Expr -> []Expr view for validator
                    var flat = std.ArrayList(ast.Expr).empty;
                    for (args_slice) |p| try flat.append(self.arena.allocator(), p.*);
                    if (!validateBuiltinCall(name.orig, try flat.toOwnedSlice(self.arena.allocator()), self.ts_extensions) and !std.ascii.eqlIgnoreCase(name.orig, "countDistinct")) return self.unexpected("invalid builtin function call");
                }
                base = .{ .Call = .{ .callee = cp, .args = args_slice, .distinct = saw_distinct } };
                continue;
            }
            if (self.cur.kind == .l_bracket) {
                // CANARY: REQ=REQ-GQL-SLICE-002; FEATURE="ListSlicing"; ASPECT=ParserSupport; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=parser; UPDATED=2025-12-24
                // array index: base[index] or slice: base[start..end]
                self.advance();
                const a = self.arena.allocator();
                const bp = try a.create(ast.Expr);
                bp.* = base;

                // Check for slice syntax: [..end], [start..], [start..end]
                if (self.cur.kind == .dotdot) {
                    // [..end] - slice from beginning
                    self.advance();
                    const end_expr = try self.parseOrExpr();
                    _ = try self.expect(.r_bracket);
                    const ep = try a.create(ast.Expr);
                    ep.* = end_expr;
                    base = .{ .Slice = .{ .target = bp, .start = null, .end = ep } };
                    continue;
                }

                const first_expr = try self.parseOrExpr();

                if (self.cur.kind == .dotdot) {
                    // [start..] or [start..end] - slice with start
                    self.advance();
                    const sp = try a.create(ast.Expr);
                    sp.* = first_expr;

                    if (self.cur.kind == .r_bracket) {
                        // [start..] - slice to end
                        self.advance();
                        base = .{ .Slice = .{ .target = bp, .start = sp, .end = null } };
                    } else {
                        // [start..end] - full slice
                        const end_expr = try self.parseOrExpr();
                        _ = try self.expect(.r_bracket);
                        const ep = try a.create(ast.Expr);
                        ep.* = end_expr;
                        base = .{ .Slice = .{ .target = bp, .start = sp, .end = ep } };
                    }
                    continue;
                }

                // Regular index: base[index]
                _ = try self.expect(.r_bracket);
                const ip = try a.create(ast.Expr);
                ip.* = first_expr;
                base = .{ .Index = .{ .target = bp, .index = ip } };
                continue;
            }
            if (self.cur.kind == .l_brace) {
                // Map projection: n {.name, .age}
                self.advance();
                var fields = std.ArrayList([]const u8).empty;

                // Parse fields: .prop1, .prop2, ...
                while (self.cur.kind == .dot) {
                    self.advance();
                    const field_token = try self.expectIdentifierOrKeyword();
                    try fields.append(self.arena.allocator(), field_token.lexeme);

                    if (self.cur.kind == .comma) {
                        self.advance();
                    } else {
                        break;
                    }
                }

                _ = try self.expect(.r_brace);
                const a = self.arena.allocator();
                const bp = try a.create(ast.Expr);
                bp.* = base;
                base = .{ .MapProjection = .{ .source = bp, .fields = try fields.toOwnedSlice(self.arena.allocator()) } };
                continue;
            }
            // Label test: n:Label (only if base is an identifier)
            if (self.cur.kind == .colon and base == .Ident) {
                self.advance();
                const label_token = try self.expectIdentifierOrKeyword();
                return .{ .HasLabel = .{ .node = base.Ident.orig, .label = label_token.lexeme } };
            }
            break;
        }
        return base;
    }

    fn parsePrimaryExpr(self: *Parser) ParserError!ast.Expr {
        return switch (self.cur.kind) {
            .dollar => blk_param: {
                // Parameter: $identifier or $N (positional)
                // Named: $param_name, $count, $name (identifier or keyword after $)
                // Positional: $1, $2, $3 (integer literal after $, used by Go client)
                self.advance();
                if (self.cur.kind == .integer_lit) {
                    const name = self.cur;
                    self.advance();
                    break :blk_param .{ .Param = name.lexeme };
                }
                const name = try self.expectIdentifierOrKeyword();
                break :blk_param .{ .Param = name.lexeme };
            },
            .date_lit => blk_dt: {
                const tkn = self.cur;
                self.advance();
                const parsed = temporal.parseDate(tkn.lexeme) catch return self.unexpected("invalid DATE literal");
                break :blk_dt .{ .Date = .{ .raw = tkn.lexeme, .parsed = parsed } };
            },
            .datetime_lit => blk_dtt: {
                const tkn = self.cur;
                self.advance();
                const parsed = temporal.parseDateTime(tkn.lexeme, true) catch return self.unexpected("invalid DATETIME literal");
                break :blk_dtt .{ .DateTime = .{ .raw = tkn.lexeme, .parsed = parsed } };
            },
            .time_lit => blk_t: {
                const tkn = self.cur;
                self.advance();
                const parsed = temporal.parseTime(tkn.lexeme, true) catch return self.unexpected("invalid TIME literal");
                break :blk_t .{ .Time = .{ .raw = tkn.lexeme, .parsed = parsed } };
            },
            .local_datetime_lit => blk_ldt: {
                const tkn = self.cur;
                self.advance();
                const parsed = temporal.parseDateTime(tkn.lexeme, false) catch return self.unexpected("invalid LOCAL DATETIME literal");
                break :blk_ldt .{ .LocalDateTime = .{ .raw = tkn.lexeme, .parsed = parsed } };
            },
            .CASE => blk_case: {
                self.advance();
                var operand_opt: ?*ast.Expr = null;
                // Optional simple CASE operand
                if (self.cur.kind != .WHEN) {
                    const opnd = try self.parseOrExpr();
                    const pp = try self.arena.allocator().create(ast.Expr);
                    pp.* = opnd;
                    operand_opt = pp;
                }
                var whens = std.ArrayList(ast.CaseWhen).empty;
                while (self.cur.kind == .WHEN) {
                    self.advance();
                    const when_expr = try self.parseOrExpr();
                    _ = try self.expect(.THEN);
                    const then_expr = try self.parseOrExpr();
                    const a = self.arena.allocator();
                    const wp = try a.create(ast.Expr);
                    const tp = try a.create(ast.Expr);
                    wp.* = when_expr;
                    tp.* = then_expr;
                    try whens.append(self.arena.allocator(), .{ .when = wp, .then_expr = tp });
                }
                var else_p: ?*ast.Expr = null;
                if (self.cur.kind == .ELSE) {
                    self.advance();
                    const e = try self.parseOrExpr();
                    const ep = try self.arena.allocator().create(ast.Expr);
                    ep.* = e;
                    else_p = ep;
                }
                _ = try self.expect(.END);
                const wh_slice = try whens.toOwnedSlice(self.arena.allocator());
                break :blk_case .{ .Case = .{ .operand = operand_opt, .whens = wh_slice, .else_expr = else_p } };
            },
            .identifier => blk: {
                const tkn = self.cur;
                self.advance();
                // Create CNF representation for identifiers
                const unicode = @import("../unicode/unicode_tables.zig");
                const cnf = unicode.caseFoldToUpper(self.arena.allocator(), tkn.lexeme) catch tkn.lexeme;
                break :blk .{ .Ident = .{ .orig = tkn.lexeme, .cnf = cnf } };
            },
            .string_lit => blk: {
                const tkn = self.cur;
                self.advance();
                // CANARY: REQ=REQ-GQL-STRING-ESCAPE-001; FEATURE="StringEscaping"; ASPECT=Unescaping; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=parser; UPDATED=2026-01-09
                // Unescape the string literal to handle \' -> ' and other escape sequences
                break :blk .{ .String = try self.unescapeString(tkn.lexeme) };
            },
            .integer_lit => blk: {
                const tkn = self.cur;
                self.advance();
                break :blk .{ .Int = try std.fmt.parseInt(i64, tkn.lexeme, 10) };
            },
            .float_lit => blk_f: {
                const tkn = self.cur;
                self.advance();
                const lex = tkn.lexeme;

                // Check if this is scientific notation (contains e/E)
                var has_exp = false;
                var exp_idx: usize = 0;
                for (lex, 0..) |c, i| {
                    if (c == 'e' or c == 'E') {
                        has_exp = true;
                        exp_idx = i;
                        break;
                    }
                }

                if (has_exp) {
                    // Parse scientific notation: parse as f64 and convert to decimal
                    const value = try std.fmt.parseFloat(f64, lex);
                    // Use 15 decimal places to preserve precision for small values (e.g. 1.23e-7).
                    // GAP-0905: guard the i128 conversion — an unchecked @intFromFloat
                    // panicked (and killed the server) for literals like 1.0e308.
                    // 0x1p127 is 2^127 as f64; i128 holds (-2^127, 2^127). NaN fails
                    // both comparisons and falls through to the error.
                    const i128_limit: f64 = 0x1p127;
                    const scaled = value * 1_000_000_000_000_000;
                    if (scaled >= -i128_limit and scaled < i128_limit) {
                        const coeff = @as(i128, @intFromFloat(scaled));
                        break :blk_f .{ .Decimal = .{ .coeff = coeff, .scale = 15 } };
                    }
                    if (value >= -i128_limit and value < i128_limit) {
                        // Too large for the scale-15 fixed-point form; fall back to an
                        // integer-valued decimal so huge-but-representable literals work.
                        break :blk_f .{ .Decimal = .{ .coeff = @as(i128, @intFromFloat(value)), .scale = 0 } };
                    }
                    // Unrepresentable in a 38-digit decimal: clean parse error, matching
                    // the pre-existing oversized-integer-literal policy (error.Overflow).
                    return error.Overflow;
                } else {
                    // Standard decimal notation
                    var dot_idx: usize = 0;
                    while (dot_idx < lex.len and lex[dot_idx] != '.') : (dot_idx += 1) {}
                    if (dot_idx >= lex.len) return error.UnexpectedToken;
                    const int_part = lex[0..dot_idx];
                    const frac_part = lex[dot_idx + 1 .. lex.len];
                    // SONNY-2739: more than 255 fraction digits aborted the
                    // server here (`@intCast`); it is an out-of-range literal.
                    const scale: u8 = std.math.cast(u8, frac_part.len) orelse return error.Overflow;
                    // coeff = parse int_part ++ frac_part as i128
                    var buf = std.ArrayList(u8).empty;
                    try buf.appendSlice(self.arena.allocator(), int_part);
                    try buf.appendSlice(self.arena.allocator(), frac_part);
                    const coeff = try std.fmt.parseInt(i128, buf.items, 10);
                    break :blk_f .{ .Decimal = .{ .coeff = coeff, .scale = scale } };
                }
            },
            .TRUE => {
                self.advance();
                return .{ .Bool = true };
            },
            .FALSE => {
                self.advance();
                return .{ .Bool = false };
            },
            .NULL => {
                self.advance();
                return .Null;
            },
            .CAST => blk_cast: {
                // CANARY: REQ=REQ-GQL-CAST-001; FEATURE="TypeCasting"; ASPECT=Parser; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=parser; UPDATED=2026-01-25
                // Parse CAST(expr AS type) or CAST(expr AS type(precision)) or CAST(expr AS type(precision, scale))
                self.advance(); // consume CAST
                _ = try self.expect(.l_paren);

                // Parse the expression to cast
                const expr = try self.parseOrExpr();
                const expr_ptr = try self.arena.allocator().create(ast.Expr);
                expr_ptr.* = expr;

                // Expect AS keyword
                _ = try self.expect(.AS);

                // Parse target type - accept identifier or any keyword (type names like DECIMAL are parsed as identifiers)
                const type_name: []const u8 = self.cur.lexeme;
                if (self.cur.kind == .identifier or self.cur.lexeme.len > 0) {
                    self.advance();
                } else {
                    return self.unexpected("expected type name in CAST");
                }

                // Check for optional precision/scale: (precision) or (precision, scale)
                var full_type_name = type_name;
                if (self.cur.kind == .l_paren) {
                    self.advance(); // consume (
                    var type_buf = try std.ArrayList(u8).initCapacity(self.arena.allocator(), 32);
                    try type_buf.appendSlice(self.arena.allocator(), type_name);
                    try type_buf.appendSlice(self.arena.allocator(), "(");

                    // Parse precision
                    if (self.cur.kind != .integer_lit) return self.unexpected("expected precision in CAST type");
                    try type_buf.appendSlice(self.arena.allocator(), self.cur.lexeme);
                    self.advance();

                    // Optional scale
                    if (self.cur.kind == .comma) {
                        self.advance();
                        try type_buf.appendSlice(self.arena.allocator(), ",");
                        if (self.cur.kind != .integer_lit) return self.unexpected("expected scale in CAST type");
                        try type_buf.appendSlice(self.arena.allocator(), self.cur.lexeme);
                        self.advance();
                    }

                    _ = try self.expect(.r_paren);
                    try type_buf.appendSlice(self.arena.allocator(), ")");
                    full_type_name = try type_buf.toOwnedSlice(self.arena.allocator());
                }

                _ = try self.expect(.r_paren); // closing paren of CAST

                // Create a Call node with "cast" as the function name
                const a = self.arena.allocator();
                const callee_ptr = try a.create(ast.Expr);
                callee_ptr.* = .{ .Ident = .{ .orig = "cast", .cnf = "CAST" } };

                const type_ptr = try a.create(ast.Expr);
                type_ptr.* = .{ .String = full_type_name };

                const args = try a.alloc(*ast.Expr, 2);
                args[0] = expr_ptr;
                args[1] = type_ptr;

                break :blk_cast .{ .Call = .{ .callee = callee_ptr, .args = args } };
            },
            .l_paren => blk_paren: {
                // grouping
                self.advance();
                const inner = try self.parseOrExpr();
                _ = try self.expect(.r_paren);
                break :blk_paren inner;
            },
            .l_brace => blk_map: {
                const props = try self.parsePropertyMap();
                break :blk_map .{ .Map = props };
            },
            .l_bracket => blk_pc: {
                // Try to parse pattern comprehension: [ pattern (WHERE expr)? | expr ]
                // Heuristic: next meaningful token starts a node pattern or alias (identifier '=')
                // ENG-3904: `.minus`/`.arrow_l` must NOT be treated as the start of a
                // pattern — parseGraphPattern always requires a leading node pattern, so
                // those arms could never parse, and they stole `[-0.0483, 1.0]` (a list
                // literal whose first element is negative) from the expression parser.
                self.advance();
                var starts_pattern = false;
                if (self.cur.kind == .l_paren or ((self.cur.kind == .identifier or self.cur.kind == .PATH) and self.peekKind() == .eq)) {
                    starts_pattern = true;
                }
                if (!starts_pattern) {
                    // Check for list comprehension: [x IN list WHERE cond | expr]
                    // Detected by: identifier IN ...
                    if (self.cur.kind == .identifier and self.peekKind() == .IN) {
                        // Parse list comprehension
                        const var_name = self.cur.lexeme;
                        self.advance(); // consume identifier
                        self.advance(); // consume IN

                        // Parse source expression
                        const source_expr = try self.parseOrExpr();
                        const source_ptr = try self.arena.allocator().create(ast.Expr);
                        source_ptr.* = source_expr;

                        // Optional WHERE filter
                        var filter_ptr: ?*ast.Expr = null;
                        if (self.cur.kind == .WHERE) {
                            self.advance();
                            const filter_expr = try self.parseOrExpr();
                            const fp = try self.arena.allocator().create(ast.Expr);
                            fp.* = filter_expr;
                            filter_ptr = fp;
                        }

                        // Optional | map expression
                        var map_ptr: ?*ast.Expr = null;
                        if (self.cur.kind == .bar) {
                            self.advance();
                            const map_expr = try self.parseOrExpr();
                            const mp = try self.arena.allocator().create(ast.Expr);
                            mp.* = map_expr;
                            map_ptr = mp;
                        }

                        _ = try self.expect(.r_bracket);
                        break :blk_pc .{ .ListComprehension = .{
                            .variable = var_name,
                            .source = source_ptr,
                            .filter = filter_ptr,
                            .map = map_ptr,
                        } };
                    }

                    // Try to parse as array literal: [expr, expr, ...]
                    var elements = std.ArrayList(*ast.Expr).empty;

                    // Handle empty array
                    if (self.cur.kind == .r_bracket) {
                        self.advance();
                        const elements_slice = try elements.toOwnedSlice(self.arena.allocator());
                        break :blk_pc .{ .ArrayLit = elements_slice };
                    }

                    // Parse comma-separated expressions
                    while (true) {
                        const elem = try self.parseOrExpr();
                        const ep = try self.arena.allocator().create(ast.Expr);
                        ep.* = elem;
                        try elements.append(self.arena.allocator(), ep);

                        if (self.cur.kind != .comma) break;
                        self.advance();
                    }

                    _ = try self.expect(.r_bracket);
                    const elements_slice = try elements.toOwnedSlice(self.arena.allocator());
                    break :blk_pc .{ .ArrayLit = elements_slice };
                }
                // CANARY: REQ=REQ-GQL-164; FEATURE="Pattern Comprehension Shorthand"; ASPECT=Parser; STATUS=TESTED; OWNER=parser; UPDATED=2025-10-14
                self.pattern_comp_depth += 1;
                const pat_val = try self.parseGraphPattern();
                var where_expr: ?*ast.Expr = null;
                if (self.cur.kind == .WHERE) {
                    self.advance();
                    const w = try self.parseOrExpr();
                    const wp = try self.arena.allocator().create(ast.Expr);
                    wp.* = w;
                    where_expr = wp;
                }

                // Make | optional - when omitted, return the matched path/nodes
                // Syntax: [(a)--()]  is shorthand for  [(a)--(x) | x]
                // We'll create a synthetic identifier for the last node in the pattern
                var map_expr_v: ast.Expr = undefined;
                if (self.cur.kind == .bar) {
                    self.advance();
                    map_expr_v = try self.parseOrExpr();
                } else {
                    // No | provided - create synthetic expression to return matched nodes
                    // Find the last node variable in the pattern to return
                    // For pattern (a)--(), the unnamed node should be bound to a synthetic var
                    // We'll use a special marker to indicate "return all matched nodes"
                    // The execution engine will interpret this as returning the target node
                    const unicode = @import("../unicode/unicode_tables.zig");
                    const synthetic_name = "__pattern_target__";
                    const cnf = unicode.caseFoldToUpper(self.arena.allocator(), synthetic_name) catch synthetic_name;
                    map_expr_v = .{ .Ident = .{ .orig = synthetic_name, .cnf = cnf } };
                }
                const mp = try self.arena.allocator().create(ast.Expr);
                mp.* = map_expr_v;
                _ = try self.expect(.r_bracket);
                self.pattern_comp_depth -= 1;
                const a = self.arena.allocator();
                const pat_ptr = try a.create(ast.GraphPattern);
                pat_ptr.* = pat_val;
                // Optional alias for comprehension result: allow preceding identifier '=' before '[' already handled in outer parse? Here we support inline alias via a prior token check.
                // We accept syntax like: p = [ pattern | expr ] by handling in parsePostfix callsite normally as a top-level expression using Binary Eq? Simpler: support a prefix alias in primary by checking for preceding identifier '=' is not feasible here.
                // Implement simpler form: allow after comprehension an optional 'AS ident' alias; or embed none. We'll stick to none here; aliasing can be carried by outer ReturnItem alias.
                break :blk_pc .{ .PatternComp = .{ .pattern = pat_ptr, .where = where_expr, .map = mp, .alias = null } };
            },
            else => blk: {
                // Accept keywords as identifiers (ISO/IEC 39075:2024 compliance)
                // This handles cases like: MATCH (create:Person) RETURN create
                if (self.isKeyword(self.cur.kind)) {
                    const tkn = self.cur;
                    self.advance();
                    // Create CNF representation for identifiers
                    const unicode = @import("../unicode/unicode_tables.zig");
                    const cnf = unicode.caseFoldToUpper(self.arena.allocator(), tkn.lexeme) catch tkn.lexeme;
                    break :blk .{ .Ident = .{ .orig = tkn.lexeme, .cnf = cnf } };
                }
                // Not an identifier or keyword, return error
                return error.UnexpectedToken;
            },
        };
    }

    fn makeBinary(self: *Parser, op: ast.BinOp, left: ast.Expr, right: ast.Expr) ParserError!ast.Expr {
        // SONNY-3181: a binary link of the expression being parsed.
        try self.countExprLink();
        const a = self.arena.allocator();
        const lp = try a.create(ast.Expr);
        const rp = try a.create(ast.Expr);
        lp.* = left;
        rp.* = right;
        return .{ .Binary = .{ .op = op, .left = lp, .right = rp } };
    }

    fn isSimpleOrderKey(self: *Parser, expr: ast.Expr) bool {
        // Simple: IDENT or nested Member chains like a.b.c
        return switch (expr) {
            .Ident => true,
            .Member => |m| self.isSimpleOrderPtr(m.target.*),
            else => false,
        };
    }

    fn isSimpleOrderPtr(self: *Parser, e: ast.Expr) bool {
        _ = self;
        // SONNY-3133: a member chain (`a.b.c`) is built by a loop and is as
        // deep as the input is long: it is followed in a loop.
        var cur = e;
        while (true) {
            switch (cur) {
                .Ident => return true,
                .Member => |m| cur = m.target.*,
                else => return false,
            }
        }
    }

    pub fn containsCall(self: *Parser, e: ast.Expr) bool {
        _ = self;
        return containsCallStatic(e);
    }

    // Static variant for post-parse validation (no Parser instance state needed)
    //
    // SONNY-3133: an operator chain (`1 + 1 + ... + 1`) and a member chain
    // (`a.b.c`) are built by loops and are as deep as the input is long. The
    // left operand, the member target, the unary operand, the IS NULL target
    // and the IN value are followed in a loop; only a right operand, list
    // items and IN set items recurse, and their nesting is bounded by
    // `enterRecursion`. It recursed on each, and the server parses ORDER BY
    // keys with `forbid_orderby_calls` set: `ORDER BY 1 + 1 + ... + 1`
    // recursed once per operator.
    pub fn containsCallStatic(e: ast.Expr) bool {
        var cur = e;
        while (true) {
            switch (cur) {
                .Call => return true,
                .Member => |m| cur = m.target.*,
                .Unary => |u| cur = u.expr.*,
                .IsNull => |z| cur = z.target.*,
                .Binary => |b| {
                    if (containsCallStatic(b.right.*)) return true;
                    cur = b.left.*;
                },
                .List => |items| {
                    for (items) |it| if (containsCallStatic(it.*)) return true;
                    return false;
                },
                .In => |x| {
                    for (x.set) |it| if (containsCallStatic(it.*)) return true;
                    cur = x.value.*;
                },
                else => return false,
            }
        }
    }

    fn argIsPropertyLike(e: ast.Expr) bool {
        return switch (e) {
            .Member => true, // n.prop
            .Ident => true, // bare identifier accepted
            else => false,
        };
    }

    fn argIsNumericLike(e: ast.Expr) bool {
        return switch (e) {
            .Int => true,
            .Decimal => true,
            .Binary => true, // allow arithmetic expressions
            .Unary => true,
            .Ident => true,
            .Member => true,
            .Call => true, // allow nested function calls
            .Null => true, // NULL is valid for functions like abs(NULL)
            // ENG-3905: a $param is only known at bind time; the runtime validates it.
            .Param => true,
            else => false,
        };
    }

    fn argIsStringLike(e: ast.Expr) bool {
        return switch (e) {
            .String => true,
            .Ident => true,
            .Member => true,
            .Call => true, // allow nested function calls
            // ENG-3905: a $param is only known at bind time; the runtime validates it.
            .Param => true,
            else => false,
        };
    }

    // CANARY: REQ=REQ-GQL-SET-QUANTIFIER-004; FEATURE="AggregateSetQuantifier"; ASPECT=ComputationalOperation; STATUS=TESTED; TEST=tests/test_bug731_aggregates_vectors.zig; OWNER=parser; UPDATED=2026-07-31
    // CANARY: REQ=REQ-UNSUPPORTED-AGGREGATE-REJECTION; FEATURE="AggregateSetQuantifier"; ASPECT=ComputationalOperation; STATUS=TESTED; TEST=tests/test_unsupported_aggregates.zig; OWNER=parser; UPDATED=2026-08-25
    /// ISO/IEC 39075:2024 <computational operation> — the aggregate names whose
    /// argument may be prefixed with a <set quantifier> (DISTINCT | ALL).
    ///
    /// UNSUPPORTED-AGGREGATES: this list used to also carry collect_list / stddev_samp /
    /// stddev_pop / percentile_cont / percentile_disc, none of which
    /// src/execution/aggregation_evaluation.zig implements. It is now exactly
    /// the implemented set; the phantom names are refused by
    /// `unsupportedAggregateName` below instead of being half-admitted.
    fn acceptsSetQuantifier(name: []const u8) bool {
        const computational_operations = [_][]const u8{
            "count", "sum", "avg",
            "min",   "max", "collect",
        };
        for (computational_operations) |op| {
            if (std.ascii.eqlIgnoreCase(name, op)) return true;
        }
        return false;
    }

    // CANARY: REQ=REQ-UNSUPPORTED-AGGREGATE-REJECTION; FEATURE="AggregateSetQuantifier"; ASPECT=UnsupportedAggregateReject; STATUS=TESTED; TEST=tests/test_unsupported_aggregates.zig; OWNER=parser; UPDATED=2026-08-25
    /// Aggregate names this engine recognises as aggregates but does NOT
    /// implement. `src/execution/aggregation_evaluation.zig` implements exactly
    /// count / countDistinct / sum / avg / min / max / collect.
    ///
    /// UNSUPPORTED-AGGREGATES — WHY THIS IS A HARD PARSE-TIME REFUSAL AND NOT A RUNTIME NULL:
    /// the grouped-aggregation path (`evaluateGroupAggregation`) answers NULL
    /// for any Call it does not recognise, so
    ///
    ///   MATCH (n:G) RETURN n.k, percentile_cont(n.v, 0.5) GROUP BY n.k
    ///
    /// returned a full result set with a NULL statistic in it — indistinguishable
    /// from "the median of this group really is null". A statistic that silently
    /// evaluates to NULL is worse than one that does not exist. Refusing the
    /// statement names the function the user asked for.
    ///
    /// Returns the canonical spelling to quote back to the user, or null.
    fn unsupportedAggregateName(name: []const u8) ?[]const u8 {
        const unimplemented = [_][]const u8{
            "percentile_cont", "percentile_disc", "percentilecont", "percentiledisc",
            "stddev_samp",     "stddev_pop",      "collect_list",   "stdev",
        };
        for (unimplemented) |op| {
            if (std.ascii.eqlIgnoreCase(name, op)) return op;
        }
        return null;
    }

    fn validateBuiltinCall(name: []const u8, args: []ast.Expr, ts_enabled: bool) bool {
        const n = args.len;
        // Table of builtins: name, min_arity, max_arity (usize max means unbounded), validator
        if (std.ascii.eqlIgnoreCase(name, "exists")) {
            if (n != 1) return false;
            return argIsPropertyLike(args[0]);
        }
        if (std.ascii.eqlIgnoreCase(name, "length")) {
            return n == 1;
        }
        if (std.ascii.eqlIgnoreCase(name, "id")) {
            return n == 1 and argIsPropertyLike(args[0]);
        }
        if (std.ascii.eqlIgnoreCase(name, "labels")) {
            return n == 1 and (args[0] == .Ident or args[0] == .Member);
        }
        if (std.ascii.eqlIgnoreCase(name, "type")) {
            // Accept any single expression for type() function
            return n == 1;
        }
        if (std.ascii.eqlIgnoreCase(name, "coalesce")) {
            return n >= 1;
        }
        if (std.ascii.eqlIgnoreCase(name, "toInteger")) {
            // Accept any single expression for toInteger() function
            return n == 1;
        }
        if (std.ascii.eqlIgnoreCase(name, "toString")) {
            // Accept any single expression for toString() function
            return n == 1;
        }
        // CANARY: REQ=REQ-GQL-CAST-003; FEATURE="TypeCasting"; ASPECT=Validation; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=parser; UPDATED=2026-01-25
        if (std.ascii.eqlIgnoreCase(name, "cast")) {
            // CAST(expr, type_string) - requires exactly 2 args
            return n == 2;
        }
        if (std.ascii.eqlIgnoreCase(name, "abs")) {
            return n == 1 and argIsNumericLike(args[0]);
        }
        // Vector types - accept array literal or string
        if (std.ascii.eqlIgnoreCase(name, "VectorF32")) {
            return n == 1 and (args[0] == .ArrayLit or argIsStringLike(args[0]));
        }
        if (std.ascii.eqlIgnoreCase(name, "VectorI32")) {
            return n == 1 and (args[0] == .ArrayLit or argIsStringLike(args[0]));
        }
        // Geographic types - accept two numbers or one string
        if (std.ascii.eqlIgnoreCase(name, "LatLon")) {
            return (n == 2 and argIsNumericLike(args[0]) and argIsNumericLike(args[1])) or (n == 1 and argIsStringLike(args[0]));
        }
        if (std.ascii.eqlIgnoreCase(name, "LatLonAlt")) {
            // Accept 3 numeric args (lat, lon, alt) or 4 args (lat, lon, alt, ref) or 1 string
            if (n == 1 and argIsStringLike(args[0])) return true;
            if (n == 3 and argIsNumericLike(args[0]) and argIsNumericLike(args[1]) and argIsNumericLike(args[2])) return true;
            if (n == 4 and argIsNumericLike(args[0]) and argIsNumericLike(args[1]) and argIsNumericLike(args[2])) return true;
            return false;
        }
        if (std.ascii.eqlIgnoreCase(name, "GeoPoint")) {
            return (n == 2 and argIsNumericLike(args[0]) and argIsNumericLike(args[1])) or (n == 1 and argIsStringLike(args[0]));
        }
        // JSON/Geometry types - accept string
        if (std.ascii.eqlIgnoreCase(name, "Jsonb")) {
            return n == 1 and argIsStringLike(args[0]);
        }
        if (std.ascii.eqlIgnoreCase(name, "GeometryFromText")) {
            return n == 1 and argIsStringLike(args[0]);
        }
        // Map functions
        if (std.ascii.eqlIgnoreCase(name, "keys")) {
            return n == 1; // Accept any expression that evaluates to a map
        }
        if (std.ascii.eqlIgnoreCase(name, "values")) {
            return n == 1; // Accept any expression that evaluates to a map
        }
        if (ts_enabled) {
            // Core time-series functions
            if (std.ascii.eqlIgnoreCase(name, "last_value")) {
                if (n != 1) return false;
                return argIsPropertyLike(args[0]) or args[0] == .Ident or args[0] == .Member or argIsStringLike(args[0]);
            }
            if (std.ascii.eqlIgnoreCase(name, "value_at")) {
                if (n != 2) return false;
                return (argIsPropertyLike(args[0]) or args[0] == .Ident or args[0] == .Member or argIsStringLike(args[0])) and argIsNumericLike(args[1]);
            }
            if (std.ascii.eqlIgnoreCase(name, "sample_by")) {
                if (n < 2 or n > 5) return false; // series, interval, [start_ts, end_ts, aggregation]
                if (!(argIsPropertyLike(args[0]) or args[0] == .Ident or args[0] == .Member or argIsStringLike(args[0]))) return false;
                if (!argIsNumericLike(args[1])) return false;
                if (n >= 3 and !argIsNumericLike(args[2])) return false;
                if (n >= 4 and !argIsNumericLike(args[3])) return false;
                if (n == 5 and !(argIsStringLike(args[4]) or args[4] == .Ident)) return false;
                return true;
            }
            // Advanced time-series functions
            if (std.ascii.eqlIgnoreCase(name, "interpolate")) {
                if (n < 2 or n > 3) return false; // series, timestamp, [method]
                if (!(argIsPropertyLike(args[0]) or args[0] == .Ident or args[0] == .Member or argIsStringLike(args[0]))) return false;
                if (!argIsNumericLike(args[1])) return false;
                if (n == 3 and !(argIsStringLike(args[2]) or args[2] == .Ident)) return false;
                return true;
            }
            if (std.ascii.eqlIgnoreCase(name, "moving_avg")) {
                if (n != 3) return false; // series, window_ms, step_ms
                if (!(argIsPropertyLike(args[0]) or args[0] == .Ident or args[0] == .Member or argIsStringLike(args[0]))) return false;
                if (!argIsNumericLike(args[1])) return false;
                if (!argIsNumericLike(args[2])) return false;
                return true;
            }
            if (std.ascii.eqlIgnoreCase(name, "rate")) {
                if (n != 2) return false; // series, interval_ms
                if (!(argIsPropertyLike(args[0]) or args[0] == .Ident or args[0] == .Member or argIsStringLike(args[0]))) return false;
                if (!argIsNumericLike(args[1])) return false;
                return true;
            }
            if (std.ascii.eqlIgnoreCase(name, "derivative")) {
                if (n < 1 or n > 2) return false; // series, [order]
                if (!(argIsPropertyLike(args[0]) or args[0] == .Ident or args[0] == .Member or argIsStringLike(args[0]))) return false;
                if (n == 2 and !argIsNumericLike(args[1])) return false;
                return true;
            }
            if (std.ascii.eqlIgnoreCase(name, "time_bucket")) {
                if (n != 4) return false; // series, bucket_ms, start_ts, end_ts
                if (!(argIsPropertyLike(args[0]) or args[0] == .Ident or args[0] == .Member or argIsStringLike(args[0]))) return false;
                if (!argIsNumericLike(args[1])) return false;
                if (!argIsNumericLike(args[2])) return false;
                if (!argIsNumericLike(args[3])) return false;
                return true;
            }
        }
        // Unknown functions: allow any arity for now
        return true;
    }

    // Parse CREATE statement (CREATE pattern or CREATE INDEX)
    fn parseCreateStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.CREATE);

        // Check for OR REPLACE
        var or_replace = false;
        if (self.cur.kind == .OR) {
            self.advance();
            if (self.cur.kind == .REPLACE) {
                self.advance();
                or_replace = true;
            } else {
                return error.UnexpectedToken;
            }
        }

        // Check if this is CREATE USER or CREATE ROLE (auth DDL soft keywords)
        if (self.softKw("USER")) {
            self.advance();
            return self.parseCreateUser();
        }
        if (self.softKw("ROLE")) {
            self.advance();
            return self.parseCreateRole();
        }
        // GPS policy DDL: CREATE POLICY <name> ON GRAPH ...
        if (self.softKw("POLICY")) {
            self.advance();
            return self.parseCreatePolicy();
        }

        // Check if this is CREATE INDEX
        if (self.cur.kind == .INDEX or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "INDEX")) or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "UNIQUE")))
        {
            return self.parseCreateIndex();
        }

        // Check if this is CREATE CONSTRAINT
        if (self.cur.kind == .CONSTRAINT) {
            self.advance();
            return self.parseCreateConstraint();
        }

        // Check if this is CREATE SCHEMA
        if (self.cur.kind == .SCHEMA) {
            return self.parseCreateSchema();
        }

        // Check if this is CREATE GRAPH or CREATE PROPERTY GRAPH
        if (self.cur.kind == .GRAPH or
            self.cur.kind == .PROPERTY or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "PROPERTY")))
        {
            // For now, let the individual functions handle TYPE detection
            return self.parseCreateGraphWithReplace(or_replace);
        }

        // Otherwise, parse the pattern to create - support multiple consecutive CREATE clauses
        // e.g., CREATE (a:Node) CREATE (b:Node) WITH 1 AS x ...
        // CANARY: REQ=REQ-GQL-MULTI-CREATE-002; FEATURE="MultipleConsecutiveCreate"; ASPECT=ParserCreateStatement; STATUS=TESTED; TEST=geodetestlab/specs/gql_data_modification_comprehensive.yml; OWNER=parser; UPDATED=2025-12-27
        var pattern: ast.GraphPattern = undefined;
        {
            var create_chains = std.ArrayList(ast.Chain).empty;
            // First pattern already consumed the CREATE keyword
            const first_pattern = try self.parseGraphPattern();
            for (first_pattern.chains) |chain| {
                try create_chains.append(self.arena.allocator(), chain);
            }
            // Handle additional CREATE patterns
            // SONNY-3190: at most `max_write_clauses_per_part` clauses.
            var write_clauses: usize = 1;
            while (self.cur.kind == .CREATE) {
                try self.countWriteClause(&write_clauses);
                self.advance();
                const next_pattern = try self.parseGraphPattern();
                for (next_pattern.chains) |chain| {
                    try create_chains.append(self.arena.allocator(), chain);
                }
            }
            pattern = .{ .chains = try create_chains.toOwnedSlice(self.arena.allocator()) };
        }

        // CANARY: REQ=REQ-GQL-083; FEATURE="CreateWithClause"; ASPECT=ParserSupport; STATUS=TESTED; OWNER=parser; UPDATED=2025-10-09
        // Check if this is followed by WITH, SET, REMOVE, or DELETE - if so, this should be a Query, not a standalone CREATE
        if (self.cur.kind == .WITH or self.cur.kind == .SET or self.cur.kind == .REMOVE or self.cur.kind == .DELETE) {
            // This is CREATE ... WITH/SET/REMOVE ... RETURN
            // We need to construct a Query with create_pattern set

            // Parse WITH clause if present
            var with_clause: ?ast.WithClause = null;
            var next_query_ptr: ?*ast.Query = null;
            if (self.cur.kind == .WITH) {
                self.advance();
                var witems = std.ArrayList(ast.ReturnItem).empty;
                try self.parseProjectionItems(&witems);

                // Parse optional ORDER BY, LIMIT, OFFSET after WITH items
                var with_order_by: ?*ast.OrderBy = null;
                var with_limit: ?u64 = null;
                var with_offset: ?u64 = null;
                var with_limit_param: ?[]const u8 = null;
                var with_offset_param: ?[]const u8 = null;

                if (self.cur.kind == .ORDER) {
                    self.advance();
                    _ = try self.expect(.BY);
                    var keys = std.ArrayList(ast.OrderBy.OrderKey).empty;
                    while (true) {
                        const key_expr = try self.parseOrExpr();
                        const mods = try self.parseOrderKeyModifiers();
                        try keys.append(self.arena.allocator(), .{ .expr = key_expr, .desc = mods.desc, .nulls = mods.nulls });
                        if (self.cur.kind != .comma) break;
                        self.advance();
                    }
                    const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                    order_by_ptr.* = .{ .keys = try keys.toOwnedSlice(self.arena.allocator()) };
                    with_order_by = order_by_ptr;
                }

                if (self.cur.kind == .LIMIT) {
                    self.advance();
                    const lim = try self.parseLimitValue();
                    with_limit = lim.value;
                    with_limit_param = lim.param;
                }

                if (self.cur.kind == .OFFSET or self.cur.kind == .SKIP) {
                    self.advance();
                    const off = try self.parseLimitValue();
                    with_offset = off.value;
                    with_offset_param = off.param;
                }

                with_clause = .{
                    .items = try witems.toOwnedSlice(self.arena.allocator()),
                    .order_by = with_order_by,
                    .limit = with_limit,
                    .offset = with_offset,
                    .limit_param = with_limit_param,
                    .offset_param = with_offset_param,
                };

                // CANARY: REQ=REQ-GQL-CHAIN; FEATURE="Query Chaining via WITH"; ASPECT=Parser; STATUS=TESTED; TEST=graph_algorithms; OWNER=parser; UPDATED=2026-01-17
                // Check for query chaining: WITH ... MATCH/CREATE ...
                // If we see MATCH or CREATE after WITH, parse it as a chained query
                if (self.cur.kind == .MATCH or self.cur.kind == .CREATE) {
                    // Parse the continuation as a new query
                    const next_query = try self.parseQuery();
                    // Allocate on arena and store pointer
                    const next_ptr = try self.arena.allocator().create(ast.Query);
                    next_ptr.* = next_query;
                    next_query_ptr = next_ptr;

                    // Current query acts as a WITH-only query (implicit RETURN from WITH items)
                    // Return a Query with create_pattern and next_query set
                    return .{
                        .Query = .{
                            .optional_match = false,
                            .match = .{ .chains = &.{} }, // Empty match pattern
                            .create_pattern = pattern, // CREATE pattern goes here
                            .where_clause = null,
                            .with_clause = with_clause,
                            .set_clauses = &.{},
                            .remove_clauses = &.{},
                            .ret = .{ .items = with_clause.?.items, .distinct = false }, // Implicit RETURN
                            .order_by = null,
                            .limit = null,
                            .offset = null,
                            .next_query = next_query_ptr,
                        },
                    };
                }
            }

            // Parse SET clauses if present
            var set_clauses: []ast.SetClause = &.{};
            if (self.cur.kind == .SET) {
                self.advance();
                set_clauses = try self.parseSetClauses();
            }

            // Parse REMOVE clauses if present
            var remove_clauses: []ast.RemoveClause = &.{};
            if (self.cur.kind == .REMOVE) {
                self.advance();
                remove_clauses = try self.parseRemoveClauses();
            }

            // Parse DELETE clause if present (for CREATE ... WITH ... DELETE ... pattern)
            // CANARY: REQ=REQ-GQL-DELETE; FEATURE="DELETE in Query"; ASPECT=ParserCreateStatement; STATUS=TESTED; TEST=no-id-collision-on-delete-create; OWNER=parser; UPDATED=2025-10-14
            var delete_items: []ast.DeleteItem = &.{};
            if (self.cur.kind == .DELETE) {
                self.advance();
                delete_items = try self.parseDeleteItems();
            }

            // Parse RETURN clause (required for Query)
            var return_clause: ast.ReturnClause = undefined;
            if (self.cur.kind == .RETURN) {
                self.advance();
                const distinct = if (self.cur.kind == .DISTINCT) blk: {
                    self.advance();
                    break :blk true;
                } else false;
                var items = std.ArrayList(ast.ReturnItem).empty;
                try self.parseProjectionItems(&items);
                return_clause = .{ .items = try items.toOwnedSlice(self.arena.allocator()), .distinct = distinct };
            } else if (set_clauses.len > 0 or remove_clauses.len > 0 or delete_items.len > 0) {
                // SET/REMOVE/DELETE without RETURN - create empty return clause
                return_clause = .{ .items = &.{}, .distinct = false };
            } else {
                // No SET/REMOVE/DELETE and no RETURN after WITH - error
                _ = try self.expect(.RETURN);
                unreachable;
            }

            // Return a Query with create_pattern set (no chaining)
            return .{
                .Query = .{
                    .optional_match = false,
                    .match = .{ .chains = &.{} }, // Empty match pattern
                    .create_pattern = pattern, // CREATE pattern goes here
                    .where_clause = null,
                    .with_clause = with_clause,
                    .set_clauses = set_clauses,
                    .remove_clauses = remove_clauses,
                    .delete_items = delete_items,
                    .ret = return_clause,
                    .order_by = null,
                    .limit = null,
                    .offset = null,
                },
            };
        }

        // Optional RETURN clause (for standalone CREATE without WITH/SET/REMOVE)
        var return_clause: ?ast.ReturnClause = null;
        if (self.cur.kind == .RETURN) {
            self.advance();
            const distinct = if (self.cur.kind == .DISTINCT) blk: {
                self.advance();
                break :blk true;
            } else false;
            var return_items = std.ArrayList(ast.ReturnItem).empty;
            try self.parseProjectionItems(&return_items);
            return_clause = .{
                .items = try return_items.toOwnedSlice(self.arena.allocator()),
                .distinct = distinct,
            };

            // Check if RETURN is followed by UNION, ORDER BY, LIMIT, or OFFSET
            // If so, convert to Query and handle through handleQueryResult
            if (self.cur.kind == .UNION or self.cur.kind == .ORDER or self.cur.kind == .LIMIT or self.cur.kind == .OFFSET or self.cur.kind == .SKIP) {
                // Convert CREATE ... RETURN to a Query
                const query = ast.Query{
                    .optional_match = false,
                    .match = .{ .chains = &.{} },
                    .where_clause = null,
                    .with_clause = null,
                    .create_pattern = pattern,
                    .ret = return_clause.?,
                    .order_by = null,
                    .limit = null,
                    .offset = null,
                    .next_query = null,
                };
                // handleQueryResult will parse UNION, ORDER BY, LIMIT, OFFSET
                return self.handleQueryResult(query);
            }
        }

        return .{ .Create = .{
            .pattern = pattern,
            .return_clause = return_clause,
        } };
    }

    // Parse DELETE statement
    fn parseDeleteStatement(self: *Parser) ParserError!ast.Statement {
        const detach = if (self.cur.kind == .DETACH) blk: {
            self.advance();
            break :blk true;
        } else false;

        _ = try self.expect(.DELETE);

        // Optional MATCH clause
        var match_clause: ?ast.GraphPattern = null;
        var where_clause: ?ast.Expr = null;

        if (self.cur.kind == .MATCH) {
            self.advance();
            match_clause = try self.parseGraphPattern();

            if (self.cur.kind == .WHERE) {
                self.advance();
                where_clause = try self.parseOrExpr();
            }
        }

        // Parse items to delete
        // GAP-0220 FIX: Use try for proper error propagation
        var items = try std.ArrayList(ast.DeleteItem).initCapacity(self.arena.allocator(), 0);

        // Parse first item
        const first_item = try self.parseDeleteItem();
        try items.append(self.arena.allocator(), first_item);

        // Parse additional items
        while (self.cur.kind == .comma) {
            self.advance();
            const item = try self.parseDeleteItem();
            try items.append(self.arena.allocator(), item);
        }

        // Optional RETURN clause
        var return_clause: ?ast.ReturnClause = null;
        if (self.cur.kind == .RETURN) {
            self.advance();
            const distinct = if (self.cur.kind == .DISTINCT) blk: {
                self.advance();
                break :blk true;
            } else false;
            var return_items = std.ArrayList(ast.ReturnItem).empty;
            try self.parseProjectionItems(&return_items);
            return_clause = .{
                .items = try return_items.toOwnedSlice(self.arena.allocator()),
                .distinct = distinct,
            };
        }

        return .{ .Delete = .{
            .match_clause = match_clause,
            .where_clause = where_clause,
            .detach = detach,
            .items = try items.toOwnedSlice(self.arena.allocator()),
            .return_clause = return_clause,
        } };
    }

    fn parseDeleteItem(self: *Parser) ParserError!ast.DeleteItem {
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const name = self.cur.lexeme;
        self.advance();
        return .{ .Variable = name };
    }

    // Parse MERGE statement
    fn parseMergeStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.MERGE);

        // Parse the pattern to merge — supporting consecutive MERGE clauses,
        // e.g. `MERGE (a:T {..}) MERGE (b:T {..}) MERGE (a)-[:REL]->(b)`.
        // ENG-3903: parsing only ONE clause split the rest into separate
        // statements, so the third clause never saw the `a`/`b` bindings and
        // the relationship was silently never written. Clause order is
        // preserved (MERGE is sequential: a later clause sees the bindings an
        // earlier one established). Mirrors the multi-CREATE loop above.
        // A clause carrying ON CREATE / ON MATCH / SET / RETURN ends the run,
        // because those clauses bind to the MERGE that introduced them.
        // CANARY: REQ=REQ-MERGE-RELPROPS-001; FEATURE="MergeRelationship"; ASPECT=ChainedMergeClauses; STATUS=TESTED; TEST=tests/test_merge_relationship_bugs.zig; OWNER=parser; UPDATED=2026-08-24
        var pattern: ast.GraphPattern = undefined;
        var last_clause_start: ?usize = null;
        {
            var merge_chains = std.ArrayList(ast.Chain).empty;
            const first_pattern = try self.parseGraphPattern();
            for (first_pattern.chains) |chain| {
                try merge_chains.append(self.arena.allocator(), chain);
            }
            // SONNY-3190: at most `max_write_clauses_per_part` clauses.
            var write_clauses: usize = 1;
            while (self.cur.kind == .MERGE) {
                try self.countWriteClause(&write_clauses);
                self.advance();
                // SONNY-3320: where the last clause starts (its actions' clause).
                last_clause_start = merge_chains.items.len;
                const next_pattern = try self.parseGraphPattern();
                for (next_pattern.chains) |chain| {
                    try merge_chains.append(self.arena.allocator(), chain);
                }
            }
            pattern = .{ .chains = try merge_chains.toOwnedSlice(self.arena.allocator()) };
        }

        // Parse ON CREATE/MATCH clauses
        // GAP-0220 FIX: Use try for proper error propagation
        var on_create = try std.ArrayList(ast.SetClause).initCapacity(self.arena.allocator(), 0);
        var on_match = try std.ArrayList(ast.SetClause).initCapacity(self.arena.allocator(), 0);
        // SONNY-3242: where each SET clause of either list ends.
        var on_create_ends = std.ArrayList(usize).empty;
        var on_match_ends = std.ArrayList(usize).empty;

        while (self.cur.kind == .ON) {
            self.advance();

            if (self.cur.kind == .CREATE) {
                self.advance();
                _ = try self.expect(.SET);
                const clauses = try self.parseSetClauses();
                try on_create.appendSlice(self.arena.allocator(), clauses);
                try on_create_ends.append(self.arena.allocator(), on_create.items.len);
            } else if (self.cur.kind == .MATCH) {
                self.advance();
                _ = try self.expect(.SET);
                const clauses = try self.parseSetClauses();
                try on_match.appendSlice(self.arena.allocator(), clauses);
                try on_match_ends.append(self.arena.allocator(), on_match.items.len);
            } else {
                return error.UnexpectedToken;
            }
        }

        // Handle bare SET (applies to both create and match paths) - GAP #59
        // Track the bare-SET case so the bulk fast path can recognise that
        // on_create and on_match carry the same clauses by construction and
        // accept the MERGE despite on_match being non-empty.
        var set_is_bare = false;
        if (self.cur.kind == .SET) {
            self.advance();
            const clauses = try self.parseSetClauses();
            try on_create.appendSlice(self.arena.allocator(), clauses);
            try on_match.appendSlice(self.arena.allocator(), clauses);
            try on_create_ends.append(self.arena.allocator(), on_create.items.len);
            try on_match_ends.append(self.arena.allocator(), on_match.items.len);
            set_is_bare = true;
        }

        // Optional RETURN clause
        var return_clause: ?ast.ReturnClause = null;
        if (self.cur.kind == .RETURN) {
            self.advance();
            const distinct = if (self.cur.kind == .DISTINCT) blk: {
                self.advance();
                break :blk true;
            } else false;
            var return_items = std.ArrayList(ast.ReturnItem).empty;
            try self.parseProjectionItems(&return_items);
            return_clause = .{
                .items = try return_items.toOwnedSlice(self.arena.allocator()),
                .distinct = distinct,
            };
        }

        return .{ .Merge = .{
            .pattern = pattern,
            .on_create = try on_create.toOwnedSlice(self.arena.allocator()),
            .on_match = try on_match.toOwnedSlice(self.arena.allocator()),
            .set_is_bare = set_is_bare,
            .return_clause = return_clause,
            .on_create_ends = if (on_create_ends.items.len > 1) try on_create_ends.toOwnedSlice(self.arena.allocator()) else &.{},
            .on_match_ends = if (on_match_ends.items.len > 1) try on_match_ends.toOwnedSlice(self.arena.allocator()) else &.{},
            .last_clause_start = last_clause_start,
        } };
    }

    fn parseSetClauses(self: *Parser) ParserError![]ast.SetClause {
        // GAP-0220 FIX: Use try for proper error propagation
        var clauses = try std.ArrayList(ast.SetClause).initCapacity(self.arena.allocator(), 0);
        try self.appendSetClauses(&clauses);
        return clauses.toOwnedSlice(self.arena.allocator());
    }

    /// The items of one SET clause (`a.x = 1, b:L, ...`), appended to `clauses`.
    fn appendSetClauses(self: *Parser, clauses: *std.ArrayList(ast.SetClause)) ParserError!void {
        // Parse first clause
        const first = try self.parseSetClause();
        try clauses.append(self.arena.allocator(), first);

        // Parse additional clauses
        while (self.cur.kind == .comma) {
            self.advance();
            const clause = try self.parseSetClause();
            try clauses.append(self.arena.allocator(), clause);
        }
    }

    fn parseSetClause(self: *Parser) ParserError!ast.SetClause {
        // Parse identifier (e.g., n)
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const object = self.cur.lexeme;
        self.advance();

        // Check what follows the identifier
        if (self.cur.kind == .colon) {
            // Parse label(s): SET n:Label or SET n:Label1:Label2
            // GAP-0220 FIX: Use try for proper error propagation
            var labels = try std.ArrayList([]const u8).initCapacity(self.arena.allocator(), 0);

            while (self.cur.kind == .colon) {
                self.advance(); // consume ':'
                const label_token = try self.expectIdentifierOrKeyword();
                try labels.append(self.arena.allocator(), label_token.lexeme);
            }

            return .{ .Labels = .{
                .node = object,
                .labels = try labels.toOwnedSlice(self.arena.allocator()),
            } };
        } else if (self.cur.kind == .eq) {
            // SET n = {properties}: Replace all properties
            self.advance(); // consume '='
            const properties = try self.parseOrExpr();

            return .{ .AllProperties = .{
                .node = object,
                .properties = properties,
            } };
        } else {
            // Property setting: n.property = value
            _ = try self.expect(.dot);

            const property_token = try self.expectIdentifierOrKeyword();
            const property = property_token.lexeme;

            _ = try self.expect(.eq);

            const value = try self.parseOrExpr();

            return .{ .Property = .{
                .target = .{ .object = object, .property = property },
                .value = value,
            } };
        }
    }

    fn parseRemoveClauses(self: *Parser) ParserError![]ast.RemoveClause {
        // GAP-0220 FIX: Use try for proper error propagation
        var clauses = try std.ArrayList(ast.RemoveClause).initCapacity(self.arena.allocator(), 0);

        // Parse first clause
        const first = try self.parseRemoveClause();
        try clauses.append(self.arena.allocator(), first);

        // Parse additional clauses
        while (self.cur.kind == .comma) {
            self.advance();
            const clause = try self.parseRemoveClause();
            try clauses.append(self.arena.allocator(), clause);
        }

        return clauses.toOwnedSlice(self.arena.allocator());
    }

    fn parseRemoveClause(self: *Parser) ParserError!ast.RemoveClause {
        // Parse identifier (e.g., n)
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const object = self.cur.lexeme;
        self.advance();

        // Check if it's a label removal (n:Label) or property removal (n.property)
        if (self.cur.kind == .colon) {
            // Parse label(s): REMOVE n:Label or REMOVE n:Label1:Label2
            // GAP-0220 FIX: Use try for proper error propagation
            var labels = try std.ArrayList([]const u8).initCapacity(self.arena.allocator(), 0);

            while (self.cur.kind == .colon) {
                self.advance(); // consume ':'
                const label_token = try self.expectIdentifierOrKeyword();
                try labels.append(self.arena.allocator(), label_token.lexeme);
            }

            return .{ .Labels = .{
                .node = object,
                .labels = try labels.toOwnedSlice(self.arena.allocator()),
            } };
        } else {
            // Property removal: n.property
            _ = try self.expect(.dot);

            const property_token = try self.expectIdentifierOrKeyword();
            const property = property_token.lexeme;

            return .{ .Property = .{ .object = object, .property = property } };
        }
    }

    fn parseDeleteItems(self: *Parser) ParserError![]ast.DeleteItem {
        // GAP-0220 FIX: Use try for proper error propagation
        var items = try std.ArrayList(ast.DeleteItem).initCapacity(self.arena.allocator(), 0);

        // Parse first item
        const first = try self.parseDeleteItem();
        try items.append(self.arena.allocator(), first);

        // Parse additional items
        while (self.cur.kind == .comma) {
            self.advance();
            const item = try self.parseDeleteItem();
            try items.append(self.arena.allocator(), item);
        }

        return items.toOwnedSlice(self.arena.allocator());
    }

    // Parse CREATE INDEX statement
    fn parseCreateIndex(self: *Parser) ParserError!ast.Statement {
        var unique = false;

        // Check for UNIQUE keyword
        if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "UNIQUE")) {
            unique = true;
            self.advance();
        }

        // Expect INDEX keyword
        if (self.cur.kind == .INDEX) {
            self.advance();
        } else if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "INDEX")) {
            self.advance();
        } else {
            return error.UnexpectedToken;
        }

        // Optional IF NOT EXISTS
        var if_not_exists = false;
        if (self.cur.kind == .IF) {
            self.advance();
            if (self.cur.kind == .NOT) {
                self.advance();
                if (self.cur.kind == .EXISTS) {
                    self.advance();
                    if_not_exists = true;
                } else {
                    return error.UnexpectedToken;
                }
            } else {
                return error.UnexpectedToken;
            }
        }

        // Index name (optional - may be omitted when ON or FOR follows directly)
        var name: ?[]const u8 = null;
        if (self.cur.kind == .identifier) {
            name = self.cur.lexeme;
            self.advance();
        } else if (self.cur.kind != .ON and self.cur.kind != .FOR) {
            return error.UnexpectedToken;
        }

        var label: []const u8 = undefined;
        var pattern_variable: ?[]const u8 = null;

        // Check for ISO GQL syntax: FOR (n:Label) ON (n.property)
        if (self.cur.kind == .FOR) {
            self.advance();

            // Parse pattern: (n:Label) or ()-[r:RelType]-()
            if (self.cur.kind != .l_paren) return error.UnexpectedToken;
            self.advance();

            // Check for relationship pattern: ()-[r:RelType]-()
            if (self.cur.kind == .r_paren) {
                // ()-[r:RelType]-() syntax for relationship indexes
                self.advance(); // consume )
                if (self.cur.kind != .minus) return error.UnexpectedToken;
                self.advance(); // consume -
                if (self.cur.kind != .l_bracket) return error.UnexpectedToken;
                self.advance(); // consume [

                // Variable name
                if (self.cur.kind != .identifier) return error.UnexpectedToken;
                pattern_variable = self.cur.lexeme;
                self.advance();

                // :RelType
                if (self.cur.kind != .colon) return error.UnexpectedToken;
                self.advance();
                if (self.cur.kind != .identifier) return error.UnexpectedToken;
                label = self.cur.lexeme;
                self.advance();

                // Close bracket and remaining pattern: ]-()
                if (self.cur.kind != .r_bracket) return error.UnexpectedToken;
                self.advance(); // consume ]
                if (self.cur.kind != .minus) return error.UnexpectedToken;
                self.advance(); // consume -
                if (self.cur.kind != .l_paren) return error.UnexpectedToken;
                self.advance(); // consume (
                if (self.cur.kind != .r_paren) return error.UnexpectedToken;
                self.advance(); // consume ) - end of pattern
            } else {
                // Node pattern: (n:Label)
                if (self.cur.kind != .identifier) return error.UnexpectedToken;
                pattern_variable = self.cur.lexeme;
                self.advance();

                if (self.cur.kind != .colon) return error.UnexpectedToken;
                self.advance();

                if (self.cur.kind != .identifier) return error.UnexpectedToken;
                label = self.cur.lexeme;
                self.advance();

                if (self.cur.kind != .r_paren) return error.UnexpectedToken;
                self.advance();
            }

            // ON keyword
            if (self.cur.kind != .ON) return error.UnexpectedToken;
            self.advance();
        } else {
            // Legacy syntax: ON Label or ON :Label
            if (self.cur.kind != .ON) return error.UnexpectedToken;
            self.advance();

            // Label (e.g., :Person or Person)
            // Allow keywords as label names (e.g., :SCAN, :MATCH, :NODE)
            if (self.cur.kind == .colon) {
                self.advance();
                if (self.cur.kind != .identifier and !self.isKeyword(self.cur.kind)) return error.UnexpectedToken;
                label = self.cur.lexeme;
                self.advance();
            } else if (self.cur.kind == .identifier or self.isKeyword(self.cur.kind)) {
                label = self.cur.lexeme;
                self.advance();
            } else {
                return error.UnexpectedToken;
            }
        }

        // Optional USING index_type (before properties)
        var index_type = ast.IndexType.btree;
        if (self.cur.kind == .USING) {
            self.advance();
            if (self.cur.kind == .identifier) {
                const type_str = self.cur.lexeme;
                if (std.ascii.eqlIgnoreCase(type_str, "btree") or std.ascii.eqlIgnoreCase(type_str, "BTree")) {
                    index_type = .btree;
                } else if (std.ascii.eqlIgnoreCase(type_str, "hash") or std.ascii.eqlIgnoreCase(type_str, "Hash")) {
                    index_type = .hash;
                } else if (std.ascii.eqlIgnoreCase(type_str, "fulltext") or std.ascii.eqlIgnoreCase(type_str, "FullText")) {
                    index_type = .fulltext;
                } else if (std.ascii.eqlIgnoreCase(type_str, "spatial") or std.ascii.eqlIgnoreCase(type_str, "RTree")) {
                    index_type = .spatial;
                } else if (std.ascii.eqlIgnoreCase(type_str, "vector") or std.ascii.eqlIgnoreCase(type_str, "HNSW")) {
                    index_type = .vector;
                } else if (std.ascii.eqlIgnoreCase(type_str, "vector_f32")) {
                    index_type = .vector_f32;
                } else if (std.ascii.eqlIgnoreCase(type_str, "spatial_geographic")) {
                    index_type = .spatial_geographic;
                } else if (std.ascii.eqlIgnoreCase(type_str, "network_cidr") or std.ascii.eqlIgnoreCase(type_str, "PatriciaTrie") or std.ascii.eqlIgnoreCase(type_str, "trie")) {
                    index_type = .network_cidr;
                } else if (std.ascii.eqlIgnoreCase(type_str, "signature_crypto")) {
                    index_type = .signature_crypto;
                } else if (std.ascii.eqlIgnoreCase(type_str, "interval_tree") or std.ascii.eqlIgnoreCase(type_str, "IntervalTree")) {
                    index_type = .interval_tree;
                } else if (std.ascii.eqlIgnoreCase(type_str, "jsonb_inverted") or std.ascii.eqlIgnoreCase(type_str, "JsonbInverted")) {
                    index_type = .jsonb_inverted;
                } else if (std.ascii.eqlIgnoreCase(type_str, "domain_trie") or std.ascii.eqlIgnoreCase(type_str, "DomainTrie")) {
                    index_type = .domain_trie;
                } else {
                    // Reject unrecognized index types
                    return error.InvalidIndexType;
                }
                self.advance();
            }
        }

        // Properties in parentheses
        if (self.cur.kind != .l_paren) return error.UnexpectedToken;
        self.advance();

        // GAP-0220 FIX: Use try for proper error propagation
        var properties = try std.ArrayList([]const u8).initCapacity(self.arena.allocator(), 1);

        // Parse properties - handle both (property) and (n.property) syntax
        // CANARY: REQ=REQ-GQL-084; FEATURE="CreateIndexKeywordProperties"; ASPECT=ParserSupport; STATUS=TESTED; OWNER=parser; UPDATED=2025-10-14
        while (true) {
            // Allow keywords as property names (common case: "value", "type", etc.)
            if (self.cur.kind != .identifier and !self.isKeyword(self.cur.kind)) return error.UnexpectedToken;

            // Check for qualified property (n.property)
            if (pattern_variable != null) {
                const first_part = self.cur.lexeme;
                self.advance();

                // Check for dot
                if (self.cur.kind == .dot) {
                    self.advance();
                    // Allow keywords as property names after dot
                    if (self.cur.kind != .identifier and !self.isKeyword(self.cur.kind)) return error.UnexpectedToken;
                    // Use the property name after the dot
                    try properties.append(self.arena.allocator(), self.cur.lexeme);
                    self.advance();
                } else {
                    // No dot, use the identifier as-is (fallback for unqualified)
                    try properties.append(self.arena.allocator(), first_part);
                }
            } else {
                // Unqualified property
                try properties.append(self.arena.allocator(), self.cur.lexeme);
                self.advance();
            }

            // Check for more properties
            if (self.cur.kind == .comma) {
                self.advance();
            } else {
                break;
            }
        }

        if (self.cur.kind != .r_paren) return error.UnexpectedToken;
        self.advance();

        // Optional USING index_type (after properties) - Neo4j/Cypher syntax
        if (self.cur.kind == .USING) {
            self.advance();
            if (self.cur.kind == .identifier) {
                const type_str = self.cur.lexeme;
                if (std.ascii.eqlIgnoreCase(type_str, "btree") or std.ascii.eqlIgnoreCase(type_str, "BTree")) {
                    index_type = .btree;
                } else if (std.ascii.eqlIgnoreCase(type_str, "hash") or std.ascii.eqlIgnoreCase(type_str, "Hash")) {
                    index_type = .hash;
                } else if (std.ascii.eqlIgnoreCase(type_str, "fulltext") or std.ascii.eqlIgnoreCase(type_str, "FullText")) {
                    index_type = .fulltext;
                } else if (std.ascii.eqlIgnoreCase(type_str, "spatial") or std.ascii.eqlIgnoreCase(type_str, "RTree")) {
                    index_type = .spatial;
                } else if (std.ascii.eqlIgnoreCase(type_str, "vector") or std.ascii.eqlIgnoreCase(type_str, "HNSW")) {
                    index_type = .vector;
                } else if (std.ascii.eqlIgnoreCase(type_str, "vector_f32")) {
                    index_type = .vector_f32;
                } else if (std.ascii.eqlIgnoreCase(type_str, "spatial_geographic")) {
                    index_type = .spatial_geographic;
                } else if (std.ascii.eqlIgnoreCase(type_str, "network_cidr") or std.ascii.eqlIgnoreCase(type_str, "PatriciaTrie") or std.ascii.eqlIgnoreCase(type_str, "trie")) {
                    index_type = .network_cidr;
                } else if (std.ascii.eqlIgnoreCase(type_str, "signature_crypto")) {
                    index_type = .signature_crypto;
                } else if (std.ascii.eqlIgnoreCase(type_str, "interval_tree") or std.ascii.eqlIgnoreCase(type_str, "IntervalTree")) {
                    index_type = .interval_tree;
                } else if (std.ascii.eqlIgnoreCase(type_str, "jsonb_inverted") or std.ascii.eqlIgnoreCase(type_str, "JsonbInverted")) {
                    index_type = .jsonb_inverted;
                } else if (std.ascii.eqlIgnoreCase(type_str, "domain_trie") or std.ascii.eqlIgnoreCase(type_str, "DomainTrie")) {
                    index_type = .domain_trie;
                } else {
                    // Reject unrecognized index types
                    return error.InvalidIndexType;
                }
                self.advance();
            }
        }

        // Optional WITH clause for index parameters, parsed as real
        // `key = value` / `key: value` pairs. `metric` is captured so the
        // executor can validate it for vector/HNSW indexes (GAP-0918 — an
        // invalid metric like 'banana' used to be silently discarded here).
        //
        // ENG-3906: this used to be a token walk that skipped everything it did
        // not recognise, which hid TWO defects behind one loop:
        //   (A1) it only honoured `metric` after an `.eq`, so the ISO map
        //        spelling `metric: 'banana'` never reached the validator and the
        //        index was built with no metric at all;
        //   (A2) every other key — a typo, or an HNSW tuning knob this engine
        //        does not implement (m / ef_construction / ef_search) — was
        //        accepted and thrown away, so the operator believed they had
        //        tuned an index that was in fact built with defaults.
        // Both spellings are now equivalent, and on a VECTOR-typed index any key
        // other than `metric` is refused rather than discarded. Non-vector index
        // types keep the previous permissive behaviour (their WITH parameters are
        // outside this fix's blast radius).
        // CANARY: REQ=REQ-ENG-3906-INDEX-WITH-PARAM-VALIDATION; FEATURE="VectorIndex"; ASPECT=WithParameterValidation; STATUS=TESTED; TEST=tests/test_eng3906_index_with_params.zig; OWNER=index; UPDATED=2026-08-24
        var index_metric: ?[]const u8 = null;
        if (self.cur.kind == .WITH) {
            self.advance();
            if (self.cur.kind == .l_paren) {
                self.advance();
                const vector_typed_index = index_type == .vector or index_type == .vector_f32;
                // Pair loop. Any shape this cannot read (a nested list/map value,
                // a parameter reference, ...) breaks out to the tolerant
                // skip-to-matching-paren recovery below, exactly as before.
                pairs: while (self.cur.kind != .r_paren and self.cur.kind != .eof) {
                    if (self.cur.kind != .identifier and self.cur.kind != .quoted_identifier and !self.isKeyword(self.cur.kind)) break :pairs;
                    const param_key = self.cur.lexeme;
                    self.advance();

                    // `=` (Neo4j / pgvector spelling) and `:` (ISO map spelling)
                    // are the SAME parameter. Only `=` was honoured before.
                    if (self.cur.kind != .eq and self.cur.kind != .colon) break :pairs;
                    self.advance();

                    const value_kind = self.cur.kind;
                    const value_lexeme = self.cur.lexeme;
                    switch (value_kind) {
                        .string_lit,
                        .identifier,
                        .quoted_identifier,
                        .integer_lit,
                        .float_lit,
                        .TRUE,
                        .FALSE,
                        => self.advance(),
                        else => break :pairs,
                    }

                    if (std.ascii.eqlIgnoreCase(param_key, "metric")) {
                        if (value_kind == .string_lit or value_kind == .identifier or value_kind == .quoted_identifier) {
                            index_metric = value_lexeme;
                        }
                    } else if (vector_typed_index) {
                        self.last_error = std.fmt.allocPrint(
                            self.arena.allocator(),
                            "unknown index parameter '{s}' in the WITH clause: a vector index accepts only 'metric' (l2, euclidean, cosine, dot, dot_product, inner_product); the HNSW tuning knobs m / ef_construction / ef_search are not implemented",
                            .{param_key},
                        ) catch "unknown index parameter in the WITH clause: a vector index accepts only 'metric'";
                        return error.UnknownIndexParameter;
                    }

                    if (self.cur.kind == .comma) {
                        self.advance();
                        continue :pairs;
                    }
                    break :pairs;
                }
                // Tolerant recovery: consume whatever the pair loop did not read
                // and balance the WITH parentheses.
                var paren_depth: u32 = 1;
                while (paren_depth > 0 and self.cur.kind != .eof) {
                    if (self.cur.kind == .l_paren) {
                        paren_depth += 1;
                    } else if (self.cur.kind == .r_paren) {
                        paren_depth -= 1;
                        if (paren_depth == 0) break;
                    }
                    self.advance();
                }
                if (self.cur.kind == .r_paren) {
                    self.advance();
                }
            }
        }

        // Optional OPTIONS clause (alternative to USING/WITH)
        // CANARY: REQ=REQ-FTS-INDEX-OPTIONS-VALIDATION; FEATURE="FulltextIndex"; ASPECT=OptionsKeyValidation; STATUS=TESTED; TEST=tests/test_fts_index_options.zig; OWNER=index; UPDATED=2026-08-25
        //
        // FTS-INDEX-OPTIONS (same class as ENG-3906): this block used to skip to the
        // matching brace and throw every key away, so
        //
        //   CREATE INDEX i ON L (p) USING fulltext OPTIONS {k1: 1.5, b: 0.3}
        //
        // reported success while nothing at all was configured — the user
        // believes they tuned BM25 and did not.
        //
        // NOT WIREABLE, SO REFUSED: the fts-storage engine fixes BM25 k1 and b
        // as compile-time constants (`BM25_K1` / `BM25_B` in its src/search.zig)
        // and exposes no per-index override; the analyzer is likewise fixed by
        // src/index/fts_tokenizer.zig. No index type implements any OPTIONS key
        // today, so every key is refused by name. An empty `OPTIONS {}` asks for
        // nothing and stays accepted.
        if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "OPTIONS")) {
            self.advance();
            if (self.cur.kind == .l_brace) {
                self.advance();
                if (self.cur.kind != .r_brace and self.cur.kind != .eof) {
                    const option_key = self.cur.lexeme;
                    self.last_error = std.fmt.allocPrint(
                        self.arena.allocator(),
                        "unknown index option '{s}' in the OPTIONS clause: CREATE INDEX implements no OPTIONS keys (the BM25 knobs k1 / b and the analyzer are fixed by the fulltext engine and are not tunable per index)",
                        .{option_key},
                    ) catch "unknown index option in the OPTIONS clause: CREATE INDEX implements no OPTIONS keys";
                    return error.UnknownIndexOption;
                }
                if (self.cur.kind == .r_brace) {
                    self.advance();
                }
            }
        }

        return .{ .CreateIndex = .{
            .name = name,
            .unique = unique,
            .index_type = index_type,
            .label = label,
            .properties = try properties.toOwnedSlice(self.arena.allocator()),
            .if_not_exists = if_not_exists,
            .metric = index_metric,
        } };
    }

    // Parse CREATE CONSTRAINT statement
    fn parseCreateConstraint(self: *Parser) ParserError!ast.Statement {
        // Optional IF NOT EXISTS
        var if_not_exists = false;
        if (self.cur.kind == .IF) {
            self.advance();
            if (self.cur.kind == .NOT) {
                self.advance();
                if (self.cur.kind == .EXISTS) {
                    self.advance();
                    if_not_exists = true;
                } else {
                    return error.UnexpectedToken;
                }
            } else {
                return error.UnexpectedToken;
            }
        }

        // Constraint name (required)
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const name = self.cur.lexeme;
        self.advance();

        var label: []const u8 = undefined;
        // GAP-0220 FIX: Use try for proper error propagation
        var properties = try std.ArrayList([]const u8).initCapacity(self.arena.allocator(), 1);
        var constraint_type: ast.ConstraintType = undefined;

        // Check for ISO GQL syntax: FOR (n:Label) REQUIRE ...
        if (self.cur.kind == .FOR) {
            self.advance();

            // Parse pattern: (n:Label)
            if (self.cur.kind != .l_paren) return error.UnexpectedToken;
            self.advance();

            // Variable name
            if (self.cur.kind != .identifier) return error.UnexpectedToken;
            const pattern_var = self.cur.lexeme;
            self.advance();

            // :Label
            if (self.cur.kind != .colon) return error.UnexpectedToken;
            self.advance();

            if (self.cur.kind != .identifier) return error.UnexpectedToken;
            label = self.cur.lexeme;
            self.advance();

            if (self.cur.kind != .r_paren) return error.UnexpectedToken;
            self.advance();

            // REQUIRE keyword
            if (self.cur.kind != .REQUIRE) return error.UnexpectedToken;
            self.advance();

            // Parse constraint condition
            constraint_type = try self.parseConstraintCondition(pattern_var, &properties);
        } else {
            // Legacy syntax: ON :Label ASSERT ...
            if (self.cur.kind != .ON) return error.UnexpectedToken;
            self.advance();

            // :Label or Label
            if (self.cur.kind == .colon) {
                self.advance();
                if (self.cur.kind != .identifier) return error.UnexpectedToken;
                label = self.cur.lexeme;
                self.advance();
            } else if (self.cur.kind == .identifier) {
                label = self.cur.lexeme;
                self.advance();
            } else {
                return error.UnexpectedToken;
            }

            // ASSERT keyword
            if (self.cur.kind != .ASSERT) return error.UnexpectedToken;
            self.advance();

            // Parse constraint condition (legacy format)
            constraint_type = try self.parseConstraintConditionLegacy(&properties);
        }

        return .{ .CreateConstraint = .{
            .name = name,
            .constraint_type = constraint_type,
            .label = label,
            .properties = try properties.toOwnedSlice(self.arena.allocator()),
            .if_not_exists = if_not_exists,
        } };
    }

    // Helper: Parse REQUIRE condition (ISO GQL)
    fn parseConstraintCondition(self: *Parser, pattern_var: []const u8, properties: *std.ArrayList([]const u8)) ParserError!ast.ConstraintType {
        _ = pattern_var;

        // Check for composite constraint: (n.prop1, n.prop2)
        if (self.cur.kind == .l_paren) {
            self.advance();

            // Parse property list
            while (true) {
                if (self.cur.kind != .identifier) return error.UnexpectedToken;
                const var_name = self.cur.lexeme;
                self.advance();

                if (self.cur.kind == .dot) {
                    self.advance();
                    if (self.cur.kind != .identifier) return error.UnexpectedToken;
                    try properties.append(self.arena.allocator(), self.cur.lexeme);
                    self.advance();
                } else {
                    try properties.append(self.arena.allocator(), var_name);
                }

                if (self.cur.kind == .comma) {
                    self.advance();
                } else {
                    break;
                }
            }

            if (self.cur.kind != .r_paren) return error.UnexpectedToken;
            self.advance();

            // IS NODE KEY
            if (self.cur.kind == .IS) {
                self.advance();
                if (self.cur.kind == .NODE) {
                    self.advance();
                    if (self.cur.kind == .KEY) {
                        self.advance();
                        return .node_key;
                    }
                    return error.UnexpectedToken;
                }
                return error.UnexpectedToken;
            }
            return error.UnexpectedToken;
        }

        // Single property: n.prop IS UNIQUE / IS NOT NULL
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const var_name = self.cur.lexeme;
        self.advance();

        if (self.cur.kind == .dot) {
            self.advance();
            if (self.cur.kind != .identifier) return error.UnexpectedToken;
            try properties.append(self.arena.allocator(), self.cur.lexeme);
            self.advance();
        } else {
            try properties.append(self.arena.allocator(), var_name);
        }

        // IS UNIQUE / IS NOT NULL
        if (self.cur.kind == .IS) {
            self.advance();

            if (self.cur.kind == .NOT) {
                self.advance();
                if (self.cur.kind == .NULL) {
                    self.advance();
                    return .not_null;
                }
                return error.UnexpectedToken;
            }

            if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "UNIQUE")) {
                self.advance();
                return .unique;
            }
        }

        return error.UnexpectedToken;
    }

    // Helper: Parse ASSERT condition (Legacy)
    fn parseConstraintConditionLegacy(self: *Parser, properties: *std.ArrayList([]const u8)) ParserError!ast.ConstraintType {
        // EXISTS (prop) - property existence
        if (self.cur.kind == .EXISTS) {
            self.advance();
            if (self.cur.kind != .l_paren) return error.UnexpectedToken;
            self.advance();

            if (self.cur.kind != .identifier) return error.UnexpectedToken;
            try properties.append(self.arena.allocator(), self.cur.lexeme);
            self.advance();

            if (self.cur.kind != .r_paren) return error.UnexpectedToken;
            self.advance();

            return .exists;
        }

        // (prop) IS NODE KEY or (prop1, prop2, ...) IS NODE KEY
        if (self.cur.kind == .l_paren) {
            self.advance();

            // Parse property list
            while (true) {
                if (self.cur.kind != .identifier) return error.UnexpectedToken;
                try properties.append(self.arena.allocator(), self.cur.lexeme);
                self.advance();

                if (self.cur.kind == .comma) {
                    self.advance();
                } else {
                    break;
                }
            }

            if (self.cur.kind != .r_paren) return error.UnexpectedToken;
            self.advance();

            if (self.cur.kind == .IS) {
                self.advance();
                if (self.cur.kind == .NODE) {
                    self.advance();
                    if (self.cur.kind == .KEY) {
                        self.advance();
                        return .node_key;
                    }
                    return error.UnexpectedToken;
                }
                if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "UNIQUE")) {
                    self.advance();
                    return .unique;
                }
                return error.UnexpectedToken;
            }
            return error.UnexpectedToken;
        }

        // prop IS UNIQUE
        if (self.cur.kind == .identifier) {
            try properties.append(self.arena.allocator(), self.cur.lexeme);
            self.advance();

            if (self.cur.kind == .IS) {
                self.advance();
                if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "UNIQUE")) {
                    self.advance();
                    return .unique;
                }
            }
        }

        return error.UnexpectedToken;
    }

    // Parse SHOW statement
    fn parseShowStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.SHOW);

        // Determine what to show based on next token
        const show_type: ast.ShowType = if (self.cur.kind == .identifier) blk: {
            const type_str = self.cur.lexeme;
            self.advance();

            if (std.ascii.eqlIgnoreCase(type_str, "INDEXES") or
                std.ascii.eqlIgnoreCase(type_str, "INDEX"))
            {
                break :blk .indexes;
            } else if (std.ascii.eqlIgnoreCase(type_str, "CONSTRAINTS") or
                std.ascii.eqlIgnoreCase(type_str, "CONSTRAINT"))
            {
                break :blk .constraints;
            } else if (std.ascii.eqlIgnoreCase(type_str, "TABLES") or
                std.ascii.eqlIgnoreCase(type_str, "TABLE"))
            {
                break :blk .tables;
            } else if (std.ascii.eqlIgnoreCase(type_str, "GRAPHS") or
                std.ascii.eqlIgnoreCase(type_str, "GRAPH"))
            {
                break :blk .graphs;
            } else if (std.ascii.eqlIgnoreCase(type_str, "PROCEDURES") or
                std.ascii.eqlIgnoreCase(type_str, "PROCEDURE"))
            {
                break :blk .procedures;
            } else if (std.ascii.eqlIgnoreCase(type_str, "FUNCTIONS") or
                std.ascii.eqlIgnoreCase(type_str, "FUNCTION"))
            {
                break :blk .functions;
            } else if (std.ascii.eqlIgnoreCase(type_str, "USERS") or std.ascii.eqlIgnoreCase(type_str, "USER")) {
                break :blk .users;
            } else if (std.ascii.eqlIgnoreCase(type_str, "ROLES") or std.ascii.eqlIgnoreCase(type_str, "ROLE")) {
                break :blk .roles;
            } else if (std.ascii.eqlIgnoreCase(type_str, "PERMISSIONS") or std.ascii.eqlIgnoreCase(type_str, "PERMISSION")) {
                break :blk .permissions;
            } else if (std.ascii.eqlIgnoreCase(type_str, "VERSION")) {
                break :blk .version;
            } else if (std.ascii.eqlIgnoreCase(type_str, "CAPABILITIES") or std.ascii.eqlIgnoreCase(type_str, "CAPABILITY")) {
                break :blk .capabilities;
            } else if (std.ascii.eqlIgnoreCase(type_str, "POLICIES") or std.ascii.eqlIgnoreCase(type_str, "POLICY")) {
                break :blk .policies;
            } else if (std.ascii.eqlIgnoreCase(type_str, "GRANTS") or std.ascii.eqlIgnoreCase(type_str, "GRANT")) {
                // CANARY: REQ=REQ-GPS-DDL-004; FEATURE="GPS SHOW GRANTS FOR"; ASPECT=ParserDispatch; STATUS=TESTED; TEST=tests/test_gps_show_grants_for.zig; OWNER=security; UPDATED=2026-05-21
                break :blk .grants_for;
            } else if (std.ascii.eqlIgnoreCase(type_str, "CLUSTER")) {
                // CANARY: REQ=REQ-DIST-SHOW-CLUSTER-STATUS; FEATURE="SHOW CLUSTER STATUS"; ASPECT=ParserDispatch; STATUS=TESTED; TEST=tests/test_show_cluster_status.zig; OWNER=distributed; UPDATED=2026-05-26
                // SHOW CLUSTER STATUS — neither CLUSTER nor STATUS are
                // reserved keywords, so we match them as identifiers via
                // case-insensitive lexeme comparison.  This avoids growing
                // the reserved-keyword set and keeps both words available
                // as user identifiers everywhere else in the grammar.
                if (self.cur.kind != .identifier or !std.ascii.eqlIgnoreCase(self.cur.lexeme, "STATUS")) {
                    return self.unexpected("expected STATUS after SHOW CLUSTER");
                }
                self.advance();
                break :blk .cluster_status;
            } else {
                return error.UnexpectedToken;
            }
        } else {
            return error.UnexpectedToken;
        };

        var target: ?[]const u8 = null;
        if (show_type == .permissions and self.cur.kind == .FOR) {
            self.advance(); // FOR
            target = try self.parseName();
        } else if (show_type == .grants_for) {
            if (self.cur.kind != .FOR) return self.unexpected("expected FOR after SHOW GRANTS");
            self.advance(); // FOR
            target = try self.parseName();
        }
        return .{ .Show = .{ .show_type = show_type, .target = target } };
    }

    fn parseValuesStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.VALUES);

        // Parse rows: (expr1), (expr2), ...
        var rows_list = std.ArrayList([]ast.Expr).empty;

        while (true) {
            // Expect opening paren for row
            _ = try self.expect(.l_paren);

            // Parse expressions in this row
            var row_exprs = std.ArrayList(ast.Expr).empty;

            // Parse first expression
            const first_expr = try self.parseOrExpr();
            try row_exprs.append(self.arena.allocator(), first_expr);

            // Parse additional expressions (if multi-column)
            while (self.cur.kind == .comma) {
                self.advance();
                const expr = try self.parseOrExpr();
                try row_exprs.append(self.arena.allocator(), expr);
            }

            _ = try self.expect(.r_paren);

            try rows_list.append(self.arena.allocator(), try row_exprs.toOwnedSlice(self.arena.allocator()));

            // Check for more rows
            if (self.cur.kind == .comma) {
                self.advance();
                continue;
            }
            break;
        }

        // Expect AS keyword
        _ = try self.expect(.AS);

        // Parse column names: (col1, col2, ...)
        _ = try self.expect(.l_paren);

        var column_names = std.ArrayList([]const u8).empty;

        // Parse first column name
        if (self.cur.kind != .identifier) return self.unexpected("expected column name after AS (");
        try column_names.append(self.arena.allocator(), self.cur.lexeme);
        self.advance();

        // Parse additional column names
        while (self.cur.kind == .comma) {
            self.advance();
            if (self.cur.kind != .identifier) return self.unexpected("expected column name");
            try column_names.append(self.arena.allocator(), self.cur.lexeme);
            self.advance();
        }

        _ = try self.expect(.r_paren);

        // Parse continuation (RETURN, MATCH, etc.)
        var next_stmt: ?*ast.Statement = null;
        if (self.cur.kind != .eof and self.cur.kind != .semicolon) {
            const stmt_ptr = try self.arena.allocator().create(ast.Statement);
            // SONNY-3133: a nested statement.
            stmt_ptr.* = try self.parseNestedStatement();
            next_stmt = stmt_ptr;
        }

        return .{ .Values = .{
            .rows = try rows_list.toOwnedSlice(self.arena.allocator()),
            .column_names = try column_names.toOwnedSlice(self.arena.allocator()),
            .next_statement = next_stmt,
        } };
    }

    /// One projection item per variable `pattern` binds (path, node and edge
    /// variables, each once, in order): what a MATCH passes on to a FOR
    /// after it.
    fn patternVariableItems(self: *Parser, pattern: ast.GraphPattern) ParserError![]ast.ReturnItem {
        const a = self.arena.allocator();
        var names = std.ArrayList([]const u8).empty;
        for (pattern.chains) |chain| {
            var candidates = std.ArrayList(?[]const u8).empty;
            try candidates.append(a, chain.name);
            if (chain.head) |head| try candidates.append(a, head.name);
            for (chain.hops) |hop| {
                try candidates.append(a, hop.left.name);
                try candidates.append(a, hop.rel.name);
                try candidates.append(a, hop.right.name);
            }
            next: for (candidates.items) |maybe| {
                const name = maybe orelse continue;
                for (names.items) |seen| if (std.mem.eql(u8, seen, name)) continue :next;
                try names.append(a, name);
            }
        }
        const unicode = @import("../unicode/unicode_tables.zig");
        const items = try a.alloc(ast.ReturnItem, names.items.len);
        for (names.items, items) |name, *item| {
            const cnf = unicode.caseFoldToUpper(a, name) catch name;
            item.* = .{ .expr = .{ .Ident = .{ .orig = name, .cnf = cnf } }, .alias = null };
        }
        return items;
    }

    /// A FOR statement after a WITH (or a MATCH), as the next part of the
    /// chain: a query that holds only the FOR.
    fn parseForContinuation(self: *Parser) ParserError!*ast.Query {
        const for_stmt = try self.parseForStatement();
        const for_ptr = try self.arena.allocator().create(ast.ForStatement);
        for_ptr.* = for_stmt.For;
        const next_ptr = try self.arena.allocator().create(ast.Query);
        next_ptr.* = ast.Query{
            .optional_match = false,
            .match = .{ .chains = &.{} }, // Empty match pattern
            .create_pattern = null,
            .where_clause = null,
            .with_clause = null,
            .set_clauses = &.{},
            .remove_clauses = &.{},
            .ret = for_stmt.For.return_clause orelse .{ .items = &.{}, .distinct = false },
            .order_by = for_stmt.For.order_by,
            .offset = for_stmt.For.offset,
            .limit = for_stmt.For.limit,
            .next_query = null,
            .group_by = null,
            .having = null,
            .for_statement = for_ptr,
        };
        return next_ptr;
    }

    /// `FOR <variable> IN <collection> [WITH ORDINALITY v | WITH OFFSET v]`.
    fn parseForHeader(self: *Parser) ParserError!ast.ForLoop {
        _ = try self.expect(.FOR);

        // Parse iteration variable: FOR item IN ...
        if (self.cur.kind != .identifier) return self.unexpected("expected identifier after FOR");
        const variable = self.cur.lexeme;
        self.advance();

        // Expect IN keyword
        _ = try self.expect(.IN);

        // Parse collection expression (list, variable reference, etc.)
        const collection = try self.parseOrExpr();

        // Check for WITH ORDINALITY or WITH OFFSET
        var ordinality_var: ?[]const u8 = null;
        var offset_var: ?[]const u8 = null;

        if (self.cur.kind == .WITH) {
            self.advance();
            if (self.cur.kind == .ORDINALITY) {
                self.advance();
                // Expect variable name after ORDINALITY
                if (self.cur.kind != .identifier) return self.unexpected("expected identifier after ORDINALITY");
                ordinality_var = self.cur.lexeme;
                self.advance();
            } else if (self.cur.kind == .OFFSET) {
                self.advance();
                // Expect variable name after OFFSET
                if (self.cur.kind != .identifier) return self.unexpected("expected identifier after OFFSET");
                offset_var = self.cur.lexeme;
                self.advance();
            } else {
                return self.unexpected("expected ORDINALITY or OFFSET after WITH");
            }
        }

        return .{
            .variable = variable,
            .collection = collection,
            .ordinality_var = ordinality_var,
            .offset_var = offset_var,
        };
    }

    fn parseForStatement(self: *Parser) ParserError!ast.Statement {
        const header = try self.parseForHeader();
        const variable = header.variable;
        const collection = header.collection;
        const ordinality_var = header.ordinality_var;
        const offset_var = header.offset_var;

        // A FOR that follows this one before the RETURN extends every row of
        // this one: `FOR x IN [[1, 2], [3]] FOR y IN x RETURN sum(y)` sums
        // 1, 2 and 3. Only before a RETURN: a write body runs once per
        // element of one list.
        var nested = std.ArrayList(ast.ForLoop).empty;
        while (self.cur.kind == .FOR) {
            try nested.append(self.arena.allocator(), try self.parseForHeader());
        }
        if (nested.items.len > 0 and self.cur.kind != .RETURN) {
            return self.unexpected("expected RETURN after a nested FOR");
        }

        // CANARY: REQ=REQ-GQL-FOR-WRITE-BODY-876; FEATURE="ForStatement"; ASPECT=BodyParse; STATUS=TESTED; TEST=tests/test_for_write_body.zig; OWNER=parser; UPDATED=2026-08-29
        // geode#876: FOR is a <primitive query statement> (ISO/IEC 39075:2024) —
        // a <data-modifying statement> may follow the header and the result
        // statement is OPTIONAL. Anything other than RETURN is parsed as the
        // loop BODY (CREATE / MERGE / MATCH ... SET ..., with its own optional
        // trailing RETURN). The RETURN form below is unchanged.
        if (self.cur.kind != .RETURN) {
            const body_ptr = try self.arena.allocator().create(ast.Query);
            if (self.cur.kind == .MERGE) {
                // parseQuery has no leading-MERGE arm; wrap the MERGE in a query
                // exactly like the post-WITH chaining path does.
                const merge_stmt = try self.parseMergeStatement();
                const merge_ptr = try self.arena.allocator().create(ast.MergeStatement);
                merge_ptr.* = merge_stmt.Merge;
                body_ptr.* = ast.Query{
                    .optional_match = false,
                    .match = .{ .chains = &.{} },
                    .create_pattern = null,
                    .where_clause = null,
                    .with_clause = null,
                    .set_clauses = &.{},
                    .remove_clauses = &.{},
                    .ret = merge_stmt.Merge.return_clause orelse .{ .items = &.{}, .distinct = false },
                    .order_by = null,
                    .limit = null,
                    .offset = null,
                    .next_query = null,
                    .group_by = null,
                    .having = null,
                    .merge_statement = merge_ptr,
                };
            } else {
                body_ptr.* = try self.parseNestedQuery();
            }

            return .{ .For = .{
                .variable = variable,
                .collection = collection,
                .ordinality_var = ordinality_var,
                .offset_var = offset_var,
                .return_clause = null,
                .body = body_ptr,
            } };
        }

        // Expect RETURN clause
        _ = try self.expect(.RETURN);

        // Parse RETURN clause
        const distinct = if (self.cur.kind == .DISTINCT) blk: {
            self.advance();
            break :blk true;
        } else false;

        var return_items = std.ArrayList(ast.ReturnItem).empty;
        try self.parseProjectionItems(&return_items);

        // CANARY: REQ=REQ-SONNY-2683-RETURN-SHAPES; FEATURE="ForStatement"; ASPECT=NoGroupedReturn; STATUS=TESTED; TEST=tests/test_sonny2683_return_shapes.zig; OWNER=parser; UPDATED=2026-09-25
        // SONNY-2683: a FOR's RETURN does not filter. A HAVING or WHERE here
        // was left for an enclosing query to parse, so `MATCH (n) WITH n FOR
        // x IN [1, 2] RETURN x, count(*) AS c GROUP BY x HAVING c > 1`
        // grouped that query's WITH by `x` and returned unrelated rows. Its
        // GROUP BY is its own: the RETURN groups the loop's rows.
        if (self.cur.kind == .HAVING or self.cur.kind == .WHERE) {
            return self.unexpected("HAVING and WHERE are not supported after a FOR's RETURN");
        }
        var group_by: ?ast.GroupBy = null;
        if (self.cur.kind == .GROUP) {
            self.advance();
            _ = try self.expect(.BY);
            var keys = std.ArrayList(ast.Expr).empty;
            while (true) {
                try keys.append(self.arena.allocator(), try self.parseOrExpr());
                if (self.cur.kind != .comma) break;
                self.advance();
            }
            group_by = .{ .keys = try keys.toOwnedSlice(self.arena.allocator()) };
            if (self.cur.kind == .HAVING or self.cur.kind == .WHERE) {
                return self.unexpected("HAVING and WHERE are not supported after a FOR's RETURN");
            }
        }

        const return_clause = ast.ReturnClause{
            .items = try return_items.toOwnedSlice(self.arena.allocator()),
            .distinct = distinct,
        };

        // Optional ORDER BY
        var order_by: ?ast.OrderBy = null;
        if (self.cur.kind == .ORDER) {
            self.advance();
            _ = try self.expect(.BY);
            var keys = std.ArrayList(ast.OrderBy.OrderKey).empty;

            // Parse first key
            const expr1 = try self.parseOrExpr();
            const mods1 = try self.parseOrderKeyModifiers();
            try keys.append(self.arena.allocator(), .{ .expr = expr1, .desc = mods1.desc, .nulls = mods1.nulls });

            // Parse additional keys
            while (self.cur.kind == .comma) {
                self.advance();
                const exprk = try self.parseOrExpr();
                const modsk = try self.parseOrderKeyModifiers();
                try keys.append(self.arena.allocator(), .{ .expr = exprk, .desc = modsk.desc, .nulls = modsk.nulls });
            }
            order_by = .{ .keys = try keys.toOwnedSlice(self.arena.allocator()) };
        }

        // Optional LIMIT
        var limit: ?usize = null;
        var limit_param: ?[]const u8 = null;
        if (self.cur.kind == .LIMIT) {
            self.advance();
            const lim = try self.parseLimitValue();
            limit = if (lim.value) |v| @as(usize, @intCast(v)) else null;
            limit_param = lim.param;
        }

        // Optional OFFSET
        var offset: ?usize = null;
        var offset_param: ?[]const u8 = null;
        if (self.cur.kind == .OFFSET or self.cur.kind == .SKIP) {
            self.advance();
            const off = try self.parseLimitValue();
            offset = if (off.value) |v| @as(usize, @intCast(v)) else null;
            offset_param = off.param;
        }

        return .{ .For = .{
            .variable = variable,
            .collection = collection,
            .ordinality_var = ordinality_var,
            .offset_var = offset_var,
            .return_clause = return_clause,
            .nested = try nested.toOwnedSlice(self.arena.allocator()),
            .group_by = group_by,
            .order_by = order_by,
            .limit = limit,
            .offset = offset,
            .limit_param = limit_param,
            .offset_param = offset_param,
        } };
    }

    fn parseExplainStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.EXPLAIN);

        // CANARY: REQ=REQ-GPS-EXPLAIN-001; FEATURE="GPS EXPLAIN POLICY"; ASPECT=ParserDispatch; STATUS=TESTED; TEST=tests/test_gps_explain_policy.zig; OWNER=security; UPDATED=2026-05-21
        // Check for EXPLAIN POLICY FOR <inner_query> syntax.
        // "POLICY" is a soft keyword (identifier), so we use softKw().
        if (self.softKw("POLICY")) {
            self.advance(); // consume "POLICY"
            // Expect FOR keyword (hard keyword)
            if (self.cur.kind != .FOR) return self.unexpected("expected FOR after EXPLAIN POLICY");
            self.advance(); // consume FOR
            // Parse the inner statement.
            const inner_ptr = try self.arena.allocator().create(ast.Statement);
            // SONNY-3133: a nested statement.
            inner_ptr.* = try self.parseNestedStatement();
            return .{ .ExplainPolicy = .{ .inner = inner_ptr } };
        }

        // Parse the query to explain
        // SONNY-3133: a nested statement; `PROFILE EXPLAIN PROFILE ...` recursed
        // with no limit, and overflowed a worker's stack at depth 50.
        const query_stmt_ptr = try self.arena.allocator().create(ast.Statement);
        query_stmt_ptr.* = try self.parseNestedStatement();

        return .{ .Explain = .{ .query = query_stmt_ptr } };
    }

    fn parseProfileStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.PROFILE);

        // Parse the query to profile
        // SONNY-3133: a nested statement (see parseExplainStatement).
        const query_stmt_ptr = try self.arena.allocator().create(ast.Statement);
        query_stmt_ptr.* = try self.parseNestedStatement();

        return .{ .Profile = .{ .query = query_stmt_ptr } };
    }

    // Parse DROP statement (DROP INDEX, DROP SCHEMA, DROP GRAPH, etc.)
    fn parseDropStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.DROP);

        // Check if this is DROP INDEX
        if (self.cur.kind == .INDEX or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "INDEX")))
        {
            return self.parseDropIndex();
        }

        // Check if this is DROP SCHEMA
        if (self.cur.kind == .SCHEMA) {
            return self.parseDropSchema();
        }

        // Check if this is DROP GRAPH or DROP PROPERTY GRAPH
        if (self.cur.kind == .GRAPH or
            self.cur.kind == .PROPERTY or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "PROPERTY")))
        {
            // For now, let the individual functions handle TYPE detection
            return self.parseDropGraph();
        }

        // Check if this is DROP CONSTRAINT
        if (self.cur.kind == .CONSTRAINT) {
            return self.parseDropConstraint();
        }

        // Check if this is DROP USER or DROP ROLE (auth DDL soft keywords)
        if (self.softKw("USER")) {
            self.advance();
            return self.parseDropUserOrRole(true);
        }
        if (self.softKw("ROLE")) {
            self.advance();
            return self.parseDropUserOrRole(false);
        }
        // GPS policy DDL: DROP POLICY [IF EXISTS] <name>
        if (self.softKw("POLICY")) {
            self.advance();
            return self.parseDropPolicy();
        }

        // Future: handle DROP DATABASE, etc.
        return error.UnexpectedToken;
    }

    // Parse DROP INDEX statement
    fn parseDropIndex(self: *Parser) ParserError!ast.Statement {
        // Expect INDEX keyword
        if (self.cur.kind == .INDEX) {
            self.advance();
        } else if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "INDEX")) {
            self.advance();
        } else {
            return error.UnexpectedToken;
        }

        // Optional IF EXISTS
        var if_exists = false;
        if (self.cur.kind == .IF) {
            self.advance();
            if (self.cur.kind == .EXISTS) {
                self.advance();
                if_exists = true;
            } else {
                return error.UnexpectedToken;
            }
        }

        // Index name
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const name = self.cur.lexeme;
        self.advance();

        return .{ .DropIndex = .{
            .name = name,
            .if_exists = if_exists,
        } };
    }

    // Parse DROP CONSTRAINT statement
    fn parseDropConstraint(self: *Parser) ParserError!ast.Statement {
        // Expect CONSTRAINT keyword
        if (self.cur.kind == .CONSTRAINT) {
            self.advance();
        } else {
            return error.UnexpectedToken;
        }

        // Optional IF EXISTS
        var if_exists = false;
        if (self.cur.kind == .IF) {
            self.advance();
            if (self.cur.kind == .EXISTS) {
                self.advance();
                if_exists = true;
            } else {
                return error.UnexpectedToken;
            }
        }

        // Constraint name
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const name = self.cur.lexeme;
        self.advance();

        return .{ .DropConstraint = .{
            .name = name,
            .if_exists = if_exists,
        } };
    }

    // Parse CREATE SCHEMA statement
    fn parseCreateSchema(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.SCHEMA);

        // Optional IF NOT EXISTS
        var if_not_exists = false;
        if (self.cur.kind == .IF) {
            self.advance();
            if (self.cur.kind == .NOT) {
                self.advance();
                if (self.cur.kind == .EXISTS) {
                    self.advance();
                    if_not_exists = true;
                } else {
                    return error.UnexpectedToken;
                }
            } else {
                return error.UnexpectedToken;
            }
        }

        // Schema name
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const name = self.cur.lexeme;
        self.advance();

        return .{ .CreateSchema = .{
            .name = name,
            .if_not_exists = if_not_exists,
        } };
    }

    // Parse CREATE GRAPH statement with optional OR REPLACE
    fn parseCreateGraphWithReplace(self: *Parser, or_replace: bool) ParserError!ast.Statement {
        var property_graph = true;

        // Check for PROPERTY keyword
        if (self.cur.kind == .PROPERTY or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "PROPERTY")))
        {
            self.advance();
            property_graph = true;
        }

        // Expect GRAPH keyword
        if (self.cur.kind != .GRAPH) return error.UnexpectedToken;
        self.advance();

        // Optional IF NOT EXISTS
        var if_not_exists = false;
        if (self.cur.kind == .IF) {
            self.advance();
            if (self.cur.kind == .NOT) {
                self.advance();
                if (self.cur.kind == .EXISTS) {
                    self.advance();
                    if_not_exists = true;
                } else {
                    return error.UnexpectedToken;
                }
            } else {
                return error.UnexpectedToken;
            }
        }

        // Check for TYPE (graph type creation) immediately after GRAPH (and optional IF NOT EXISTS)
        if (self.cur.kind == .TYPE or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "TYPE")))
        {
            // This is CREATE [PROPERTY] GRAPH TYPE
            // TYPE is already detected, don't consume it here - let parseCreateGraphType handle it
            return self.parseCreateGraphType(or_replace, property_graph);
        }

        // Graph name (for regular CREATE GRAPH statements)
        // Support qualified names: schema.graph or just graph
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        var name = self.cur.lexeme;
        self.advance();

        // Check for qualified name (schema.graph)
        if (self.cur.kind == .dot) {
            self.advance(); // consume dot
            if (self.cur.kind != .identifier) return error.UnexpectedToken;
            // Concatenate schema.graph
            const graph_part = self.cur.lexeme;
            const qualified_name = try std.fmt.allocPrint(self.arena.allocator(), "{s}.{s}", .{ name, graph_part });
            name = qualified_name;
            self.advance();
        }

        // Initialize optional fields
        var typed_spec: ?[]const u8 = null;
        var like_source: ?[]const u8 = null;
        var copy_source: ?[]const u8 = null;

        // Check for TYPED clause
        if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "TYPED")) {
            self.advance(); // Skip TYPED
            // Expect type specification
            if (self.cur.kind == .identifier) {
                typed_spec = self.cur.lexeme;
                self.advance();
            } else if (self.cur.kind == .ANY) {
                typed_spec = "ANY";
                self.advance();
            } else {
                return error.UnexpectedToken;
            }
            // Optional PROPERTY GRAPH after type spec
            if (self.cur.kind == .PROPERTY or
                (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "PROPERTY")))
            {
                self.advance();
                if (self.cur.kind == .GRAPH) {
                    self.advance();
                }
            }
        }
        // Check for ANY keyword (without TYPED)
        else if (self.cur.kind == .ANY) {
            self.advance();
            // Optional PROPERTY GRAPH keywords after ANY
            if (self.cur.kind == .PROPERTY or
                (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "PROPERTY")))
            {
                self.advance();
                if (self.cur.kind == .GRAPH) {
                    self.advance();
                }
            } else if (self.cur.kind == .GRAPH) {
                self.advance();
            }
        }
        // Check for LIKE clause first (independent of TYPED/ANY)
        else if (self.cur.kind == .LIKE) {
            self.advance(); // Skip LIKE
            if (self.cur.kind == .identifier) {
                like_source = self.cur.lexeme;
                self.advance();
            } else {
                return error.UnexpectedToken;
            }
        }

        // Check for AS COPY OF clause (can be combined with TYPED/ANY but not LIKE)
        if (self.cur.kind == .AS and like_source == null) {
            self.advance(); // Skip AS
            if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "COPY")) {
                self.advance(); // Skip COPY
                if (self.cur.kind == .OF or
                    (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "OF")))
                {
                    self.advance(); // Skip OF
                    if (self.cur.kind == .identifier) {
                        copy_source = self.cur.lexeme;
                        self.advance();
                    } else {
                        return error.UnexpectedToken;
                    }
                } else {
                    return error.UnexpectedToken;
                }
            } else {
                return error.UnexpectedToken;
            }
        }

        return .{ .CreateGraph = .{
            .name = name,
            .if_not_exists = if_not_exists,
            .or_replace = or_replace,
            .property_graph = property_graph,
            .typed_spec = typed_spec,
            .like_source = like_source,
            .copy_source = copy_source,
        } };
    }

    // Parse CREATE GRAPH statement (wrapper for compatibility)
    fn parseCreateGraph(self: *Parser) ParserError!ast.Statement {
        return self.parseCreateGraphWithReplace(false);
    }

    // Parse CREATE GRAPH TYPE statement
    // Field-Level Encryption Parser Extensions
    // CANARY: REQ=REQ-FLE-PARSER-001; FEATURE="FieldLevelEncryption"; ASPECT=PARSER; STATUS=TESTED; TEST=tests/test_tde_kms_integration.zig; OWNER=security; UPDATED=2026-01-15

    /// Parse field definitions within graph type: { field1 TYPE, field2 TYPE @annotations, ... }
    fn parseFieldDefinitions(self: *Parser) ParserError![]ast.FieldDefinition {
        _ = try self.expect(.l_brace); // Consume opening brace

        var fields = std.ArrayList(ast.FieldDefinition).empty;

        // Parse fields until we hit closing brace
        while (self.cur.kind != .r_brace and self.cur.kind != .eof) {
            // Field name
            if (self.cur.kind != .identifier) return error.UnexpectedToken;
            const field_name = self.cur.lexeme;
            self.advance();

            // Field type (required)
            if (self.cur.kind != .identifier) return error.UnexpectedToken;
            const type_name = self.cur.lexeme;
            self.advance();

            // Optional PRIMARY KEY
            var primary_key = false;
            if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "PRIMARY")) {
                self.advance();
                if (self.cur.kind == .KEY or (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "KEY"))) {
                    self.advance();
                    primary_key = true;
                }
            }

            // Parse annotations (e.g., @encrypted(...), @searchable(...))
            var annotations = std.ArrayList(ast.FieldAnnotation).empty;
            while (self.cur.kind == .at) {
                // Track start of annotation (@)
                const at_lexeme = self.cur.lexeme;
                const annotation_start = @intFromPtr(at_lexeme.ptr) - @intFromPtr(self.lx.src.ptr);
                self.advance(); // Skip @

                // Annotation name
                if (self.cur.kind != .identifier) return error.UnexpectedToken;
                const annot_name = self.cur.lexeme;
                var annotation_end = @intFromPtr(annot_name.ptr) - @intFromPtr(self.lx.src.ptr) + annot_name.len;
                self.advance();

                // Annotation parameters (optional)
                if (self.cur.kind == .l_paren) {
                    self.advance(); // Skip opening paren

                    // Skip until matching closing paren
                    var paren_count: i32 = 1;
                    while (paren_count > 0 and self.cur.kind != .eof) {
                        if (self.cur.kind == .l_paren) {
                            paren_count += 1;
                        } else if (self.cur.kind == .r_paren) {
                            paren_count -= 1;
                        }
                        annotation_end = @intFromPtr(self.cur.lexeme.ptr) - @intFromPtr(self.lx.src.ptr) + self.cur.lexeme.len;
                        if (paren_count > 0) {
                            self.advance();
                        }
                    }

                    if (paren_count != 0) return error.UnexpectedToken;
                    self.advance(); // Skip closing paren
                }

                // Extract full annotation text from source
                const annot_text = self.lx.src[annotation_start..annotation_end];

                try annotations.append(self.arena.allocator(), .{
                    .name = annot_name,
                    .text = annot_text,
                });
            }

            // Add field definition
            try fields.append(self.arena.allocator(), .{
                .name = field_name,
                .type_name = type_name,
                .nullable = true, // Default to nullable
                .primary_key = primary_key,
                .annotations = try annotations.toOwnedSlice(self.arena.allocator()),
            });

            // Expect comma or closing brace
            if (self.cur.kind == .comma) {
                self.advance();
                // Allow trailing comma before closing brace
                if (self.cur.kind == .r_brace) break;
            } else if (self.cur.kind == .r_brace) {
                break;
            } else {
                return error.UnexpectedToken;
            }
        }

        _ = try self.expect(.r_brace); // Consume closing brace

        return try fields.toOwnedSlice(self.arena.allocator());
    }

    fn parseCreateGraphType(self: *Parser, or_replace: bool, property_graph: bool) ParserError!ast.Statement {
        // Expect TYPE keyword
        if (self.cur.kind != .TYPE and
            !(self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "TYPE")))
        {
            return error.UnexpectedToken;
        }
        self.advance();

        // Optional IF NOT EXISTS
        var if_not_exists = false;
        if (self.cur.kind == .IF) {
            self.advance();
            if (self.cur.kind == .NOT) {
                self.advance();
                if (self.cur.kind == .EXISTS) {
                    self.advance();
                    if_not_exists = true;
                } else {
                    return error.UnexpectedToken;
                }
            } else {
                return error.UnexpectedToken;
            }
        }

        // Graph type name
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const name = self.cur.lexeme;
        self.advance();

        // Initialize optional fields
        var like_source: ?[]const u8 = null;
        var copy_source: ?[]const u8 = null;
        const type_definition: []const u8 = "{ }"; // Default empty type definition

        // Check for AS keyword (COPY OF or type definition)
        if (self.cur.kind == .AS) {
            self.advance(); // Skip AS

            // Check for COPY OF
            if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "COPY")) {
                self.advance(); // Skip COPY
                if (self.cur.kind == .OF or
                    (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "OF")))
                {
                    self.advance(); // Skip OF
                    if (self.cur.kind == .identifier) {
                        copy_source = self.cur.lexeme;
                        self.advance();
                    } else {
                        return error.UnexpectedToken;
                    }
                } else {
                    return error.UnexpectedToken;
                }
            } else {
                // This should be a type definition starting with {
                if (self.cur.kind == .l_brace) {
                    // Parse field definitions
                    const fields = try self.parseFieldDefinitions();
                    return .{
                        .CreateGraphType = .{
                            .name = name,
                            .if_not_exists = if_not_exists,
                            .or_replace = or_replace,
                            .property_graph = property_graph,
                            .type_definition = "{ }", // Keep for backward compatibility
                            .fields = fields,
                            .like_source = like_source,
                            .copy_source = copy_source,
                        },
                    };
                } else {
                    return error.UnexpectedToken;
                }
            }
        }
        // Check for LIKE clause
        else if (self.cur.kind == .LIKE) {
            self.advance(); // Skip LIKE
            if (self.cur.kind == .identifier) {
                like_source = self.cur.lexeme;
                self.advance();
            } else {
                return error.UnexpectedToken;
            }
        }

        return .{
            .CreateGraphType = .{
                .name = name,
                .if_not_exists = if_not_exists,
                .or_replace = or_replace,
                .property_graph = property_graph,
                .type_definition = type_definition,
                .fields = &.{}, // Empty fields for LIKE/COPY OF cases
                .like_source = like_source,
                .copy_source = copy_source,
            },
        };
    }

    // Parse DROP SCHEMA statement
    fn parseDropSchema(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.SCHEMA);

        // Optional IF EXISTS
        var if_exists = false;
        if (self.cur.kind == .IF) {
            self.advance();
            if (self.cur.kind == .EXISTS) {
                self.advance();
                if_exists = true;
            } else {
                return error.UnexpectedToken;
            }
        }

        // Schema name
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const name = self.cur.lexeme;
        self.advance();

        return .{ .DropSchema = .{
            .name = name,
            .if_exists = if_exists,
        } };
    }

    // Parse DROP GRAPH statement
    fn parseDropGraph(self: *Parser) ParserError!ast.Statement {
        var property_graph = true;

        // Check for PROPERTY keyword
        if (self.cur.kind == .PROPERTY or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "PROPERTY")))
        {
            self.advance();
            property_graph = true;
        }

        // Expect GRAPH keyword
        if (self.cur.kind != .GRAPH) return error.UnexpectedToken;
        self.advance();

        // Check for TYPE keyword (DROP GRAPH TYPE)
        if (self.cur.kind == .TYPE or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "TYPE")))
        {
            return self.parseDropGraphType(property_graph);
        }

        // Optional IF EXISTS
        var if_exists = false;
        if (self.cur.kind == .IF) {
            self.advance();
            if (self.cur.kind == .EXISTS) {
                self.advance();
                if_exists = true;
            } else {
                return error.UnexpectedToken;
            }
        }

        // Graph name
        // Support qualified names: schema.graph or just graph
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        var name = self.cur.lexeme;
        self.advance();

        // Check for qualified name (schema.graph)
        if (self.cur.kind == .dot) {
            self.advance(); // consume dot
            if (self.cur.kind != .identifier) return error.UnexpectedToken;
            // Concatenate schema.graph
            const graph_part = self.cur.lexeme;
            const qualified_name = try std.fmt.allocPrint(self.arena.allocator(), "{s}.{s}", .{ name, graph_part });
            name = qualified_name;
            self.advance();
        }

        return .{ .DropGraph = .{
            .name = name,
            .if_exists = if_exists,
            .property_graph = property_graph,
        } };
    }

    // Parse DROP GRAPH TYPE statement (disabled for now)
    fn parseDropGraphType(self: *Parser, property_graph: bool) ParserError!ast.Statement {
        // Expect TYPE keyword
        if (self.cur.kind != .TYPE and
            !(self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "TYPE")))
        {
            return error.UnexpectedToken;
        }
        self.advance();

        // Optional IF EXISTS
        var if_exists = false;
        if (self.cur.kind == .IF) {
            self.advance();
            if (self.cur.kind == .EXISTS) {
                self.advance();
                if_exists = true;
            } else {
                return error.UnexpectedToken;
            }
        }

        // Graph type name
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const name = self.cur.lexeme;
        self.advance();

        return .{ .DropGraphType = .{
            .name = name,
            .if_exists = if_exists,
            .property_graph = property_graph,
        } };
    }

    // Parse BACKUP statement
    fn parseBackupStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.identifier); // Expect BACKUP

        // TO keyword or path
        if (self.cur.kind == .TO) {
            self.advance();
        }

        // Parse path as string literal
        if (self.cur.kind != .string_lit) return error.UnexpectedToken;
        const path = self.cur.lexeme;
        self.advance();

        var incremental = false;
        var compressed = false;
        var encrypted = false;
        var encryption_key: ?[]const u8 = null;

        // Parse options
        while (self.cur.kind == .WITH or self.cur.kind == .identifier) {
            if (self.cur.kind == .WITH) {
                self.advance();
            }

            if (self.cur.kind == .identifier) {
                const option = self.cur.lexeme;
                if (std.ascii.eqlIgnoreCase(option, "INCREMENTAL")) {
                    incremental = true;
                } else if (std.ascii.eqlIgnoreCase(option, "COMPRESSED")) {
                    compressed = true;
                } else if (std.ascii.eqlIgnoreCase(option, "ENCRYPTED")) {
                    encrypted = true;
                    self.advance();
                    // Optional encryption key
                    if (self.cur.kind == .string_lit) {
                        encryption_key = self.cur.lexeme;
                        self.advance();
                    }
                    continue;
                }
                self.advance();
            }
        }

        return .{ .Backup = .{
            .path = path,
            .incremental = incremental,
            .compressed = compressed,
            .encrypted = encrypted,
            .encryption_key = encryption_key,
        } };
    }

    // Parse RESTORE statement
    fn parseRestoreStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.identifier); // Expect RESTORE

        // FROM keyword or path
        if (self.cur.kind == .FROM) {
            self.advance();
        }

        // Parse path as string literal
        if (self.cur.kind != .string_lit) return error.UnexpectedToken;
        const path = self.cur.lexeme;
        self.advance();

        var timestamp: ?[]const u8 = null;
        var verify_only = false;

        // Parse options
        while (self.cur.kind == .TO or self.cur.kind == .identifier) {
            if (self.cur.kind == .TO) {
                self.advance();
                // GAP-0871: accept the documented `TO TIMESTAMP '<ts>'` form —
                // TIMESTAMP lexes as a keyword token, skip it before the literal.
                if (self.cur.kind == .TIMESTAMP) {
                    self.advance();
                }
                // Expect timestamp
                if (self.cur.kind == .string_lit) {
                    timestamp = self.cur.lexeme;
                    self.advance();
                }
            } else {
                const option = self.cur.lexeme;
                if (std.ascii.eqlIgnoreCase(option, "VERIFY")) {
                    verify_only = true;
                    self.advance();
                    // GAP-0871: ONLY lexes as a keyword token (.ONLY), not an
                    // identifier — accept both so `VERIFY ONLY` parses and the
                    // statement reaches the stable executor-level refusal.
                    if (self.cur.kind == .ONLY or (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "ONLY"))) {
                        self.advance();
                    }
                } else {
                    // Unknown option identifier — consume to guarantee progress
                    // (the loop previously spun forever on unrecognized options).
                    self.advance();
                }
            }
        }

        return .{ .Restore = .{
            .path = path,
            .timestamp = timestamp,
            .verify_only = verify_only,
        } };
    }

    // ---------------------------------------------------------------------------
    // Auth DDL parse functions (Geode extension — soft-keyword based)
    // ---------------------------------------------------------------------------
    // CANARY: REQ=REQ-GQL-AUTH-DDL-002; FEATURE="GQL Auth DDL"; ASPECT=Parser; STATUS=TESTED; TEST=tests/test_auth_ddl_parser.zig; OWNER=parser; UPDATED=2026-05-11

    // Parse CREATE USER <name> SET PASSWORD '<pw>' [EMAIL '<email>'] [ROLE <role>]
    fn parseCreateUser(self: *Parser) ParserError!ast.Statement {
        const name = try self.parseName();
        _ = try self.expect(.SET);
        if (!self.softKw("PASSWORD")) return self.unexpected("expected PASSWORD after SET in CREATE USER");
        self.advance(); // PASSWORD
        const password = try self.parseStringLit();
        var email: ?[]const u8 = null;
        var role: ?[]const u8 = null;
        while (self.softKw("EMAIL") or self.softKw("ROLE")) {
            if (self.softKw("EMAIL")) {
                self.advance();
                email = try self.parseStringLit();
            } else {
                self.advance(); // ROLE
                role = try self.parseName();
            }
        }
        return .{ .CreateUser = .{ .name = name, .password = password, .email = email, .role = role } };
    }

    // Parse CREATE ROLE <name> [SET DESCRIPTION '<desc>']
    fn parseCreateRole(self: *Parser) ParserError!ast.Statement {
        const name = try self.parseName();
        var description: ?[]const u8 = null;
        if (self.cur.kind == .SET) {
            self.advance();
            if (!self.softKw("DESCRIPTION")) return self.unexpected("expected DESCRIPTION after SET in CREATE ROLE");
            self.advance();
            description = try self.parseStringLit();
        }
        return .{ .CreateRole = .{ .name = name, .description = description } };
    }

    // Parse DROP USER [IF EXISTS] <name>  or  DROP ROLE [IF EXISTS] <name>
    fn parseDropUserOrRole(self: *Parser, is_user: bool) ParserError!ast.Statement {
        var if_exists = false;
        if (self.cur.kind == .IF) {
            self.advance();
            if (self.cur.kind != .EXISTS) return self.unexpected("expected EXISTS after IF");
            self.advance();
            if_exists = true;
        }
        const name = try self.parseName();
        if (is_user) return .{ .DropUser = .{ .name = name, .if_exists = if_exists } };
        return .{ .DropRole = .{ .name = name, .if_exists = if_exists } };
    }

    // Parse ALTER USER <name> ENABLE|DISABLE|SET PASSWORD '<pw>'|SET ROLE <role>
    fn parseAlterStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.identifier); // ALTER
        if (self.softKw("POLICY")) {
            self.advance(); // POLICY
            return self.parseAlterPolicy();
        }
        if (!self.softKw("USER")) return self.unexpected("expected USER or POLICY after ALTER");
        self.advance(); // USER
        const name = try self.parseName();
        if (self.softKw("ENABLE")) {
            self.advance();
            return .{ .AlterUser = .{ .name = name, .action = .enable } };
        }
        if (self.softKw("DISABLE")) {
            self.advance();
            return .{ .AlterUser = .{ .name = name, .action = .disable } };
        }
        _ = try self.expect(.SET);
        if (self.softKw("PASSWORD")) {
            self.advance();
            const pw = try self.parseStringLit();
            return .{ .AlterUser = .{ .name = name, .action = .{ .set_password = pw } } };
        }
        if (self.softKw("ROLE")) {
            self.advance();
            const r = try self.parseName();
            return .{ .AlterUser = .{ .name = name, .action = .{ .set_role = r } } };
        }
        // #832: ALTER USER <name> SET ATTRIBUTE <key> = <value>
        if (self.softKw("ATTRIBUTE")) {
            self.advance();
            const key = try self.parseName();
            _ = try self.expect(.eq);
            const value = try self.parseStringLit();
            return .{ .AlterUser = .{ .name = name, .action = .{ .set_attribute = .{ .key = key, .value = value } } } };
        }
        return self.unexpected("expected PASSWORD, ROLE, or ATTRIBUTE after ALTER USER ... SET");
    }

    // Parse READ | WRITE | SCHEMA | ALL into a GrantPrivilege
    fn parseGrantPrivilege(self: *Parser) ParserError!ast.GrantPrivilege {
        switch (self.cur.kind) {
            .READ => {
                self.advance();
                return .read;
            },
            .WRITE => {
                self.advance();
                return .write;
            },
            .SCHEMA => {
                self.advance();
                return .schema;
            },
            .ALL => {
                self.advance();
                return .all;
            },
            else => return self.unexpected("expected one of READ, WRITE, SCHEMA, ALL"),
        }
    }

    // Parse optional ON GRAPH <name> clause
    fn parseOnGraphClause(self: *Parser) ParserError!?[]const u8 {
        if (self.cur.kind != .ON) return null;
        self.advance(); // ON
        if (self.cur.kind != .GRAPH) return self.unexpected("expected GRAPH after ON");
        self.advance(); // GRAPH
        return try self.parseName();
    }

    // Parse GRANT ROLE <role> TO <user>  or  GRANT <priv> [ON GRAPH <g>] TO <user>
    fn parseGrantStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.identifier); // GRANT
        if (self.softKw("ROLE")) {
            self.advance(); // ROLE
            const role_name = try self.parseName();
            _ = try self.expect(.TO);
            const grantee = try self.parseName();
            return .{ .Grant = .{ .subject = .{ .role = role_name }, .on_graph = null, .grantee = grantee } };
        }
        const priv = try self.parseGrantPrivilege();
        const on_graph = try self.parseOnGraphClause();
        _ = try self.expect(.TO);
        const grantee = try self.parseName();
        return .{ .Grant = .{ .subject = .{ .privilege = priv }, .on_graph = on_graph, .grantee = grantee } };
    }

    // Parse REVOKE <priv> [ON GRAPH <g>] FROM <user>
    fn parseRevokeStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.identifier); // REVOKE
        const priv = try self.parseGrantPrivilege();
        const on_graph = try self.parseOnGraphClause();
        _ = try self.expect(.FROM);
        const grantee = try self.parseName();
        return .{ .Revoke = .{ .privilege = priv, .on_graph = on_graph, .grantee = grantee } };
    }

    // ---------------------------------------------------------------------------
    // GPS policy DDL parse functions (Phase 4 — soft-keyword based).
    // CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=Parser; STATUS=TESTED; TEST=tests/test_gps_policy_ddl_parser.zig; OWNER=security; UPDATED=2026-05-20
    // ---------------------------------------------------------------------------

    // Parse a single PolicyAction from the current token.
    // Actions that are reserved keywords (MATCH, READ, WRITE, SCHEMA, DELETE, CREATE)
    // are matched by kind; UPDATE is a soft keyword (identifier).
    fn parsePolicyAction(self: *Parser) ParserError!ast.PolicyAction {
        switch (self.cur.kind) {
            .READ => {
                self.advance();
                return .read;
            },
            .WRITE => {
                self.advance();
                return .write;
            },
            .MATCH => {
                self.advance();
                return .match_;
            },
            .CREATE => {
                self.advance();
                return .create;
            },
            .DELETE => {
                self.advance();
                return .delete;
            },
            .SCHEMA => {
                self.advance();
                return .schema;
            },
            else => {
                if (self.softKw("UPDATE")) {
                    self.advance();
                    return .update;
                }
                return self.unexpected("expected one of READ, WRITE, MATCH, CREATE, UPDATE, DELETE, SCHEMA");
            },
        }
    }

    // Parse a non-empty comma-separated ActionList.
    fn parsePolicyActionList(self: *Parser) ParserError![]ast.PolicyAction {
        var list = std.ArrayList(ast.PolicyAction).empty;
        const first = try self.parsePolicyAction();
        try list.append(self.arena.allocator(), first);
        while (self.cur.kind == .comma) {
            self.advance(); // consume comma
            const action = try self.parsePolicyAction();
            try list.append(self.arena.allocator(), action);
        }
        return list.toOwnedSlice(self.arena.allocator());
    }

    // Skip tokens until semicolon or EOF — used to discard Phase 5+ clauses
    // (TO ROLE, USING <expr>, WITH CHECK) that appear after the FOR <ActionList>.
    fn skipTrailingPolicyClauses(self: *Parser) void {
        while (self.cur.kind != .semicolon and self.cur.kind != .eof) {
            self.advance();
        }
    }

    // Parse CREATE POLICY <name> ON GRAPH (<graph_name> | "*") FOR <ActionList>
    // Trailing Phase 5+ clauses are consumed and discarded.
    fn parseCreatePolicy(self: *Parser) ParserError!ast.Statement {
        const name = try self.parseName();
        if (self.cur.kind != .ON) return self.unexpected("expected ON after CREATE POLICY <name>");
        self.advance(); // ON
        if (self.cur.kind != .GRAPH) return self.unexpected("expected GRAPH after ON in CREATE POLICY");
        self.advance(); // GRAPH
        // Accept either a bare "*" (star / multiply token) or an identifier.
        const scope_graph: []const u8 = if (self.cur.kind == .star) blk: {
            self.advance();
            break :blk "*";
        } else try self.parseName();
        if (self.cur.kind != .FOR) return self.unexpected("expected FOR after graph scope in CREATE POLICY");
        self.advance(); // FOR
        const actions = try self.parsePolicyActionList();
        // CANARY: REQ=REQ-GPS-EXPR-002; FEATURE="GPS Policy Expression"; ASPECT=ParseCaptureUsing; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/gps_phase6_abac_migration.yml; OWNER=security; UPDATED=2026-05-21
        // Capture the USING <expr> clause source text. Phase 4 discarded it;
        // Phase 5+ needs the raw source so policy_expression can compile it.
        // TO ROLE and WITH CHECK clauses are still discarded.
        var expression_source: ?[]const u8 = null;
        while (self.cur.kind != .semicolon and self.cur.kind != .eof) {
            if (self.cur.kind == .USING) {
                self.advance(); // consume USING
                // Capture the byte offset of the current token inside the lexer's
                // source buffer. Walk to the clause terminator (semicolon/eof).
                // For each token, set end_offset to the lexer's idx *after*
                // consuming it — this includes any closing quotes or other
                // trailing characters that aren't part of the lexeme itself
                // (string literals strip their quotes).
                const src = self.lx.src;
                const start_offset: usize = @intFromPtr(self.cur.lexeme.ptr) - @intFromPtr(src.ptr);
                var end_offset: usize = start_offset;
                while (self.cur.kind != .semicolon and self.cur.kind != .eof) {
                    self.advance();
                    // self.lx.idx is the lexer's read cursor — for the previous
                    // token it points just past the last consumed byte (including
                    // closing quote for string literals).  For the new cur token
                    // it points past *that* token's start, so back off to the
                    // beginning of the new cur token for the actual end.
                    //
                    // CANARY: REQ=REQ-RLS-POLICY-COMPILE-ERROR-AT-DDL; FEATURE="GPS Policy Expression"; ASPECT=UsingCaptureExcludesTerminator; STATUS=TESTED; TEST=tests/test_rls_policy_ddl.zig; OWNER=security; UPDATED=2026-08-25
                    // RLS-POLICY-DDL: the semicolon arm used to take self.lx.idx too,
                    // which points PAST the `;` — so the captured source was
                    // "current_user() = 'alice';" and compileExpression rejected
                    // it as trailing junk. Every semicolon-terminated
                    // `CREATE POLICY … USING …` therefore stored compiled=null
                    // and silently denied everything, including perfectly valid
                    // predicates. The `catch null` at the call site hid it.
                    // The terminator is not part of the expression, so a
                    // semicolon now ends the capture at its own start, exactly
                    // like any other following token. Only EOF — which has no
                    // terminator to exclude and no lexeme to point at — takes
                    // the read cursor.
                    if (self.cur.kind == .eof) {
                        end_offset = self.lx.idx;
                    } else {
                        end_offset = @intFromPtr(self.cur.lexeme.ptr) - @intFromPtr(src.ptr);
                    }
                }
                // Trim trailing whitespace/EOF padding.
                while (end_offset > start_offset and end_offset <= src.len) {
                    const c = src[end_offset - 1];
                    if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                        end_offset -= 1;
                    } else break;
                }
                if (end_offset > start_offset and end_offset <= src.len) {
                    expression_source = src[start_offset..end_offset];
                }
                break;
            }
            self.advance();
        }
        // Consume any remaining tokens to the semicolon/eof.
        self.skipTrailingPolicyClauses();
        return .{ .CreatePolicy = .{
            .name = name,
            .scope_graph = scope_graph,
            .actions = actions,
            .expression_source = expression_source,
        } };
    }

    // Parse DROP POLICY [IF EXISTS] <name>
    fn parseDropPolicy(self: *Parser) ParserError!ast.Statement {
        var if_exists = false;
        if (self.cur.kind == .IF) {
            self.advance();
            if (self.cur.kind != .EXISTS) return self.unexpected("expected EXISTS after IF in DROP POLICY");
            self.advance();
            if_exists = true;
        }
        const name = try self.parseName();
        return .{ .DropPolicy = .{ .name = name, .if_exists = if_exists } };
    }

    // Parse ALTER POLICY <name> SET ENABLED true|false
    //    or ALTER POLICY <name> RENAME TO <new_name>
    // CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS ALTER POLICY DDL"; ASPECT=Parser; STATUS=TESTED; TEST=tests/test_gps_alter_policy.zig; OWNER=security; UPDATED=2026-06-09
    fn parseAlterPolicy(self: *Parser) ParserError!ast.Statement {
        const name = try self.parseName();

        // GAP-0858: RENAME TO <new_name> branch (durable rename).
        if (self.softKw("RENAME")) {
            self.advance(); // RENAME
            _ = try self.expect(.TO);
            const new_name = try self.parseName();
            return .{ .AlterPolicy = .{ .name = name, .rename_to = new_name } };
        }

        _ = try self.expect(.SET);
        if (!self.softKw("ENABLED")) return self.unexpected("expected ENABLED after ALTER POLICY <name> SET");
        self.advance(); // ENABLED
        const enabled: bool = switch (self.cur.kind) {
            .TRUE => blk: {
                self.advance();
                break :blk true;
            },
            .FALSE => blk: {
                self.advance();
                break :blk false;
            },
            else => return self.unexpected("expected true or false after ALTER POLICY ... SET ENABLED"),
        };
        return .{ .AlterPolicy = .{ .name = name, .set_enabled = enabled } };
    }

    // Parse SESSION SET statement with full ISO GQL syntax
    fn parseSessionSetStatement(self: *Parser) ParserError!ast.Statement {
        self.advance(); // consume SET

        // Parse the different types of SESSION SET clauses
        if (self.cur.kind == .SCHEMA) {
            self.advance();
            // Parse schema reference
            const schema_name = if (self.cur.kind == .identifier or self.cur.kind == .string_lit) blk: {
                const name = self.cur.lexeme;
                self.advance();
                break :blk name;
            } else {
                return error.UnexpectedToken;
            };

            return .{ .SessionSet = .{
                .clause_type = .{ .Schema = .{ .name = schema_name } },
            } };
        } else if (self.cur.kind == .GRAPH or self.cur.kind == .PROPERTY) {
            // Check if this is a parameter clause (GRAPH $param = ...) or graph setting (GRAPH name)
            const is_property = self.cur.kind == .PROPERTY;
            if (is_property) self.advance();

            _ = try self.expect(.GRAPH);

            // If next token is IF NOT EXISTS or a parameter ($...), parse as GRAPH parameter clause
            if (self.cur.kind == .IF or self.cur.kind == .dollar) {
                const param_name = try self.parseSessionParameterName();
                var initializer: ?[]const u8 = null;
                if (self.cur.kind == .eq) {
                    self.advance();
                    // Parse the initializer expression - accept various formats
                    if (self.cur.kind == .l_brace) {
                        // Graph literal like {} or { MATCH ... }
                        const start_idx = self.lx.idx - 1; // Include the opening brace
                        var brace_depth: u32 = 1;
                        self.advance(); // consume {
                        while (brace_depth > 0 and self.cur.kind != .eof) {
                            if (self.cur.kind == .l_brace) brace_depth += 1;
                            if (self.cur.kind == .r_brace) brace_depth -= 1;
                            self.advance();
                        }
                        const end_idx = self.lx.idx;
                        initializer = self.lx.src[start_idx..end_idx];
                    } else if (self.cur.kind == .identifier or self.cur.kind == .string_lit or self.cur.kind == .integer_lit or self.cur.kind == .TRUE or self.cur.kind == .FALSE) {
                        initializer = self.cur.lexeme;
                        self.advance();
                    }
                }

                return .{ .SessionSet = .{
                    .clause_type = .{ .Parameter = .{ .GraphParam = .{
                        .property_graph = is_property,
                        .parameter_name = param_name,
                        .initializer = initializer,
                    } } },
                } };
            }

            // Otherwise, parse as graph expression
            // Optional = before graph name (e.g., SET SESSION GRAPH = 'name')
            if (self.cur.kind == .eq) {
                self.advance();
            }

            const graph_expr = if (self.cur.kind == .identifier or self.cur.kind == .string_lit) blk: {
                const expr = self.cur.lexeme;
                self.advance();
                break :blk expr;
            } else {
                return error.UnexpectedToken;
            };

            return .{ .SessionSet = .{
                .clause_type = .{ .Graph = .{
                    .property_graph = is_property,
                    .expression = graph_expr,
                } },
            } };
        } else if (self.cur.kind == .time_lit or self.cur.kind == .TIME or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "TIME")))
        {
            // Handle TIME ZONE in SESSION SET context
            // Note: "TIME" without following string literal is now lexed as .TIME keyword
            self.advance();
            _ = try self.expect(.ZONE);

            // Parse time zone value - can be string literal or LOCAL keyword
            const tz_value = if (self.cur.kind == .string_lit) blk: {
                const val = self.cur.lexeme;
                self.advance();
                break :blk val;
            } else if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "LOCAL")) blk2: {
                const val = self.cur.lexeme;
                self.advance();
                break :blk2 val;
            } else {
                return error.UnexpectedToken;
            };

            return .{ .SessionSet = .{
                .clause_type = .{ .TimeZone = .{ .value = tz_value } },
            } };
        } else if (self.cur.kind == .VALUE or self.cur.kind == .BINDING or self.cur.kind == .TABLE) {
            // Parse parameter clauses
            return .{ .SessionSet = .{
                .clause_type = .{ .Parameter = try self.parseSessionParameterClause() },
            } };
        } else {
            return error.UnexpectedToken;
        }
    }

    // Parse SESSION RESET statement with full ISO GQL syntax
    fn parseSessionResetStatement(self: *Parser) ParserError!ast.Statement {
        self.advance(); // consume RESET

        // Parse optional reset arguments
        if (self.cur.kind == .semicolon or self.cur.kind == .eof) {
            // SESSION RESET without arguments
            return .{ .SessionReset = .{ .arguments = null } };
        }

        // Parse reset arguments
        if (self.cur.kind == .ALL) {
            self.advance();
            // Parse ALL PARAMETERS or ALL CHARACTERISTICS
            if (self.cur.kind == .identifier) {
                const type_arg = self.cur.lexeme;
                self.advance();
                if (std.ascii.eqlIgnoreCase(type_arg, "PARAMETERS")) {
                    return .{ .SessionReset = .{
                        .arguments = .{ .All = .Parameters },
                    } };
                } else if (std.ascii.eqlIgnoreCase(type_arg, "CHARACTERISTICS")) {
                    return .{ .SessionReset = .{
                        .arguments = .{ .All = .Characteristics },
                    } };
                }
            }
        } else if (self.cur.kind == .identifier) {
            const arg = self.cur.lexeme;
            if (std.ascii.eqlIgnoreCase(arg, "PARAMETERS")) {
                // SESSION RESET PARAMETERS (equivalent to ALL PARAMETERS)
                self.advance();
                return .{ .SessionReset = .{
                    .arguments = .{ .All = .Parameters },
                } };
            } else if (std.ascii.eqlIgnoreCase(arg, "PARAMETER")) {
                self.advance();
                // Parse parameter specification (with $ prefix)
                _ = try self.expect(.dollar); // Consume $
                // Allow any keyword to be used as a parameter name (like count, name, etc.)
                const param_spec = if (self.cur.kind == .string_lit) blk: {
                    const spec = self.cur.lexeme;
                    self.advance();
                    break :blk spec;
                } else blk: {
                    const token = try self.expectIdentifierOrKeyword();
                    break :blk token.lexeme;
                };

                return .{ .SessionReset = .{
                    .arguments = .{ .Parameter = param_spec },
                } };
            } else if (std.ascii.eqlIgnoreCase(arg, "TIME")) {
                // SESSION RESET TIME ZONE
                self.advance(); // consume TIME
                _ = try self.expect(.ZONE);
                return .{ .SessionReset = .{
                    .arguments = .TimeZone,
                } };
            }
        } else if (self.cur.kind == .SCHEMA) {
            self.advance();
            return .{ .SessionReset = .{
                .arguments = .Schema,
            } };
        } else if (self.cur.kind == .GRAPH or self.cur.kind == .PROPERTY) {
            // Parse [PROPERTY] GRAPH
            const property_graph = if (self.cur.kind == .PROPERTY) blk: {
                self.advance();
                _ = try self.expect(.GRAPH);
                break :blk true;
            } else blk: {
                self.advance(); // consume GRAPH
                break :blk false;
            };

            return .{ .SessionReset = .{
                .arguments = .{ .Graph = property_graph },
            } };
        } else if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "TIME")) {
            // Handle TIME ZONE
            self.advance(); // consume TIME
            _ = try self.expect(.ZONE);
            return .{ .SessionReset = .{
                .arguments = .TimeZone,
            } };
        }

        return error.UnexpectedToken;
    }

    // Parse session parameter clause (for SESSION SET parameter)
    fn parseSessionParameterClause(self: *Parser) ParserError!ast.ParameterClause {
        if (self.cur.kind == .VALUE) {
            self.advance();
            const param_name = try self.parseSessionParameterName();
            // Optional typed value initializer
            var initializer: ?[]const u8 = null;
            if (self.cur.kind == .eq) {
                self.advance();
                if (self.cur.kind == .string_lit or self.cur.kind == .identifier or self.cur.kind == .integer_lit or self.cur.kind == .TRUE or self.cur.kind == .FALSE) {
                    initializer = self.cur.lexeme;
                    self.advance();
                }
            }

            return .{ .ValueParam = .{
                .parameter_name = param_name,
                .initializer = initializer,
            } };
        } else if (self.cur.kind == .BINDING or self.cur.kind == .TABLE) {
            // [BINDING] TABLE
            if (self.cur.kind == .BINDING) {
                self.advance();
                _ = try self.expect(.TABLE);
            } else {
                self.advance(); // consume TABLE
            }

            const param_name = try self.parseSessionParameterName();
            var initializer: ?[]const u8 = null;
            if (self.cur.kind == .eq) {
                self.advance();
                // Accept various initializer formats: string, identifier, number, or braces for table literals
                if (self.cur.kind == .l_brace) {
                    // Table literal like {} or { MATCH ... }
                    const start_idx = self.lx.idx - 1; // Include the opening brace
                    var brace_depth: u32 = 1;
                    self.advance(); // consume {
                    while (brace_depth > 0 and self.cur.kind != .eof) {
                        if (self.cur.kind == .l_brace) brace_depth += 1;
                        if (self.cur.kind == .r_brace) brace_depth -= 1;
                        self.advance();
                    }
                    const end_idx = self.lx.idx;
                    initializer = self.lx.src[start_idx..end_idx];
                } else if (self.cur.kind == .string_lit or self.cur.kind == .identifier or self.cur.kind == .integer_lit or self.cur.kind == .TRUE or self.cur.kind == .FALSE) {
                    initializer = self.cur.lexeme;
                    self.advance();
                }
            }

            return .{ .BindingTableParam = .{
                .parameter_name = param_name,
                .initializer = initializer,
            } };
        } else if (self.cur.kind == .GRAPH or self.cur.kind == .PROPERTY) {
            // [PROPERTY] GRAPH parameter
            const property_graph = if (self.cur.kind == .PROPERTY) blk: {
                self.advance();
                _ = try self.expect(.GRAPH);
                break :blk true;
            } else blk: {
                self.advance(); // consume GRAPH
                break :blk false;
            };

            const param_name = try self.parseSessionParameterName();
            var initializer: ?[]const u8 = null;
            if (self.cur.kind == .eq) {
                self.advance();
                // Accept various initializer formats including braces for graph literals
                if (self.cur.kind == .l_brace) {
                    // Graph literal like {} or { MATCH ... }
                    const start_idx = self.lx.idx - 1; // Include the opening brace
                    var brace_depth: u32 = 1;
                    self.advance(); // consume {
                    while (brace_depth > 0 and self.cur.kind != .eof) {
                        if (self.cur.kind == .l_brace) brace_depth += 1;
                        if (self.cur.kind == .r_brace) brace_depth -= 1;
                        self.advance();
                    }
                    const end_idx = self.lx.idx;
                    initializer = self.lx.src[start_idx..end_idx];
                } else if (self.cur.kind == .string_lit or self.cur.kind == .identifier or self.cur.kind == .integer_lit) {
                    initializer = self.cur.lexeme;
                    self.advance();
                }
            }

            return .{ .GraphParam = .{
                .property_graph = property_graph,
                .parameter_name = param_name,
                .initializer = initializer,
            } };
        } else {
            return error.UnexpectedToken;
        }
    }

    // Parse session parameter name with optional IF NOT EXISTS
    fn parseSessionParameterName(self: *Parser) ParserError!ast.SessionParameterName {
        var if_not_exists = false;

        // Check for optional IF NOT EXISTS
        if (self.cur.kind == .IF) {
            self.advance();
            _ = try self.expect(.NOT);
            _ = try self.expect(.EXISTS);
            if_not_exists = true;
        }

        // Consume the $ token
        _ = try self.expect(.dollar);

        // Parse parameter specification (identifier or keyword after the $)
        // Allow any keyword to be used as a parameter name since it follows $
        const specification = if (self.cur.kind == .string_lit) blk: {
            const spec = self.cur.lexeme;
            self.advance();
            break :blk spec;
        } else blk: {
            const token = try self.expectIdentifierOrKeyword();
            break :blk token.lexeme;
        };

        return .{
            .if_not_exists = if_not_exists,
            .specification = specification,
        };
    }

    // Parse USE GRAPH statement
    fn parseUseStatement(self: *Parser) ParserError!ast.Statement {
        self.advance(); // consume USE

        // Optional GRAPH keyword
        if (self.cur.kind == .GRAPH) {
            self.advance();
        }

        // Expect graph name (identifier or string literal)
        const graph_name = if (self.cur.kind == .identifier or self.cur.kind == .string_lit) blk: {
            const name = self.cur.lexeme;
            self.advance();
            break :blk name;
        } else {
            return error.UnexpectedToken;
        };

        return .{ .UseGraph = .{
            .graph_name = graph_name,
        } };
    }
};

test "parser - != operator in RETURN expression" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var lx = Lexer{ .src = "RETURN 1 != 2 AS x" };
    var parser = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = parser.parseProgram() catch |err| {
        std.debug.print("Parse error: {s}\n", .{@errorName(err)});
        return err;
    };
    try std.testing.expect(program.statements.len > 0);
}

test "parser - != operator in WHERE clause" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var lx = Lexer{ .src = "MATCH (n:Group) WHERE n.trust_level != 'unknown' RETURN n" };
    var parser = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = parser.parseProgram() catch |err| {
        std.debug.print("Parse error: {s}\n", .{@errorName(err)});
        return err;
    };
    try std.testing.expect(program.statements.len > 0);
}

test "parser - <> operator works" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var lx = Lexer{ .src = "RETURN 1 <> 2 AS x" };
    var parser = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = parser.parseProgram() catch |err| {
        std.debug.print("Parse error: {s}\n", .{@errorName(err)});
        return err;
    };
    try std.testing.expect(program.statements.len > 0);
}

// Quality #733 (2026-06-11): hot-path inline test backfill. The deep-nesting
// path through parseExpr/parseMap/parseList (Phase 2 "8+ level" claim) had no
// inline coverage — the three tests above were also dormant (they failed to
// compile under any test root) until this backfill fixed them and wired the
// `zig build test-quality733` focused runner.
test "#733 parser - 8-level nested map/list literal builds the exact AST shape" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // Nesting (8 levels deep): l1>l2>l3>l4>[array]>l5>l6>[array]>l7>l8
    // (bracket literals parse as .ArrayLit — see parsePrimary blk_pc)
    const src =
        "RETURN {l1: {l2: {l3: {l4: [1, {l5: {l6: [{l7: {l8: 42}}]}}]}}}} AS m";
    var lx = Lexer{ .src = src };
    var parser = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try parser.parseProgram();

    try std.testing.expectEqual(@as(usize, 1), program.statements.len);
    const query = program.statements[0].Query;
    try std.testing.expectEqual(@as(usize, 1), query.ret.items.len);
    try std.testing.expectEqualStrings("m", query.ret.items[0].alias.?);

    // Walk levels 1-3: single-key nested maps.
    var expr: *const ast.Expr = &query.ret.items[0].expr;
    inline for (.{ "l1", "l2", "l3" }) |key| {
        try std.testing.expect(expr.* == .Map);
        try std.testing.expectEqual(@as(usize, 1), expr.Map.len);
        try std.testing.expectEqualStrings(key, expr.Map[0].key);
        expr = expr.Map[0].value;
    }

    // Level 4: {l4: [1, {...}]} — list with a scalar and a nested map.
    try std.testing.expect(expr.* == .Map);
    try std.testing.expectEqualStrings("l4", expr.Map[0].key);
    const l4_list = expr.Map[0].value;
    try std.testing.expect(l4_list.* == .ArrayLit);
    try std.testing.expectEqual(@as(usize, 2), l4_list.ArrayLit.len);
    try std.testing.expectEqual(@as(i64, 1), l4_list.ArrayLit[0].Int);

    // Levels 5-6: {l5: {l6: [...]}}.
    const l5_map = l4_list.ArrayLit[1];
    try std.testing.expect(l5_map.* == .Map);
    try std.testing.expectEqualStrings("l5", l5_map.Map[0].key);
    const l6_map = l5_map.Map[0].value;
    try std.testing.expect(l6_map.* == .Map);
    try std.testing.expectEqualStrings("l6", l6_map.Map[0].key);
    const l6_list = l6_map.Map[0].value;
    try std.testing.expect(l6_list.* == .ArrayLit);
    try std.testing.expectEqual(@as(usize, 1), l6_list.ArrayLit.len);

    // Levels 7-8: innermost {l7: {l8: 42}}.
    const l7_map = l6_list.ArrayLit[0];
    try std.testing.expect(l7_map.* == .Map);
    try std.testing.expectEqualStrings("l7", l7_map.Map[0].key);
    const l8_map = l7_map.Map[0].value;
    try std.testing.expect(l8_map.* == .Map);
    try std.testing.expectEqualStrings("l8", l8_map.Map[0].key);
    try std.testing.expectEqual(@as(i64, 42), l8_map.Map[0].value.Int);
}

test "#733 parser - unterminated nested map literal is a clean parse error" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // Error path: 3 opens, 2 closes — the parser must reject, not crash/hang.
    var lx = Lexer{ .src = "RETURN {a: {b: {c: 1}} AS m" };
    var parser = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const result = parser.parseProgram();
    try std.testing.expectError(error.UnexpectedToken, result);
}
