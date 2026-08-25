// RED reproduction tests — ENG-3911: an oversized property VALUE is reported to
// the client as `PropertyKeyTooLong` / SQLSTATE 58000 — a message that names the
// wrong thing and a status class that says "internal system error" about a
// perfectly ordinary caller mistake.
//
// THE BUG (triage complete; verified live against v0.8.5 / 5c37d58a with a
// `--data-dir`-backed server, i.e. the persistent property-page path):
//
//   Per-entry budget is 8142 bytes (8192-byte page minus header; an entry is
//   2 + key.len + encoded value). Crossing it raises `error.PropertyKeyTooLong`
//   inside the graph_storage dependency — a misnomer the dependency's own
//   comment admits — and `proto_util.mapError` (src/server/proto_util.zig:244)
//   has no arm for it, so the `else` fallback emits:
//
//       {"status_class":"58000","error":"PropertyKeyTooLong"}
//
//   Live probe (property key is `emb` / `s` — three characters, nowhere near
//   any key limit):
//
//     vectorf32 with 2030 dims  ->  00000            (fits: 2030*4 + overhead)
//     vectorf32 with 2048 dims  ->  58000 "PropertyKeyTooLong"
//     string of 8132 chars      ->  00000
//     string of 8200 chars      ->  58000 "PropertyKeyTooLong"
//     list parameter, 700 elems ->  58000 "PropertyKeyTooLong"
//
//   Two independent defects in one response: (a) the message blames the KEY when
//   the VALUE is what overflowed, sending every operator who reads it down the
//   wrong path; (b) 58000 is the system-error class, which tells clients and
//   monitoring "the server broke", when in truth the request was refused for a
//   documented resource limit and the server is perfectly healthy.
//
// INTENDED FIX CONTRACT (what these tests pin; NOT the implementation):
//
//   1. When the storage layer reports the per-entry overflow for a SHORT key,
//      geode surfaces a TRUTHFUL, distinctly-named error —
//      `error.PropertyValueTooLarge` — instead of re-exporting the dependency's
//      misnomer.
//   2. That error maps to SQLSTATE 54000 (program_limit_exceeded, class 54
//      "insufficient resources / limit exceeded"), NOT 58000.
//   3. Its message names what actually overflowed and states the byte budget,
//      so an operator can size their payload without reading storage source:
//      it mentions the value/property-size limit and the number 8142.
//   4. A GENUINELY oversized property KEY still reports a key error —
//      `error.PropertyKeyTooLong` keeps its own identity and must not be
//      collapsed into the new value error. (GUARD: the fix is a re-map of a
//      specific mis-attributed case, not a blanket rename.)
//   5. An arbitrary unrelated error still falls through to 58000. (GUARD.)
//
// RED MECHANISM: `proto_util.mapError` is `pub` and takes `anyerror`, so both
// the current misnomer and the intended error name are callable directly — no
// server, no storage, no mocks. Tests 1-3 fail today (`error.PropertyValueTooLarge`
// has no arm and falls to 58000 with `@errorName` as its message); tests 4-5
// pass today and must keep passing.
//
// The end-to-end wire behaviour, the 2030-dim control, and the partial-write
// reality (the node persists WITHOUT the offending property) are pinned by the
// harness spec
// geode-test-harness/geodetestlab-cli/specs/property_value_size_limit.yml.
//
// NOT IN SCOPE: raising the 8142-byte per-entry cap itself. That is a storage
// format change tracked separately; this ticket only makes the refusal honest.
//
// CANARY: REQ=REQ-ENG-3911-PROPERTY-VALUE-SIZE-ERROR; FEATURE="PropertyStorage"; ASPECT=OversizedValueErrorMapping; STATUS=TESTED; TEST=tests/test_eng3911_property_value_size_error.zig; OWNER=transport; UPDATED=2026-08-24

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const proto_util = geode.proto_util;

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
//     and it states the byte budget the caller has to fit inside.
// ---------------------------------------------------------------------------
test "ENG-3911: the oversized-value message names the value and the 8142-byte budget" {
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

    // It must state the budget, so the caller can size their payload.
    if (std.mem.indexOf(u8, info.message, "8142") == null) {
        std.debug.print(
            "\n[ENG-3911] message does not state the 8142-byte per-entry budget: \"{s}\"\n",
            .{info.message},
        );
        return error.OversizedValueMessageOmitsByteBudget;
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
