# Migration task checklist (branch: feat/storage-lib-migration)

Baseline (2026-05-30): geode `zig build` GREEN (247M binary @17:39); fts-storage + timeseries-storage
build green offline (the *_EXIT=1 was mise noise, not zig). fts hash =
`fts_storage-0.1.0-onLN42xpAACEKExBLj4zRRfWLfVdwYkn7yKuvAYQrCCk`, commit 3f080a14.

## Phase A — FTS → fts-storage

- [x] A1  Wire fts-storage dep + module (build.zig.zon + build.zig + addImport sites) + smoke test
- [x] A2  src/storage/fts_storage_adapter.zig (wrap fts_storage.Engine) + unit test
- [x] A3  Rework FullTextIndex to delegate to adapter (keep tokenizer); delete fulltext_persist
- [x] A4  End-to-end wiring DONE (A4a c1833f37; lazy-fix 09ff969c; A4b cfa687b9; field-leak fix f350f53c) — full suite green, independently confirmed
- [ ] A5  Comprehensive unit tests
- [ ] A6  Native benchmark (VarianceEnvelope) + CI-aware latency gate
- [ ] A7  geode-test-harness fts specs
- [ ] A8  Downstream verify + CLAUDE.md + finalize

## Phase B — Timeseries completion/hardening (already cut over to timeseries-storage)

- [ ] B0  Confirm cut-over + value-type mapping + baseline (read-only)
- [ ] B1  Pin/lib hygiene (likely no-op; fix lib stale version test)
- [ ] B2  GQL ingest path (ts_insert/ts_insert_many) — the functional gap
- [ ] B3  Comprehensive unit tests
- [ ] B4  Native benchmark parity + CI-aware latency gate
- [ ] B5  geode-test-harness timeseries specs
- [ ] B6  Downstream verify + CLAUDE.md + finalize

## Per-task protocol (subagent-driven-development)

implementer (TDD, build+test, commit) → spec review → code-quality review → mark done.
Single core: ONE build at a time; smoke steps where possible; full `zig build` sparingly.
