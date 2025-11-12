const std = @import("std");
const impl_flagger = @import("flagger_impl_defined.zig");

// CANARY: REQ=REQ-SERVER-REFACTOR-004; FEATURE="ServerRefactoring"; ASPECT=FLAG_UTILITIES; STATUS=IMPL; OWNER=refactor; UPDATED=2025-11-12
// Phase 3 M3.1 - Server Flags Module (Incremental Extraction)
// Extracted flag computation and management utilities from server/main.zig

/// Flag constant definitions for query execution metadata
pub const F_ILLEGAL = "I:IllegalOrderKeyPolicy=ident-only";
pub const F_PROPERTY_ORDER = "I:PropertyOrderingEnabled";
pub const F_NULLS_FIRST = "U:NullsFirstPolicy";
pub const F_NULLS_LAST = "U:NullsLastPolicy";
pub const F_TIEBREAK = "U:OrderTiebreak=LexJSON";
pub const F_DISTINCT_UNORDERED = "U:DistinctOutputUnordered";
pub const F_UNION_PHASES = "U:UnionPhaseTimings";
pub const F_ADAPT_EST = "U:AdaptiveEstimatesPlanned"; // groundwork flag (no behavior change yet)
pub const F_HEUR_INDEX = "U:HeuristicIndexSelection"; // emitted when NodeIndexScan chosen via heuristic

/// Flag buffer storage for dynamic flag construction
/// Expanded base buffer to accommodate impl-defined findings (e.g., ZeroLengthPathExcluded)
var flags_buf_base: [12][]const u8 = undefined; // room for adaptive + impl-defined additions
var flags_buf_ext: [7][]const u8 = undefined; // room for adaptive + union phases + deprecation

/// Global flag state variables
var g_nulls_last: bool = false; // default NullsFirstPolicy unless overridden by env
var g_order_keys_expr: bool = true; // enable property-based ordering by default
var g_adapt_estimates: bool = false; // env or future CLI toggled
var g_estimate_adjust_factor: f64 = 1.0; // groundwork; stays 1.0 until adaptive algorithm enabled

/// Implementation-defined flag cache (codes only). Allocated once on first use.
var g_impl_defined_codes: [][]const u8 = &.{};
var g_impl_defined_inited: bool = false;

/// Helper returns correct null policy flag pointer
pub inline fn nullsFlag() []const u8 {
    return if (g_nulls_last) F_NULLS_LAST else F_NULLS_FIRST;
}

/// Pagination streaming scaffold (S-018): introduce a stub to emit incremental pages in future slices.
/// Current implementation writes full result; this stub records an intent and adds CANARY evidence.
/// CANARY: REQ=REQ-GQL-004; FEATURE="PaginationExecutionStreaming"; ASPECT=Scaffold; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_004_PaginationStreamingScaffold; OWNER=planner; UPDATED=2025-09-23
pub fn paginationStreamScaffold(total_rows: usize, page_size: usize) bool {
    // Return true if streaming would produce multiple pages (future: drive incremental emission loop)
    if (page_size == 0) return false;
    return total_rows > page_size;
}

/// Initialize implementation-defined flags from the flagger module
pub fn initImplDefinedFlags(allocator: std.mem.Allocator) void {
    if (g_impl_defined_inited) return;
    if (impl_flagger.collect(allocator, .{ .zero_length_paths_excluded = true, .collation_binary_default = true, .null_order_policy_default = true })) |findings| {
        // Extract codes slice
        const codes = allocator.alloc([]const u8, findings.len) catch return;
        var i: usize = 0;
        while (i < findings.len) : (i += 1) codes[i] = findings[i].code;
        g_impl_defined_codes = codes;
        g_impl_defined_inited = true;
    } else |_| {
        return; // leave empty on failure
    }
}

/// Compute base flags for query execution
/// Returns appropriate ordering and property flags based on query characteristics
pub fn computeBaseFlags(ordered: bool, distinct: bool) []const []const u8 {
    _ = ordered;
    _ = distinct;
    // Use appropriate flag based on property ordering setting
    flags_buf_base[0] = if (g_order_keys_expr) F_PROPERTY_ORDER else F_ILLEGAL;
    return flags_buf_base[0..1];
}

/// Compute extended flags including union phases and deprecation warnings
/// Builds on base flags with additional metadata flags
pub fn computeFlagsExtended(ordered: bool, distinct: bool, union_phases: bool) []const []const u8 {
    const base = computeBaseFlags(ordered, distinct);
    var i: usize = 0;
    while (i < base.len) : (i += 1) flags_buf_ext[i] = base[i];
    var end: usize = base.len;
    if (union_phases) {
        flags_buf_ext[end] = F_UNION_PHASES;
        end += 1;
    }
    // Deprecation flag for wal_skip_ratio legacy key always appended (profile context check later could refine)
    flags_buf_ext[end] = "U:WalSkipRatioDeprecated";
    end += 1;
    return flags_buf_ext[0..end];
}

/// Get implementation-defined flag codes
pub fn getImplDefinedCodes() []const []const u8 {
    return g_impl_defined_codes;
}

/// Check if implementation-defined flags are initialized
pub fn isImplDefinedInited() bool {
    return g_impl_defined_inited;
}

/// Set nulls last policy (for testing/configuration)
pub fn setNullsLast(value: bool) void {
    g_nulls_last = value;
}

/// Get nulls last policy
pub fn getNullsLast() bool {
    return g_nulls_last;
}

/// Set order keys expression policy
pub fn setOrderKeysExpr(value: bool) void {
    g_order_keys_expr = value;
}

/// Get order keys expression policy
pub fn getOrderKeysExpr() bool {
    return g_order_keys_expr;
}

/// Set adaptive estimates enabled
pub fn setAdaptEstimates(value: bool) void {
    g_adapt_estimates = value;
}

/// Get adaptive estimates enabled
pub fn getAdaptEstimates() bool {
    return g_adapt_estimates;
}

/// Set estimate adjust factor
pub fn setEstimateAdjustFactor(value: f64) void {
    g_estimate_adjust_factor = value;
}

/// Get estimate adjust factor
pub fn getEstimateAdjustFactor() f64 {
    return g_estimate_adjust_factor;
}
