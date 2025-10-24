# Development & Contributing

- Repo layout: src/ (engine/storage/gql/security/etc.), clients/, docs/, tests/, benchmarks/, scripts/
- Toolchain: Zig 0.15.1; Go for clients; Nix flake optional; submodules (QUIC) must be initialized
- Standards: zig fmt; no compile-time feature flags; evidence-driven CANARY annotations
- Tests: `zig build test`; dataset & cluster tests via scripts; fuzz and benches available
- CI Governance: canaryscan generates status.json/status.csv; strict freshness and coverage rules
- Workflow: fork → branch → tests/docs → PR; update CANARY and regenerate status.csv; reference issues
- Versioning: 0.x; see CHANGELOG/MIGRATION; unified CLI with legacy tools deprecated but available
