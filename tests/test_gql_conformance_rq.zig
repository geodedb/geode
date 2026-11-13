//! GQL ISO/IEC 39075:2024 Conformance Requirements Unit Tests
//! One test per requirement (RQ-0001 through RQ-0024).
//! Tests verify Geode's implementation against each conformance requirement.
//
// CANARY: REQ=GQL-39075-RQ-0001; FEATURE="Conformance/ExecuteConformingPrograms"; ASPECT=Profile; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0001_ExecuteConformingPrograms; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0002; FEATURE="Conformance/RequiredErrors"; ASPECT=SQLSTATE; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0002_RequiredErrors; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0003; FEATURE="Conformance/GQLFlaggerImplDefined"; ASPECT=AnnexB; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0003_GqlFlaggerImplDefined; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0004; FEATURE="Conformance/ISOFeatureIDs"; ASPECT=ClaimGG01GG20; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0004_ConformanceClaimISO; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0005; FEATURE="Conformance/MinimumLevel"; ASPECT=GG01GG02GG20-23; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0005_MinimumConformanceLevel; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0006; FEATURE="Conformance/UnicodeVersion13"; ASPECT=ImplDefined; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0006_UnicodeVersion13; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0007; FEATURE="Conformance/MinPropertyTypes"; ASPECT=ImplDefined; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0007_MinPropertyTypes; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0008; FEATURE="Conformance/CharRepertoire"; ASPECT=ImplDefined; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0008_CharRepertoire; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0009; FEATURE="Conformance/DefaultCollation"; ASPECT=ImplDefined; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0009_ExactlyOneDefaultCollation; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0010; FEATURE="Conformance/StringMaxLength"; ASPECT=ImplDefined; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0010_StringMaxLength16383; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0011; FEATURE="Conformance/ConfusableNeverSelf"; ASPECT=SkeletonAlgo; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0011_ConfusableNeverSelf; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0012; FEATURE="Conformance/ConfusableDetection"; ASPECT=SQLSTATE42004; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0012_ConfusableIdentifierDetection; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0013; FEATURE="Conformance/UtcSls"; ASPECT=ImplDefined; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0013_UtcSls; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0014; FEATURE="Conformance/TemporalLiteralFormat"; ASPECT=ImplDefined; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0014_TemporalLiteralFormat; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0015; FEATURE="Conformance/SecondsPrecision"; ASPECT=ImplDefined; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0015_SecondsPrecision6; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0016; FEATURE="Conformance/BytestringMaxLength"; ASPECT=ImplDefined; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0016_BytestringMaxLength65534; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0017; FEATURE="Conformance/SessionParamPrefix"; ASPECT=ImplDefined; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0017_SessionParamPrefix; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0018; FEATURE="Conformance/GA08DiagnosticGating"; ASPECT=FeatureFlag; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0018_GA08DiagnosticGating; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0019; FEATURE="Conformance/PrivilegeViolation42000"; ASPECT=SQLSTATE; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0019_PrivilegeViolation42000; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0020; FEATURE="Conformance/ConnectionLoss40003_08007"; ASPECT=SQLSTATE; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0020_ConnectionLoss40003_08007; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0021; FEATURE="Conformance/ImplTransactionsExplicit"; ASPECT=GT01; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0021_ImplTransactionsAreExplicit; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0022; FEATURE="Conformance/KeywordsCaseInsensitive"; ASPECT=Parser; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0022_KeywordsCaseInsensitive; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0023; FEATURE="Conformance/GT01TransactionGating"; ASPECT=FeatureFlag; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0023_GT01TransactionGating; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0024; FEATURE="Conformance/AllImplDefinedItemsEnumerated"; ASPECT=AnnexB; STATUS=TESTED; TEST=TestCANARY_GQL39075_RQ_0024_AllImplDefinedItemsEnumerated; OWNER=conformance; UPDATED=2026-02-23

const std = @import("std");
const geode = @import("geode");

// Imports from the conformance infrastructure.
// lib.zig exports: geode.conformance, geode.gql.status, geode.server_flags,
//                  geode.confusables
const conformance = geode.conformance;
const status = geode.gql.status;
const server_flags = geode.server_flags;
const confusables = geode.confusables;

// RQ-0001: Execute conforming GQL programs.
// The implementation can execute the minimal conforming program set.
test "TestCANARY_GQL39075_RQ_0001_ExecuteConformingPrograms" {
    const prof = conformance.Profile{ .features = .{} };
    try std.testing.expectEqualStrings("1.0", prof.version);
    // Core features that enable executing conforming programs must be true.
    try std.testing.expect(prof.features.select_statement);
    try std.testing.expect(prof.features.return_distinct);
}

// RQ-0002: Required error conditions with correct SQLSTATE codes.
test "TestCANARY_GQL39075_RQ_0002_RequiredErrors" {
    const priv_err = status.privilegeViolation("SELECT");
    try std.testing.expect(priv_err.sqlstate.len > 0);
    const conn_err = status.connectionFailure();
    try std.testing.expect(conn_err.sqlstate.len > 0);
}

// RQ-0003: GQL Flagger enumerates all implementation-defined items.
test "TestCANARY_GQL39075_RQ_0003_GqlFlaggerImplDefined" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const findings = try conformance.collectImplDefinedFlags(alloc);
    defer alloc.free(findings);
    // Must enumerate at least all 15 Annex B items.
    try std.testing.expect(findings.len >= 15);
}

// RQ-0004: Conformance claim includes ISO feature IDs.
test "TestCANARY_GQL39075_RQ_0004_ConformanceClaimISO" {
    const prof = conformance.Profile{ .features = .{} };
    // Must declare at least one of GG01/GG02.
    try std.testing.expect(prof.iso_features.GG01 or prof.iso_features.GG02);
    // Must declare at least one of GG20-GG23.
    const has_labeling = prof.iso_features.GG20 or prof.iso_features.GG21 or
        prof.iso_features.GG22 or prof.iso_features.GG23;
    try std.testing.expect(has_labeling);
}

// RQ-0005: Minimum conformance level (GG01/GG02 + GG20-23).
test "TestCANARY_GQL39075_RQ_0005_MinimumConformanceLevel" {
    const prof = conformance.Profile{ .features = .{} };
    const has_gg01_or_gg02 = prof.iso_features.GG01 or prof.iso_features.GG02;
    const has_gg20_23 = prof.iso_features.GG20 or prof.iso_features.GG21 or
        prof.iso_features.GG22 or prof.iso_features.GG23;
    try std.testing.expect(has_gg01_or_gg02);
    try std.testing.expect(has_gg20_23);
}

// RQ-0006: Unicode version >= 13.0.0 declared.
test "TestCANARY_GQL39075_RQ_0006_UnicodeVersion13" {
    const prof = conformance.Profile{ .features = .{} };
    try std.testing.expect(prof.impl_defined.unicode_version.len > 0);
    // Geode declares 15.1.0, which satisfies >= 13.0.0.
    try std.testing.expectEqualStrings("15.1.0", prof.impl_defined.unicode_version);
}

// RQ-0007: Minimum property value types (STRING, BOOLEAN, SIGNEDINTEGER, FLOAT).
test "TestCANARY_GQL39075_RQ_0007_MinPropertyTypes" {
    const prof = conformance.Profile{ .features = .{} };
    const types = prof.impl_defined.min_property_types;
    try std.testing.expect(std.mem.indexOf(u8, types, "STRING") != null);
    try std.testing.expect(std.mem.indexOf(u8, types, "BOOLEAN") != null);
    try std.testing.expect(std.mem.indexOf(u8, types, "SIGNEDINTEGER") != null);
    try std.testing.expect(std.mem.indexOf(u8, types, "FLOAT") != null);
}

// RQ-0008: Source text character repertoire declared.
test "TestCANARY_GQL39075_RQ_0008_CharRepertoire" {
    const prof = conformance.Profile{ .features = .{} };
    try std.testing.expect(prof.impl_defined.char_repertoire.len > 0);
    try std.testing.expectEqualStrings("Unicode", prof.impl_defined.char_repertoire);
}

// RQ-0009: Exactly one default collation declared.
test "TestCANARY_GQL39075_RQ_0009_ExactlyOneDefaultCollation" {
    const prof = conformance.Profile{ .features = .{} };
    try std.testing.expect(prof.impl_defined.default_collation.len > 0);
    try std.testing.expectEqualStrings("BINARY", prof.impl_defined.default_collation);
}

// RQ-0010: String max length >= 16383 characters.
test "TestCANARY_GQL39075_RQ_0010_StringMaxLength16383" {
    const prof = conformance.Profile{ .features = .{} };
    try std.testing.expect(prof.impl_defined.string_max_length >= 16383);
}

// RQ-0011: Confusable never self-confusable.
test "TestCANARY_GQL39075_RQ_0011_ConfusableNeverSelf" {
    const alloc = std.testing.allocator;
    try std.testing.expect(!try confusables.confusable(alloc, "hello", "hello"));
    try std.testing.expect(!try confusables.confusable(alloc, "geode", "geode"));
    try std.testing.expect(!try confusables.confusable(alloc, "", ""));
}

// RQ-0012: Confusable identifiers detectable (SQLSTATE 42004 path exists).
test "TestCANARY_GQL39075_RQ_0012_ConfusableIdentifierDetection" {
    const alloc = std.testing.allocator;
    // Cyrillic а (U+0430) vs Latin a — skeletons both map to "a", so confusable.
    const latin_abc = "abc";
    const cyrillic_abc = "\xD0\xB0bc"; // Cyrillic а + bc
    try std.testing.expect(try confusables.confusable(alloc, latin_abc, cyrillic_abc));
    // Verify SQLSTATE 42004 is produced by the helper.
    const s = status.confusableIdentifier("myVar", 1, 1);
    try std.testing.expect(std.mem.eql(u8, &s.sqlstate, "42004"));
}

// RQ-0013: UTC-SLS timescale declared.
test "TestCANARY_GQL39075_RQ_0013_UtcSls" {
    const prof = conformance.Profile{ .features = .{} };
    try std.testing.expect(prof.impl_defined.utc_sls == true);
}

// RQ-0014: Temporal literals in ISO 8601 format.
test "TestCANARY_GQL39075_RQ_0014_TemporalLiteralFormat" {
    const prof = conformance.Profile{ .features = .{} };
    try std.testing.expectEqualStrings("ISO8601", prof.impl_defined.temporal_format);
}

// RQ-0015: Seconds precision >= 6 (IL024).
test "TestCANARY_GQL39075_RQ_0015_SecondsPrecision6" {
    const prof = conformance.Profile{ .features = .{} };
    try std.testing.expect(prof.impl_defined.seconds_precision >= 6);
}

// RQ-0016: Bytestring max length >= 65534 bytes.
test "TestCANARY_GQL39075_RQ_0016_BytestringMaxLength65534" {
    const prof = conformance.Profile{ .features = .{} };
    try std.testing.expect(prof.impl_defined.bytestring_max_length >= 65534);
}

// RQ-0017: Session parameters start with "_".
test "TestCANARY_GQL39075_RQ_0017_SessionParamPrefix" {
    const prof = conformance.Profile{ .features = .{} };
    try std.testing.expectEqualStrings("_", prof.impl_defined.session_param_prefix);
}

// RQ-0018: GA08 feature flag for diagnostic records.
test "TestCANARY_GQL39075_RQ_0018_GA08DiagnosticGating" {
    // GA08 is enabled by default.
    try std.testing.expect(server_flags.getGA08DiagnosticsEnabled() == true);
    // Profile also declares GA08 support.
    const prof = conformance.Profile{ .features = .{} };
    try std.testing.expect(prof.iso_features.GA08 == true);
}

// RQ-0019: Privilege violations raise SQLSTATE 42000.
test "TestCANARY_GQL39075_RQ_0019_PrivilegeViolation42000" {
    const s = status.privilegeViolation("CREATE GRAPH");
    try std.testing.expect(std.mem.eql(u8, &s.sqlstate, "42000"));
}

// RQ-0020: Connection loss raises 40003/08007.
test "TestCANARY_GQL39075_RQ_0020_ConnectionLoss40003_08007" {
    const s1 = status.connectionFailure();
    try std.testing.expect(std.mem.eql(u8, &s1.sqlstate, "40003"));
    const s2 = status.connectionFailureCommit();
    try std.testing.expect(std.mem.eql(u8, &s2.sqlstate, "08007"));
}

// RQ-0021: Implementation-defined transactions = explicit transactions.
test "TestCANARY_GQL39075_RQ_0021_ImplTransactionsAreExplicit" {
    const prof = conformance.Profile{ .features = .{} };
    try std.testing.expect(prof.iso_features.GT01 == true);
    try std.testing.expect(server_flags.getGT01ExplicitTransactions() == true);
}

// RQ-0022: GQL keywords are case-insensitive.
test "TestCANARY_GQL39075_RQ_0022_KeywordsCaseInsensitive" {
    const prof = conformance.Profile{ .features = .{} };
    try std.testing.expect(prof.features.case_insensitive_identifiers);
}

// RQ-0023: GT01 feature flag for explicit transactions.
test "TestCANARY_GQL39075_RQ_0023_GT01TransactionGating" {
    // GT01 enabled by default.
    try std.testing.expect(server_flags.getGT01ExplicitTransactions() == true);
    // Flag mechanism works: toggle off and restore.
    server_flags.setGT01ExplicitTransactions(false);
    try std.testing.expect(server_flags.getGT01ExplicitTransactions() == false);
    server_flags.setGT01ExplicitTransactions(true);
}

// RQ-0024: All implementation-defined items enumerated (Annex B).
test "TestCANARY_GQL39075_RQ_0024_AllImplDefinedItemsEnumerated" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const flags = try conformance.collectImplDefinedFlags(alloc);
    defer alloc.free(flags);
    // All 15 Annex B items must be listed.
    try std.testing.expect(flags.len >= 15);
    // Spot-check key items.
    var found_unicode = false;
    var found_collation = false;
    var found_temporal = false;
    for (flags) |f| {
        if (std.mem.startsWith(u8, f, "UnicodeVersion")) found_unicode = true;
        if (std.mem.startsWith(u8, f, "CollationBinaryDefault")) found_collation = true;
        if (std.mem.startsWith(u8, f, "TemporalFormat")) found_temporal = true;
    }
    try std.testing.expect(found_unicode);
    try std.testing.expect(found_collation);
    try std.testing.expect(found_temporal);
}
