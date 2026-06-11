# Error Handling Policy

Status: Active (introduced 2026-06-11, GAP-0886b — quality issues #721, #556, #809, #810)

This policy governs every `catch {}`, `catch |_| {}`, `catch unreachable`, and bare
`unreachable` in the Geode codebase. The goal is **zero unjustified error swallows**:
every site that discards or asserts away an error must fall into one of the four
categories below, and (in the audited trees) carry an `// error-policy:` comment
naming its category and the concrete reason ignoring/asserting is safe.

## Categories

### A — Safe to ignore (requires a justification comment)

The operation is **best-effort by design**: its failure cannot affect correctness,
durability, security posture, or the truthfulness of anything reported to a caller.
Typical shapes: cache population, observability/metric registration, cleanup of
temporary artifacts, error-path rollback where the primary error is already being
propagated.

A bare `catch {}` is **not** self-justifying. The comment must say *why* the failure
is harmless, not just that it is intended.

Real examples from this repo:

```zig
// src/security/gps.zig — authorization decision cache
// Allocation errors from cache.insert are swallowed — a cache failure must never
// block an authorization decision.
cache.insert(k, d) catch {};
```

```zig
// src/storage/graph_storage_adapter.zig — error-path rollback
// error-policy: A — best-effort abort on an already-failing path; the primary
// error is propagated and WAL recovery supersedes a failed abort.
node_shard.abortTxn(local_txn) catch {};
```

```zig
// src/storage/group_commit.zig — observability registration
// error-policy: A — metric registration is best-effort observability;
// a duplicate-name or OOM failure must never block the commit pipeline.
reg.register("coord_apply_batches_total", &self.apply_batches_total) catch {};
```

### B — Must log

The failure does not justify aborting the surrounding operation, but it leaves the
system in a degraded or surprising state that an operator needs to see: stale
indexes, lost audit anchors, disabled rate-limit accounting, skipped maintenance.
Swallowing silently is a policy violation; the site must emit at least a `log.warn`
with enough context to act on (`@errorName(err)` plus the affected object).

Real examples from this repo (fixed in the 2026-06-11 audit):

```zig
// src/execution/property_mutation.zig — advanced-index rebuild after SET
manager.rebuildAdvancedIndex(store, name) catch |err| {
    // error-policy: B — a failed rebuild leaves the advanced index stale
    // (queries fall back to scans / may serve stale entries); the mutation
    // itself committed, so log loudly instead of failing the statement.
    log.warn("advanced index rebuild failed for '{s}': {s}", .{ name, @errorName(err) });
};
```

```zig
// src/security/audit.zig — recovering the audit hash-chain anchor at startup
var decoded: [32]u8 = undefined;
if (std.fmt.hexToBytes(&decoded, hex)) |_| {
    self.last_hash = decoded;
} else |err| {
    // error-policy: B — a malformed tail anchor must not brick startup, but
    // silently restarting the hash chain would hide tampering; warn loudly.
    log.warn("audit tail event_hash undecodable; hash chain restarts", ...);
}
```

### C — Must propagate

The caller's contract depends on the operation having succeeded: durability
(fsync-before-rename), security bookkeeping the caller reports on, or any result
the procedure surfaces to a client ("created", "started", `logged=true`). Swallowing
makes the system lie. These sites must `try`/propagate, or branch on the specific
benign error values and propagate the rest.

Real examples from this repo (fixed in the 2026-06-11 audit):

```zig
// src/security/tenant_registry.zig — atomic persist (temp file + rename)
// error-policy: C — fsync before rename is the durability point of the
// atomic-write protocol; swallowing the error could publish an empty/partial
// registry after a crash.
try f.sync(io);
```

```zig
// src/execution/storage_dispatch.zig — geode.cdc.start procedure
engine.start() catch |err| switch (err) {
    // error-policy: A — start is intentionally idempotent.
    error.AlreadyRunning => {},
    // error-policy: C — the procedure reports status="started"; a real
    // start failure must propagate instead of lying to the client.
    else => return err,
};
```

### D — Must crash / assert (invariant; requires a justification comment)

The error is statically impossible at this call site, and the justification must
name the invariant that makes it so (buffer sizes, validated lengths, error-set
analysis). `catch unreachable` without a provable invariant is a violation — if the
"impossible" error has any input-dependent path, it is category B or C instead.

Real examples from this repo:

```zig
// src/storage/graph_storage_adapter.zig
// error-policy: D — "{x:0>16}" of a u64 is exactly 16 bytes; id_buf is [16]u8.
var id_buf: [16]u8 = undefined;
const id_text = std.fmt.bufPrint(&id_buf, "{x:0>16}", .{reserved_id}) catch unreachable;
```

```zig
// src/security/auth_graph_manager.zig
// error-policy: D — computeRecordHmac's only error is TooManyProperties
// (>128); every call site passes a fixed-size props array well under that.
return auth_hmac.computeRecordHmac(hmac_key, props) catch unreachable;
```

## Scope and enforcement

- **Audited trees (zero unjustified swallows as of 2026-06-11):** `src/security/`,
  `src/storage/`, `src/wal.zig` (no sites), and `src/execution/` write paths
  (`property_mutation`, `auth_dispatch`, `audit_dispatch`, `tenant_dispatch`,
  `storage_dispatch` CDC, `fts_index_ops`).
- **Test code** (file-level `test` blocks, `tests/` helpers): `catch {}` /
  `catch unreachable` for environment setup, spin-wait yields, and cleanup is
  category A by default; a one-line tag is still preferred but not required.
- **Remaining tiers** (transport, CLI, REPL, execution read paths, etc.) are
  tracked in the burn-down table in `docs/QUALITY_GAP_ANALYSIS.md` (#721 row) and
  must be brought under this policy in subsequent rounds. New code in any tree
  must comply immediately: code review rejects a `catch {}` without a category
  comment.
- Counting commands (used for the burn-down):
  `rg -c "catch \{\}" src/<tree>/` and `rg -c "catch unreachable" src/<tree>/`.

## Known accepted residual (documented, not silent)

`deriveTenantTdeKey` (`src/security/tde_key_manager.zig`) and
`deriveTenantFileKey` (`src/storage/tde_file_encryption.zig`) fall back to a
fixed `"geode/tde/tenant/truncated"` HKDF info string when `tenant_id` exceeds
~490 bytes, which would collapse domain separation for two such tenants. The
final `catch unreachable` is category D (the literal always fits), but the
fallback itself is flagged: tenant ids are far below that bound in practice, and
changing the derivation would break at-rest compatibility. Tracked as a residual
in `docs/QUALITY_GAP_ANALYSIS.md`.
