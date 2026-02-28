# Geode QA Deployment - Connection Investigation

**Date:** 2026-02-27 / 2026-02-28
**Target:** qa.geodedb.com:31410 (QUIC/UDP)
**Server:** earendil Azure VM (172.176.193.24), k3s, geode v0.1.11-beta.6
**Status:** RESOLVED - QUIC connection fully operational

---

## Issue Chain (All Resolved)

### 1. Double-free in QuicClient (FIXED)

- **Symptom:** GPA double-free on `geode shell --server qa.geodedb.com:31410`
- **Root cause:** `errdefer` freed `quic_config` but didn't null the struct field; `deinit()` freed stale pointer
- **Fix:** Added `self.quic_config = null` in errdefer blocks in `connectInsecure()` and `connectEx()`
- **Commit:** `542ba51f` (geode repo, pushed)

### 2. DNS hostname resolution (FIXED)

- **Symptom:** Vendor QUIC library can't resolve hostnames (only IP literals)
- **Root cause:** `vendor_quic/endpoint/utils.zig:resolveAny()` only handles IPs and "localhost"
- **Fix:** Added `resolveHostToIp()` helper using `dns` library; added `dns` module to `build.zig`
- **Commit:** `542ba51f` (geode repo, pushed)

### 3. DNS string-vs-binary bug (FIXED)

- **Symptom:** tcpdump showed packets going to 49.55.50.46 instead of 172.176.193.24
- **Root cause:** `dns.Client.resolveA()` returns IP as string ("172.176.193.24"), code treated string bytes as binary octets (49='1', 55='7', 50='2', 46='.')
- **Fix:** Changed `std.fmt.allocPrint("{d}.{d}.{d}.{d}", bytes)` to `allocator.dupe(u8, result.addresses[0])`
- **Commit:** `099197c2` (geode repo, pushed)
- **Note:** Same bug exists in `src/audit/syslog.zig:resolveHostToAddress()` (not yet fixed)

### 4. Missing `serve` subcommand (FIXED)

- **Symptom:** Pod CrashLoopBackOff, "Error: unknown option '--listen'"
- **Fix:** Added `"serve"` as first arg in k8s deployment YAML
- **Commit:** infra repo (pipeline passed)

### 5. gRPC TLS unavailable (FIXED)

- **Symptom:** Pod CrashLoopBackOff, "error: TlsNotAvailable"
- **Root cause:** Docker image lacks OpenSSL for gRPC TLS (`GeodeGrpcServer.init()` calls `initTlsContext()` which is a stub)
- **Fix:** Removed `--listen-grpc 0.0.0.0:50051` from container args
- **Commit:** infra repo (pipeline passed)

### 6. UFW blocking UDP 31410 (FIXED)

- **Symptom:** tcpdump on server showed zero incoming traffic on port 31410
- **Root cause:** UFW only allowed SSH (22/tcp) and k3s API (6443/tcp)
- **Fix:** `sudo ufw allow 31410/udp` applied live + added to cloud-init runcmd in `azure.tf`
- **Commit:** `9931ec6` (infra repo, pushed)

### 7. TLS handshake loop - RSA vs EC key type (FIXED)

- **Symptom:** QUIC handshake exchanges packets bidirectionally but never completes (30s timeout)
- **Root cause:** Vault PKI issued RSA 4096 certs; the vendor QUIC library's TLS 1.3 only supports ECDSA P-256 for server certificate signing. Handshake gets stuck in an infinite retry loop.
- **Evidence:**
  - Local server with self-signed EC P-256 cert: connection succeeds immediately ("Authentication required" = handshake completed)
  - Remote server with RSA 4096 cert from Vault: bidirectional packet exchange observed via tcpdump but handshake never completes
  - tcpdump shows proper 1200-byte Initial, server responds (405, 48, 1200, 46, 1467, 83, 45, 2347 bytes), client continues (1201, 47, 49 bytes), but cycle repeats endlessly
  - The vendor library field is literally named `inline_server_priv_p256` (the p256 is a hint!)
  - Supported signature schemes in `handshake_integration.zig` list RSA-PSS but the signing code may only implement ECDSA
- **Fix:** Changed Vault PKI from `key_type="rsa", key_bits=4096` to `key_type="ec", key_bits=256` for CA, server role, and client role
- **Commit:** `9931ec6` (infra repo, pushed)

### 8. Terraform didn't recreate certs after PKI role change (FIXED)

- **Symptom:** After changing PKI role key_type from RSA→EC, server cert was still RSA
- **Root cause:** `vault_pki_secret_backend_cert` resource arguments (backend, name, common_name) didn't change — only the referenced role's key_type changed. Terraform treated TTL changes as in-place updates without re-issuing. The Vault provider's `vault_pki_secret_backend_cert` does NOT have ForceNew on `ttl`.
- **Fix:** Used `TF_CLI_ARGS_plan="-replace=vault_pki_secret_backend_cert.geode_qa_server -replace=...admin -replace=...benji"` to force Terraform to destroy and recreate all three cert resources. Also added `lifecycle { replace_triggered_by = [vault_pki_secret_backend_root_cert.geode_ca] }` for future CA rotations.
- **Commits:** `81a36bc` (lifecycle), `184d08f` (TTL attempt), `0114a14` (force-replace), `f325c58` (cleanup)

---

## Verification (2026-02-28)

```
$ geode query --server qa.geodedb.com:31410 --insecure-tls-skip-verify -U admin -P <pw> "RETURN 1 AS x"
{"status_class":"00000","columns":[{"name":"x","type":"INTEGER"}],"rows":[{"x":1}]}
```

Server cert confirmed EC P-256:

```
Public Key Algorithm: id-ecPublicKey
ASN1 OID: prime256v1
Issuer: CN = Geode QA CA
Subject: CN = qa.geodedb.com
```

## Network Path (Verified Working)

```
Client (10.0.0.33)
  → NAT → 174.99.97.9
  → Internet
  → Azure NSG (AllowGeodeQUIC: UDP 31410)
  → VM eth0 (10.50.1.4:31410)
  → iptables DNAT (KUBE-EXT-ML6WGVTS3CJOJBN4)
  → cni0 → Pod (10.42.0.x:3141)
  → Geode QUIC server (vendor/quic endpoint)
```

All links verified with tcpdump at each hop.

## All Known Issues Resolved

- **DNS library memory leak** — Fixed in `dns` library `src/client.zig`: moved `free(response.data)` from inside the block scope (where it either leaked in stub mode or caused use-after-free in recursive mode) to after the switch statement. Commit: `976fedf` (dns repo).
- **Syslog DNS string-vs-binary bug** — Fixed in `src/audit/syslog.zig:resolveHostToAddress()`: same pattern as issue #3, replaced binary-octet formatting with direct `parseIp4(result.addresses[0], port)`.

## Lessons Learned

1. **Vendor QUIC library requires EC P-256 certs** — despite listing RSA-PSS in supported signature schemes, the signing code only implements ECDSA. The field name `inline_server_priv_p256` is the hint.
2. **Terraform cert resources don't auto-recreate on role changes** — the cert resource only tracks its own arguments (backend, name, common_name, ttl). Changes to the referenced role's key_type don't trigger recreation. Use `lifecycle { replace_triggered_by }` or explicit `-replace` flags.
3. **Vault provider treats TTL changes as in-place updates** — changing TTL on `vault_pki_secret_backend_cert` does NOT force recreation (unlike most Terraform resources). The only reliable way is `-replace`.
4. **Cloud-init changes cause VM recreation** — modifying `custom_data` in Azure VMs causes Terraform to destroy and recreate the VM. Plan for this.
5. **DNS library returns strings, not binary** — `dns.Client.resolveA()` returns `[]const []const u8` where each entry is an IP string like "172.176.193.24", NOT binary IPv4 octets.
