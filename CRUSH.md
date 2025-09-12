CRUSH.md — geode repo quick facts for agents

Build & run

- Build (release-safe): zig build -Drelease-safe
- Debug build: zig build
- Run server: ./zig-out/bin/geoded --data_dir ./data --log_json --result-format json
- Run CLI: ./zig-out/bin/geodec "RETURN 1 AS x ORDER BY x LIMIT 1" --format json

Tests

- All tests: zig build test
- Single test file: zig test src/main.zig
- E2E protocol tests: zig test tests/e2e_protocol.zig
- Note: tests should be deterministic, RSS ≤512 MiB, timeout ≤30s

Lint/format/typecheck

- Zig format: zig fmt .
- Typecheck (build graph): zig build
- C/clang format (if needed): clang-format -i <files> (see .clang-format)

Project conventions

- Language: Zig 0.13.0; Linux x86_64; default JSON output (TXT via --format=txt)
- Imports: prefer std; avoid dynamic net deps; versions pinned if any third-party used
- File organization mirrors modules under src/ (gql/, parser/, planner.zig, exec.zig, protocol.zig, server/, client/)
- Names: lower_snake_case for vars/fns; UpperCamelCase for types; constants SCREAMING_SNAKE when appropriate
- Errors: return error unions; do not log secrets; map diagnostics to ISO GQLSTATUS with codes (US001, IllegalOrderKey, GroupByIllegal, TypeMismatch) and anchors
- Result encoding: JSON by default; include ordered flag and order_keys in bindings when applicable
- Policy: LIMIT/OFFSET requires stable ORDER (US001) unless configured; ORDER BY keys identifiers-only by default (IllegalOrderKey)
- Logging: JSON Lines at INFO; errors at ERROR

Pending Commit Message:
chore(docs): refresh GAP analysis + next steps; add ISO-GQL conformance profile & crosswalk

Cursor/Copilot rules to honor

- .github/copilot-instructions.md defines scope (full DB), protocol frames, diagnostics policy, tests, and required outputs. Follow these when adding features or tests.

Notes for agents

- Use zig fmt before committing; keep functions small and testable.
- Prefer small, incremental changes; add unit + e2e coverage for new behavior.
- Do not introduce runtime network dependencies. Never commit secrets.
