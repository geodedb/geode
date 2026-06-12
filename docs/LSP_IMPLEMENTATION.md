# Geode Language Server Protocol (LSP) Implementation

## Overview

A full Language Server Protocol implementation for GQL/Geode has been created to provide IDE support for `.gql` files. The LSP server provides real-time syntax checking, code completion, hover documentation, and more.

## Status (2026-06-10)

This page is the authoritative description of the LSP server's *shipped* surface.
The single source of truth in code is `src/cli/lsp/server.zig`: the comptime
`request_dispatch` / `notification_dispatch` tables and `buildCapabilitiesObject`.
A comptime truthfulness guard (GAP-0831) makes it impossible to advertise a
capability without a wired handler, or to wire a feature request without
advertising it — see [Capability truthfulness guard](#capability-truthfulness-guard).

### Implemented request handlers

Every row below corresponds to one entry in `request_dispatch` (`src/cli/lsp/server.zig`)
and an advertised capability built by `buildCapabilitiesObject`. The "pinned by"
column names the gap regression test (`zig build <step>`) that pins the behavior.

| Method | Advertised capability | Pinned by |
|---|---|---|
| `initialize` | (lifecycle) | `test-gap0827` (lifecycle/JSON-RPC error shape), `test-gap0817` (position-encoding negotiation in result) |
| `shutdown` | (lifecycle) | `test-gap0827` |
| `textDocument/hover` | `hoverProvider: true` | `test-gap0818` (tenant gate), `test-gap0831` (truthfulness) |
| `textDocument/completion` | `completionProvider` (`triggerCharacters: [".", ":", "$"]`) | `test-gap0818`, `test-gap0831` |
| `textDocument/definition` | `definitionProvider: true` | `test-gap0818`, `test-gap0831` |
| `textDocument/formatting` | `documentFormattingProvider: true` | `test-gap0831` |
| `textDocument/documentSymbol` | `documentSymbolProvider: true` | `test-gap0831` |
| `textDocument/signatureHelp` | `signatureHelpProvider` (`triggerCharacters: ["(", ","]`) | `test-gap0831` |
| `textDocument/references` | `referencesProvider: true` | `test-gap0831` |
| `textDocument/semanticTokens/full` | `semanticTokensProvider` (`full: true` + legend) | `test-gap0831` |

### Implemented notification handlers

Every row corresponds to one entry in `notification_dispatch`. Notifications never
produce a response of their own.

| Method | Backed by | Pinned by |
|---|---|---|
| `initialized` | lifecycle flag | `test-gap0827` |
| `exit` | lifecycle flag (clean exit) | `test-gap0827` |
| `textDocument/didOpen` | `textDocumentSync: 1` (Full sync) | `test-gap0827`, `test-gap0828` |
| `textDocument/didChange` | `textDocumentSync: 1` | `test-gap0827`, `test-gap0826` (250-version churn) |
| `textDocument/didClose` | `textDocumentSync: 1` | `test-gap0827`, `test-gap0828` |
| `$/cancelRequest` | base protocol (`$/` namespace, capability-exempt) | `test-gap0816` |

### Diagnostics

Diagnostics are published via `textDocument/publishDiagnostics` on `didOpen` /
`didChange` (debounced). They are sourced from Geode's GQL parser (`parseGql`) and
are gated on caller tenant identity (GAP-0818) so a multi-byte / multi-tenant
client never sees another tenant's label in a diagnostic hint. Outbound positions
are converted to the negotiated encoding (GAP-0817). Pinned by `test-gap0818`
(tenant gate) and `test-gap0821` (multi-label MATCH diagnostic).

### Protocol correctness (shipped)

- **`$/cancelRequest` (GAP-0816).** Geode processes messages strictly
  synchronously, so a cancel can never race an in-flight handler in-process. The
  spec-compliant realization is a bounded FIFO registry (`CancelRegistry`, 64
  slots): `$/cancelRequest` records the id; `handleRequest` consults it at entry
  and short-circuits with JSON-RPC **-32800 (RequestCancelled)**, consuming the
  entry so a later legitimate id reuse is unaffected. An `AnsweredRing`
  anti-poisoning guard prevents a cancel that arrives after a request was already
  answered from poisoning a future request that reuses the same id. Pinned by
  `test-gap0816`.
- **Position encoding negotiation (GAP-0817).** `initialize` negotiates the
  encoding from `capabilities.general.positionEncodings` (LSP 3.17): prefer
  `utf-8` (cheapest for Geode's UTF-8 byte-slice internals), else the protocol
  default `utf-16`, with `utf-32` honored only when it is the first recognized
  non-`utf-8` offer. The choice is stored per session and advertised back as
  `capabilities.positionEncoding`. Every inbound `Position.character` is converted
  from the negotiated encoding's code units to a UTF-8 byte column
  (`codeUnitsToByteColumn`); every outbound position is converted back
  (`byteColumnToCodeUnits`). Both converters are fail-safe on malformed UTF-8 and
  clamp past-end columns. Pinned by `test-gap0817`.
- **Validated envelope decode (GAP-0832 / GAP-0827).** A malformed JSON-RPC
  envelope yields **-32600 (Invalid Request)**. A root that is not an object, a
  non-string `method`, or a present-but-structured `id` (object/array — not a
  valid JSON-RPC id) is rejected with -32600 and `"id": null` rather than being
  silently dispatched as a notification. Pinned by `test-gap0832`, `test-gap0827`.
- **Lifecycle gates (GAP-0827).** A request other than `initialize` received
  before `initialize` is answered **-32002 (ServerNotInitialized)**; a second
  `initialize` is **-32600**; any request after `shutdown` is **-32600**. `exit`
  still flips the clean-exit flag post-`shutdown`. Pinned by `test-gap0827`.
- **Content-Length framing (GAP-0825).** The framer accepts case-insensitive
  `Content-Length` headers and tolerates extra/`Content-Type` headers per the
  base protocol. Pinned by `test-gap0825`.

### Authentication / caller-identity posture (GAP-0818)

Caller identity is threaded through completion, hover, definition, and diagnostics
as an `LspContext` (`src/cli/lsp/context.zig`: `tenant_id`, `user_id`,
`session_id`, all nullable). On the stdio path the context is the unauthenticated
single-tenant `LspContext.stdio` (no tenant, no user, no session); on the
embedded-TCP path the server binds a **derived session handle** at `initialize`
(it never reuses the raw client token) and constructs the per-session context from
the verified `AuthState`. Tenant-scoped schema data is only consulted when the
caller's tenant matches the provider's tenant (`schemaTenantMatches`), so a
mis-wired or reused provider degrades to the static, tenant-independent language
metadata instead of leaking another tenant's labels/properties. Pinned by
`test-gap0818`.

> **Honest residual (GAP-0818 / GAP-0848):** on the embedded-TCP path the
> session `AuthState.tenant_id` is currently **client-asserted** (taken from the
> HELLO frame), not yet independently re-derived server-side from the
> authenticated principal. The auth-layer refactor that makes the tenant
> server-authoritative is tracked separately and is out of scope for the LSP
> providers themselves; the providers correctly *enforce* whatever tenant the
> session carries. Single-tenant stdio is unaffected (no tenant, no assertion).

### Explicit non-support (capability-trimmed, tested)

These methods are **deliberately not implemented** and **not advertised**. The
contract is honest non-support: an unadvertised feature **request** is answered
with **-32601 (MethodNotFound)** echoing the request id (so the client fails fast
instead of blocking on a read timeout), and an unadvertised **notification** is
silently tolerated (no response, no crash) per JSON-RPC 2.0 §5. All pinned by
`test-gap0820-0824`, with the inverse-direction "no handler" assertion in
`test-gap0831`.

| Method(s) | Kind | Gap |
|---|---|---|
| `workspace/symbol`, `workspace/configuration`, `workspace/applyEdit`, `workspace/executeCommand` | request → -32601 | GAP-0820 |
| `workspace/didChangeWorkspaceFolders` | notification → tolerated | GAP-0820 |
| `textDocument/rename`, `textDocument/prepareRename` | request → -32601 (`renameProvider` absent) | GAP-0821 |
| `textDocument/codeAction` | request → -32601 (`codeActionProvider` absent) | GAP-0822 |
| `textDocument/inlayHint` | request → -32601 (`inlayHintProvider` absent) | GAP-0823 |
| `textDocument/willSaveWaitUntil` | request → -32601 | GAP-0824 |
| `textDocument/willSave`, `textDocument/didSave` | notification → tolerated | GAP-0824 |

`textDocumentSync` is advertised as the bare integer `1` (Full sync) with **no**
`save` / `willSave` / `willSaveWaitUntil` members — the capability shape itself is
honest about the lack of save support.

### Capability truthfulness guard

The dispatch tables (`request_dispatch` / `notification_dispatch`) are the single
source of truth: `handleRequest` / `handleNotification` run an `inline for` over
them, and the introspected `handled_request_methods` / `handled_notification_methods`
lists are **derived at comptime from those same tables**. `buildCapabilitiesObject`
is the single place that decides what is advertised, and both `handleInitialize`
and the guard test call it. `tests/test_gap0831_lsp_capability_guard.zig`
(`zig build test-gap0831`) asserts bidirectionally: (a) every advertised feature
capability has a wired handler, and (b) every wired feature request method has an
advertised capability. Deleting a dispatch row simultaneously removes the dispatch
branch and shrinks the introspected list, so the guard trips
(`CapabilityWithoutHandler`) — closing the branch-removal blind spot that produced
the GAP-0056 advertised-but-stub regression. `positionEncoding` is treated as a
data-only (non-method) capability and is exempt.

### Conformance & stress coverage

| Suite | Step | What it drives |
|---|---|---|
| LSP 3.17 / JSON-RPC 2.0 conformance | `test-gap0827` | Lifecycle gates, error-object shape, unknown-method/notification handling, structured-id rejection |
| Content-Length framing | `test-gap0825` | Case-insensitive header, tolerated extra headers, framing edge cases |
| Performance / stress pack | `test-gap0826` | >=1 MiB single-`didOpen`, 600 sequential mixed requests, 150-request burst + cancel storm, 1000-label schema completion bound-check, 250-version `didChange` storm — all leak-checked, CI-safe (no wall-clock assertions) |
| DocumentStore reopen/deinit | `test-gap0828` | Reopen-without-close, 256 churn cycles, 64-URI reopen — leak-checked |
| Honest non-support contract | `test-gap0820-0824` | -32601 for unadvertised requests, tolerance for unadvertised notifications |
| Caller-identity / tenant gate | `test-gap0818` | Cross-tenant leak regression on completion/hover/definition/diagnostics |
| Capability truthfulness guard | `test-gap0831` | Bidirectional capability↔handler guard |
| Validated decode | `test-gap0832` | Malformed-envelope -32600 handling |
| Cancel semantics | `test-gap0816` | -32800 RequestCancelled, FIFO registry, AnsweredRing anti-poisoning |
| Position encoding | `test-gap0817` | utf-8/utf-16/utf-32 negotiation + inbound/outbound multi-byte conversion |
| Full LSP unit + e2e + auth-gate | `test-lsp` | The complete LSP test runner |

### Build & cross-platform

- Builds into the unified `zig-out/bin/geode` binary; launch with `geode lsp`.
- Cross-platform stdio handling (`getStdinHandle`) and Zig 0.16 stdlib APIs — see
  [API Compatibility Notes](#api-compatibility-notes).

## Architecture

### Directory Structure

```
src/cli/lsp/
├── protocol.zig          # LSP protocol types and JSON-RPC structures
├── transport.zig         # transport abstraction (stdio + capturing Noop for tests)
├── framer.zig            # Content-Length framing (case-insensitive header — GAP-0825)
├── document.zig          # Document state + position-encoding conversion (GAP-0817)
├── context.zig           # LspContext caller identity (tenant/user/session — GAP-0818)
├── features.zig          # Language features (hover, completion, definition, diagnostics)
├── completion_context.zig# cursor-position analyzer for completion
├── schema_provider.zig   # lazy, tenant-scoped schema lookup for completion/hover
├── semantic.zig          # semantic-tokens token classification
├── auth.zig              # per-session auth/verify hooks
├── json_helpers.zig      # JSON envelope decode/encode helpers
└── server.zig            # Main LSP server: dispatch tables + capabilities + lifecycle
```

### Key Components

#### 1. Protocol (protocol.zig)

- JSON-RPC 2.0 message types (Request, Response, Notification)
- LSP data structures (Position, Range, Location, Diagnostic, etc.)
- Completion and hover types
- Error codes and response errors

#### 2. Transport (transport.zig)

- Reads/writes messages with Content-Length headers
- Stdin/stdout communication
- Message framing per LSP specification
- Error logging to stderr

#### 3. Document Management (document.zig)

- `Document`: Represents open .gql files
- `DocumentStore`: Manages all open documents
- Helper methods for line/column to offset conversion
- Word-at-position extraction for features

#### 4. Language Features (features.zig)

**Diagnostics:**

- Uses Geode's GQL parser to detect syntax errors
- Reports errors with line/column positions
- Integrates with `parseGql()` from the main library

**Hover:**

- Documentation for 40+ GQL keywords (MATCH, CREATE, RETURN, etc.)
- Documentation for 50+ GQL functions (count, sum, distance, similarity, etc.)
- Documentation for 15+ GQL types (INTEGER, VECTOR, UUID, DATETIME, etc.)
- Returns formatted markdown documentation

**Completion:**

- Auto-complete for all GQL keywords
- Function suggestions with `()` insertion
- Type suggestions
- Triggered by typing or specific characters (`.`, `:`, `$`)

#### 5. Main Server (server.zig)

- Manages LSP lifecycle
- Routes requests to appropriate handlers
- Manages client/server capabilities negotiation
- Handles all LSP messages (requests and notifications)

## Usage

### Starting the LSP Server

```bash
geode lsp
```

The server communicates via JSON-RPC 2.0 over stdin/stdout.

### Editor Integration

#### Visual Studio Code

Add to your `settings.json` or create a VS Code extension:

```json
{
  "gql.server.path": "/path/to/geode",
  "gql.server.args": ["lsp"]
}
```

#### Neovim (with nvim-lspconfig)

```lua
require'lspconfig'.geode.setup{
  cmd = {"/path/to/geode", "lsp"},
  filetypes = {"gql"},
  root_dir = function(fname)
    return vim.fn.getcwd()
  end,
}
```

#### Vim (with vim-lsp)

```vim
if executable('geode')
  au User lsp_setup call lsp#register_server({
    \ 'name': 'geode-lsp',
    \ 'cmd': {server_info->['geode', 'lsp']},
    \ 'allowlist': ['gql'],
    \ })
endif
```

#### Emacs (with lsp-mode)

```elisp
(add-to-list 'lsp-language-id-configuration '(gql-mode . "gql"))
(lsp-register-client
 (make-lsp-client :new-connection (lsp-stdio-connection '("geode" "lsp"))
                  :major-modes '(gql-mode)
                  :server-id 'geode-lsp))
```

## Language Features Reference

### Supported GQL Keywords (40+)

MATCH, CREATE, DELETE, MERGE, SET, REMOVE, RETURN, WHERE, ORDER BY, LIMIT, OFFSET, SKIP, WITH, UNWIND, CALL, YIELD, UNION, OPTIONAL, AS, DISTINCT, AND, OR, NOT, XOR, IN, IS, NULL, TRUE, FALSE, CASE, WHEN, THEN, ELSE, END, ASC, DESC, GROUP BY, HAVING, INTERSECT, EXCEPT, INSERT, UPDATE, DROP, USE, GRAPH, CATALOG, SCHEMA, TABLE, VIEW, INDEX, CONSTRAINT, EXISTS, IF NOT, SHOW, DESCRIBE, EXPLAIN

### Supported GQL Functions (50+)

**Aggregation:** count, sum, avg, min, max, collect
**List:** size, length, head, last, tail, reverse, range
**String:** split, substring, replace, toLower, toUpper, trim, lTrim, rTrim, left, right, startsWith, endsWith, contains
**Math:** abs, ceil, floor, round, sqrt, rand, sign, exp, log, log10, sin, cos, tan, asin, acos, atan, atan2, pi, e, degrees, radians
**Type Conversion:** toInteger, toFloat, toString, toBoolean
**Vector:** distance, similarity, cosine, euclidean, manhattan
**Graph:** type, id, labels, properties, keys, nodes, relationships
**Temporal:** timestamp, date, time, datetime, duration
**Misc:** coalesce, nullIf

### Supported GQL Types (15+)

INTEGER, FLOAT, STRING, BOOLEAN, DATE, TIME, DATETIME, DURATION, POINT, VECTOR, UUID, BYTES, JSON, LIST, MAP, NODE, RELATIONSHIP, PATH, GRAPH, ANY

## Implementation Details

### Parser Integration

The LSP server uses Geode's existing GQL parser (`parseGql` from `src/lib.zig`) to:

- Detect syntax errors in real-time
- Generate accurate diagnostics with line/column information
- Leverage the ISO/IEC 39075:2024-aligned parser (96/96 named conformance-suite cases; parse-only scope)

### Performance

- Full-document `didChange` replacement (incremental sync is not advertised)
- Efficient document storage with hash-map lookups
- Minimal memory overhead for document state
- Parser runs on-demand for diagnostics, debounced on rapid `didChange`
- LSP response trees are recursively freed after send (`sendOwnedJsonValue`); the
  whole feature path is leak-checked by `test-gap0826`

### Protocol Compliance

- Implements the LSP 3.17 specification (conformance pinned by `test-gap0827`)
- JSON-RPC 2.0 transport with Content-Length framing (`test-gap0825`)
- Full text synchronization (`textDocumentSync: 1`) — incremental sync is not advertised
- Position-encoding negotiation: utf-8 / utf-16 / utf-32 (`test-gap0817`)
- Proper capability negotiation during initialization, kept truthful by the GAP-0831 comptime guard

## Testing

### Manual Testing

1. Start the LSP server:

   ```bash
   geode lsp
   ```

2. Send an initialize request (JSON-RPC):

   ```json
   Content-Length: 250\r\n\r\n
   {
     "jsonrpc": "2.0",
     "id": 1,
     "method": "initialize",
     "params": {
       "processId": null,
       "rootUri": "file:///path/to/workspace",
       "capabilities": {}
     }
   }
   ```

3. The server should respond with its capabilities.

### Integration Testing

Create a sample `.gql` file and use it with an LSP-enabled editor to test:

- Syntax error highlighting
- Hover documentation
- Code completion
- Go-to-definition

## Example .gql File for Testing

```gql
// Sample GQL query for testing LSP features
MATCH (p:Person)-[:KNOWS]->(f:Person)
WHERE p.age > 25
RETURN p.name, f.name, distance(p.embedding, f.embedding, 'L2') AS similarity
ORDER BY similarity ASC
LIMIT 10
```

## Shipped vs. deliberately unsupported

The items historically listed here as "future enhancements" have largely shipped.
This section records their *current* state honestly.

### Shipped

- ✅ Document formatting (`textDocument/formatting`)
- ✅ Go-to-definition for variables (`textDocument/definition`)
- ✅ Semantic highlighting (`textDocument/semanticTokens/full`)
- ✅ Symbol outline (`textDocument/documentSymbol`)
- ✅ Find references (`textDocument/references`)
- ✅ Signature help for functions (`textDocument/signatureHelp`)
- ✅ Integration / conformance / stress tests (see [Conformance & stress coverage](#conformance--stress-coverage))

### Deliberately unsupported (honest non-support, tested)

These are **intentionally not implemented** and **not advertised** — see
[Explicit non-support](#explicit-non-support-capability-trimmed-tested). A request
for any of them is answered with **-32601**; an unsupported notification is
tolerated.

- ✗ Rename refactoring (`textDocument/rename` / `prepareRename`) — GAP-0821
- ✗ Code actions / quick fixes (`textDocument/codeAction`) — GAP-0822
- ✗ Inlay hints (`textDocument/inlayHint`) — GAP-0823
- ✗ Save lifecycle (`willSave` / `willSaveWaitUntil` / `didSave`) — GAP-0824
- ✗ Workspace family (`workspace/*`) — GAP-0820
- ✗ Call hierarchy / type hierarchy — not implemented, not advertised

### Known residual

- The tenant carried on the embedded-TCP session is currently client-asserted —
  see the [GAP-0818 honest residual](#authentication--caller-identity-posture-gap-0818).

## API Compatibility Notes

**Zig 0.15.1 API Issues Resolved:**

All Zig 0.15 compatibility issues were successfully fixed:

1. **Stdio Handling** - Used cross-platform pattern from main.zig:

   ```zig
   fn getStdinHandle() std.fs.File.Handle {
       if (builtin.os.tag == .windows) {
           return windows.GetStdHandle(windows.STD_INPUT_HANDLE) catch unreachable;
       } else {
           return std.posix.STDIN_FILENO;
       }
   }

   .stdin = std.fs.File{ .handle = getStdinHandle() }
   ```

2. **ArrayList Initialization** - Changed to `initCapacity()`:

   ```zig
   // Before: std.ArrayList(T).init(allocator)
   // After:
   var items = std.ArrayList(T).initCapacity(allocator, capacity) catch return error.OutOfMemory;
   ```

3. **ArrayList.append()** - Added allocator parameter:

   ```zig
   // Before: try items.append(item)
   // After:
   try items.append(allocator, item)
   ```

4. **ArrayList.toOwnedSlice()** - Added allocator parameter:

   ```zig
   // Before: items.toOwnedSlice()
   // After:
   items.toOwnedSlice(allocator)
   ```

5. **ArrayList.deinit()** - Added allocator parameter:

   ```zig
   // Before: items.deinit()
   // After:
   items.deinit(allocator)
   ```

6. **JSON Serialization** - Changed to `Stringify.valueAlloc()`:

   ```zig
   // Before: std.json.stringifyAlloc(allocator, value, .{})
   // After:
   const json_str = try std.json.Stringify.valueAlloc(allocator, value, .{});
   ```

7. **Compile-time Maps** - Changed to `StaticStringMap().initComptime()`:

   ```zig
   // Before: std.ComptimeStringMap(T, entries)
   // After:
   const docs = std.StaticStringMap([]const u8).initComptime(entries);
   ```

8. **ParseResult.last_error** - Fixed type understanding:

   ```zig
   // last_error is ?[]const u8 (optional string), not a struct
   if (result.last_error) |last_err| {
       // last_err is a string, not an object with .token
       const diag = protocol.Diagnostic{ .message = try allocator.dupe(u8, last_err), ... };
   }
   ```

9. **parseGql() Parameter Order** - Fixed call signature:

   ```zig
   // Before: parseGql(allocator, doc.text)
   // After:
   var result = parseGql(doc.text, allocator) catch |err| { ... };
   ```

10. **Mutable ParseResult** - Changed from const to var for deinit():

    ```zig
    // Before: const result = parseGql(...)
    // After:
    var result = parseGql(...)  // Needed for result.deinit()
    ```

## Documentation

### Help Text

```
geode lsp - Language Server Protocol server for GQL/Geode

Usage: geode lsp [options]

Description:
  Starts a Language Server Protocol (LSP) server for GQL files.
  The server communicates via JSON-RPC over stdin/stdout and provides:
    - Syntax error diagnostics
    - Hover documentation for GQL keywords, functions, and types
    - Code completion for GQL syntax
    - Go-to-definition support
    - Document formatting

Options:
  -h, --help         Show this help message

Examples:
  geode lsp
```

## CANARY Markers

All LSP implementation files include appropriate CANARY markers:

- `REQ-LSP-001` - LSP server subcommand implementation
- `LSP_PROTOCOL_IMPLEMENTATION` - Protocol structures
- `LSP_TRANSPORT_IMPLEMENTATION` - Transport layer
- `LSP_DOCUMENT_MANAGEMENT` - Document management
- `LSP_LANGUAGE_FEATURES` - Language features
- `LSP_SERVER_IMPLEMENTATION` - Main server

## References

- LSP Specification: `specs/lsp/language-server-protocol/_specifications/lsp/3.17/specification.md`
- Base Protocol: `specs/lsp/language-server-protocol/_specifications/base/0.9/specification.md`
- GQL Parser: `src/gql/parser.zig`
- Geode Library API: `src/lib.zig`

## Editor Extensions & Plugins

Complete editor integration packages are available in the repository:

### Claude Code Plugin

Located in `claude-code-lsp-plugin/`:

```bash
# Install plugin
claude /plugin install /path/to/claude-code-lsp-plugin

# Or install from marketplace (when published)
claude /plugin install geode-lsp@claude-code-lsps
```

Features:

- Automatic LSP integration for Claude Code
- File extension mapping for .gql, .gcypher, .cypher, .pgql
- Auto-installation hooks

### VS Code Extension

Located in `editors/vscode/`:

```bash
cd editors/vscode
npm install
npm run compile
npx vsce package
# Then install the .vsix file in VS Code
```

Features:

- Full syntax highlighting with TextMate grammar
- LSP integration via vscode-languageclient
- Configurable settings for LSP path and args

### Neovim Configuration

Located in `editors/neovim/`:

- `gql.lua` - Full nvim-lspconfig setup with key mappings
- `gql.vim` - Vim-style syntax highlighting

See `editors/README.md` for complete setup instructions.

---

*Implementation Date: October 28, 2025*
*Last reconciled against `src/cli/lsp/server.zig`: 2026-06-10 (GAP-0829 — post-Pass-3 LSP work).*
*Source of truth: `request_dispatch` / `notification_dispatch` tables + `buildCapabilitiesObject`; the GAP-0831 comptime guard keeps this doc honest.*
*Build: unified `zig-out/bin/geode` binary.*
*Launch: `./zig-out/bin/geode lsp`*
