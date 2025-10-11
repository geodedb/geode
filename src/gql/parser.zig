// CANARY: REQ=REQ-GQL-006; FEATURE="GQL Parser"; ASPECT=Parser; STATUS=TESTED; TEST=tests/e2e_protocol.zig; OWNER=parser; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-007; FEATURE="MATCH/OPTIONAL Parsing"; ASPECT=Parser; STATUS=TESTED; TEST=tests/e2e_graph_match.zig; OWNER=parser; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-008; FEATURE="ORDER/LIMIT/OFFSET Parsing"; ASPECT=Parser; STATUS=TESTED; TEST=tests/e2e_protocol.zig; OWNER=parser; UPDATED=2025-09-20

const std = @import("std");
const tok = @import("token.zig");
const ast = @import("ast.zig");
const temporal = @import("../temporal.zig");
const Lexer = @import("lexer.zig").Lexer;

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
    // TS extensions (SERIES UDFs) allowed when true
    ts_extensions: bool = false,
    // Last error context message (static or source-backed slice).
    last_error: ?[]const u8 = null,
    // Path alias names collected from the last parsed graph pattern (MATCH or pattern comprehension).
    path_aliases: std.ArrayList([]const u8) = undefined,
    // Whether parseGraphPattern should record chain aliases into path_aliases.
    collect_chain_aliases: bool = false,
    // Track nesting depth in pattern comprehensions to handle ambiguous | tokens
    pattern_comp_depth: u32 = 0,

    fn advance(self: *Parser) void {
        self.cur = self.lx.next();
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
            // .VALUES - Removed to allow values() function calls
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
            .ORDINALITY,
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
            self.last_error = @tagName(kind);
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
        self.last_error = "identifier";
        return error.UnexpectedToken;
    }

    // Parser operations can fail due to syntax or allocation issues.
    // We’ll thread a tiny error wrapper with a message alongside generic errors when needed.
    const ParserError = error{ UnexpectedToken, OutOfMemory, Overflow, InvalidCharacter };

    fn unexpected(self: *Parser, what: []const u8) ParserError {
        // For now, we just return UnexpectedToken; callers like CLI can add context using 'what'.
        self.last_error = what;
        return error.UnexpectedToken;
    }

    pub fn parseProgram(self: *Parser) ParserError!ast.Program {
        // initialize alias set arraylist
        self.path_aliases = std.ArrayList([]const u8).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
        var list = std.ArrayList(ast.Statement).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
        var recursive_mode = false;
        // Minimal recognition of leading WITH RECURSIVE (no full CTE parsing yet)
        // CANARY: REQ=REQ-GQL-079; FEATURE="RecursiveExecution"; ASPECT=ParserRecognition; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_079_ParserRecognitionNegativeCycle; OWNER=engine; UPDATED=2025-09-26
        if (self.cur.kind == .WITH) {
            // Peek if next token is identifier RECURSIVE (case-insensitive)
            var tmp = self.lx.*;
            const maybe = tmp.next(); // token after WITH
            if (maybe.kind == .identifier and std.ascii.eqlIgnoreCase(maybe.lexeme, "RECURSIVE")) {
                // Consume WITH and the RECURSIVE identifier, but skip full CTE parsing for now (stub)
                self.advance(); // WITH
                self.advance(); // RECURSIVE
                recursive_mode = true;
                // For now we expect immediate query start (MATCH/RETURN etc.)
            }
        }
        while (self.cur.kind != .eof) {
            const st = try self.parseStatement();
            // If we recognized WITH RECURSIVE, propagate flag onto contained queries
            if (recursive_mode) switch (st) {
                .Query => |q| {
                    // set flag; need to patch the copy before appending
                    var q_mut = q;
                    q_mut.has_recursive_cte = true;
                    try list.append(self.arena.allocator(), .{ .Query = q_mut });
                    if (self.cur.kind == .semicolon) self.advance();
                    continue;
                },
                .Union, .Intersect, .Except => {
                    // Future: mark nested queries; leave unset for now (recognition limited to simple Query)
                },
                else => {},
            };
            try list.append(self.arena.allocator(), st);
            if (self.cur.kind == .semicolon) self.advance();
        }
        return .{ .statements = try list.toOwnedSlice(self.arena.allocator()) };
    }

    fn parseStatement(self: *Parser) ParserError!ast.Statement {
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
                        var return_items = std.ArrayList(ast.ReturnItem).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
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
                var items = std.ArrayList(ast.ReturnItem).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
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
                    var delete_items = std.ArrayList(ast.DeleteItem).initCapacity(self.arena.allocator(), 0) catch unreachable;

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
                        var return_items = std.ArrayList(ast.ReturnItem).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
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
                const first = try self.parseQuery();
                if (self.cur.kind == .UNION) {
                    var parts = std.ArrayList(ast.UnionQuery.Part).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
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
                        const q2 = try self.parseQuery();
                        try parts.append(self.arena.allocator(), .{ .all = all, .distinct = distinct, .query = q2 });
                    }
                    break :blk_with .{ .Union = .{ .first = first, .tails = try parts.toOwnedSlice(self.arena.allocator()) } };
                }
                break :blk_with self.handleQueryResult(first);
            },
            .RETURN => blk_r: {
                // Parenthesized set expression grouping: (RETURN ... UNION ...)
                if (self.cur.kind == .l_paren) {
                    self.advance();
                    const first = try self.parseQuery();
                    var parts = std.ArrayList(ast.UnionQuery.Part).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
                    if (self.cur.kind != .UNION) return error.UnexpectedToken;
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
                        const q2 = try self.parseQuery();
                        try parts.append(self.arena.allocator(), .{ .all = all, .distinct = distinct, .query = q2 });
                    }
                    _ = try self.expect(.r_paren);
                    // After grouped set expr, allow ORDER/LIMIT/OFFSET handled by outer caller; here we return a Union statement
                    break :blk_r .{ .Union = .{ .first = first, .tails = try parts.toOwnedSlice(self.arena.allocator()) } };
                }
                const first = try self.parseQuery();
                if (self.cur.kind == .UNION) {
                    var parts = std.ArrayList(ast.UnionQuery.Part).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
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
                        const q2 = try self.parseQuery();
                        try parts.append(self.arena.allocator(), .{ .all = all, .distinct = distinct, .query = q2 });
                    }
                    break :blk_r .{ .Union = .{ .first = first, .tails = try parts.toOwnedSlice(self.arena.allocator()) } };
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
            .START => blk2: {
                self.advance();
                if (self.cur.kind == .TRANSACTION) {
                    self.advance();
                    break :blk2 .StartTransaction;
                }
                return error.UnexpectedToken;
            },
            .BEGIN => {
                self.advance();
                // BEGIN can be standalone or followed by TRANSACTION
                if (self.cur.kind == .TRANSACTION) {
                    self.advance();
                }
                return .StartTransaction;
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
                // Parse procedure call expression (e.g., db.labels())
                const procedure = try self.parseOrExpr();

                // Optional YIELD clause
                var yield_items: ?[]ast.ReturnItem = null;
                if (self.cur.kind == .YIELD) {
                    self.advance();
                    var items = std.ArrayList(ast.ReturnItem).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
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
                    var return_items = std.ArrayList(ast.ReturnItem).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
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
                    var keys = std.ArrayList(ast.OrderBy.OrderKey).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
                    const expr1 = try self.parseOrExpr();
                    var desc1 = false;
                    var nulls1: ast.OrderBy.NullsPolicy = .default;
                    if (self.cur.kind == .DESC) {
                        desc1 = true;
                        self.advance();
                    } else if (self.cur.kind == .ASC) {
                        self.advance();
                    }
                    if (self.cur.kind == .NULLS) {
                        self.advance();
                        if (self.cur.kind == .FIRST) {
                            nulls1 = .first;
                            self.advance();
                        } else if (self.cur.kind == .LAST) {
                            nulls1 = .last;
                            self.advance();
                        }
                    }
                    try keys.append(self.arena.allocator(), .{ .expr = expr1, .desc = desc1, .nulls = nulls1 });
                    while (self.cur.kind == .comma) {
                        self.advance();
                        const exprk = try self.parseOrExpr();
                        var desk = false;
                        var nullsk: ast.OrderBy.NullsPolicy = .default;
                        if (self.cur.kind == .DESC) {
                            desk = true;
                            self.advance();
                        } else if (self.cur.kind == .ASC) {
                            self.advance();
                        }
                        if (self.cur.kind == .NULLS) {
                            self.advance();
                            if (self.cur.kind == .FIRST) {
                                nullsk = .first;
                                self.advance();
                            } else if (self.cur.kind == .LAST) {
                                nullsk = .last;
                                self.advance();
                            }
                        }
                        try keys.append(self.arena.allocator(), .{ .expr = exprk, .desc = desk, .nulls = nullsk });
                    }
                    order_by = .{ .keys = try keys.toOwnedSlice(self.arena.allocator()) };
                }

                // Optional LIMIT clause
                var limit: ?usize = null;
                if (self.cur.kind == .LIMIT) {
                    self.advance();
                    if (self.cur.kind != .integer_lit) return error.UnexpectedToken;
                    const lim_val = std.fmt.parseInt(usize, self.cur.lexeme, 10) catch return error.UnexpectedToken;
                    limit = lim_val;
                    self.advance();
                }

                // Optional OFFSET/SKIP clause
                var offset: ?usize = null;
                if (self.cur.kind == .OFFSET or self.cur.kind == .SKIP) {
                    self.advance();
                    if (self.cur.kind != .integer_lit) return error.UnexpectedToken;
                    const off_val = std.fmt.parseInt(usize, self.cur.lexeme, 10) catch return error.UnexpectedToken;
                    offset = off_val;
                    self.advance();
                }

                break :blk_call .{ .Call = .{
                    .procedure = procedure,
                    .yield_items = yield_items,
                    .return_clause = return_clause,
                    .order_by = order_by,
                    .limit = limit,
                    .offset = offset,
                } };
            },
            else => return error.UnexpectedToken,
        };
    }

    fn handleQueryResult(self: *Parser, first: ast.Query) ParserError!ast.Statement {
        if (self.cur.kind == .UNION or self.cur.kind == .INTERSECT or self.cur.kind == .EXCEPT) {
            var parts = std.ArrayList(ast.UnionQuery.Part).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
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
                const q = try self.parseQuery();
                try parts.append(self.arena.allocator(), .{ .operation = operation, .all = all, .distinct = distinct, .query = q });
            }
            return .{ .Union = .{ .first = first, .tails = try parts.toOwnedSlice(self.arena.allocator()) } };
        }
        return .{ .Query = first };
    }

    fn parseQuery(self: *Parser) ParserError!ast.Query {
        // Parse LET bindings first (LET $var = expr, ...)
        var let_bindings = std.ArrayList(ast.LetBinding).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
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

        // Check for WITH at the beginning (for queries like: WITH 5 AS x RETURN x)
        // Parse WITH clause first if present, before MATCH/CREATE
        var initial_with_clause: ?ast.WithClause = null;
        if (self.cur.kind == .WITH) {
            self.advance();
            var witems = std.ArrayList(ast.ReturnItem).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
            try self.parseProjectionItems(&witems);
            initial_with_clause = .{ .items = try witems.toOwnedSlice(self.arena.allocator()) };
            // Allow optional WHERE after WITH
            // Note: WHERE after WITH filters the WITH results, not graph patterns
        }

        // Check for CREATE at the beginning
        if (self.cur.kind == .CREATE) {
            have_create = true;
            self.advance();
            create_pattern = try self.parseGraphPattern();
        } else if (self.cur.kind == .OPTIONAL) {
            self.advance();
            optional_match = true;
            have_match = true;
        }
        if (self.cur.kind == .MATCH and !have_create) {
            have_match = true;
        }
        // Prepare defaults
        var where_expr: ?ast.Expr = null;
        var with_clause: ?ast.WithClause = null;
        var group_by: ?ast.GroupBy = null;
        var having_expr: ?ast.Expr = null;
        var path_variable: ?[]const u8 = null;
        const pat: ast.GraphPattern = if (have_match) blk_pat: {
            _ = try self.expect(.MATCH);
            // For the top-level MATCH pattern, collect aliases freshly.
            self.collect_chain_aliases = true;
            self.path_aliases.clearRetainingCapacity();

            // Path variable assignment is handled inside parseGraphPattern

            // Parse first MATCH pattern
            var all_chains = std.ArrayList(ast.Chain).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
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

            // Check for additional MATCH or OPTIONAL MATCH clauses and combine their chains
            while (self.cur.kind == .MATCH or self.cur.kind == .OPTIONAL) {
                // Handle OPTIONAL MATCH
                if (self.cur.kind == .OPTIONAL) {
                    self.advance();
                    if (self.cur.kind != .MATCH) {
                        return error.UnexpectedToken;
                    }
                    // Mark that we have an optional match (this affects the overall query)
                    optional_match = true;
                }
                self.advance(); // consume MATCH
                const additional_gp = try self.parseGraphPattern();
                for (additional_gp.chains) |chain| {
                    try all_chains.append(self.arena.allocator(), chain);
                }
            }

            const combined_gp = ast.GraphPattern{ .chains = try all_chains.toOwnedSlice(self.arena.allocator()) };

            // Keep aliases for ORDER BY checks that follow.
            self.collect_chain_aliases = false;
            // optional WHERE predicate
            if (self.cur.kind == .WHERE) {
                self.advance();
                where_expr = try self.parseOrExpr();
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

        // Optional WITH projection forwarding (works for both MATCH and CREATE)
        // CANARY: REQ=REQ-GQL-CHAIN; FEATURE="Query Chaining via WITH"; ASPECT=Parser; STATUS=IMPLEMENTED; TEST=graph_algorithms; OWNER=parser; UPDATED=2025-10-10
        var next_query_ptr: ?*ast.Query = null;
        if (self.cur.kind == .WITH) {
            self.advance();
            var witems = std.ArrayList(ast.ReturnItem).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
            try self.parseProjectionItems(&witems);
            with_clause = .{ .items = try witems.toOwnedSlice(self.arena.allocator()) };
            // Allow an additional WHERE after WITH to filter the projected bindings
            if (self.cur.kind == .WHERE) {
                self.advance();
                const cond2 = try self.parseOrExpr();
                if (where_expr) |cond1| {
                    where_expr = try self.makeBinary(.And, cond1, cond2);
                } else {
                    where_expr = cond2;
                }
            }

            // Check for query chaining: WITH ... MATCH/CREATE ...
            // If we see MATCH or CREATE after WITH, parse it as a chained query
            if (self.cur.kind == .MATCH or self.cur.kind == .CREATE) {
                // Parse the continuation as a new query
                const next_query = try self.parseQuery();
                // Allocate on arena and store pointer
                const next_ptr = try self.arena.allocator().create(ast.Query);
                next_ptr.* = next_query;
                next_query_ptr = next_ptr;

                // Current query acts as a WITH-only query (no explicit RETURN needed)
                // The WITH clause serves as an implicit RETURN for passing bindings forward
            }
        }
        // GROUP BY (optional)
        if (self.cur.kind == .GROUP) {
            self.advance();
            _ = try self.expect(.BY);
            var keys_list = std.ArrayList(ast.Expr).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
            // one or more expressions separated by commas
            while (true) {
                try keys_list.append(self.arena.allocator(), try self.parseOrExpr());
                if (self.cur.kind != .comma) break;
                self.advance();
            }
            group_by = .{ .keys = try keys_list.toOwnedSlice(self.arena.allocator()) };
            // Optional HAVING predicate directly after GROUP BY
            if (self.cur.kind == .HAVING) {
                self.advance();
                having_expr = try self.parseOrExpr();
            }
        }

        // Parse SET clauses if present (before RETURN)
        var set_clauses: []ast.SetClause = &.{};
        if (self.cur.kind == .SET) {
            self.advance();
            set_clauses = try self.parseSetClauses();
        }

        // Parse REMOVE clauses if present (before RETURN)
        var remove_clauses: []ast.RemoveClause = &.{};
        if (self.cur.kind == .REMOVE) {
            self.advance();
            remove_clauses = try self.parseRemoveClauses();
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
                var items = std.ArrayList(ast.ReturnItem).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
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
            var items = std.ArrayList(ast.ReturnItem).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
            try self.parseProjectionItems(&items);
            return_clause = .{ .items = try items.toOwnedSlice(self.arena.allocator()), .distinct = distinct };

            // Allow GROUP BY (and optional HAVING) after RETURN as well
            if (self.cur.kind == .GROUP) {
                self.advance();
                _ = try self.expect(.BY);
                var keys_list2 = std.ArrayList(ast.Expr).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
                while (true) {
                    try keys_list2.append(self.arena.allocator(), try self.parseOrExpr());
                    if (self.cur.kind != .comma) break;
                    self.advance();
                }
                group_by = .{ .keys = try keys_list2.toOwnedSlice(self.arena.allocator()) };
                if (self.cur.kind == .HAVING) {
                    self.advance();
                    having_expr = try self.parseOrExpr();
                }
            }
        } else if (set_clauses.len > 0 or remove_clauses.len > 0) {
            // SET/REMOVE without RETURN - create empty return clause
            return_clause = .{ .items = &.{}, .distinct = false };
        } else if (next_query_ptr != null and with_clause != null) {
            // Query chaining: WITH followed by MATCH/CREATE
            // Use WITH items as implicit RETURN to pass bindings forward
            return_clause = .{ .items = with_clause.?.items, .distinct = false };
        } else {
            // No SET/REMOVE, no chaining, and no RETURN - error
            _ = try self.expect(.RETURN);
            unreachable;
        }

        var ord: ?ast.OrderBy = null;
        if (self.cur.kind == .ORDER) {
            self.advance();
            _ = try self.expect(.BY);
            var keys = std.ArrayList(ast.OrderBy.OrderKey).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
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
            var desc1 = false;
            if (self.cur.kind == .ASC) {
                desc1 = false;
                self.advance();
            } else if (self.cur.kind == .DESC) {
                desc1 = true;
                self.advance();
            }
            var nulls1: ast.OrderBy.NullsPolicy = .default;
            if (self.cur.kind == .NULLS) {
                self.advance();
                if (self.cur.kind == .FIRST) {
                    nulls1 = .first;
                    self.advance();
                } else if (self.cur.kind == .LAST) {
                    nulls1 = .last;
                    self.advance();
                } else return self.unexpected("expected FIRST/LAST after NULLS");
            }
            try keys.append(self.arena.allocator(), .{ .expr = expr1, .desc = desc1, .nulls = nulls1 });
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
                var d = false;
                if (self.cur.kind == .ASC) {
                    d = false;
                    self.advance();
                } else if (self.cur.kind == .DESC) {
                    d = true;
                    self.advance();
                }
                var np: ast.OrderBy.NullsPolicy = .default;
                if (self.cur.kind == .NULLS) {
                    self.advance();
                    if (self.cur.kind == .FIRST) {
                        np = .first;
                        self.advance();
                    } else if (self.cur.kind == .LAST) {
                        np = .last;
                        self.advance();
                    } else return self.unexpected("expected FIRST/LAST after NULLS");
                }
                try keys.append(self.arena.allocator(), .{ .expr = exprk, .desc = d, .nulls = np });
            }
            ord = .{ .keys = try keys.toOwnedSlice(self.arena.allocator()) };
        }

        var limit: ?usize = null;
        var offset: ?usize = null;

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
            const n = try self.expect(.integer_lit);
            limit = try std.fmt.parseInt(usize, n.lexeme, 10);
        }
        // Check for OFFSET/SKIP
        if (self.cur.kind == .OFFSET or self.cur.kind == .SKIP) {
            self.advance();
            const n = try self.expect(.integer_lit);
            offset = try std.fmt.parseInt(usize, n.lexeme, 10);
        }
        // Check for LIMIT again (in case it comes after OFFSET)
        if (limit == null and self.cur.kind == .LIMIT) {
            self.advance();
            const n = try self.expect(.integer_lit);
            limit = try std.fmt.parseInt(usize, n.lexeme, 10);
        }

        return .{
            .let_bindings = try let_bindings.toOwnedSlice(self.arena.allocator()),
            .optional_match = optional_match,
            .match = pat,
            .create_pattern = create_pattern,
            .where_clause = where_expr,
            .filter_clause = filter_expr,
            .with_clause = if (with_clause) |wc| wc else initial_with_clause,
            .set_clauses = set_clauses,
            .remove_clauses = remove_clauses,
            .group_by = group_by,
            .having = having_expr,
            .ret = return_clause,
            .order_by = ord,
            .limit = limit,
            .offset = offset,
            .path_variable = path_variable,
            .call_clause = call_clause,
            .next_query = next_query_ptr, // Query chaining support
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
        var chains = std.ArrayList(ast.Chain).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
        while (true) {
            // parse a chain with one-or-more hops
            var hops = std.ArrayList(ast.Hop).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
            // Optional path alias: ident '=' before a node pattern or shortestPath function
            var chain_name: ?[]const u8 = null;
            if ((self.cur.kind == .identifier or self.cur.kind == .PATH) and self.peekKind() == .eq) {
                chain_name = self.cur.lexeme;
                self.advance(); // ident or PATH
                _ = try self.expect(.eq);

                // Check if this is a shortestPath or allShortestPaths function call
                if (self.cur.kind == .identifier) {
                    const func_name = self.cur.lexeme;
                    if (std.ascii.eqlIgnoreCase(func_name, "shortestPath") or std.ascii.eqlIgnoreCase(func_name, "allShortestPaths")) {
                        // This is a path function - create a special chain with shortestPath marker
                        self.advance(); // consume function name
                        _ = try self.expect(.l_paren);
                        const inner_pattern = try self.parseGraphPattern();
                        _ = try self.expect(.r_paren);

                        // Store the shortestPath pattern as a special chain
                        // The execution engine will handle this specially
                        const is_all = std.ascii.eqlIgnoreCase(func_name, "allShortestPaths");
                        _ = is_all; // Will use this in execution

                        // For now, just return the inner pattern with the path name
                        for (inner_pattern.chains) |chain| {
                            var modified_chain = chain;
                            modified_chain.name = chain_name;
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
                const rel = try self.parseRelPattern(dir);
                // trailing connector to right node: -, ->, or <-
                if (self.cur.kind == .minus or self.cur.kind == .arrow_r or self.cur.kind == .arrow_l) {
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
            try chains.append(self.arena.allocator(), .{ .name = chain_name, .hops = owned_hops, .head = head });
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
        var labels = std.ArrayList([]const u8).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
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
        var types = std.ArrayList([]const u8).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
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
                if (min_len == null) min_len = 0;
            }
            if (min_len == null and max_len == null) {
                // plain * => 0..∞
                min_len = 0;
                max_len = null;
            }
            if (min_len != null and max_len != null and min_len.? > max_len.?) {
                return self.unexpected("relationship length min>max");
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
        var list = std.ArrayList(ast.Property).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
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
        var left = try self.parseAndExpr();
        while (self.cur.kind == .OR) {
            self.advance();
            const right = try self.parseAndExpr();
            const node = try self.makeBinary(.Or, left, right);
            left = node;
        }
        return left;
    }

    fn parseAndExpr(self: *Parser) ParserError!ast.Expr {
        var left = try self.parseCmpExpr();
        while (self.cur.kind == .AND) {
            self.advance();
            const right = try self.parseCmpExpr();
            const node = try self.makeBinary(.And, left, right);
            left = node;
        }
        return left;
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
                    _ = try self.expect(.l_bracket);
                    var elems = std.ArrayList(*ast.Expr).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
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
                }
                if (self.cur.kind == .NOT) {
                    // NOT IN
                    self.advance();
                    _ = try self.expect(.IN);
                    _ = try self.expect(.l_bracket);
                    var elems = std.ArrayList(*ast.Expr).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
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
        const right = try self.parseAddExpr();
        return self.makeBinary(op_kind, left, right);
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
        var left = try self.parseUnaryExpr();
        while (self.cur.kind == .star or self.cur.kind == .slash or self.cur.kind == .percent) {
            const op = if (self.cur.kind == .star)
                ast.BinOp.Mul
            else if (self.cur.kind == .slash)
                ast.BinOp.Div
            else
                ast.BinOp.Mod;
            self.advance();
            const right = try self.parseUnaryExpr();
            left = try self.makeBinary(op, left, right);
        }
        return left;
    }

    fn parseUnaryExpr(self: *Parser) ParserError!ast.Expr {
        if (self.cur.kind == .NOT) {
            self.advance();
            const e = try self.parseUnaryExpr();
            const a = self.arena.allocator();
            const ep = try a.create(ast.Expr);
            ep.* = e;
            return .{ .Unary = .{ .op = .Not, .expr = ep } };
        }
        if (self.cur.kind == .EXISTS and self.peekToken() == .l_brace) {
            // This is EXISTS { pattern } - EXISTS predicate
            self.advance(); // consume EXISTS
            _ = try self.expect(.l_brace);
            const pattern = try self.parseGraphPattern();
            _ = try self.expect(.r_brace);
            const a = self.arena.allocator();
            const pattern_ptr = try a.create(ast.GraphPattern);
            pattern_ptr.* = pattern;
            return .{ .Exists = .{ .pattern = pattern_ptr } };
        }
        if (self.cur.kind == .minus) {
            self.advance();
            const e = try self.parseUnaryExpr();
            const a = self.arena.allocator();
            const ep = try a.create(ast.Expr);
            ep.* = e;
            return .{ .Unary = .{ .op = .Neg, .expr = ep } };
        }
        if (self.cur.kind == .plus) {
            self.advance();
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
        while (true) {
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
            if (self.cur.kind == .l_paren) {
                // Check for shortestPath/allShortestPaths or size() with pattern
                if (base == .Ident) {
                    const name = base.Ident.orig;
                    if (std.ascii.eqlIgnoreCase(name, "shortestPath") or std.ascii.eqlIgnoreCase(name, "allShortestPaths")) {
                        const is_all = std.ascii.eqlIgnoreCase(name, "allShortestPaths");
                        self.advance(); // consume '('
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
                            base = .{ .PatternCount = pat_ptr };
                            continue;
                        }
                        // Otherwise fall through to regular function call handling
                        // This handles size([ pattern | expr ]) and size(expr)
                    }
                }
                // function call: base(args)
                self.advance();
                var args = std.ArrayList(*ast.Expr).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
                var saw_distinct = false;
                if (self.cur.kind != .r_paren) {
                    // Special handling: COUNT(DISTINCT expr)
                    if (base == .Ident and std.ascii.eqlIgnoreCase(base.Ident.orig, "count") and self.cur.kind == .DISTINCT) {
                        saw_distinct = true;
                        self.advance();
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
                            const arg = try self.parseOrExpr();
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
                    var flat = std.ArrayList(ast.Expr).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
                    for (args_slice) |p| try flat.append(self.arena.allocator(), p.*);
                    if (!validateBuiltinCall(name.orig, try flat.toOwnedSlice(self.arena.allocator()), self.ts_extensions) and !std.ascii.eqlIgnoreCase(name.orig, "countDistinct")) return self.unexpected("invalid builtin function call");
                }
                base = .{ .Call = .{ .callee = cp, .args = args_slice } };
                continue;
            }
            if (self.cur.kind == .l_bracket) {
                // array index: base[index]
                self.advance();
                const index_expr = try self.parseOrExpr();
                _ = try self.expect(.r_bracket);
                const a = self.arena.allocator();
                const bp = try a.create(ast.Expr);
                bp.* = base;
                const ip = try a.create(ast.Expr);
                ip.* = index_expr;
                base = .{ .Index = .{ .target = bp, .index = ip } };
                continue;
            }
            if (self.cur.kind == .l_brace) {
                // Map projection: n {.name, .age}
                self.advance();
                var fields = std.ArrayList([]const u8).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");

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
            break;
        }
        return base;
    }

    fn parsePrimaryExpr(self: *Parser) ParserError!ast.Expr {
        return switch (self.cur.kind) {
            .dollar => blk_param: {
                // Parameter: $identifier (allow keywords as parameter names)
                self.advance();
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
                var whens = std.ArrayList(ast.CaseWhen).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
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
                break :blk .{ .String = tkn.lexeme };
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
                    // Convert to decimal with reasonable precision (6 decimal places)
                    const coeff = @as(i128, @intFromFloat(value * 1000000));
                    break :blk_f .{ .Decimal = .{ .coeff = coeff, .scale = 6 } };
                } else {
                    // Standard decimal notation
                    var dot_idx: usize = 0;
                    while (dot_idx < lex.len and lex[dot_idx] != '.') : (dot_idx += 1) {}
                    if (dot_idx >= lex.len) return error.UnexpectedToken;
                    const int_part = lex[0..dot_idx];
                    const frac_part = lex[dot_idx + 1 .. lex.len];
                    const scale: u8 = @intCast(frac_part.len);
                    // coeff = parse int_part ++ frac_part as i128
                    var buf = std.ArrayList(u8).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
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
                // Heuristic: next meaningful token starts a node/connector or alias (identifier '=')
                self.advance();
                var starts_pattern = false;
                if (self.cur.kind == .l_paren or self.cur.kind == .arrow_l or self.cur.kind == .minus or ((self.cur.kind == .identifier or self.cur.kind == .PATH) and self.peekKind() == .eq)) {
                    starts_pattern = true;
                }
                if (!starts_pattern) {
                    // Try to parse as array literal: [expr, expr, ...]
                    var elements = std.ArrayList(*ast.Expr).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");

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
                _ = try self.expect(.bar);
                const map_expr_v = try self.parseOrExpr();
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
        return switch (e) {
            .Ident => true,
            .Member => |m| self.isSimpleOrderPtr(m.target.*),
            else => false,
        };
    }

    pub fn containsCall(self: *Parser, e: ast.Expr) bool {
        return switch (e) {
            .Call => true,
            .Member => |m| self.containsCall(m.target.*),
            .Unary => |u| self.containsCall(u.expr.*),
            .Binary => |b| self.containsCall(b.left.*) or self.containsCall(b.right.*),
            .List => |items| blk: {
                for (items) |it| if (self.containsCall(it.*)) break :blk true;
                break :blk false;
            },
            .In => |x| blk2: {
                if (self.containsCall(x.value.*)) break :blk2 true;
                for (x.set) |it| if (self.containsCall(it.*)) break :blk2 true;
                break :blk2 false;
            },
            .IsNull => |z| self.containsCall(z.target.*),
            else => false,
        };
    }

    // Static variant for post-parse validation (no Parser instance state needed)
    pub fn containsCallStatic(e: ast.Expr) bool {
        return switch (e) {
            .Call => true,
            .Member => |m| containsCallStatic(m.target.*),
            .Unary => |u| containsCallStatic(u.expr.*),
            .Binary => |b| containsCallStatic(b.left.*) or containsCallStatic(b.right.*),
            .List => |items| blk: {
                for (items) |it| if (containsCallStatic(it.*)) break :blk true;
                break :blk false;
            },
            .In => |x| blk2: {
                if (containsCallStatic(x.value.*)) break :blk2 true;
                for (x.set) |it| if (containsCallStatic(it.*)) break :blk2 true;
                break :blk2 false;
            },
            .IsNull => |z| containsCallStatic(z.target.*),
            else => false,
        };
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
            else => false,
        };
    }

    fn argIsStringLike(e: ast.Expr) bool {
        return switch (e) {
            .String => true,
            .Ident => true,
            .Member => true,
            .Call => true, // allow nested function calls
            else => false,
        };
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
        if (std.ascii.eqlIgnoreCase(name, "abs")) {
            return n == 1 and argIsNumericLike(args[0]);
        }
        // Vector types - accept array literal or string
        if (std.ascii.eqlIgnoreCase(name, "VectorF32")) {
            return n == 1 and (args[0] == .List or argIsStringLike(args[0]));
        }
        if (std.ascii.eqlIgnoreCase(name, "VectorI32")) {
            return n == 1 and (args[0] == .List or argIsStringLike(args[0]));
        }
        // Geographic types - accept two numbers or one string
        if (std.ascii.eqlIgnoreCase(name, "LatLon")) {
            return (n == 2 and argIsNumericLike(args[0]) and argIsNumericLike(args[1])) or (n == 1 and argIsStringLike(args[0]));
        }
        if (std.ascii.eqlIgnoreCase(name, "LatLonAlt")) {
            return (n == 3 and argIsNumericLike(args[0]) and argIsNumericLike(args[1]) and argIsNumericLike(args[2])) or (n == 1 and argIsStringLike(args[0]));
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

        // Otherwise, parse the pattern to create
        const pattern = try self.parseGraphPattern();

        // CANARY: REQ=REQ-GQL-083; FEATURE="CreateWithClause"; ASPECT=ParserSupport; STATUS=TESTED; OWNER=parser; UPDATED=2025-10-09
        // Check if this is followed by WITH, SET, or REMOVE - if so, this should be a Query, not a standalone CREATE
        if (self.cur.kind == .WITH or self.cur.kind == .SET or self.cur.kind == .REMOVE) {
            // This is CREATE ... WITH/SET/REMOVE ... RETURN
            // We need to construct a Query with create_pattern set

            // Parse WITH clause if present
            var with_clause: ?ast.WithClause = null;
            var next_query_ptr: ?*ast.Query = null;
            if (self.cur.kind == .WITH) {
                self.advance();
                var witems = std.ArrayList(ast.ReturnItem).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
                try self.parseProjectionItems(&witems);
                with_clause = .{ .items = try witems.toOwnedSlice(self.arena.allocator()) };

                // CANARY: REQ=REQ-GQL-CHAIN; FEATURE="Query Chaining via WITH"; ASPECT=ParserCREATE;
                //         STATUS=IMPLEMENTED; TEST=graph_algorithms; OWNER=parser; UPDATED=2025-10-10
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

            // Parse RETURN clause (required for Query)
            var return_clause: ast.ReturnClause = undefined;
            if (self.cur.kind == .RETURN) {
                self.advance();
                const distinct = if (self.cur.kind == .DISTINCT) blk: {
                    self.advance();
                    break :blk true;
                } else false;
                var items = std.ArrayList(ast.ReturnItem).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
                try self.parseProjectionItems(&items);
                return_clause = .{ .items = try items.toOwnedSlice(self.arena.allocator()), .distinct = distinct };
            } else if (set_clauses.len > 0 or remove_clauses.len > 0) {
                // SET/REMOVE without RETURN - create empty return clause
                return_clause = .{ .items = &.{}, .distinct = false };
            } else {
                // No SET/REMOVE and no RETURN after WITH - error
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
            var return_items = std.ArrayList(ast.ReturnItem).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
            try self.parseProjectionItems(&return_items);
            return_clause = .{
                .items = try return_items.toOwnedSlice(self.arena.allocator()),
                .distinct = distinct,
            };
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
        var items = std.ArrayList(ast.DeleteItem).initCapacity(self.arena.allocator(), 0) catch unreachable;

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
            var return_items = std.ArrayList(ast.ReturnItem).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
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

        // Parse the pattern to merge
        const pattern = try self.parseGraphPattern();

        // Parse ON CREATE/MATCH clauses
        var on_create = std.ArrayList(ast.SetClause).initCapacity(self.arena.allocator(), 0) catch unreachable;
        var on_match = std.ArrayList(ast.SetClause).initCapacity(self.arena.allocator(), 0) catch unreachable;

        while (self.cur.kind == .ON) {
            self.advance();

            if (self.cur.kind == .CREATE) {
                self.advance();
                _ = try self.expect(.SET);
                const clauses = try self.parseSetClauses();
                try on_create.appendSlice(self.arena.allocator(), clauses);
            } else if (self.cur.kind == .MATCH) {
                self.advance();
                _ = try self.expect(.SET);
                const clauses = try self.parseSetClauses();
                try on_match.appendSlice(self.arena.allocator(), clauses);
            } else {
                return error.UnexpectedToken;
            }
        }

        // Optional RETURN clause
        var return_clause: ?ast.ReturnClause = null;
        if (self.cur.kind == .RETURN) {
            self.advance();
            const distinct = if (self.cur.kind == .DISTINCT) blk: {
                self.advance();
                break :blk true;
            } else false;
            var return_items = std.ArrayList(ast.ReturnItem).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
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
            .return_clause = return_clause,
        } };
    }

    fn parseSetClauses(self: *Parser) ParserError![]ast.SetClause {
        var clauses = std.ArrayList(ast.SetClause).initCapacity(self.arena.allocator(), 0) catch unreachable;

        // Parse first clause
        const first = try self.parseSetClause();
        try clauses.append(self.arena.allocator(), first);

        // Parse additional clauses
        while (self.cur.kind == .comma) {
            self.advance();
            const clause = try self.parseSetClause();
            try clauses.append(self.arena.allocator(), clause);
        }

        return clauses.toOwnedSlice(self.arena.allocator());
    }

    fn parseSetClause(self: *Parser) ParserError!ast.SetClause {
        // Parse identifier (e.g., n)
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const object = self.cur.lexeme;
        self.advance();

        // Check if it's a label setting (n:Label) or property setting (n.property = value)
        if (self.cur.kind == .colon) {
            // Parse label(s): SET n:Label or SET n:Label1:Label2
            var labels = std.ArrayList([]const u8).initCapacity(self.arena.allocator(), 0) catch unreachable;

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
        var clauses = std.ArrayList(ast.RemoveClause).initCapacity(self.arena.allocator(), 0) catch unreachable;

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
            var labels = std.ArrayList([]const u8).initCapacity(self.arena.allocator(), 0) catch unreachable;

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

        // Index name (required in GQL)
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const name = self.cur.lexeme;
        self.advance();

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
                self.advance();
                if (self.cur.kind != .minus) return error.UnexpectedToken;
                self.advance();
                if (self.cur.kind != .l_bracket) return error.UnexpectedToken;
                self.advance();

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

                // Close bracket and remaining pattern
                if (self.cur.kind != .r_bracket) return error.UnexpectedToken;
                self.advance();
                if (self.cur.kind != .minus) return error.UnexpectedToken;
                self.advance();
                if (self.cur.kind != .l_paren) return error.UnexpectedToken;
                self.advance();
                if (self.cur.kind != .r_paren) return error.UnexpectedToken;
                self.advance();
                if (self.cur.kind != .r_paren) return error.UnexpectedToken;
                self.advance();
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
                } else if (std.ascii.eqlIgnoreCase(type_str, "network_cidr") or std.ascii.eqlIgnoreCase(type_str, "PatriciaTrie")) {
                    index_type = .network_cidr;
                } else if (std.ascii.eqlIgnoreCase(type_str, "signature_crypto")) {
                    index_type = .signature_crypto;
                } else if (std.ascii.eqlIgnoreCase(type_str, "IntervalTree")) {
                    // IntervalTree - temporal/interval index (map to btree for now)
                    index_type = .btree;
                } else if (std.ascii.eqlIgnoreCase(type_str, "JsonbInverted")) {
                    // JsonbInverted - JSONB GIN-style index (map to btree for now)
                    index_type = .btree;
                } else if (std.ascii.eqlIgnoreCase(type_str, "DomainTrie")) {
                    // DomainTrie - domain name trie (map to btree for now)
                    index_type = .btree;
                }
                self.advance();
            }
        }

        // Properties in parentheses
        if (self.cur.kind != .l_paren) return error.UnexpectedToken;
        self.advance();

        var properties = std.ArrayList([]const u8).initCapacity(self.arena.allocator(), 1) catch unreachable;

        // Parse properties - handle both (property) and (n.property) syntax
        while (true) {
            if (self.cur.kind != .identifier) return error.UnexpectedToken;

            // Check for qualified property (n.property)
            if (pattern_variable != null and self.cur.kind == .identifier) {
                const first_part = self.cur.lexeme;
                self.advance();

                // Check for dot
                if (self.cur.kind == .dot) {
                    self.advance();
                    if (self.cur.kind != .identifier) return error.UnexpectedToken;
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
                } else if (std.ascii.eqlIgnoreCase(type_str, "network_cidr") or std.ascii.eqlIgnoreCase(type_str, "PatriciaTrie")) {
                    index_type = .network_cidr;
                } else if (std.ascii.eqlIgnoreCase(type_str, "signature_crypto")) {
                    index_type = .signature_crypto;
                } else if (std.ascii.eqlIgnoreCase(type_str, "IntervalTree")) {
                    index_type = .btree;
                } else if (std.ascii.eqlIgnoreCase(type_str, "JsonbInverted")) {
                    index_type = .btree;
                } else if (std.ascii.eqlIgnoreCase(type_str, "DomainTrie")) {
                    index_type = .btree;
                }
                self.advance();
            }
        }

        // Optional WITH clause for index parameters (parse but ignore for now)
        if (self.cur.kind == .WITH) {
            self.advance();
            if (self.cur.kind == .l_paren) {
                self.advance();
                // Skip parameters until closing paren
                var paren_depth: u32 = 1;
                while (paren_depth > 0 and self.cur.kind != .eof) {
                    if (self.cur.kind == .l_paren) {
                        paren_depth += 1;
                    } else if (self.cur.kind == .r_paren) {
                        paren_depth -= 1;
                    }
                    if (paren_depth > 0) self.advance();
                }
                if (self.cur.kind == .r_paren) {
                    self.advance();
                }
            }
        }

        // Optional OPTIONS clause (alternative to USING/WITH)
        if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "OPTIONS")) {
            self.advance();
            if (self.cur.kind == .l_brace) {
                self.advance();
                // Skip options until closing brace
                var brace_depth: u32 = 1;
                while (brace_depth > 0 and self.cur.kind != .eof) {
                    if (self.cur.kind == .l_brace) {
                        brace_depth += 1;
                    } else if (self.cur.kind == .r_brace) {
                        brace_depth -= 1;
                    }
                    if (brace_depth > 0) self.advance();
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
        var properties = std.ArrayList([]const u8).initCapacity(self.arena.allocator(), 1) catch unreachable;
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
                    if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "KEY")) {
                        self.advance();
                        return .node_key;
                    }
                }
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
                    if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "KEY")) {
                        self.advance();
                        return .node_key;
                    }
                }
            }
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
            } else {
                return error.UnexpectedToken;
            }
        } else {
            return error.UnexpectedToken;
        };

        return .{ .Show = .{ .show_type = show_type } };
    }

    fn parseValuesStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.VALUES);

        // Parse rows: (expr1), (expr2), ...
        var rows_list = std.ArrayList([]ast.Expr).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");

        while (true) {
            // Expect opening paren for row
            _ = try self.expect(.l_paren);

            // Parse expressions in this row
            var row_exprs = std.ArrayList(ast.Expr).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");

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

        var column_names = std.ArrayList([]const u8).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");

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
            stmt_ptr.* = try self.parseStatement();
            next_stmt = stmt_ptr;
        }

        return .{ .Values = .{
            .rows = try rows_list.toOwnedSlice(self.arena.allocator()),
            .column_names = try column_names.toOwnedSlice(self.arena.allocator()),
            .next_statement = next_stmt,
        } };
    }

    fn parseForStatement(self: *Parser) ParserError!ast.Statement {
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

        // Expect RETURN clause
        _ = try self.expect(.RETURN);

        // Parse RETURN clause
        const distinct = if (self.cur.kind == .DISTINCT) blk: {
            self.advance();
            break :blk true;
        } else false;

        var return_items = std.ArrayList(ast.ReturnItem).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
        try self.parseProjectionItems(&return_items);

        const return_clause = ast.ReturnClause{
            .items = try return_items.toOwnedSlice(self.arena.allocator()),
            .distinct = distinct,
        };

        // Optional ORDER BY
        var order_by: ?ast.OrderBy = null;
        if (self.cur.kind == .ORDER) {
            self.advance();
            _ = try self.expect(.BY);
            var keys = std.ArrayList(ast.OrderBy.OrderKey).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");

            // Parse first key
            const expr1 = try self.parseOrExpr();
            var desc1 = false;
            if (self.cur.kind == .ASC) {
                desc1 = false;
                self.advance();
            } else if (self.cur.kind == .DESC) {
                desc1 = true;
                self.advance();
            }
            var nulls1: ast.OrderBy.NullsPolicy = .default;
            if (self.cur.kind == .NULLS) {
                self.advance();
                if (self.cur.kind == .FIRST) {
                    nulls1 = .first;
                    self.advance();
                } else if (self.cur.kind == .LAST) {
                    nulls1 = .last;
                    self.advance();
                } else return self.unexpected("expected FIRST/LAST after NULLS");
            }
            try keys.append(self.arena.allocator(), .{ .expr = expr1, .desc = desc1, .nulls = nulls1 });

            // Parse additional keys
            while (self.cur.kind == .comma) {
                self.advance();
                const exprk = try self.parseOrExpr();
                var d = false;
                if (self.cur.kind == .ASC) {
                    d = false;
                    self.advance();
                } else if (self.cur.kind == .DESC) {
                    d = true;
                    self.advance();
                }
                var np: ast.OrderBy.NullsPolicy = .default;
                if (self.cur.kind == .NULLS) {
                    self.advance();
                    if (self.cur.kind == .FIRST) {
                        np = .first;
                        self.advance();
                    } else if (self.cur.kind == .LAST) {
                        np = .last;
                        self.advance();
                    } else return self.unexpected("expected FIRST/LAST after NULLS");
                }
                try keys.append(self.arena.allocator(), .{ .expr = exprk, .desc = d, .nulls = np });
            }
            order_by = .{ .keys = try keys.toOwnedSlice(self.arena.allocator()) };
        }

        // Optional LIMIT
        var limit: ?usize = null;
        if (self.cur.kind == .LIMIT) {
            self.advance();
            const lim_tok = try self.expect(.integer_lit);
            limit = std.fmt.parseInt(usize, lim_tok.lexeme, 10) catch return error.Overflow;
        }

        // Optional OFFSET
        var offset: ?usize = null;
        if (self.cur.kind == .OFFSET or self.cur.kind == .SKIP) {
            self.advance();
            const off_tok = try self.expect(.integer_lit);
            offset = std.fmt.parseInt(usize, off_tok.lexeme, 10) catch return error.Overflow;
        }

        return .{ .For = .{
            .variable = variable,
            .collection = collection,
            .ordinality_var = ordinality_var,
            .offset_var = offset_var,
            .return_clause = return_clause,
            .order_by = order_by,
            .limit = limit,
            .offset = offset,
        } };
    }

    fn parseExplainStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.EXPLAIN);

        // Parse the query to explain
        const query_stmt_ptr = try self.arena.allocator().create(ast.Statement);
        query_stmt_ptr.* = try self.parseStatement();

        return .{ .Explain = .{ .query = query_stmt_ptr } };
    }

    fn parseProfileStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.PROFILE);

        // Parse the query to profile
        const query_stmt_ptr = try self.arena.allocator().create(ast.Statement);
        query_stmt_ptr.* = try self.parseStatement();

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

        // Future: handle DROP CONSTRAINT, DROP DATABASE, etc.
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
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const name = self.cur.lexeme;
        self.advance();

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
        var type_definition: []const u8 = "{ }"; // Default empty type definition

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
                    // For now, we'll just use "{ }" as placeholder and advance past the braces
                    // TODO: Implement proper type definition parsing
                    type_definition = "{ }";
                    self.advance(); // Skip opening brace

                    // Skip until matching closing brace
                    var brace_count: i32 = 1;
                    while (brace_count > 0 and self.cur.kind != .eof) {
                        if (self.cur.kind == .l_brace) {
                            brace_count += 1;
                        } else if (self.cur.kind == .r_brace) {
                            brace_count -= 1;
                        }
                        self.advance();
                    }

                    if (brace_count != 0) {
                        return error.UnexpectedToken;
                    }
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

        return .{ .CreateGraphType = .{
            .name = name,
            .if_not_exists = if_not_exists,
            .or_replace = or_replace,
            .property_graph = property_graph,
            .type_definition = type_definition,
            .like_source = like_source,
            .copy_source = copy_source,
        } };
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
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const name = self.cur.lexeme;
        self.advance();

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
                // Expect timestamp
                if (self.cur.kind == .string_lit) {
                    timestamp = self.cur.lexeme;
                    self.advance();
                }
            } else if (self.cur.kind == .identifier) {
                const option = self.cur.lexeme;
                if (std.ascii.eqlIgnoreCase(option, "VERIFY")) {
                    verify_only = true;
                    self.advance();
                    if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "ONLY")) {
                        self.advance();
                    }
                }
            }
        }

        return .{ .Restore = .{
            .path = path,
            .timestamp = timestamp,
            .verify_only = verify_only,
        } };
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

            // If next token is a parameter ($...), parse as GRAPH parameter clause
            if (self.cur.kind == .dollar) {
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
                    } else if (self.cur.kind == .identifier or self.cur.kind == .string_lit or self.cur.kind == .integer_lit) {
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
        } else if (self.cur.kind == .time_lit or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "TIME")))
        {
            // Handle TIME ZONE in SESSION SET context
            // Note: "TIME" without following string literal is lexed as .identifier
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
                const param_spec = if (self.cur.kind == .identifier or self.cur.kind == .string_lit) blk: {
                    const spec = self.cur.lexeme;
                    self.advance();
                    break :blk spec;
                } else {
                    return error.UnexpectedToken;
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
                if (self.cur.kind == .string_lit or self.cur.kind == .identifier or self.cur.kind == .integer_lit) {
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
                } else if (self.cur.kind == .string_lit or self.cur.kind == .identifier or self.cur.kind == .integer_lit) {
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

        // Parse parameter specification (identifier after the $)
        const specification = if (self.cur.kind == .identifier or self.cur.kind == .string_lit) blk: {
            const spec = self.cur.lexeme;
            self.advance();
            break :blk spec;
        } else {
            return error.UnexpectedToken;
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
