CRUSH.md — geode (ISO/IEC 39075 GQL graph database) quick reference

BUILD & TEST
  zig build -Doptimize=ReleaseSafe          # Build (ReleaseSafe)
  zig build test                            # All Zig tests (unit+e2e)
  zig test tests/e2e_protocol.zig           # Single Zig test file
  zig fmt .                                 # Format all Zig code
  go test ./...                             # Go tests (run at repo root)
  (cd clients/go/gql && go test -run TestName -v)  # Single Go test
  go build -o bin/canaryscan ./tools/canaryscan && \
    ./bin/canaryscan --root . --out status.json --csv status.csv
  make build                                # Build all (Zig + Go)
  make canary-verify                        # Verify CANARY rules vs docs

RUN
  ./zig-out/bin/geoded --listen-quic 0.0.0.0:7567 --log_json --result-format json
  ./zig-out/bin/geodec "RETURN 1 AS x" --server 127.0.0.1:7567 --format json

LINT & QUALITY
  zig fmt --check .                         # Enforce Zig formatting
  go fmt ./... && go vet ./...              # Go formatting & vetting

CODE STYLE (Zig 0.15.1)
  Naming: lower_snake_case (vars/fns), UpperCamelCase (types), SCREAMING_SNAKE (consts)
  Imports: prefer std; avoid dynamic net deps; pin versions if third‑party
  Errors: use error unions; surface ISO GQLSTATUS (US001, IllegalOrderKey, etc.)
  Logging: JSON Lines (INFO/ERROR); never log secrets
  Files: src/{gql/, parser/, planner.zig, exec.zig, protocol.zig, server/, client/}
  Determinism: tests ≤512MiB RSS, ≤30s; fixed seeds; no nondeterminism

POLICIES & RULES
  ORDER/PAGE: LIMIT/OFFSET requires ORDER (US001); ORDER BY identifiers only
  Protocol: binary frames w/ status_class/subclass; JSON default; TXT via flag
  Security: TLS 1.3 dev certs; least privilege; no secrets in code or logs
  Copilot rules: follow .github/copilot-instructions.md (acceptance tests, diagnostics, conformance)
