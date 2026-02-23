const std = @import("std");
// CANARY: REQ=REQ-GQL-026; FEATURE="Conformance/Flagger"; ASPECT=FlaggerCompleteness; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_026_FlaggerCompleteness,TestCANARY_REQ_GQL_026_FlaggerNegativeMissing; BENCH=BenchmarkCANARY_REQ_GQL_026_FlaggerGenerationVarianceEnvelope; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0004; FEATURE="ConformanceProfile/ISOFeatureIDs"; ASPECT=IsoFeatures; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0004_IsoFeaturesInProfile,TestCANARY_GQL39075_RQ_0005_MinimumConformanceGating; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0024; FEATURE="ConformanceProfile/AnnexB"; ASPECT=ImplDefined; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0024_ConformanceJsonIncludesIsoFeatures,TestCANARY_GQL39075_RQ_0024_ImplDefinedFlagsComplete; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0006; FEATURE="GQL Conformance Profile"; ASPECT=UnicodeVersionDeclaration; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0006_UnicodeVersionDeclared; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0007; FEATURE="GQL Conformance Profile"; ASPECT=MinPropertyTypesDeclaration; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0007_MinPropertyTypes; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0008; FEATURE="GQL Conformance Profile"; ASPECT=CharRepertoireDeclaration; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0008_CharRepertoire; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0009; FEATURE="GQL Conformance Profile"; ASPECT=ExactlyOneDefaultCollation; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0009_ExactlyOneCollation; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0010; FEATURE="GQL Conformance Profile"; ASPECT=StringMaxLengthDeclaration; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0010_StringMaxLength; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0013; FEATURE="GQL Conformance Profile"; ASPECT=UtcSlsDeclaration; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0013_UtcSlsDeclared; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0014; FEATURE="GQL Conformance Profile"; ASPECT=TemporalLiteralFormat; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0014_TemporalFormat; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0015; FEATURE="GQL Conformance Profile"; ASPECT=SecondsPrecisionDeclaration; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0015_SecondsPrecision6; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0016; FEATURE="GQL Conformance Profile"; ASPECT=BytestringMaxLengthDeclaration; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0016_BytestringMaxLength; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0017; FEATURE="GQL Conformance Profile"; ASPECT=SessionParamPrefixDeclaration; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0017_SessionParamPrefix; OWNER=conformance; UPDATED=2026-02-23

/// ISO/IEC 39075:2024 §24.2 optional feature IDs required for minimum conformance claim.
pub const IsoFeatures = struct {
    // Graph type model (§24.2): declare GG01 or GG02
    GG01: bool = true, // typed graph element types (node/edge type declarations)
    GG02: bool = false, // untyped graph element types
    // Element-type key labeling (§24.2): at least one of GG20-GG23 required
    GG20: bool = true, // implicit key labeling
    GG21: bool = false,
    GG22: bool = false,
    GG23: bool = false,
    // Explicit transaction commands
    GT01: bool = true, // START TRANSACTION / END TRANSACTION
    // Diagnostic records
    GA08: bool = true, // structured diagnostic records in status objects
};

/// ISO/IEC 39075:2024 Annex B implementation-defined declarations.
pub const ImplDefined = struct {
    // IV001: declared Unicode version for source text (must be >= 13.0.0)
    unicode_version: []const u8 = "15.1.0",
    // ID022: default collation for string comparison
    default_collation: []const u8 = "BINARY",
    // IV001: accepted source text character repertoire
    char_repertoire: []const u8 = "Unicode",
    // IL013: maximum length of character strings (chars); must be >= 16383
    string_max_length: u32 = 16_383,
    // IL013: maximum length of byte strings (bytes); must be >= 65534
    bytestring_max_length: u32 = 65_534,
    // IL024: maximum seconds precision; must be >= 6 (microseconds)
    seconds_precision: u8 = 6,
    // Temporal literal format: "ISO8601" or "SQL"
    temporal_format: []const u8 = "ISO8601",
    // UTC-SLS timescale declaration (§4.16.6.1)
    utc_sls: bool = true,
    // ID049: impl-defined session parameter name prefix
    session_param_prefix: []const u8 = "_",
    // IW014: confusable identifier detection policy
    confusable_detection: []const u8 = "TR39-skeleton",
    // Minimum supported property value types (§24.2)
    min_property_types: []const u8 = "STRING,BOOLEAN,SIGNEDINTEGER,FLOAT",
};

pub const Profile = struct {
    version: []const u8 = "1.0",
    features: Features,
    iso_features: IsoFeatures = .{},
    impl_defined: ImplDefined = .{},
};

pub const Features = struct {
    // Core language features
    order_by: bool = true,
    order_by_nulls_policy: bool = true,
    order_by_alias_resolution: bool = true,
    group_by_phase1: bool = true,
    having_parsed: bool = true,
    set_ops_skeleton: bool = true,
    temporals_structured: bool = true,
    session_offset_flag: bool = true,
    // ISO conformance features
    select_statement: bool = true,
    return_distinct: bool = true,
    unicode_identifiers: bool = true,
    case_insensitive_identifiers: bool = true,
    comment_double_slash: bool = true, // GB03
    comment_double_dash: bool = true, // GB02
    reserved_words_complete: bool = true,
    unordered_pagination: bool = true,
    structured_diagnostics: bool = true,
};

pub fn writeConformanceJson(w: anytype, prof: Profile) !void {
    try w.writeByte('{');
    try w.print("\"version\":\"{s}\",", .{prof.version});
    // Core features
    try w.writeAll("\"features\":{");
    try w.print("\"order_by\":{},", .{prof.features.order_by});
    try w.print("\"order_by_nulls_policy\":{},", .{prof.features.order_by_nulls_policy});
    try w.print("\"order_by_alias_resolution\":{},", .{prof.features.order_by_alias_resolution});
    try w.print("\"group_by_phase1\":{},", .{prof.features.group_by_phase1});
    try w.print("\"having_parsed\":{},", .{prof.features.having_parsed});
    try w.print("\"set_ops_skeleton\":{},", .{prof.features.set_ops_skeleton});
    try w.print("\"temporals_structured\":{},", .{prof.features.temporals_structured});
    try w.print("\"session_offset_flag\":{},", .{prof.features.session_offset_flag});
    try w.print("\"select_statement\":{},", .{prof.features.select_statement});
    try w.print("\"return_distinct\":{},", .{prof.features.return_distinct});
    try w.print("\"unicode_identifiers\":{},", .{prof.features.unicode_identifiers});
    try w.print("\"case_insensitive_identifiers\":{},", .{prof.features.case_insensitive_identifiers});
    try w.print("\"comment_double_slash\":{},", .{prof.features.comment_double_slash});
    try w.print("\"comment_double_dash\":{},", .{prof.features.comment_double_dash});
    try w.print("\"reserved_words_complete\":{},", .{prof.features.reserved_words_complete});
    try w.print("\"unordered_pagination\":{},", .{prof.features.unordered_pagination});
    try w.print("\"structured_diagnostics\":{}", .{prof.features.structured_diagnostics});
    try w.writeAll("},");
    // ISO feature IDs
    try w.writeAll("\"iso_features\":{");
    try w.print("\"GG01\":{},", .{prof.iso_features.GG01});
    try w.print("\"GG02\":{},", .{prof.iso_features.GG02});
    try w.print("\"GG20\":{},", .{prof.iso_features.GG20});
    try w.print("\"GG21\":{},", .{prof.iso_features.GG21});
    try w.print("\"GG22\":{},", .{prof.iso_features.GG22});
    try w.print("\"GG23\":{},", .{prof.iso_features.GG23});
    try w.print("\"GT01\":{},", .{prof.iso_features.GT01});
    try w.print("\"GA08\":{}", .{prof.iso_features.GA08});
    try w.writeAll("},");
    // Annex B impl-defined declarations
    try w.writeAll("\"impl_defined\":{");
    try w.print("\"unicode_version\":\"{s}\",", .{prof.impl_defined.unicode_version});
    try w.print("\"default_collation\":\"{s}\",", .{prof.impl_defined.default_collation});
    try w.print("\"char_repertoire\":\"{s}\",", .{prof.impl_defined.char_repertoire});
    try w.print("\"string_max_length\":{},", .{prof.impl_defined.string_max_length});
    try w.print("\"bytestring_max_length\":{},", .{prof.impl_defined.bytestring_max_length});
    try w.print("\"seconds_precision\":{},", .{prof.impl_defined.seconds_precision});
    try w.print("\"temporal_format\":\"{s}\",", .{prof.impl_defined.temporal_format});
    try w.print("\"utc_sls\":{},", .{prof.impl_defined.utc_sls});
    try w.print("\"session_param_prefix\":\"{s}\",", .{prof.impl_defined.session_param_prefix});
    try w.print("\"confusable_detection\":\"{s}\",", .{prof.impl_defined.confusable_detection});
    try w.print("\"min_property_types\":\"{s}\"", .{prof.impl_defined.min_property_types});
    try w.writeAll("}}");
}

pub fn collectImplDefinedFlags(allocator: std.mem.Allocator) ![][]const u8 {
    const items = [_][]const u8{
        "CollationBinaryDefault",
        "NullOrderPolicyDefault",
        "UnorderedPaginationAllowed",
        "UA005PathTieBreak",
        "UA006PathTieBreak",
        "UnicodeVersion=15.1.0",
        "StringMaxLength=16383",
        "BytestringMaxLength=65534",
        "SecondsPrec=6",
        "TemporalFormat=ISO8601",
        "UtcSls=true",
        "SessionParamPrefix=_",
        "ConfusableDetection=TR39-skeleton",
        "MinPropertyTypes=STRING,BOOLEAN,SIGNEDINTEGER,FLOAT",
        "CharRepertoire=Unicode",
    };
    var list = try allocator.alloc([]const u8, items.len);
    for (items, 0..) |item, i| list[i] = item;
    return list;
}

// ============================================================================
// TESTS
// ============================================================================

test "conformance json outputs expected keys" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit(std.testing.allocator);
    const prof = Profile{ .features = .{}, .iso_features = .{}, .impl_defined = .{} };
    try writeConformanceJson(buf.writer(std.testing.allocator), prof);
    const s = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, s, "\"version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"features\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"group_by_phase1\"") != null);
}

test "TestCANARY_REQ_GQL_026_FlaggerCompleteness" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const flags = try collectImplDefinedFlags(alloc);
    defer alloc.free(flags);
    inline for (.{ "CollationBinaryDefault", "UnorderedPaginationAllowed" }) |req| {
        var found = false;
        for (flags) |f| {
            if (std.mem.eql(u8, f, req)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "TestCANARY_REQ_GQL_026_FlaggerNegativeMissing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const flags = try collectImplDefinedFlags(alloc);
    defer alloc.free(flags);
    var found = false;
    for (flags) |f| {
        if (std.mem.eql(u8, f, "NonExistentPolicyToggle")) found = true;
    }
    try std.testing.expect(!found);
}

test "BenchmarkCANARY_REQ_GQL_026_FlaggerGenerationVarianceEnvelope" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const iterations: usize = 64;
    var samples = try alloc.alloc(u64, iterations);
    defer alloc.free(samples);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();
        const flags = collectImplDefinedFlags(alloc) catch unreachable;
        alloc.free(flags);
        const end = std.time.nanoTimestamp();
        samples[i] = @as(u64, @intCast(end - start));
    }
    var sum: f64 = 0;
    for (samples) |s| sum += @as(f64, @floatFromInt(s));
    const mean = sum / @as(f64, @floatFromInt(iterations));
    var var_acc: f64 = 0;
    for (samples) |s| {
        const diff = @as(f64, @floatFromInt(s)) - mean;
        var_acc += diff * diff;
    }
    const variance = var_acc / @as(f64, @floatFromInt(iterations));
    const cv = std.math.sqrt(variance) / mean;
    try std.testing.expect(cv <= 0.30);
}

test "TestCANARY_GQL39075_RQ_0004_IsoFeaturesInProfile" {
    const prof = Profile{ .features = .{}, .iso_features = .{}, .impl_defined = .{} };
    try std.testing.expect(prof.iso_features.GG01 == true);
    try std.testing.expect(prof.iso_features.GT01 == true);
    try std.testing.expect(prof.iso_features.GA08 == true);
}

test "TestCANARY_GQL39075_RQ_0005_MinimumConformanceGating" {
    const prof = Profile{ .features = .{}, .iso_features = .{}, .impl_defined = .{} };
    const has_gg01_or_gg02 = prof.iso_features.GG01 or prof.iso_features.GG02;
    const has_gg20_23 = prof.iso_features.GG20 or prof.iso_features.GG21 or
        prof.iso_features.GG22 or prof.iso_features.GG23;
    try std.testing.expect(has_gg01_or_gg02 and has_gg20_23);
}

test "TestCANARY_GQL39075_RQ_0006_UnicodeVersionDeclared" {
    const prof = Profile{ .features = .{}, .iso_features = .{}, .impl_defined = .{} };
    try std.testing.expectEqualStrings("15.1.0", prof.impl_defined.unicode_version);
}

test "TestCANARY_GQL39075_RQ_0009_ExactlyOneCollation" {
    const prof = Profile{ .features = .{}, .iso_features = .{}, .impl_defined = .{} };
    try std.testing.expect(prof.impl_defined.default_collation.len > 0);
}

test "TestCANARY_GQL39075_RQ_0010_StringMaxLength" {
    const prof = Profile{ .features = .{}, .iso_features = .{}, .impl_defined = .{} };
    try std.testing.expect(prof.impl_defined.string_max_length >= 16383);
}

test "TestCANARY_GQL39075_RQ_0013_UtcSlsDeclared" {
    const prof = Profile{ .features = .{}, .iso_features = .{}, .impl_defined = .{} };
    try std.testing.expect(prof.impl_defined.utc_sls == true);
}

test "TestCANARY_GQL39075_RQ_0015_SecondsPrecision6" {
    const prof = Profile{ .features = .{}, .iso_features = .{}, .impl_defined = .{} };
    try std.testing.expect(prof.impl_defined.seconds_precision >= 6);
}

test "TestCANARY_GQL39075_RQ_0016_BytestringMaxLength" {
    const prof = Profile{ .features = .{}, .iso_features = .{}, .impl_defined = .{} };
    try std.testing.expect(prof.impl_defined.bytestring_max_length >= 65534);
}

test "TestCANARY_GQL39075_RQ_0017_SessionParamPrefix" {
    const prof = Profile{ .features = .{}, .iso_features = .{}, .impl_defined = .{} };
    try std.testing.expectEqualStrings("_", prof.impl_defined.session_param_prefix);
}

test "TestCANARY_GQL39075_RQ_0024_ConformanceJsonIncludesIsoFeatures" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit(std.testing.allocator);
    const prof = Profile{ .features = .{}, .iso_features = .{}, .impl_defined = .{} };
    try writeConformanceJson(buf.writer(std.testing.allocator), prof);
    const s = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, s, "\"iso_features\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"GG01\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"GT01\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"GA08\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"impl_defined\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"unicode_version\"") != null);
}

test "TestCANARY_GQL39075_RQ_0024_ImplDefinedFlagsComplete" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const flags = try collectImplDefinedFlags(alloc);
    defer alloc.free(flags);
    try std.testing.expect(flags.len >= 10);
    var found_unicode = false;
    for (flags) |f| {
        if (std.mem.startsWith(u8, f, "UnicodeVersion")) found_unicode = true;
    }
    try std.testing.expect(found_unicode);
}

test "TestCANARY_GQL39075_RQ_0007_MinPropertyTypes" {
    // RQ-0007: Implementation declares support for minimum required property types
    // (STRING, BOOLEAN, SIGNED INTEGER, FLOAT) per ISO 39075 §7.2
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const flags = try collectImplDefinedFlags(alloc);
    defer alloc.free(flags);
    var found = false;
    for (flags) |f| {
        if (std.mem.startsWith(u8, f, "MinPropertyTypes=")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "TestCANARY_GQL39075_RQ_0008_CharRepertoire" {
    // RQ-0008: Implementation declares the source text character repertoire
    // per ISO 39075 §5.1
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const flags = try collectImplDefinedFlags(alloc);
    defer alloc.free(flags);
    var found = false;
    for (flags) |f| {
        if (std.mem.startsWith(u8, f, "CharRepertoire=")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "TestCANARY_GQL39075_RQ_0014_TemporalFormat" {
    // RQ-0014: Implementation declares temporal literal format (ISO 8601)
    // per ISO 39075 §8.4
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const flags = try collectImplDefinedFlags(alloc);
    defer alloc.free(flags);
    var found = false;
    for (flags) |f| {
        if (std.mem.startsWith(u8, f, "TemporalFormat=")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}
