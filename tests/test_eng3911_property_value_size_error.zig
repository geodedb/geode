// Regression tests — ENG-3911: the wire contract for an over-limit property
// value. These pin the ERROR MAPPING only; they use no server and no storage.
//
// ORIGINAL BUG (fixed): an oversized property VALUE reached the client as
// `PropertyKeyTooLong` / SQLSTATE 58000 — the wrong noun AND the
// "internal system error" class for an ordinary caller mistake. The storage
// layer raised `error.PropertyKeyTooLong` for two structurally different
// refusals (genuine key overflow vs. an entry that outgrew the ~8142-byte
// inline per-page budget) and `proto_util.mapError` had no arm for either, so
// the `else` fallback emitted:
//
//     {"status_class":"58000","error":"PropertyKeyTooLong"}
//
// WHAT CHANGED SINCE (graph-storage v0.4.0, pinned 2026-08-25): the ~8142-byte
// inline budget is NO LONGER A CEILING. A value whose entry does not fit inline
// spills into a VarStore overflow chain (13-byte tag-7 stub in the entry), so
// values that used to be refused now STORE and round-trip:
//
//     vectorf32 with 2030 dims  ->  00000    (fits inline, unchanged)
//     vectorf32 with 2048 dims  ->  00000    (was 58000; now spills+stores)
//     vectorf32 with 4096 dims  ->  00000    (16 KB embedding)
//     string of 8132 chars      ->  00000    (fits inline, unchanged)
//     string of 8200 chars      ->  00000    (was 58000; now spills+stores)
//     list parameter, 700 elems ->  00000    (was 58000; now spills+stores)
//
// The value-class refusal survives, but it now means something different and
// truthful: the storage layer itself raises `error.PropertyValueTooLarge` when
// the ENCODED value exceeds `GraphConfig.max_property_value_bytes` — the sanity
// cap that bounds WAL record volume and per-op memory for a spill (default
// 1 MiB ≈ 262,144 f32 dimensions). `error.PropertyKeyTooLong` is now reserved
// for a genuinely oversized KEY. Geode no longer re-attributes anything:
// `graph_storage_adapter.mapPropertyEntryError` is a pass-through seam.
//
// CONTRACT PINNED HERE:
//
//   1. `error.PropertyValueTooLarge` is NOT the generic 58000 system class —
//      an over-cap request is a caller limit, not a server fault.
//   2. It maps to SQLSTATE 54000 (program_limit_exceeded, class 54
//      "insufficient resources / limit exceeded").
//   3. Its message names what actually overflowed (the VALUE, never the key)
//      and states the cap that applies, so an operator can size a payload
//      without reading storage source: the 1 MiB / 1048576-byte cap.
//   4. A GENUINELY oversized property KEY still reports a key error —
//      `error.PropertyKeyTooLong` keeps its own identity and must not be
//      collapsed into the value error. (GUARD.)
//   5. An arbitrary unrelated error still falls through to 58000. (GUARD.)
//   6. `mapPropertyEntryError` is a pass-through: it must NOT invent a value
//      error out of a key error any more, in either direction. (GUARD — the
//      re-map belonged to the pre-v0.4.0 dependency and would now LIE.)
//
// MECHANISM: `proto_util.mapError` is `pub` and takes `anyerror`, and
// `graph_storage_adapter.mapPropertyEntryError` is `pub` too, so the whole
// contract is callable directly — no server, no storage, no mocks.
//
// The end-to-end wire behaviour — the now-succeeding 2048-dim / 8200-char /
// 700-element writes with readback, the 2030-dim and 8132-char inline controls,
// and the oversized-KEY guard — is pinned by the harness specs
// geode-test-harness/geodetestlab-cli/specs/property_value_size_limit.yml and
// .../specs/large_vector_embeddings.yml. Storage-level round-trip, overwrite
// and restart survival of overflowed values are pinned upstream in
// graph-storage v0.4.0.
//
// CANARY: REQ=REQ-ENG-3911-PROPERTY-VALUE-SIZE-ERROR; FEATURE="PropertyStorage"; ASPECT=OversizedValueErrorMapping; STATUS=TESTED; TEST=tests/test_eng3911_property_value_size_error.zig; OWNER=transport; UPDATED=2026-08-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const proto_util = geode.proto_util;
const adapter = geode.graph_storage_adapter;

const GENERIC_SYSTEM_ERROR = "58000";

/// The SQLSTATE class is the first two characters: "54" = program-limit
/// exceeded, "58" = system error. Asserting the class (plus the exact code the
/// contract names) keeps the test readable in failure output.
fn sqlstateClass(code: []const u8) []const u8 {
    return if (code.len >= 2) code[0..2] else code;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

// ---------------------------------------------------------------------------
// (1) The oversized-VALUE error is not the generic system-error class.
// ---------------------------------------------------------------------------
test "ENG-3911: PropertyValueTooLarge is not SQLSTATE 58000" {
    const info = proto_util.mapError(error.PropertyValueTooLarge);

    if (std.mem.eql(u8, info.code, GENERIC_SYSTEM_ERROR)) {
        std.debug.print(
            "\n[ENG-3911] oversized property value mapped to the generic system-error class:\n" ++
                "           code = {s}, message = \"{s}\"\n" ++
                "           A refused-for-documented-limit request is not a server fault.\n",
            .{ info.code, info.message },
        );
        return error.OversizedPropertyValueMappedToSystemError;
    }
}

// ---------------------------------------------------------------------------
// (2) It lands in the limit-exceeded class, at the code the contract names.
// ---------------------------------------------------------------------------
test "ENG-3911: PropertyValueTooLarge maps to SQLSTATE 54000 (program_limit_exceeded)" {
    const info = proto_util.mapError(error.PropertyValueTooLarge);

    try testing.expectEqualStrings("54", sqlstateClass(info.code));
    try testing.expectEqualStrings("54000", info.code);
}

// ---------------------------------------------------------------------------
// (3) The message is truthful and actionable: it blames the VALUE, not the key,
//     and it states the cap the caller has to fit inside — which since
//     graph-storage v0.4.0 is `max_property_value_bytes` (1 MiB), NOT the old
//     ~8142-byte inline page budget (values above that now spill and store).
// ---------------------------------------------------------------------------
test "ENG-3911: the oversized-value message names the value and the 1 MiB value cap" {
    const info = proto_util.mapError(error.PropertyValueTooLarge);

    // It must NOT re-export the dependency's misnomer to the client.
    if (containsIgnoreCase(info.message, "PropertyKeyTooLong")) {
        std.debug.print(
            "\n[ENG-3911] the oversized-VALUE message still blames the KEY: \"{s}\"\n",
            .{info.message},
        );
        return error.OversizedValueMessageBlamesKey;
    }

    // It must say what actually overflowed.
    if (!containsIgnoreCase(info.message, "value")) {
        std.debug.print(
            "\n[ENG-3911] message does not name the property VALUE: \"{s}\"\n",
            .{info.message},
        );
        return error.OversizedValueMessageDoesNotNameValue;
    }

    // It must state the cap that actually applies, so the caller can size their
    // payload. The stale ~8142-byte inline budget must NOT be quoted as the
    // limit: values above it spill to an overflow chain and store fine.
    if (std.mem.indexOf(u8, info.message, "8142") != null) {
        std.debug.print(
            "\n[ENG-3911] message still quotes the obsolete 8142-byte inline budget as the limit: \"{s}\"\n",
            .{info.message},
        );
        return error.OversizedValueMessageQuotesObsoleteInlineBudget;
    }

    if (std.mem.indexOf(u8, info.message, "1048576") == null) {
        std.debug.print(
            "\n[ENG-3911] message does not state the 1048576-byte (1 MiB) value cap: \"{s}\"\n",
            .{info.message},
        );
        return error.OversizedValueMessageOmitsByteBudget;
    }

    // It must name the knob an operator would have to move.
    if (!containsIgnoreCase(info.message, "max_property_value_bytes")) {
        std.debug.print(
            "\n[ENG-3911] message does not name the configurable cap: \"{s}\"\n",
            .{info.message},
        );
        return error.OversizedValueMessageOmitsConfigurableCap;
    }
}

// ---------------------------------------------------------------------------
// (4) GUARD — a genuinely oversized property KEY keeps its own identity.
//     The fix must be a targeted re-map of the mis-attributed case, not a
//     blanket rename that would make key overflows unreportable.
// ---------------------------------------------------------------------------
test "ENG-3911 (guard): PropertyKeyTooLong stays a distinct, key-specific error" {
    const key_info = proto_util.mapError(error.PropertyKeyTooLong);
    const value_info = proto_util.mapError(error.PropertyValueTooLarge);

    // The two outcomes must be distinguishable by a client.
    if (std.mem.eql(u8, key_info.code, value_info.code) and
        std.mem.eql(u8, key_info.message, value_info.message))
    {
        std.debug.print(
            "\n[ENG-3911] key and value overflow are indistinguishable: code={s} message=\"{s}\"\n",
            .{ key_info.code, key_info.message },
        );
        return error.KeyAndValueOverflowCollapsed;
    }

    // A key overflow must still talk about the KEY.
    try testing.expect(containsIgnoreCase(key_info.message, "key"));
}

// ---------------------------------------------------------------------------
// (5) GUARD — the generic fallback survives for genuinely unknown errors.
// ---------------------------------------------------------------------------
test "ENG-3911 (guard): an unrelated error still falls through to 58000" {
    const info = proto_util.mapError(error.SomeCompletelyUnrelatedInternalFailure);
    try testing.expectEqualStrings(GENERIC_SYSTEM_ERROR, info.code);
}

// ---------------------------------------------------------------------------
// (6) GUARD — `mapPropertyEntryError` is a pass-through.
//     Pre-v0.4.0 it re-attributed a short-key `PropertyKeyTooLong` to
//     `PropertyValueTooLarge`, because the dependency conflated the two. The
//     dependency now makes the split itself, so re-attributing would LIE: a
//     `PropertyKeyTooLong` from storage is a real key overflow, and a
//     `PropertyValueTooLarge` is a real over-cap value. Neither may be
//     rewritten, whatever the key length.
// ---------------------------------------------------------------------------
test "ENG-3911 (guard): mapPropertyEntryError passes storage errors through untouched" {
    const long_key = "k" ** 128;

    // A key error stays a key error — short key or long.
    try testing.expectEqual(
        error.PropertyKeyTooLong,
        adapter.mapPropertyEntryError(error.PropertyKeyTooLong, "emb"),
    );
    try testing.expectEqual(
        error.PropertyKeyTooLong,
        adapter.mapPropertyEntryError(error.PropertyKeyTooLong, long_key),
    );

    // The value error the dependency now raises itself survives verbatim.
    try testing.expectEqual(
        error.PropertyValueTooLarge,
        adapter.mapPropertyEntryError(error.PropertyValueTooLarge, "emb"),
    );

    // Unrelated errors are untouched.
    try testing.expectEqual(
        error.OutOfMemory,
        adapter.mapPropertyEntryError(error.OutOfMemory, "emb"),
    );
}
