// SONNY-3055: one string identity, NFC, on every path.
//
// `=` compared two strings by their Normalization Form C forms, but the NFC
// it used knew two characters (é and É); everything else that decides string
// identity compared raw bytes: an inline property map and MERGE
// (execution.valuesEqual), the persisted read paths' stored-property matcher,
// GROUP BY and DISTINCT keys, the planned read's hash join, the exact
// node-property index the WHERE and inline-map seeks probe (persisted as
// prop_exact.idx), MERGE's property index (persisted in hydration_merge.snap),
// its tuple locks and UNIQUE. So `WHERE n.s = 'é'` (precomposed) missed a
// stored 'e' + U+0301 that `=` calls equal, MERGE created a second node, and
// the two were two groups.
//
// ISO/IEC 39075:2024: 19.3 <comparison predicate> General Rule 3b compares
// character strings by their collation (22.16 Determination of collation);
// 4.16.x leaves operations on unnormalized strings implementation-defined
// (IA003) and points to Unicode Standard Annex #15 for the normal forms.
// Geode's collation compares the NFC forms (UAX #15), and every path now
// shares it (src/unicode/canonical_string.zig).
//
// A persisted exact index or merge snapshot written by an earlier binary
// keyed a non-NFC string by its raw bytes; their format editions are bumped
// (prop_exact.idx GENPIDX6, prop_rev.idx GENRVIX3, HYDRATION_SNAP_VERSION 6),
// so such a file is stale and rebuilt on open. The last test writes those
// files with the earlier key derivation (a test-only switch in the adapter
// and the store) and checks that a reopened store answers from the rebuilt
// index, never the old one.
//
// CANARY: REQ=REQ-SONNY-3055-NFC-STRING-IDENTITY; FEATURE="UnicodeEval"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3055_nfc_string_identity.zig; OWNER=unicode; UPDATED=2026-11-13

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const vs = @import("value_semantics_harness.zig");

const Session = vs.Session;
const Failures = vs.Failures;
const Param = vs.Param;
const expectValue = vs.expectValue;
const expectRows = vs.expectRows;

// é precomposed (NFC) and decomposed (NFD).
const e_nfc = "caf\u{00E9}";
const e_nfd = "cafe\u{0301}";
// Hangul GA: the syllable and its conjoining jamo.
const ga_nfc = "\u{AC00}";
const ga_nfd = "\u{1100}\u{1161}";
// ANGSTROM SIGN is a singleton decomposition of Å.
const angstrom_sign = "\u{212B}";
const a_ring = "\u{00C5}";
// Two marks in non-canonical order: dot below (ccc 220) after dot above
// (ccc 230) is reordered by normalization.
const q_marks_a = "q\u{0307}\u{0323}";
const q_marks_b = "q\u{0323}\u{0307}";

fn p(name: []const u8, s: []const u8) Param {
    return .{ .name = name, .value = .{ .Str = s } };
}

fn checkOperators(s: *Session, f: *Failures) !void {
    try expectValue(s, f, "RETURN $a = $b AS r", &.{ p("a", e_nfc), p("b", e_nfd) }, "true");
    try expectValue(s, f, "RETURN $a <> $b AS r", &.{ p("a", e_nfc), p("b", e_nfd) }, "false");
    try expectValue(s, f, "RETURN $a = $b AS r", &.{ p("a", ga_nfc), p("b", ga_nfd) }, "true");
    try expectValue(s, f, "RETURN $a = $b AS r", &.{ p("a", angstrom_sign), p("b", a_ring) }, "true");
    try expectValue(s, f, "RETURN $a = $b AS r", &.{ p("a", q_marks_a), p("b", q_marks_b) }, "true");
    try expectValue(s, f, "RETURN $a = 'cafe' AS r", &.{p("a", e_nfd)}, "false");
    // Order by the NFC form: é (U+00E9) sorts after 'f', though its NFD
    // bytes ('e' ...) sort before it.
    try expectValue(s, f, "RETURN $a > 'caff' AS r", &.{p("a", e_nfd)}, "true");
    try expectValue(s, f, "RETURN $a IN [$b] AS r", &.{ p("a", e_nfd), p("b", e_nfc) }, "true");
}

test "SONNY-3055: = and the order operators compare strings by their NFC forms" {
    try vs.inModes("operators", &vs.eval_modes, checkOperators);
}

fn checkStored(s: *Session, f: *Failures) !void {
    try s.exec("CREATE (:S {s: $v, k: 'nfd'})", &.{p("v", e_nfd)});
    try s.exec("CREATE (:G {s: $v, k: 'nfd'})", &.{p("v", ga_nfd)});
    // WHERE (the planned read seeks the exact index), an inline map (seek
    // and matcher), IN, MERGE.
    try expectRows(s, f, "MATCH (n:S) WHERE n.s = $v RETURN n.k AS k", &.{p("v", e_nfc)}, &.{"'nfd'"});
    try expectRows(s, f, "MATCH (n:S) WHERE n.s = 'caf\u{00E9}' RETURN n.k AS k", &.{}, &.{"'nfd'"});
    try expectRows(s, f, "MATCH (n:S {s: $v}) RETURN n.k AS k", &.{p("v", e_nfc)}, &.{"'nfd'"});
    try expectRows(s, f, "MATCH (n:G {s: $v}) RETURN n.k AS k", &.{p("v", ga_nfc)}, &.{"'nfd'"});
    try expectRows(s, f, "MATCH (n:S) WHERE n.s IN [$v] RETURN n.k AS k", &.{p("v", e_nfc)}, &.{"'nfd'"});
    try expectValue(s, f, "MERGE (n:S {s: $v}) RETURN n.k AS k", &.{p("v", e_nfc)}, "'nfd'");
    try expectValue(s, f, "MERGE (n:G {s: $v}) RETURN n.k AS k", &.{p("v", ga_nfc)}, "'nfd'");
    try expectValue(s, f, "MATCH (n:S) RETURN count(n) AS c", &.{}, "1");
    // GROUP BY, DISTINCT and the hash join see one value.
    try s.exec("CREATE (:S {s: $v, k: 'nfc'})", &.{p("v", e_nfc)});
    try expectValue(s, f, "MATCH (n:S) RETURN count(DISTINCT n.s) AS c", &.{}, "1");
    try expectValue(s, f, "MATCH (n:S) WITH DISTINCT n.s AS s RETURN count(*) AS c", &.{}, "1");
    try expectRows(s, f, "MATCH (n:S) RETURN count(*) AS c GROUP BY n.s", &.{}, &.{"2"});
    try expectValue(s, f, "MATCH (a:S), (b:S) WHERE a.s = b.s RETURN count(*) AS c", &.{}, "4");
    try expectValue(s, f, "MATCH (n:S) WHERE n.s = $v RETURN count(n) AS c", &.{p("v", e_nfd)}, "2");
}

test "SONNY-3055: WHERE seeks, inline maps, IN, MERGE, GROUP BY, DISTINCT and joins find an NFD string by its NFC form" {
    try vs.inModes("stored", &vs.all_modes, checkStored);
}

fn checkUnique(s: *Session, f: *Failures) !void {
    try s.exec("CREATE CONSTRAINT u_s FOR (n:U) REQUIRE n.s IS UNIQUE", &.{});
    try s.exec("CREATE (:U {s: $v})", &.{p("v", e_nfd)});
    try vs.expectFail(s, f, "CREATE (:U {s: $v})", &.{p("v", e_nfc)}, error.UniqueConstraintViolation);
    try expectValue(s, f, "MATCH (n:U) RETURN count(n) AS c", &.{}, "1");
}

test "SONNY-3055: UNIQUE treats NFC and NFD forms as one value" {
    try vs.inModes("unique", &vs.all_modes, checkUnique);
}

// ---------------------------------------------------------------------------
// Upgrade: an exact index and a merge snapshot written with the earlier key
// derivation are rebuilt, not served.
// ---------------------------------------------------------------------------

test "SONNY-3055: a store whose indexes were written with raw-byte string keys is rebuilt on open" {
    const adapter_mod = geode.graph_storage_adapter;
    vs.silenceEngineLogs();
    var f: Failures = .{};
    defer f.deinit();
    var s = try Session.init(.persisted);
    defer s.deinit();
    {
        // An earlier binary: raw-byte string keys, the earlier format editions.
        adapter_mod.setLegacyStringKeysForTest(true);
        defer adapter_mod.setLegacyStringKeysForTest(false);
        geode.graph_store.setLegacyStringKeysForTest(true);
        defer geode.graph_store.setLegacyStringKeysForTest(false);
        try s.exec("CREATE (:L {s: $v, k: 'nfd'})", &.{p("v", e_nfd)});
        try s.exec("MERGE (:L {s: $v, k: 'nfd'})", &.{p("v", e_nfd)});
        // Builds both indexes and writes them at a full checkpoint.
        try expectRows(&s, &f, "MATCH (n:L {s: $v}) RETURN n.k AS k", &.{p("v", e_nfd)}, &.{"'nfd'"});
        const adapter = geode.graph_store.getGlobalAdapter() orelse return error.NoAdapter;
        try adapter.checkpointAll();
        const magic = adapter.exactIndexMagicForTesting(geode.graph_store.DEFAULT_GRAPH_NAME) orelse return error.NoExactIndexFile;
        try testing.expectEqualStrings("GENPIDX5", &magic);
        // The earlier binary shuts down (and persists what it persists at
        // close) before the upgraded one opens the store.
        s.close();
    }
    try s.open();
    try expectRows(&s, &f, "MATCH (n:L) WHERE n.s = $v RETURN n.k AS k", &.{p("v", e_nfc)}, &.{"'nfd'"});
    try expectRows(&s, &f, "MATCH (n:L {s: $v}) RETURN n.k AS k", &.{p("v", e_nfc)}, &.{"'nfd'"});
    try expectValue(&s, &f, "MERGE (n:L {s: $v}) RETURN n.k AS k", &.{p("v", e_nfc)}, "'nfd'");
    try expectValue(&s, &f, "MATCH (n:L) RETURN count(n) AS c", &.{}, "1");
    try f.check("upgrade");
}
