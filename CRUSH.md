CRUSH.md — geode (ISO/IEC 39075 GQL graph database) quick reference

BUILD & TEST
  make build                    # Build all (Zig + Go components)
  zig build -Doptimize=ReleaseSafe  # Release build
  zig build test                # Run all tests
  zig test tests/e2e_protocol.zig   # Single test file
  zig fmt .                     # Format all Zig code
  make canary-verify            # Verify feature claims match code

RUN
  ./zig-out/bin/geoded --listen-quic 0.0.0.0:7567  # Server (QUIC/TLS)
  ./zig-out/bin/geodec "RETURN 1 AS x" --server 127.0.0.1:7567  # Client

CODE STYLE (Zig 0.15.1)
  Naming: lower_snake_case (vars/fns), UpperCamelCase (types), SCREAMING_SNAKE (consts)
  Imports: prefer std lib; no dynamic net deps; pin versions if third-party
  Errors: return error unions; map to ISO GQLSTATUS codes (US001, IllegalOrderKey, etc)
  Files: src/{gql/, parser/, planner.zig, exec.zig, protocol.zig, server/, client/}
  Format: always run `zig fmt` before commit; functions small & testable
  Tests: deterministic, RSS ≤512MiB, timeout ≤30s; add unit+e2e for new features

PROJECT RULES
  Protocol: binary frames with ISO status_class/subclass; JSON default (TXT via --format=txt)
  Transport: QUIC+TLS 1.3 default, TCP legacy, stdio backward compat
  Security: never log secrets; TLS 1.3 self-signed for dev
  Policy: LIMIT/OFFSET requires ORDER (US001); ORDER BY identifiers only
  Logging: JSON Lines at INFO/ERROR levels
  Copilot: follow .github/copilot-instructions.md for scope, diagnostics, tests
