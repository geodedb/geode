Geode CLI -> Zig Client Library Migration Plan
==============================================

Goal
----

Move the core client behavior of the `geode` CLI (networking, auth/session handling, request/response flow, formatting hooks) into the Zig client library so the CLI becomes a thin wrapper over shared library APIs.

Milestones
----------

1) Library surface audit
   - Inventory existing `transport/quic.zig` (client), protocol helpers, and any reusable auth/session utilities.
   - Identify gaps the CLI currently fills: HELLO/SCHEMA/PULL exchange, auth credential loading, session persistence, output formatting.
   - Decide the module namespace for new library entrypoints (e.g., `client/cli_adapter.zig` or expanding `transport/quic.zig` exports).

2) Extract request/response pipeline
   - Lift HELLO + RUN_GQL + PULL flow into a reusable function that accepts query text, auth params, timeout, and formatting options.
   - Preserve streaming semantics and polling logic (readLineWithPoll) inside the library.
   - Provide a minimal result object (schema, rows, raw lines) for the CLI to print.

3) Auth/session handling
   - Add helpers to resolve saved sessions and apply `--no-saved-session` behavior.
   - Expose credential injection (user/password/token) independent of CLI flag parsing.

4) TLS / transport defaults
   - Centralize cert/key defaults and `--insecure` handling in the library.
   - Ensure client functions accept overrides but default to the shared certs and QUIC settings.

5) Error and logging contract
   - Normalize error types/messages so the CLI can map them to exit codes without string matching.
   - Provide debug hooks for verbose/CI modes.

6) CLI thin wrapper
   - Refactor `src/cli/main.zig` to call the new library entrypoints, keeping only argument parsing and exit-code mapping in the CLI.
   - Remove duplicated polling/output logic from the CLI.

7) Tests and harness alignment
   - Update client test harness to use the new library entrypoints.
   - Add unit-style tests for the library functions (mock transport or loopback QUIC), and a small end-to-end smoke using the harness.

Risks / Open Questions
----------------------

- How to expose session persistence (filesystem path, env overrides) without pulling filesystem concerns into the transport layer?
- Do we keep formatting (json/table) in the library or just return structured data for the CLI to render?
- Compatibility with existing harness scripts that expect current CLI output shape—need a compatibility shim if output changes.

Notes
-----

This plan defers implementation; it only outlines the migration steps so we can execute later without re-discovery.
