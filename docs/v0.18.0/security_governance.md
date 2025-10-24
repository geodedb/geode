# Security & Governance

Authentication & Users:
- Users with hashed passwords (Argon2id recommended); enable MFA (TOTP) with recovery codes.
- Sessions via time-limited tokens; client stores at 0600 perms.

Authorization (RBAC + ABAC/RLS):
- Roles/permissions with inheritance and conditional clauses.
- Row-level security via policy rewrite (USING/CHECK); subject/resource/environment attributes; deny precedence.

Network & Encryption:
- QUIC+TLS only (no plaintext). Production: CA-signed certs; dev: self-signed auto-gen.
- TDE (AES‑256‑GCM) for data/WAL via GEODE_DISK_KEY_HEX; key rotation scaffolding; optional remote KMS unwrapping.
- Secrets never logged; zeroization of sensitive buffers.

Auditing:
- Append-only JSONL audit log; hash-chained entries; periodic Ed25519-signed digests.
- `geode-audit verify` validates chain/signatures.

Governance:
- CANARY annotations tie requirements to tests/benches; status.csv auto-generated.
- SECURITY_PROGRESS.md tracks maturity; CI enforces freshness and no feature flags.
