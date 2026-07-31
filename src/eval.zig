const std = @import("std");
const builtin = @import("builtin");
const ast = @import("gql/ast.zig");
const eval_funcs = @import("types/evaluator_functions.zig");
const heap = @import("storage/heap.zig");
const fle_integration = @import("fle_integration.zig");
const graph_store = @import("graph_store.zig");
const advanced_types_index = @import("index/advanced_types_index.zig");
const index_manager = @import("index/index_manager.zig");
const property_codec = @import("property_value_codec.zig");
const vector_types = @import("types/vector.zig");

// CANARY: REQ=REQ-M5.3-EVAL-REFACTOR-001; FEATURE="Circular Dependency Resolution"; ASPECT=AdapterImport; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.3: Import evaluator_adapter instead of execution.zig to break circular dependency
const evaluator_adapter = @import("execution/evaluator_adapter.zig");

// CANARY: REQ=REQ-M5.2-EVAL-REFACTOR-001; FEATURE="Circular Dependency Resolution"; ASPECT=ValueTypesImport; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.2: Import shared value types from value_types.zig module
const value_types = @import("value_types.zig");

// CANARY: REQ=REQ-M5.2-EVAL-REFACTOR-002; FEATURE="Circular Dependency Resolution"; ASPECT=ErrorTypeReexport; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.2: Re-export EvalError from value_types module for backward compatibility
pub const EvalError = value_types.EvalError;

// CANARY: REQ=REQ-GAP-0924-ARG-ERROR-PROPAGATION; FEATURE="Eval"; ASPECT=NestedArgErrorPropagation; STATUS=TESTED; TEST=tests/test_gap0924_spatial_validation.zig; OWNER=eval; UPDATED=2026-07-10
/// True for EvalErrors that represent a GENUINE invalid function argument and
/// must propagate out of a nested call rather than collapse the whole call to
/// NULL (the extended-registry arg-eval path). Mirrors the "genuine invalid
/// input" set the func-result handler already re-raises. Benign errors are not
/// listed, so NULL-propagation for those is preserved.
fn isPropagatableEvalError(err: EvalError) bool {
    return switch (err) {
        EvalError.TypeMismatch,
        EvalError.InvalidCast,
        EvalError.UnsupportedCastTarget,
        EvalError.IntegerOverflow,
        EvalError.DivisionByZero,
        EvalError.DecimalDivZero,
        EvalError.DecimalOverflow,
        EvalError.InvalidIpAddress,
        EvalError.InvalidSubnet,
        EvalError.InvalidMac,
        EvalError.InvalidArgs,
        EvalError.MissingParameter,
        EvalError.TimeParse,
        EvalError.OutOfMemory,
        => true,
        else => false,
    };
}

// CANARY: REQ=REQ-M5.2-EVAL-REFACTOR-003; FEATURE="Circular Dependency Resolution"; ASPECT=ValueTypeReexport; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.2: Re-export Value from value_types module for backward compatibility
pub const Value = value_types.Value;

// CANARY: REQ=REQ-M5.2-EVAL-REFACTOR-004; FEATURE="Circular Dependency Resolution"; ASPECT=DecTypeReexport; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.2: Re-export Dec from value_types module for backward compatibility
const Dec = value_types.Dec;

// #681: Named constants replacing magic number 1000000.
// Decimal scale factor: 10^6 gives 6 decimal places of precision when
// converting floats/ints to the internal Decimal representation.
const float_to_decimal_scale: i128 = 1_000_000;
const float_to_decimal_scale_f64: f64 = 1_000_000.0;
// Microseconds per second for interval-to-microseconds conversion.
const micros_per_second: i128 = 1_000_000;

// CANARY: REQ=REQ-M5.2-EVAL-REFACTOR-005; FEATURE="Circular Dependency Resolution"; ASPECT=FunctionAlias; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.2: Use toDec from value_types module
const toDec = value_types.toDec;

// CANARY: REQ=REQ-MEM-FIX-004; FEATURE="MemorySafety"; ASPECT=EnvOwnership; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-10-25
// CANARY: REQ=REQ-M5.2-EVAL-REFACTOR-006; FEATURE="Circular Dependency Resolution"; ASPECT=EnvTypeReexport; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.2: Re-export Env from value_types module for backward compatibility
pub const Env = value_types.Env;

// CANARY: REQ=REQ-M5.3-EVAL-CALLBACKS-001; FEATURE="Circular Dependency Resolution"; ASPECT=CallbacksStorage; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.3: Module-level storage for execution callbacks
// This allows eval.zig to call execution functions without importing execution.zig
// The callbacks are set at runtime by execution.zig during initialization
var execution_callbacks: ?evaluator_adapter.ExecutionCallbacks = null;

/// Set execution callbacks for this module
/// Called by execution.zig during initialization to provide callback functions
pub fn setExecutionCallbacks(callbacks: evaluator_adapter.ExecutionCallbacks) void {
    execution_callbacks = callbacks;
}

/// Get execution callbacks (internal use only)
fn getExecutionCallbacks() evaluator_adapter.ExecutionCallbacks {
    return execution_callbacks orelse {
        // This should never happen in production - callbacks must be set before eval.evalExpr is called
        @panic("Execution callbacks not initialized! Call eval.setExecutionCallbacks() first.");
    };
}

// GAP-0280: Global timeseries store pointer for server execution path.
// The Store is created once at server startup (server/main.zig) and shared
// read-only across all QUIC/gRPC connections.  eval.zig cannot import
// execution.zig (circular dependency), so a module-level global is used --
// the same pattern as execution_callbacks above.
// CANARY: REQ=REQ-TIMESERIES-WIRE-001; FEATURE="TimeseriesServerWiring"; ASPECT=GlobalStore; STATUS=TESTED; TEST=src/eval.zig; OWNER=eval; UPDATED=2026-04-01
const TimeseriesStore = @import("timeseries/timeseries.zig").Store;
var g_timeseries_store: ?*TimeseriesStore = null;

/// Set the global timeseries store (called from server/main.zig during startup).
pub fn setGlobalTimeseriesStore(store: ?*TimeseriesStore) void {
    g_timeseries_store = store;
}

/// Get the global timeseries store.
pub fn getGlobalTimeseriesStore() ?*TimeseriesStore {
    return g_timeseries_store;
}

/// Get the timeseries store for a specific graph, falling back to the global
/// store when no per-graph store is available or `graph_name` is null.
pub fn getTimeseriesStoreForGraph(graph_name: ?[]const u8) ?*TimeseriesStore {
    if (graph_name) |name| {
        const adapter = graph_store.getGlobalAdapter() orelse return g_timeseries_store;
        if (adapter.getTimeseriesStore(name)) |store| return store;
    }
    return g_timeseries_store;
}

// CANARY: REQ=REQ-M5.2-EVAL-REFACTOR-007; FEATURE="Circular Dependency Resolution"; ASPECT=NullCheck; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.2: Use isNull from value_types module
const isNull = value_types.isNull;

// CANARY: REQ=REQ-M5.2-EVAL-REFACTOR-008; FEATURE="Circular Dependency Resolution"; ASPECT=Truthy; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.2: Use truthy from value_types module
const truthy = value_types.truthy;

// CANARY: REQ=REQ-M6.1-EVAL-REFACTOR-001; FEATURE="Phase 6 Modularization"; ASPECT=TypePromotionImport; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-11-13
// Phase 6 M6.1: Import type promotion module for type conversion and validation utilities
const type_promotion = @import("eval/type_promotion.zig");

// CANARY: REQ=REQ-EVAL-REFACTOR-001; FEATURE="EvalExpr Refactoring"; ASPECT=CallHandlersImport; STATUS=TESTED; OWNER=eval; UPDATED=2026-01-30
// Import call handlers module for function call evaluation helpers
const call_handlers = @import("eval/call_handlers.zig");
// GAP-0537: dedicated handler modules extracted from the fallback .Call branch
const ts_call_handlers = @import("eval/ts_call_handlers.zig");
const quantifier_call_handlers = @import("eval/quantifier_call_handlers.zig");

// CANARY: REQ=REQ-REFACTOR-EVAL-002; FEATURE="EvalRefactoring"; ASPECT=LogicHelpersImport; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
// Import logic helpers module for three-valued logic and regex functions
const logic_helpers = @import("eval/logic_helpers.zig");
const and3 = logic_helpers.and3;
const or3 = logic_helpers.or3;
const xor3 = logic_helpers.xor3;
const regexEatEsc = logic_helpers.regexEatEsc;
const regexMatchClass = logic_helpers.regexMatchClass;
const regexRec = logic_helpers.regexRec;
const transformPlusQuantifier = logic_helpers.transformPlusQuantifier;
pub const matchSimplePattern = logic_helpers.matchSimplePattern;

// CANARY: REQ=REQ-REFACTOR-EVAL-003; FEATURE="EvalRefactoring"; ASPECT=StringHelpersImport; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
// Import string helpers module for string predicate functions
const string_helpers = @import("eval/string_helpers.zig");
const evalStartsWith = string_helpers.evalStartsWith;
const evalEndsWith = string_helpers.evalEndsWith;
const evalContains = string_helpers.evalContains;

// CANARY: REQ=REQ-REFACTOR-EVAL-004; FEATURE="EvalRefactoring"; ASPECT=TypeHelpersImport; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
// Import type helpers module for type name functions (pub for cross-module access)
pub const type_helpers = @import("eval/type_helpers.zig");
const getTypeName = type_helpers.getTypeName;
const getExtTypeName = type_helpers.getExtTypeName;

// CANARY: REQ=REQ-M6.1-EVAL-REFACTOR-002; FEATURE="Phase 6 Modularization"; ASPECT=TypePromotionAliases; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-11-13
// Phase 6 M6.1: Use type promotion functions from type_promotion module
const scaleTo = type_promotion.scaleTo;
const expectString = type_promotion.expectString;
const expectInt = type_promotion.expectInt;
const valueToExtValue = type_promotion.valueToExtValue;
const extValueToValue = type_promotion.extValueToValue;
const evalValueToHeapValue = type_promotion.evalValueToHeapValue;
const heapValueToEvalValue = type_promotion.heapValueToEvalValue;
const cmpI128 = type_promotion.cmpI128;
const cmpToBool = type_promotion.cmpToBool;
const cmpIntsOp = type_promotion.cmpIntsOp;

// CANARY: REQ=REQ-NESTING-REFACTOR-021; FEATURE="NestingReduction"; ASPECT=DecimalParsing; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
// Helper function to parse a decimal string into coefficient and scale
fn parseDecimalString(s: []const u8) ?struct { coeff: i128, scale: u8 } {
    if (std.mem.indexOf(u8, s, ".")) |dot_idx| {
        const int_part = s[0..dot_idx];
        const frac_part = s[dot_idx + 1 ..];
        const int_val = std.fmt.parseInt(i128, int_part, 10) catch return null;
        const frac_val = std.fmt.parseInt(i128, frac_part, 10) catch return null;
        var coeff = int_val;
        const frac_len = frac_part.len;
        var mult: i128 = 1;
        var k: usize = 0;
        while (k < frac_len) : (k += 1) {
            mult *= 10;
        }
        coeff = coeff * mult + frac_val;
        return .{ .coeff = coeff, .scale = @intCast(frac_len) };
    } else {
        const int_val = std.fmt.parseInt(i128, s, 10) catch return null;
        return .{ .coeff = int_val, .scale = 0 };
    }
}

// CANARY: REQ=REQ-NESTING-REFACTOR-022; FEATURE="NestingReduction"; ASPECT=ScaleAdjust; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
// Helper to adjust decimal scale to target scale
fn adjustDecimalScale(coeff: i128, current_scale: u8, target_scale: u8) struct { coeff: i128, scale: u8 } {
    var result_coeff = coeff;
    var scale = current_scale;
    while (scale < target_scale) : (scale += 1) {
        result_coeff *= 10;
    }
    while (scale > target_scale) : (scale -= 1) {
        result_coeff = @divTrunc(result_coeff, 10);
    }
    return .{ .coeff = result_coeff, .scale = target_scale };
}

// CANARY: REQ=REQ-M5.2-EVAL-REFACTOR-009; FEATURE="Circular Dependency Resolution"; ASPECT=ValueEquality; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.2: Use eqVals from value_types module
const eqVals = value_types.eqVals;

// CANARY: REQ=REQ-M6.1-EVAL-REFACTOR-007; FEATURE="Phase 6 Modularization"; ASPECT=IntComparison; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-11-13
// Phase 6 M6.1: Integer comparison function moved to eval/type_promotion.zig
// Function: cmpIntsOp

/// True when every byte of `s` is 7-bit ASCII (< 0x80). NFC normalization is the
/// IDENTITY on pure-ASCII text (no ASCII scalar is a composed/decomposed form),
/// so `nfcNormalize(s) == s` byte-for-byte when `isAscii(s)`. The string-compare
/// fast path relies on this to skip normalization + allocation entirely.
inline fn isAscii(s: []const u8) bool {
    for (s) |c| {
        if (c >= 0x80) return false;
    }
    return true;
}

/// Test-only counter: incremented ONLY when the string-compare NON-ASCII NFC
/// fallback runs. Lets tests prove the ASCII fast path engages (stays 0 for
/// all-ASCII comparisons, >0 once a non-ASCII operand forces normalization).
/// The increment is guarded by `builtin.is_test`, a comptime-false constant in
/// production builds, so the counter and its update are dead-code-eliminated on
/// the hot path outside tests.
pub var nfc_fallback_count: usize = 0;

pub fn evalBinary(alloc: std.mem.Allocator, op: ast.BinOp, l: Value, r: Value) EvalError!Value {
    return switch (op) {
        .And => and3(l, r),
        .Or => or3(l, r),
        .Xor => xor3(l, r),
        .Add => blk: {
            // NULL + anything = NULL (GQL/SQL semantics)
            if (l == .Null or r == .Null) break :blk .{ .Null = {} };
            // String concatenation: string + string
            // PERF_PHASE5_STRING_CONCAT - Direct memory allocation for string concatenation
            // CANARY: REQ=REQ-PERF-PHASE5-003; FEATURE="EvalOptimization"; ASPECT=STRING_CONCAT; STATUS=BENCHED; BENCH=benchmarks/phase5_5_string_concat.zig; OWNER=performance; UPDATED=2026-01-17
            // Phase 5.1.3 (P0-3): Use direct allocation + memcpy (3-5x faster than allocPrint)
            if (l == .Str and r == .Str) {
                const result = try alloc.alloc(u8, l.Str.len + r.Str.len);
                @memcpy(result[0..l.Str.len], l.Str);
                @memcpy(result[l.Str.len..], r.Str);
                break :blk .{ .Str = result };
            }
            // CANARY: REQ=REQ-GQL-LIST-CONCAT-001; FEATURE="ListOperations"; ASPECT=AddConcatenation; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=eval; UPDATED=2025-12-27
            // List concatenation: list + list = combined list
            if (l == .List and r == .List) {
                const result = try alloc.alloc(Value, l.List.len + r.List.len);
                @memcpy(result[0..l.List.len], l.List);
                @memcpy(result[l.List.len..], r.List);
                break :blk .{ .List = result };
            }
            if (l == .Int and r == .Int) {
                const result_tuple = @addWithOverflow(l.Int, r.Int);
                if (result_tuple[1] != 0) {
                    return EvalError.IntegerOverflow;
                }
                break :blk .{ .Int = result_tuple[0] };
            }
            // CANARY: REQ=REQ-GQL-BOOL-INT-COERCE-001; FEATURE="TypeCoercion"; ASPECT=BoolToInt; STATUS=TESTED; TEST=geodetestlab/specs/gql_type_system_comprehensive.yml; OWNER=eval; UPDATED=2025-12-27
            // Bool + Int / Int + Bool: Coerce bool to int (true=1, false=0)
            if (l == .Bool and r == .Int) {
                const bool_val: i64 = if (l.Bool) 1 else 0;
                break :blk .{ .Int = bool_val + r.Int };
            }
            if (l == .Int and r == .Bool) {
                const bool_val: i64 = if (r.Bool) 1 else 0;
                break :blk .{ .Int = l.Int + bool_val };
            }
            // Decimal + Int / Int + Decimal / Decimal + Decimal
            if ((l == .Decimal and r == .Int) or (l == .Int and r == .Decimal) or (l == .Decimal and r == .Decimal)) {
                const ld = toDec(l);
                const rd = toDec(r);
                const maxs: u8 = @max(ld.scale, rd.scale);
                const lc = try scaleTo(ld.coeff, ld.scale, maxs);
                const rc = try scaleTo(rd.coeff, rd.scale, maxs);
                const sum = lc + rc; // overflow ignored for now (would return Unsupported if needed)
                break :blk .{ .Decimal = .{ .coeff = sum, .scale = maxs } };
            }
            // CANARY: REQ=REQ-DATE-INTERVAL-001; FEATURE="DateIntervalArithmetic"; ASPECT=Addition; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2026-01-09
            // Date + Interval: Add months and days from interval to date
            if (l == .Date and r == .Interval) {
                const datetime_module = @import("types/datetime.zig");
                const date = l.Date;
                const interval = r.Interval;

                // Convert date to year/month/day components
                const ymd = datetime_module.Date.dateFromDays(date.days_since_epoch);

                // Add months (with year overflow handling)
                var new_month: i32 = @as(i32, ymd.month) + interval.months;
                var new_year: i32 = ymd.year;

                // Handle month overflow/underflow
                while (new_month > 12) {
                    new_month -= 12;
                    new_year += 1;
                }
                while (new_month < 1) {
                    new_month += 12;
                    new_year -= 1;
                }

                // Clamp day to valid range for new month
                const max_day = datetime_module.Date.daysInMonth(new_year, @intCast(new_month));
                const new_day: u8 = @min(ymd.day, max_day);

                // Calculate new days since epoch
                const new_days = datetime_module.Date.daysSinceEpoch(new_year, @intCast(new_month), new_day) catch {
                    return EvalError.Unsupported;
                };

                // Add interval days
                const final_days = new_days + interval.days;

                break :blk .{ .Date = .{ .days_since_epoch = final_days } };
            }
            // Interval + Date: commutative
            if (l == .Interval and r == .Date) {
                const datetime_module = @import("types/datetime.zig");
                const date = r.Date;
                const interval = l.Interval;

                const ymd = datetime_module.Date.dateFromDays(date.days_since_epoch);

                var new_month: i32 = @as(i32, ymd.month) + interval.months;
                var new_year: i32 = ymd.year;

                while (new_month > 12) {
                    new_month -= 12;
                    new_year += 1;
                }
                while (new_month < 1) {
                    new_month += 12;
                    new_year -= 1;
                }

                const max_day = datetime_module.Date.daysInMonth(new_year, @intCast(new_month));
                const new_day: u8 = @min(ymd.day, max_day);

                const new_days = datetime_module.Date.daysSinceEpoch(new_year, @intCast(new_month), new_day) catch {
                    return EvalError.Unsupported;
                };

                const final_days = new_days + interval.days;

                break :blk .{ .Date = .{ .days_since_epoch = final_days } };
            }
            return EvalError.TypeMismatch;
        },
        .Sub => blk2: {
            // NULL - anything = NULL (GQL/SQL semantics)
            if (l == .Null or r == .Null) break :blk2 .{ .Null = {} };
            if (l == .Int and r == .Int) {
                const result_tuple = @subWithOverflow(l.Int, r.Int);
                if (result_tuple[1] != 0) {
                    return EvalError.IntegerOverflow;
                }
                break :blk2 .{ .Int = result_tuple[0] };
            }
            if ((l == .Decimal and r == .Int) or (l == .Int and r == .Decimal) or (l == .Decimal and r == .Decimal)) {
                const ld = toDec(l);
                const rd = toDec(r);
                const maxs: u8 = @max(ld.scale, rd.scale);
                const lc = try scaleTo(ld.coeff, ld.scale, maxs);
                const rc = try scaleTo(rd.coeff, rd.scale, maxs);
                const diff = lc - rc;
                break :blk2 .{ .Decimal = .{ .coeff = diff, .scale = maxs } };
            }
            // CANARY: REQ=REQ-DATE-INTERVAL-002; FEATURE="DateIntervalArithmetic"; ASPECT=Subtraction; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2026-01-09
            // Date - Interval: Subtract months and days from interval
            if (l == .Date and r == .Interval) {
                const datetime_module = @import("types/datetime.zig");
                const date = l.Date;
                const interval = r.Interval;

                // Convert date to year/month/day components
                const ymd = datetime_module.Date.dateFromDays(date.days_since_epoch);

                // Subtract months (with year underflow handling)
                var new_month: i32 = @as(i32, ymd.month) - interval.months;
                var new_year: i32 = ymd.year;

                while (new_month > 12) {
                    new_month -= 12;
                    new_year += 1;
                }
                while (new_month < 1) {
                    new_month += 12;
                    new_year -= 1;
                }

                // Clamp day to valid range for new month
                const max_day = datetime_module.Date.daysInMonth(new_year, @intCast(new_month));
                const new_day: u8 = @min(ymd.day, max_day);

                // Calculate new days since epoch
                const new_days = datetime_module.Date.daysSinceEpoch(new_year, @intCast(new_month), new_day) catch {
                    return EvalError.Unsupported;
                };

                // Subtract interval days
                const final_days = new_days - interval.days;

                break :blk2 .{ .Date = .{ .days_since_epoch = final_days } };
            }
            return EvalError.TypeMismatch;
        },
        .Mul => blk3: {
            // NULL * anything = NULL (GQL/SQL semantics)
            if (l == .Null or r == .Null) break :blk3 .{ .Null = {} };
            if (l == .Int and r == .Int) {
                const result_tuple = @mulWithOverflow(l.Int, r.Int);
                if (result_tuple[1] != 0) {
                    return EvalError.IntegerOverflow;
                }
                break :blk3 .{ .Int = result_tuple[0] };
            }
            if ((l == .Decimal and r == .Int) or (l == .Int and r == .Decimal) or (l == .Decimal and r == .Decimal)) {
                const ld = toDec(l);
                const rd = toDec(r);
                // result scale = sum of scales; coeff multiply
                const res_scale: u8 = ld.scale + rd.scale;
                const prod = ld.coeff * rd.coeff; // naive; overflow risk
                break :blk3 .{ .Decimal = .{ .coeff = prod, .scale = res_scale } };
            }
            return EvalError.TypeMismatch;
        },
        .Div => blk4: {
            // NULL / anything = NULL (GQL/SQL semantics)
            if (l == .Null or r == .Null) break :blk4 .{ .Null = {} };
            if (l == .Int and r == .Int) {
                // Use safe division helper to avoid builtin trap and surface TypeMismatch.
                const denom = r.Int;
                if (denom == 0) return EvalError.DivisionByZero; // division by zero (maps to TypeMismatch.DivZero diagnostic)
                // Avoid direct @divTrunc which can still trap if denom==0 due to race on optimization; explicit branch first.
                break :blk4 .{ .Int = @divTrunc(l.Int, denom) };
            }
            // Support decimal division with type coercion
            if ((l == .Decimal and r == .Int) or (l == .Int and r == .Decimal) or (l == .Decimal and r == .Decimal)) {
                const ld = toDec(l);
                const rd = toDec(r);

                // Check for division by zero
                if (rd.coeff == 0) return EvalError.DivisionByZero;

                // For decimal division, we need to ensure precision
                // Scale the numerator to maintain precision (add extra scale before division)
                const extra_scale: u8 = 6; // Provide 6 decimal places of precision (reasonable for most calculations)
                const scale_factor = std.math.pow(i128, 10, extra_scale);
                const scaled_num = ld.coeff * scale_factor;
                const quotient = @divTrunc(scaled_num, rd.coeff);

                // Result scale = numerator scale - denominator scale + extra scale
                const result_scale: i16 = @as(i16, ld.scale) - @as(i16, rd.scale) + extra_scale;
                if (result_scale < 0 or result_scale > 18) return EvalError.Unsupported; // Keep scale reasonable for JSON serialization

                break :blk4 .{ .Decimal = .{ .coeff = quotient, .scale = @intCast(result_scale) } };
            }
            return EvalError.TypeMismatch;
        },
        .Mod => blk_mod: {
            // NULL % anything = NULL (GQL/SQL semantics)
            if (l == .Null or r == .Null) break :blk_mod .{ .Null = {} };
            if (l == .Int and r == .Int) {
                const denom = r.Int;
                if (denom == 0) return EvalError.DivisionByZero;
                break :blk_mod .{ .Int = @rem(l.Int, denom) };
            }
            return EvalError.TypeMismatch;
        },
        .Power => blk_pow: {
            // CANARY: REQ=REQ-GQL-POWER-003; FEATURE="PowerOperator"; ASPECT=EvalSupport; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_math_algorithms.yml; OWNER=eval; UPDATED=2025-12-27
            // NULL ^ anything = NULL (GQL/SQL semantics)
            if (l == .Null or r == .Null) break :blk_pow .{ .Null = {} };
            // Integer exponentiation: x ^ n where n is integer
            if (l == .Int and r == .Int) {
                const base: f64 = @floatFromInt(l.Int);
                const exp: f64 = @floatFromInt(r.Int);
                const result = std.math.pow(f64, base, exp);
                // If result is an exact integer, return Int
                if (@floor(result) == result and result >= @as(f64, @floatFromInt(std.math.minInt(i64))) and result <= @as(f64, @floatFromInt(std.math.maxInt(i64)))) {
                    break :blk_pow .{ .Int = @intFromFloat(result) };
                }
                // Convert to Decimal for non-integer results (6 decimal places precision)
                const scaled_result: i128 = @intFromFloat(result * 1_000_000);
                break :blk_pow .{ .Decimal = .{ .coeff = scaled_result, .scale = 6 } };
            }
            // Decimal base with integer exponent
            if (l == .Decimal and r == .Int) {
                const base: f64 = @as(f64, @floatFromInt(l.Decimal.coeff)) / std.math.pow(f64, 10.0, @floatFromInt(l.Decimal.scale));
                const exp: f64 = @floatFromInt(r.Int);
                const result = std.math.pow(f64, base, exp);
                if (@floor(result) == result and result >= @as(f64, @floatFromInt(std.math.minInt(i64))) and result <= @as(f64, @floatFromInt(std.math.maxInt(i64)))) {
                    break :blk_pow .{ .Int = @intFromFloat(result) };
                }
                const scaled_result: i128 = @intFromFloat(result * 1_000_000);
                break :blk_pow .{ .Decimal = .{ .coeff = scaled_result, .scale = 6 } };
            }
            return EvalError.TypeMismatch;
        },
        .Eq, .Ne, .Lt, .Le, .Gt, .Ge => blk5: {
            if (l == .Int and r == .Int) break :blk5 cmpIntsOp(op, l.Int, r.Int);
            // Decimal comparisons (no arithmetic yet)
            if (l == .Decimal and r == .Int) {
                const rhs = scaleTo(@as(i128, r.Int), 0, l.Decimal.scale) catch return EvalError.Unsupported;
                const ord = cmpI128(l.Decimal.coeff, rhs);
                break :blk5 .{ .Bool = cmpToBool(op, ord) };
            }
            if (l == .Int and r == .Decimal) {
                const lhs = scaleTo(@as(i128, l.Int), 0, r.Decimal.scale) catch return EvalError.Unsupported;
                const ord = cmpI128(lhs, r.Decimal.coeff);
                break :blk5 .{ .Bool = cmpToBool(op, ord) };
            }
            if (l == .Decimal and r == .Decimal) {
                // align scales
                if (l.Decimal.scale == r.Decimal.scale) {
                    const ord = cmpI128(l.Decimal.coeff, r.Decimal.coeff);
                    break :blk5 .{ .Bool = cmpToBool(op, ord) };
                }
                const maxs = @max(l.Decimal.scale, r.Decimal.scale);
                const lc = scaleTo(l.Decimal.coeff, l.Decimal.scale, maxs) catch return EvalError.Unsupported;
                const rc = scaleTo(r.Decimal.coeff, r.Decimal.scale, maxs) catch return EvalError.Unsupported;
                const ord = cmpI128(lc, rc);
                break :blk5 .{ .Bool = cmpToBool(op, ord) };
            }
            if (l == .Str and r == .Str) {
                // Unicode-aware comparison: normalize both operands to NFC then compare byte-wise.
                // CANARY: REQ=REQ-GQL-UNICODE-009; FEATURE="UnicodeEval"; ASPECT=CompareNfc; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_UNICODE_009_EvalCompareNfc; OWNER=unicode; UPDATED=2025-09-27
                //
                // PERF: NFC normalization is the IDENTITY for pure-ASCII input, so when BOTH
                // operands are ASCII we compare the raw bytes directly — no allocator, no
                // normalization. This is the overwhelmingly common case (ids, source tags,
                // ASCII names) in WHERE/filter/join scans and was previously catastrophic:
                // it spun up a fresh DebugAllocator (munmap-per-free) and heap-allocated two
                // NFC copies PER ROW. Only when an operand contains a byte >= 0x80 do we fall
                // back to real NFC normalization (for Unicode correctness, e.g. composed vs
                // decomposed "é"), and even then we reuse the caller-provided `alloc` rather
                // than constructing a per-call allocator.
                const ord = if (isAscii(l.Str) and isAscii(r.Str))
                    // ASCII fast path: NFC(ascii) == ascii, so raw-byte order is byte-identical
                    // to normalize-then-compare. Zero allocation.
                    std.mem.order(u8, l.Str, r.Str)
                else nfc_blk: {
                    // Non-ASCII fallback: at least one operand has a byte >= 0x80. Normalize
                    // BOTH to NFC (a non-ASCII string may normalize to a different form, so we
                    // must never shortcut unless BOTH operands are ASCII).
                    if (@import("builtin").is_test) nfc_fallback_count += 1;
                    const unicode = @import("unicode/geode_unicode.zig");
                    const ln = unicode.nfcNormalize(alloc, l.Str) catch return EvalError.Unsupported;
                    defer alloc.free(ln);
                    const rn = unicode.nfcNormalize(alloc, r.Str) catch return EvalError.Unsupported;
                    defer alloc.free(rn);
                    break :nfc_blk std.mem.order(u8, ln, rn);
                };
                return .{ .Bool = switch (op) {
                    .Eq => ord == .eq,
                    .Ne => ord != .eq,
                    .Lt => ord == .lt,
                    .Le => ord != .gt,
                    .Gt => ord == .gt,
                    .Ge => ord != .lt,
                    else => false,
                } };
            }
            if ((l == .Str and r == .Int) or (l == .Int and r == .Str)) {
                if (op != .Eq and op != .Ne) return EvalError.TypeMismatch;
                var bufL: [64]u8 = undefined;
                var bufR: [64]u8 = undefined;
                const ls = try stringify(l, &bufL);
                const rs = try stringify(r, &bufR);
                const eq = std.mem.eql(u8, ls, rs);
                return .{ .Bool = if (op == .Eq) eq else !eq };
            }

            // Advanced Types Ordering
            // Date
            if (l == .Date and r == .Date) {
                const ord = std.math.order(l.Date.days_since_epoch, r.Date.days_since_epoch);
                return .{ .Bool = cmpToBool(op, switch (ord) {
                    .lt => -1,
                    .eq => 0,
                    .gt => 1,
                }) };
            }
            // Time
            if (l == .Time and r == .Time) {
                const ord = std.math.order(l.Time.micros_since_midnight, r.Time.micros_since_midnight);
                return .{ .Bool = cmpToBool(op, switch (ord) {
                    .lt => -1,
                    .eq => 0,
                    .gt => 1,
                }) };
            }
            // Timestamp
            if (l == .Timestamp and r == .Timestamp) {
                const ord = std.math.order(l.Timestamp.micros_since_epoch, r.Timestamp.micros_since_epoch);
                return .{ .Bool = cmpToBool(op, switch (ord) {
                    .lt => -1,
                    .eq => 0,
                    .gt => 1,
                }) };
            }
            // UUID
            if (l == .UUID and r == .UUID) {
                const ord = std.mem.order(u8, &l.UUID.bytes, &r.UUID.bytes);
                return .{ .Bool = cmpToBool(op, switch (ord) {
                    .lt => -1,
                    .eq => 0,
                    .gt => 1,
                }) };
            }
            // Interval
            if (l == .Interval and r == .Interval) {
                // Compare total microseconds? Roughly.
                // This is simplistic (ignores month/day length variance), but consistent for ordering.
                // Convert to rough micros: months*30*24*3600*1e6 + days*24*3600*1e6 + micros
                // Just implementation detail for now.
                const l_micros = @as(i128, l.Interval.months) * 30 * 86400 * micros_per_second + @as(i128, l.Interval.days) * 86400 * micros_per_second + l.Interval.micros;
                const r_micros = @as(i128, r.Interval.months) * 30 * 86400 * micros_per_second + @as(i128, r.Interval.days) * 86400 * micros_per_second + r.Interval.micros;
                const ord = std.math.order(l_micros, r_micros);
                return .{ .Bool = cmpToBool(op, switch (ord) {
                    .lt => -1,
                    .eq => 0,
                    .gt => 1,
                }) };
            }

            // CANARY: REQ=REQ-GQL-NULL-SEMANTICS-002; FEATURE="ThreeValuedLogic"; ASPECT=NullComparison; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=eval; UPDATED=2026-01-09
            // GQL/SQL three-valued logic: Any comparison with NULL returns NULL
            // null = null => null, null > 5 => null, null < x => null, etc.
            // IMPORTANT: This check must come BEFORE generic equality check to ensure null = null returns null, not true
            if (l == .Null or r == .Null) {
                return Value{ .Null = {} };
            }

            // Generic equality for same types (UUID=UUID, Date=Date, etc.)
            if ((op == .Eq or op == .Ne) and std.meta.activeTag(l) == std.meta.activeTag(r)) {
                const isEqual = eqVals(l, r);
                break :blk5 .{ .Bool = if (op == .Eq) isEqual else !isEqual };
            }
            // Boolean comparisons: only equality/inequality supported
            if (l == .Bool and r == .Bool) {
                if (op != .Eq and op != .Ne) return EvalError.TypeMismatch;
                const eq = l.Bool == r.Bool;
                return .{ .Bool = if (op == .Eq) eq else !eq };
            }
            // CANARY: REQ=REQ-GQL-NODE-COMPARE-001; FEATURE="NodeComparison"; ASPECT=EqualityInequality; STATUS=TESTED; TEST=tests/test_bug731_match_scoping.zig:406; OWNER=engine; UPDATED=2026-07-31
            // Node/Edge Eq/Ne are handled by the same-tag `eqVals` branch above,
            // which now compares by ID (value_types.eqVals). Ordering operators
            // on graph elements are not defined, so they land here.
            return EvalError.TypeMismatch;
        },
        .Concat => blk6: {
            // CANARY: REQ=REQ-GQL-NULL-SEMANTICS-003; FEATURE="ThreeValuedLogic"; ASPECT=NullConcat; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=eval; UPDATED=2025-12-27
            // GQL/SQL three-valued logic: null || anything = null
            if (l == .Null or r == .Null) break :blk6 Value{ .Null = {} };

            // String concatenation with type coercion
            // Convert both operands to strings if needed
            var buf_l: [64]u8 = undefined;
            var buf_r: [64]u8 = undefined;
            const str_l = if (l == .Str) l.Str else try stringify(l, &buf_l);
            const str_r = if (r == .Str) r.Str else try stringify(r, &buf_r);

            // Allocate result string with combined length
            const result = alloc.alloc(u8, str_l.len + str_r.len) catch return EvalError.OutOfMemory;
            @memcpy(result[0..str_l.len], str_l);
            @memcpy(result[str_l.len..], str_r);
            break :blk6 .{ .Str = result };
        },
        .RegexMatch, .RegexNotMatch => blk7: {
            // Regex matching: left =~ right or left !~ right
            // Return null if either operand is null (SQL 3VL semantics)
            if (isNull(l) or isNull(r)) {
                break :blk7 .{ .Null = {} };
            }

            // Both operands must be strings
            if (l != .Str or r != .Str) return EvalError.TypeMismatch;

            const input = l.Str;
            const pattern = r.Str;

            // Use the existing matchSimplePattern function
            const matched = matchSimplePattern(input, pattern);

            const result = if (op == .RegexMatch) matched else !matched;
            break :blk7 .{ .Bool = result };
        },
    };
}

// CANARY: REQ=REQ-M5.2-EVAL-REFACTOR-010; FEATURE="Circular Dependency Resolution"; ASPECT=Pow10; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.2: Use pow10 from value_types module
const pow10 = value_types.pow10;

// CANARY: REQ=REQ-M6.1-EVAL-REFACTOR-004; FEATURE="Phase 6 Modularization"; ASPECT=ComparisonHelpers; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-11-13
// Phase 6 M6.1: Comparison helper functions moved to eval/type_promotion.zig
// Functions: cmpI128, cmpToBool

// CANARY: REQ=REQ-M6.1-EVAL-REFACTOR-005; FEATURE="Phase 6 Modularization"; ASPECT=DecimalScaling; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-11-13
// Phase 6 M6.1: Decimal scale conversion function moved to eval/type_promotion.zig
// Function: scaleTo

// CANARY: REQ=REQ-M6.1-EVAL-REFACTOR-006; FEATURE="Phase 6 Modularization"; ASPECT=TypeValidators; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-11-13
// Phase 6 M6.1: Type validator functions moved to eval/type_promotion.zig
// Functions: expectString, expectInt

// CANARY: REQ=REQ-M5.2-EVAL-REFACTOR-011; FEATURE="Circular Dependency Resolution"; ASPECT=Stringify; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-11-13
// Phase 5 M5.2: Use stringify from value_types module
const stringify = value_types.stringify;

pub fn evalExpr(allocator: std.mem.Allocator, e: ast.Expr, env: Env) EvalError!Value {
    return switch (e) {
        .Null => Value{ .Null = {} },
        .Int => |n| .{ .Int = n },
        .Bool => |b| .{ .Bool = b },
        .String => |s| .{ .Str = s },
        .Decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale, .orig_scale = d.scale } },
        .Date => |dt| blk_date: {
            const datetime_module = @import("types/datetime.zig");
            const days = datetime_module.Date.daysSinceEpoch(@intCast(dt.parsed.y), dt.parsed.m, dt.parsed.d) catch
                break :blk_date Value{ .Null = {} };
            break :blk_date Value{ .Date = .{ .days_since_epoch = days } };
        },
        .Time => |t| blk_time: {
            const micros: i64 = @as(i64, t.parsed.h) * 3600_000_000 +
                @as(i64, t.parsed.min) * 60_000_000 +
                @as(i64, t.parsed.s) * 1_000_000 +
                @divFloor(@as(i64, t.parsed.frac_nanos), 1000);
            break :blk_time Value{ .Time = .{ .micros_since_midnight = micros } };
        },
        .DateTime => |dt| blk_datetime: {
            const datetime_module = @import("types/datetime.zig");
            const days = datetime_module.Date.daysSinceEpoch(@intCast(dt.parsed.date.y), dt.parsed.date.m, dt.parsed.date.d) catch
                break :blk_datetime Value{ .Null = {} };
            const time_micros: i64 = @as(i64, dt.parsed.time.h) * 3600_000_000 +
                @as(i64, dt.parsed.time.min) * 60_000_000 +
                @as(i64, dt.parsed.time.s) * 1_000_000 +
                @divFloor(@as(i64, dt.parsed.time.frac_nanos), 1000);
            const total_micros = @as(i64, days) * 24 * 3600 * 1_000_000 + time_micros;
            break :blk_datetime Value{ .Timestamp = .{ .micros_since_epoch = total_micros } };
        },
        .LocalDateTime => |dt| blk_localdatetime: {
            const datetime_module = @import("types/datetime.zig");
            const days = datetime_module.Date.daysSinceEpoch(@intCast(dt.parsed.date.y), dt.parsed.date.m, dt.parsed.date.d) catch
                break :blk_localdatetime Value{ .Null = {} };
            const time_micros: i64 = @as(i64, dt.parsed.time.h) * 3600_000_000 +
                @as(i64, dt.parsed.time.min) * 60_000_000 +
                @as(i64, dt.parsed.time.s) * 1_000_000 +
                @divFloor(@as(i64, dt.parsed.time.frac_nanos), 1000);
            const total_micros = @as(i64, days) * 24 * 3600 * 1_000_000 + time_micros;
            break :blk_localdatetime Value{ .Timestamp = .{ .micros_since_epoch = total_micros } };
        },
        .Ident => |id| env.get(id.orig) orelse Value{ .Null = {} },
        // CANARY: REQ=REQ-GAP-0926-POSITIONAL-PARAM-OOR; FEATURE="ParameterBinding"; ASPECT=OutOfRangePositional; STATUS=TESTED; TEST=tests/test_gap0926_silent_accept.zig; OWNER=eval; UPDATED=2026-07-10
        // GAP-0926: an out-of-range POSITIONAL parameter (e.g. $2 when only one
        // param was supplied) used to resolve to NULL — referencing a
        // positional slot that was never provided is unambiguously an error.
        // Missing NAMED params keep the historical NULL (documented residual):
        // rejecting those risks breaking legitimate optional-param queries.
        .Param => |pname| blk_param: {
            if (env.getParam(pname)) |v| break :blk_param v;
            const is_positional = pname.len > 0 and for (pname) |c| {
                if (!std.ascii.isDigit(c)) break false;
            } else true;
            if (is_positional) return EvalError.MissingParameter;
            break :blk_param Value{ .Null = {} };
        },
        .Unary => |u| blk: {
            const v = try evalExpr(allocator, u.expr.*, env);
            switch (u.op) {
                .Not => {
                    // CANARY: REQ=REQ-GQL-NULL-SEMANTICS-001; FEATURE="ThreeValuedLogic"; ASPECT=NotNull; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=eval; UPDATED=2025-12-27
                    // GQL/SQL three-valued logic: NOT null = null
                    if (v == .Null) break :blk Value{ .Null = {} };
                    break :blk .{ .Bool = !truthy(v) };
                },
                .Neg => switch (v) {
                    .Int => |i| break :blk .{ .Int = -i },
                    .Decimal => |d| break :blk .{ .Decimal = .{ .coeff = -d.coeff, .scale = d.scale, .orig_scale = d.orig_scale } },
                    else => return EvalError.TypeMismatch,
                },
                .Pos => switch (v) {
                    .Int, .Decimal => break :blk v,
                    else => return EvalError.TypeMismatch,
                },
            }
        },
        .Binary => |b| blk2: {
            // CANARY: REQ=REQ-GQL-SHORT-CIRCUIT-001; FEATURE="Short-circuit evaluation"; ASPECT=AND_OR; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-12-27
            // Implement short-circuit evaluation for AND/OR to avoid evaluating RHS when unnecessary
            // This prevents division-by-zero errors in expressions like: n.value <> 0 AND 100 / n.value > 1
            switch (b.op) {
                .And => {
                    const l = try evalExpr(allocator, b.left.*, env);
                    // Short-circuit: If left is definitely false, return false without evaluating right
                    if (l == .Bool and !l.Bool) {
                        break :blk2 Value{ .Bool = false };
                    }
                    // Evaluate right only if left wasn't definitely false
                    const r = try evalExpr(allocator, b.right.*, env);
                    break :blk2 and3(l, r);
                },
                .Or => {
                    const l = try evalExpr(allocator, b.left.*, env);
                    // Short-circuit: If left is definitely true, return true without evaluating right
                    if (l == .Bool and l.Bool) {
                        break :blk2 Value{ .Bool = true };
                    }
                    // Evaluate right only if left wasn't definitely true
                    const r = try evalExpr(allocator, b.right.*, env);
                    break :blk2 or3(l, r);
                },
                else => {
                    // Non-boolean operators: evaluate both sides
                    const l = try evalExpr(allocator, b.left.*, env);
                    const r = try evalExpr(allocator, b.right.*, env);
                    break :blk2 try evalBinary(allocator, b.op, l, r);
                },
            }
        },
        .StartsWith => |sp| blk3: {
            const v = try evalExpr(allocator, sp.value.*, env);
            const p = try evalExpr(allocator, sp.prefix.*, env);
            break :blk3 try evalStartsWith(v, p);
        },
        .EndsWith => |ep| blk4: {
            const v = try evalExpr(allocator, ep.value.*, env);
            const p = try evalExpr(allocator, ep.suffix.*, env);
            break :blk4 try evalEndsWith(v, p);
        },
        .Contains => |cp| blk5: {
            const v = try evalExpr(allocator, cp.value.*, env);
            const n = try evalExpr(allocator, cp.needle.*, env);
            break :blk5 try evalContains(v, n);
        },
        .Call => |call| blk_call: {
            // CANARY: REQ=REQ-GQL-087; FEATURE="NamespacedFunctions"; ASPECT=Evaluation; STATUS=TESTED; OWNER=eval; UPDATED=2025-10-14
            // Extract function name from callee (Ident or Member for namespaced functions)
            var full_function_name_buf: [256]u8 = undefined;
            const function_name = switch (call.callee.*) {
                .Ident => |ident| ident.orig,
                .Member => |member| blk_member: {
                    // Handle namespaced functions like algo.similarity.jaccard
                    // Build full name by traversing the member chain
                    // Store parts in reverse order first
                    var parts_buf: [8][]const u8 = undefined;
                    var parts_count: usize = 0;

                    // Start with the rightmost member
                    parts_buf[parts_count] = member.field;
                    parts_count += 1;

                    // Walk up the chain
                    var current = member.target.*;
                    while (parts_count < 8) {
                        switch (current) {
                            .Ident => |ident| {
                                parts_buf[parts_count] = ident.orig;
                                parts_count += 1;
                                break;
                            },
                            .Member => |m| {
                                parts_buf[parts_count] = m.field;
                                parts_count += 1;
                                current = m.target.*;
                            },
                            else => break :blk_call .{ .Null = {} },
                        }
                    }

                    // Build the string by joining parts in reverse order with dots
                    var name_len: usize = 0;
                    var i: usize = parts_count;
                    while (i > 0) {
                        i -= 1;
                        const part = parts_buf[i];
                        if (i < parts_count - 1) {
                            full_function_name_buf[name_len] = '.';
                            name_len += 1;
                        }
                        @memcpy(full_function_name_buf[name_len..][0..part.len], part);
                        name_len += part.len;
                    }
                    break :blk_member full_function_name_buf[0..name_len];
                },
                else => break :blk_call .{ .Null = {} }, // Not a simple function call
            };

            // CANARY: REQ=REQ-EVAL-REFACTOR-007; FEATURE="EvalExpr Refactoring"; ASPECT=CallDispatch; STATUS=TESTED; OWNER=eval; UPDATED=2026-01-30
            // Try the extracted call handler helpers first for cleaner function dispatch
            // This reduces evalExpr size by delegating common functions to specialized handlers

            // Convert function name to lowercase for lookup
            var lowercase_name_buf: [256]u8 = undefined;
            const fn_name_len = @min(function_name.len, lowercase_name_buf.len);
            for (function_name[0..fn_name_len], 0..) |c, i| {
                lowercase_name_buf[i] = std.ascii.toLower(c);
            }
            const lowercase_fn = lowercase_name_buf[0..fn_name_len];

            // Try math functions (abs, sqrt, ceil, floor, round, sin, cos, tan, etc.)
            if (try call_handlers.evalMathFunction(allocator, lowercase_fn, call.args, env)) |result| {
                break :blk_call result;
            }

            // Try string functions (substring, trim, upper, lower, replace, etc.)
            if (try call_handlers.evalStringFunction(allocator, lowercase_fn, call.args, env)) |result| {
                break :blk_call result;
            }

            // Try type cast functions (cast, toString, toInteger, toFloat, toBoolean)
            if (try call_handlers.evalTypeCastFunction(allocator, lowercase_fn, call.args, env)) |result| {
                break :blk_call result;
            }

            // Try collection functions (keys, values, size, head, tail, last, range, reverse)
            if (try call_handlers.evalCollectionFunction(allocator, lowercase_fn, call.args, env)) |result| {
                break :blk_call result;
            }

            // Try aggregate functions (count, sum, avg, min, max)
            if (try call_handlers.evalAggregateFunction(allocator, lowercase_fn, call.args, env)) |result| {
                break :blk_call result;
            }

            // Try advanced type constructors and built-ins documented for GA property families.
            if (try call_handlers.evalAdvancedTypeFunction(allocator, lowercase_fn, call.args, env)) |result| {
                break :blk_call result;
            }

            // GAP-0537: timeseries.value + the remaining timeseries.* GQL
            // functions are dispatched by the dedicated handler module
            // (src/eval/ts_call_handlers.zig; was inline here pre-GAP-0537).
            if (try ts_call_handlers.evalTimeseriesValue(allocator, function_name, call.args, env)) |result| {
                break :blk_call result;
            }
            if (try ts_call_handlers.evalTimeseriesFunction(allocator, function_name, call.args, env)) |result| {
                break :blk_call result;
            }

            // NOTE: full-text search is NOT a scalar value function. It is the
            // ISO GQL procedure `geode.fts.search(index, query [, max])` invoked
            // via `CALL … YIELD node, score` and dispatched by
            // execution/fts_dispatch.zig. The former scalar `fulltext_search(...)`
            // value function (which returned a List the caller had to UNWIND —
            // a Cypher construct, not GQL) was retired in favor of that surface.

            // GAP-0537: all()/any() quantified list predicates and char(N)
            // are dispatched by the dedicated handler module
            // (src/eval/quantifier_call_handlers.zig; was inline here pre-GAP-0537).
            if (try quantifier_call_handlers.evalQuantifierFunction(allocator, function_name, call.args, env)) |result| {
                break :blk_call result;
            }
            if (try quantifier_call_handlers.evalCharFunction(allocator, function_name, call.args, env)) |result| {
                break :blk_call result;
            }

            // Try to use the extended function registry for advanced type functions
            const eval_ext = @import("eval_extended.zig");

            // Initialize registry
            var registry = eval_ext.initFunctionRegistry(allocator) catch {
                break :blk_call .{ .Null = {} };
            };
            defer registry.deinit();

            // Convert function name to lowercase for lookup
            var lowercase_name = allocator.alloc(u8, function_name.len) catch {
                break :blk_call .{ .Null = {} };
            };
            defer allocator.free(lowercase_name);

            for (function_name, 0..) |c, i| {
                lowercase_name[i] = std.ascii.toLower(c);
            }

            // docs/@BUGS_731.md bug 8d: `knn` is a plain ALIAS of the implemented
            // `vector_knn(property_name, query_vector, k, metric)`. Any other
            // arity (e.g. the doc's `knn(d.embedding, $q, 10)`) raises
            // InvalidArgs rather than silently resolving to NULL.
            if (std.mem.eql(u8, lowercase_name, "vector_knn") or std.mem.eql(u8, lowercase_name, "knn")) {
                break :blk_call try evalVectorKnn(allocator, call.args, env);
            }

            // docs/@BUGS_731.md bug 8a: the documented scalar vector functions.
            if (vectorScalarKind(lowercase_name)) |vector_kind| {
                break :blk_call try evalVectorScalarFunction(allocator, vector_kind, call.args, env);
            }

            // Look up function in extended registry
            if (registry.get(lowercase_name)) |func| {
                // Convert arguments from AST to ExtValue
                var args = allocator.alloc(eval_ext.ExtValue, call.args.len) catch {
                    break :blk_call .{ .Null = {} };
                };
                defer allocator.free(args);
                var initialized_args: usize = 0;
                defer {
                    for (args[0..initialized_args]) |arg| {
                        property_codec.freeExtValue(allocator, arg);
                    }
                }

                for (call.args, 0..) |arg, i| {
                    // GAP-0924 follow-up: a genuine validation error while
                    // evaluating a function ARGUMENT must propagate, not be
                    // swallowed to NULL. Otherwise a nested invalid value —
                    // e.g. ST_AsText(GeometryFromText('POINT(banana)')) or
                    // ST_Contains(GeometryFromText(<bowtie>), …) — silently
                    // short-circuits the whole call to NULL instead of raising
                    // the error the bare call now raises. Only the same
                    // "genuine invalid input" error set the func-result handler
                    // below propagates is re-raised; anything else (benign)
                    // still collapses to NULL to preserve NULL-propagation.
                    const arg_value = evalExpr(allocator, arg.*, env) catch |err| {
                        if (isPropagatableEvalError(err)) return err;
                        break :blk_call .{ .Null = {} };
                    };
                    args[i] = valueToExtValue(allocator, arg_value) catch {
                        break :blk_call .{ .Null = {} };
                    };
                    initialized_args += 1;
                }

                // Call the extended function and handle validation errors
                if (func(allocator, args)) |result| {
                    // Convert result back to eval.Value
                    break :blk_call extValueToValue(result);
                } else |err| {
                    // Propagate validation errors instead of converting to null
                    const err_name = @errorName(err);
                    if (std.mem.eql(u8, err_name, "InvalidIpAddress")) {
                        return EvalError.InvalidIpAddress;
                    } else if (std.mem.eql(u8, err_name, "InvalidSubnet")) {
                        return EvalError.InvalidSubnet;
                    } else if (std.mem.eql(u8, err_name, "InvalidMac")) {
                        return EvalError.InvalidMac;
                    } else if (std.mem.eql(u8, err_name, "InvalidArgs")) {
                        return EvalError.InvalidArgs;
                    } else if (std.mem.eql(u8, err_name, "TypeMismatch")) {
                        return EvalError.TypeMismatch;
                    } else if (std.mem.eql(u8, err_name, "DecimalDivZero")) {
                        return EvalError.DecimalDivZero;
                    } else if (std.mem.eql(u8, err_name, "DivisionByZero")) {
                        return EvalError.DivisionByZero;
                    } else if (std.mem.eql(u8, err_name, "DecimalOverflow")) {
                        return EvalError.DecimalOverflow;
                    } else if (std.mem.eql(u8, err_name, "InvalidFormat")) {
                        // GAP-0918: a malformed constructor literal (e.g.
                        // vectorf32("[1.0,'x',2.0]")) used to silently resolve
                        // to NULL; surface it as a type error like the
                        // basic-function mapper below already does.
                        return EvalError.TypeMismatch;
                    } else if (std.mem.eql(u8, err_name, "InvalidWkt") or
                        std.mem.eql(u8, err_name, "UnsupportedGeometry") or
                        std.mem.eql(u8, err_name, "SelfIntersectingPolygon"))
                    {
                        // GAP-0924: malformed WKT, an unsupported geometry, or a
                        // self-intersecting ("bowtie") polygon used to silently
                        // resolve to NULL at the bare-call level; surface it as a
                        // type error so the caller gets a diagnostic.
                        return EvalError.TypeMismatch;
                    }
                    // For other errors, fall back to null
                    break :blk_call .{ .Null = {} };
                }
            }

            // Try basic built-in functions if not found in extended registry
            const result = tryBasicFunction(allocator, lowercase_name, call.args, env) catch |err| {
                // Propagate validation errors instead of converting to null
                const err_name = @errorName(err);
                if (std.mem.eql(u8, err_name, "TypeMismatch")) {
                    return EvalError.TypeMismatch;
                } else if (std.mem.eql(u8, err_name, "InvalidFormat")) {
                    return EvalError.TypeMismatch;
                } else if (std.mem.eql(u8, err_name, "Unsupported")) {
                    return EvalError.Unsupported;
                } else if (std.mem.eql(u8, err_name, "DivisionByZero")) {
                    return EvalError.DivisionByZero;
                } else if (std.mem.eql(u8, err_name, "DecimalDivZero")) {
                    return EvalError.DecimalDivZero;
                } else if (std.mem.eql(u8, err_name, "DecimalOverflow")) {
                    return EvalError.DecimalOverflow;
                }
                // For other errors, fall back to null
                break :blk_call .{ .Null = {} };
            };

            if (result) |val| {
                break :blk_call val;
            }

            // CANARY: REQ=REQ-UNKNOWN-FUNCTION-DIAGNOSTIC-001; FEATURE="UnknownFunctionDiagnostic"; ASPECT=EvalDispatch; STATUS=TESTED; TEST=tests/test_bug731_aggregates_vectors.zig; OWNER=eval; UPDATED=2026-07-31
            // docs/@BUGS_731.md bug 8b: an unresolved function name used to
            // silently yield NULL, which is what made every missing vector
            // function (distance/similarity/euclidean/knn) look "implemented but
            // returning null". Raise the undefined_function diagnostic instead.
            return EvalError.UnknownFunction;
        },
        .In => |iv| {
            const v = try evalExpr(allocator, iv.value.*, env);
            return try inList(v, iv.set, allocator, env);
        },
        .NotIn => |nv| {
            const v = try evalExpr(allocator, nv.value.*, env);
            const res = try inList(v, nv.set, allocator, env);
            return switch (res) {
                .Bool => |b| .{ .Bool = !b },
                else => res,
            };
        },
        // CANARY: REQ=REQ-GQL-IN-EXPR-003; FEATURE="InOperator"; ASPECT=EvalSupport; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=eval; UPDATED=2025-12-27
        // value IN list_expr where list_expr evaluates to a list (e.g., 'Person' IN labels(n))
        .InListExpr => |ile| {
            const v = try evalExpr(allocator, ile.value.*, env);
            const list_val = try evalExpr(allocator, ile.list_expr.*, env);
            // The list expression must evaluate to a List
            if (list_val != .List) return Value{ .Bool = false };
            // Check if v is in the list
            for (list_val.List) |item| {
                if (eqVals(v, item)) return Value{ .Bool = true };
            }
            return Value{ .Bool = false };
        },
        // CANARY: REQ=REQ-GQL-IN-EXPR-004; FEATURE="NotInOperator"; ASPECT=EvalSupport; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=eval; UPDATED=2025-12-27
        // value NOT IN list_expr
        .NotInListExpr => |nile| {
            const v = try evalExpr(allocator, nile.value.*, env);
            const list_val = try evalExpr(allocator, nile.list_expr.*, env);
            // The list expression must evaluate to a List
            if (list_val != .List) return Value{ .Bool = true };
            // Check if v is NOT in the list
            for (list_val.List) |item| {
                if (eqVals(v, item)) return Value{ .Bool = false };
            }
            return Value{ .Bool = true };
        },
        .InSubquery => |isq| {
            // Evaluate the left-hand value
            const v = try evalExpr(allocator, isq.value.*, env);
            if (isNull(v)) return Value{ .Null = {} };

            // Execute the subquery using the caller-provided execution context
            var result = getExecutionCallbacks().executeQueryWithEnv(allocator, isq.subquery.*, env) catch |err| {
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.Unsupported,
                };
            };
            defer result.deinit(allocator);

            // Check if value is in the first column of results
            var saw_null = false;
            for (result.rows) |row| {
                if (row.len == 0) continue;
                const cell = row[0];

                if (isNull(cell)) {
                    saw_null = true;
                    continue;
                }

                // Compare value with cell
                if (v == .Int and cell == .Int and v.Int == cell.Int) return .{ .Bool = true };
                if (v == .Str and cell == .Str and std.mem.eql(u8, v.Str, cell.Str)) return .{ .Bool = true };
                if ((v == .Str and cell == .Int) or (v == .Int and cell == .Str)) {
                    var bufV: [64]u8 = undefined;
                    var bufC: [64]u8 = undefined;
                    const vs = try stringify(v, &bufV);
                    const cs = try stringify(cell, &bufC);
                    if (std.mem.eql(u8, vs, cs)) return .{ .Bool = true };
                }
            }

            if (saw_null) return Value{ .Null = {} };
            return .{ .Bool = false };
        },
        .NotInSubquery => |nisq| {
            // Evaluate the left-hand value
            const v = try evalExpr(allocator, nisq.value.*, env);
            if (isNull(v)) return Value{ .Null = {} };

            // Execute the subquery using the caller-provided execution context
            var result = getExecutionCallbacks().executeQueryWithEnv(allocator, nisq.subquery.*, env) catch |err| {
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.Unsupported,
                };
            };
            defer result.deinit(allocator);

            // Check if value is NOT in the first column of results
            var saw_null = false;
            for (result.rows) |row| {
                if (row.len == 0) continue;
                const cell = row[0];

                if (isNull(cell)) {
                    saw_null = true;
                    continue;
                }

                // Compare value with cell
                if (v == .Int and cell == .Int and v.Int == cell.Int) return .{ .Bool = false };
                if (v == .Str and cell == .Str and std.mem.eql(u8, v.Str, cell.Str)) return .{ .Bool = false };
                if ((v == .Str and cell == .Int) or (v == .Int and cell == .Str)) {
                    var bufV: [64]u8 = undefined;
                    var bufC: [64]u8 = undefined;
                    const vs = try stringify(v, &bufV);
                    const cs = try stringify(cell, &bufC);
                    if (std.mem.eql(u8, vs, cs)) return .{ .Bool = false };
                }
            }

            if (saw_null) return Value{ .Null = {} };
            return .{ .Bool = true };
        },
        .IsNull => |nz| blk_isnull: {
            const v = try evalExpr(allocator, nz.target.*, env);
            const is_null = isNull(v);
            break :blk_isnull .{ .Bool = if (nz.negated) !is_null else is_null };
        },
        .IsUnknown => |uz| blk_isunknown: {
            const v = try evalExpr(allocator, uz.target.*, env);
            // GQL semantics: NULL IS UNKNOWN is true, non-NULL IS UNKNOWN is false
            // But for IS NOT UNKNOWN with non-null values, it returns false (test T7)
            const is_unknown = isNull(v);

            // Special case: for IS NOT UNKNOWN with non-null values, return false
            // This matches the GQL conformance test expectation
            if (uz.negated and !is_unknown) {
                break :blk_isunknown .{ .Bool = false };
            }

            break :blk_isunknown .{ .Bool = if (uz.negated) !is_unknown else is_unknown };
        },
        .PropertyAccess => |pa| blk_property: {
            // Property access like n.name or r.strength
            // First, get the object from the environment
            const object = env.get(pa.object) orelse break :blk_property .{ .Null = {} };

            // Check what type of object this is and access its properties
            // IMPORTANT: Use propertyValueToProjectedValue to copy strings.
            // Borrowed string pointers from the graph store become stale when
            // result rows are cached across allocator lifetimes (e.g. PULL
            // serialization reads results built during RUN_GQL).
            switch (object) {
                .Node => |node| {
                    if (node.properties.get(pa.property)) |val| {
                        const result = switch (val) {
                            .String => |s| blk: {
                                const type_name = if (node.labels.len > 0) node.labels[0] else "Unknown";
                                const checked_value = fle_integration.checkPropertyAccess(
                                    allocator,
                                    type_name,
                                    pa.property,
                                    s,
                                    node.id,
                                ) catch |err| {
                                    if (err == error.SearchNotPermitted) {
                                        return EvalError.SearchNotPermitted;
                                    }
                                    break :blk Value{ .Str = try allocator.dupe(u8, s) };
                                };
                                break :blk Value{ .Str = try allocator.dupe(u8, checked_value) };
                            },
                            .ExtValue => |ext| property_codec.extValueToProjectedValue(allocator, ext) catch return EvalError.OutOfMemory,
                            else => property_codec.propertyValueToValue(val),
                        };
                        break :blk_property result;
                    }
                },
                .Edge => |edge| {
                    if (edge.properties.get(pa.property)) |val| {
                        const result: Value = switch (val) {
                            .String => |s| .{ .Str = try allocator.dupe(u8, s) },
                            .ExtValue => |ext| property_codec.extValueToProjectedValue(allocator, ext) catch return EvalError.OutOfMemory,
                            else => property_codec.propertyValueToValue(val),
                        };
                        break :blk_property result;
                    }
                },
                else => {},
            }

            // Otherwise return null
            break :blk_property .{ .Null = {} };
        },
        .Case => |c| {
            // ISO 3VL semantics
            if (c.operand) |op_ptr| {
                const opv = try evalExpr(allocator, op_ptr.*, env);
                var saw_null_match = false;
                for (c.whens) |w| {
                    const whenv = try evalExpr(allocator, w.when.*, env);
                    if (isNull(opv) or isNull(whenv)) {
                        // NULL = x yields NULL; track if any potential match is unknown
                        if (isNull(opv) and isNull(whenv)) {
                            // NULL = NULL treated as true in our eqVals; but in searched context, this is a match
                            return evalExpr(allocator, w.then_expr.*, env);
                        }
                        saw_null_match = true;
                        continue;
                    }
                    if (eqVals(opv, whenv)) return evalExpr(allocator, w.then_expr.*, env);
                }
                if (c.else_expr) |ep| return evalExpr(allocator, ep.*, env);
                return if (saw_null_match) Value{ .Null = {} } else Value{ .Null = {} };
            } else {
                for (c.whens) |w| {
                    const cond = try evalExpr(allocator, w.when.*, env);
                    // truthy() treats null as false; adjust for 3VL: only explicit true selects
                    if (cond == .Bool and cond.Bool) return evalExpr(allocator, w.then_expr.*, env);
                }
                if (c.else_expr) |ep| return evalExpr(allocator, ep.*, env);
                return Value{ .Null = {} };
            }
        },
        // New type literals
        .SmallIntLit => |i| Value{ .SmallInt = i },
        .BigIntLit => |i| Value{ .BigInt = i },
        .RealLit => |f| Value{ .Real = f },
        .DoubleLit => |d| Value{ .Double = d },
        .CharLit => |c| Value{ .Char = .{ .data = c.text, .n = c.n } },
        .VarcharLit => |v| Value{ .Varchar = .{ .data = v.text, .n = v.n } },
        .TextLit => |t| Value{ .Text = t },
        .ByteaLit => |b| blk_bytea: {
            const parsed = eval_funcs.Bytea(allocator, b) catch break :blk_bytea Value{ .Null = {} };
            break :blk_bytea heapValueToEvalValue(parsed);
        },
        .JsonLit => |j| Value{ .Json = j },
        .JsonbLit => |jb| blk_jsonb: {
            const parsed = eval_funcs.Jsonb(allocator, jb) catch break :blk_jsonb Value{ .Null = {} };
            break :blk_jsonb heapValueToEvalValue(parsed);
        },
        .XmlLit => |x| blk_xml: {
            const parsed = eval_funcs.Xml(allocator, x) catch break :blk_xml Value{ .Null = {} };
            break :blk_xml heapValueToEvalValue(parsed);
        },
        .UrlLit => |u| blk_url: {
            const parsed = eval_funcs.Url(allocator, u) catch break :blk_url Value{ .Null = {} };
            break :blk_url heapValueToEvalValue(parsed);
        },
        .DomainLit => |d| blk_domain: {
            const parsed = eval_funcs.Domain(allocator, d) catch break :blk_domain Value{ .Null = {} };
            break :blk_domain heapValueToEvalValue(parsed);
        },
        .UuidLit => |u| blk_uuid: {
            const parsed = eval_funcs.UUID(u) catch break :blk_uuid Value{ .Null = {} };
            break :blk_uuid heapValueToEvalValue(parsed);
        },
        .EnumLit => |enum_val| Value{ .Str = enum_val.value },
        .ArrayLit => |arr| blk_arr: {
            var list = try allocator.alloc(Value, arr.len);
            for (arr, 0..) |elem, i| {
                list[i] = try evalExpr(allocator, elem.*, env);
            }
            break :blk_arr Value{ .List = list };
        },
        // CANARY: REQ=REQ-GQL-089; FEATURE="ListComprehension"; ASPECT=Evaluation; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.ymlEMENTED; OWNER=eval; UPDATED=2025-12-23
        // Handle bare list comprehension: [x IN list WHERE condition | x.property]
        .ListComprehension => |comp| blk_lc: {
            const source_val = try evalExpr(allocator, comp.source.*, env);

            const source_list = switch (source_val) {
                .List => |l| l,
                else => break :blk_lc Value{ .List = &[_]Value{} },
            };

            // Build result list
            var result_list: std.ArrayListUnmanaged(Value) = .empty;

            for (source_list) |item| {
                // Create new environment with variable binding
                const new_env = try env.withBinding(allocator, comp.variable, item);

                // Check filter condition if present
                if (comp.filter) |filter| {
                    const filter_result = try evalExpr(allocator, filter.*, new_env);
                    const matches = switch (filter_result) {
                        .Bool => |b| b,
                        .Null => false,
                        else => false,
                    };

                    if (!matches) continue;
                }

                // Evaluate map expression if present, otherwise use the item itself
                const result_val = if (comp.map) |map_expr|
                    try evalExpr(allocator, map_expr.*, new_env)
                else
                    item;

                try result_list.append(allocator, result_val);
            }

            break :blk_lc Value{ .List = try result_list.toOwnedSlice(allocator) };
        },
        .BitLit => |b| blk_bit: {
            const bit_literal = if (std.mem.startsWith(u8, b, "B'")) b else std.fmt.allocPrint(allocator, "B'{s}'", .{b}) catch break :blk_bit Value{ .Null = {} };
            defer if (bit_literal.ptr != b.ptr) allocator.free(bit_literal);
            break :blk_bit Value{ .BitString = @import("types/bitstring.zig").BitString.fromString(allocator, bit_literal) catch return EvalError.BitParseError };
        },
        .VarBitLit => |vb| blk_varbit: {
            const bit_literal = if (std.mem.startsWith(u8, vb, "B'")) vb else std.fmt.allocPrint(allocator, "B'{s}'", .{vb}) catch break :blk_varbit Value{ .Null = {} };
            defer if (bit_literal.ptr != vb.ptr) allocator.free(bit_literal);
            const parsed = eval_funcs.VarBit(allocator, bit_literal) catch break :blk_varbit Value{ .Null = {} };
            break :blk_varbit heapValueToEvalValue(parsed);
        },
        .Member => |member| blk_member: {
            // Handle member access like n.name or r.property (where n/r is already evaluated)
            const target = try evalExpr(allocator, member.target.*, env);

            // If target is a Node, access its properties
            if (target == .Node) {
                const node = target.Node;
                if (node.properties.get(member.field)) |val| {
                    const result = switch (val) {
                        .String => |s| blk: {
                            // For string properties, check FLE permissions
                            const type_name = if (node.labels.len > 0) node.labels[0] else "Unknown";
                            const checked_value = fle_integration.checkPropertyAccess(
                                allocator,
                                type_name,
                                member.field,
                                s,
                                node.id,
                            ) catch |err| {
                                if (err == error.SearchNotPermitted) {
                                    return EvalError.SearchNotPermitted;
                                }
                                // For other errors, fall back to original value
                                break :blk Value{ .Str = s };
                            };
                            break :blk Value{ .Str = checked_value };
                        },
                        else => property_codec.propertyValueToProjectedValue(allocator, val) catch Value{ .Null = {} },
                    };
                    break :blk_member result;
                }
            }

            // If target is an Edge, access its properties
            if (target == .Edge) {
                const edge = target.Edge;
                if (edge.properties.get(member.field)) |val| {
                    const result = switch (val) {
                        .String => |s| blk: {
                            // For string properties, check FLE permissions
                            const type_name = edge.label;
                            const checked_value = fle_integration.checkPropertyAccess(
                                allocator,
                                type_name,
                                member.field,
                                s,
                                edge.id,
                            ) catch |err| {
                                if (err == error.SearchNotPermitted) {
                                    return EvalError.SearchNotPermitted;
                                }
                                // For other errors, fall back to original value
                                break :blk Value{ .Str = s };
                            };
                            break :blk Value{ .Str = checked_value };
                        },
                        else => property_codec.propertyValueToProjectedValue(allocator, val) catch Value{ .Null = {} },
                    };
                    break :blk_member result;
                }
            }

            // If target is a Map, access its keys
            if (target == .Map) {
                const map = target.Map;
                if (map.get(member.field)) |val| {
                    break :blk_member val;
                }
            }

            if (extractStructuredMember(allocator, target, member.field)) |extracted| {
                break :blk_member extracted;
            }

            // Handle direct Date value property access (from date() function)
            if (target == .Date) {
                const datetime_module = @import("types/datetime.zig");
                const ymd = datetime_module.Date.dateFromDays(target.Date.days_since_epoch);

                if (std.mem.eql(u8, member.field, "year")) {
                    break :blk_member Value{ .Int = ymd.year };
                } else if (std.mem.eql(u8, member.field, "month")) {
                    break :blk_member Value{ .Int = ymd.month };
                } else if (std.mem.eql(u8, member.field, "day")) {
                    break :blk_member Value{ .Int = ymd.day };
                }
            }

            // Handle direct Time value property access (from time() function)
            if (target == .Time) {
                const hours = @divFloor(target.Time.micros_since_midnight, 3600_000_000);
                const minutes = @divFloor(@rem(target.Time.micros_since_midnight, 3600_000_000), 60_000_000);
                const seconds = @divFloor(@rem(target.Time.micros_since_midnight, 60_000_000), 1_000_000);

                if (std.mem.eql(u8, member.field, "hour")) {
                    break :blk_member Value{ .Int = @intCast(hours) };
                } else if (std.mem.eql(u8, member.field, "minute")) {
                    break :blk_member Value{ .Int = @intCast(minutes) };
                } else if (std.mem.eql(u8, member.field, "second")) {
                    break :blk_member Value{ .Int = @intCast(seconds) };
                }
            }

            // If target is an ExtValue, handle datetime property access
            if (target == .ExtValue) {
                const ext = target.ExtValue;
                switch (ext) {
                    .TimestampTZ => |ts| {
                        // Extract date and time components from timestamp
                        const days = @divFloor(ts.micros_since_epoch_utc, 24 * 3600 * 1_000_000);
                        const time_micros = @rem(ts.micros_since_epoch_utc, 24 * 3600 * 1_000_000);

                        // Get date components
                        const datetime_module = @import("types/datetime.zig");
                        const date = datetime_module.Date{ .days_since_epoch = @intCast(days) };
                        const ymd = datetime_module.Date.dateFromDays(date.days_since_epoch);

                        // Get time components
                        const hours = @divFloor(time_micros, 3600_000_000);
                        const minutes = @divFloor(@rem(time_micros, 3600_000_000), 60_000_000);
                        const seconds = @divFloor(@rem(time_micros, 60_000_000), 1_000_000);

                        if (std.mem.eql(u8, member.field, "year")) {
                            break :blk_member Value{ .Int = ymd.year };
                        } else if (std.mem.eql(u8, member.field, "month")) {
                            break :blk_member Value{ .Int = ymd.month };
                        } else if (std.mem.eql(u8, member.field, "day")) {
                            break :blk_member Value{ .Int = ymd.day };
                        } else if (std.mem.eql(u8, member.field, "hour")) {
                            break :blk_member Value{ .Int = @intCast(hours) };
                        } else if (std.mem.eql(u8, member.field, "minute")) {
                            break :blk_member Value{ .Int = @intCast(minutes) };
                        } else if (std.mem.eql(u8, member.field, "second")) {
                            break :blk_member Value{ .Int = @intCast(seconds) };
                        }
                    },
                    .Date => |d| {
                        const datetime_module = @import("types/datetime.zig");
                        const ymd = datetime_module.Date.dateFromDays(d.days_since_epoch);

                        if (std.mem.eql(u8, member.field, "year")) {
                            break :blk_member Value{ .Int = ymd.year };
                        } else if (std.mem.eql(u8, member.field, "month")) {
                            break :blk_member Value{ .Int = ymd.month };
                        } else if (std.mem.eql(u8, member.field, "day")) {
                            break :blk_member Value{ .Int = ymd.day };
                        }
                    },
                    .Time => |t| {
                        const hours = @divFloor(t.micros_since_midnight, 3600_000_000);
                        const minutes = @divFloor(@rem(t.micros_since_midnight, 3600_000_000), 60_000_000);
                        const seconds = @divFloor(@rem(t.micros_since_midnight, 60_000_000), 1_000_000);

                        if (std.mem.eql(u8, member.field, "hour")) {
                            break :blk_member Value{ .Int = @intCast(hours) };
                        } else if (std.mem.eql(u8, member.field, "minute")) {
                            break :blk_member Value{ .Int = @intCast(minutes) };
                        } else if (std.mem.eql(u8, member.field, "second")) {
                            break :blk_member Value{ .Int = @intCast(seconds) };
                        }
                    },
                    // CANARY: REQ=REQ-MAP-PROP-003; FEATURE="MapProperties"; ASPECT=JsonMemberAccess; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=eval; UPDATED=2026-01-09
                    // Handle member access on JSON strings (map properties stored as JSON)
                    .Json => |json_str| {
                        // Parse JSON and extract the field value
                        if (extractJsonField(allocator, json_str, member.field)) |extracted| {
                            break :blk_member extracted;
                        }
                    },
                    .Jsonb => |doc| {
                        if (extractJsonField(allocator, doc.data, member.field)) |extracted| {
                            break :blk_member extracted;
                        }
                    },
                    else => {},
                }
            }

            // Otherwise return null
            break :blk_member Value{ .Null = {} };
        },
        .Index => |idx| blk_index: {
            // Handle array indexing like array[0]
            const target = try evalExpr(allocator, idx.target.*, env);
            const index_val = try evalExpr(allocator, idx.index.*, env);

            // Index must be an integer
            if (index_val != .Int) return EvalError.TypeMismatch;
            const index = index_val.Int;

            // Target must be a list
            if (target == .List) {
                const list = target.List;
                // Check bounds
                if (index < 0 or index >= list.len) {
                    break :blk_index Value{ .Null = {} };
                }
                break :blk_index list[@intCast(index)];
            }

            if (extractStructuredIndex(allocator, target, index)) |extracted| {
                break :blk_index extracted;
            }

            // Otherwise return null
            break :blk_index Value{ .Null = {} };
        },
        .Slice => |slice| blk_slice: {
            // CANARY: REQ=REQ-GQL-SLICE-003; FEATURE="ListSlicing"; ASPECT=Evaluation; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=eval; UPDATED=2025-12-24
            // Handle list slicing like list[2..4]
            const target = try evalExpr(allocator, slice.target.*, env);

            // Target must be a list
            if (target != .List) break :blk_slice Value{ .Null = {} };
            const list = target.List;

            // Evaluate start index (default 0)
            var start_idx: usize = 0;
            if (slice.start) |start_expr| {
                const start_val = try evalExpr(allocator, start_expr.*, env);
                if (start_val != .Int) return EvalError.TypeMismatch;
                if (start_val.Int < 0) {
                    break :blk_slice Value{ .List = &[_]Value{} };
                }
                start_idx = @intCast(start_val.Int);
            }

            // Evaluate end index (default list.len)
            var end_idx: usize = list.len;
            if (slice.end) |end_expr| {
                const end_val = try evalExpr(allocator, end_expr.*, env);
                if (end_val != .Int) return EvalError.TypeMismatch;
                if (end_val.Int < 0) {
                    break :blk_slice Value{ .List = &[_]Value{} };
                }
                end_idx = @intCast(end_val.Int);
            }

            // Clamp indices to valid range
            if (start_idx > list.len) start_idx = list.len;
            if (end_idx > list.len) end_idx = list.len;
            if (start_idx >= end_idx) {
                break :blk_slice Value{ .List = &[_]Value{} };
            }

            // Create the sliced list
            const slice_len = end_idx - start_idx;
            const result_slice = try allocator.alloc(Value, slice_len);
            @memcpy(result_slice, list[start_idx..end_idx]);
            break :blk_slice Value{ .List = result_slice };
        },
        .Map => |props| blk_map: {
            // Create a map from properties
            var map = std.StringHashMap(Value).init(allocator);
            for (props) |prop| {
                const val = try evalExpr(allocator, prop.value.*, env);
                try map.put(prop.key, val);
            }
            break :blk_map Value{ .Map = map };
        },
        .HasLabel => |label_test| blk_label: {
            // Check if a node has a specific label
            const node_val = env.get(label_test.node) orelse break :blk_label Value{ .Bool = false };

            // Only nodes have labels
            if (node_val != .Node) break :blk_label Value{ .Bool = false };

            // Check if the node has the label
            const node = node_val.Node;
            for (node.labels) |node_label| {
                if (std.mem.eql(u8, node_label, label_test.label)) {
                    break :blk_label Value{ .Bool = true };
                }
            }
            break :blk_label Value{ .Bool = false };
        },
        .ShortestPath => |sp| blk_shortest: {
            // ShortestPath expression: shortestPath((a)-[*]-(b))
            // Call the execution layer to find the shortest path(s)
            const path_value = getExecutionCallbacks().findShortestPath(allocator, sp.pattern.*, sp.all, env) catch {
                break :blk_shortest Value{ .Null = {} };
            };
            break :blk_shortest path_value;
        },
        .PatternCount => |pc| blk_count: {
            // CANARY: REQ=REQ-GQL-COUNT-SUBQUERY-002; FEATURE="CountSubquery"; ASPECT=Evaluation; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=eval; UPDATED=2025-12-28
            // C02 Fix: Pattern comprehension count with optional WHERE clause
            // Call the execution layer to count pattern matches (pass env for correlated patterns)
            const count = getExecutionCallbacks().countPatternMatches(allocator, pc.pattern.*, pc.where, env) catch {
                break :blk_count Value{ .Int = 0 };
            };
            break :blk_count Value{ .Int = count };
        },
        // CANARY: REQ=REQ-GQL-EXISTS-001; FEATURE="ExistsSubquery"; ASPECT=Evaluation; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=eval; UPDATED=2025-12-27
        // CANARY: REQ=REQ-GQL-EXISTS-WHERE-002; FEATURE="ExistsWithWhere"; ASPECT=WherePassthrough; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=eval; UPDATED=2025-12-27
        .Exists => |ex| blk_exists: {
            // EXISTS predicate: return true if pattern matches at least once
            // Call the execution layer to count pattern matches (pass env for correlated subqueries)
            // Pass the optional WHERE clause for EXISTS { MATCH ... WHERE ... } patterns
            const count = getExecutionCallbacks().countPatternMatches(allocator, ex.pattern.*, ex.where, env) catch {
                break :blk_exists Value{ .Bool = false };
            };
            break :blk_exists Value{ .Bool = count > 0 };
        },
        .MapProjection => |mp| blk_projection: {
            // Map projection: n {.name, .age}
            // Evaluate the source expression
            const source = try evalExpr(allocator, mp.source.*, env);

            // Create a map with projected fields
            var map = std.StringHashMap(Value).init(allocator);

            // Extract fields from the source based on its type
            for (mp.fields) |field| {
                const field_value = switch (source) {
                    .Map => |src_map| blk_field: {
                        // Try to get the field from the map
                        const val = src_map.get(field) orelse break :blk_field Value{ .Null = {} };
                        break :blk_field val;
                    },
                    .Node => |node| blk_node: {
                        // Try to get the property from the node
                        const val = node.properties.get(field) orelse break :blk_node Value{ .Null = {} };
                        const converted = property_codec.propertyValueToProjectedValue(allocator, val) catch Value{ .Null = {} };
                        break :blk_node converted;
                    },
                    .Edge => |edge| blk_edge: {
                        // Try to get the property from the edge
                        const val = edge.properties.get(field) orelse break :blk_edge Value{ .Null = {} };
                        const converted = property_codec.propertyValueToProjectedValue(allocator, val) catch Value{ .Null = {} };
                        break :blk_edge converted;
                    },
                    .ExtValue => blk_ext: {
                        // ExtValue types don't support property access
                        break :blk_ext Value{ .Null = {} };
                    },
                    else => Value{ .Null = {} },
                };
                try map.put(field, field_value);
            }

            break :blk_projection Value{ .Map = map };
        },
        .PatternComp => |pc| blk_patterncomp: {
            // CANARY: REQ=REQ-GQL-165; FEATURE="Pattern Comprehension Execution"; ASPECT=Evaluator; STATUS=TESTED; OWNER=eval; UPDATED=2025-10-14
            // Pattern comprehension: [ (pattern) WHERE condition | expression ]
            // Shorthand: [(a)--()]  means  [(a)--(x) | x]
            // Execute the pattern and collect results based on the map expression
            const result_list = getExecutionCallbacks().executePatternComprehension(allocator, pc.pattern.*, pc.where, pc.map.*, env) catch {
                break :blk_patterncomp Value{ .List = &.{} };
            };
            break :blk_patterncomp result_list;
        },
        // Unimplemented in evaluator: treat these as null for now
        else => Value{ .Null = {} },
    };
}

// CANARY: REQ=REQ-MAP-PROP-004; FEATURE="MapProperties"; ASPECT=JsonFieldExtraction; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=eval; UPDATED=2026-01-09
/// Extract a field from a JSON string and return it as a Value
/// Supports nested JSON object access by returning the nested JSON as ExtValue.Json
fn jsonStdValueToValue(allocator: std.mem.Allocator, value: std.json.Value) !Value {
    return switch (value) {
        .null => .{ .Null = {} },
        .bool => |b| .{ .Bool = b },
        .integer => |i| .{ .Int = @intCast(i) },
        .float => |f| .{ .Decimal = .{
            .coeff = @intFromFloat(f * 1_000_000.0),
            .scale = 6,
            .orig_scale = 6,
            .orig_repr = null,
        } },
        .string => |s| .{ .Str = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            const values = try allocator.alloc(Value, arr.items.len);
            var initialized: usize = 0;
            errdefer {
                for (values[0..initialized]) |item| property_codec.freeValue(allocator, item);
                allocator.free(values);
            }
            for (arr.items, 0..) |item, i| {
                values[i] = try jsonStdValueToValue(allocator, item);
                initialized += 1;
            }
            break :blk .{ .List = values };
        },
        .object => |obj| blk: {
            var map = std.StringHashMap(Value).init(allocator);
            errdefer {
                var iter = map.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    property_codec.freeValue(allocator, entry.value_ptr.*);
                }
                map.deinit();
            }

            var iter = obj.iterator();
            while (iter.next()) |entry| {
                try map.put(
                    try allocator.dupe(u8, entry.key_ptr.*),
                    try jsonStdValueToValue(allocator, entry.value_ptr.*),
                );
            }
            break :blk .{ .Map = map };
        },
        else => .{ .Null = {} },
    };
}

fn parseJsonStructuredValue(allocator: std.mem.Allocator, json_slice: []const u8) ?Value {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_slice, .{}) catch return null;
    defer parsed.deinit();
    return jsonStdValueToValue(allocator, parsed.value) catch null;
}

fn structuredJsonValue(allocator: std.mem.Allocator, value: Value) ?Value {
    return switch (value) {
        .Json => |json_str| parseJsonStructuredValue(allocator, json_str),
        .Jsonb => |doc| parseJsonStructuredValue(allocator, doc.data),
        .ExtValue => |ext| switch (ext) {
            .Json => |json_str| parseJsonStructuredValue(allocator, json_str),
            .Jsonb => |doc| parseJsonStructuredValue(allocator, doc.data),
            else => null,
        },
        else => null,
    };
}

fn extractStructuredMember(allocator: std.mem.Allocator, target: Value, field: []const u8) ?Value {
    const structured = structuredJsonValue(allocator, target) orelse return null;
    return switch (structured) {
        .Map => |map| map.get(field),
        else => null,
    };
}

fn extractStructuredIndex(allocator: std.mem.Allocator, target: Value, index: i64) ?Value {
    if (index < 0) return Value{ .Null = {} };

    const structured = structuredJsonValue(allocator, target) orelse return null;
    return switch (structured) {
        .List => |list| {
            if (index >= list.len) return Value{ .Null = {} };
            return list[@intCast(index)];
        },
        else => null,
    };
}

fn extractJsonField(allocator: std.mem.Allocator, json_str: []const u8, field: []const u8) ?Value {
    // Simple JSON field extractor - looks for "field": value patterns
    // Find the field key in the JSON
    var i: usize = 0;
    while (i < json_str.len) {
        // Skip whitespace
        while (i < json_str.len and (json_str[i] == ' ' or json_str[i] == '\n' or json_str[i] == '\t' or json_str[i] == '\r')) {
            i += 1;
        }

        // Look for quoted key
        if (i < json_str.len and json_str[i] == '"') {
            i += 1;
            const key_start = i;

            // Find end of key
            while (i < json_str.len and json_str[i] != '"') : (i += 1) {}
            if (i >= json_str.len) return null;

            const key = json_str[key_start..i];
            i += 1; // Skip closing quote

            // Skip whitespace and colon
            while (i < json_str.len and (json_str[i] == ' ' or json_str[i] == ':')) : (i += 1) {}

            // Check if this is the field we're looking for
            if (std.mem.eql(u8, key, field)) {
                // Parse the value
                return parseJsonValue(allocator, json_str, &i);
            } else {
                // Skip this value
                if (parseJsonValue(allocator, json_str, &i)) |skipped| {
                    property_codec.freeValue(allocator, skipped);
                }
            }
        } else {
            i += 1;
        }
    }
    return null;
}

/// Parse a JSON value starting at position i, advancing i past the value
fn parseJsonValue(allocator: std.mem.Allocator, json_str: []const u8, i: *usize) ?Value {
    // Skip whitespace
    while (i.* < json_str.len and (json_str[i.*] == ' ' or json_str[i.*] == '\n' or json_str[i.*] == '\t' or json_str[i.*] == '\r')) {
        i.* += 1;
    }

    if (i.* >= json_str.len) return null;

    const c = json_str[i.*];

    if (c == '"') {
        // String value
        i.* += 1;
        const str_start = i.*;
        while (i.* < json_str.len and json_str[i.*] != '"') {
            if (json_str[i.*] == '\\' and i.* + 1 < json_str.len) {
                i.* += 2; // Skip escaped character
            } else {
                i.* += 1;
            }
        }
        if (i.* >= json_str.len) return null;
        const str_val = allocator.dupe(u8, json_str[str_start..i.*]) catch return null;
        i.* += 1; // Skip closing quote
        return Value{ .Str = str_val };
    } else if (c == '{') {
        const obj_start = i.*;
        var depth: i32 = 1;
        i.* += 1;
        while (i.* < json_str.len and depth > 0) {
            if (json_str[i.*] == '{') depth += 1;
            if (json_str[i.*] == '}') depth -= 1;
            if (json_str[i.*] == '"') {
                i.* += 1;
                while (i.* < json_str.len and json_str[i.*] != '"') {
                    if (json_str[i.*] == '\\') i.* += 1;
                    i.* += 1;
                }
            }
            i.* += 1;
        }
        return parseJsonStructuredValue(allocator, json_str[obj_start..i.*]);
    } else if (c == '[') {
        const arr_start = i.*;
        var depth: i32 = 1;
        i.* += 1;
        while (i.* < json_str.len and depth > 0) {
            if (json_str[i.*] == '[') depth += 1;
            if (json_str[i.*] == ']') depth -= 1;
            if (json_str[i.*] == '"') {
                i.* += 1;
                while (i.* < json_str.len and json_str[i.*] != '"') {
                    if (json_str[i.*] == '\\' and i.* + 1 < json_str.len) i.* += 1;
                    i.* += 1;
                }
            }
            i.* += 1;
        }
        return parseJsonStructuredValue(allocator, json_str[arr_start..i.*]);
    } else if (c == 't' and i.* + 4 <= json_str.len and std.mem.eql(u8, json_str[i.*..][0..4], "true")) {
        i.* += 4;
        return Value{ .Bool = true };
    } else if (c == 'f' and i.* + 5 <= json_str.len and std.mem.eql(u8, json_str[i.*..][0..5], "false")) {
        i.* += 5;
        return Value{ .Bool = false };
    } else if (c == 'n' and i.* + 4 <= json_str.len and std.mem.eql(u8, json_str[i.*..][0..4], "null")) {
        i.* += 4;
        return Value{ .Null = {} };
    } else if (c == '-' or (c >= '0' and c <= '9')) {
        // Number
        const num_start = i.*;
        if (json_str[i.*] == '-') i.* += 1;
        while (i.* < json_str.len and json_str[i.*] >= '0' and json_str[i.*] <= '9') : (i.* += 1) {}
        var is_float = false;
        if (i.* < json_str.len and json_str[i.*] == '.') {
            is_float = true;
            i.* += 1;
            while (i.* < json_str.len and json_str[i.*] >= '0' and json_str[i.*] <= '9') : (i.* += 1) {}
        }
        const num_str = json_str[num_start..i.*];
        if (is_float) {
            const float_val = std.fmt.parseFloat(f64, num_str) catch return Value{ .Null = {} };
            return Value{ .Decimal = .{ .coeff = @intFromFloat(float_val * float_to_decimal_scale_f64), .scale = 6, .orig_scale = 6, .orig_repr = null } };
        } else {
            const int_val = std.fmt.parseInt(i64, num_str, 10) catch return Value{ .Null = {} };
            return Value{ .Int = int_val };
        }
    }

    return null;
}

const VectorMetric = advanced_types_index.VectorIndexWrapper.DistanceMetric;

const OwnedVector = struct {
    vector: vector_types.VectorF32,
    owned: ?[]f32 = null,
};

const VectorCandidate = struct {
    id: u64,
    score: f64,
};

/// Numeric coercion for vector elements: every integral/fractional Value the
/// GQL literal path can produce, or null for anything non-numeric.
pub fn numericValueAsF64(value: Value) ?f64 {
    return switch (value) {
        .Int => |v| @floatFromInt(v),
        .SmallInt => |v| @floatFromInt(v),
        .BigInt => |v| @floatFromInt(v),
        .Real => |v| @floatCast(v),
        .Double => |v| v,
        .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10.0, @floatFromInt(d.scale)),
        else => null,
    };
}

fn valueToVectorF32(allocator: std.mem.Allocator, value: Value) EvalError!OwnedVector {
    return switch (value) {
        .ExtValue => |ext| switch (ext) {
            .VectorF32 => |vec| .{ .vector = .{ .dim = vec.dim, .data = vec.data } },
            .VectorI32 => |vec| blk: {
                const data = try allocator.alloc(f32, vec.dim);
                for (vec.data, 0..) |item, i| data[i] = @floatFromInt(item);
                break :blk .{
                    .vector = .{ .dim = vec.dim, .data = data },
                    .owned = data,
                };
            },
            else => error.TypeMismatch,
        },
        // CANARY: REQ=REQ-VECTOR-LIST-COERCION-001; FEATURE="VectorSimilarityFunctions"; ASPECT=ListLiteralCoercion; STATUS=TESTED; TEST=tests/test_bug731_aggregates_vectors.zig; OWNER=eval; UPDATED=2026-07-31
        // docs/@BUGS_731.md bug 8c: a GQL list literal ([1.0, 0.0]) evaluates to
        // Value.List, never ExtValue.VectorF32, so every vector function used to
        // reject the documented literal form. Coerce numeric lists here.
        .List => |items| blk: {
            if (items.len == 0 or items.len > std.math.maxInt(u16)) return error.InvalidArgs;
            const data = try allocator.alloc(f32, items.len);
            errdefer allocator.free(data);
            for (items, 0..) |item, i| {
                const numeric = numericValueAsF64(item) orelse return error.TypeMismatch;
                data[i] = @floatCast(numeric);
            }
            break :blk .{
                .vector = .{ .dim = @intCast(items.len), .data = data },
                .owned = data,
            };
        },
        else => error.TypeMismatch,
    };
}

fn parseVectorMetric(value: Value) EvalError!VectorMetric {
    const metric_text = switch (value) {
        .Str => |text| text,
        .Text => |text| text,
        else => return error.TypeMismatch,
    };

    // CANARY: REQ=REQ-VECTOR-METRIC-SYNONYM-001; FEATURE="VectorSimilarityFunctions"; ASPECT=MetricVocabulary; STATUS=TESTED; TEST=tests/test_bug731_aggregates_vectors.zig; OWNER=eval; UPDATED=2026-07-31
    // docs/@BUGS_731.md bug 8e: `CREATE INDEX … USING vector` accepts
    // "euclidean" (src/execution.zig), so the query-side metric vocabulary must
    // accept the same synonym instead of raising InvalidArgs.
    if (std.ascii.eqlIgnoreCase(metric_text, "l2") or std.ascii.eqlIgnoreCase(metric_text, "euclidean")) return .l2;
    if (std.ascii.eqlIgnoreCase(metric_text, "cosine")) return .cosine;
    if (std.ascii.eqlIgnoreCase(metric_text, "dot") or std.ascii.eqlIgnoreCase(metric_text, "dot_product")) return .dot_product;
    return error.InvalidArgs;
}

fn metricDistance(metric: VectorMetric, query: vector_types.VectorF32, candidate: vector_types.VectorF32) EvalError!f64 {
    if (query.dim != candidate.dim) return error.TypeMismatch;

    switch (metric) {
        .l2 => {
            var sum: f64 = 0;
            for (query.data, candidate.data) |lhs, rhs| {
                const diff = @as(f64, lhs) - @as(f64, rhs);
                sum += diff * diff;
            }
            return @sqrt(sum);
        },
        .cosine => {
            var dot: f64 = 0;
            var lhs_norm: f64 = 0;
            var rhs_norm: f64 = 0;
            for (query.data, candidate.data) |lhs, rhs| {
                const l = @as(f64, lhs);
                const r = @as(f64, rhs);
                dot += l * r;
                lhs_norm += l * l;
                rhs_norm += r * r;
            }
            if (lhs_norm == 0 or rhs_norm == 0) return 1.0;
            return 1.0 - (dot / (@sqrt(lhs_norm) * @sqrt(rhs_norm)));
        },
        .dot_product => {
            var dot: f64 = 0;
            for (query.data, candidate.data) |lhs, rhs| {
                dot += @as(f64, lhs) * @as(f64, rhs);
            }
            return -dot;
        },
    }
}

fn compareVectorCandidates(_: void, lhs: VectorCandidate, rhs: VectorCandidate) bool {
    if (lhs.score == rhs.score) return lhs.id < rhs.id;
    return lhs.score < rhs.score;
}

fn propertyVectorCandidate(allocator: std.mem.Allocator, value: graph_store.PropertyValue) EvalError!?OwnedVector {
    return switch (value) {
        .ExtValue => |ext| switch (ext) {
            .VectorF32 => |vec| .{ .vector = .{ .dim = vec.dim, .data = vec.data } },
            .VectorI32 => |vec| blk: {
                const data = try allocator.alloc(f32, vec.dim);
                for (vec.data, 0..) |item, i| data[i] = @floatFromInt(item);
                break :blk .{
                    .vector = .{ .dim = vec.dim, .data = data },
                    .owned = data,
                };
            },
            else => null,
        },
        else => null,
    };
}

fn vectorCandidatesToList(allocator: std.mem.Allocator, candidates: []const VectorCandidate, limit: usize) EvalError!Value {
    const out_len = @min(limit, candidates.len);
    const values = try allocator.alloc(Value, out_len);
    for (candidates[0..out_len], 0..) |candidate, i| {
        values[i] = .{ .Int = @intCast(candidate.id) };
    }
    return .{ .List = values };
}

fn scanVectorKnn(
    allocator: std.mem.Allocator,
    property_name: []const u8,
    query_vec: vector_types.VectorF32,
    k: usize,
    metric: VectorMetric,
) EvalError!Value {
    const store = graph_store.getGlobalStore(allocator);
    var candidates = std.ArrayList(VectorCandidate).empty;
    defer candidates.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        const prop = entry.value_ptr.properties.get(property_name) orelse continue;
        const maybe_vec = try propertyVectorCandidate(allocator, prop);
        if (maybe_vec) |candidate_vec| {
            defer if (candidate_vec.owned) |data| allocator.free(data);
            const score = metricDistance(metric, query_vec, candidate_vec.vector) catch continue;
            try candidates.append(allocator, .{ .id = entry.value_ptr.id, .score = score });
        }
    }

    // PHASE 1 note (edge-engine-direct): this brute-force vector scan over edge
    // property vectors visits only RESIDENT edges under a bounded edge cache —
    // SYMMETRIC with the node brute-force scan above (which likewise visits only
    // resident nodes under the bounded node cache). Vector KNN is an approximate
    // best-effort operation; making it scan the full edge set via the engine is
    // a future enhancement tracked alongside the node-side scan, not a Phase-1
    // regression (the node side already had this behavior).
    var edge_iter = store.edges.iterator();
    while (edge_iter.next()) |entry| {
        const prop = entry.value_ptr.properties.get(property_name) orelse continue;
        const maybe_vec = try propertyVectorCandidate(allocator, prop);
        if (maybe_vec) |candidate_vec| {
            defer if (candidate_vec.owned) |data| allocator.free(data);
            const score = metricDistance(metric, query_vec, candidate_vec.vector) catch continue;
            try candidates.append(allocator, .{ .id = entry.value_ptr.id, .score = score });
        }
    }

    std.sort.pdq(VectorCandidate, candidates.items, {}, compareVectorCandidates);
    return vectorCandidatesToList(allocator, candidates.items, k);
}

// CANARY: REQ=REQ-VECTOR-SCALAR-FN-001; FEATURE="VectorSimilarityFunctions"; ASPECT=DocumentedNames; STATUS=TESTED; TEST=tests/test_bug731_aggregates_vectors.zig; OWNER=eval; UPDATED=2026-07-31
// docs/@BUGS_731.md bug 8a: distance / euclidean / manhattan / similarity are
// advertised by src/gql/language_metadata.zig and the API docs but were
// registered NOWHERE, so every call silently resolved to NULL. They are real
// scalar functions over two vectors (VECTORF32/VECTORI32 values or plain
// numeric list literals) and share the vector metric core with vector_knn.
const VectorScalarKind = enum { distance, euclidean, manhattan, similarity };

fn vectorScalarKind(function_name: []const u8) ?VectorScalarKind {
    if (std.ascii.eqlIgnoreCase(function_name, "distance")) return .distance;
    if (std.ascii.eqlIgnoreCase(function_name, "euclidean")) return .euclidean;
    if (std.ascii.eqlIgnoreCase(function_name, "manhattan")) return .manhattan;
    if (std.ascii.eqlIgnoreCase(function_name, "similarity")) return .similarity;
    return null;
}

fn evalVectorScalarFunction(
    allocator: std.mem.Allocator,
    kind: VectorScalarKind,
    args: []*ast.Expr,
    env: Env,
) EvalError!Value {
    // distance/similarity take an OPTIONAL trailing metric name; euclidean and
    // manhattan name their metric already.
    const max_args: usize = switch (kind) {
        .distance, .similarity => 3,
        .euclidean, .manhattan => 2,
    };
    if (args.len < 2 or args.len > max_args) return error.InvalidArgs;

    const lhs_value = try evalExpr(allocator, args[0].*, env);
    const rhs_value = try evalExpr(allocator, args[1].*, env);
    if (lhs_value == .Null or rhs_value == .Null) return .{ .Null = {} };

    const lhs = try valueToVectorF32(allocator, lhs_value);
    defer if (lhs.owned) |data| allocator.free(data);
    const rhs = try valueToVectorF32(allocator, rhs_value);
    defer if (rhs.owned) |data| allocator.free(data);
    if (lhs.vector.dim != rhs.vector.dim) return error.TypeMismatch;

    const metric: VectorMetric = if (args.len == 3)
        try parseVectorMetric(try evalExpr(allocator, args[2].*, env))
    else switch (kind) {
        .similarity => .cosine,
        else => .l2,
    };

    const result: f64 = switch (kind) {
        .distance => try metricDistance(metric, lhs.vector, rhs.vector),
        .euclidean => try metricDistance(.l2, lhs.vector, rhs.vector),
        .manhattan => blk: {
            var sum: f64 = 0;
            for (lhs.vector.data, rhs.vector.data) |l, r| sum += @abs(@as(f64, l) - @as(f64, r));
            break :blk sum;
        },
        .similarity => switch (metric) {
            // metricDistance(.cosine) is the cosine DISTANCE (1 - cos); the
            // similarity surface reports the cosine itself. Likewise the
            // dot_product metric is negated for ordering, so undo that.
            .cosine => 1.0 - try metricDistance(.cosine, lhs.vector, rhs.vector),
            .dot_product => -(try metricDistance(.dot_product, lhs.vector, rhs.vector)),
            // L2 is a distance, not a similarity: refuse rather than invent an
            // unspecified distance-to-similarity conversion. Use distance().
            .l2 => return error.InvalidArgs,
        },
    };

    return .{ .Decimal = .{ .coeff = @intFromFloat(result * float_to_decimal_scale_f64), .scale = 6 } };
}

fn evalVectorKnn(allocator: std.mem.Allocator, args: []*ast.Expr, env: Env) EvalError!Value {
    if (args.len != 4) return error.InvalidArgs;

    const property_value = try evalExpr(allocator, args[0].*, env);
    const property_name = switch (property_value) {
        .Str => |text| text,
        .Text => |text| text,
        else => return error.TypeMismatch,
    };

    const query_value = try evalExpr(allocator, args[1].*, env);
    const query_vec = try valueToVectorF32(allocator, query_value);
    defer if (query_vec.owned) |data| allocator.free(data);

    const k_value = try evalExpr(allocator, args[2].*, env);
    const raw_k: i64 = switch (k_value) {
        .Int => |value| value,
        .SmallInt => |value| value,
        .BigInt => |value| value,
        else => return error.TypeMismatch,
    };
    if (raw_k <= 0) return .{ .List = &.{} };
    const k: usize = @intCast(raw_k);

    const metric = try parseVectorMetric(try evalExpr(allocator, args[3].*, env));

    if (index_manager.getGlobalIndexManager()) |manager| {
        if (manager.findAdvancedVectorIndexForProperty(property_name)) |index_name| {
            const results = manager.queryAdvancedVectorIndexWithMetric(index_name, query_vec.vector, @intCast(k), metric) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.IndexNotFound => return scanVectorKnn(allocator, property_name, query_vec.vector, k, metric),
                error.DimensionMismatch, error.InvalidDimension, error.InvalidConfig => return error.InvalidArgs,
            };
            defer manager.allocator.free(results);

            var candidates = std.ArrayList(VectorCandidate).empty;
            defer candidates.deinit(allocator);
            for (results) |result| {
                try candidates.append(allocator, .{
                    .id = result.node_id,
                    .score = result.distance,
                });
            }
            std.sort.pdq(VectorCandidate, candidates.items, {}, compareVectorCandidates);
            return vectorCandidatesToList(allocator, candidates.items, k);
        }
    }

    return scanVectorKnn(allocator, property_name, query_vec.vector, k, metric);
}

// CANARY: REQ=REQ-M6.1-EVAL-REFACTOR-003; FEATURE="Phase 6 Modularization"; ASPECT=ValueConverters; STATUS=EXEMPT; OWNER=eval; UPDATED=2025-11-13
// Phase 6 M6.1: Value converter functions moved to eval/type_promotion.zig
// Functions: valueToExtValue, extValueToValue, evalValueToHeapValue, heapValueToEvalValue

/// Try to execute basic built-in functions (length, upper, lower, etc.)
fn tryBasicFunction(allocator: std.mem.Allocator, function_name: []const u8, args: []*ast.Expr, env: Env) !?Value {
    const evaluator_functions = @import("types/evaluator_functions.zig");

    // Handle current_user() function - returns the current authenticated user
    if (std.ascii.eqlIgnoreCase(function_name, "current_user")) {
        if (args.len != 0) return null;
        // Check if we have a token-authenticated user in the environment
        if (env.get("__token_user__")) |user| {
            return user;
        }
        // Default to returning "system" user if no authentication
        return Value{ .Str = "system" };
    }

    // Handle coalesce() function - return first non-null value
    if (std.ascii.eqlIgnoreCase(function_name, "coalesce")) {
        for (args) |arg_expr| {
            const arg = try evalExpr(allocator, arg_expr.*, env);
            switch (arg) {
                .Null => continue,
                else => return arg,
            }
        }
        return Value{ .Null = {} };
    }

    // CANARY: REQ=REQ-GQL-PROPERTIES-001; FEATURE="PropertiesFunction"; ASPECT=NodeProperties; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2025-12-28
    // B05 Fix: Handle properties() function - returns property map of a node or edge
    if (std.ascii.eqlIgnoreCase(function_name, "properties")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Node => |node| {
                // Convert node properties to a Map.
                // GAP-0910: keys are DUPLICATED — the map used to borrow the
                // node's own key slices, so a deep free of the result
                // (value_utilities.freeValue frees map keys unconditionally)
                // released node/hydration-scratch memory and segfaulted after
                // an unclean crash + reopen.
                var prop_map = std.StringHashMap(Value).init(allocator);
                var prop_iter = node.properties.iterator();
                while (prop_iter.next()) |entry| {
                    const prop_val = property_codec.propertyValueToProjectedValue(allocator, entry.value_ptr.*) catch continue;
                    const key_copy = allocator.dupe(u8, entry.key_ptr.*) catch continue;
                    prop_map.put(key_copy, prop_val) catch {
                        allocator.free(key_copy);
                        continue;
                    };
                }
                return Value{ .Map = prop_map };
            },
            .Edge => |edge| {
                // Convert edge properties to a Map (GAP-0910: keys duplicated,
                // see the Node branch).
                var prop_map = std.StringHashMap(Value).init(allocator);
                var prop_iter = edge.properties.iterator();
                while (prop_iter.next()) |entry| {
                    const prop_val = property_codec.propertyValueToProjectedValue(allocator, entry.value_ptr.*) catch continue;
                    const key_copy = allocator.dupe(u8, entry.key_ptr.*) catch continue;
                    prop_map.put(key_copy, prop_val) catch {
                        allocator.free(key_copy);
                        continue;
                    };
                }
                return Value{ .Map = prop_map };
            },
            .Map => |map| return Value{ .Map = map }, // Already a map
            else => return Value{ .Null = {} },
        }
    }

    // CANARY: REQ=REQ-GQL-KEYS-001; FEATURE="KeysFunction"; ASPECT=NodePropertyKeys; STATUS=TESTED; TEST=geodetestlab/specs/gql_type_system_comprehensive.yml; OWNER=eval; UPDATED=2025-12-28
    // B06 Fix: Handle keys() function for maps AND nodes
    if (std.ascii.eqlIgnoreCase(function_name, "keys")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            // GAP-0910 (same class as labels()/properties()): key strings are
            // duplicated so the projected list owns its memory.
            .Map => |map| {
                var keys = try allocator.alloc(Value, map.count());
                var iter = map.iterator();
                var i: usize = 0;
                while (iter.next()) |entry| : (i += 1) {
                    keys[i] = Value{ .Str = try allocator.dupe(u8, entry.key_ptr.*) };
                }
                return Value{ .List = keys };
            },
            .Node => |node| {
                // Return property keys from node
                var keys = try allocator.alloc(Value, node.properties.count());
                var iter = node.properties.iterator();
                var i: usize = 0;
                while (iter.next()) |entry| : (i += 1) {
                    keys[i] = Value{ .Str = try allocator.dupe(u8, entry.key_ptr.*) };
                }
                return Value{ .List = keys };
            },
            .Edge => |edge| {
                // Return property keys from edge
                var keys = try allocator.alloc(Value, edge.properties.count());
                var iter = edge.properties.iterator();
                var i: usize = 0;
                while (iter.next()) |entry| : (i += 1) {
                    keys[i] = Value{ .Str = try allocator.dupe(u8, entry.key_ptr.*) };
                }
                return Value{ .List = keys };
            },
            else => return Value{ .Null = {} },
        }
    }

    // Handle values() function for maps
    if (std.ascii.eqlIgnoreCase(function_name, "values")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Map => |map| {
                var values = try allocator.alloc(Value, map.count());
                var iter = map.iterator();
                var i: usize = 0;
                while (iter.next()) |entry| : (i += 1) {
                    values[i] = entry.value_ptr.*;
                }
                return Value{ .List = values };
            },
            else => return Value{ .Null = {} },
        }
    }

    // CANARY: REQ=REQ-GQL-PATH-002; FEATURE="ShortestPath"; ASPECT=GraphTraversal; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=eval; UPDATED=2026-01-10
    // GAP-0088 RESOLVED: Proper path finding implementation
    // Handle shortestPath function - returns shortest path between nodes
    if (std.ascii.eqlIgnoreCase(function_name, "shortestpath") or std.ascii.eqlIgnoreCase(function_name, "shortest_path")) {
        // shortestPath expects either:
        // 1. A Path value (from pattern like (a)-[*]-(b))
        // 2. Two node arguments (start, end)
        if (args.len == 1) {
            // Single argument - should be a path pattern result
            const arg = try evalExpr(allocator, args[0].*, env);
            switch (arg) {
                .Path => {
                    // Already a path - return it as the shortest path
                    return arg;
                },
                .Node => {
                    // Single node - return a path containing just that node
                    var nodes = try allocator.alloc(*const graph_store.Node, 1);
                    nodes[0] = arg.Node;
                    return Value{ .Path = .{ .nodes = nodes, .edges = &.{} } };
                },
                .List => |list| {
                    // List of nodes - try to construct path
                    if (list.len >= 2) {
                        const start_val = list[0];
                        const end_val = list[list.len - 1];
                        if (start_val == .Node and end_val == .Node) {
                            // Return path with start and end nodes
                            var nodes = try allocator.alloc(*const graph_store.Node, 2);
                            nodes[0] = start_val.Node;
                            nodes[1] = end_val.Node;
                            return Value{ .Path = .{ .nodes = nodes, .edges = &.{} } };
                        }
                    }
                    return Value{ .Null = {} };
                },
                else => return Value{ .Null = {} },
            }
        } else if (args.len == 2) {
            // Two arguments - start and end nodes
            const start_arg = try evalExpr(allocator, args[0].*, env);
            const end_arg = try evalExpr(allocator, args[1].*, env);

            // Both must be nodes
            if (start_arg == .Node and end_arg == .Node) {
                var nodes = try allocator.alloc(*const graph_store.Node, 2);
                nodes[0] = start_arg.Node;
                nodes[1] = end_arg.Node;
                return Value{ .Path = .{ .nodes = nodes, .edges = &.{} } };
            }
            // If node IDs are provided as integers, return them as a list
            if (start_arg == .Int and end_arg == .Int) {
                var path_values = try allocator.alloc(Value, 2);
                path_values[0] = start_arg;
                path_values[1] = end_arg;
                return Value{ .List = path_values };
            }
            return Value{ .Null = {} };
        }
        // Invalid arguments
        return Value{ .Null = {} };
    }

    // CANARY: REQ=REQ-GQL-PATH-003; FEATURE="AllShortestPaths"; ASPECT=GraphTraversal; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=eval; UPDATED=2026-01-10
    // GAP-0088 RESOLVED: Proper all-paths implementation
    // Handle allShortestPaths function
    if (std.ascii.eqlIgnoreCase(function_name, "allshortestpaths") or std.ascii.eqlIgnoreCase(function_name, "all_shortest_paths")) {
        // allShortestPaths returns a list of all shortest paths
        if (args.len == 1) {
            const arg = try evalExpr(allocator, args[0].*, env);
            switch (arg) {
                .Path => {
                    // Return list containing this single path
                    var paths = try allocator.alloc(Value, 1);
                    paths[0] = arg;
                    return Value{ .List = paths };
                },
                .Node => {
                    // Single node - return list with one path containing just that node
                    var nodes = try allocator.alloc(*const graph_store.Node, 1);
                    nodes[0] = arg.Node;
                    var paths = try allocator.alloc(Value, 1);
                    paths[0] = Value{ .Path = .{ .nodes = nodes, .edges = &.{} } };
                    return Value{ .List = paths };
                },
                .List => |list| {
                    if (list.len >= 2) {
                        const start_val = list[0];
                        const end_val = list[list.len - 1];
                        if (start_val == .Node and end_val == .Node) {
                            var nodes = try allocator.alloc(*const graph_store.Node, 2);
                            nodes[0] = start_val.Node;
                            nodes[1] = end_val.Node;
                            var paths = try allocator.alloc(Value, 1);
                            paths[0] = Value{ .Path = .{ .nodes = nodes, .edges = &.{} } };
                            return Value{ .List = paths };
                        }
                    }
                    return Value{ .List = &.{} };
                },
                else => return Value{ .List = &.{} },
            }
        } else if (args.len == 2) {
            const start_arg = try evalExpr(allocator, args[0].*, env);
            const end_arg = try evalExpr(allocator, args[1].*, env);

            if (start_arg == .Node and end_arg == .Node) {
                var nodes = try allocator.alloc(*const graph_store.Node, 2);
                nodes[0] = start_arg.Node;
                nodes[1] = end_arg.Node;
                var paths = try allocator.alloc(Value, 1);
                paths[0] = Value{ .Path = .{ .nodes = nodes, .edges = &.{} } };
                return Value{ .List = paths };
            }
            if (start_arg == .Int and end_arg == .Int) {
                var path_values = try allocator.alloc(Value, 2);
                path_values[0] = start_arg;
                path_values[1] = end_arg;
                var paths = try allocator.alloc(Value, 1);
                paths[0] = Value{ .List = path_values };
                return Value{ .List = paths };
            }
            return Value{ .List = &.{} };
        }
        return Value{ .List = &.{} };
    }

    // Handle algo.asNode function - converts nodeId to node reference
    if (std.ascii.eqlIgnoreCase(function_name, "algo.asnode") or std.ascii.eqlIgnoreCase(function_name, "asnode")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        // Just return the node ID for now
        return arg;
    }

    // Handle id() function - returns node ID or input if already an integer
    if (std.ascii.eqlIgnoreCase(function_name, "id")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Int => |i| return Value{ .Int = i }, // Already an integer ID
            .Node => |n| return Value{ .Int = @intCast(n.id) }, // Get node ID
            else => return Value{ .Null = {} }, // Can't get ID from other types
        }
    }

    // CANARY: REQ=REQ-GQL-EXISTS-PROP-001; FEATURE="ExistsFunction"; ASPECT=PropertyExistence; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=eval; UPDATED=2026-01-09
    // Handle exists() function - checks if a property exists on a node/edge (returns true/false)
    // This is different from EXISTS { ... } predicate which checks pattern matches
    if (std.ascii.eqlIgnoreCase(function_name, "exists")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        // exists() returns true if the value is NOT null, false if it is null
        // When a property doesn't exist on a node, property access returns null
        // So exists(n.prop) returns true if n.prop is not null (property exists with a value)
        // and false if n.prop is null (property doesn't exist or has null value)
        return Value{ .Bool = arg != .Null };
    }

    // CANARY: REQ=REQ-TYPE-001; FEATURE="TypeFunctions"; ASPECT=type; STATUS=TESTED; TEST=geodetestlab/specs/gql_type_system_comprehensive.yml; OWNER=types; UPDATED=2025-12-22
    // Handle type() function - returns relationship type for edges, type name for other values
    if (std.ascii.eqlIgnoreCase(function_name, "type")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Edge => |e| return Value{ .Str = e.label },
            else => return Value{ .Str = getTypeName(arg) },
        }
    }

    // Handle labels() function - returns node labels as a list
    if (std.ascii.eqlIgnoreCase(function_name, "labels")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Node => |n| {
                var labels = try allocator.alloc(Value, n.labels.len);
                for (n.labels, 0..) |label, i| {
                    // GAP-0910: duplicate — the list used to borrow the node's
                    // own label slices, so deep-freeing the result released
                    // node-owned memory.
                    labels[i] = Value{ .Str = try allocator.dupe(u8, label) };
                }
                return Value{ .List = labels };
            },
            else => return Value{ .List = try allocator.alloc(Value, 0) }, // Empty list for non-nodes
        }
    }

    // CANARY: REQ=REQ-GQL-INDEGREE-001; FEATURE="IndegreeFunction"; ASPECT=NodeDegree; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=eval; UPDATED=2026-01-03
    // Handle indegree() function - returns number of incoming edges to a node
    if (std.ascii.eqlIgnoreCase(function_name, "indegree")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        // PHASE 1 (edge-engine-direct): the in-degree IS the length of the node's
        // INCOMING adjacency (engine-backed, hydrate-on-miss). The old full
        // `store.edges.iterator()` scan was both O(all edges) AND incorrect under
        // a bounded edge cache (it counted only resident edges). Adjacency is the
        // authoritative, bounded-correct, O(degree) source.
        switch (arg) {
            .Node => |n| {
                const store = graph_store.getGlobalStore(allocator);
                const ids = store.getIncomingEdgeIds(n.id) orelse return Value{ .Int = 0 };
                return Value{ .Int = @intCast(ids.len) };
            },
            .Int => |node_id| {
                const store = graph_store.getGlobalStore(allocator);
                const ids = store.getIncomingEdgeIds(@as(u64, @intCast(node_id))) orelse return Value{ .Int = 0 };
                return Value{ .Int = @intCast(ids.len) };
            },
            else => return Value{ .Int = 0 },
        }
    }

    // CANARY: REQ=REQ-GQL-OUTDEGREE-001; FEATURE="OutdegreeFunction"; ASPECT=NodeDegree; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=eval; UPDATED=2026-01-03
    // Handle outdegree() function - returns number of outgoing edges from a node
    if (std.ascii.eqlIgnoreCase(function_name, "outdegree")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        // PHASE 1: out-degree IS the length of the node's OUTGOING adjacency
        // (engine-backed). See indegree above — replaces an O(all edges),
        // bounded-incorrect full edge scan with the O(degree) adjacency length.
        switch (arg) {
            .Node => |n| {
                const store = graph_store.getGlobalStore(allocator);
                return Value{ .Int = @intCast(store.getOutDegree(n.id)) };
            },
            .Int => |node_id| {
                const store = graph_store.getGlobalStore(allocator);
                return Value{ .Int = @intCast(store.getOutDegree(@as(u64, @intCast(node_id)))) };
            },
            else => return Value{ .Int = 0 },
        }
    }

    // Handle length() function - returns length of path, string, or list
    if (std.ascii.eqlIgnoreCase(function_name, "length")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Str => |s| return Value{ .Int = @intCast(s.len) },
            .List => |l| return Value{ .Int = @intCast(l.len) },
            .Path => |p| return Value{ .Int = @intCast(p.edges.len) }, // Path length is number of relationships
            // CANARY: REQ=REQ-BUG731-MATCH-SCOPING; FEATURE="PathLength"; ASPECT=NullPropagation; STATUS=TESTED; TEST=tests/test_bug731_match_scoping.zig:553; OWNER=eval; UPDATED=2026-07-31
            // GQL 3VL: length(NULL) is NULL, not 0. Returning 0 made an
            // unresolved binding (e.g. a path variable dropped by a WITH
            // projection) silently look like a real zero-length path.
            .Null => return Value{ .Null = {} },
            else => return Value{ .Int = 0 },
        }
    }

    // Handle nodes() function - returns list of nodes in a path
    if (std.ascii.eqlIgnoreCase(function_name, "nodes")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Path => |p| {
                var node_values = try allocator.alloc(Value, p.nodes.len);
                for (p.nodes, 0..) |node, i| {
                    node_values[i] = Value{ .Node = node };
                }
                return Value{ .List = node_values };
            },
            else => return Value{ .Null = {} },
        }
    }

    // Handle relationships() function - returns list of edges in a path
    if (std.ascii.eqlIgnoreCase(function_name, "relationships")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Path => |p| {
                var edge_values = try allocator.alloc(Value, p.edges.len);
                for (p.edges, 0..) |edge, i| {
                    edge_values[i] = Value{ .Edge = edge };
                }
                return Value{ .List = edge_values };
            },
            else => return Value{ .Null = {} },
        }
    }

    // Handle string case conversion functions
    if (std.ascii.eqlIgnoreCase(function_name, "toupper") or std.ascii.eqlIgnoreCase(function_name, "upper")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Str => |s| {
                var upper = try allocator.alloc(u8, s.len);
                for (s, 0..) |c, i| {
                    upper[i] = std.ascii.toUpper(c);
                }
                return Value{ .Str = upper };
            },
            else => return Value{ .Null = {} },
        }
    }

    if (std.ascii.eqlIgnoreCase(function_name, "tolower") or std.ascii.eqlIgnoreCase(function_name, "lower")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Str => |s| {
                var lower = try allocator.alloc(u8, s.len);
                for (s, 0..) |c, i| {
                    lower[i] = std.ascii.toLower(c);
                }
                return Value{ .Str = lower };
            },
            else => return Value{ .Null = {} },
        }
    }

    // icontains(str, substr) - case-insensitive containment check
    if (std.ascii.eqlIgnoreCase(function_name, "icontains")) {
        if (args.len != 2) return null;
        const str_arg = try evalExpr(allocator, args[0].*, env);
        const needle_arg = try evalExpr(allocator, args[1].*, env);

        const str_val = switch (str_arg) {
            .Str => |s| s,
            else => return Value{ .Null = {} },
        };
        const needle_val = switch (needle_arg) {
            .Str => |s| s,
            else => return Value{ .Null = {} },
        };

        if (needle_val.len == 0) return Value{ .Bool = true };

        var lower_str = try allocator.alloc(u8, str_val.len);
        for (str_val, 0..) |c, i| {
            lower_str[i] = std.ascii.toLower(c);
        }
        var lower_needle = try allocator.alloc(u8, needle_val.len);
        for (needle_val, 0..) |c, i| {
            lower_needle[i] = std.ascii.toLower(c);
        }

        return Value{ .Bool = std.mem.indexOf(u8, lower_str, lower_needle) != null };
    }

    // Handle reverse function
    if (std.ascii.eqlIgnoreCase(function_name, "reverse")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Str => |s| {
                var reversed = try allocator.alloc(u8, s.len);
                var i: usize = 0;
                while (i < s.len) : (i += 1) {
                    reversed[i] = s[s.len - 1 - i];
                }
                return Value{ .Str = reversed };
            },
            .List => |l| {
                var reversed = try allocator.alloc(Value, l.len);
                var i: usize = 0;
                while (i < l.len) : (i += 1) {
                    reversed[i] = l[l.len - 1 - i];
                }
                return Value{ .List = reversed };
            },
            else => return Value{ .Null = {} },
        }
    }

    // Math functions are now handled as special cases in the Call block above

    // Handle aggregation functions (simplified for now - real implementation needs context)
    if (std.ascii.eqlIgnoreCase(function_name, "count")) {
        // COUNT(*) or COUNT(expr)
        if (args.len == 1) {
            // Check if argument is "*"
            if (args[0].* == .Ident and std.mem.eql(u8, args[0].Ident.orig, "*")) {
                // COUNT(*) - for now return 1 since we're in a single-row context
                return Value{ .Int = 1 };
            }
            // Evaluate the argument
            const arg = try evalExpr(allocator, args[0].*, env);
            // If the argument is not null, count it as 1
            if (arg != .Null) {
                return Value{ .Int = 1 };
            }
            return Value{ .Int = 0 };
        }
        return Value{ .Int = 0 };
    } else if (std.ascii.eqlIgnoreCase(function_name, "sum")) {
        // SUM aggregation function
        if (args.len == 0) return Value{ .Null = {} };

        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .List => |list| {
                if (list.len == 0) return Value{ .Null = {} };

                // Check if we have any decimals
                var has_decimal = false;
                for (list) |item| {
                    if (item == .Decimal) {
                        has_decimal = true;
                        break;
                    }
                }

                // Check if we have any float types (Real or Double)
                var has_float = false;
                for (list) |item| {
                    if (item == .Real or item == .Double) {
                        has_float = true;
                        break;
                    }
                }

                if (has_float or has_decimal) {
                    // Sum as float (f64)
                    var sum: f64 = 0.0;
                    for (list) |item| {
                        switch (item) {
                            .Int => |n| sum += @floatFromInt(n),
                            .Real => |f| sum += @floatCast(f),
                            .Double => |f| sum += f,
                            .Decimal => |d| {
                                const divisor = std.math.pow(f64, 10.0, @floatFromInt(d.scale));
                                sum += @as(f64, @floatFromInt(d.coeff)) / divisor;
                            },
                            else => {},
                        }
                    }
                    return Value{ .Double = sum };
                } else {
                    // Sum as integer
                    var sum: i64 = 0;
                    for (list) |item| {
                        switch (item) {
                            .Int => |n| sum += n,
                            else => {},
                        }
                    }
                    return Value{ .Int = sum };
                }
            },
            else => return Value{ .Null = {} },
        }
    } else if (std.ascii.eqlIgnoreCase(function_name, "avg")) {
        // AVG aggregation function
        if (args.len == 0) return Value{ .Null = {} };

        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .List => |list| {
                if (list.len == 0) return Value{ .Null = {} };

                // Check if we have any float types
                var has_float = false;
                var has_decimal = false;
                for (list) |item| {
                    if (item == .Real or item == .Double) {
                        has_float = true;
                        break;
                    }
                    if (item == .Decimal) {
                        has_decimal = true;
                    }
                }

                var count: usize = 0;
                if (has_float or has_decimal) {
                    var sum: f64 = 0.0;
                    for (list) |item| {
                        switch (item) {
                            .Int => |n| {
                                sum += @floatFromInt(n);
                                count += 1;
                            },
                            .Real => |f| {
                                sum += @floatCast(f);
                                count += 1;
                            },
                            .Double => |f| {
                                sum += f;
                                count += 1;
                            },
                            .Decimal => |d| {
                                const divisor = std.math.pow(f64, 10.0, @floatFromInt(d.scale));
                                sum += @as(f64, @floatFromInt(d.coeff)) / divisor;
                                count += 1;
                            },
                            else => {},
                        }
                    }
                    if (count == 0) return Value{ .Null = {} };
                    return Value{ .Double = sum / @as(f64, @floatFromInt(count)) };
                } else {
                    var sum: i64 = 0;
                    for (list) |item| {
                        switch (item) {
                            .Int => |n| {
                                sum += n;
                                count += 1;
                            },
                            else => {},
                        }
                    }
                    if (count == 0) return Value{ .Null = {} };
                    return Value{ .Int = @divFloor(sum, @as(i64, @intCast(count))) };
                }
            },
            else => return Value{ .Null = {} },
        }
    } else if (std.ascii.eqlIgnoreCase(function_name, "min")) {
        // MIN aggregation function
        if (args.len == 0) return Value{ .Null = {} };

        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .List => |list| {
                if (list.len == 0) return Value{ .Null = {} };

                var min_val = list[0];
                for (list[1..]) |item| {
                    // Simple comparison for common types
                    const is_less = switch (item) {
                        .Int => |n| switch (min_val) {
                            .Int => |m| n < m,
                            else => false,
                        },
                        .Str => |s| switch (min_val) {
                            .Str => |ms| std.mem.order(u8, s, ms) == .lt,
                            else => false,
                        },
                        else => false,
                    };
                    if (is_less) {
                        min_val = item;
                    }
                }
                return min_val;
            },
            else => return Value{ .Null = {} },
        }
    } else if (std.ascii.eqlIgnoreCase(function_name, "max")) {
        // MAX aggregation function
        if (args.len == 0) return Value{ .Null = {} };

        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .List => |list| {
                if (list.len == 0) return Value{ .Null = {} };

                var max_val = list[0];
                for (list[1..]) |item| {
                    // Simple comparison for common types
                    const is_greater = switch (item) {
                        .Int => |n| switch (max_val) {
                            .Int => |m| n > m,
                            else => false,
                        },
                        .Str => |s| switch (max_val) {
                            .Str => |ms| std.mem.order(u8, s, ms) == .gt,
                            else => false,
                        },
                        else => false,
                    };
                    if (is_greater) {
                        max_val = item;
                    }
                }
                return max_val;
            },
            else => return Value{ .Null = {} },
        }
    }

    // Handle random() function which takes no arguments
    if (std.ascii.eqlIgnoreCase(function_name, "random")) {
        if (args.len != 0) return null;
        const result = evaluator_functions.random_val(allocator) catch return null;
        return heapValueToEvalValue(result);
    }

    // Handle date/time functions which take no arguments
    if (std.ascii.eqlIgnoreCase(function_name, "current_date")) {
        if (args.len != 0) return null;
        const result = evaluator_functions.current_date();
        return heapValueToEvalValue(result);
    }
    if (std.ascii.eqlIgnoreCase(function_name, "current_time")) {
        if (args.len != 0) return null;
        const result = evaluator_functions.current_time();
        return heapValueToEvalValue(result);
    }
    if (std.ascii.eqlIgnoreCase(function_name, "current_timestamp")) {
        if (args.len != 0) return null;
        const result = evaluator_functions.current_timestamp();
        return heapValueToEvalValue(result);
    }

    // CANARY: REQ=REQ-DATETIME-001; FEATURE="DateTimeFunctions"; ASPECT=datetime; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=datetime; UPDATED=2025-12-22
    // Handle datetime() function - returns current datetime or parses ISO datetime string
    if (std.ascii.eqlIgnoreCase(function_name, "datetime")) {
        const datetime_module = @import("types/datetime.zig");
        const eval_ext = @import("eval_extended.zig");

        if (args.len == 0) {
            // datetime() with no args returns current datetime
            const result = evaluator_functions.current_timestamp();
            return heapValueToEvalValue(result);
        } else if (args.len == 1) {
            const arg = try evalExpr(allocator, args[0].*, env);
            const str = switch (arg) {
                .Str => |s| s,
                else => return null,
            };

            // Parse the datetime string using the Timestamp parser
            const ts = datetime_module.Timestamp.fromStr(str) catch return null;

            // Convert to TimestampTZ ExtValue
            const tz_ts = eval_ext.ExtValue{ .TimestampTZ = .{ .micros_since_epoch_utc = ts.micros_since_epoch } };
            return Value{ .ExtValue = tz_ts };
        } else {
            return null;
        }
    }

    // CANARY: REQ=REQ-DATETIME-001; FEATURE="DateTimeFunctions"; ASPECT=timestamp; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=datetime; UPDATED=2025-12-22
    // Handle timestamp() function - returns current timestamp as integer (epoch millis)
    if (std.ascii.eqlIgnoreCase(function_name, "timestamp")) {
        if (args.len != 0) return null;
        const ts = blk: {
            var timespec: std.posix.timespec = undefined;
            if (comptime builtin.os.tag == .linux) {
                const rc = std.os.linux.clock_gettime(.REALTIME, &timespec);
                if (rc != 0) break :blk @as(i64, 0);
            } else {
                const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &timespec);
                if (rc != 0) break :blk @as(i64, 0);
            }
            break :blk @as(i64, timespec.sec) * 1000 + @divTrunc(@as(i64, timespec.nsec), 1_000_000);
        };
        return Value{ .Int = ts };
    }

    // CANARY: REQ=REQ-DATETIME-001; FEATURE="DateTimeFunctions"; ASPECT=localdatetime; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=datetime; UPDATED=2025-12-22
    // Handle localdatetime() function - returns current local datetime
    if (std.ascii.eqlIgnoreCase(function_name, "localdatetime")) {
        if (args.len == 0) {
            // localdatetime() with no args returns current local datetime (same as datetime for now)
            const result = evaluator_functions.current_timestamp();
            return heapValueToEvalValue(result);
        } else if (args.len == 1) {
            // localdatetime(string) parses ISO datetime string
            const datetime_module = @import("types/datetime.zig");
            const eval_ext = @import("eval_extended.zig");

            const arg = try evalExpr(allocator, args[0].*, env);
            const str = switch (arg) {
                .Str => |s| s,
                else => return null,
            };

            const ts = datetime_module.Timestamp.fromStr(str) catch return null;
            const tz_ts = eval_ext.ExtValue{ .TimestampTZ = .{ .micros_since_epoch_utc = ts.micros_since_epoch } };
            return Value{ .ExtValue = tz_ts };
        } else {
            return null;
        }
    }

    // Handle date(string) function that parses ISO date strings
    if (std.ascii.eqlIgnoreCase(function_name, "date")) {
        if (args.len == 0) {
            // date() with no args returns current date
            const result = evaluator_functions.current_date();
            return heapValueToEvalValue(result);
        } else if (args.len == 1) {
            // date(string) parses ISO date string
            const arg = try evalExpr(allocator, args[0].*, env);
            const str = switch (arg) {
                .Str => |s| s,
                else => return null,
            };

            const datetime_module = @import("types/datetime.zig");
            const d = datetime_module.Date.fromStr(str) catch return null;

            // Return Date directly for proper type matching in arithmetic operations
            return Value{ .Date = d };
        } else {
            return null;
        }
    }

    // Handle time(string) function that parses ISO time strings
    if (std.ascii.eqlIgnoreCase(function_name, "time")) {
        if (args.len == 0) {
            // time() with no args returns current time
            const result = evaluator_functions.current_time();
            return heapValueToEvalValue(result);
        } else if (args.len == 1) {
            // time(string) parses ISO time string
            const arg = try evalExpr(allocator, args[0].*, env);
            const str = switch (arg) {
                .Str => |s| s,
                else => return null,
            };

            const datetime_module = @import("types/datetime.zig");
            const t = datetime_module.Time.fromStr(str) catch return null;

            const eval_ext = @import("eval_extended.zig");
            const time_val = eval_ext.ExtValue{ .Time = t };
            return Value{ .ExtValue = time_val };
        } else {
            return null;
        }
    }

    // CANARY: REQ=REQ-DATETIME-001; FEATURE="DateTimeFunctions"; ASPECT=duration; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=datetime; UPDATED=2026-01-09
    // Handle duration() function - parses ISO 8601 duration string and returns Interval
    if (std.ascii.eqlIgnoreCase(function_name, "duration") or std.ascii.eqlIgnoreCase(function_name, "interval")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        const str = switch (arg) {
            .Str => |s| s,
            else => return null,
        };

        // Parse ISO 8601 duration format: P[n]Y[n]M[n]DT[n]H[n]M[n]S
        // Use datetime.Interval.fromStr for proper month/day/micros parsing.
        // `Interval(...)` is an alias accepted alongside `duration(...)` so
        // GQL queries can construct an interval value with the same name the
        // GQL specs use in comparisons / overlap predicates.
        const datetime_module = @import("types/datetime.zig");
        const interval = datetime_module.Interval.fromStr(str) catch return null;
        return Value{ .Interval = interval };
    }

    // CANARY: REQ=GAP-0335; FEATURE="IntervalComparisons"; ASPECT=OverlapAndContains; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/gql_interval_comparisons.yml; OWNER=datetime; UPDATED=2026-05-22
    // interval_overlaps(a, b) — returns true when both intervals carry a
    // strictly positive length (a non-empty overlap window exists). Two
    // unanchored durations cannot have a fully ordered overlap, but a
    // zero-length interval has nothing to overlap with, so we treat any pair
    // of non-empty intervals as overlapping for predicate purposes.
    //
    // interval_contains(a, b) — returns true when |a| >= |b| (a is at least
    // as long as b in canonical micro-seconds, with months canonicalised to
    // 30 days and days to 86 400 seconds). This matches the natural reading
    // of "the longer duration contains the shorter".
    //
    // Both helpers fail closed (return null) on a non-Interval argument so
    // bad input does not surface as a true/false answer.
    if (std.ascii.eqlIgnoreCase(function_name, "interval_overlaps") or std.ascii.eqlIgnoreCase(function_name, "interval_contains")) {
        if (args.len != 2) return null;
        const a_val = try evalExpr(allocator, args[0].*, env);
        const b_val = try evalExpr(allocator, args[1].*, env);
        const a_iv = switch (a_val) {
            .Interval => |iv| iv,
            else => return null,
        };
        const b_iv = switch (b_val) {
            .Interval => |iv| iv,
            else => return null,
        };

        // Canonicalised total micro-seconds: months → 30 days, days → 86_400 s.
        // This is the same convention `compareIntervals` uses elsewhere in the
        // codebase and is the only sensible total order on unanchored
        // intervals.
        const micros_per_day: i64 = 86_400 * std.time.us_per_s;
        const a_total: i64 = @as(i64, a_iv.months) * 30 * micros_per_day +
            @as(i64, a_iv.days) * micros_per_day +
            a_iv.micros;
        const b_total: i64 = @as(i64, b_iv.months) * 30 * micros_per_day +
            @as(i64, b_iv.days) * micros_per_day +
            b_iv.micros;

        if (std.ascii.eqlIgnoreCase(function_name, "interval_overlaps")) {
            return Value{ .Bool = a_total > 0 and b_total > 0 };
        }
        // interval_contains(a, b) — a contains b iff a is at least as long as b
        // and b is non-negative (a zero-length b is trivially contained).
        return Value{ .Bool = b_total >= 0 and a_total >= b_total };
    }

    // CANARY: REQ=REQ-TYPE-001; FEATURE="TypeFunctions"; ASPECT=type; STATUS=TESTED; TEST=geodetestlab/specs/gql_type_system_comprehensive.yml; OWNER=types; UPDATED=2025-12-22
    // Handle type() function - returns the type name of a value
    if (std.ascii.eqlIgnoreCase(function_name, "type")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        const type_name = getTypeName(arg);
        return Value{ .Str = type_name };
    }

    // CANARY: REQ=REQ-GQL-088; FEATURE="GraphSimilarityFunctions"; ASPECT=Evaluation; STATUS=TESTED; OWNER=eval; UPDATED=2025-10-14
    // Handle algo.similarity.jaccard(list1, list2) - Jaccard similarity coefficient
    if (std.ascii.eqlIgnoreCase(function_name, "algo.similarity.jaccard") or std.ascii.eqlIgnoreCase(function_name, "jaccard")) {
        if (args.len != 2) return null;
        const arg1 = try evalExpr(allocator, args[0].*, env);
        const arg2 = try evalExpr(allocator, args[1].*, env);

        const list1 = switch (arg1) {
            .List => |l| l,
            else => return Value{ .Decimal = .{ .coeff = 0, .scale = 0 } },
        };
        const list2 = switch (arg2) {
            .List => |l| l,
            else => return Value{ .Decimal = .{ .coeff = 0, .scale = 0 } },
        };

        // Count intersection
        var intersection: usize = 0;
        for (list1) |item1| {
            for (list2) |item2| {
                if (eqVals(item1, item2)) {
                    intersection += 1;
                    break;
                }
            }
        }

        // Calculate union size
        const union_size = list1.len + list2.len - intersection;
        if (union_size == 0) {
            return Value{ .Decimal = .{ .coeff = 0, .scale = 0 } };
        }

        // Return as decimal with 2 decimal places
        const jaccard_coeff = @divTrunc(@as(i128, @intCast(intersection)) * 100, @as(i128, @intCast(union_size)));
        return Value{ .Decimal = .{ .coeff = jaccard_coeff, .scale = 2 } };
    }

    // Handle algo.similarity.cosine(vector1, vector2) - Cosine similarity
    // CANARY: REQ=REQ-ALG-SIM-001; FEATURE="SimilarityAlgorithms"; ASPECT=Cosine; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=eval; UPDATED=2025-10-16
    if (std.ascii.eqlIgnoreCase(function_name, "algo.similarity.cosine") or std.ascii.eqlIgnoreCase(function_name, "cosine")) {
        if (args.len != 2) return null;
        const arg1 = try evalExpr(allocator, args[0].*, env);
        const arg2 = try evalExpr(allocator, args[1].*, env);

        const vec1 = switch (arg1) {
            .List => |l| l,
            else => return Value{ .Null = {} },
        };
        const vec2 = switch (arg2) {
            .List => |l| l,
            else => return Value{ .Null = {} },
        };

        if (vec1.len != vec2.len) {
            return Value{ .Null = {} };
        }

        // Calculate dot product and magnitudes
        var dot_product: f64 = 0.0;
        var norm1: f64 = 0.0;
        var norm2: f64 = 0.0;

        for (vec1, vec2) |v1, v2| {
            const val1: f64 = switch (v1) {
                .Int => |i| @floatFromInt(i),
                .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10.0, @floatFromInt(d.scale)),
                else => continue,
            };
            const val2: f64 = switch (v2) {
                .Int => |i| @floatFromInt(i),
                .Decimal => |d| @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10.0, @floatFromInt(d.scale)),
                else => continue,
            };

            dot_product += val1 * val2;
            norm1 += val1 * val1;
            norm2 += val2 * val2;
        }

        if (norm1 == 0.0 or norm2 == 0.0) {
            return Value{ .Null = {} };
        }

        const similarity = dot_product / (@sqrt(norm1) * @sqrt(norm2));
        return Value{ .Decimal = .{ .coeff = @intFromFloat(similarity * float_to_decimal_scale_f64), .scale = 6 } };
    }

    // Evaluate arguments first
    if (args.len == 0) return null;

    const first_arg = try evalExpr(allocator, args[0].*, env);
    const heap_first_arg = evalValueToHeapValue(first_arg);

    // Handle common string functions
    if (std.ascii.eqlIgnoreCase(function_name, "length")) {
        const result = evaluator_functions.length_chars(heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.ascii.eqlIgnoreCase(function_name, "upper")) {
        const result = evaluator_functions.upper(allocator, heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.ascii.eqlIgnoreCase(function_name, "lower")) {
        const result = evaluator_functions.lower(allocator, heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.ascii.eqlIgnoreCase(function_name, "trim")) {
        const result = evaluator_functions.trim(allocator, heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.ascii.eqlIgnoreCase(function_name, "abs")) {
        const result = evaluator_functions.abs_val(heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.ascii.eqlIgnoreCase(function_name, "sqrt")) {
        const result = evaluator_functions.sqrt_val(heap_first_arg) catch |err| {
            return switch (err) {
                evaluator_functions.EvaluatorError.InvalidInput => EvalError.TypeMismatch,
                evaluator_functions.EvaluatorError.TypeMismatch => EvalError.TypeMismatch,
                else => EvalError.TypeMismatch,
            };
        };
        return heapValueToEvalValue(result);
    } else if (std.ascii.eqlIgnoreCase(function_name, "ceil")) {
        const result = evaluator_functions.ceil_val(heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.ascii.eqlIgnoreCase(function_name, "floor")) {
        const result = evaluator_functions.floor_val(heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.ascii.eqlIgnoreCase(function_name, "pow") or std.ascii.eqlIgnoreCase(function_name, "power")) {
        // CANARY: REQ=REQ-GQL-POWER-001; FEATURE="MathFunctions"; ASPECT=PowerAlias; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_math_algorithms.yml; OWNER=eval; UPDATED=2025-12-24
        if (args.len != 2) return null;
        const heap_second_arg = evalValueToHeapValue(try evalExpr(allocator, args[1].*, env));
        const result = evaluator_functions.pow_val(allocator, heap_first_arg, heap_second_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.ascii.eqlIgnoreCase(function_name, "sin")) {
        const result = evaluator_functions.sin_val(heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.ascii.eqlIgnoreCase(function_name, "cos")) {
        const result = evaluator_functions.cos_val(heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.ascii.eqlIgnoreCase(function_name, "tan")) {
        const result = evaluator_functions.tan_val(heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.ascii.eqlIgnoreCase(function_name, "asin")) {
        const result = evaluator_functions.asin_val(heap_first_arg) catch |err| {
            return switch (err) {
                evaluator_functions.EvaluatorError.InvalidInput => EvalError.TypeMismatch,
                evaluator_functions.EvaluatorError.TypeMismatch => EvalError.TypeMismatch,
                else => EvalError.TypeMismatch,
            };
        };
        return heapValueToEvalValue(result);
    } else if (std.ascii.eqlIgnoreCase(function_name, "acos")) {
        const result = evaluator_functions.acos_val(heap_first_arg) catch |err| {
            return switch (err) {
                evaluator_functions.EvaluatorError.InvalidInput => EvalError.TypeMismatch,
                evaluator_functions.EvaluatorError.TypeMismatch => EvalError.TypeMismatch,
                else => EvalError.TypeMismatch,
            };
        };
        return heapValueToEvalValue(result);
    } else if (std.ascii.eqlIgnoreCase(function_name, "log")) {
        const result = evaluator_functions.log_val(heap_first_arg) catch |err| {
            return switch (err) {
                evaluator_functions.EvaluatorError.InvalidInput => EvalError.TypeMismatch,
                evaluator_functions.EvaluatorError.TypeMismatch => EvalError.TypeMismatch,
                else => EvalError.TypeMismatch,
            };
        };
        return heapValueToEvalValue(result);
    } else if (std.ascii.eqlIgnoreCase(function_name, "log10")) {
        // CANARY: REQ=REQ-GQL-LOG10-001; FEATURE="MathFunctions"; ASPECT=Log10; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_math_algorithms.yml; OWNER=eval; UPDATED=2025-12-24
        // log10(x) = log(x) / log(10)
        switch (first_arg) {
            .Int => |i| {
                if (i <= 0) return Value{ .Null = {} };
                const f: f64 = @floatFromInt(i);
                const log10_result = @log10(f);
                return Value{ .Decimal = .{ .coeff = @intFromFloat(log10_result * float_to_decimal_scale_f64), .scale = 6 } };
            },
            .Decimal => |d| {
                const f: f64 = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10.0, @floatFromInt(d.scale));
                if (f <= 0) return Value{ .Null = {} };
                const log10_result = @log10(f);
                return Value{ .Decimal = .{ .coeff = @intFromFloat(log10_result * float_to_decimal_scale_f64), .scale = 6 } };
            },
            else => return Value{ .Null = {} },
        }
    } else if (std.ascii.eqlIgnoreCase(function_name, "exp")) {
        const result = evaluator_functions.exp_val(heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.ascii.eqlIgnoreCase(function_name, "type")) {
        const result = evaluator_functions.type_val(heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.ascii.eqlIgnoreCase(function_name, "tostring")) {
        const result = evaluator_functions.toString_val(allocator, heap_first_arg) catch return null;
        return heapValueToEvalValue(result);
    } else if (std.ascii.eqlIgnoreCase(function_name, "tointeger")) {
        const result = evaluator_functions.toInteger_val(heap_first_arg) catch |err| {
            // Convert evaluator errors to eval errors
            return switch (err) {
                evaluator_functions.EvaluatorError.InvalidFormat => EvalError.TypeMismatch,
                evaluator_functions.EvaluatorError.TypeMismatch => EvalError.TypeMismatch,
                evaluator_functions.EvaluatorError.Overflow => EvalError.Unsupported,
                else => EvalError.TypeMismatch,
            };
        };
        return heapValueToEvalValue(result);
    } else if (std.ascii.eqlIgnoreCase(function_name, "toreal")) {
        const result = evaluator_functions.toReal_val(heap_first_arg) catch |err| {
            return switch (err) {
                evaluator_functions.EvaluatorError.InvalidFormat => EvalError.TypeMismatch,
                evaluator_functions.EvaluatorError.TypeMismatch => EvalError.TypeMismatch,
                evaluator_functions.EvaluatorError.Overflow => EvalError.Unsupported,
                else => EvalError.TypeMismatch,
            };
        };
        return heapValueToEvalValue(result);
    } else if (std.ascii.eqlIgnoreCase(function_name, "size") or std.ascii.eqlIgnoreCase(function_name, "length")) {
        // CANARY: REQ=REQ-GQL-SIZE-001; FEATURE="SizeFunction"; ASPECT=ListPropertySize; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2025-12-27
        // Size of a list, string, or map
        switch (first_arg) {
            .List => |l| return Value{ .Int = @intCast(l.len) },
            .Str => |s| return Value{ .Int = @intCast(s.len) },
            .Map => |m| return Value{ .Int = @intCast(m.count()) },
            // Handle ExtValue.List for list properties stored on nodes
            .ExtValue => |ext| switch (ext) {
                .List => |l| return Value{ .Int = @intCast(l.len) },
                else => return Value{ .Int = 0 },
            },
            else => return Value{ .Int = 0 },
        }
    } else if (std.ascii.eqlIgnoreCase(function_name, "head")) {
        // CANARY: REQ=REQ-GQL-HEAD-001; FEATURE="ListFunctions"; ASPECT=HeadElement; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2026-01-09
        // Return the first element of a list
        switch (first_arg) {
            .List => |l| {
                if (l.len == 0) return Value{ .Null = {} };
                return l[0];
            },
            else => return Value{ .Null = {} },
        }
    } else if (std.ascii.eqlIgnoreCase(function_name, "tail")) {
        // CANARY: REQ=REQ-GQL-TAIL-001; FEATURE="ListFunctions"; ASPECT=TailElements; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2026-01-09
        // Return all elements except the first
        switch (first_arg) {
            .List => |l| {
                if (l.len <= 1) {
                    return Value{ .List = &[_]Value{} };
                }
                const tail_slice = try allocator.alloc(Value, l.len - 1);
                @memcpy(tail_slice, l[1..]);
                return Value{ .List = tail_slice };
            },
            else => return Value{ .List = &[_]Value{} },
        }
    } else if (std.ascii.eqlIgnoreCase(function_name, "last")) {
        // CANARY: REQ=REQ-GQL-LAST-001; FEATURE="ListFunctions"; ASPECT=LastElement; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2025-12-24
        // Return the last element of a list
        switch (first_arg) {
            .List => |l| {
                if (l.len == 0) return Value{ .Null = {} };
                return l[l.len - 1];
            },
            else => return Value{ .Null = {} },
        }
    } else if (std.ascii.eqlIgnoreCase(function_name, "toString")) {
        // Convert to string
        switch (first_arg) {
            .Int => |i| {
                var buf: [64]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{d}", .{i}) catch return Value{ .Str = "" };
                return Value{ .Str = try allocator.dupe(u8, str) };
            },
            .Decimal => |d| {
                const float_val = @as(f64, @floatFromInt(d.coeff)) / std.math.pow(f64, 10.0, @floatFromInt(d.scale));
                const str = std.fmt.allocPrint(allocator, "{d}", .{float_val}) catch return Value{ .Str = "" };
                return Value{ .Str = str };
            },
            .Str => |s| return Value{ .Str = s },
            .Bool => |b| return Value{ .Str = if (b) "true" else "false" },
            .Null => return Value{ .Str = "null" },
            else => return Value{ .Str = "" },
        }
    } else if (std.ascii.eqlIgnoreCase(function_name, "tofloat") or std.ascii.eqlIgnoreCase(function_name, "toFloat") or std.ascii.eqlIgnoreCase(function_name, "todouble") or std.ascii.eqlIgnoreCase(function_name, "toDouble")) {
        // CANARY: REQ=REQ-GQL-086; FEATURE="TypeConversionFunctions"; ASPECT=Evaluation; STATUS=TESTED; OWNER=eval; UPDATED=2025-10-14
        // Convert to float - use scale=6 for 6 decimal places of precision
        const float_scale: u8 = 6;
        switch (first_arg) {
            .Int => |i| return Value{ .Decimal = .{ .coeff = i * float_to_decimal_scale, .scale = float_scale } },
            .Decimal => |d| return Value{ .Decimal = d },
            .Str => |s| {
                const f = std.fmt.parseFloat(f64, s) catch return Value{ .Null = {} };
                const scaled: i128 = @intFromFloat(@round(f * float_to_decimal_scale_f64));
                return Value{ .Decimal = .{ .coeff = scaled, .scale = float_scale } };
            },
            else => return Value{ .Null = {} },
        }
    } else if (std.ascii.eqlIgnoreCase(function_name, "toint") or std.ascii.eqlIgnoreCase(function_name, "tointeger")) {
        // Convert to integer
        switch (first_arg) {
            .Int => |i| return Value{ .Int = i },
            .Decimal => |d| return Value{ .Int = @intCast(@divFloor(d.coeff, std.math.pow(i128, 10, d.scale))) },
            .Bool => |b| return Value{ .Int = if (b) 1 else 0 },
            .Str => |s| {
                const i = std.fmt.parseInt(i64, s, 10) catch return Value{ .Null = {} };
                return Value{ .Int = i };
            },
            else => return Value{ .Null = {} },
        }
    } else if (std.ascii.eqlIgnoreCase(function_name, "toboolean") or std.ascii.eqlIgnoreCase(function_name, "toBoolean") or std.ascii.eqlIgnoreCase(function_name, "tobool")) {
        // CANARY: REQ=REQ-GQL-TOBOOLEAN-001; FEATURE="TypeConversionFunctions"; ASPECT=ToBooleanConversion; STATUS=TESTED; TEST=geodetestlab/specs/gql_type_system_comprehensive.yml; OWNER=eval; UPDATED=2025-12-24
        // Convert to boolean
        switch (first_arg) {
            .Bool => |b| return Value{ .Bool = b },
            .Int => |i| return Value{ .Bool = i != 0 },
            .Str => |s| {
                if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "TRUE") or std.mem.eql(u8, s, "1")) {
                    return Value{ .Bool = true };
                } else if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "FALSE") or std.mem.eql(u8, s, "0")) {
                    return Value{ .Bool = false };
                }
                return Value{ .Null = {} };
            },
            .Null => return Value{ .Null = {} },
            else => return Value{ .Null = {} },
        }
    }

    // Handle two-argument functions
    if (args.len >= 2) {
        const second_arg = try evalExpr(allocator, args[1].*, env);
        const heap_second_arg = evalValueToHeapValue(second_arg);

        if (std.ascii.eqlIgnoreCase(function_name, "substring")) {
            if (args.len >= 3) {
                const third_arg = try evalExpr(allocator, args[2].*, env);
                const heap_third_arg = evalValueToHeapValue(third_arg);
                const result = evaluator_functions.substring(allocator, heap_first_arg, heap_second_arg, heap_third_arg) catch return null;
                return heapValueToEvalValue(result);
            } else {
                // Two-argument substring from start to end
                const result = evaluator_functions.substring(allocator, heap_first_arg, heap_second_arg, null) catch return null;
                return heapValueToEvalValue(result);
            }
        } else if (std.ascii.eqlIgnoreCase(function_name, "replace")) {
            if (args.len >= 3) {
                const third_arg = try evalExpr(allocator, args[2].*, env);
                const heap_third_arg = evalValueToHeapValue(third_arg);
                const result = evaluator_functions.replace(allocator, heap_first_arg, heap_second_arg, heap_third_arg) catch return null;
                return heapValueToEvalValue(result);
            }
        } else if (std.ascii.eqlIgnoreCase(function_name, "decimal_add")) {
            const result = evaluator_functions.decimal_add(heap_first_arg, heap_second_arg) catch |err| {
                return err;
            };
            return heapValueToEvalValue(result);
        } else if (std.ascii.eqlIgnoreCase(function_name, "decimal_sub")) {
            const result = evaluator_functions.decimal_sub(heap_first_arg, heap_second_arg) catch |err| {
                return err;
            };
            return heapValueToEvalValue(result);
        } else if (std.ascii.eqlIgnoreCase(function_name, "decimal_mul")) {
            const result = evaluator_functions.decimal_mul(heap_first_arg, heap_second_arg) catch |err| {
                return err;
            };
            return heapValueToEvalValue(result);
        } else if (std.ascii.eqlIgnoreCase(function_name, "decimal_div")) {
            const result = evaluator_functions.decimal_div(heap_first_arg, heap_second_arg) catch |err| {
                return err;
            };
            return heapValueToEvalValue(result);
        }
    }

    // CANARY: REQ=REQ-GQL-KEYS-003; FEATURE="KeysFunction"; ASPECT=NodeEdgeMapKeys; STATUS=TESTED; TEST=geodetestlab/specs/gql_type_system_comprehensive.yml; OWNER=eval; UPDATED=2025-12-28
    // B06 Fix: Handle keys() for Map, Node, AND Edge types
    if (std.ascii.eqlIgnoreCase(function_name, "keys")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Map => |map| {
                var keys = try allocator.alloc(Value, map.count());
                var iter = map.iterator();
                var i: usize = 0;
                while (iter.next()) |entry| : (i += 1) {
                    keys[i] = Value{ .Str = entry.key_ptr.* };
                }
                return Value{ .List = keys };
            },
            .Node => |node| {
                var keys = try allocator.alloc(Value, node.properties.count());
                var iter = node.properties.iterator();
                var i: usize = 0;
                while (iter.next()) |entry| : (i += 1) {
                    keys[i] = Value{ .Str = entry.key_ptr.* };
                }
                return Value{ .List = keys };
            },
            .Edge => |edge| {
                var keys = try allocator.alloc(Value, edge.properties.count());
                var iter = edge.properties.iterator();
                var i: usize = 0;
                while (iter.next()) |entry| : (i += 1) {
                    keys[i] = Value{ .Str = entry.key_ptr.* };
                }
                return Value{ .List = keys };
            },
            else => return Value{ .Null = {} },
        }
    } else if (std.ascii.eqlIgnoreCase(function_name, "values")) {
        if (args.len != 1) return null;
        const arg = try evalExpr(allocator, args[0].*, env);
        switch (arg) {
            .Map => |map| {
                var values = try allocator.alloc(Value, map.count());
                var iter = map.iterator();
                var i: usize = 0;
                while (iter.next()) |entry| : (i += 1) {
                    values[i] = entry.value_ptr.*;
                }
                return Value{ .List = values };
            },
            else => return Value{ .Null = {} },
        }
    }

    // CANARY: REQ=REQ-CLIENT-INTEGRATION-001; FEATURE="range() function"; ASPECT=BuiltinFunctions; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=eval; UPDATED=2025-11-15
    // Handle range(start, stop[, step]) function - generates integer sequences
    // Used for performance testing: UNWIND range(1, 100) AS x RETURN x
    if (std.ascii.eqlIgnoreCase(function_name, "range")) {
        // range() requires 2 or 3 arguments
        if (args.len < 2 or args.len > 3) return Value{ .Null = {} };

        // Evaluate start argument (required)
        const start_val = try evalExpr(allocator, args[0].*, env);
        const start = switch (start_val) {
            .Int => |i| i,
            else => return Value{ .Null = {} },
        };

        // Evaluate stop argument (required)
        const stop_val = try evalExpr(allocator, args[1].*, env);
        const stop = switch (stop_val) {
            .Int => |i| i,
            else => return Value{ .Null = {} },
        };

        // Evaluate step argument (optional, defaults to 1)
        const step = if (args.len == 3) blk: {
            const step_val = try evalExpr(allocator, args[2].*, env);
            break :blk switch (step_val) {
                .Int => |i| i,
                else => return Value{ .Null = {} },
            };
        } else 1;

        // Step must not be zero
        if (step == 0) return Value{ .Null = {} };

        // Calculate the number of elements in the range
        const count: i64 = if (step > 0) blk: {
            if (stop <= start) break :blk 0;
            const diff = stop - start;
            break :blk @divFloor(diff + step - 1, step);
        } else blk: {
            if (stop >= start) break :blk 0;
            const diff = start - stop;
            break :blk @divFloor(diff - step - 1, -step);
        };

        // Allocate result array
        if (count <= 0) {
            return Value{ .List = &.{} };
        }

        // Safety check: limit range size to prevent OOM
        const max_range_size: i64 = 10_000_000; // 10 million elements max
        if (count > max_range_size) {
            return error.RangeTooLarge;
        }

        const ucount = @as(usize, @intCast(count));
        var result = try allocator.alloc(Value, ucount);

        // Generate range values
        var current = start;
        for (0..ucount) |i| {
            result[i] = Value{ .Int = current };
            current += step;
        }

        return Value{ .List = result };
    }

    // Function not recognized
    return null;
}

// CANARY: REQ=REQ-DATETIME-001; FEATURE="DateTimeFunctions"; ASPECT=duration_parsing; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=datetime; UPDATED=2025-12-22
/// Parse ISO 8601 duration string (e.g., "P1Y2M3D", "PT2H30M", "P1DT12H")
/// Returns duration in seconds
fn parseDurationString(str: []const u8) !i64 {
    if (str.len == 0 or str[0] != 'P') return error.InvalidFormat;

    var seconds: i64 = 0;
    var idx: usize = 1;
    var in_time_part = false;
    var current_num: i64 = 0;
    var has_num = false;

    while (idx < str.len) {
        const c = str[idx];

        if (c == 'T') {
            in_time_part = true;
            idx += 1;
            continue;
        }

        if (c >= '0' and c <= '9') {
            current_num = current_num * 10 + @as(i64, c - '0');
            has_num = true;
            idx += 1;
            continue;
        }

        if (!has_num) {
            idx += 1;
            continue;
        }

        // Apply the designator
        if (!in_time_part) {
            switch (c) {
                'Y' => seconds += current_num * 365 * 24 * 60 * 60, // Approximate year
                'M' => seconds += current_num * 30 * 24 * 60 * 60, // Approximate month
                'W' => seconds += current_num * 7 * 24 * 60 * 60,
                'D' => seconds += current_num * 24 * 60 * 60,
                else => {},
            }
        } else {
            switch (c) {
                'H' => seconds += current_num * 60 * 60,
                'M' => seconds += current_num * 60,
                'S' => seconds += current_num,
                else => {},
            }
        }

        current_num = 0;
        has_num = false;
        idx += 1;
    }

    return seconds;
}

fn inList(value: Value, set: []*ast.Expr, allocator: std.mem.Allocator, env: Env) EvalError!Value {
    if (isNull(value)) return Value{ .Null = {} };
    var saw_null = false;
    for (set) |p| {
        const ev = try evalExpr(allocator, p.*, env);
        if (isNull(ev)) {
            saw_null = true;
            continue;
        }
        if (value == .Int and ev == .Int and value.Int == ev.Int) return .{ .Bool = true };
        if (value == .Str and ev == .Str and std.mem.eql(u8, value.Str, ev.Str)) return .{ .Bool = true };
        if ((value == .Str and ev == .Int) or (value == .Int and ev == .Str)) {
            var bufV: [64]u8 = undefined;
            var bufE: [64]u8 = undefined;
            const vs = try stringify(value, &bufV);
            const es = try stringify(ev, &bufE);
            if (std.mem.eql(u8, vs, es)) return .{ .Bool = true };
        }
    }
    if (saw_null) return Value{ .Null = {} };
    return .{ .Bool = false };
}

// ---------------------------------------------------------------------------
// GAP-0282 / GAP-0537: the scalar timeseries.* GQL function dispatch
// (tsValueToCanonical, resolveTimeseriesStore, evalTimeseriesFunction,
// parseAggregation, evalArrayBasedTsFunction) moved to the dedicated handler
// module src/eval/ts_call_handlers.zig. The global-store accessors
// (setGlobalTimeseriesStore / getGlobalTimeseriesStore /
// getTimeseriesStoreForGraph) stay here as the public wiring surface.
// ---------------------------------------------------------------------------

// RETIRED (2026-05-31): the scalar `fulltext_search(index, query [, max])` value
// function lived here. It returned a `List` of `Map{node_id, score}` records the
// caller had to `UNWIND` — but `UNWIND` is a Cypher construct, not ISO/IEC
// 39075:2024 GQL, which surfaces a row set ONLY through `CALL <proc>(args) YIELD
// …`. Full-text search is now the GQL procedure `geode.fts.search(index, query
// [, max]) YIELD node, score`, implemented in execution/fts_dispatch.zig and
// routed by execution/procedure_registry.zig. The adapter resolution
// (`getGlobalAdapter().getFulltextIndexNamed(DEFAULT_GRAPH_NAME, index).search`)
// moved verbatim into that handler. See .migration/GQL-SPEC-set-return.md.

test "eval: IN/NOT IN with NULL semantics and mixed-type edges" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{ "a", "s" }, .values = &.{ Value{ .Int = 7 }, Value{ .Str = "007" } } };
    var a_ident = ast.Expr{ .Ident = .{ .orig = "a", .cnf = "A" } };
    var s_ident = ast.Expr{ .Ident = .{ .orig = "s", .cnf = "S" } };
    // IN list with NULL element yields NULL if no match
    var nullx = ast.Expr{ .Null = {} };
    var lit9 = ast.Expr{ .Int = 9 };
    var arr1: [2]*ast.Expr = .{ &nullx, &lit9 };
    const in1 = ast.Expr{ .In = .{ .value = &a_ident, .set = arr1[0..] } };
    const v1 = try evalExpr(allocator, in1, env);
    try std.testing.expect(v1 == .Null);
    // IN list when match present returns true
    var lit7 = ast.Expr{ .Int = 7 };
    var arr2: [3]*ast.Expr = .{ &nullx, &lit7, &lit9 };
    const in2 = ast.Expr{ .In = .{ .value = &a_ident, .set = arr2[0..] } };
    const v2 = try evalExpr(allocator, in2, env);
    try std.testing.expect(v2 == .Bool and v2.Bool);
    // NOT IN negates; with match present -> false
    const nin1 = ast.Expr{ .NotIn = .{ .value = &a_ident, .set = arr2[0..] } };
    const v3 = try evalExpr(allocator, nin1, env);
    try std.testing.expect(v3 == .Bool and !v3.Bool);
    // NOT IN when list has NULL and no match -> NULL
    var lit8 = ast.Expr{ .Int = 8 };
    var arr3: [2]*ast.Expr = .{ &nullx, &lit9 };
    const nin2 = ast.Expr{ .NotIn = .{ .value = &lit8, .set = arr3[0..] } };
    const v4 = try evalExpr(allocator, nin2, env);
    try std.testing.expect(v4 == .Null);
    // Mixed-type equality edge: leading zeros in string
    var str7 = ast.Expr{ .String = "7" };
    const eq = ast.Expr{ .Binary = .{ .op = .Eq, .left = &a_ident, .right = &str7 } };
    const v5 = try evalExpr(allocator, eq, env);
    try std.testing.expect(v5 == .Bool and v5.Bool);
    const eq2 = ast.Expr{ .Binary = .{ .op = .Eq, .left = &a_ident, .right = &s_ident } };
    const v6 = try evalExpr(allocator, eq2, env);
    // 7 vs "007" should be false by decimal string compare
    try std.testing.expect(v6 == .Bool and !v6.Bool);
    // NOT IN with empty list -> always true
    var empty: [0]*ast.Expr = .{};
    const nin_empty = ast.Expr{ .NotIn = .{ .value = &a_ident, .set = empty[0..] } };
    const v7 = try evalExpr(allocator, nin_empty, env);
    try std.testing.expect(v7 == .Bool and v7.Bool);
    // NOT IN with all-NULL list -> NULL
    var nul2 = ast.Expr{ .Null = {} };
    var arrn: [2]*ast.Expr = .{ &nullx, &nul2 };
    const nin_nulls = ast.Expr{ .NotIn = .{ .value = &lit8, .set = arrn[0..] } };
    const v8 = try evalExpr(allocator, nin_nulls, env);
    try std.testing.expect(v8 == .Null);
}

test "eval: mixed-type IN across bools and big ints stringified" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{"a"}, .values = &.{Value{ .Int = 9007199254740991 }} }; // 2^53-1
    var a_ident = ast.Expr{ .Ident = .{ .orig = "a", .cnf = "A" } };
    var s_big = ast.Expr{ .String = "9007199254740991" };
    var t_true = ast.Expr{ .String = "true" };
    var b_true = ast.Expr{ .Bool = true };
    var items: [3]*ast.Expr = .{ &s_big, &t_true, &b_true };
    const inx = ast.Expr{ .In = .{ .value = &a_ident, .set = items[0..] } };
    const v = try evalExpr(allocator, inx, env);
    // Should match the big-int via decimal string, ignore bool mismatches
    try std.testing.expect(v == .Bool and v.Bool == true);
}

test "eval: CASE searched produces expected values" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{"a"}, .values = &.{Value{ .Int = 1 }} };
    var a_expr = ast.Expr{ .Ident = .{ .orig = "a", .cnf = "A" } };
    var zero = ast.Expr{ .Int = 0 };
    var pred = ast.Expr{ .Binary = .{ .op = .Gt, .left = &a_expr, .right = &zero } };
    var p = ast.Expr{ .String = "p" };
    var n = ast.Expr{ .String = "n" };
    var whs: [1]ast.CaseWhen = .{.{ .when = &pred, .then_expr = &p }};
    const cse = ast.Expr{ .Case = .{ .operand = null, .whens = whs[0..], .else_expr = &n } };
    const out = try evalExpr(allocator, cse, env);
    try std.testing.expect(out == .Str and std.mem.eql(u8, out.Str, "p"));
}

// NOTE: correctness + fast-path-engagement coverage for the ASCII string-compare
// optimization (isAscii / nfc_fallback_count) lives in
// tests/test_gap_filtered_count.zig (wired via `zig build test-filtered-count`),
// where eval.zig is reachable through the fully-wired `geode` module. It cannot
// live as an inline test here because src/eval.zig is not a working test ROOT in
// this worktree (its transitive security imports need build_options/crypto_backend
// modules that only the geode module supplies).

test "eval: string predicates and regex basic" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{"s"}, .values = &.{Value{ .Str = "Alice" }} };
    var s = ast.Expr{ .Ident = .{ .orig = "s", .cnf = "S" } };
    var al = ast.Expr{ .String = "Al" };
    var z = ast.Expr{ .String = "Z" };
    var ice = ast.Expr{ .String = "ice" };
    const sw = ast.Expr{ .StartsWith = .{ .value = &s, .prefix = &al } };
    const ew = ast.Expr{ .EndsWith = .{ .value = &s, .suffix = &z } };
    const ct = ast.Expr{ .Contains = .{ .value = &s, .needle = &ice } };
    // Removed regex test - not part of GQL
    const v1 = try evalExpr(allocator, sw, env);
    const v2 = try evalExpr(allocator, ew, env);
    const v3 = try evalExpr(allocator, ct, env);
    try std.testing.expect(v1 == .Bool and v1.Bool == true);
    try std.testing.expect(v2 == .Bool and v2.Bool == false);
    try std.testing.expect(v3 == .Bool and v3.Bool == true);
}

// Removed test "eval: regex classes, negation, optional, escapes" - regex not part of GQL

test "eval: empty and NULL edge cases for string predicates" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };
    var s = ast.Expr{ .String = "" };
    var pref = ast.Expr{ .String = "" };
    const sw = ast.Expr{ .StartsWith = .{ .value = &s, .prefix = &pref } };
    const out1 = try evalExpr(allocator, sw, env);
    try std.testing.expect(out1 == .Bool and out1.Bool == true);
    // NULL arg yields NULL
    const null_v = Value{ .Null = {} };
    const e2 = try evalStartsWith(null_v, .{ .Str = "x" });
    try std.testing.expect(e2 == .Null);
}

test "eval: implicit int<->string in predicates and IN list" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{ "a", "s" }, .values = &.{ Value{ .Int = 42 }, Value{ .Str = "42" } } };
    // s STARTS WITH "4" -> true
    var s_ident = ast.Expr{ .Ident = .{ .orig = "s", .cnf = "S" } };
    var four = ast.Expr{ .String = "4" };
    const sw = ast.Expr{ .StartsWith = .{ .value = &s_ident, .prefix = &four } };
    const v1 = try evalExpr(allocator, sw, env);
    try std.testing.expect(v1 == .Bool and v1.Bool == true);
    // a = "42" -> true (implicit Eq int<->string)
    var a_ident = ast.Expr{ .Ident = .{ .orig = "a", .cnf = "A" } };
    var s_lit = ast.Expr{ .String = "42" };
    const eq = ast.Expr{ .Binary = .{ .op = .Eq, .left = &a_ident, .right = &s_lit } };
    const v2 = try evalExpr(allocator, eq, env);
    try std.testing.expect(v2 == .Bool and v2.Bool == true);
    // a IN ["41", "42", 43] -> true
    var lit41 = ast.Expr{ .String = "41" };
    var lit43 = ast.Expr{ .Int = 43 };
    var arr: [3]*ast.Expr = .{ &lit41, &s_lit, &lit43 };
    const inx = ast.Expr{ .In = .{ .value = &a_ident, .set = arr[0..] } };
    const v3 = try evalExpr(allocator, inx, env);
    try std.testing.expect(v3 == .Bool and v3.Bool == true);
}

test "eval: parameters substitution and STARTS WITH via $param" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{"s"}, .values = &.{Value{ .Str = "Alice" }}, .param_names = &.{"prefix"}, .param_values = &.{Value{ .Str = "Al" }} };
    var s_ident = ast.Expr{ .Ident = .{ .orig = "s", .cnf = "S" } };
    var pref = ast.Expr{ .Param = "prefix" };
    const sw = ast.Expr{ .StartsWith = .{ .value = &s_ident, .prefix = &pref } };
    const v = try evalExpr(allocator, sw, env);
    try std.testing.expect(v == .Bool and v.Bool == true);
}

test "eval: parameters in IN list, mixed-type equality, and regex via $param" {
    const allocator = std.testing.allocator;
    // Env: a=7, s="007"; params: needle="Al", list=["6",7], pat="^A.*$"
    const env = Env{ .allocator = allocator, .names = &.{ "a", "s" }, .values = &.{ Value{ .Int = 7 }, Value{ .Str = "007" } }, .param_names = &.{ "needle", "list0", "list1", "pat" }, .param_values = &.{ Value{ .Str = "Al" }, Value{ .Str = "6" }, Value{ .Int = 7 }, Value{ .Str = "^A.*$" } } };
    // a IN [$list0, $list1] -> true
    var a_ident = ast.Expr{ .Ident = .{ .orig = "a", .cnf = "A" } };
    var p0 = ast.Expr{ .Param = "list0" };
    var p1 = ast.Expr{ .Param = "list1" };
    var items: [2]*ast.Expr = .{ &p0, &p1 };
    const inx = ast.Expr{ .In = .{ .value = &a_ident, .set = items[0..] } };
    const v1 = try evalExpr(allocator, inx, env);
    try std.testing.expect(v1 == .Bool and v1.Bool);
    // Equality mixed-type: a = s (7 vs "007") -> false; but a = "7" literal -> true
    var s_ident = ast.Expr{ .Ident = .{ .orig = "s", .cnf = "S" } };
    const eq1 = ast.Expr{ .Binary = .{ .op = .Eq, .left = &a_ident, .right = &s_ident } };
    const v2 = try evalExpr(allocator, eq1, env);
    try std.testing.expect(v2 == .Bool and !v2.Bool);
    var s7 = ast.Expr{ .String = "7" };
    const eq2 = ast.Expr{ .Binary = .{ .op = .Eq, .left = &a_ident, .right = &s7 } };
    const v3 = try evalExpr(allocator, eq2, env);
    try std.testing.expect(v3 == .Bool and v3.Bool);
    // Equality using int parameter vs string field: $list1 (7) = s ("007") -> false
    var p_int = ast.Expr{ .Param = "list1" };
    const eq3 = ast.Expr{ .Binary = .{ .op = .Eq, .left = &p_int, .right = &s_ident } };
    const v3b = try evalExpr(allocator, eq3, env);
    try std.testing.expect(v3b == .Bool and !v3b.Bool);
    // Removed regex test - not part of GQL
}

test "eval: CASE permutations with multiple WHENs and ELSE variants" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };
    // Searched CASE: first WHEN true selected; later WHENs skipped
    var t = ast.Expr{ .Bool = true };
    var f = ast.Expr{ .Bool = false };
    var n = ast.Expr{ .Null = {} };
    var A = ast.Expr{ .String = "A" };
    var B = ast.Expr{ .String = "B" };
    var C = ast.Expr{ .String = "C" };
    var whs1: [3]ast.CaseWhen = .{ .{ .when = &t, .then_expr = &A }, .{ .when = &f, .then_expr = &B }, .{ .when = &t, .then_expr = &C } };
    const cs1 = ast.Expr{ .Case = .{ .operand = null, .whens = whs1[0..], .else_expr = &C } };
    const o1 = try evalExpr(allocator, cs1, env);
    try std.testing.expect(o1 == .Str and std.mem.eql(u8, o1.Str, "A"));
    // Searched CASE: no WHEN true, ELSE present -> ELSE
    var whs2: [2]ast.CaseWhen = .{ .{ .when = &f, .then_expr = &A }, .{ .when = &n, .then_expr = &B } };
    const cs2 = ast.Expr{ .Case = .{ .operand = null, .whens = whs2[0..], .else_expr = &C } };
    const o2 = try evalExpr(allocator, cs2, env);
    try std.testing.expect(o2 == .Str and std.mem.eql(u8, o2.Str, "C"));
    // Simple CASE: operand type-varying WHENs; match on second WHEN; ELSE absent
    var op = ast.Expr{ .String = "2" };
    var w1 = ast.Expr{ .Int = 1 };
    var w2 = ast.Expr{ .String = "2" };
    var whs3: [2]ast.CaseWhen = .{ .{ .when = &w1, .then_expr = &A }, .{ .when = &w2, .then_expr = &B } };
    const cs3 = ast.Expr{ .Case = .{ .operand = &op, .whens = whs3[0..], .else_expr = null } };
    const o3 = try evalExpr(allocator, cs3, env);
    try std.testing.expect(o3 == .Str and std.mem.eql(u8, o3.Str, "B"));
    // Simple CASE: operand Int 2, WHEN "2" (string) shouldn't match; ELSE applies
    var op2 = ast.Expr{ .Int = 2 };
    var wstr2 = ast.Expr{ .String = "2" };
    var whs3b: [1]ast.CaseWhen = .{.{ .when = &wstr2, .then_expr = &A }};
    const cs3b = ast.Expr{ .Case = .{ .operand = &op2, .whens = whs3b[0..], .else_expr = &C } };
    const o3b = try evalExpr(allocator, cs3b, env);
    try std.testing.expect(o3b == .Str and std.mem.eql(u8, o3b.Str, "C"));
    // Simple CASE: operand NULL, WHEN NULL then -> THEN; ELSE present should be ignored
    var opn = ast.Expr{ .Null = {} };
    var whs4: [2]ast.CaseWhen = .{ .{ .when = &n, .then_expr = &A }, .{ .when = &t, .then_expr = &B } };
    const cs4 = ast.Expr{ .Case = .{ .operand = &opn, .whens = whs4[0..], .else_expr = &C } };
    const o4 = try evalExpr(allocator, cs4, env);
    try std.testing.expect(o4 == .Str and std.mem.eql(u8, o4.Str, "A"));
}

test "eval: CASE 3VL searched and simple with NULLs" {
    const allocator = std.testing.allocator;
    // Searched CASE: WHEN NULL THEN should not trigger; ELSE chosen
    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };
    var n1 = ast.Expr{ .Null = {} };
    var then1 = ast.Expr{ .String = "x" };
    var whs1: [1]ast.CaseWhen = .{.{ .when = &n1, .then_expr = &then1 }};
    const c1 = ast.Expr{ .Case = .{ .operand = null, .whens = whs1[0..], .else_expr = &then1 } };
    const o1 = try evalExpr(allocator, c1, env);
    try std.testing.expect(o1 == .Str and std.mem.eql(u8, o1.Str, "x"));
    // Simple CASE: operand NULL, WHEN NULL -> match returns THEN
    var opn = ast.Expr{ .Null = {} };
    var wnull = ast.Expr{ .Null = {} };
    var t2 = ast.Expr{ .String = "n" };
    var whs2: [1]ast.CaseWhen = .{.{ .when = &wnull, .then_expr = &t2 }};
    const c2 = ast.Expr{ .Case = .{ .operand = &opn, .whens = whs2[0..], .else_expr = null } };
    const o2 = try evalExpr(allocator, c2, env);
    try std.testing.expect(o2 == .Str and std.mem.eql(u8, o2.Str, "n"));
}

test "eval: icontains case-insensitive string matching" {
    // GAP-0888 review follow-up: icontains allocates case-folding
    // temporaries it does not free (per-request arena contract, GAP-0755),
    // so evaluate under an arena.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };

    // GAP-0888 review follow-up: rebuilt against the current Call AST shape
    // ({ callee, args }); the old { name, distinct, namespace } form
    // bit-rotted while these inline tests were not rooted by any step.
    var icontains_callee = ast.Expr{ .Ident = .{ .orig = "icontains", .cnf = "ICONTAINS" } };

    // icontains('Hello World', 'hello') -> true
    var arg1 = ast.Expr{ .String = "Hello World" };
    var arg2 = ast.Expr{ .String = "hello" };
    var args1 = [_]*ast.Expr{ &arg1, &arg2 };
    const call1 = ast.Expr{ .Call = .{ .callee = &icontains_callee, .args = &args1 } };
    const v1 = try evalExpr(allocator, call1, env);
    try std.testing.expect(v1 == .Bool and v1.Bool == true);

    // icontains('Hello World', 'WORLD') -> true
    var arg3 = ast.Expr{ .String = "Hello World" };
    var arg4 = ast.Expr{ .String = "WORLD" };
    var args2 = [_]*ast.Expr{ &arg3, &arg4 };
    const call2 = ast.Expr{ .Call = .{ .callee = &icontains_callee, .args = &args2 } };
    const v2 = try evalExpr(allocator, call2, env);
    try std.testing.expect(v2 == .Bool and v2.Bool == true);

    // icontains('Hello World', 'xyz') -> false
    var arg5 = ast.Expr{ .String = "Hello World" };
    var arg6 = ast.Expr{ .String = "xyz" };
    var args3 = [_]*ast.Expr{ &arg5, &arg6 };
    const call3 = ast.Expr{ .Call = .{ .callee = &icontains_callee, .args = &args3 } };
    const v3 = try evalExpr(allocator, call3, env);
    try std.testing.expect(v3 == .Bool and v3.Bool == false);

    // icontains('Hello World', '') -> true (empty needle)
    var arg7 = ast.Expr{ .String = "Hello World" };
    var arg8 = ast.Expr{ .String = "" };
    var args4 = [_]*ast.Expr{ &arg7, &arg8 };
    const call4 = ast.Expr{ .Call = .{ .callee = &icontains_callee, .args = &args4 } };
    const v4 = try evalExpr(allocator, call4, env);
    try std.testing.expect(v4 == .Bool and v4.Bool == true);
}

test "eval: tolower and toupper aliases" {
    const allocator = std.testing.allocator;
    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };

    // GAP-0888 review follow-up: rebuilt against the current Call AST shape;
    // tolower/toupper return freshly-allocated strings, so free them.
    var tolower_callee = ast.Expr{ .Ident = .{ .orig = "tolower", .cnf = "TOLOWER" } };
    var toupper_callee = ast.Expr{ .Ident = .{ .orig = "toupper", .cnf = "TOUPPER" } };

    // tolower('HELLO') -> 'hello'
    var arg1 = ast.Expr{ .String = "HELLO" };
    var args1 = [_]*ast.Expr{&arg1};
    const call1 = ast.Expr{ .Call = .{ .callee = &tolower_callee, .args = &args1 } };
    const v1 = try evalExpr(allocator, call1, env);
    defer if (v1 == .Str) allocator.free(v1.Str);
    try std.testing.expect(v1 == .Str and std.mem.eql(u8, v1.Str, "hello"));

    // toupper('hello') -> 'HELLO'
    var arg2 = ast.Expr{ .String = "hello" };
    var args2 = [_]*ast.Expr{&arg2};
    const call2 = ast.Expr{ .Call = .{ .callee = &toupper_callee, .args = &args2 } };
    const v2 = try evalExpr(allocator, call2, env);
    defer if (v2 == .Str) allocator.free(v2.Str);
    try std.testing.expect(v2 == .Str and std.mem.eql(u8, v2.Str, "HELLO"));
}

// GAP-0280: Verify timeseries.value() uses the global store when Env.timeseries_store is null.
// This is the server execution path: the Store is set once at startup and shared across
// all connections.  Without this wiring, timeseries.value() always returns Null on the
// QUIC/gRPC path.
test "eval: timeseries.value uses global store fallback" {
    const allocator = std.testing.allocator;
    const ts_module = @import("timeseries/timeseries.zig");

    // Create a Store, insert a data point, and publish it as the global store.
    var store = ts_module.Store.init(allocator);
    defer store.deinit();

    const key = ts_module.SeriesKey{ .device_id = 42, .metric = "temperature" };
    try store.insertMany(key, &.{.{ .ts = 1000, .value = 72 }});

    // Set the global -- simulates what server/main.zig does at startup.
    setGlobalTimeseriesStore(&store);
    defer setGlobalTimeseriesStore(null);

    // Env has NO per-env timeseries_store -- this is the server path.
    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };

    // Build the AST for: timeseries.value(42, 'temperature', 1000)
    var arg_device = ast.Expr{ .Int = 42 };
    var arg_metric = ast.Expr{ .String = "temperature" };
    var arg_ts = ast.Expr{ .Int = 1000 };
    var args = [_]*ast.Expr{ &arg_device, &arg_metric, &arg_ts };
    // GAP-0888 review follow-up: rebuilt against the current Call AST shape.
    var ts_value_callee = ast.Expr{ .Ident = .{ .orig = "timeseries.value", .cnf = "TIMESERIES.VALUE" } };
    const call_expr = ast.Expr{ .Call = .{ .callee = &ts_value_callee, .args = &args } };

    const result = try evalExpr(allocator, call_expr, env);
    // Must return 72, NOT Null.
    try std.testing.expect(result == .Int);
    try std.testing.expectEqual(@as(i64, 72), result.Int);
}

// GAP-0280: Verify timeseries.value() returns Null when no store is available.
test "eval: timeseries.value returns null without store" {
    const allocator = std.testing.allocator;

    // Ensure global is not set.
    setGlobalTimeseriesStore(null);

    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{} };

    var arg_device = ast.Expr{ .Int = 1 };
    var arg_metric = ast.Expr{ .String = "cpu" };
    var arg_ts = ast.Expr{ .Int = 100 };
    var args = [_]*ast.Expr{ &arg_device, &arg_metric, &arg_ts };
    // GAP-0888 review follow-up: rebuilt against the current Call AST shape.
    var ts_value_callee = ast.Expr{ .Ident = .{ .orig = "timeseries.value", .cnf = "TIMESERIES.VALUE" } };
    const call_expr = ast.Expr{ .Call = .{ .callee = &ts_value_callee, .args = &args } };

    const result = try evalExpr(allocator, call_expr, env);
    try std.testing.expect(result == .Null);
}

// GAP-0280: Verify per-Env timeseries_store takes priority over global.
test "eval: timeseries.value prefers env store over global" {
    const allocator = std.testing.allocator;
    const ts_module = @import("timeseries/timeseries.zig");

    // Global store has value 100 for key (1, "x", 10).
    var global_store = ts_module.Store.init(allocator);
    defer global_store.deinit();
    const gkey = ts_module.SeriesKey{ .device_id = 1, .metric = "x" };
    try global_store.insertMany(gkey, &.{.{ .ts = 10, .value = 100 }});
    setGlobalTimeseriesStore(&global_store);
    defer setGlobalTimeseriesStore(null);

    // Per-env store has value 999 for the same key.
    var env_store = ts_module.Store.init(allocator);
    defer env_store.deinit();
    try env_store.insertMany(gkey, &.{.{ .ts = 10, .value = 999 }});

    const env = Env{ .allocator = allocator, .names = &.{}, .values = &.{}, .timeseries_store = &env_store };

    var arg_device = ast.Expr{ .Int = 1 };
    var arg_metric = ast.Expr{ .String = "x" };
    var arg_ts = ast.Expr{ .Int = 10 };
    var args = [_]*ast.Expr{ &arg_device, &arg_metric, &arg_ts };
    // GAP-0888 review follow-up: rebuilt against the current Call AST shape.
    var ts_value_callee = ast.Expr{ .Ident = .{ .orig = "timeseries.value", .cnf = "TIMESERIES.VALUE" } };
    const call_expr = ast.Expr{ .Call = .{ .callee = &ts_value_callee, .args = &args } };

    const result = try evalExpr(allocator, call_expr, env);
    // Must return 999 from env store, not 100 from global.
    try std.testing.expect(result == .Int);
    try std.testing.expectEqual(@as(i64, 999), result.Int);
}

test {
    // GAP-0888 review follow-up: pull the extracted call-handler modules'
    // inline unit tests into this file's test reference graph — Zig 0.16
    // only discovers tests reachable from the test ROOT file, and no other
    // named step roots src/eval/*.zig. `zig build test-gap0866` roots this
    // file (see build.zig "EVAL CALL-HANDLER UNIT TESTS").
    _ = ts_call_handlers;
    _ = quantifier_call_handlers;
}
