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
    // Last error context message (static or source-backed slice).
    last_error: ?[]const u8 = null,
    // Path alias names collected from the last parsed graph pattern (MATCH or pattern comprehension).
    path_aliases: std.ArrayList([]const u8) = undefined,
    // Whether parseGraphPattern should record chain aliases into path_aliases.
    collect_chain_aliases: bool = false,

    fn advance(self: *Parser) void {
        self.cur = self.lx.next();
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
        while (self.cur.kind != .eof) {
            const st = try self.parseStatement();
            try list.append(self.arena.allocator(), st);
            if (self.cur.kind == .semicolon) self.advance();
        }
        return .{ .statements = try list.toOwnedSlice(self.arena.allocator()) };
    }

    fn parseStatement(self: *Parser) ParserError!ast.Statement {
        return switch (self.cur.kind) {
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
            .MATCH, .OPTIONAL => blk_query: {
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
                        // Disallow both modifiers at once
                        if (self.cur.kind == .ALL or self.cur.kind == .DISTINCT) return self.unexpected("both ALL and DISTINCT specified");
                        const q = try self.parseQuery();
                        try parts.append(self.arena.allocator(), .{ .all = all, .distinct = distinct, .query = q });
                    }
                    break :blk_query .{ .Union = .{ .first = first, .tails = try parts.toOwnedSlice(self.arena.allocator()) } };
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
                        break :blk_query .{ .Intersect = .{ .left = first, .right = rhs, .all = all, .distinct = distinct } };
                    } else {
                        break :blk_query .{ .Except = .{ .left = first, .right = rhs, .all = all, .distinct = distinct } };
                    }
                }
                break :blk_query .{ .Query = first };
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
                    break :blk .SessionSet;
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
            else => return error.UnexpectedToken,
        };
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
        const pat: ast.GraphPattern = if (have_match) blk_pat: {
            _ = try self.expect(.MATCH);
            // For the top-level MATCH pattern, collect aliases freshly.
            self.collect_chain_aliases = true;
            self.path_aliases.clearRetainingCapacity();
            const gp = try self.parseGraphPattern();
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
            break :blk_pat gp;
        } else blk_empty: {
            // No MATCH: use empty pattern, and ensure no stale aliases
            self.path_aliases.clearRetainingCapacity();
            break :blk_empty .{ .chains = &.{} };
        };

        // RETURN item (, item)*
        _ = try self.expect(.RETURN);
        const distinct = if (self.cur.kind == .DISTINCT) blk: {
            self.advance();
            break :blk true;
        } else false;
        var items = std.ArrayList(ast.ReturnItem).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
        try self.parseProjectionItems(&items);

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

        var ord: ?ast.OrderBy = null;
        if (self.cur.kind == .ORDER) {
            self.advance();
            _ = try self.expect(.BY);
            var keys = std.ArrayList(ast.OrderBy.OrderKey).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
            // first expression key
            const expr1 = try self.parseOrExpr();
            if (self.forbid_orderby_calls and self.containsCall(expr1)) return self.unexpected("function calls in ORDER BY are disabled");
            if (self.ident_order_only and !(expr1 == .Ident or (expr1 == .Int and self.isValidOrdinal(expr1.Int, items.items.len)))) return self.unexpected("ORDER BY key must be identifier");
            if (!self.ident_order_only and self.strict_order_keys and !self.isSimpleOrderKey(expr1)) return self.unexpected("ORDER BY key must be identifier or member");
            if (self.forbid_orderby_paths and self.isPathAlias(expr1)) return self.unexpected("ORDER BY cannot reference path alias");
            if (self.ident_order_only and expr1 == .Ident) {
                if (!self.isProjectedIdent(expr1.Ident, items.items)) return self.unexpected("ORDER BY key must reference projected identifier");
            }
            // If ident_order_only policy is active by server, enforce identifier-only here
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
                if (self.forbid_orderby_calls and self.containsCall(exprk)) return self.unexpected("function calls in ORDER BY are disabled");
                if (self.ident_order_only and !(exprk == .Ident or (exprk == .Int and self.isValidOrdinal(exprk.Int, items.items.len)))) return self.unexpected("ORDER BY key must be identifier");
                if (!self.ident_order_only and self.strict_order_keys and !self.isSimpleOrderKey(exprk)) return self.unexpected("ORDER BY key must be identifier or member");
                if (self.forbid_orderby_paths and self.isPathAlias(exprk)) return self.unexpected("ORDER BY cannot reference path alias");
                if (self.ident_order_only and exprk == .Ident) {
                    if (!self.isProjectedIdent(exprk.Ident, items.items)) return self.unexpected("ORDER BY key must reference projected identifier");
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
        if (self.cur.kind == .LIMIT) {
            self.advance();
            const n = try self.expect(.integer_lit);
            limit = try std.fmt.parseInt(usize, n.lexeme, 10);
        }
        if (self.cur.kind == .OFFSET) {
            self.advance();
            const n = try self.expect(.integer_lit);
            offset = try std.fmt.parseInt(usize, n.lexeme, 10);
        }

        return .{
            .optional_match = optional_match,
            .match = pat,
            .where_clause = where_expr,
            .with_clause = with_clause,
            .group_by = group_by,
            .having = having_expr,
            .ret = .{ .items = try items.toOwnedSlice(self.arena.allocator()), .distinct = distinct },
            .order_by = ord,
            .limit = limit,
            .offset = offset,
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
            try chains.append(self.arena.allocator(), .{ .name = chain_name, .hops = try hops.toOwnedSlice(self.arena.allocator()) });
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
                const key = try self.expect(.identifier);
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
                    _ = try self.expect(.NULL);
                    const a = self.arena.allocator();
                    const tp = try a.create(ast.Expr);
                    tp.* = left;
                    return .{ .IsNull = .{ .target = tp, .negated = neg } };
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
        while (self.cur.kind == .plus or self.cur.kind == .minus) {
            const op = if (self.cur.kind == .plus) ast.BinOp.Add else ast.BinOp.Sub;
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
                const field = try self.expect(.identifier);
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
                if (self.cur.kind != .r_paren) {
                    while (true) {
                        const arg = try self.parseOrExpr();
                        const ap = try self.arena.allocator().create(ast.Expr);
                        ap.* = arg;
                        try args.append(self.arena.allocator(), ap);
                        if (self.cur.kind != .comma) break;
                        self.advance();
                    }
                }
                _ = try self.expect(.r_paren);
                const a = self.arena.allocator();
                const cp = try a.create(ast.Expr);
                cp.* = base;
                const args_slice = try args.toOwnedSlice(self.arena.allocator());
                // Simple built-in validation: enforce arity for a few known functions
                if (base == .Ident) {
                    const name = base.Ident;
                    // Convert []*Expr -> []Expr view for existing validator: pass dereferenced copies into a temp arraylist
                    var flat = std.ArrayList(ast.Expr).initCapacity(self.arena.allocator(), 0) catch @panic("OOM");
                    for (args_slice) |p| try flat.append(self.arena.allocator(), p.*);
                    if (!validateBuiltinCall(name, try flat.toOwnedSlice(self.arena.allocator()))) return self.unexpected("invalid builtin function call");
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
            .identifier => blk: {
                const tkn = self.cur;
                self.advance();
                break :blk .{ .Ident = tkn.lexeme };
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
                if (!starts_pattern) return error.UnexpectedToken;
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

    fn containsCall(self: *Parser, e: ast.Expr) bool {
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

    fn validateBuiltinCall(name: []const u8, args: []ast.Expr) bool {
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
        // Unknown functions: allow any arity for now
        return true;
    }
};
