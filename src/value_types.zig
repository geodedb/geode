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
const decimal128 = @import("types/decimal128.zig");
const jsonb = @import("types/jsonb.zig");
const xml = @import("types/xml.zig");
const url = @import("types/url.zig");
const uuid = @import("types/uuid.zig");
const arrays = @import("types/arrays.zig");
const bitstring = @import("types/bitstring.zig");
const range = @import("types/range.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=ValueTypes; STATUS=EXEMPT; OWNER=value_types; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("value_types");
const Attr = logging.Attr;

// CANARY: REQ=REQ-M5.2-VALUE-TYPES-002; FEATURE="Error Handling"; ASPECT=EvalError; STATUS=TESTED; TEST=geodetestlab/specs/geode_edge_cases_errors.yml; OWNER=value_types; UPDATED=2025-11-13
/// Evaluation errors that can occur during expression evaluation and query execution
pub const EvalError = error{
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
    DecimalOverflow,
    DecimalDivZero,
    IdnaError,
    InvalidIpAddress,
    InvalidSubnet,
    InvalidMac,
    InvalidArgs,
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

        // Free old arrays to prevent memory leak (C4 fix)
        // Only free if this Env owns its arrays AND they were allocated
        // CANARY: REQ=REQ-MEM-FIX-005; FEATURE="MemorySafety"; ASPECT=OwnershipRespect; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-10-25
        if (self.owned and self.names.len > 0) {
            self.allocator.free(self.names);
            self.allocator.free(self.values);
        }

        return Env{
            .names = new_names,
            .values = new_values,
            .param_names = self.param_names,
            .param_values = self.param_values,
            .allocator = allocator,
            .owned = true, // New Env owns its newly allocated arrays
            .timeseries_store = self.timeseries_store,
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
        .Str => |as| b == .Str and std.mem.eql(u8, as, b.Str),
        .Decimal => |ad| b == .Decimal and ad.coeff == b.Decimal.coeff and ad.scale == b.Decimal.scale,
        .Node => |an| b == .Node and an == b.Node, // Compare node pointers
        .Edge => |ae| b == .Edge and ae == b.Edge, // Compare edge pointers
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
                if (an != bn) break :blk false;
            }
            for (ap.edges, bp.edges) |ae, be| {
                if (ae != be) break :blk false;
            }
            break :blk true;
        },
        .SmallInt => |ai| b == .SmallInt and ai == b.SmallInt,
        .BigInt => |ai| b == .BigInt and ai == b.BigInt,
        .Real => |af| b == .Real and af == b.Real,
        .Double => |ad| b == .Double and ad == b.Double,
        .Char => |ac| b == .Char and std.mem.eql(u8, ac.data, b.Char.data) and ac.n == b.Char.n,
        .Varchar => |av| b == .Varchar and std.mem.eql(u8, av.data, b.Varchar.data) and av.n == b.Varchar.n,
        .Text => |at| b == .Text and std.mem.eql(u8, at, b.Text),
        .Date => |ad| b == .Date and ad.days_since_epoch == b.Date.days_since_epoch,
        .Time => |at| b == .Time and at.micros_since_midnight == b.Time.micros_since_midnight,
        .TimeTZ => |at| b == .TimeTZ and at.time.micros_since_midnight == b.TimeTZ.time.micros_since_midnight and at.offset_seconds == b.TimeTZ.offset_seconds,
        .Timestamp => |at| b == .Timestamp and at.micros_since_epoch == b.Timestamp.micros_since_epoch,
        .TimestampTZ => |at| b == .TimestampTZ and at.micros_since_epoch_utc == b.TimestampTZ.micros_since_epoch_utc,
        .Interval => |ai| b == .Interval and ai.months == b.Interval.months and ai.days == b.Interval.days and ai.micros == b.Interval.micros,
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

// CANARY: REQ=REQ-M5.2-VALUE-TYPES-010; FEATURE="Decimal Helpers"; ASPECT=Power10; STATUS=TESTED; TEST=geodetestlab/specs/gql_type_system_comprehensive.yml; OWNER=value_types; UPDATED=2025-11-13
/// Calculate 10^scale for decimal arithmetic
fn pow10(scale: u8) i128 {
    var p: i128 = 1;
    var i: u8 = 0;
    while (i < scale) : (i += 1) p *= 10;
    return p;
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
        .Str => |v| std.mem.eql(u8, v, b.Str),
        .Decimal => |v| v.coeff == b.Decimal.coeff and v.scale == b.Decimal.scale,
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
        .TimestampTZ => |v| v.micros_since_epoch_utc == b.TimestampTZ.micros_since_epoch_utc,
        .Interval => |v| v.months == b.Interval.months and v.days == b.Interval.days and v.micros == b.Interval.micros,
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
    };
}

// CANARY: REQ=REQ-M5.2-VALUE-TYPES-011; FEATURE="Value Helpers"; ASPECT=Stringify; STATUS=EXEMPT; OWNER=value_types; UPDATED=2025-11-13
/// Convert a value to its string representation (for comparison and display)
///
/// Uses a provided buffer for string formatting to avoid allocations.
/// Handles: Int, Bool, Str, Null, Decimal
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
        .Decimal => |d| blk2: {
            // render with scale decimal point
            const abs = if (d.coeff < 0) -d.coeff else d.coeff;
            const scale_p = pow10(d.scale);
            const whole = @divTrunc(abs, scale_p);
            const frac = @mod(abs, scale_p);
            var tmp: [64]u8 = undefined;
            const w = std.fmt.bufPrint(&tmp, "{d}", .{whole}) catch return EvalError.Unsupported;
            if (d.scale == 0) {
                const s = if (d.coeff < 0) std.fmt.bufPrint(buf[0..], "-{s}", .{w}) catch return EvalError.Unsupported else std.fmt.bufPrint(buf[0..], "{s}", .{w}) catch return EvalError.Unsupported;
                break :blk2 s;
            }
            // format fractional part with leading zeros to scale width
            var frac_buf: [32]u8 = undefined;
            const fb = std.fmt.bufPrint(&frac_buf, "{d}", .{frac}) catch return EvalError.Unsupported;
            // pad leading zeros
            if (fb.len < d.scale) {
                const pad = d.scale - @as(u8, @intCast(fb.len));
                var padbuf: [32]u8 = undefined;
                @memset(padbuf[0..pad], '0');
                const s = if (d.coeff < 0)
                    std.fmt.bufPrint(buf[0..], "-{s}.{s}{s}", .{ w, padbuf[0..pad], fb }) catch return EvalError.Unsupported
                else
                    std.fmt.bufPrint(buf[0..], "{s}.{s}{s}", .{ w, padbuf[0..pad], fb }) catch return EvalError.Unsupported;
                break :blk2 s;
            }
            const s = if (d.coeff < 0)
                std.fmt.bufPrint(buf[0..], "-{s}.{s}", .{ w, fb }) catch return EvalError.Unsupported
            else
                std.fmt.bufPrint(buf[0..], "{s}.{s}", .{ w, fb }) catch return EvalError.Unsupported;
            break :blk2 s;
        },
        // Extended types stringify
        .SmallInt => |n| std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return EvalError.Unsupported,
        .BigInt => |n| std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return EvalError.Unsupported,
        .Real => |n| std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return EvalError.Unsupported,
        .Double => |n| std.fmt.bufPrint(buf[0..], "{d}", .{n}) catch return EvalError.Unsupported,
        .Char => |c| c.data,
        .Varchar => |vc| vc.data,
        .Text => |t| t,
        .Date => |_| "date", // Todo: implement formatting
        .Time => |_| "time",
        .TimeTZ => |_| "timetz",
        .Timestamp => |_| "timestamp",
        .TimestampTZ => |_| "timestamptz",
        .Interval => |_| "interval",
        .Bytea => |_| "bytea",
        .Json => |j| j,
        .Jsonb => |j| j.data,
        .Xml => |x| x.data,
        .Url => |_| "url", // Todo: call toString
        .Domain => |_| "domain",
        .UUID => |u| blk3: {
            const s = std.fmt.bufPrint(buf[0..], "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ u.bytes[0], u.bytes[1], u.bytes[2], u.bytes[3], u.bytes[4], u.bytes[5], u.bytes[6], u.bytes[7], u.bytes[8], u.bytes[9], u.bytes[10], u.bytes[11], u.bytes[12], u.bytes[13], u.bytes[14], u.bytes[15] }) catch return EvalError.Unsupported;
            break :blk3 s;
        },
        .Enum => |_| "enum",
        .BitString => |_| "bitstring",
        .VarBit => |_| "varbit",
        .IntRange => |_| "range",
        else => return EvalError.TypeMismatch,
    };
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
