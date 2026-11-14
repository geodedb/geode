//! Value Types Module - Shared value types for execution and evaluation
//!
//! CANARY: REQ=REQ-M5.2-VALUE-TYPES-001; FEATURE="Circular Dependency Resolution"; ASPECT=SharedTypes; STATUS=EXEMPT; OWNER=architecture; UPDATED=2025-11-13
//!
//! This module extracts the core Value and Env types from eval.zig to break the
//! circular dependency between execution.zig and eval.zig. These types are used
//! throughout the query execution and expression evaluation layers.
//!
//! Phase 5 M5.2: Extract Value Types
//! - Shared types used by both execution and evaluation
//! - No behavioral changes, pure code movement
//! - Enables incremental circular dependency resolution

const std = @import("std");
const datetime = @import("types/datetime.zig");
const decimal_text = @import("types/decimal_text.zig");
const decimal128 = @import("types/decimal128.zig");
const jsonb = @import("types/jsonb.zig");
const xml = @import("types/xml.zig");
const url = @import("types/url.zig");
const uuid = @import("uuid");
const arrays = @import("types/arrays.zig");
const bitstring = @import("types/bitstring.zig");
const range = @import("types/range.zig");
const canonical_string = @import("unicode/canonical_string.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=ValueTypes; STATUS=EXEMPT; OWNER=value_types; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("value_types");
const Attr = logging.Attr;

// CANARY: REQ=REQ-M5.2-VALUE-TYPES-002; FEATURE="Error Handling"; ASPECT=EvalError; STATUS=TESTED; TEST=geodetestlab/specs/geode_edge_cases_errors.yml; OWNER=value_types; UPDATED=2025-11-13
/// Evaluation errors that can occur during expression evaluation and query execution
pub const EvalError = error{
    // SONNY-6499: a value of the wrong type for an operation, a function or
    // a CAST (user data; GQLSTATUS 22G03 invalid value type). An internal
    // invariant failure uses an error of its own, never this one.
    TypeMismatch,
    DivisionByZero,
    IntegerOverflow,
    Unsupported,
    RegexCompile,
    CharLengthExceeded,
    HexFormatError,
    JsonInvalid,
    XmlNotWellFormed,
    SearchNotPermitted,
    // SONNY-6324: the FLE catalog cannot be loaded, so whether a string
    // property is encrypted (and who may read it) is unknown: the read is
    // refused rather than answered with the stored bytes.
    FleCatalogUnavailable,
    // SONNY-6327: an encrypted string property the principal may read does
    // not decrypt; refused rather than answered with the stored bytes.
    FleDecryptionFailed,
    UrlParseError,
    DomainSyntaxError,
    UuidParseError,
    EnumTypeError,
    EnumValueError,
    IndexOutOfBounds,
    BitParseError,
    RangeBoundsError,
    RangeTooLarge, // CANARY: REQ=REQ-CLIENT-INTEGRATION-001; range() function safety limit
    FloatNaN,
    TimeParse,
    // SONNY-6489: a duration string that is not an ISO 8601 duration
    // (ISO/IEC 39075 20.29 GR 1c: invalid duration format, 22G0H). Kept apart
    // from TimeParse (a date, time or datetime string, 22007).
    DurationParse,
    // SONNY-6489: duration and datetime arithmetic (ISO/IEC 39075 20.28,
    // 23.1 Table 8): a duration result out of range (22015), a datetime
    // result out of range (22008), and duration +/- duration of a
    // year-to-month and a day-to-second operand (22G14). They were 22003.
    IntervalFieldOverflow,
    DatetimeFieldOverflow,
    IncompatibleTemporalUnitGroups,
    DecimalOverflow,
    DecimalDivZero,
    // GAP-0921: CAST semantic validation — an unconvertible value (invalid
    // character for the target) vs an unsupported target type.
    InvalidCast,
    UnsupportedCastTarget,
    // SONNY-6499: a value no target number type represents without losing
    // leading digits (ISO/IEC 39075 20.8 GR i i 2, 22003): CAST('1e400' AS
    // DOUBLE), CAST of a NaN or an infinity to STRING.
    NumericOutOfRange,
    // SONNY-6518: ISO/IEC 39075:2024 20.22 GR 9 b): LN of 0 or a negative
    // number (2201E invalid argument for natural logarithm); GR 11 b), e):
    // POWER of 0 to a negative power or of a negative base to a power that
    // is not whole, and SQRT of a negative number (SR 13) (2201F invalid
    // argument for power function).
    InvalidLogArgument,
    InvalidPowerArgument,
    // GAP-0926: an out-of-range positional parameter ($2 with one param).
    MissingParameter,
    IdnaError,
    InvalidIpAddress,
    InvalidSubnet,
    InvalidMac,
    InvalidArgs,
    // docs/@BUGS_731.md bug 8b: an unresolved function name is a diagnostic
    // (SQLSTATE 42883 undefined_function), not a silent NULL.
    UnknownFunction,
    // ENG-3910: the right-hand side of IN / NOT IN evaluated to something that
    // is neither a LIST nor NULL. Previously the evaluator invented a definite
    // boolean (false for IN, TRUE for NOT IN — a fail-OPEN that turns a
    // deny-list predicate into an allow-all). It is a data exception, and it
    // needs its own identity because the generic `TypeMismatch` still maps to
    // the 58000 system-error class.
    // CANARY: REQ=REQ-ENG-3910-IN-PREDICATE-TYPE-SAFETY; FEATURE="InOperator"; ASPECT=NonListRightHandSide; STATUS=TESTED; TEST=tests/test_eng3910_in_type_safety.zig; OWNER=eval; UPDATED=2026-08-24
    InListRequiresList,
    // Round 4 (I1'): an ordering comparison (<, <=, >, >=) of two values
    // that have no order between them: a year-to-month duration against a
    // day-to-second one (1 month against 30 days). GQLSTATE 22G04.
    ValuesNotComparable,
    // Spec geode-vectorization-and-reranking: knn()'s query metric does not
    // match the metric the target HNSW index was built with. Distinct from
    // InvalidArgs so it can carry its own GQLSTATE (42704) in proto_util.
    // CANARY: REQ=REQ-VECTOR-KNN-METRIC-VALIDATE-001; FEATURE="VectorIndex"; ASPECT=QueryMetricMatchesIndex; STATUS=TESTED; TEST=tests/test_knn_metric_mismatch.zig; OWNER=index; UPDATED=2026-08-28
    VectorMetricMismatch,
    // ENG-3922(b): a vector literal with more than 65535 elements — the u16
    // `dim` cap. It needs its own identity because the generic `TypeMismatch` it
    // used to be laundered into maps to the 58000 system-error class, telling
    // the caller the SERVER broke when they crossed a documented limit.
    // CANARY: REQ=REQ-ENG-3922-VECTOR-DIM-GUARD; FEATURE="VectorF32"; ASPECT=OverCapErrorIdentity; STATUS=TESTED; TEST=tests/test_eng3922_dim_guard.zig; OWNER=eval; UPDATED=2026-08-29
    VectorTooLarge,
    // geode#877 (c): `knn('embeddings', …)` on a MISSPELLED property returned an
    // empty list, so a typo was indistinguishable from "your data has no
    // neighbours". Same diagnostic class as `UnknownFunction` above — it needs
    // its own identity to carry GQLSTATE 42703 (undefined_column) instead of
    // being folded into a silent empty result.
    // CANARY: REQ=REQ-GEODE-877-KNN-UNKNOWN-PROPERTY; FEATURE="VectorKnn"; ASPECT=UnknownPropertyDiagnostic; STATUS=TESTED; TEST=tests/test_vector_knn_silent_failures.zig; OWNER=eval; UPDATED=2026-08-29
    UnknownProperty,
    // GAP-0840: strict-tenancy refusal raised from an evaluator read path (the
    // brute-force knn scan resolves the session tenant scope the same way the
    // MATCH loop does). Already mapped to GQLSTATE 42501 in proto_util.
    TenantScopeRequired,
    // GAP-ENT-0044/0045 (geode#875 (i)): the read-executor budget / cancel poll
    // (`read_budget.check()`) now has sites inside the brute-force knn scan, so
    // its two abort identities must be expressible by the evaluator. Already
    // mapped to GQLSTATE 53200 / 57014 in proto_util.
    ReadQueryBudgetExceeded,
    ReadQueryCancelled,
    // Item 5 of the SONNY-2686 review: the evaluator's execution callbacks and
    // row visibility were never installed (`execution.initEvaluator`), and
    // the statement needs them: a pattern predicate or subquery, or a degree /
    // knn() read for a session a policy could restrict. Refused instead of
    // answered without RLS, or a panic. Mapped to XX000 in proto_util.
    EvaluatorNotInitialized,
    // SONNY-3181: an expression nested deeper than the evaluating thread's
    // stack holds (`eval.evalExpr`'s stack guard). Refused instead of a
    // stack overflow. Mapped to 54001 (statement too complex) in proto_util.
    ExpressionTooDeep,
    OutOfMemory,
};

// CANARY: REQ=REQ-M5.2-VALUE-TYPES-003; FEATURE="Value Type"; ASPECT=CoreType; STATUS=TESTED; TEST=geodetestlab/specs/gql_type_system_comprehensive.yml; OWNER=value_types; UPDATED=2025-11-13
/// Core value type used throughout the Geode query engine
///
/// Represents all possible values in the GQL type system:
/// - Primitives: Null, Int, Bool, Str
/// - Graph types: Node, Edge, Path
/// - Advanced types: Decimal, List, Map, ExtValue
///
/// This type is the fundamental data representation used by:
/// - Query execution (execution.zig)
/// - Expression evaluation (eval.zig)
/// - Result formatting and return values
pub const Value = union(enum) {
    Null,
    Int: i64,
    Bool: bool,
    Str: []const u8,
    Node: *const @import("graph_store.zig").Node,
    Edge: *const @import("graph_store.zig").Edge,
    /// Fixed-point decimal: coeff * 10^-scale. Preserve original scale & literal for round-trip fidelity.
    Decimal: struct {
        coeff: i128,
        scale: u8,
        /// Original scale digits count (post decimal point) before any canonical trimming; may exceed scale if trailing zeros trimmed.
        orig_scale: u8 = 0,
        /// Original literal bytes (without surrounding quotes) if preservation required; optional to avoid extra alloc for computed decimals.
        orig_repr: ?[]const u8 = null,
    },
    List: []Value,
    Map: std.StringHashMap(Value),
    /// Extended types (advanced types like IpAddr, Subnet, etc.) wrapped to preserve type information
    ExtValue: @import("eval_extended.zig").ExtValue,
    /// Path type: sequence of alternating nodes and edges
    Path: struct {
        nodes: []const *const @import("graph_store.zig").Node,
        edges: []const *const @import("graph_store.zig").Edge,
    },
    // Advanced types
    SmallInt: i16,
    BigInt: i64,
    Real: f32,
    Double: f64,
    Char: struct { data: []const u8, n: u16 },
    Varchar: struct { data: []const u8, n: u16 },
    Text: []const u8,
    Date: datetime.Date,
    Time: datetime.Time,
    TimeTZ: datetime.TimeTZ,
    Timestamp: datetime.Timestamp,
    TimestampTZ: datetime.TimestampTZ,
    Interval: datetime.Interval,
    Bytea: []const u8,
    Json: []const u8,
    Jsonb: jsonb.JsonbDocument,
    Xml: xml.XmlDocument,
    Url: url.Url,
    Domain: url.Domain,
    UUID: uuid.UUID,
    Enum: struct { type_id: u32, value_ordinal: u32 },
    BitString: bitstring.BitString,
    VarBit: bitstring.BitString,
    IntRange: range.IntRange,
};

// CANARY: REQ=REQ-M5.2-VALUE-TYPES-004; FEATURE="Decimal Helper"; ASPECT=DecimalType; STATUS=TESTED; TEST=geodetestlab/specs/gql_type_system_comprehensive.yml; OWNER=value_types; UPDATED=2025-11-13
/// Helper struct for decimal arithmetic operations
pub const Dec = struct {
    coeff: i128,
    scale: u8,
};

// CANARY: REQ=REQ-M5.2-VALUE-TYPES-005; FEATURE="Environment"; ASPECT=VariableBinding; STATUS=EXEMPT; OWNER=value_types; UPDATED=2025-11-13
// CANARY: REQ=REQ-MEM-FIX-004; FEATURE="MemorySafety"; ASPECT=EnvOwnership; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-10-25
/// Environment for variable bindings during expression evaluation
///
/// Manages two types of bindings:
/// 1. Regular variables (names/values) - from MATCH, WITH, etc.
/// 2. Parameter bindings (param_names/param_values) - from query parameters
///
/// Supports:
/// - Variable lookup with fallback to parameters
/// - Immutable environment extension (withBinding)
/// - Memory ownership tracking for proper cleanup
pub const Env = struct {
    /// Simple linear env for tests/demos
    names: []const []const u8,
    values: []const Value,
    /// Optional parameter bindings: parallel arrays
    param_names: []const []const u8 = &.{},
    param_values: []const Value = &.{},
    /// Allocator for memory management (C4 fix)
    allocator: std.mem.Allocator,
    /// Track whether this Env owns its arrays and should free them
    owned: bool = false,
    /// Reference to TimeSeries store (GAP-004 wiring)
    timeseries_store: ?*const @import("timeseries/timeseries.zig").Store = null,
    /// Optional opaque execution context pointer for subquery evaluation
    exec_context: ?*anyopaque = null,

    /// Lookup a variable by name, checking regular bindings first, then parameters
    pub fn get(self: Env, name: []const u8) ?Value {
        // First check regular environment variables
        var i: usize = 0;
        while (i < self.names.len) : (i += 1) {
            if (std.mem.eql(u8, self.names[i], name)) return self.values[i];
        }

        // Fall back to checking parameters (for VALUES bindings and other parameter contexts)
        // This allows identifiers to reference parameters without the $ prefix
        i = 0;
        while (i < self.param_names.len) : (i += 1) {
            if (std.mem.eql(u8, self.param_names[i], name)) {
                if (i >= self.param_values.len) {
                    log.err("Env.get mismatch", &.{
                        Attr.int("param_names_len", @intCast(self.param_names.len)),
                        Attr.int("param_values_len", @intCast(self.param_values.len)),
                        Attr.int("i", @intCast(i)),
                    });
                    return null;
                }
                return self.param_values[i];
            }
        }

        return null;
    }

    /// Lookup a parameter by name (with or without $ prefix)
    pub fn getParam(self: Env, name: []const u8) ?Value {
        var i: usize = 0;
        while (i < self.param_names.len) : (i += 1) {
            if (std.mem.eql(u8, self.param_names[i], name)) return self.param_values[i];
        }
        return null;
    }

    // CANARY: REQ=REQ-GQL-089; FEATURE="ListComprehension"; ASPECT=Environment; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.ymlEMENTED; OWNER=eval; UPDATED=2025-10-17
    // CANARY: REQ=REQ-C4-001; FEATURE="MemoryLeakFix"; ASPECT=Environment; STATUS=TESTED; OWNER=core; UPDATED=2025-10-17
    //         EVIDENCE="Free old arrays in withBinding() to prevent memory leaks"
    /// Create a new environment with an additional binding (for list comprehension variable scopes)
    ///
    /// This creates an immutable extension of the environment, preserving the original
    /// bindings and adding a new name/value pair. Used for nested scopes in list
    /// comprehensions and pattern comprehensions.
    pub fn withBinding(self: Env, allocator: std.mem.Allocator, name: []const u8, value: Value) !Env {
        var new_names = try allocator.alloc([]const u8, self.names.len + 1);
        errdefer allocator.free(new_names);

        var new_values = try allocator.alloc(Value, self.values.len + 1);
        errdefer allocator.free(new_values);

        @memcpy(new_names[0..self.names.len], self.names);
        @memcpy(new_values[0..self.values.len], self.values);

        new_names[self.names.len] = name;
        new_values[self.values.len] = value;

        // OWNERSHIP (REQ-EVAL-ENV-OWNERSHIP-004): `withBinding` NEVER frees
        // `self.names`/`self.values`. `self` is a BY-VALUE `Env`, so the old
        // "free-self-if-owned" collapse corrupted the caller's arrays whenever
        // this was called in a loop over a source list (the comprehension /
        // quantifier evaluators call it on the SAME by-value env once per
        // element): iteration 2 would `@memcpy` out of freed memory and free
        // the same pointers a second time. The freshly-allocated arrays
        // returned here are owned by the CALLER, which is responsible for
        // releasing them (see the per-iteration `defer` in the comprehension
        // and quantifier loops). `owned` is therefore no longer read anywhere;
        // it is left on the struct only for source compatibility.
        return Env{
            .names = new_names,
            .values = new_values,
            .param_names = self.param_names,
            .param_values = self.param_values,
            .allocator = allocator,
            .owned = false, // caller owns and frees the returned arrays
            .timeseries_store = self.timeseries_store,
            .exec_context = self.exec_context,
        };
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

// CANARY: REQ=REQ-M5.2-VALUE-TYPES-006; FEATURE="Value Helpers"; ASPECT=NullCheck; STATUS=EXEMPT; OWNER=value_types; UPDATED=2025-11-13
/// Check if a value is Null
pub fn isNull(v: Value) bool {
    return v == .Null;
}

// CANARY: REQ=REQ-M5.2-VALUE-TYPES-007; FEATURE="Value Helpers"; ASPECT=Truthiness; STATUS=EXEMPT; OWNER=value_types; UPDATED=2025-11-13
/// Check if a value is truthy (used for boolean conversions)
pub fn truthy(v: Value) bool {
    return switch (v) {
        .Bool => |b| b,
        .Null => false,
        else => false,
    };
}

// CANARY: REQ=REQ-M5.2-VALUE-TYPES-008; FEATURE="Decimal Helpers"; ASPECT=DecimalConversion; STATUS=TESTED; TEST=geodetestlab/specs/gql_type_system_comprehensive.yml; OWNER=value_types; UPDATED=2025-11-13
/// Convert a Value to a decimal representation (helper for arithmetic)
pub fn toDec(v: Value) Dec {
    return switch (v) {
        .Decimal => |d| .{ .coeff = d.coeff, .scale = d.scale },
        .Int => |iv| .{ .coeff = @as(i128, iv), .scale = 0 },
        else => unreachable,
    };
}

/// Convert a Value to f64 for Double arithmetic operations
pub fn toDouble(v: Value) ?f64 {
    return switch (v) {
        .Double => |d| d,
        .Int => |i| @as(f64, @floatFromInt(i)),
        .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10.0, @as(f64, @floatFromInt(d.scale))),
        else => null,
    };
}

// CANARY: REQ=REQ-M5.2-VALUE-TYPES-009; FEATURE="Value Helpers"; ASPECT=Equality; STATUS=EXEMPT; OWNER=value_types; UPDATED=2025-11-13
/// Compare two values for equality (deep comparison for lists and paths)
pub fn eqVals(a: Value, b: Value) bool {
    return switch (a) {
        .Null => b == .Null,
        .Int => |ai| b == .Int and ai == b.Int,
        .Bool => |ab| b == .Bool and ab == b.Bool,
        // SONNY-6489: strings by their NFC form, as `=` compares them
        // (SONNY-3055); this is the element rule of `[...] = [...]`.
        .Str => |as| b == .Str and canonical_string.eqlNoAlloc(as, b.Str),
        .Decimal => |ad| b == .Decimal and ad.coeff == b.Decimal.coeff and ad.scale == b.Decimal.scale,
        // CANARY: REQ=REQ-BUG731-MATCH-SCOPING; FEATURE="NodeComparison"; ASPECT=IdentityById; STATUS=TESTED; TEST=tests/test_bug731_match_scoping.zig:406; OWNER=value_types; UPDATED=2026-07-31
        // Graph elements compare by IDENTITY (id), never by pointer. Node/Edge
        // pointers are not stable: getNodePtrForScan mints a fresh *Node per
        // call and the executor heap-allocates per-row copies, so pointer
        // equality was never true even for the same node.
        .Node => |an| b == .Node and an.id == b.Node.id,
        .Edge => |ae| b == .Edge and ae.id == b.Edge.id,
        .List => |al| blk: {
            if (b != .List) break :blk false;
            const bl = b.List;
            if (al.len != bl.len) break :blk false;
            for (al, bl) |av, bv| {
                if (!eqVals(av, bv)) break :blk false;
            }
            break :blk true;
        },
        // CANARY: REQ=REQ-VALUE-EQUALITY-001; FEATURE="MapEquality"; ASPECT=DeepCompare; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=value_types; UPDATED=2026-01-10
        .Map => |am| blk: {
            if (b != .Map) break :blk false;
            const bm = b.Map;
            // Maps must have same number of entries
            if (am.count() != bm.count()) break :blk false;
            // Every key in a must exist in b with equal value
            var iter = am.iterator();
            while (iter.next()) |entry| {
                const bval = bm.get(entry.key_ptr.*) orelse break :blk false;
                if (!eqVals(entry.value_ptr.*, bval)) break :blk false;
            }
            break :blk true;
        },
        // CANARY: REQ=REQ-VALUE-EQUALITY-002; FEATURE="ExtValueEquality"; ASPECT=TaggedUnion; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=value_types; UPDATED=2026-01-10
        .ExtValue => |ae| blk: {
            if (b != .ExtValue) break :blk false;
            const be = b.ExtValue;
            break :blk eqExtValues(ae, be);
        },
        .Path => |ap| blk: {
            if (b != .Path) break :blk false;
            const bp = b.Path;
            if (ap.nodes.len != bp.nodes.len or ap.edges.len != bp.edges.len) break :blk false;
            for (ap.nodes, bp.nodes) |an, bn| {
                if (an.id != bn.id) break :blk false;
            }
            for (ap.edges, bp.edges) |ae, be| {
                if (ae.id != be.id) break :blk false;
            }
            break :blk true;
        },
        .SmallInt => |ai| b == .SmallInt and ai == b.SmallInt,
        .BigInt => |ai| b == .BigInt and ai == b.BigInt,
        .Real => |af| b == .Real and af == b.Real,
        .Double => |ad| b == .Double and ad == b.Double,
        .Char => |ac| b == .Char and canonical_string.eqlNoAlloc(ac.data, b.Char.data) and ac.n == b.Char.n,
        .Varchar => |av| b == .Varchar and canonical_string.eqlNoAlloc(av.data, b.Varchar.data) and av.n == b.Varchar.n,
        .Text => |at| b == .Text and canonical_string.eqlNoAlloc(at, b.Text),
        .Date => |ad| b == .Date and ad.days_since_epoch == b.Date.days_since_epoch,
        .Time => |at| b == .Time and at.micros_since_midnight == b.Time.micros_since_midnight,
        // Round 4 (I1'): a zoned time by its UTC time and a duration by its
        // months and day-to-second length, as GROUP BY, DISTINCT and ORDER BY
        // compare them; both were compared field by field.
        .TimeTZ => |at| b == .TimeTZ and at.utcMicros() == b.TimeTZ.utcMicros(),
        .Timestamp => |at| b == .Timestamp and at.micros_since_epoch == b.Timestamp.micros_since_epoch,
        .TimestampTZ => |at| b == .TimestampTZ and at.micros_since_epoch_utc == b.TimestampTZ.micros_since_epoch_utc,
        .Interval => |ai| b == .Interval and ai.eql(b.Interval),
        .Bytea => |ab| b == .Bytea and std.mem.eql(u8, ab, b.Bytea),
        .Json => |aj| b == .Json and std.mem.eql(u8, aj, b.Json),
        .Jsonb => |aj| b == .Jsonb and std.mem.eql(u8, aj.data, b.Jsonb.data), // Compare canonical data
        .Xml => |ax| b == .Xml and std.mem.eql(u8, ax.data, b.Xml.data),
        .Url => |au| blk: {
            if (b != .Url) break :blk false;
            const bu = b.Url;
            if (!std.mem.eql(u8, au.scheme, bu.scheme)) break :blk false;
            if (!std.mem.eql(u8, au.host, bu.host)) break :blk false;
            if (au.port != bu.port) break :blk false;
            if (!std.mem.eql(u8, au.path, bu.path)) break :blk false;
            if (!std.mem.eql(u8, if (au.query) |q| q else "", if (bu.query) |q| q else "")) break :blk false;
            if (!std.mem.eql(u8, if (au.fragment) |f| f else "", if (bu.fragment) |f| f else "")) break :blk false;
            break :blk true;
        },
        // Wait, Url struct in src/types/url.zig? I need to check.
        // It has `toString`. `Url` might be complex. Checking heap.zig... `Url` has `string`.
        // Let's assume equality is checkable or use deeply.
        // Actually src/types/url.zig likely has `equal`. I should check or rely on fields.
        // For now, I'll use strict equality if they are structs.
        // Url in heap is `url.Url`.
        .Domain => |ad| blk: {
            if (b != .Domain) break :blk false;
            const bd = b.Domain;
            if (ad.labels.len != bd.labels.len) break :blk false;
            for (ad.labels, bd.labels) |l1, l2| {
                if (!std.mem.eql(u8, l1, l2)) break :blk false;
            }
            break :blk true;
        },
        .UUID => |au| b == .UUID and std.mem.eql(u8, &au.bytes, &b.UUID.bytes),
        .Enum => |ae| b == .Enum and ae.type_id == b.Enum.type_id and ae.value_ordinal == b.Enum.value_ordinal,
        .BitString => |ab| b == .BitString and ab.bit_length == b.BitString.bit_length and std.mem.eql(u8, ab.bytes, b.BitString.bytes),
        .VarBit => |ab| b == .VarBit and ab.bit_length == b.VarBit.bit_length and std.mem.eql(u8, ab.bytes, b.VarBit.bytes),
        .IntRange => |ar| b == .IntRange and ar.bounds == b.IntRange.bounds and ar.lower == b.IntRange.lower and ar.upper == b.IntRange.upper,
    };
}

// CANARY: REQ=REQ-VALUE-EQUALITY-002; FEATURE="ExtValueEquality"; ASPECT=Helper; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=value_types; UPDATED=2026-01-10
/// Compare two ExtValue instances for equality
pub fn eqExtValues(a: @import("eval_extended.zig").ExtValue, b: @import("eval_extended.zig").ExtValue) bool {
    const ExtValue = @import("eval_extended.zig").ExtValue;
    // Must be same tag
    if (@as(std.meta.Tag(ExtValue), a) != @as(std.meta.Tag(ExtValue), b)) return false;

    return switch (a) {
        .Null => true,
        .Int => |v| v == b.Int,
        .Bool => |v| v == b.Bool,
        // CANARY: REQ=REQ-SONNY-6489-LIST-STRING-NFC; FEATURE="UnicodeEval"; ASPECT=StoredListElementsNfc; STATUS=TESTED; TEST=tests/test_sonny6489_list_string_nfc.zig; OWNER=unicode; UPDATED=2026-11-13
        // SONNY-6489: strings by their NFC form, as `=` compares them
        // (SONNY-3055); a stored list of 'caf\u{e9}' and one of 'cafe\u{301}'
        // compared unequal by raw bytes.
        .Str => |v| canonical_string.eqlNoAlloc(v, b.Str),
        .SmallInt => |v| v == b.SmallInt,
        .BigInt => |v| v == b.BigInt,
        .Real => |v| v == b.Real,
        .Double => |v| v == b.Double,
        .Decimal => |v| v.coeff == b.Decimal.coeff and v.scale == b.Decimal.scale,
        .Char => |v| v.n == b.Char.n and canonical_string.eqlNoAlloc(v.data, b.Char.data),
        .Varchar => |v| v.n == b.Varchar.n and canonical_string.eqlNoAlloc(v.data, b.Varchar.data),
        .Text => |v| canonical_string.eqlNoAlloc(v, b.Text),
        .IpAddr => |v| switch (v) {
            .v4 => |addr| switch (b.IpAddr) {
                .v4 => |baddr| std.mem.eql(u8, &addr, &baddr),
                .v6 => false,
            },
            .v6 => |addr| switch (b.IpAddr) {
                .v4 => false,
                .v6 => |baddr| std.mem.eql(u8, &addr, &baddr),
            },
        },
        .Subnet => |v| blk: {
            const bv = b.Subnet;
            if (v.prefix_len != bv.prefix_len) break :blk false;
            break :blk switch (v.addr) {
                .v4 => |addr| switch (bv.addr) {
                    .v4 => |baddr| std.mem.eql(u8, &addr, &baddr),
                    .v6 => false,
                },
                .v6 => |addr| switch (bv.addr) {
                    .v4 => false,
                    .v6 => |baddr| std.mem.eql(u8, &addr, &baddr),
                },
            };
        },
        .Mac => |v| std.mem.eql(u8, &v.bytes, &b.Mac.bytes),
        .Hash => |v| std.mem.eql(u8, v.digest, b.Hash.digest) and v.alg == b.Hash.alg,
        .Currency => |v| std.mem.eql(u8, &v.code, &b.Currency.code),
        .LanguageTag => |v| std.mem.eql(u8, v.tag, b.LanguageTag.tag),
        .LatLon => |v| v.lat == b.LatLon.lat and v.lon == b.LatLon.lon,
        .LatLonAlt => |v| v.lat == b.LatLonAlt.lat and v.lon == b.LatLonAlt.lon and v.alt == b.LatLonAlt.alt,
        .Geometry => |v| std.mem.eql(u8, v.wkb, b.Geometry.wkb),
        .Temperature => |v| v.value_K == b.Temperature.value_K,
        .Pressure => |v| v.value_Pa == b.Pressure.value_Pa,
        .VectorF32 => |v| std.mem.eql(f32, v.data, b.VectorF32.data),
        .VectorI32 => |v| std.mem.eql(i32, v.data, b.VectorI32.data),
        .Date => |v| v.days_since_epoch == b.Date.days_since_epoch,
        .Time => |v| v.micros_since_midnight == b.Time.micros_since_midnight,
        .TimeTZ => |v| v.utcMicros() == b.TimeTZ.utcMicros(),
        .Timestamp => |v| v.micros_since_epoch == b.Timestamp.micros_since_epoch,
        .TimestampTZ => |v| v.micros_since_epoch_utc == b.TimestampTZ.micros_since_epoch_utc,
        .Interval => |v| v.eql(b.Interval),
        .UUID => |v| std.mem.eql(u8, &v.bytes, &b.UUID.bytes),
        .Url => |v| std.mem.eql(u8, v.scheme, b.Url.scheme) and std.mem.eql(u8, v.host, b.Url.host) and v.port == b.Url.port,
        .Domain => |v| blk: {
            if (v.labels.len != b.Domain.labels.len) break :blk false;
            for (v.labels, b.Domain.labels) |l1, l2| {
                if (!std.mem.eql(u8, l1, l2)) break :blk false;
            }
            break :blk true;
        },
        .Bytea => |v| std.mem.eql(u8, v, b.Bytea),
        .Json => |v| std.mem.eql(u8, v, b.Json),
        .Jsonb => |v| std.mem.eql(u8, v.data, b.Jsonb.data),
        .Xml => |v| std.mem.eql(u8, v.data, b.Xml.data),
        .BitString => |v| v.bit_length == b.BitString.bit_length and std.mem.eql(u8, v.bytes, b.BitString.bytes),
        .VarBit => |v| v.bit_length == b.VarBit.bit_length and std.mem.eql(u8, v.bytes, b.VarBit.bytes),
        .IntRange => |v| v.lower == b.IntRange.lower and v.upper == b.IntRange.upper and v.bounds == b.IntRange.bounds,
        .List => |v| blk: {
            if (v.len != b.List.len) break :blk false;
            for (v, b.List) |va, vb| {
                if (!eqExtValues(va, vb)) break :blk false;
            }
            break :blk true;
        },
        .Enum => |v| v.type_id == b.Enum.type_id and v.value_ordinal == b.Enum.value_ordinal,
        .Array => |v| v.elem_type == b.Array.elem_type and std.mem.eql(u8, v.data, b.Array.data),
    };
}

// CANARY: REQ=REQ-M5.2-VALUE-TYPES-011; FEATURE="Value Helpers"; ASPECT=Stringify; STATUS=TESTED; TEST=tests/test_gap0877_advanced_types.zig; OWNER=value_types; UPDATED=2026-06-11
/// Convert a value to its string representation (for comparison and display)
///
/// Uses a provided buffer for string formatting to avoid allocations.
/// GAP-0877: Date/Time/TimeTZ/Timestamp/TimestampTZ/Interval render canonical
/// ISO-8601; Url/Domain/Bytea render their actual value. Values that do not
/// fit the 64-byte buffer return EvalError.Unsupported (stable error, never a
/// placeholder). Enum/BitString/VarBit/IntRange still stringify as type-name
/// placeholders (documented in docs/TYPES_AND_FUNCTIONS.md).
/// Returns error for unsupported types.
pub fn stringify(v: Value, buf: *[64]u8) EvalError![]const u8 {
    return switch (v) {
        .Str => |s| s,
        .Int => |n| blk: {
            const s = std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return EvalError.Unsupported;
            break :blk s;
        },
        .Bool => |b| if (b) "true" else "false",
        .Null => "null",
        // SONNY-2769: at any scale. `pow10` overflowed past scale 38 and
        // aborted the server (`'a' || <a scale-40 decimal>`), a scale-33 to
        // scale-38 fraction overran its 32-byte padding buffer, and
        // minInt(i128) overflowed `-coeff`. A text past the 64-byte buffer is
        // Unsupported, as for every other type.
        .Decimal => |d| decimal_text.bufPrint(buf[0..], d.coeff, d.scale) catch return EvalError.Unsupported,
        // Extended types stringify
        .SmallInt => |n| std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return EvalError.Unsupported,
        .BigInt => |n| std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return EvalError.Unsupported,
        .Real => |n| std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return EvalError.Unsupported,
        .Double => |n| std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return EvalError.Unsupported,
        .Char => |c| c.data,
        .Varchar => |vc| vc.data,
        .Text => |t| t,
        // GAP-0877: canonical ISO-8601 / RFC-3986 rendering into the caller's
        // buffer. Values that cannot fit return EvalError.Unsupported (a
        // stable error) instead of a placeholder string.
        .Date => |d| blk_date: {
            var w: std.Io.Writer = .fixed(buf[0..]);
            writeDateIso(&w, d.days_since_epoch) catch return EvalError.Unsupported;
            break :blk_date w.buffered();
        },
        .Time => |t| blk_time: {
            var w: std.Io.Writer = .fixed(buf[0..]);
            writeTimeIso(&w, t.micros_since_midnight) catch return EvalError.Unsupported;
            break :blk_time w.buffered();
        },
        .TimeTZ => |t| blk_timetz: {
            var w: std.Io.Writer = .fixed(buf[0..]);
            writeTimeIso(&w, t.time.micros_since_midnight) catch return EvalError.Unsupported;
            writeUtcOffset(&w, t.offset_seconds) catch return EvalError.Unsupported;
            break :blk_timetz w.buffered();
        },
        .Timestamp => |ts| blk_ts: {
            var w: std.Io.Writer = .fixed(buf[0..]);
            writeTimestampIso(&w, ts.micros_since_epoch) catch return EvalError.Unsupported;
            break :blk_ts w.buffered();
        },
        .TimestampTZ => |ts| blk_tstz: {
            var w: std.Io.Writer = .fixed(buf[0..]);
            writeTimestampIso(&w, ts.micros_since_epoch_utc) catch return EvalError.Unsupported;
            w.writeByte('Z') catch return EvalError.Unsupported;
            break :blk_tstz w.buffered();
        },
        .Interval => |iv| blk_iv: {
            var w: std.Io.Writer = .fixed(buf[0..]);
            writeIntervalIso(&w, iv) catch return EvalError.Unsupported;
            break :blk_iv w.buffered();
        },
        .Bytea => |bytes| blk_bytea: {
            var w: std.Io.Writer = .fixed(buf[0..]);
            w.writeAll("\\x") catch return EvalError.Unsupported;
            for (bytes) |byte| {
                w.print("{x:0>2}", .{byte}) catch return EvalError.Unsupported;
            }
            break :blk_bytea w.buffered();
        },
        .Json => |j| j,
        .Jsonb => |j| j.data,
        .Xml => |x| x.data,
        .Url => |u| blk_url: {
            var w: std.Io.Writer = .fixed(buf[0..]);
            writeUrl(&w, u) catch return EvalError.Unsupported;
            break :blk_url w.buffered();
        },
        .Domain => |d| blk_domain: {
            var w: std.Io.Writer = .fixed(buf[0..]);
            for (d.labels, 0..) |label, i| {
                if (i > 0) w.writeByte('.') catch return EvalError.Unsupported;
                w.writeAll(label) catch return EvalError.Unsupported;
            }
            break :blk_domain w.buffered();
        },
        .UUID => |u| blk3: {
            const s = std.fmt.bufPrint(buf[0..], "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ u.bytes[0], u.bytes[1], u.bytes[2], u.bytes[3], u.bytes[4], u.bytes[5], u.bytes[6], u.bytes[7], u.bytes[8], u.bytes[9], u.bytes[10], u.bytes[11], u.bytes[12], u.bytes[13], u.bytes[14], u.bytes[15] }) catch return EvalError.Unsupported;
            break :blk3 s;
        },
        .Enum => "enum",
        .BitString => "bitstring",
        .VarBit => "varbit",
        .IntRange => "range",
        else => return EvalError.TypeMismatch,
    };
}

// ============================================================================
// GAP-0877: canonical ISO-8601 / RFC-3986 writer helpers for stringify
// ============================================================================

fn writeDateIso(w: *std.Io.Writer, days_since_epoch: i32) !void {
    const ymd = datetime.Date.dateFromDays(days_since_epoch);
    if (ymd.year < 0) {
        try w.print("-{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(-ymd.year)), ymd.month, ymd.day });
    } else {
        try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(ymd.year)), ymd.month, ymd.day });
    }
}

fn writeTimeIso(w: *std.Io.Writer, micros_since_midnight: i64) !void {
    if (micros_since_midnight < 0) return error.InvalidTime;
    const h: u32 = @intCast(@divFloor(micros_since_midnight, 3600_000_000));
    const m: u32 = @intCast(@divFloor(@rem(micros_since_midnight, 3600_000_000), 60_000_000));
    const s: u32 = @intCast(@divFloor(@rem(micros_since_midnight, 60_000_000), 1_000_000));
    const us: u32 = @intCast(@rem(micros_since_midnight, 1_000_000));
    if (us == 0) {
        try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ h, m, s });
    } else {
        try w.print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{ h, m, s, us });
    }
}

fn writeUtcOffset(w: *std.Io.Writer, offset_seconds: i32) !void {
    const sign: u8 = if (offset_seconds < 0) '-' else '+';
    const abs_off: u32 = @abs(offset_seconds);
    try w.print("{c}{d:0>2}:{d:0>2}", .{ sign, abs_off / 3600, (abs_off % 3600) / 60 });
}

fn writeTimestampIso(w: *std.Io.Writer, micros_since_epoch: i64) !void {
    const day_us: i64 = 24 * 3600 * 1_000_000;
    const days = @divFloor(micros_since_epoch, day_us);
    const time_of_day = @mod(micros_since_epoch, day_us);
    try writeDateIso(w, @intCast(days));
    try w.writeByte('T');
    try writeTimeIso(w, time_of_day);
}

/// SONNY-6489: the one ISO 8601 duration writer (`Interval.writeIso`), which
/// keeps the fraction of a second (PT1.5S was written PT1S).
fn writeIntervalIso(w: *std.Io.Writer, iv: datetime.Interval) !void {
    return iv.writeIso(w);
}

fn writeUrl(w: *std.Io.Writer, u: url.Url) !void {
    try w.print("{s}://{s}", .{ u.scheme, u.host });
    if (u.port) |p| try w.print(":{d}", .{p});
    try w.writeAll(u.path);
    if (u.query) |q| try w.print("?{s}", .{q});
    if (u.fragment) |f| try w.print("#{s}", .{f});
}

// ============================================================================
// Module Test (basic sanity checks)
// ============================================================================

test "Value type basics" {
    const v_null = Value{ .Null = {} };
    const v_int = Value{ .Int = 42 };
    const v_bool = Value{ .Bool = true };

    try std.testing.expect(isNull(v_null));
    try std.testing.expect(!isNull(v_int));
    try std.testing.expect(truthy(v_bool));
    try std.testing.expect(!truthy(v_null));
}

test "Env variable lookup" {
    const allocator = std.testing.allocator;

    const names = &[_][]const u8{"x"};
    const values = &[_]Value{.{ .Int = 10 }};

    const env = Env{
        .names = names,
        .values = values,
        .allocator = allocator,
    };

    try std.testing.expect(env.get("x").? == .Int);
    try std.testing.expect(env.get("x").?.Int == 10);
    try std.testing.expect(env.get("y") == null);
}

test "Env getParam uses param_names not names - R4 regression" {
    const allocator = std.testing.allocator;

    // Correct: params in param_names/param_values => getParam finds them
    const correct_env = Env{
        .names = &.{},
        .values = &.{},
        .param_names = &[_][]const u8{"age"},
        .param_values = &[_]Value{.{ .Int = 30 }},
        .allocator = allocator,
    };
    try std.testing.expect(correct_env.getParam("age") != null);
    try std.testing.expectEqual(@as(i64, 30), correct_env.getParam("age").?.Int);

    // Bug scenario: params placed in names/values instead of param_names/param_values
    // getParam must NOT find them there (this is what NodeCollector2 was doing wrong)
    const buggy_env = Env{
        .names = &[_][]const u8{"age"},
        .values = &[_]Value{.{ .Int = 30 }},
        .allocator = allocator,
    };
    try std.testing.expect(buggy_env.getParam("age") == null);
}

test "Value equality" {
    const v1 = Value{ .Int = 42 };
    const v2 = Value{ .Int = 42 };
    const v3 = Value{ .Int = 43 };

    try std.testing.expect(eqVals(v1, v2));
    try std.testing.expect(!eqVals(v1, v3));
}

test "Value stringify" {
    var buf: [64]u8 = undefined;

    const v_int = Value{ .Int = 42 };
    const s1 = try stringify(v_int, &buf);
    try std.testing.expectEqualStrings("42", s1);

    const v_bool = Value{ .Bool = true };
    const s2 = try stringify(v_bool, &buf);
    try std.testing.expectEqualStrings("true", s2);

    const v_null = Value{ .Null = {} };
    const s3 = try stringify(v_null, &buf);
    try std.testing.expectEqualStrings("null", s3);
}
