# MCP LSP Bridge

**Last updated:** 2026-05-06
**Owner:** mcp / lsp
**Status:** Living document; refer to GAP-0818 for the latent-RLS pre-condition.

This document is the authoritative reference for the four LSP-bridge
tools exposed by the Geode MCP server. It captures public surface,
ownership semantics, threading expectations, and the row-level
security (RLS) pre-condition that operators must understand before
enabling tenant-aware policies.

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
- Pre-condition matches `validateQuery`.
- The returned `CompletionItemJson.insertText` is owned by the caller
  via the surrounding response buffer.

### `pub fn getHover(allocator, query, line, column) ![]const u8`

- Returns a JSON-encoded `HoverResponse` (`{contents}` — `null` when
  the word at `(line, column)` has no metadata entry).
- Pre-condition matches `validateQuery`.

### `pub fn getDiagnostics(allocator, query) ![]const u8`

- Alias for `validateQuery`. Provided so MCP clients that expose
  diagnostics-as-a-separate-concept can call a method whose name
  matches their UI.

## Input chokepoint (LSP-SEC-007 / GAP-0819)

All four entry points run their `query` argument through
`validateAndSanitizeGqlInput` (in `src/mcp/input_guards.zig`) before
any lexer/parser work. This is the single source of truth for input
acceptance:

| Reject reason | Error |
|---|---|
| `query.len > MAX_GQL_TEXT (1 MiB)` | `InputError.QueryTooLarge` |
| `query.len == 0` | `InputError.QueryEmpty` |
| Invalid UTF-8 | `InputError.InvalidUtf8` |
| Embedded NUL byte | `InputError.EmbeddedNul` |
| Nested comments > 64 deep | `InputError.NestedCommentTooDeep` |

On any rejection the entry point returns a
`ValidationResponse`-shaped JSON document with a single
error-severity diagnostic naming the rejection reason. No diagnostic
position is asserted (line/column are 0).

## Ownership and threading

- All four functions are pure with respect to their input. They do not
  mutate global state. They allocate JSON output strings owned by the
  caller's allocator.
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

## Cross-references

- GAP-0818 (latent RLS pre-condition) — closed 2026-05-06 by this
  documentation.
- GAP-0819 (MCP GQL input chokepoint) — closed 2026-05-06 with
  `validateAndSanitizeGqlInput`.
- LSP-SEC-007 (1 MiB query cap) — closed 2026-05-06 with
  `rejectIfOversized`.
- GAP-0510 (RLS expression engine wiring) — closed 2026-04-11; see
  the Known Limitations section of `CLAUDE.md`.
- GitLab tracking issues: `#754` (GAP-0818), `#668` (GAP-0819),
  `#793` (LSP-SEC-007).

CANARY: REQ=REQ-DOC-MCP-LSP-BRIDGE; FEATURE="MCPLSPBridgeDoc"; ASPECT=Documentation; STATUS=EXEMPT; OWNER=mcp; UPDATED=2026-05-06
