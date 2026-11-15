# MCP LSP Bridge

**Last updated:** 2026-06-10
**Owner:** mcp / lsp
**Requirement:** `REQ-MCP-LSP-BRIDGE-001` (bridge contract; CANARY in `src/mcp/lsp.zig`)
**Status:** Living document; refer to GAP-0818 for the latent-RLS pre-condition.

This document is the authoritative reference for the four LSP-bridge
tools exposed by the Geode MCP server. It captures public surface,
ownership semantics, threading expectations, and the row-level
security (RLS) pre-condition that operators must understand before
enabling tenant-aware policies.

The bridge contract is governed by requirement
`REQ-MCP-LSP-BRIDGE-001` (CANARY marker at the top of
`src/mcp/lsp.zig`, STATUS=TESTED) and pinned by the governance test
`tests/test_gap0830_mcp_lsp_bridge.zig` (`zig build test-gap0830`).

## Why this exists

The MCP (Model Context Protocol) server lets AI/LLM tools query the
Geode language server without speaking the LSP wire protocol
directly. It bridges four kinds of read-only language operations:

| MCP tool name | Backing function (`src/mcp/lsp.zig`) | Semantics |
|---|---|---|
| `validate` | `validateQuery` | Lex + parse the query; return diagnostics. |
| `complete` | `getCompletions` | Suggest keywords/functions/types at a cursor. |
| `hover` | `getHover` | Return Markdown documentation for the word at a cursor. |
| `diagnostics` | `getDiagnostics` (alias of `validate`) | Same as `validate`. |

Tool dispatch happens in `src/mcp/tools.zig:callTool` — the MCP server
parses an `args_json` blob, routes by tool name, and forwards to the
typed function in `src/mcp/lsp.zig`.

## Public surface

### `pub fn validateQuery(allocator, query) ![]const u8`

- Returns a JSON-encoded `ValidationResponse` (`{isValid, diagnostics[]}`).
- Caller owns the returned bytes; free with `allocator.free`.
- Pre-condition: `query` must be UTF-8, ≤ 1 MiB, contain no NUL byte,
  and have nested-comment depth ≤ 64. Enforced by
  `validateAndSanitizeGqlInput` (LSP-SEC-007 / GAP-0819).

### `pub fn getCompletions(allocator, query, line, column) ![]const u8`

- Returns a JSON-encoded `CompletionResponse` (`{completions[]}`).
- Pre-condition matches `validateQuery`, except that an empty `query` is
  the start of a statement (an editor's empty buffer): it returns the
  clause keywords (SONNY-6484).
- The returned `CompletionItemJson.insertText` is owned by the caller
  via the surrounding response buffer.

### `pub fn getHover(allocator, query, line, column) ![]const u8`

- Returns a JSON-encoded `HoverResponse`, `{"contents": ...}`. The field
  is always present: `{"contents":null}` when the word at
  `(line, column)` has no metadata entry (SONNY-6484; it used to be `{}`).
- Pre-condition matches `validateQuery`, except that an empty `query`
  returns `{"contents":null}`.

### `pub fn getDiagnostics(allocator, query) ![]const u8`

- Alias for `validateQuery`. Provided so MCP clients that expose
  diagnostics-as-a-separate-concept can call a method whose name
  matches their UI.

## Input chokepoint (LSP-SEC-007 / GAP-0819)

All four entry points run a non-empty `query` argument through
`validateAndSanitizeGqlInput` (in `src/mcp/input_guards.zig`) before
any lexer/parser work (`getCompletions` and `getHover` answer an empty
one without it; `validateQuery` and `getDiagnostics` refuse it). This is the single source of truth for input
acceptance:

| Reject reason | Error |
|---|---|
| `query.len > MAX_GQL_TEXT (1 MiB)` | `InputError.QueryTooLarge` |
| `query.len == 0` (`validateQuery`, `getDiagnostics` only) | `InputError.QueryEmpty` |
| Invalid UTF-8 | `InputError.InvalidUtf8` |
| Embedded NUL byte | `InputError.EmbeddedNul` |
| Nested comments > 64 deep | `InputError.NestedCommentTooDeep` |

On any rejection the entry point returns a
`ValidationResponse`-shaped JSON document with a single
error-severity diagnostic naming the rejection reason. No diagnostic
position is asserted (line/column are 0).

## Transport and dispatch

The bridge is reached over the MCP server's transports (stdio for
local clients such as Claude Desktop; HTTP for networked clients) via
the `tools/call` JSON-RPC method. `src/mcp/server.zig` validates the
bearer token at the transport boundary (default `auth_mode = .bearer`,
SEC-08) and routes `tools/call` to `src/mcp/tools.zig:callTool`, which
dispatches by tool name to the typed function below. The four bridge
tools are **read-only language services**: they never touch the graph
backend and require no QUIC endpoint (unlike the `query`/`schema`/
`explain`/`graphs` tools).

## Auth posture

- The MCP server derives a single per-server `Principal` from the
  bearer token at init (GPS Phase 5, `source = .mcp_handler`). All
  bridge calls run under that principal; there is no per-connection
  multi-user threading yet (deferred to Phase 6+).
- The bridge functions themselves perform **no authorization** beyond
  the GAP-0819 input chokepoint — they are pure parser/metadata
  lookups over the supplied query text and expose no row data. The
  RLS pre-condition below governs when tenant-aware policies may be
  safely attached to MCP-reachable databases.

## Ownership and threading

- All four functions are pure with respect to their input. They do not
  mutate global state. They allocate JSON output strings owned by the
  caller's allocator.
- `getCompletions` internally `dupe`s each completion item's
  label/detail/documentation/insertText, encodes them into the JSON
  response, and frees those per-item slices before returning (the
  caller only frees the single returned JSON buffer). The earlier
  implementation freed only the item array and leaked every duped
  string; that leak was fixed under GAP-0830 and is regression-covered
  by `tests/test_gap0830_mcp_lsp_bridge.zig`.
- The MCP server (`src/mcp/server.zig`) is single-threaded as of
  2026-05-06; tool calls run sequentially under the server's auth
  layer. There is no per-call locking.
- Caller-supplied `query`/`line`/`column` are validated structurally
  by the chokepoint above (length + shape) but are NOT validated
  semantically — a syntactically invalid GQL fragment will still
  reach the parser and produce a `validate` diagnostic with a parser
  error. That is intended: the goal of `validate` is precisely to
  surface those diagnostics.

## RLS pre-condition (GAP-0818, latent)

The bridge is RLS-blind today. See
[`USER_AUTH.md` § "MCP LSP Bridge — RLS Pre-Condition (GAP-0818)"](USER_AUTH.md#mcp-lsp-bridge--rls-pre-condition-gap-0818)
for the three pre-conditions that must be in place before
RLS-on-MCP can be safely enabled:

1. Per-caller principal threading.
2. Token → user mapping.
3. Audit identity.

**Operator action:** until those pre-conditions land in code, do not
attach tenant-aware RLS policies (those that depend on
`current_user()` or `current_tenant()`) to any database that is
reachable through the MCP server.

**Enforcement gate (landed 2026-06-10):** the unverified-principal
half of the pre-condition is now enforced in code on the LSP side —
when auth provides no VERIFIED principal, the LSP serves no
tenant-scoped schema: `Server.callerContext()` collapses an unverified
`AuthState` to the anonymous (null-tenant) context, which the provider
tenant gate (`LspContext.schemaTenantMatches`) never matches against a
tenant-scoped SchemaProvider, and `Server.publishVerifiedState()`
refuses to build tenant-carrying session state for an unverified
principal. Pinned by `zig build test-gap0818-gate`. The bridge tools
themselves remain static (no SchemaProvider, no store) and the MCP
Principal is derived with `tenant_id = null` always. The residual —
verified tenant DERIVATION for authenticated principals (the LSP
tenant is still client-asserted) — keeps the operator action above in
force.

## Verification

- `zig build test-gap0830` — governance test exercising all four
  bridge entry points: `validate`/`diagnostics` (valid + invalid +
  alias equivalence), `complete`, `hover` (known keyword + unknown
  word), and the GAP-0819 input chokepoint (empty / embedded-NUL /
  oversize rejection). Leak-checked under `std.testing.allocator`, so
  it also guards the `getCompletions` ownership fix.

## Cross-references

- GAP-0830 (bridge contract doc + CANARY + governance test) — closed
  2026-06-10 by this documentation, the `REQ-MCP-LSP-BRIDGE-001`
  CANARY in `src/mcp/lsp.zig`, the `getCompletions` leak fix, and
  `tests/test_gap0830_mcp_lsp_bridge.zig`.
- GAP-0818 (latent RLS pre-condition) — closed 2026-05-06 by this
  documentation.
- GAP-0819 (MCP GQL input chokepoint) — closed 2026-05-06 with
  `validateAndSanitizeGqlInput`.
- LSP-SEC-007 (1 MiB query cap) — closed 2026-05-06 with
  `rejectIfOversized`.
- GAP-0510 (RLS expression engine wiring) — closed 2026-04-11; see
  the Known Limitations section of `CLAUDE.md`.
- GitLab tracking issues: `#547` (GAP-0830), `#754` (GAP-0818),
  `#668` (GAP-0819), `#793` (LSP-SEC-007).

CANARY: REQ=REQ-DOC-MCP-LSP-BRIDGE; FEATURE="MCPLSPBridgeDoc"; ASPECT=Documentation; STATUS=EXEMPT; OWNER=mcp; UPDATED=2026-05-06
