const std = @import("std");
const Lexer = @import("gql/lexer.zig").Lexer;
const Parser = @import("gql/parser.zig").Parser;
pub const ast = @import("gql/ast.zig");

pub const ParseResult = struct {
    program: ast.Program,
    arena: std.heap.ArenaAllocator,
    last_error: ?[]const u8 = null,

    pub fn deinit(self: *ParseResult) void {
        self.arena.deinit();
    }
};

pub const ParseOptions = struct {
    strict_order_keys: bool = false,
    ident_order_only: bool = false,
    forbid_orderby_calls: bool = false,
    forbid_orderby_paths: bool = false,
    ts_extensions: bool = false,
};

// Re-export printer module so binaries can import through the geode module
pub const printer = @import("gql/print.zig");
// Re-export conformance profile helpers for CLI/tools
pub const conformance = @import("conformance.zig");
// Re-export selected runtime helpers so binaries can import via the geode package
pub const exec = @import("exec.zig");
pub const planner = @import("planner.zig");
pub const temporal = @import("temporal.zig");
// Re-export evaluator for expression tests and demos
pub const eval = @import("eval.zig");
pub const diagnostics = @import("diagnostics.zig");
// Time-series module (initial in-memory scaffold)
pub const timeseries = @import("timeseries/timeseries.zig");
// Re-export storage submodules needed across server modules (CSR adjacency)
pub const storage = struct {
    // Note: CSR is available to the server binary via build.zig module injection; tests import it directly.
    pub const csr = @import("storage/csr_adjacency.zig");
};

// Lightweight helper to carry parameter bindings across subsystems
pub const ParamBindings = struct {
    names: []const []const u8,
    values: []const eval.Value,
};

/// Construct an eval.Env from identifier bindings and optional ParamBindings
pub fn makeEnv(id_names: []const []const u8, id_values: []const eval.Value, params: ?ParamBindings) eval.Env {
    if (params) |p| {
        return .{ .names = id_names, .values = id_values, .param_names = p.names, .param_values = p.values };
    }
    return .{ .names = id_names, .values = id_values };
}

pub fn parseGql(src: []const u8, allocator: std.mem.Allocator) !ParseResult {
    return parseGqlOptions(src, allocator, .{});
}

pub fn parseGqlOptions(src: []const u8, allocator: std.mem.Allocator, opts: ParseOptions) !ParseResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next(), .strict_order_keys = opts.strict_order_keys, .ident_order_only = opts.ident_order_only, .forbid_orderby_calls = opts.forbid_orderby_calls, .forbid_orderby_paths = opts.forbid_orderby_paths, .ts_extensions = opts.ts_extensions };
    const program = try p.parseProgram();
    return .{ .program = program, .arena = arena, .last_error = p.last_error };
}

pub const ParseOutcome = union(enum) {
    Ok: ParseResult,
    Err: struct { msg: []const u8, line: u32, column: u32, token: @import("gql/token.zig").TokenKind },
};

// Parse but capture parser error details instead of throwing; allocation errors still throw.
pub fn parseGqlOutcome(src: []const u8, allocator: std.mem.Allocator, opts: ParseOptions) !ParseOutcome {
    //
    var arena = std.heap.ArenaAllocator.init(allocator);
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next(), .strict_order_keys = opts.strict_order_keys, .ident_order_only = opts.ident_order_only, .forbid_orderby_calls = opts.forbid_orderby_calls, .forbid_orderby_paths = opts.forbid_orderby_paths, .ts_extensions = opts.ts_extensions };
    const program = p.parseProgram() catch {
        const msg = p.last_error orelse "parse error";
        const loc = p.cur.loc;
        const kind = p.cur.kind;
        arena.deinit();
        return .{ .Err = .{ .msg = msg, .line = loc.line, .column = loc.column, .token = kind } };
    };
    return .{ .Ok = .{ .program = program, .arena = arena, .last_error = p.last_error } };
}

test "lib.parseGql basic" {
    const ally = std.testing.allocator;
    var res = try parseGql("MATCH (a)-[r]->(b) RETURN a", ally);
    defer res.deinit();
    try std.testing.expect(res.program.statements.len == 1);
}
