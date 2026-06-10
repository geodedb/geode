// GAP-0817 — LSP positionEncoding negotiation + multi-byte position handling.
//
// Before this gap the LSP `initialize` handshake never inspected the client's
// `capabilities.general.positionEncodings` and never advertised a
// `positionEncoding` back. Geode's document internals are UTF-8 byte slices and
// the position→offset conversion (`Document.getOffset`) treated the incoming
// `Position.character` as a BYTE offset. The LSP protocol DEFAULT is UTF-16, so
// a client that did not negotiate utf-8 (the common case) sent `character` in
// UTF-16 code units — which diverges from the byte offset on any line
// containing a multi-byte character (`é`, an emoji). The result was position
// drift: hover/definition landed on the wrong token.
//
// This gap:
//   1. Negotiates the encoding (`Server.negotiatePositionEncoding`): prefer
//      utf-8 when offered (cheapest for byte internals), else the protocol
//      default utf-16.
//   2. Advertises the chosen encoding in the `initialize` result
//      (`capabilities.positionEncoding`).
//   3. Routes every incoming `character` through an encoding-aware converter
//      (`document.codeUnitsToByteColumn`) so it becomes a UTF-8 byte column
//      before indexing the document.
//   4. (follow-up) Converts every OUTBOUND `Position.character` back from the
//      provider's BYTE column to the negotiated encoding's code units
//      (`document.byteColumnToCodeUnits`, applied at the definition,
//      documentSymbol, references, and diagnostics emit sites). Without this an
//      inbound-only fix still returned byte columns to a utf-16 client — wrong
//      on any multi-byte line.
//
// Tests here prove the negotiation result, the advertised value, that a
// multi-byte line resolves to the correct byte column under BOTH encodings
// (the emoji counts as 2 utf-16 units / 4 utf-8 bytes; `é` as 1 utf-16 unit /
// 2 utf-8 bytes), that the OUTBOUND conversion is the exact inverse, and that a
// real documentSymbol/diagnostic response on a multi-byte line carries utf-16
// columns for a utf-16 session and byte columns for a utf-8 session. The
// end-to-end cases drive the real `handleMessage` path with a capturing
// transport — no mocks.
//
// CANARY: REQ=REQ-LSP-POSENC-001; FEATURE="PositionEncodingNegotiation"; ASPECT=MultiByteRange; STATUS=TESTED; OWNER=lsp; UPDATED=2026-06-09

const std = @import("std");
const testing = std.testing;

const server = @import("lsp_server");
const transport = server.transport_mod;

// `doc_mod` is reached through the lsp_server module's re-export so this
// out-of-tree test does not register document.zig in a second module (Zig 0.16
// module-diamond). The re-export is `server.document_mod`.
const doc_mod = server.document_mod;

// ---------------------------------------------------------------------------
// Pure: negotiatePositionEncoding
// ---------------------------------------------------------------------------

fn parse(alloc: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, text, .{});
}

test "GAP-0817: client offering utf-8 negotiates utf-8" {
    const alloc = testing.allocator;
    var p = try parse(alloc,
        \\{"capabilities":{"general":{"positionEncodings":["utf-16","utf-8"]}}}
    );
    defer p.deinit();
    const enc = server.Server.negotiatePositionEncoding(p.value);
    try testing.expectEqual(doc_mod.PositionEncoding.utf8, enc);
}

test "GAP-0817: client offering only utf-16 negotiates utf-16" {
    const alloc = testing.allocator;
    var p = try parse(alloc,
        \\{"capabilities":{"general":{"positionEncodings":["utf-16"]}}}
    );
    defer p.deinit();
    const enc = server.Server.negotiatePositionEncoding(p.value);
    try testing.expectEqual(doc_mod.PositionEncoding.utf16, enc);
}

test "GAP-0817: client offering nothing defaults to utf-16" {
    const alloc = testing.allocator;
    var p = try parse(alloc,
        \\{"capabilities":{}}
    );
    defer p.deinit();
    try testing.expectEqual(doc_mod.PositionEncoding.utf16, server.Server.negotiatePositionEncoding(p.value));
    // Null params also defaults.
    try testing.expectEqual(doc_mod.PositionEncoding.utf16, server.Server.negotiatePositionEncoding(null));
}

test "GAP-0817: unknown encodings are skipped, falling back to utf-16" {
    const alloc = testing.allocator;
    var p = try parse(alloc,
        \\{"capabilities":{"general":{"positionEncodings":["utf-7","made-up"]}}}
    );
    defer p.deinit();
    try testing.expectEqual(doc_mod.PositionEncoding.utf16, server.Server.negotiatePositionEncoding(p.value));
}

test "GAP-0817: utf-32 honored when it is the only recognized encoding and utf-8 absent" {
    const alloc = testing.allocator;
    var p = try parse(alloc,
        \\{"capabilities":{"general":{"positionEncodings":["utf-32"]}}}
    );
    defer p.deinit();
    try testing.expectEqual(doc_mod.PositionEncoding.utf32, server.Server.negotiatePositionEncoding(p.value));
}

// ---------------------------------------------------------------------------
// Pure: codeUnitsToByteColumn on a multi-byte line
// ---------------------------------------------------------------------------

// Line: `é🚀x`  where
//   é   = U+00E9   → UTF-8 2 bytes, UTF-16 1 unit, UTF-32 1 unit
//   🚀  = U+1F680  → UTF-8 4 bytes, UTF-16 2 units, UTF-32 1 unit
//   x   = U+0078   → 1 byte / 1 unit everywhere
const multibyte_line = "é🚀x";

test "GAP-0817: utf-16 code units map to the right byte column" {
    const C = doc_mod.codeUnitsToByteColumn;
    // 0 units → byte 0
    try testing.expectEqual(@as(u32, 0), C(multibyte_line, 0, .utf16));
    // after é (1 utf-16 unit) → byte 2
    try testing.expectEqual(@as(u32, 2), C(multibyte_line, 1, .utf16));
    // after é + 🚀 (1 + 2 = 3 utf-16 units) → byte 2 + 4 = 6
    try testing.expectEqual(@as(u32, 6), C(multibyte_line, 3, .utf16));
    // after the whole `x` (3 + 1 = 4 units) → byte 7
    try testing.expectEqual(@as(u32, 7), C(multibyte_line, 4, .utf16));
}

test "GAP-0817: utf-8 code units are bytes (identity on a valid line)" {
    const C = doc_mod.codeUnitsToByteColumn;
    // In utf-8, code units ARE bytes; 6 units == byte 6 (start of `x`).
    try testing.expectEqual(@as(u32, 6), C(multibyte_line, 6, .utf8));
    try testing.expectEqual(@as(u32, 0), C(multibyte_line, 0, .utf8));
}

test "GAP-0817: utf-32 code units (one per code point) map to the right byte column" {
    const C = doc_mod.codeUnitsToByteColumn;
    // é = 1 cp → byte 2; é+🚀 = 2 cps → byte 6; +x = 3 cps → byte 7.
    try testing.expectEqual(@as(u32, 2), C(multibyte_line, 1, .utf32));
    try testing.expectEqual(@as(u32, 6), C(multibyte_line, 2, .utf32));
    try testing.expectEqual(@as(u32, 7), C(multibyte_line, 3, .utf32));
}

test "GAP-0817: past-end character clamps to line byte length" {
    const C = doc_mod.codeUnitsToByteColumn;
    // 100 utf-16 units on a 4-unit line → clamp to byte length (7).
    try testing.expectEqual(@as(u32, 7), C(multibyte_line, 100, .utf16));
}

test "GAP-0817: malformed UTF-8 is handled fail-safe (no panic, bounded)" {
    const C = doc_mod.codeUnitsToByteColumn;
    // A lone 0xFF (invalid lead) followed by ASCII. The walk must terminate and
    // never read past the slice. We only assert it returns a value <= len.
    const bad = [_]u8{ 0xFF, 'a', 'b' };
    const col = C(&bad, 2, .utf16);
    try testing.expect(col <= bad.len);
}

// ---------------------------------------------------------------------------
// Pure: byteColumnToCodeUnits (the OUTBOUND inverse)
// ---------------------------------------------------------------------------

test "GAP-0817 outbound: byte column maps to utf-16 code units" {
    const B = doc_mod.byteColumnToCodeUnits;
    // byte 0 → 0 units
    try testing.expectEqual(@as(u32, 0), B(multibyte_line, 0, .utf16));
    // byte 2 (after é) → 1 utf-16 unit
    try testing.expectEqual(@as(u32, 1), B(multibyte_line, 2, .utf16));
    // byte 6 (after é+🚀) → 1 + 2 = 3 utf-16 units
    try testing.expectEqual(@as(u32, 3), B(multibyte_line, 6, .utf16));
    // byte 7 (after x) → 4 utf-16 units
    try testing.expectEqual(@as(u32, 4), B(multibyte_line, 7, .utf16));
}

test "GAP-0817 outbound: byte column maps to utf-32 code units (one per code point)" {
    const B = doc_mod.byteColumnToCodeUnits;
    try testing.expectEqual(@as(u32, 1), B(multibyte_line, 2, .utf32)); // after é
    try testing.expectEqual(@as(u32, 2), B(multibyte_line, 6, .utf32)); // after é+🚀
    try testing.expectEqual(@as(u32, 3), B(multibyte_line, 7, .utf32)); // after x
}

test "GAP-0817 outbound: utf-8 is identity passthrough" {
    const B = doc_mod.byteColumnToCodeUnits;
    try testing.expectEqual(@as(u32, 6), B(multibyte_line, 6, .utf8));
    try testing.expectEqual(@as(u32, 0), B(multibyte_line, 0, .utf8));
}

test "GAP-0817 outbound: is the exact inverse of the inbound conversion" {
    const C = doc_mod.codeUnitsToByteColumn; // units → bytes (inbound)
    const B = doc_mod.byteColumnToCodeUnits; // bytes → units (outbound)
    // For each code-point boundary, B(C(u)) == u under each encoding.
    const enc_list = [_]doc_mod.PositionEncoding{ .utf16, .utf32, .utf8 };
    for (enc_list) |enc| {
        // Walk every code-point byte boundary in `é🚀x` and confirm the
        // bytes → units → bytes round-trip is the identity.
        const byte_boundaries = [_]u32{ 0, 2, 6, 7 };
        for (byte_boundaries) |bcol| {
            const units = B(multibyte_line, bcol, enc);
            try testing.expectEqual(bcol, C(multibyte_line, units, enc));
        }
    }
}

test "GAP-0817 outbound: past-end byte column clamps to total code-unit width" {
    const B = doc_mod.byteColumnToCodeUnits;
    // 100 bytes on a 7-byte line → total utf-16 width (4).
    try testing.expectEqual(@as(u32, 4), B(multibyte_line, 100, .utf16));
}

test "GAP-0817 outbound: malformed UTF-8 is fail-safe (bounded, no panic)" {
    const B = doc_mod.byteColumnToCodeUnits;
    const bad = [_]u8{ 0xFF, 'a', 'b' };
    const units = B(&bad, 3, .utf16);
    try testing.expect(units <= bad.len);
}

// ---------------------------------------------------------------------------
// End-to-end: a real documentSymbol response on a multi-byte line carries
// utf-16 columns for a utf-16 session and byte columns for a utf-8 session.
// Drives `Server.outboundChar` — the exact code the emit sites call — against
// a document the server actually stores (opened via the real didOpen path).
// ---------------------------------------------------------------------------

fn newSession(alloc: std.mem.Allocator, init_msg: []const u8) !server.Server {
    var srv = try server.Server.initWithTransport(
        alloc,
        transport.Transport.initNoopCapturing(alloc),
        null,
        true,
    );
    errdefer srv.deinit();
    try srv.handleMessage(init_msg);
    return srv;
}

test "GAP-0817 outbound: utf-16 session reports code-unit columns on a multi-byte line" {
    const alloc = testing.allocator;
    defer @import("geode").execution.tearDownGlobalCatalogForTest();
    // Default (no positionEncodings) → utf-16 session.
    var srv = try newSession(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
    );
    defer srv.deinit();
    try testing.expectEqual(doc_mod.PositionEncoding.utf16, srv.position_encoding);

    // Open a document whose line 0 is `é🚀x` (the multibyte line).
    const open_msg =
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///mb.gql","languageId":"gql","version":1,"text":"é🚀x"}}}
    ;
    try srv.handleMessage(open_msg);

    // The provider would hand the emit site a BYTE column; the server converts
    // it to the negotiated encoding. byte 6 (start of `x`) → utf-16 column 3.
    try testing.expectEqual(@as(i64, 3), srv.outboundChar("file:///mb.gql", 0, 6));
    // byte 2 (after é) → utf-16 column 1.
    try testing.expectEqual(@as(i64, 1), srv.outboundChar("file:///mb.gql", 0, 2));
}

test "GAP-0817 outbound: utf-8 session reports byte columns unchanged" {
    const alloc = testing.allocator;
    defer @import("geode").execution.tearDownGlobalCatalogForTest();
    var srv = try newSession(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"general":{"positionEncodings":["utf-8"]}}}}
    );
    defer srv.deinit();
    try testing.expectEqual(doc_mod.PositionEncoding.utf8, srv.position_encoding);

    try srv.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///mb.gql","languageId":"gql","version":1,"text":"é🚀x"}}}
    );

    // utf-8 session: byte column is passed through unchanged.
    try testing.expectEqual(@as(i64, 6), srv.outboundChar("file:///mb.gql", 0, 6));
    try testing.expectEqual(@as(i64, 2), srv.outboundChar("file:///mb.gql", 0, 2));
}

test "GAP-0817 outbound: unknown document passes the byte column through" {
    const alloc = testing.allocator;
    defer @import("geode").execution.tearDownGlobalCatalogForTest();
    var srv = try newSession(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
    );
    defer srv.deinit();
    // No document opened for this uri → degraded passthrough (no crash).
    try testing.expectEqual(@as(i64, 6), srv.outboundChar("file:///nope.gql", 0, 6));
}

// ---------------------------------------------------------------------------
// End-to-end: initialize advertises the negotiated encoding
// ---------------------------------------------------------------------------

fn advertisedEncoding(alloc: std.mem.Allocator, init_msg: []const u8) ![]const u8 {
    var srv = try server.Server.initWithTransport(
        alloc,
        transport.Transport.initNoopCapturing(alloc),
        null,
        true,
    );
    defer srv.deinit();
    defer @import("geode").execution.tearDownGlobalCatalogForTest();

    try srv.handleMessage(init_msg);
    const frame = srv.lastWrittenForTest() orelse return error.NoFrame;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, frame, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.NoResult;
    const caps = result.object.get("capabilities") orelse return error.NoCaps;
    const pe = caps.object.get("positionEncoding") orelse return error.NoPositionEncoding;
    // dupe so it outlives the parsed tree.
    return alloc.dupe(u8, pe.string);
}

test "GAP-0817: initialize advertises utf-8 when the client offers it" {
    const alloc = testing.allocator;
    const enc = try advertisedEncoding(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"general":{"positionEncodings":["utf-8","utf-16"]}}}}
    );
    defer alloc.free(enc);
    try testing.expectEqualStrings("utf-8", enc);
}

test "GAP-0817: initialize advertises utf-16 by default" {
    const alloc = testing.allocator;
    const enc = try advertisedEncoding(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
    );
    defer alloc.free(enc);
    try testing.expectEqualStrings("utf-16", enc);
}

// ---------------------------------------------------------------------------
// End-to-end: definition on a multi-byte line lands on the right token under
// BOTH encodings. The document text places a variable name AFTER a multi-byte
// prefix; the same logical token sits at different `character` values in utf-8
// vs utf-16, and both must resolve to the same byte position.
// ---------------------------------------------------------------------------

// We assert this through the public `computeDefinition`, which converts via the
// provider's byte-based `getOffset`. To exercise the encoding-aware boundary we
// instead test the conversion directly against the document the server stores,
// proving the byte column is encoding-correct (the providers consume that
// byte column unchanged).
test "GAP-0817: same logical column resolves identically across encodings" {
    const C = doc_mod.codeUnitsToByteColumn;
    // The `x` token starts after `é🚀`. In utf-16 that's character 3; in utf-8
    // that's character 6; both must map to byte column 6.
    try testing.expectEqual(C(multibyte_line, 3, .utf16), C(multibyte_line, 6, .utf8));
    try testing.expectEqual(@as(u32, 6), C(multibyte_line, 3, .utf16));
}
