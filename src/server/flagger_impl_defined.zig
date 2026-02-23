const std = @import("std");

// CANARY: REQ=REQ-GQL-024; FEATURE="Conformance Flagger"; ASPECT=ImplDefinedZeroLengthPathPolicy; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_ImplDefinedZeroLengthPathPolicy; OWNER=engine; UPDATED=2025-09-21
// CANARY: REQ=GQL-39075-RQ-0003; FEATURE="GQL Flagger/ImplDefined"; ASPECT=AnnexBCompleteness; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0003_AnnexBComplete; OWNER=conformance; UPDATED=2026-02-23

pub const ImplDefinedFinding = struct {
    code: []const u8,
    detail: []const u8,
};

// collect returns all implementation-defined findings for the Geode GQL engine.
//
// The 15 Annex B items from ISO/IEC 39075:2024 are always emitted (subject to
// their respective boolean opts).  An additional optional finding
// "ZeroLengthPathExcluded" is included when opts.zero_length_paths_excluded is
// true.
//
// The 15 conformance.zig Annex B items (codes match collectImplDefinedFlags):
//   CollationBinaryDefault, NullOrderPolicyDefault, UnorderedPaginationAllowed,
//   UA005PathTieBreak, UA006PathTieBreak, UnicodeVersion, StringMaxLength,
//   BytestringMaxLength, SecondsPrec, TemporalFormat, UtcSls, SessionParamPrefix,
//   ConfusableDetection, MinPropertyTypes, CharRepertoire
pub fn collect(
    allocator: std.mem.Allocator,
    opts: struct {
        zero_length_paths_excluded: bool,
        collation_binary_default: bool = true,
        null_order_policy_default: bool = true,
        unordered_pagination_allowed: bool = true,
        ua005_path_tie_break: bool = true,
        ua006_path_tie_break: bool = true,
        unicode_version: []const u8 = "15.1.0",
        string_max_length: u32 = 16383,
        bytestring_max_length: u32 = 65534,
        seconds_precision: u8 = 6,
        temporal_format: []const u8 = "ISO8601",
        utc_sls: bool = true,
        session_param_prefix: []const u8 = "_",
        confusable_detection: []const u8 = "TR39-skeleton",
        min_property_types: []const u8 = "STRING,BOOLEAN,SIGNEDINTEGER,FLOAT",
        char_repertoire: []const u8 = "Unicode",
    },
) ![]ImplDefinedFinding {
    var list = try std.ArrayList(ImplDefinedFinding).initCapacity(allocator, 16);
    errdefer list.deinit();

    // Optional: zero-length path exclusion policy
    if (opts.zero_length_paths_excluded) {
        try list.append(.{ .code = "ZeroLengthPathExcluded", .detail = "Zero-length paths excluded when min_hops=0 (impl-defined policy)" });
    }

    // Annex B items 1-5 (boolean-gated, default true)
    if (opts.collation_binary_default) {
        try list.append(.{ .code = "CollationBinaryDefault", .detail = "Binary collation default (Unicode collation optional feature not enabled)" });
    }
    if (opts.null_order_policy_default) {
        try list.append(.{ .code = "NullOrderPolicyDefault", .detail = "NULL ordering defaults to NULLS LAST unless ORDER BY specifies otherwise (impl-defined)" });
    }
    if (opts.unordered_pagination_allowed) {
        try list.append(.{ .code = "UnorderedPaginationAllowed", .detail = "OFFSET/LIMIT pagination permitted on unordered result sets (impl-defined)" });
    }
    if (opts.ua005_path_tie_break) {
        try list.append(.{ .code = "UA005PathTieBreak", .detail = "UA005: tie-breaking among equal-cost paths is implementation-defined" });
    }
    if (opts.ua006_path_tie_break) {
        try list.append(.{ .code = "UA006PathTieBreak", .detail = "UA006: tie-breaking among equal-cost paths in group operations is implementation-defined" });
    }

    // Annex B items 6-15 (always emitted - value declarations)
    const unicode_detail = try std.fmt.allocPrint(allocator, "Unicode version declared: {s}", .{opts.unicode_version});
    try list.append(.{ .code = "UnicodeVersion", .detail = unicode_detail });

    const str_detail = try std.fmt.allocPrint(allocator, "Maximum string value length: {d} code points", .{opts.string_max_length});
    try list.append(.{ .code = "StringMaxLength", .detail = str_detail });

    const bytes_detail = try std.fmt.allocPrint(allocator, "Maximum byte string length: {d} octets", .{opts.bytestring_max_length});
    try list.append(.{ .code = "BytestringMaxLength", .detail = bytes_detail });

    const sec_detail = try std.fmt.allocPrint(allocator, "SECONDS precision for temporal types: {d}", .{opts.seconds_precision});
    try list.append(.{ .code = "SecondsPrec", .detail = sec_detail });

    const tf_detail = try std.fmt.allocPrint(allocator, "Temporal literal format: {s}", .{opts.temporal_format});
    try list.append(.{ .code = "TemporalFormat", .detail = tf_detail });

    const utc_detail = try std.fmt.allocPrint(allocator, "UTC-SLS enabled: {}", .{opts.utc_sls});
    try list.append(.{ .code = "UtcSls", .detail = utc_detail });

    const sp_detail = try std.fmt.allocPrint(allocator, "Session parameter prefix: '{s}'", .{opts.session_param_prefix});
    try list.append(.{ .code = "SessionParamPrefix", .detail = sp_detail });

    const cd_detail = try std.fmt.allocPrint(allocator, "Confusable detection algorithm: {s}", .{opts.confusable_detection});
    try list.append(.{ .code = "ConfusableDetection", .detail = cd_detail });

    const mpt_detail = try std.fmt.allocPrint(allocator, "Minimum required property types: {s}", .{opts.min_property_types});
    try list.append(.{ .code = "MinPropertyTypes", .detail = mpt_detail });

    const cr_detail = try std.fmt.allocPrint(allocator, "Character repertoire: {s}", .{opts.char_repertoire});
    try list.append(.{ .code = "CharRepertoire", .detail = cr_detail });

    return try list.toOwnedSlice();
}

// freeFindings releases allocator memory for findings whose .detail strings
// were allocated by collect() (the value-declaration items).
pub fn freeFindings(allocator: std.mem.Allocator, findings: []ImplDefinedFinding) void {
    // The 10 value-declaration findings (indices from the end) have heap-allocated
    // detail strings.  The boolean-gated findings use string literals.
    // Rather than tracking which are heap-allocated, callers should use an arena.
    // This helper is provided for convenience when using a GPA.
    for (findings) |f| {
        if (std.mem.startsWith(u8, f.code, "UnicodeVersion") or
            std.mem.startsWith(u8, f.code, "StringMaxLength") or
            std.mem.startsWith(u8, f.code, "BytestringMaxLength") or
            std.mem.startsWith(u8, f.code, "SecondsPrec") or
            std.mem.startsWith(u8, f.code, "TemporalFormat") or
            std.mem.startsWith(u8, f.code, "UtcSls") or
            std.mem.startsWith(u8, f.code, "SessionParamPrefix") or
            std.mem.startsWith(u8, f.code, "ConfusableDetection") or
            std.mem.startsWith(u8, f.code, "MinPropertyTypes") or
            std.mem.startsWith(u8, f.code, "CharRepertoire"))
        {
            allocator.free(f.detail);
        }
    }
    allocator.free(findings);
}

test "TestCANARY_REQ_GQL_024_ImplDefinedZeroLengthPathPolicy" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    // All boolean opts default to true; zero_length_paths_excluded=true adds 1 extra
    const findings = try collect(alloc, .{ .zero_length_paths_excluded = true });
    defer freeFindings(alloc, findings);
    // 5 boolean-gated (including ZeroLength) + 10 always-emitted value declarations = 15 total
    // ZeroLength(1) + Collation(2) + NullOrder(3) + UnorderedPagination(4) +
    // UA005(5) + UA006(6) + Unicode(7) + StrMax(8) + BytesMax(9) + SecPrec(10) +
    // TempFmt(11) + UtcSls(12) + SessPrefix(13) + Confusable(14) + MinPropTypes(15)
    // + CharRep(16) = 16
    try std.testing.expectEqual(@as(usize, 16), findings.len);
    try std.testing.expect(std.mem.eql(u8, findings[0].code, "ZeroLengthPathExcluded"));
}

// CANARY: REQ=REQ-GQL-024; FEATURE="Conformance Flagger"; ASPECT=ImplDefinedCollationAndNullOrdering; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_ImplDefinedCollationAndNullOrdering; OWNER=engine; UPDATED=2025-09-21
test "TestCANARY_REQ_GQL_024_ImplDefinedCollationAndNullOrdering" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const findings = try collect(alloc, .{ .zero_length_paths_excluded = false });
    defer freeFindings(alloc, findings);
    // No ZeroLengthPathExcluded: 4 boolean + 10 value = 15 (the 15 Annex B items)
    try std.testing.expectEqual(@as(usize, 15), findings.len);
    var have_coll = false;
    var have_null = false;
    for (findings) |f| {
        if (std.mem.eql(u8, f.code, "CollationBinaryDefault")) have_coll = true;
        if (std.mem.eql(u8, f.code, "NullOrderPolicyDefault")) have_null = true;
    }
    try std.testing.expect(have_coll and have_null);
}

test "TestCANARY_GQL39075_RQ_0003_AnnexBComplete" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    // With zero_length_paths_excluded=false we get exactly the 15 Annex B items
    // matching conformance.zig:collectImplDefinedFlags
    const findings = try collect(alloc, .{ .zero_length_paths_excluded = false });
    defer freeFindings(alloc, findings);
    try std.testing.expectEqual(@as(usize, 15), findings.len);

    // Verify all required Annex B codes are present
    var found_collation = false;
    var found_null_order = false;
    var found_unordered = false;
    var found_ua005 = false;
    var found_ua006 = false;
    var found_unicode = false;
    var found_str_max = false;
    var found_bytes_max = false;
    var found_sec_prec = false;
    var found_temporal = false;
    var found_utc_sls = false;
    var found_sess_prefix = false;
    var found_confusable = false;
    var found_min_prop = false;
    var found_char_rep = false;

    for (findings) |f| {
        if (std.mem.eql(u8, f.code, "CollationBinaryDefault")) found_collation = true;
        if (std.mem.eql(u8, f.code, "NullOrderPolicyDefault")) found_null_order = true;
        if (std.mem.eql(u8, f.code, "UnorderedPaginationAllowed")) found_unordered = true;
        if (std.mem.eql(u8, f.code, "UA005PathTieBreak")) found_ua005 = true;
        if (std.mem.eql(u8, f.code, "UA006PathTieBreak")) found_ua006 = true;
        if (std.mem.eql(u8, f.code, "UnicodeVersion")) found_unicode = true;
        if (std.mem.eql(u8, f.code, "StringMaxLength")) found_str_max = true;
        if (std.mem.eql(u8, f.code, "BytestringMaxLength")) found_bytes_max = true;
        if (std.mem.eql(u8, f.code, "SecondsPrec")) found_sec_prec = true;
        if (std.mem.eql(u8, f.code, "TemporalFormat")) found_temporal = true;
        if (std.mem.eql(u8, f.code, "UtcSls")) found_utc_sls = true;
        if (std.mem.eql(u8, f.code, "SessionParamPrefix")) found_sess_prefix = true;
        if (std.mem.eql(u8, f.code, "ConfusableDetection")) found_confusable = true;
        if (std.mem.eql(u8, f.code, "MinPropertyTypes")) found_min_prop = true;
        if (std.mem.eql(u8, f.code, "CharRepertoire")) found_char_rep = true;
    }

    try std.testing.expect(found_collation);
    try std.testing.expect(found_null_order);
    try std.testing.expect(found_unordered);
    try std.testing.expect(found_ua005);
    try std.testing.expect(found_ua006);
    try std.testing.expect(found_unicode);
    try std.testing.expect(found_str_max);
    try std.testing.expect(found_bytes_max);
    try std.testing.expect(found_sec_prec);
    try std.testing.expect(found_temporal);
    try std.testing.expect(found_utc_sls);
    try std.testing.expect(found_sess_prefix);
    try std.testing.expect(found_confusable);
    try std.testing.expect(found_min_prop);
    try std.testing.expect(found_char_rep);

    // Verify default values are correctly embedded in detail strings
    for (findings) |f| {
        if (std.mem.eql(u8, f.code, "UnicodeVersion")) {
            try std.testing.expect(std.mem.containsAtLeast(u8, f.detail, 1, "15.1.0"));
        }
        if (std.mem.eql(u8, f.code, "StringMaxLength")) {
            try std.testing.expect(std.mem.containsAtLeast(u8, f.detail, 1, "16383"));
        }
        if (std.mem.eql(u8, f.code, "BytestringMaxLength")) {
            try std.testing.expect(std.mem.containsAtLeast(u8, f.detail, 1, "65534"));
        }
        if (std.mem.eql(u8, f.code, "TemporalFormat")) {
            try std.testing.expect(std.mem.containsAtLeast(u8, f.detail, 1, "ISO8601"));
        }
        if (std.mem.eql(u8, f.code, "MinPropertyTypes")) {
            try std.testing.expect(std.mem.containsAtLeast(u8, f.detail, 1, "STRING,BOOLEAN,SIGNEDINTEGER,FLOAT"));
        }
        if (std.mem.eql(u8, f.code, "CharRepertoire")) {
            try std.testing.expect(std.mem.containsAtLeast(u8, f.detail, 1, "Unicode"));
        }
    }
}
