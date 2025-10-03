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

    fn advance(self: *Parser) void {
        self.cur = self.lx.next();
    }

    fn isKeyword(self: *Parser, kind: tok.TokenKind) bool {
        _ = self;
        // Check if the token kind is a keyword (not a delimiter, literal, or identifier)
        return switch (kind) {
            .MATCH, .OPTIONAL, .WHERE, .RETURN, .WITH, .CASE, .WHEN, .THEN, .ELSE, .END,
            .AND, .OR, .NOT, .IN, .IS, .STARTS, .ENDS, .CONTAINS, .CALL, .YIELD,
            .TRUE, .FALSE, .NULL, .AS, .DISTINCT, .UNION, .INTERSECT, .EXCEPT, .ALL,
            .SESSION, .SET, .RESET, .CLOSE, .INSERT, .VALUE, .VALUES, .SCAN, .START,
            .TRANSACTION, .COMMIT, .ROLLBACK, .CREATE, .DELETE, .MERGE, .GRAPH,
            .PROPERTY, .DROP, .ORDER, .BY, .GROUP, .ASC, .DESC, .LIMIT, .OFFSET,
            .SKIP, .HAVING, .NULLS, .FIRST, .LAST, .ON, .UNKNOWN, .FILTER, .LET,
            .SELECT, .FROM, .EXISTS, .DETACH, .REMOVE, .FOR, .FOREACH, .UNWIND,
            .USE, .USING, .INDEX, .JOIN, .IF, .TO, .KEY, .KEYS, .LABELS, .LOAD,
            .CSV, .PERIODIC, .PROPERTIES, .RELATIONSHIPS, .START_NODE, .END_NODE,
            .TYPE, .TYPES,
            // Critical missing ISO GQL keywords (avoiding duplicates)
            .ACYCLIC, .AGGREGATE, .ANY, .AVG, .CATALOG, .CAST, .CONSTRAINT, .COUNT,
            .CURRENT, .DIFFERENT, .DURATION, .EDGES, .ELEMENT, .FINISH, .HOME,
            .LABELED, .LIKE, .LIST, .MAX, .MIN, .NEXT, .NODE, .OF, .OTHERWISE,
            .PATH, .PATHS, .RECORD, .REPEATABLE, .REPLACE, .SCHEMA, .SHORTEST,
            .SIMPLE, .SUM, .TABLE, .TRAIL, .WALK, .XOR, .ZONED => true,
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
            .CREATE => self.parseCreateStatement(),
            .DELETE => self.parseDeleteStatement(),
            .DETACH => self.parseDeleteStatement(),
            .MERGE => self.parseMergeStatement(),
            .DROP => self.parseDropStatement(),
            .SET => self.parseSetSessionStatement(),
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
                // Syntax: INSERT VALUE <expr>
                if (self.cur.kind != .VALUE) return error.UnexpectedToken;
                self.advance();
                const expr = try self.parseOrExpr();
                break :blk_ins .{ .InsertValue = .{ .expr = expr } };
            },
            .SCAN => blk_scan: {
                self.advance();
                // Syntax: SCAN VALUES; simple keyword VALUES optional
                if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "VALUES")) {
                    self.advance();
                } else if (self.cur.kind == .VALUE or self.cur.kind == .VALUES) {
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
                        const al = try self.expect(.identifier);
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
                    }};
                }
                
                // Otherwise, parse as regular query
                const first = try self.parseQuery();
                break :blk_match self.handleQueryResult(first);
            },
            .OPTIONAL => blk_query: {
                const first = try self.parseQuery();
                break :blk_query self.handleQueryResult(first);
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
                    self.advance();
                    // Parse SESSION SET PROPERTY GRAPH <name>
                    var property: []const u8 = "";
                    var value: []const u8 = "";

                    // Check for PROPERTY keyword
                    if (self.cur.kind == .PROPERTY) {
                        self.advance();
                        // Expect GRAPH
                        if (self.cur.kind == .GRAPH) {
                            property = "GRAPH";
                            self.advance();
                            // Expect graph name (identifier or quoted identifier or string)
                            if (self.cur.kind == .identifier) {
                                value = self.cur.lexeme;
                                self.advance();
                            } else if (self.cur.kind == .string_lit) {
                                value = self.cur.lexeme;
                                self.advance();
                            } else {
                                return error.UnexpectedToken;
                            }
                        } else {
                            return error.UnexpectedToken;
                        }
                    } else if (self.cur.kind == .identifier) {
                        // Other session properties (not implemented)
                        property = self.cur.lexeme;
                        self.advance();
                        if (self.cur.kind == .identifier or self.cur.kind == .string_lit) {
                            value = self.cur.lexeme;
                            self.advance();
                        }
                    }

                    break :blk .{ .SessionSet = .{ .property = property, .value = value } };
                }
                if (self.cur.kind == .RESET) {
                    self.advance();
                    break :blk .SessionReset;
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
            .COMMIT => {
                self.advance();
                return .Commit;
            },
            .ROLLBACK => {
                self.advance();
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
                
                break :blk_call .{ .Call = .{
                    .procedure = procedure,
                    .yield_items = yield_items,
                    .return_clause = return_clause,
                }};
            },
            else => return error.UnexpectedToken,
        };
    }

    fn handleQueryResult(self: *Parser, first: ast.Query) ParserError!ast.Statement {
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
                // Disallow both modifiers at once
                if (self.cur.kind == .ALL or self.cur.kind == .DISTINCT) return self.unexpected("both ALL and DISTINCT specified");
                const q = try self.parseQuery();
                try parts.append(self.arena.allocator(), .{ .all = all, .distinct = distinct, .query = q });
            }
            return .{ .Union = .{ .first = first, .tails = try parts.toOwnedSlice(self.arena.allocator()) } };
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
                return .{ .Intersect = .{ .left = first, .right = rhs, .all = all, .distinct = distinct } };
            } else {
                return .{ .Except = .{ .left = first, .right = rhs, .all = all, .distinct = distinct } };
            }
        }
        return .{ .Query = first };
    }

    fn parseQuery(self: *Parser) ParserError!ast.Query {
        // Optional MATCH/OPTIONAL MATCH pattern; allow RETURN-only queries too.
        var optional_match = false;
        var have_match = false;
        if (self.cur.kind == .OPTIONAL) {
            self.advance();
            optional_match = true;
            have_match = true;
        }
        if (self.cur.kind == .MATCH) {
            have_match = true;
        }
        // Prepare defaults
        var where_expr: ?ast.Expr = null;
        var with_clause: ?ast.WithClause = null;
        var group_by: ?ast.GroupBy = null;
        var having_expr: ?ast.Expr = null;
        const path_variable: ?[]const u8 = null;
        const pat: ast.GraphPattern = if (have_match) blk_pat: {
            _ = try self.expect(.MATCH);
            // For the top-level MATCH pattern, collect aliases freshly.
            self.collect_chain_aliases = true;
            self.path_aliases.clearRetainingCapacity();

            // Path variable assignment is handled inside parseGraphPattern

            // Parse first MATCH pattern
            var all_chains = std.ArrayList(ast.Chain).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
            const first_gp = try self.parseGraphPattern();
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
            // Optional WITH projection forwarding
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
            break :blk_pat combined_gp;
        } else blk_empty: {
            // No MATCH: use empty pattern, and ensure no stale aliases
            self.path_aliases.clearRetainingCapacity();
            break :blk_empty .{ .chains = &.{} };
        };

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

        // RETURN item (, item)* (now after SET/REMOVE, optional if SET/REMOVE present)
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
        } else {
            // No SET/REMOVE and no RETURN - error
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
            .optional_match = optional_match,
            .match = pat,
            .where_clause = where_expr,
            .with_clause = with_clause,
            .set_clauses = set_clauses,
            .remove_clauses = remove_clauses,
            .group_by = group_by,
            .having = having_expr,
            .ret = return_clause,
            .order_by = ord,
            .limit = limit,
            .offset = offset,
            .path_variable = path_variable,
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
            // Optional path alias: ident '=' before a node pattern
            var chain_name: ?[]const u8 = null;
            if (self.cur.kind == .identifier and self.peekKind() == .eq) {
                chain_name = self.cur.lexeme;
                self.advance(); // ident
                _ = try self.expect(.eq);
            }
            var left = try self.parseNodePattern();
            while (true) {
                // expect a connector for a hop: '-', '<-', or '->'
                var dir: ast.RelDir = .undirected;
                if (self.cur.kind == .minus) {
                    self.advance();
                } else if (self.cur.kind == .arrow_l) {
                    dir = .left;
                    self.advance();
                } else if (self.cur.kind == .arrow_r) {
                    dir = .right;
                    self.advance();
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
        if (self.cur.kind == .identifier) {
            name = self.cur.lexeme;
            self.advance();
        }
        var labels = std.ArrayList([]const u8).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
        while (self.cur.kind == .colon) {
            self.advance();
            const l = try self.expect(.identifier);
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
        if (self.cur.kind == .identifier) {
            name = self.cur.lexeme;
            self.advance();
        }
        var types = std.ArrayList([]const u8).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
        while (self.cur.kind == .colon) {
            self.advance();
            const tkn = try self.expect(.identifier);
            try types.append(self.arena.allocator(), tkn.lexeme);
            while (self.cur.kind == .bar) {
                self.advance();
                const alt = try self.expect(.identifier);
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
                else if (self.cur.kind == .identifier or self.isKeyword(self.cur.kind))
                    blk: {
                        const token = self.cur;
                        self.advance();
                        break :blk token;
                    }
                else
                    return self.unexpected("property key");
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
        while (true) {
            const expr = try self.parseOrExpr();
            var alias: ?[]const u8 = null;
            if (self.cur.kind == .AS) {
                self.advance();
                const a = try self.expect(.identifier);
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
        if (self.cur.kind == .regex_match) {
            self.advance();
            const rhs = try self.parseAddExpr();
            const a = self.arena.allocator();
            const lp = try a.create(ast.Expr);
            const rp = try a.create(ast.Expr);
            lp.* = left;
            rp.* = rhs;
            return .{ .RegexMatch = .{ .value = lp, .pattern = rp } };
        }
        const op_kind = switch (self.cur.kind) {
            .eq => ast.BinOp.Eq,
            .ne => ast.BinOp.Ne,
            .lt => ast.BinOp.Lt,
            .le => ast.BinOp.Le,
            .gt => ast.BinOp.Gt,
            .ge => ast.BinOp.Ge,
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
        while (self.cur.kind == .star or self.cur.kind == .slash) {
            const op = if (self.cur.kind == .star) ast.BinOp.Mul else ast.BinOp.Div;
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
        if (self.cur.kind == .minus) {
            self.advance();
            const e = try self.parseUnaryExpr();
            const a = self.arena.allocator();
            const ep = try a.create(ast.Expr);
            ep.* = e;
            return .{ .Unary = .{ .op = .Neg, .expr = ep } };
        }
        return self.parsePostfixExpr();
    }

    fn parsePostfixExpr(self: *Parser) ParserError!ast.Expr {
        var base = try self.parsePrimaryExpr();
        while (true) {
            if (self.cur.kind == .dot) {
                self.advance();
                const field = if (self.cur.kind == .identifier or self.isKeyword(self.cur.kind))
                    blk: {
                        const token = self.cur;
                        self.advance();
                        break :blk token;
                    }
                else
                    try self.expect(.identifier);
                const a = self.arena.allocator();
                const bp = try a.create(ast.Expr);
                bp.* = base;
                base = .{ .Member = .{ .target = bp, .field = field.lexeme } };
                continue;
            }
            if (self.cur.kind == .l_paren) {
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
            break;
        }
        return base;
    }

    fn parsePrimaryExpr(self: *Parser) ParserError!ast.Expr {
        return switch (self.cur.kind) {
            .dollar => blk_param: {
                // Parameter: $identifier
                self.advance();
                const name = try self.expect(.identifier);
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
            .identifier, .EXISTS, .COUNT, .SUM, .AVG, .MIN, .MAX, .VALUE, .TYPE, .LAST, .REPLACE => blk: {
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
                // Convert digits '.' digits into coeff and scale
                const lex = tkn.lexeme;
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
                // ast.Decimal currently only stores coeff/scale; original literal tracking handled later when converting to eval.Value.
                break :blk_f .{ .Decimal = .{ .coeff = coeff, .scale = scale } };
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
                if (self.cur.kind == .l_paren or self.cur.kind == .arrow_l or self.cur.kind == .minus or (self.cur.kind == .identifier and self.peekKind() == .eq)) {
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
                const a = self.arena.allocator();
                const pat_ptr = try a.create(ast.GraphPattern);
                pat_ptr.* = pat_val;
                // Optional alias for comprehension result: allow preceding identifier '=' before '[' already handled in outer parse? Here we support inline alias via a prior token check.
                // We accept syntax like: p = [ pattern | expr ] by handling in parsePostfix callsite normally as a top-level expression using Binary Eq? Simpler: support a prefix alias in primary by checking for preceding identifier '=' is not feasible here.
                // Implement simpler form: allow after comprehension an optional 'AS ident' alias; or embed none. We'll stick to none here; aliasing can be carried by outer ReturnItem alias.
                break :blk_pc .{ .PatternComp = .{ .pattern = pat_ptr, .where = where_expr, .map = mp, .alias = null } };
            },
            else => error.UnexpectedToken,
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
            else => false,
        };
    }

    fn argIsStringLike(e: ast.Expr) bool {
        return switch (e) {
            .String => true,
            .Ident => true,
            .Member => true,
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
            return n == 1 and (args[0] == .Ident or args[0] == .Member);
        }
        if (std.ascii.eqlIgnoreCase(name, "coalesce")) {
            return n >= 1;
        }
        if (std.ascii.eqlIgnoreCase(name, "toInteger")) {
            return n == 1 and (argIsNumericLike(args[0]) or argIsStringLike(args[0]));
        }
        if (std.ascii.eqlIgnoreCase(name, "toString")) {
            return n == 1 and (argIsStringLike(args[0]) or argIsNumericLike(args[0]));
        }
        if (std.ascii.eqlIgnoreCase(name, "abs")) {
            return n == 1 and argIsNumericLike(args[0]);
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

        // Check if this is CREATE INDEX
        if (self.cur.kind == .INDEX or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "INDEX")) or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "UNIQUE")))
        {
            return self.parseCreateIndex();
        }

        // Otherwise, parse the pattern to create
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
        // Parse property access (e.g., n.name)
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const object = self.cur.lexeme;
        self.advance();

        _ = try self.expect(.dot);

        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const property = self.cur.lexeme;
        self.advance();

        _ = try self.expect(.eq);

        const value = try self.parseOrExpr();

        return .{
            .target = .{ .object = object, .property = property },
            .value = value,
        };
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
        // Parse property access (e.g., n.name)
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const object = self.cur.lexeme;
        self.advance();

        _ = try self.expect(.dot);

        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const property = self.cur.lexeme;
        self.advance();

        return .{
            .target = .{ .object = object, .property = property },
        };
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

        // Index name
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const name = self.cur.lexeme;
        self.advance();

        // ON keyword
        if (self.cur.kind != .ON) return error.UnexpectedToken;
        self.advance();

        // Label (e.g., :Person or Person)
        var label: []const u8 = undefined;
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

        // Properties in parentheses
        if (self.cur.kind != .l_paren) return error.UnexpectedToken;
        self.advance();

        var properties = std.ArrayList([]const u8).initCapacity(self.arena.allocator(), 1) catch unreachable;

        // First property
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        try properties.append(self.arena.allocator(), self.cur.lexeme);
        self.advance();

        // Additional properties
        while (self.cur.kind == .comma) {
            self.advance();
            if (self.cur.kind != .identifier) return error.UnexpectedToken;
            try properties.append(self.arena.allocator(), self.cur.lexeme);
            self.advance();
        }

        if (self.cur.kind != .r_paren) return error.UnexpectedToken;
        self.advance();

        // Optional USING index_type
        var index_type = ast.IndexType.btree;
        if (self.cur.kind == .USING) {
            self.advance();
            if (self.cur.kind == .identifier) {
                const type_str = self.cur.lexeme;
                if (std.ascii.eqlIgnoreCase(type_str, "btree")) {
                    index_type = .btree;
                } else if (std.ascii.eqlIgnoreCase(type_str, "hash")) {
                    index_type = .hash;
                } else if (std.ascii.eqlIgnoreCase(type_str, "fulltext")) {
                    index_type = .fulltext;
                } else if (std.ascii.eqlIgnoreCase(type_str, "spatial")) {
                    index_type = .spatial;
                } else if (std.ascii.eqlIgnoreCase(type_str, "vector")) {
                    index_type = .vector;
                }
                self.advance();
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

    // Parse DROP statement (DROP INDEX or future DROP types)
    fn parseDropStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.DROP);

        // Check if this is DROP INDEX
        if (self.cur.kind == .INDEX or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "INDEX")))
        {
            return self.parseDropIndex();
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

    // Parse SET SESSION statement
    fn parseSetSessionStatement(self: *Parser) ParserError!ast.Statement {
        self.advance(); // consume SET
        _ = try self.expect(.SESSION);
        
        // Expect property name (currently only GRAPH is supported)
        const property = if (self.cur.kind == .GRAPH) blk: {
            self.advance();
            break :blk "GRAPH";
        } else {
            return error.UnexpectedToken;
        };
        
        _ = try self.expect(.eq); // expect '='
        
        // Expect value (string literal or identifier)
        const value = if (self.cur.kind == .string_lit or self.cur.kind == .identifier) blk: {
            const val = self.cur.lexeme;
            self.advance();
            break :blk val;
        } else {
            return error.UnexpectedToken;
        };
        
        return .{ .SessionSet = .{
            .property = property,
            .value = value,
        } };
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
