const std = @import("std");
const temporal = @import("../temporal.zig");

// A very small AST subset sufficient for an initial pipeline.
pub const Program = struct { statements: []Statement };

pub const Statement = union(enum) {
    Query: Query,
    Union: UnionQuery,
    Intersect: BinarySet,
    Except: BinarySet,
    SessionSet,
    SessionReset,
    SessionClose,
    StartTransaction,
    Commit,
    Rollback,
};

pub const Query = struct {
    optional_match: bool,
    match: GraphPattern,
    where_clause: ?Expr,
    with_clause: ?WithClause,
    group_by: ?GroupBy = null,
    having: ?Expr = null,
    ret: ReturnClause,
    order_by: ?OrderBy,
    limit: ?usize,
    offset: ?usize,
};

pub const UnionQuery = struct {
    pub const Part = struct { all: bool, distinct: bool, query: Query };
    first: Query,
    tails: []Part,
};

pub const BinarySet = struct { left: Query, right: Query, all: bool = false, distinct: bool = false };

pub const Property = struct { key: []const u8, value: *Expr };

pub const NodePattern = struct {
    name: ?[]const u8,
    labels: [][]const u8,
    props: ?[]Property,
};

pub const RelDir = enum { right, left, undirected };

pub const RelPattern = struct {
    name: ?[]const u8,
    types: [][]const u8,
    props: ?[]Property,
    dir: RelDir,
    // Optional variable-length quantifier: *min..max
    // *      => min_len=0, max_len=null
    // *k     => min_len=k, max_len=k
    // *k..m  => min_len=k, max_len=m
    // *..m   => min_len=0, max_len=m
    // *k..   => min_len=k, max_len=null
    min_len: ?u32 = null,
    max_len: ?u32 = null,
};

pub const Hop = struct { left: NodePattern, rel: RelPattern, right: NodePattern };

pub const Chain = struct {
    name: ?[]const u8 = null,
    hops: []Hop,
};

pub const GraphPattern = struct { chains: []Chain };

pub const ReturnItem = struct { expr: Expr, alias: ?[]const u8 };

pub const ReturnClause = struct { items: []ReturnItem, distinct: bool };

pub const WithClause = struct { items: []ReturnItem };

pub const GroupBy = struct { keys: []Expr };

pub const OrderBy = struct {
    pub const NullsPolicy = enum { default, first, last };
    pub const OrderKey = struct { expr: Expr, desc: bool, nulls: NullsPolicy = .default };
    keys: []OrderKey,
};

pub const Expr = union(enum) {
    Ident: []const u8,
    String: []const u8,
    Int: i64,
    Bool: bool,
    Null,
    Date: struct { raw: []const u8, parsed: temporal.Date },
    DateTime: struct { raw: []const u8, parsed: temporal.DateTime },
    Time: struct { raw: []const u8, parsed: temporal.Time },
    LocalDateTime: struct { raw: []const u8, parsed: temporal.DateTime },
    List: []*Expr,
    Member: struct { target: *Expr, field: []const u8 },
    Call: struct { callee: *Expr, args: []*Expr },
    Unary: struct { op: UnaryOp, expr: *Expr },
    Binary: struct { op: BinOp, left: *Expr, right: *Expr },
    In: struct { value: *Expr, set: []*Expr },
    IsNull: struct { target: *Expr, negated: bool },
    // String predicates
    StartsWith: struct { value: *Expr, prefix: *Expr },
    EndsWith: struct { value: *Expr, suffix: *Expr },
    Contains: struct { value: *Expr, needle: *Expr },
    RegexMatch: struct { value: *Expr, pattern: *Expr },
    // CASE expression
    Case: struct { operand: ?*Expr, whens: []CaseWhen, else_expr: ?*Expr },
    Map: []Property,
    PatternComp: struct { pattern: *GraphPattern, where: ?*Expr, map: *Expr, alias: ?[]const u8 = null },
};

pub const BinOp = enum { And, Or, Eq, Ne, Lt, Le, Gt, Ge, Add, Sub, Mul, Div };
pub const UnaryOp = enum { Not, Neg };

pub const CaseWhen = struct { when: *Expr, then_expr: *Expr };
