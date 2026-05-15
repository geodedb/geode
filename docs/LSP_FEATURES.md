# Geode LSP Features

This document describes the Geode Language Server Protocol (LSP) implementation,
including schema-aware completion, hover, and diagnostics with per-user
permission filtering.

The plan that produced this document lives at
[`docs/superpowers/plans/2026-05-14-lsp-permission-aware-completion.md`](superpowers/plans/2026-05-14-lsp-permission-aware-completion.md);
see that file for the full task-by-task history and commit log.

## Overview

The Geode LSP server speaks LSP 3.17 over two transports:

- **stdio** (`geode lsp`) — for terminal editors (neovim, helix, VS Code over
  stdio). Used today by all command-line workflows.
- **TCP** (`geode lsp --listen tcp://HOST:PORT` or co-hosted by
  `geode serve --lsp-port=3142`) — for browser clients that reach the LSP
  through `geode-ui`'s `/ws/lsp` WebSocket bridge.

Implemented capabilities:

| Capability                          | Source                                          | Permission-aware? |
|-------------------------------------|-------------------------------------------------|-------------------|
| `textDocument/completion`           | `src/cli/lsp/features.zig:provideCompletion`    | Yes               |
| `textDocument/hover`                | `src/cli/lsp/features.zig:provideHover`         | Yes               |
| `textDocument/publishDiagnostics`   | `src/cli/lsp/features.zig:provideDiagnostics`   | Yes               |
| `textDocument/definition`           | `features.zig:provideDefinition`                | No (uses parser)  |
| `textDocument/references`           | `features.zig:provideReferences`                | No                |
| `textDocument/documentSymbol`       | `features.zig:provideDocumentSymbols`           | No                |
| `textDocument/signatureHelp`        | `features.zig:provideSignatureHelp`             | No                |
| `textDocument/semanticTokens/full`  | `features.zig:provideSemanticTokensFull`        | No                |
| `textDocument/formatting`           | `features.zig:provideFormatting`                | No                |

Not yet wired (see "Follow-on work" below):
`textDocument/codeAction`, `workspace/executeCommand`, `workspace/symbol`,
`textDocument/rename`, `textDocument/rangeFormatting`.

## Architecture

```
+----------------------+        WebSocket          +----------------------+
|  Browser (Monaco)    | <-----------------------> | geode-ui Go backend  |
|  monaco-languageclient|        /ws/lsp           | wsLspHandler          |
+----------------------+                          +----------+-----------+
                                                              | TCP (127.0.0.1:3142)
                                                              v
                                                  +----------------------+
                                                  |   geode serve         |
                                                  |   LSP listener thread |
                                                  |   per-session thread  |
                                                  +----------+-----------+
                                                              | in-process
                                                              v
                                                  +----------------------+
                                                  |  SchemaProvider       |
                                                  |  (TTL cache, mutex)   |
                                                  +----------+-----------+
                                                              | direct call
                                                              v
                                                  +----------------------+
                                                  |  schema_introspection |
                                                  |  + GraphStore + auth  |
                                                  +----------------------+
```

The LSP shares the same in-process `GraphStore`, `Catalog`, and auth modules as
the QUIC query handler, so schema lookups never round-trip through the network.

## Authentication

Every LSP session except `--no-auth` stdio MUST authenticate before any
non-`initialize` request is honored. The handshake is:

1. Client sends `initialize` with
   `params.initializationOptions.geode.authToken`.
2. The Server parses it into an `AuthState` (`src/cli/lsp/auth.zig`).
3. `AuthState.verify(allocator, verifier)` validates the token via the
   `Verifier` vtable plugged in at `Server.initWithAuth(...)`. With `null`
   verifier (the current default in `geode serve`'s embedded listener),
   any non-empty token returns `InvalidToken` — fail-closed.
4. On success the Server caches a per-session `AuthState`, builds a
   `SchemaProvider` and `ExecutionContext`, and opens the request gate.
5. Until the gate opens, every non-init request gets JSON-RPC error `-32002`
   (`ServerNotInitialized`).

### `--no-auth` mode

`geode lsp --no-auth` (stdio only) synthesizes a local-admin AuthState from
`$USER` (fallback `"local"`) without invoking a verifier. The flag is
incompatible with `--listen` and the embedded TCP listener inside
`geode serve` forces `allow_unauth=false` regardless of CLI flags. This means
the TCP path **always** requires real authentication; only stdio LSP from a
terminal editor can run without it.

## Schema-aware completion

`completion_context.analyze(text, pos)` inspects the cursor's left context and
returns a `Kind` tag. `provideCompletion` then branches:

| Cursor position    | `Kind`       | Suggestions                                        |
|--------------------|--------------|----------------------------------------------------|
| `MATCH (n:` or `:` | `label`      | Node labels the user can see (from SchemaProvider) |
| `[r:` or `]-[r:`   | `edge_type`  | Edge types the user can see                        |
| `<var>.`           | `property`   | Properties of `<var>`'s resolved label             |
| `$`                | `parameter`  | Static parameter suggestion list                   |
| Default            | `keyword`    | Static keywords/functions/types/procedures         |

Every branch honors `ctx.prefix` so partial typed prefixes
(e.g. `MATCH (n:Per`) narrow the result set. The static fallback uses a
case-insensitive `startsWithCI` filter.

Schema-derived items borrow string slices from the SchemaProvider's TTL cache
(no per-completion dup); the LSP serializer copies them before any expiry
could race.

## Schema-aware hover

`provideHover` checks the hovered identifier against the SchemaProvider:

- **Label hover** (e.g. cursor on `Person` in `(n:Person)`) renders a
  Markdown panel: label name plus the property list observed on nodes
  carrying that label, filtered by tenant.
- **Edge-type hover** (cursor on `KNOWS` in `[r:KNOWS]`) renders a brief
  usage hint with the canonical pattern `()-[r:KNOWS]->()`.
- **Property hover** (cursor on `age` in `n.age`) resolves the variable's
  label via `resolveVarLabel` and shows the owning label.
- Other words fall through to the existing keyword/function/type/procedure
  metadata paths.

## Schema-aware diagnostics

`provideDiagnostics` runs after the parser and tokenizer diagnostics, with a
two-pass label/edge-type scan that emits `Warning` diagnostics for any
reference the schema doesn't know about. A Levenshtein-bounded
("did you mean `Person`?") hint is included when the closest known label
is within edit distance 2.

The diagnostic is identified by `source: "geode-lsp"` (distinct from
`"geode"` used by parser-level errors) so clients can attribute the warning
separately.

## TTL cache and DDL invalidation

`SchemaProvider` (`src/cli/lsp/schema_provider.zig`) sits between the LSP
features and the in-process schema introspection layer. It:

- Caches `getLabels()`, `getEdgeTypes()`, and `getPropertiesFor(label)` for
  `DEFAULT_TTL_NS = 5s` (configurable via `provider.ttl_ns`).
- Holds a `std.Io.Mutex` so concurrent semantic-tokens + completion requests
  on the same session are safe.
- Registers an invalidation callback with `schema_change_notifier` so that
  any successful `CREATE GRAPH`, `DROP GRAPH`, `GRANT … ON GRAPH …`, or
  `REVOKE …` fires `notify()` and drops the cache.

Without a notifier the TTL alone bounds staleness to ≤5 seconds.

## Limitations

- **Embedded LSP fails closed.** The TCP listener inside `geode serve` is wired
  with `verifier=null` until the AuthProvider→Verifier adapter lands. Until
  then no client can complete an authenticated initialize over TCP. The
  AuthProvider→Verifier adapter is blocked by a pre-existing Zig 0.16
  migration issue in `src/security/authn.zig` (`std.crypto.random.bytes` was
  retired). The stdio path with `--no-auth` works for local development; the
  WS bridge from geode-ui is wired and accepts connections but will be
  rejected at the LSP `initialize` step until the adapter is in place.
- **Property catalog is a live scan.** `listPropertiesForLabel` walks every
  node carrying the requested label in the requested tenant on every call
  (cached for the TTL window). This is O(n) in matching nodes; a persistent
  incremental property catalog is follow-on work (Plan E in the original
  plan).
- **Hot-path DDL is not in the notifier set.** Per-row writes that introduce
  a new label or edge type via `CREATE`/`MERGE` do not fire
  `schema_change_notifier.notify()` — the TTL handles freshness within the
  5-second window. The notifier covers structural DDL only (CREATE/DROP
  GRAPH, GRANT/REVOKE).
- **Auth verifier is a vtable.** `AuthState.verify` takes a `?Verifier`
  rather than depending directly on `src/security/authn.zig`. This decouples
  the LSP from the live AuthProvider so that the LSP's own tests can pass
  without the authn migration. The adapter from `*authn.AuthProvider` to
  `Verifier` is a single small function that takes a token and tries
  `.bearer_token` then `.session_token` against the provider — the same
  precedence the QUIC handler uses.

## Follow-on work (out of scope for this plan)

- **Plan B**: `textDocument/codeAction` quick fixes (auto-rename to closest
  label, add `LIMIT`, wrap `CREATE` as `MERGE`, etc.).
- **Plan C**: `workspace/executeCommand` for `geode.explainQuery`,
  `geode.profileQuery`, `geode.refreshSchema`.
- **Plan D**: `workspace/symbol` cross-document search and
  `textDocument/rename` for variables-in-scope.
- **Plan E**: Persistent incremental property catalog (replace
  `listPropertiesForLabel`'s live scan with O(1) lookups on writes).
- **Plan F**: UI affordances in `geode-ui` — schema browser panel that
  mirrors LSP data, "Run with EXPLAIN" button, format-on-save, settings
  page for completion sources.
- **Auth adapter**: migrate `src/security/authn.zig` to Zig 0.16
  (`std.crypto.random.bytes` → `std.crypto.random.bytesUncancelable` or
  the new `std.Random` API), then write the `AuthProvider → Verifier`
  adapter and pass it into the embedded LSP listener.

## Build & test reference

```bash
# Build the geode binary (includes embedded LSP listener).
zig build

# Run only the LSP-touching unit suites (fast).
zig build test-schema-provider      # 5 tests
zig build test-completion-context   # 7 tests
zig build test-auth                 # 6 tests
zig build test-tcp-transport        # 1 test
zig build test-lsp-embedded-e2e     # 1 test

# Run the standalone LSP TCP listener (no auth — terminal editor mode).
./zig-out/bin/geode lsp --no-auth

# Run a network-listening LSP (auth required; TODO above).
./zig-out/bin/geode lsp --listen=tcp://127.0.0.1:3142

# Run the embedded LSP listener alongside QUIC.
./zig-out/bin/geode serve --listen 0.0.0.0:3141 --lsp-port=3142
# (--lsp-port=0 disables; --lsp-bind-all opens 0.0.0.0 instead of loopback.)
```

geode-ui side (browser/Monaco client):

```bash
cd ../geode-ui
npm test                     # full Jest suite (includes LSP client tests)
go test ./internal/server/   # Go bridge tests (incl. /ws/lsp)
```
