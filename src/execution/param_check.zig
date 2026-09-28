//! SONNY-3247: a statement that references a parameter the request does not
//! supply is refused before anything runs (error.MissingParameter, SQLSTATE
//! 42P02 undefined_parameter), instead of reading the parameter as null.
//!
//! A named parameter nobody supplied evaluated to null: `SET q.name =
//! $nosuch` erased the property, `LIMIT $nosuch` wrote every row, and a MERGE
//! keyed on a missing parameter merged on null. Only a positional parameter
//! out of range was an error (GAP-0926). Now every parameter a statement
//! names, anywhere (an expression, a property map, a SET value, a MERGE key,
//! a subquery, a CTE body, a LIMIT or SKIP, a FOR's list), must be one the
//! request supplies or one the statement defines itself (`LET $x = ...`).
//! A variable a WITH, UNWIND or FOR binds is a variable, not a parameter:
//! `WITH 5 AS k ... $k` is refused too.
//!
//! The check walks the whole statement like the write walk (write_walk.zig):
//! iteratively, and by reflection over every AST type, so a parameter in a
//! field added later is still found.
//!
//! CANARY: REQ=REQ-SONNY-3247-MISSING-PARAMETER; FEATURE="ParameterBinding"; ASPECT=UnsuppliedParameter; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4.zig; OWNER=engine; UPDATED=2026-09-28

const std = @import("std");
const ast = @import("../gql/ast.zig");

pub const Error = error{ MissingParameter, OutOfMemory };

/// Every statement of `program` names only parameters in `supplied` (or ones
/// it defines with LET).
pub fn checkProgram(program: *const ast.Program, supplied: []const []const u8) Error!void {
    for (program.statements) |*stmt| try checkStatement(stmt, supplied);
}

pub fn checkStatement(stmt: *const ast.Statement, supplied: []const []const u8) Error!void {
    var sfa = std.heap.stackFallback(4096, std.heap.smp_allocator);
    var c = Collector{ .alloc = sfa.get() };
    defer c.deinit();
    c.push(.stmt, stmt);
    while (c.stack.pop()) |item| {
        switch (item.kind) {
            .stmt => {
                const s: *const ast.Statement = @ptrCast(@alignCast(item.ptr));
                switch (s.*) {
                    inline else => |*p| c.visit(@TypeOf(p.*), p),
                }
            },
            .query => {
                const q: *const ast.Query = @ptrCast(@alignCast(item.ptr));
                c.visitFields(ast.Query, q);
            },
            .expr => {
                const e: *const ast.Expr = @ptrCast(@alignCast(item.ptr));
                switch (e.*) {
                    .Param => |name| c.use(name),
                    inline else => |*p| c.visit(@TypeOf(p.*), p),
                }
            },
        }
    }
    if (c.failed) return error.OutOfMemory;
    for (c.used.items) |name| {
        if (has(supplied, name) or has(c.defined.items, name)) continue;
        return error.MissingParameter;
    }
}

fn has(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

const Kind = enum(u8) { stmt, query, expr };
const Item = struct { ptr: *const anyopaque, kind: Kind };

const Collector = struct {
    alloc: std.mem.Allocator,
    stack: std.ArrayList(Item) = .empty,
    /// The parameters the statement names.
    used: std.ArrayList([]const u8) = .empty,
    /// The parameters it defines (`LET $x = ...`).
    defined: std.ArrayList([]const u8) = .empty,
    failed: bool = false,

    fn deinit(c: *Collector) void {
        c.stack.deinit(c.alloc);
        c.used.deinit(c.alloc);
        c.defined.deinit(c.alloc);
    }

    fn push(c: *Collector, kind: Kind, ptr: *const anyopaque) void {
        c.stack.append(c.alloc, .{ .ptr = ptr, .kind = kind }) catch {
            c.failed = true;
        };
    }

    fn use(c: *Collector, name: []const u8) void {
        c.used.append(c.alloc, name) catch {
            c.failed = true;
        };
    }

    fn visit(c: *Collector, comptime T: type, v: *const T) void {
        if (comptime !holds(T)) return;
        if (T == ast.Expr) return c.push(.expr, v);
        if (T == ast.Query) return c.push(.query, v);
        if (T == ast.Statement) return c.push(.stmt, v);
        switch (@typeInfo(T)) {
            .@"struct" => c.visitFields(T, v),
            .@"union" => switch (v.*) {
                inline else => |*p| c.visit(@TypeOf(p.*), p),
            },
            .optional => |o| if (v.*) |*inner| c.visit(o.child, inner),
            .pointer => |p| switch (p.size) {
                .one => c.visit(p.child, v.*),
                .slice => for (v.*) |*elem| c.visit(p.child, elem),
                else => @compileError("param_check: a " ++ @typeName(T) ++ " in the AST"),
            },
            .array => |a| for (v) |*elem| c.visit(a.child, elem),
            else => @compileError("param_check: a " ++ @typeName(T) ++ " in the AST"),
        }
    }

    /// Every field of struct `v`: a LIMIT or SKIP parameter by name, a LET
    /// binding's parameter as defined, the rest walked.
    fn visitFields(c: *Collector, comptime T: type, v: *const T) void {
        if (T == ast.Query) {
            // `LET $x = <expr>` before a query defines $x; an inline `LET x =
            // <expr>` after its MATCH defines a variable, which no `$x` reads.
            for (v.let_bindings) |binding| {
                c.defined.append(c.alloc, binding.variable) catch {
                    c.failed = true;
                };
            }
        }
        inline for (@typeInfo(T).@"struct".fields) |field| {
            const is_param_name = comptime (std.mem.eql(u8, field.name, "limit_param") or std.mem.eql(u8, field.name, "offset_param"));
            if (is_param_name) {
                if (field.type != ?[]const u8) @compileError("param_check: " ++ @typeName(T) ++ "." ++ field.name ++ " is not a parameter name");
                if (@field(v.*, field.name)) |name| c.use(name);
            } else {
                c.visit(field.type, &@field(v.*, field.name));
            }
        }
    }
};

/// Whether a value of type `T` can hold a statement, a query or an
/// expression (the only places a parameter is named), or names a LIMIT or
/// SKIP parameter.
fn holds(comptime T: type) bool {
    @setEvalBranchQuota(100_000);
    if (T == ast.Expr or T == ast.Query or T == ast.Statement) return true;
    return switch (@typeInfo(T)) {
        .@"struct" => |s| blk: {
            for (s.fields) |field| {
                if (std.mem.eql(u8, field.name, "limit_param") or std.mem.eql(u8, field.name, "offset_param")) break :blk true;
                if (holds(field.type)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |u| blk: {
            if (u.tag_type == null) @compileError("param_check: an untagged union " ++ @typeName(T) ++ " in the AST");
            for (u.fields) |field| {
                if (holds(field.type)) break :blk true;
            }
            break :blk false;
        },
        .optional => |o| holds(o.child),
        .pointer => |p| switch (p.size) {
            .one, .slice => holds(p.child),
            else => @compileError("param_check: a " ++ @typeName(T) ++ " in the AST"),
        },
        .array => |a| holds(a.child),
        .int, .float, .bool, .@"enum", .void => false,
        else => @compileError("param_check: a " ++ @typeName(T) ++ " in the AST"),
    };
}
