# Geode Tamper‑Evident Audit Logging

Geode’s audit stream is a canonical JSON Lines (JSONL) append‑only log. Each record carries seq_no, a hash chain, and periodic Merkle digests signed with Ed25519 (default ON).

- Canonical keys (order): ["stream","seq_no","timestamp","event_type","actor","origin","resource","action","result","details","prev_hash","event_hash","signature"].
- Hash: SHA‑256 (default) or BLAKE3. event_hash excludes prev_hash to avoid circularity.
- Chain: prev_hash of record i equals hash(event_hash of i-1). First prev_hash is 32 zero bytes.
- Digest: every 100 events (configurable) we append a DIGEST record containing the Merkle root over the last N event_hashes and an Ed25519 signature.
- Signing: Enabled by default. Keys from env: GEODE_AUDIT_PUB (hex32), GEODE_AUDIT_SEC (hex64). If missing in non‑test builds → CONFIG_ERROR SIGNING_KEYS_MISSING (exit 78). Test builds derive a deterministic key from a fixed seed.
- Rotation: time/size rotation continues seq_no; first record of new file uses prev_hash from the prior file’s tail.
- Redaction: PII redaction and log_denies_only preserved.

Verification CLI

Use geode-audit verify to validate an audit file:

  zig build geode-audit
  zig-out/bin/geode-audit verify --file /var/log/geode/audit.jsonl --algo sha256 --pubkey $GEODE_AUDIT_PUB

Outputs:
- OK chain ✅  records=<N> digests=<D> algo=<sha256|blake3>
- TAMPER chain ❌  at_seq=<s> reason=PREV_HASH_MISMATCH expected=<hex> got=<hex>
- TAMPER digest ❌  at_seq=<s> reason=DIGEST_MISMATCH expected=<hex> got=<hex>
- SCHEMA_ERROR ❌  at_seq=<s> field=<name> detail=<msg>
- WARN ignored trailing partial record (non‑fatal)

Operational Notes

- Files are opened 0600, append‑only.
- On startup, tail scan resumes last_seq/last_hash and tolerates one trailing partial line (WARN).
- SIGNING_KEY_ROTATION events are emitted when keys change.
- Limits: RSS ≤ 512 MiB; append latency ≤ 500 µs (excluding fsync).
