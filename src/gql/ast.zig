const std = @import("std");
const temporal = @import("../temporal.zig");

// A very small AST subset sufficient for an initial pipeline.
pub const Program = struct { statements: []Statement };

pub const Statement = union(enum) {
    Query: Query,
    Union: UnionQuery,
    Intersect: BinarySet,
    Except: BinarySet,
    SessionSet: SessionSetStatement,
    SessionReset,
    SessionClose,
    StartTransaction,
    Commit,
    Rollback,
    // Simple DML prototype: INSERT VALUE <expr>
    InsertValue: struct { expr: Expr },
    // Scan all inserted values (heap table prototype)
    ScanValues,
    // Graph mutations
    Create: CreateStatement,
    Delete: DeleteStatement,
    Merge: MergeStatement,
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
    // Indicates this query is part of a WITH RECURSIVE CTE block (parser recognition only for now)
    // CANARY: REQ=REQ-GQL-079; FEATURE="RecursiveExecution"; ASPECT=ParserRecognition; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_079_ParserRecognitionNegativeCycle|TestCANARY_REQ_GQL_079_ParserRecognition; OWNER=engine; UPDATED=2025-09-26
    has_recursive_cte: bool = false,
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
    // When a graph pattern chain contains only a single node pattern (no relationship hops),
    // the parser records that standalone node here so executors can perform a NodeScan.
    // For chains with one or more hops, this remains null and executors should ignore it.
    head: ?NodePattern = null,
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
    // Fixed-point decimal literal: coeff * 10^-scale
    Decimal: struct { coeff: i128, scale: u8 },
    Bool: bool,
    Null,
    Date: struct { raw: []const u8, parsed: temporal.Date },
    DateTime: struct { raw: []const u8, parsed: temporal.DateTime },
    Time: struct { raw: []const u8, parsed: temporal.Time },
    LocalDateTime: struct { raw: []const u8, parsed: temporal.DateTime },
    List: []*Expr,
    // New type constructor literals
    SmallIntLit: i16,
    BigIntLit: i64,
    RealLit: f32,
    DoubleLit: f64,
    CharLit: struct { text: []const u8, n: u16 },
    VarcharLit: struct { text: []const u8, n: u16 },
    TextLit: []const u8,
    ByteaLit: []const u8,
    JsonLit: []const u8,
    JsonbLit: []const u8,
    XmlLit: []const u8,
    UrlLit: []const u8,
    DomainLit: []const u8,
    UuidLit: []const u8,
    EnumLit: struct { type_name: []const u8, value: []const u8 },
    ArrayLit: []*Expr,
    BitLit: []const u8,
    VarBitLit: []const u8,
    Member: struct { target: *Expr, field: []const u8 },
    PropertyAccess: struct { object: []const u8, property: []const u8 }, // n.name syntax
    Call: struct { callee: *Expr, args: []*Expr },
    Unary: struct { op: UnaryOp, expr: *Expr },
    Binary: struct { op: BinOp, left: *Expr, right: *Expr },
    In: struct { value: *Expr, set: []*Expr },
    IsNull: struct { target: *Expr, negated: bool },
    IsUnknown: struct { target: *Expr, negated: bool },
    // String predicates
    StartsWith: struct { value: *Expr, prefix: *Expr },
    EndsWith: struct { value: *Expr, suffix: *Expr },
    Contains: struct { value: *Expr, needle: *Expr },
    RegexMatch: struct { value: *Expr, pattern: *Expr },
    NotIn: struct { value: *Expr, set: []*Expr },
    // CASE expression
    Case: struct { operand: ?*Expr, whens: []CaseWhen, else_expr: ?*Expr },
    // Parameter reference: $name
    Param: []const u8,
    Map: []Property,
    PatternComp: struct { pattern: *GraphPattern, where: ?*Expr, map: *Expr, alias: ?[]const u8 = null },
};

pub const BinOp = enum { And, Or, Eq, Ne, Lt, Le, Gt, Ge, Add, Sub, Mul, Div };
pub const UnaryOp = enum { Not, Neg };

pub const CaseWhen = struct { when: *Expr, then_expr: *Expr };

// Graph mutation statements
pub const CreateStatement = struct {
    pattern: GraphPattern,
    return_clause: ?ReturnClause = null,
};

pub const DeleteStatement = struct {
    match_clause: ?GraphPattern = null,
    where_clause: ?Expr = null,
    detach: bool = false,
    items: []DeleteItem,
    return_clause: ?ReturnClause = null,
};

pub const DeleteItem = union(enum) {
    Variable: []const u8,
    Node: []const u8,
    Relationship: []const u8,
};

pub const MergeStatement = struct {
    pattern: GraphPattern,
    on_create: []SetClause = &.{},
    on_match: []SetClause = &.{},
    return_clause: ?ReturnClause = null,
};

pub const SetClause = struct {
    target: PropertyAccess,
    value: Expr,
};

pub const PropertyAccess = struct {
    object: []const u8,
    property: []const u8,
};

pub const SessionSetStatement = struct {
    property: []const u8, // e.g., "GRAPH"
    value: []const u8, // e.g., "G1"
};
