<!-- SPDX-License-Identifier: Apache-2.0 -->

# Task 10 Report — Go 1.24 FIPS mode for Go build/test

**Branch:** feat/fips  
**Date:** 2026-06-24  
**Toolchain:** go version go1.26.3 linux/amd64 (>= 1.24 required)

---

## 1. Makefile changes

### 1a. `canary` target (canaryscan `go build`)

Added `GOFIPS140=v1.0.0 GODEBUG=fips140=on` to the `go build` command for
`tools/canaryscan`.  canaryscan is crypto-free so the env vars are a
build-time affirmation that the toolchain accepts FIPS mode — they do not
restrict behaviour.

Before:

```makefile
cd tools/canaryscan && go build -o ../../bin/canaryscan .
```

After:

```makefile
cd tools/canaryscan && GOFIPS140=v1.0.0 GODEBUG=fips140=on go build -o ../../bin/canaryscan .
```

### 1b. New `go-test-fips` target

Added after the `canary-verify` block.  Compiles all structurally-valid
`tests/quic_tests/*.go` standalone programs under FIPS mode to confirm the Go
Cryptographic Module accepts the crypto surface.

Key details:

- All `tests/quic_tests/*.go` carry `//go:build ignore` — they are standalone
  `main` programs, not a `go test` package.  `go test ./...` cannot run them.
- The target compiles each non-skipped file with
  `GOFIPS140=v1.0.0 GODEBUG=fips140=on go build -o /dev/null <file>`.
- Four files are skipped (pre-existing failures, same without FIPS):
  - `comprehensive_quic.go` — quic-go v0.54 API type change (`*quic.Stream`)
  - `test_quic.go` — local relative import `"./clients/go/gql"` rejected in
    module mode
  - `test_quic_3143.go` — removed `qlog.DefaultTracer`/`WriteCloser` API
  - `test_quic_detailed.go` — same removed qlog API
- These 4 failures are identical with and without `GOFIPS140` set; they are
  not caused by FIPS mode.
- Added `go-test-fips` to the `.PHONY` line (line 33 of the Makefile).

---

## 2. Go FIPS verification result

```
==> Go FIPS build-verification (GOFIPS140=v1.0.0 GODEBUG=fips140=on)
    Toolchain: go version go1.26.3 linux/amd64
    Note: tests/quic_tests/*.go are //go:build ignore standalone programs;
    each is compiled (not run) to verify FIPS-mode acceptance.
    Skipping 4 files with known pre-existing non-FIPS build failures.
    Results: 11 compiled OK, 0 failed (4 pre-existing skipped)
==> go-test-fips PASSED (all non-pre-existing quic_tests harnesses compile under FIPS mode)
```

Go 1.26.3 accepted `GOFIPS140=v1.0.0` without error.  All 11 harnesses
(including those using `crypto/tls`, `crypto/rand`, `crypto/rsa`,
`crypto/x509`) compiled successfully under FIPS mode.

Runtime interop testing (actual QUIC handshake) requires a live geode server
peer and is environment-gated; the build-compile gate is the maximum
verification achievable in this environment.

---

## 3. Non-approved Go crypto grep

```
grep -rn --include="*.go" -E '"crypto/(md5|rc4|des|sha1)"|"golang.org/x/crypto/(chacha20|blake2|argon2)"' \
  tools/ tests/
```

**No matches** — exit 1 (grep found nothing).

Production Go (canaryscan) is crypto-free.  The only Go crypto is the
FIPS-approved surface in the QUIC test harnesses:

- `crypto/tls` (TLS 1.3) — approved
- `crypto/rand` — approved
- `crypto/rsa` (RSA-2048+) — approved
- `crypto/x509` — approved

---

## 4. Documentation

Appended a "Go 1.24 FIPS mode" section to:

```
docs/superpowers/specs/2026-06-23-fips-support-design.md
```

The section covers:

- `GOFIPS140` / `GODEBUG=fips140=on` toggle table
- Production Go (crypto-free canaryscan)
- QUIC-interop harness crypto surface (all FIPS-approved)
- `make go-test-fips` description and environment-gating caveat
- Non-approved Go crypto: none found

---

## 5. Zig build unaffected

No Zig source files were modified.  `zig build -Dfips=false` continues to
compile as before; this change is Go-side only.

---

## 6. Environment limitation

Full runtime QUIC interop testing (actual TLS 1.3 handshake under FIPS)
requires a running geode server with a QUIC peer.  The `go-test-fips` target
provides compile-time verification only.  Runtime enforcement (`GODEBUG=fips140=on`)
can be validated manually by running any compiled harness binary against a
live server.

---

## Files changed

| File | Change |
|---|---|
| `Makefile` | `canary` target: add `GOFIPS140=v1.0.0 GODEBUG=fips140=on` to `go build`; add `go-test-fips` target; add to `.PHONY` |
| `docs/superpowers/specs/2026-06-23-fips-support-design.md` | Append Go FIPS mode section |
| `.superpowers/sdd/task-10-report.md` | This file |
