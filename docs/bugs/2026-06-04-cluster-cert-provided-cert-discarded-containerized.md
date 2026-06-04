# geode silently discards an explicitly-provided `--cert`/`--key` and self-signs when containerized → secure cluster TLS is unusable, 3-node k8s cluster never forms

**Date:** 2026-06-04
**Image:** `geodedb/geode:0.6.18` (commit `a148e4f3`; contains the GAP-0838 DNS-search + auto-derive-node_id fixes)
**Environment:** arda cluster (`company.arda-ca.net`, bare-metal/flannel, `local-path` PVC storage on `/dev/md3` ext4), namespace `geode-qa`, real 3-replica `StatefulSet`, PodSecurity **restricted** (runAsUser 65532, readOnlyRootFilesystem, drop ALL caps, seccomp RuntimeDefault), cert-manager-issued shared cluster cert.
**Severity:** **BLOCKER** for distributed/clustered deployments on Kubernetes; also a **silent security downgrade** for any containerized single-node deployment that supplies its own cert.
**Relationship to GAP-0838:** GAP-0838 (0.6.18) fixed DNS search-domain expansion (Bug A) and Raft node_id auto-derivation (Bug B), and its closing note says *"Re-enable the 3-node kustomize component in geode-argo-arda to validate end-to-end on the arda cluster."* Doing exactly that surfaced this **third, independent** bug, which blocks the cluster at the TLS layer — *before* the (now-fixed) election logic ever gets a chance to run.

---

## TL;DR

geode's certificate bootstrap (`src/tools/cert_gen.zig: ensureCertificatesAtPath`, called from `src/server/main.zig:960`) gates an **explicitly-provided** `--cert`/`--key` behind an existence probe:

```zig
// src/tools/cert_gen.zig
pub fn ensureCertificatesAtPath(allocator, cert_path, key_path) !void {
    const io = std.Io.Threaded.global_single_threaded.io();   // <-- allocator = .failing
    std.Io.Dir.cwd().access(io, cert_path, .{}) catch {
        try generateSelfSignedCert(allocator, "geode.local", cert_path, key_path);
        ...
    };
}
```

When geode is launched **as a container entrypoint under the production runtime** (not via `kubectl exec`), this `access()` probe **errors even though the file exists and is readable by the runtime uid** (`test -r` succeeds in the same container). geode then takes the `catch` branch and **regenerates a throwaway self-signed cert**, falling back to `/tmp/geode-server.crt` because the cert-manager secret mount is read-only:

```
Generated self-signed certificates at /tmp/geode-server.crt and /tmp/geode-server.key
[startup] certificates ready (9ms)
```

`main.zig` then forwards that **same** `cert_path` to the Raft cluster listener (`maybeStart(... cert_path ...)` → `ClusterCoordinator.Config.cert_path`). So **every node presents a different, self-signed cert on the Raft port (4242)**. Peers cannot verify each other against the shared `GEODE_CLUSTER_CA_CERT`, every cross-pod QUIC handshake fails, and the cluster spins forever:

```
WARN geode.raft raft transport getOrCreatePeerConnection failed error=HandshakeError peer=2
[raft] node 1 state=candidate term=0 iter=11600
```

Because `GEODE_CLUSTER_INSECURE=1` is (correctly) refused in release builds, **there is no way to bring up a working 3-node cluster**: the only supported secure path is "provide CA-signed certs + `GEODE_CLUSTER_CA_CERT`", and geode discards the provided certs.

This was confirmed across ~10 StatefulSet rollouts and a dozen isolation pods. It is **not** a one-off.

---

## Two distinct defects

### Defect 1 — `ensureCertificatesAtPath` treats an explicit `--cert` as a "generate-if-missing" path

The same routine is used for both (a) the *default/auto* cert (no `--cert` given → `<data-dir>/server.crt`, which geode is expected to create) and (b) an *operator-provided* `--cert`. For case (b) the semantics are wrong on two counts:

1. **It regenerates / overrides the provided cert** instead of just loading it. An explicitly-provided `--cert` must be used as-is.
2. **The failure is silent.** When the provided path can't be probed/written it logs only an info-level `Generated self-signed certificates at /tmp/...` and continues with a throwaway cert. The operator believes their CA-signed cert is in use; it is not. (`main.zig:961` emits a `log.warn`, but that fires *before* the structured logger is initialized at cert-resolution time, so it does **not** reach `kubectl logs`.)

### Defect 2 — the existence probe is non-deterministic / environment-sensitive

The probe uses `std.Io.Dir.cwd().access(io, cert_path, .{})` with `io = std.Io.Threaded.global_single_threaded.io()`, whose `allocator` is `.failing` (a deliberate choice — see the note in `generateSelfSignedCert` about `spawnPosix` OOMing). Empirically the probe's success depends on a fragile, non-obvious combination of process-launch context rather than on whether the file is actually accessible:

| Factor | Probe succeeds (cert reused) | Probe errors (cert discarded → self-sign) |
|---|---|---|
| Launch mechanism | `kubectl exec` (runc exec) — **always reused** | container entrypoint (runc run) — usually regenerates |
| Process session | new session (`setsid`) helped in some envs | container-init session |
| cwd | cwd ≠ data-dir helped in some envs | cwd == `--data-dir` (`/data`) |
| stdout (fd 1) | a **regular file** | the **container log pipe** |
| stdout file location | emptyDir/node-fs reused | tmpfs and PVC variants regenerated |
| data-dir filesystem | emptyDir reused | **PVC (`/dev/md3` ext4)** regenerated |

The maddening part: changing **any one** of these flips the outcome, and configurations that are byte-for-byte equivalent except for the data-dir's *backing filesystem* (emptyDir vs PVC) produce **opposite** results. A correct `access()`/`stat()` existence check must not depend on the process session, cwd, stdout fd, or the backing filesystem. The `.failing`-allocator single-threaded `Io` is the prime suspect: if any internal step of the threaded-Io `access` path allocates, it returns an error that the caller misreads as "file does not exist."

The net effect for an operator is that the bug is effectively **non-deterministic in the real StatefulSet**: it regenerates on every boot of the PVC-backed pod, while every diagnostic re-run via `kubectl exec` reuses the cert — which makes it look like the manifests are wrong when they are not.

---

## Reproduction

### A. End-to-end (the real failure)

1. Provide a shared, CA-signed cert (cert-manager self-signed Issuer, SANs = `geode-{0,1,2}.geode.<ns>.svc.cluster.local` + the headless service) as a Secret, mounted read-only at `/cluster-tls`.
2. Run `geode serve --listen=0.0.0.0:3141 --data-dir=/data --cert=/cluster-tls/tls.crt --key=/cluster-tls/tls.key --cluster-port=4242` as the container entrypoint, with `GEODE_CLUSTER_TOKEN`, `GEODE_PEERS` (FQDNs), `GEODE_CLUSTER_CA_CERT=/cluster-tls/ca.crt`.
3. Observe in `kubectl logs`:

   ```
   Generated self-signed certificates at /tmp/geode-server.crt and /tmp/geode-server.key
   ...
   WARN geode.raft ... getOrCreatePeerConnection failed error=HandshakeError peer=2
   [raft] node N state=candidate term=0 iter=...
   ```

   The provided `/cluster-tls/tls.crt` is never loaded; `/tmp/geode-server.crt` (CN=`geode.local`, per-node) is what the Raft listener serves.

### B. Minimal isolation (same image, no cluster)

```sh
# In the geode container (uid 65532), generate a recognizable cert:
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout /tmp/k.key -out /tmp/c.crt -days 1 -nodes -subj /CN=PROVIDED \
  -addext subjectAltName=DNS:localhost

# Launched as a container ENTRYPOINT with stdout = the container log pipe:
#   geode serve --cert=/tmp/c.crt --key=/tmp/k.key ...
#   => "Generated self-signed certificates at /tmp/geode-server.crt"  (DISCARDED /tmp/c.crt)

# The exact same command via `kubectl exec` (new session, stdout to a file):
#   => "[startup] certificates ready"  (REUSED /tmp/c.crt, CN=PROVIDED untouched)
```

`test -r /tmp/c.crt` returns success as uid 65532 in **both** cases — the file is genuinely accessible; only geode's probe disagrees.

---

## Impact

- **Distributed mode is unusable on Kubernetes.** The documented secure path (`docs/bugs/2026-06-02-cluster-0.6.14-k8s-still-fails.md` → "TLS trust note") — internal CA + per-pod-SAN certs + `GEODE_CLUSTER_CA_CERT` — cannot be satisfied because geode discards the provided certs and self-signs per node. With `GEODE_CLUSTER_INSECURE=1` refused in release builds, **no** secure or insecure path forms a cluster. GAP-0838's "re-enable the 3-node component" step is blocked here.
- **Silent security downgrade for single-node too.** Any containerized deployment that supplies `--cert`/`--key` (e.g., to serve a real CA-signed cert to clients) silently gets a throwaway self-signed cert instead, with only an info-level log line. Clients that verify will break; clients that don't (e.g., `?insecure=true`) will *appear* fine while not using the intended cert.

---

## Recommended fix (geode side)

1. **Do not gate an explicit `--cert`/`--key` behind generate-if-missing.** Split the two cases:
   - `--cert` **provided** → load it directly. Never probe-then-regenerate, never overwrite, never fall back to `/tmp`.
   - `--cert` **not provided** → keep the auto-generate-into-`<data-dir>` behavior.
2. **Fail loud.** If an explicitly-provided cert/key cannot be read or parsed, exit non-zero with a clear error (`cert_path`, `errno`/`@errorName`). Do **not** silently self-sign — that is a security footgun.
3. **Replace the existence probe.** `std.Io.Dir.cwd().access` over `std.Io.Threaded.global_single_threaded` (allocator `= .failing`) misreports existence depending on launch context. Use a robust, allocation-free existence check (e.g., `std.fs.cwd().accessZ(path, .{})` / `openFileZ` + close), or simply attempt to open the provided cert and let the open's error be authoritative. Make cert loading independent of process session, cwd, stdout fd, and the backing filesystem.
4. **Separate the cluster listener cert (optional, hardening).** Let the Raft listener take its own cert/key/CA (`--cluster-cert` / `--cluster-key` / `GEODE_CLUSTER_CA_CERT`) distinct from the client listener, so operators don't have to overload the client cert with the intra-mesh pod-DNS SANs. Document the cert-manager setup for k8s (this is the unmet "document required server cert SANs + CA env for Kubernetes" item from `docs/GAP_ANALYSIS.md`).

A targeted regression test should launch a real `geode serve --cert <provided> --key <provided>` as a **subprocess whose stdout is a pipe** and assert the served cert equals the provided one (i.e., that no `/tmp/geode-server.crt` is generated) — this reproduces the failure that the existing loopback cluster tests miss (they run on writable cwd with file/inherited stdio and so always hit the "reused" path).

## Deployment status / workaround attempts (geode-argo-arda)

The 3-node clustered component (`manifests/components/clustered/`) was wired correctly (3 replicas, `Parallel`, FQDN peers, `GEODE_CLUSTER_TOKEN`, `GEODE_AUTH_HMAC_KEY`, cert-manager self-signed CA with pod-DNS SANs, `GEODE_CLUSTER_CA_CERT`). The cluster still will not form solely because of this bug. Deployment-layer workarounds attempted and rejected as unreliable: copy the cert into writable tmpfs/`/data`; run geode as a non-PID-1 child; `setsid`; `cd` off the data-dir; redirect stdout to a file + `tail -F`. Each "fixed" it in some throwaway pods but **not** in the real PVC-backed StatefulSet — confirming Defect 2's environment sensitivity. The component is left disabled on qa pending a geode fix; re-enable once an explicit `--cert` is honored deterministically.

---

## ✅ RESOLVED (2026-06-04)

Fixed in geode `main`. An explicitly-provided `--cert`/`--key` (or config-file
`cert_path`/`key_path`) is now loaded **as-is**, and the existence check no
longer depends on the `.failing`-allocator `std.Io` probe.

**Changes:**

- **`src/server/cli_args.zig`** — `ServerConfig` now tracks `cert_explicit` /
  `key_explicit` (set when the cert/key come from `--cert`/`--key` or the config
  file, NOT when auto-derived from `--data-dir`/`GEODE_CERT_DIR`/`/tmp`).
  `resolveCertPaths` returns both flags.
- **`src/tools/cert_gen.zig`** —
  - `certFileReadable(path)`: allocation-free, `Io`-independent readability check
    via a raw `openat()` syscall (no `global_single_threaded`, no `.failing`
    allocator, no dependence on process session / cwd / stdout fd / backing fs).
    This addresses **Defect 2**.
  - `requireExistingCertificates(cert, key)`: verifies an operator-provided pair
    is readable and returns `error.ProvidedCertificateUnreadable` /
    `error.ProvidedKeyUnreadable` otherwise. **Never** generates, overwrites, or
    falls back to `/tmp`. This addresses **Defect 1**.
  - `ensureCertificatesAtPath` (auto path) now uses `certFileReadable` and only
    regenerates on *genuine* absence — replacing the bare `catch {}` that
    swallowed every error.
- **`src/server/main.zig`** — the QUIC/gRPC cert-resolution step branches: when
  the cert is explicit it calls `requireExistingCertificates` and **refuses to
  start** (non-zero exit, loud `std.debug.print` that reaches `kubectl logs`)
  if the provided cert/key can't be read — it never self-signs. A half
  configuration (only one of `--cert`/`--key`) is also refused. The resolved
  `cert_path` is then forwarded unchanged to the Raft cluster listener
  (`cluster_bootstrap.maybeStart`), the gRPC server, and the QUIC transport, so
  every node now presents the SAME operator-provided cert on the Raft port.
- **`src/transport/quic.zig`** — `QuicTransport.listen()`'s cert probe likewise
  uses the allocation-free `certPathReadable` instead of the
  `global_single_threaded` `access` probe, so a present cert is never
  misreported as missing and spuriously self-signed.

**Regression test:** `tests/test_cert_provided_cert_honored.zig` (build step
`zig build test-cert-provided`):

- Unit: `certFileReadable` true/false; `requireExistingCertificates` ok for a
  real pair, fails loud for a missing cert/key, and never fabricates a `/tmp`
  cert.
- E2E (subprocess, **stdout = pipe** — the exact launch context that flipped the
  bug): `geode serve --cert <missing>` **refuses** (non-zero exit, no
  `Generated self-signed`, no `/tmp/geode-server.crt`); `geode serve --cert
  <existing>` **loads it** (`using operator-provided TLS certificate` marker),
  leaves the provided cert byte-for-byte intact, and generates no `/tmp` cert.

These tests **failed against the pre-fix binary** (the missing-cert case
self-signed at the provided path; the existing-cert case never emitted the
load-as-is marker) and **pass after the fix**.

**Next:** re-enable the 3-node `components/clustered` overlay on qa to validate
end-to-end cluster formation now that explicit certs are honored deterministically.
