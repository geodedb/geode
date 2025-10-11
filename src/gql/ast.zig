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
    SessionReset: SessionResetStatement,
    SessionClose,
    UseGraph: UseGraphStatement,
    StartTransaction,
    Commit,
    Rollback,
    // Simple DML prototype: INSERT VALUE <expr>
    InsertValue: struct { expr: Expr },
    // INSERT pattern syntax: INSERT (n:Label {props})
    Insert: InsertStatement,
    // Scan all inserted values (heap table prototype)
    ScanValues,
    // Graph mutations
    Create: CreateStatement,
    Delete: DeleteStatement,
    Merge: MergeStatement,
    // Procedure calls
    Call: CallStatement,
    // Index operations
    CreateIndex: CreateIndexStatement,
    DropIndex: DropIndexStatement,
    // Constraint operations
    CreateConstraint: CreateConstraintStatement,
    Show: ShowStatement,
    // Backup operations
    Backup: BackupStatement,
    Restore: RestoreStatement,
    // Catalog operations
    CreateSchema: CreateSchemaStatement,
    DropSchema: DropSchemaStatement,
    CreateGraph: CreateGraphStatement,
    DropGraph: DropGraphStatement,
    CreateGraphType: CreateGraphTypeStatement,
    DropGraphType: DropGraphTypeStatement,
    // Query introspection
    Explain: ExplainStatement,
    Profile: ProfileStatement,
    // FOR loop iteration
    For: ForStatement,
    // VALUES table constructor
    Values: ValuesStatement,
};

pub const Query = struct {
    let_bindings: []LetBinding = &.{}, // LET $var = expr bindings
    optional_match: bool,
    match: GraphPattern,
    create_pattern: ?GraphPattern = null, // Support CREATE in queries
    where_clause: ?Expr,
    filter_clause: ?Expr = null, // FILTER clause (ISO/IEC 39075:2024)
    with_clause: ?WithClause,
    set_clauses: []SetClause = &.{},
    remove_clauses: []RemoveClause = &.{},
    group_by: ?GroupBy = null,
    having: ?Expr = null,
    ret: ReturnClause,
    order_by: ?OrderBy,
    limit: ?usize,
    offset: ?usize,
    // Path variable assignment: MATCH path_var = pattern
    path_variable: ?[]const u8 = null,
    // Indicates this query is part of a WITH RECURSIVE CTE block (parser recognition only for now)
    // CANARY: REQ=REQ-GQL-079; FEATURE="RecursiveExecution"; ASPECT=ParserRecognition; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_079_ParserRecognitionNegativeCycle|TestCANARY_REQ_GQL_079_ParserRecognition; OWNER=engine; UPDATED=2025-09-26
    has_recursive_cte: bool = false,
    // CALL clause for MATCH ... CALL pattern (e.g., MATCH (n) CALL algo.bfs.stream(n) YIELD ...)
    call_clause: ?CallClause = null,
    // Query chaining: supports CREATE ... WITH ... MATCH ... pattern
    // When WITH clause is present and followed by MATCH/CREATE, the next query is stored here
    // CANARY: REQ=REQ-GQL-CHAIN; FEATURE="Query Chaining via WITH"; ASPECT=AST; STATUS=IMPLEMENTED; TEST=graph_algorithms; OWNER=parser; UPDATED=2025-10-10
    next_query: ?*Query = null,
};

pub const UnionQuery = struct {
    pub const Part = struct { operation: SetOperation = .union_op, all: bool, distinct: bool, query: Query };
    first: Query,
    tails: []Part,
};

pub const SetOperation = enum {
    union_op,
    intersect,
    except,
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

pub const LetBinding = struct { variable: []const u8, value: Expr };

pub const GroupBy = struct { keys: []Expr };

pub const OrderBy = struct {
    pub const NullsPolicy = enum { default, first, last };
    pub const OrderKey = struct { expr: Expr, desc: bool, nulls: NullsPolicy = .default };
    keys: []OrderKey,
};

// Identifier with canonical name form for case-insensitive matching
pub const IdentRepr = struct {
    orig: []const u8, // Original identifier as written
    cnf: []const u8, // Canonical name form (uppercase)
};

pub const Expr = union(enum) {
    Ident: IdentRepr,
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
    Index: struct { target: *Expr, index: *Expr },
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
    NotIn: struct { value: *Expr, set: []*Expr },
    // CASE expression
    Case: struct { operand: ?*Expr, whens: []CaseWhen, else_expr: ?*Expr },
    // Parameter reference: $name
    Param: []const u8,
    Map: []Property,
    PatternComp: struct { pattern: *GraphPattern, where: ?*Expr, map: *Expr, alias: ?[]const u8 = null },
    // EXISTS predicate with subquery pattern
    Exists: struct { pattern: *GraphPattern },
    // Label test: n:Label (checks if node has label)
    HasLabel: struct { node: []const u8, label: []const u8 },
    // Path finding functions and pattern comprehensions
    ShortestPath: struct { pattern: *GraphPattern, all: bool },
    PatternCount: *GraphPattern,
    // Map projection: n {.name, .age} - projects specified properties from an object
    MapProjection: struct { source: *Expr, fields: [][]const u8 },
};

pub const BinOp = enum { And, Or, Eq, Ne, Lt, Le, Gt, Ge, Add, Sub, Mul, Div, Mod, Concat, RegexMatch, RegexNotMatch };
pub const UnaryOp = enum { Not, Neg, Pos };

pub const CaseWhen = struct { when: *Expr, then_expr: *Expr };

// Graph mutation statements
pub const CreateStatement = struct {
    pattern: GraphPattern,
    return_clause: ?ReturnClause = null,
};

pub const InsertStatement = struct {
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

pub const CallStatement = struct {
    procedure: Expr, // Function call expression: db.labels()
    yield_items: ?[]ReturnItem = null, // YIELD clause items
    return_clause: ?ReturnClause = null, // Optional RETURN clause
    order_by: ?OrderBy = null, // ORDER BY clause
    limit: ?usize = null, // LIMIT clause
    offset: ?usize = null, // OFFSET clause
};

// CallClause for use within MATCH queries (MATCH ... CALL ... YIELD)
pub const CallClause = struct {
    procedure: Expr, // Function call expression: algo.bfs.stream(node)
    yield_items: ?[]ReturnItem = null, // YIELD clause items (required for MATCH+CALL)
};

pub const SetClause = union(enum) {
    Property: struct { target: PropertyAccess, value: Expr },
    Labels: struct { node: []const u8, labels: [][]const u8 },
};

pub const RemoveClause = union(enum) {
    Property: PropertyAccess,
    Labels: struct { node: []const u8, labels: [][]const u8 },
};

pub const PropertyAccess = struct {
    object: []const u8,
    property: []const u8,
};

pub const SessionSetStatement = struct {
    clause_type: SessionSetClauseType,
};

pub const SessionSetClauseType = union(enum) {
    Schema: SchemaReference,
    Graph: GraphClause,
    TimeZone: TimeZoneClause,
    Parameter: ParameterClause,
};

pub const SchemaReference = struct {
    name: []const u8,
};

pub const GraphClause = struct {
    property_graph: bool = true, // [PROPERTY] GRAPH
    expression: []const u8, // graph expression or reference
};

pub const TimeZoneClause = struct {
    value: []const u8, // time zone string value
};

pub const ParameterClause = union(enum) {
    GraphParam: GraphParameterClause,
    BindingTableParam: BindingTableParameterClause,
    ValueParam: ValueParameterClause,
};

pub const GraphParameterClause = struct {
    property_graph: bool = true, // [PROPERTY] GRAPH
    parameter_name: SessionParameterName,
    initializer: ?[]const u8 = null, // typed graph initializer
};

pub const BindingTableParameterClause = struct {
    parameter_name: SessionParameterName,
    initializer: ?[]const u8 = null, // typed binding table initializer
};

pub const ValueParameterClause = struct {
    parameter_name: SessionParameterName,
    initializer: ?[]const u8 = null, // typed value initializer
};

pub const SessionParameterName = struct {
    if_not_exists: bool = false,
    specification: []const u8, // parameter specification
};

pub const SessionResetStatement = struct {
    arguments: ?SessionResetArguments = null,
};

pub const SessionResetArguments = union(enum) {
    All: SessionResetAllType,
    Schema,
    Graph: bool, // true if PROPERTY GRAPH, false if just GRAPH
    TimeZone,
    Parameter: []const u8, // parameter specification
};

pub const SessionResetAllType = enum {
    Parameters, // ALL PARAMETERS
    Characteristics, // ALL CHARACTERISTICS
};

pub const UseGraphStatement = struct {
    graph_name: []const u8, // e.g., "my_graph"
};

// Index operation statements
pub const CreateIndexStatement = struct {
    name: []const u8, // Required in GQL
    unique: bool = false,
    index_type: IndexType = .btree,
    label: []const u8,
    properties: [][]const u8,
    if_not_exists: bool = false,
};

pub const CreateConstraintStatement = struct {
    name: []const u8,
    constraint_type: ConstraintType,
    label: []const u8,
    properties: [][]const u8,
    if_not_exists: bool = false,
};

pub const ConstraintType = enum {
    unique, // IS UNIQUE
    node_key, // IS NODE KEY
    not_null, // IS NOT NULL
    exists, // EXISTS (prop) - legacy syntax
};

pub const DropIndexStatement = struct {
    name: []const u8,
    if_exists: bool = false,
};

pub const ShowStatement = struct {
    show_type: ShowType,
};

pub const ShowType = enum {
    indexes,
    constraints,
    tables,
    graphs,
    procedures,
    functions,
};

pub const IndexType = enum {
    btree,
    hash,
    fulltext,
    spatial,
    vector,
    // Advanced type indexes
    vector_f32,
    spatial_geographic,
    network_cidr,
    signature_crypto,
};

// Backup and restore statements
pub const BackupStatement = struct {
    path: []const u8,
    incremental: bool = false,
    compressed: bool = false,
    encrypted: bool = false,
    encryption_key: ?[]const u8 = null,
};

pub const RestoreStatement = struct {
    path: []const u8,
    timestamp: ?[]const u8 = null,
    verify_only: bool = false,
};

// Catalog operation statements
pub const CreateSchemaStatement = struct {
    name: []const u8,
    if_not_exists: bool = false,
};

pub const DropSchemaStatement = struct {
    name: []const u8,
    if_exists: bool = false,
};

pub const CreateGraphStatement = struct {
    name: []const u8,
    if_not_exists: bool = false,
    or_replace: bool = false,
    property_graph: bool = true, // GQL property graphs are default
    typed_spec: ?[]const u8 = null, // TYPED type_name
    like_source: ?[]const u8 = null, // LIKE source_graph
    copy_source: ?[]const u8 = null, // AS COPY OF source_graph
};

pub const DropGraphStatement = struct {
    name: []const u8,
    if_exists: bool = false,
    property_graph: bool = true, // GQL property graphs are default
};

pub const CreateGraphTypeStatement = struct {
    name: []const u8,
    if_not_exists: bool = false,
    or_replace: bool = false,
    property_graph: bool = true, // GQL property graphs are default
    type_definition: []const u8, // The graph type definition (e.g., "{ }")
    like_source: ?[]const u8 = null, // LIKE source_graph
    copy_source: ?[]const u8 = null, // AS COPY OF source_type
};

pub const DropGraphTypeStatement = struct {
    name: []const u8,
    if_exists: bool = false,
    property_graph: bool = true, // GQL property graphs are default
};

// Query introspection statements
pub const ExplainStatement = struct {
    query: *Statement, // The query to explain (wrapped in a heap-allocated Statement)
};

pub const ProfileStatement = struct {
    query: *Statement, // The query to profile (wrapped in a heap-allocated Statement)
};

// FOR loop iteration statement
// Syntax: FOR item IN list_expr [WITH ORDINALITY var | WITH OFFSET var] RETURN ...
pub const ForStatement = struct {
    variable: []const u8, // The iteration variable name
    collection: Expr, // The collection to iterate over
    ordinality_var: ?[]const u8 = null, // WITH ORDINALITY variable name (1-based)
    offset_var: ?[]const u8 = null, // WITH OFFSET variable name (0-based)
    return_clause: ReturnClause, // RETURN clause for each iteration
    order_by: ?OrderBy = null,
    limit: ?usize = null,
    offset: ?usize = null,
};

pub const ValuesStatement = struct {
    rows: [][]Expr, // Each row is a list of expressions: VALUES (expr1, expr2), (expr3, expr4)
    column_names: [][]const u8, // Column names from AS (col1, col2, ...)
    next_statement: ?*Statement = null, // Continuation: MATCH, RETURN, etc.
};
