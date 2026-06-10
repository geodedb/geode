// GAP-0831 — LSP capability-vs-handler truthfulness guard.
//
// Prevents the GAP-0056-style regression where a capability is advertised in
// the `initialize` result without a wired request handler (a client then waits
// on its read timeout for a reply that never comes), or — the inverse — a
// handler exists for a feature method that the server never advertised (the
// client never sends the request, so the handler is dead).
//
// This is a STRUCTURAL test. It introspects the two single-source-of-truth
// surfaces the production dispatch is built from:
//
//   1. `Server.buildCapabilitiesObject(alloc)` — the exact same code path
//      `handleInitialize` serializes into the `capabilities` object, so the
//      advertised key set cannot drift from reality.
//   2. `server.handled_request_methods` / `server.handled_notification_methods`
//      — the exact lists the `Methods.*` dispatch chain references.
//
// The mapping between a capability key and the request method(s) it implies is
// maintained as an explicit in-test table (the LSP 3.17 spec contract). Both
// directions are checked:
//   (a) every advertised feature capability has a wired handler;
//   (b) every wired feature request method has an advertised capability.
//
// Lifecycle / control methods (initialize, shutdown) and notifications are
// exempt from the capability mapping via an explicit exemption list — they are
// mandated by the LSP base protocol, not advertised through ServerCapabilities.
// The one structural assertion kept for notifications is that the
// textDocument/did* trio implies `textDocumentSync` is advertised.
//
// CANARY: REQ=REQ-LSP-CAP-001; FEATURE="CapabilityHandlerTruthfulness"; ASPECT=BidirectionalGuard; STATUS=TESTED; OWNER=lsp; UPDATED=2026-06-09

const std = @import("std");
const testing = std.testing;

const server = @import("lsp_server");

// ---------------------------------------------------------------------------
// In-test mapping table: capability key ⇄ the request method(s) it implies.
//
// Derived from the LSP 3.17 specification's ServerCapabilities → request
// correspondence. This is the human-authored "what SHOULD be true" reference
// the code is checked against. A capability advertised without its handler, or
// a handler without its capability, fails the bidirectional assertions below.
// ---------------------------------------------------------------------------

const CapMethodMapping = struct {
    capability: []const u8,
    methods: []const []const u8,
};

const cap_method_table = [_]CapMethodMapping{
    .{ .capability = "hoverProvider", .methods = &[_][]const u8{"textDocument/hover"} },
    .{ .capability = "completionProvider", .methods = &[_][]const u8{"textDocument/completion"} },
    .{ .capability = "definitionProvider", .methods = &[_][]const u8{"textDocument/definition"} },
    .{ .capability = "documentFormattingProvider", .methods = &[_][]const u8{"textDocument/formatting"} },
    .{ .capability = "documentSymbolProvider", .methods = &[_][]const u8{"textDocument/documentSymbol"} },
    .{ .capability = "signatureHelpProvider", .methods = &[_][]const u8{"textDocument/signatureHelp"} },
    .{ .capability = "referencesProvider", .methods = &[_][]const u8{"textDocument/references"} },
    .{ .capability = "semanticTokensProvider", .methods = &[_][]const u8{"textDocument/semanticTokens/full"} },
};

// GAP-0817: `positionEncoding` is a DATA capability (a string echoing the
// negotiated encoding), not a request-handler capability — there is no method
// behind it. It is advertised but maps to no dispatch, so the "every advertised
// capability has a wired handler" direction must treat it as exempt (same shape
// as textDocumentSync, but with no backing notification either).
const non_method_capability_keys = [_][]const u8{
    "positionEncoding",
};

// GAP-0820..0824: capabilities Geode's LSP server INTENTIONALLY does not
// advertise (the "honest non-support" contract). Each is the inverse of the
// truthfulness guarantee this file enforces: GAP-0831 proves every advertised
// capability has a handler; these prove the deliberately-unadvertised
// capabilities are NOT advertised (so the unadvertised feature requests fall
// through to -32601, and the unadvertised notifications are silently tolerated
// — see tests/test_gap0820_0824_lsp_nonsupport.zig for the behavioral proof).
// This list is checked against the live `buildCapabilitiesObject` keys below so
// a future change that starts advertising any of them without wiring a handler
// trips this guard.
const IntentionallyUnsupportedCapability = struct {
    capability: []const u8,
    gap: []const u8,
};
const intentionally_unsupported_capabilities = [_]IntentionallyUnsupportedCapability{
    .{ .capability = "workspace", .gap = "GAP-0820" }, // workspace/* family
    .{ .capability = "workspaceSymbolProvider", .gap = "GAP-0820" },
    .{ .capability = "executeCommandProvider", .gap = "GAP-0820" },
    .{ .capability = "renameProvider", .gap = "GAP-0821" }, // rename/prepareRename
    .{ .capability = "codeActionProvider", .gap = "GAP-0822" }, // codeAction
    .{ .capability = "inlayHintProvider", .gap = "GAP-0823" }, // inlayHint
    // GAP-0824: save lifecycle. textDocumentSync is advertised as a bare integer
    // (Full sync) which cannot carry save/willSave members; these top-level keys
    // are never present either.
    .{ .capability = "willSave", .gap = "GAP-0824" },
    .{ .capability = "willSaveWaitUntil", .gap = "GAP-0824" },
};

// `textDocumentSync` is a sync capability, not a request-handler capability:
// it governs the textDocument/did{Open,Change,Close} NOTIFICATIONS, not a
// request/response method. It maps to notifications, handled separately below.
const text_document_sync_key = "textDocumentSync";
const text_document_sync_notifications = [_][]const u8{
    "textDocument/didOpen",
    "textDocument/didChange",
    "textDocument/didClose",
};

// Request methods that are exempt from the capability mapping: base-protocol
// lifecycle / control methods that every LSP server MUST handle regardless of
// advertised capabilities.
const exempt_request_methods = [_][]const u8{
    "initialize",
    "shutdown",
    // Forward-looking (GAP-0816 adds $/cancelRequest handling): keep the
    // control namespace exempt so the later task does not need to touch this
    // guard. Anything under "$/" is a base-protocol cancellation/progress
    // control, never a ServerCapabilities-advertised feature.
};

// Notification methods are exempt from the request-method capability mapping.
const exempt_notification_methods = [_][]const u8{
    "initialized",
    "exit",
    "textDocument/didOpen",
    "textDocument/didChange",
    "textDocument/didClose",
    // GAP-0816: $/cancelRequest is a base-protocol control notification under
    // the "$/" namespace — never advertised via ServerCapabilities.
    "$/cancelRequest",
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn sliceContains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

fn isExemptRequestMethod(method: []const u8) bool {
    if (std.mem.startsWith(u8, method, "$/")) return true;
    return sliceContains(&exempt_request_methods, method);
}

/// Collect the keys of the capabilities object EXACTLY as advertised by the
/// production `handleInitialize` path. Caller owns the returned list.
fn advertisedCapabilityKeys(allocator: std.mem.Allocator) ![][]const u8 {
    // GAP-0817: the encoding argument only changes the VALUE of the
    // `positionEncoding` key, never the key set, so any encoding works for the
    // structural key-walk; pass the protocol default.
    var caps = try server.buildCapabilitiesObject(allocator, .utf16);
    defer server.deinitCapabilitiesObject(allocator, &caps);

    var keys: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit(allocator);
    }

    var it = caps.iterator();
    while (it.next()) |entry| {
        // dupe so the slice outlives the (about-to-be-freed) ObjectMap.
        try keys.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
    }
    return try keys.toOwnedSlice(allocator);
}

fn freeKeys(allocator: std.mem.Allocator, keys: [][]const u8) void {
    for (keys) |k| allocator.free(k);
    allocator.free(keys);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "GAP-0831: every advertised feature capability has a wired handler" {
    const alloc = testing.allocator;
    const keys = try advertisedCapabilityKeys(alloc);
    defer freeKeys(alloc, keys);

    for (keys) |cap| {
        // GAP-0817: positionEncoding (and any other data-only capability) has
        // no method behind it — skip the handler mapping.
        if (sliceContains(&non_method_capability_keys, cap)) continue;

        // textDocumentSync maps to notifications, checked separately.
        if (std.mem.eql(u8, cap, text_document_sync_key)) {
            for (text_document_sync_notifications) |n| {
                if (!sliceContains(&server.handled_notification_methods, n)) {
                    std.debug.print(
                        "ADVERTISED textDocumentSync but notification '{s}' is NOT handled\n",
                        .{n},
                    );
                    return error.CapabilityWithoutHandler;
                }
            }
            continue;
        }

        // Find the mapping for this advertised capability.
        var mapping: ?CapMethodMapping = null;
        for (cap_method_table) |m| {
            if (std.mem.eql(u8, m.capability, cap)) {
                mapping = m;
                break;
            }
        }
        if (mapping == null) {
            std.debug.print(
                "ADVERTISED capability '{s}' has no entry in the cap↔method table " ++
                    "(unknown capability advertised without a mapped handler)\n",
                .{cap},
            );
            return error.UnmappedAdvertisedCapability;
        }

        for (mapping.?.methods) |method| {
            if (!sliceContains(&server.handled_request_methods, method)) {
                std.debug.print(
                    "ADVERTISED '{s}' but request method '{s}' is NOT wired in handleRequest\n",
                    .{ cap, method },
                );
                return error.CapabilityWithoutHandler;
            }
        }
    }
}

test "GAP-0831: every wired feature request method has an advertised capability" {
    const alloc = testing.allocator;
    const keys = try advertisedCapabilityKeys(alloc);
    defer freeKeys(alloc, keys);

    for (server.handled_request_methods) |method| {
        if (isExemptRequestMethod(method)) continue;

        // Find the capability that maps to this method.
        var advertised = false;
        outer: for (cap_method_table) |m| {
            if (sliceContains(m.methods, method)) {
                // The mapped capability must actually be advertised.
                if (sliceContains(keys, m.capability)) {
                    advertised = true;
                    break :outer;
                }
            }
        }
        if (!advertised) {
            std.debug.print(
                "WIRED request method '{s}' has NO advertised capability " ++
                    "(handler without capability — trim the handler or advertise the capability)\n",
                .{method},
            );
            return error.HandlerWithoutCapability;
        }
    }
}

test "GAP-0831: every wired notification is either lifecycle-exempt or sync-backed" {
    // Notifications are exempt from request-capability mapping, but the did*
    // trio is only legitimate when textDocumentSync is advertised. Assert each
    // wired notification is accounted for (no orphan notification handlers).
    const alloc = testing.allocator;
    const keys = try advertisedCapabilityKeys(alloc);
    defer freeKeys(alloc, keys);

    const sync_advertised = sliceContains(keys, text_document_sync_key);

    for (server.handled_notification_methods) |method| {
        if (!sliceContains(&exempt_notification_methods, method)) {
            std.debug.print("WIRED notification '{s}' is not in the exemption list\n", .{method});
            return error.UnexpectedNotification;
        }
        // did* notifications require textDocumentSync.
        if (sliceContains(&text_document_sync_notifications, method)) {
            try testing.expect(sync_advertised);
        }
    }
}

test "GAP-0831 + honest-non-support: intentionally-unsupported capabilities are NOT advertised" {
    // Inverse-direction guard for the honest non-support contract: each
    // capability Geode deliberately does not implement must be absent from the
    // advertised set. If a future change starts advertising one without wiring
    // the corresponding handler, this trips (and GAP-0831's forward direction
    // would then also flag the missing handler).
    const alloc = testing.allocator;
    const keys = try advertisedCapabilityKeys(alloc);
    defer freeKeys(alloc, keys);

    for (intentionally_unsupported_capabilities) |entry| {
        if (sliceContains(keys, entry.capability)) {
            std.debug.print(
                "{s}: capability '{s}' is INTENTIONALLY UNSUPPORTED but is now advertised " ++
                    "— either implement+wire its handler or keep it unadvertised\n",
                .{ entry.gap, entry.capability },
            );
            return error.IntentionallyUnsupportedCapabilityAdvertised;
        }
    }
}

test "GAP-0831: cap↔method table is itself consistent with the dispatch tables" {
    // Guards the guard: every method named in the in-test mapping table must
    // actually be a wired request method, otherwise the table has rotted and
    // the bidirectional checks above would silently pass on stale data.
    for (cap_method_table) |m| {
        for (m.methods) |method| {
            if (!sliceContains(&server.handled_request_methods, method)) {
                std.debug.print(
                    "cap↔method table references method '{s}' that is NOT wired — table is stale\n",
                    .{method},
                );
                return error.StaleMappingTable;
            }
        }
    }
}

test "GAP-0831: dispatch tables reference the Methods single-source constants" {
    // The handled_*_methods arrays must equal the Methods.* constants used by
    // the dispatch chain (not free-floating string literals). This catches a
    // refactor that adds a handler with a literal but forgets the list.
    const M = server.Methods;
    const expected_requests = [_][]const u8{
        M.initialize,      M.shutdown,
        M.hover,           M.completion,
        M.definition,      M.formatting,
        M.document_symbol, M.signature_help,
        M.references,      M.semantic_tokens_full,
    };
    try testing.expectEqual(expected_requests.len, server.handled_request_methods.len);
    for (expected_requests, 0..) |m, i| {
        try testing.expectEqualStrings(m, server.handled_request_methods[i]);
    }

    const expected_notifications = [_][]const u8{
        M.initialized,    M.exit, M.did_open, M.did_change, M.did_close,
        // GAP-0816: $/cancelRequest cancellation control notification.
        M.cancel_request,
    };
    try testing.expectEqual(expected_notifications.len, server.handled_notification_methods.len);
    for (expected_notifications, 0..) |m, i| {
        try testing.expectEqualStrings(m, server.handled_notification_methods[i]);
    }
}
