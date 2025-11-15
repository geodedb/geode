//! Value Types Module - Shared value types for execution and evaluation
//!
//! CANARY: REQ=REQ-M5.2-VALUE-TYPES-001; FEATURE="Circular Dependency Resolution"; ASPECT=SharedTypes; STATUS=IMPL; OWNER=architecture; UPDATED=2025-11-13
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

// CANARY: REQ=REQ-M5.2-VALUE-TYPES-002; FEATURE="Error Handling"; ASPECT=EvalError; STATUS=IMPL; OWNER=value_types; UPDATED=2025-11-13
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

// CANARY: REQ=REQ-M5.2-VALUE-TYPES-003; FEATURE="Value Type"; ASPECT=CoreType; STATUS=IMPL; OWNER=value_types; UPDATED=2025-11-13
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
};

// CANARY: REQ=REQ-M5.2-VALUE-TYPES-004; FEATURE="Decimal Helper"; ASPECT=DecimalType; STATUS=IMPL; OWNER=value_types; UPDATED=2025-11-13
/// Helper struct for decimal arithmetic operations
pub const Dec = struct {
    coeff: i128,
    scale: u8,
};

// CANARY: REQ=REQ-M5.2-VALUE-TYPES-005; FEATURE="Environment"; ASPECT=VariableBinding; STATUS=IMPL; OWNER=value_types; UPDATED=2025-11-13
// CANARY: REQ=REQ-MEM-FIX-004; FEATURE="MemorySafety"; ASPECT=EnvOwnership; STATUS=IMPL; OWNER=eval; UPDATED=2025-10-25
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
            if (std.mem.eql(u8, self.param_names[i], name)) return self.param_values[i];
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

    // CANARY: REQ=REQ-GQL-089; FEATURE="ListComprehension"; ASPECT=Environment; STATUS=IMPLEMENTED; OWNER=eval; UPDATED=2025-10-17
    // CANARY: REQ=REQ-C4-001; FEATURE="MemoryLeakFix"; ASPECT=Environment; STATUS=IMPLEMENTED; OWNER=core; UPDATED=2025-10-17;
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
        // CANARY: REQ=REQ-MEM-FIX-005; FEATURE="MemorySafety"; ASPECT=OwnershipRespect; STATUS=IMPL; OWNER=eval; UPDATED=2025-10-25
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
        };
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

// CANARY: REQ=REQ-M5.2-VALUE-TYPES-006; FEATURE="Value Helpers"; ASPECT=NullCheck; STATUS=IMPL; OWNER=value_types; UPDATED=2025-11-13
/// Check if a value is Null
pub fn isNull(v: Value) bool {
    return v == .Null;
}

// CANARY: REQ=REQ-M5.2-VALUE-TYPES-007; FEATURE="Value Helpers"; ASPECT=Truthiness; STATUS=IMPL; OWNER=value_types; UPDATED=2025-11-13
/// Check if a value is truthy (used for boolean conversions)
pub fn truthy(v: Value) bool {
    return switch (v) {
        .Bool => |b| b,
        .Null => false,
        else => false,
    };
}

// CANARY: REQ=REQ-M5.2-VALUE-TYPES-008; FEATURE="Decimal Helpers"; ASPECT=DecimalConversion; STATUS=IMPL; OWNER=value_types; UPDATED=2025-11-13
/// Convert a Value to a decimal representation (helper for arithmetic)
pub fn toDec(v: Value) Dec {
    return switch (v) {
        .Decimal => |d| .{ .coeff = d.coeff, .scale = d.scale },
        .Int => |iv| .{ .coeff = @as(i128, iv), .scale = 0 },
        else => unreachable,
    };
}

// CANARY: REQ=REQ-M5.2-VALUE-TYPES-009; FEATURE="Value Helpers"; ASPECT=Equality; STATUS=IMPL; OWNER=value_types; UPDATED=2025-11-13
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
        .Map => false, // Map equality comparison not implemented
        .ExtValue => false, // ExtValue equality comparison not implemented
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
    };
}

// CANARY: REQ=REQ-M5.2-VALUE-TYPES-010; FEATURE="Decimal Helpers"; ASPECT=Power10; STATUS=IMPL; OWNER=value_types; UPDATED=2025-11-13
/// Calculate 10^scale for decimal arithmetic
fn pow10(scale: u8) i128 {
    var p: i128 = 1;
    var i: u8 = 0;
    while (i < scale) : (i += 1) p *= 10;
    return p;
}

// CANARY: REQ=REQ-M5.2-VALUE-TYPES-011; FEATURE="Value Helpers"; ASPECT=Stringify; STATUS=IMPL; OWNER=value_types; UPDATED=2025-11-13
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
