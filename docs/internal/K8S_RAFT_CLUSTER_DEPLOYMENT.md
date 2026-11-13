# Geode 3‑Node Raft Cluster on Kubernetes — Internal Deployment Runbook

> ⚠️ **CONFIDENTIAL — INTERNAL CodePros ONLY. NOT FOR OPEN‑SOURCE RELEASE.**
> Exclude `docs/internal/` from any public fork (see [README](README.md)).

This runbook documents the **validated, working** configuration for running geode
as a 3‑node Raft cluster on Kubernetes, plus every deployment gotcha learned
bringing the cluster from "never converges" to **production‑eligible in
`v0.7.0`**. It is the operational companion to the engineering bug log
[`docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md`](../bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md).

It is **distinct** from [`docs/deployment/DEPLOYMENT.md`](../deployment/DEPLOYMENT.md)
(generic Docker‑Compose single‑node). This is k8s + Raft + our arda environment.

---

## 0. TL;DR

- **Use geode `v0.7.0` or newer for clustering. Do NOT cluster on any `0.6.x`.**
  Every `0.6.x` line cannot hold a stable 3‑node quorum under churn on real k8s
  (documented saga; fixes landed across `v0.6.27‑28 → ‑30 → ‑32 → ‑34`, released
  as `v0.7.0`).
- The GitOps repo `geode-argo-arda` `main` is **single‑node and stale** (pins
  `0.6.14`, clustered component disabled, `--insecure` probes, no cluster CA).
  The live working cluster (`geode-qa`) diverges from it. **§8 lists the exact
  deltas to commit before you can sync a working cluster from git.**
- The keystone that makes cluster TLS work is a **3‑tier cert‑manager PKI with
  pod‑DNS SANs** (§5) — it is the single most common reason a cluster won't form.
- Validate any cluster build with the **sustained‑churn gate** (§9) before
  trusting it. That gate is what `v0.7.0` passes and `0.6.x` fails.
- **Prod is intentionally still single‑node `0.6.14`.** Rolling prod onto a
  clustered release is a deliberate operator decision (§13), not automatic.

---

## 1. Architecture

```
 Kubernetes namespace geode-qa (or geode-prod)         context: company (arda)

   StatefulSet geode  (replicas: 3, podManagementPolicy: Parallel)
     geode-0 / geode-1 / geode-2   (PSS=restricted, runAsNonRoot 65532, RO rootfs)
        |  client QUIC      3141/UDP   <- Service geode-quic (LoadBalancer)
        |  raft mesh        4242/UDP   <- Service geode (headless, publishNotReady=true)
        |  durable raft log /data/raft (PVC, RWO, local-path)
        |  client TLS       /tls           (secret geode-tls)
        |  cluster TLS      /cluster-tls    (secret geode-cluster-tls: ca.crt+tls.crt+tls.key)
        |
   cert-manager PKI (cluster mesh):
     Issuer geode-cluster-selfsigned (selfSigned)
        -> Certificate geode-cluster-ca   (isCA:true)  -> secret geode-cluster-ca
        -> Issuer geode-cluster-ca (CA)
        -> Certificate geode-cluster-tls  (pod-DNS SANs, server+client auth) -> /cluster-tls
   ESO <- Vault pki.devnw.com (mount codepros, path codepros/geode/<env>, auth kubernetes-arda)
        -> Secret geode-secrets: GEODE_ADMIN_PASSWORD, GEODE_DSN, GEODE_CLUSTER_TOKEN,
                                  GEODE_AUTH_HMAC_KEY, S3_*
   ArgoCD Application geode-<env> (auto-sync prune+selfHeal, server-side apply)
```

- Transport is **QUIC + TLS 1.3 only**. `3141/UDP` = client; `4242/UDP` = raft mesh.
- Node identity: `GEODE_NODE_ID` is the pod ordinal + 1 (`geode-0`→1, …→3).
- Raft durable state (log + hard‑state) lives in the PVC at `/data/raft` and
  **survives pod restarts** (this is load‑bearing for restart‑idempotent apply).

---

## 2. Minimum version & why

| geode build | acceptor wedge | no‑leader livelock | stranded node rejoins 3/3 |
|---|---|---|---|
| `0.6.14`–`0.6.26` | — | cluster never forms / diverges | ❌ |
| `v0.6.27‑28` | 2 nodes wedge | permanent (manual roll) | ❌ |
| `v0.6.27‑30` | 1 node wedges | ~6 min, watchdog‑assisted | ❌ stranded |
| `v0.6.27‑32` | **0** (RC‑A fixed) | **0** (livelock fixed) | ❌ `HandshakeError` strand |
| **`v0.7.0`** (`g c5c0b833`) | **0** | **0** | **✅ clean 3/3, no roll** |

The three stacked root causes, all closed in `v0.7.0`:

- **RC‑A — QUIC acceptor rx‑queue wedge** (quic v0.1.29): under a reconnect storm
  the kernel `:3141` UDP rx_queue backed up past the 8 MiB / 30 s watchdog and a
  node `exit(70)`‑restarted. Fixed by bounding the socket‑drain independent of the
  per‑cycle Initial processing budget.
- **RC‑B — raft frozen‑term split‑vote livelock** (raft v0.1.9): all‑candidate, no
  leader, terms frozen. Fixed by timer‑based candidate demotion + randomized
  backoff (desyncs lockstep peers) so an election completes without a quorum of
  rejections.
- **RC‑C — `HandshakeError` on peer re‑connect** (geode `c5c0b833`): a churned peer
  couldn't re‑handshake its raft connection to the new leader and stayed stranded.
  Fixed by reaping the stale QUIC connection so a fresh handshake succeeds.

---

## 3. Prerequisites

- Kubernetes (arda; `kubectl --context company`), namespaces `geode-qa` / `geode-prod`.
- **cert‑manager** installed (the cluster PKI is cert‑manager `Issuer`/`Certificate`).
- **ArgoCD** (Application per env; auto‑sync prune+selfHeal).
- **External Secrets Operator (ESO)** + reachable Vault `pki.devnw.com`
  (mount `codepros`, kubernetes auth mount `kubernetes-arda`, roles `geode-qa`/`geode-prod`).
- RWO storage (local‑path) for the per‑pod 10 Gi (qa) / 100 Gi (prod) PVCs.
- **CPU headroom** — see §11.5. Raft is latency‑sensitive; the stock qa floor
  (500 m) is too low for clustering.
- geode image **`v0.7.0`+** (or the `dev` tag while iterating; releases are pure
  git tags `v0.6.27`→`v0.7.0`).

---

## 4. Secrets (Vault → ESO → `geode-secrets`)

`SecretStore geode-vault` → Vault `pki.devnw.com`, KV‑v2 mount `codepros`, auth
`kubernetes-arda` with SA `geode-vault-auth`, role `geode-<env>`.
`ExternalSecret geode-secrets` extracts `codepros/geode/<env>` into Secret
`geode-secrets`. Required keys **for clustering**:

| Key | Purpose | Constraint |
|---|---|---|
| `GEODE_ADMIN_PASSWORD` | admin user `geode` | ≥16 chars |
| `GEODE_DSN` | client DSN | `host:3141?insecure=false&user=geode&pass=…` |
| `GEODE_CLUSTER_TOKEN` | **gates raft activation + RPC auth** | **identical on all 3 members** |
| `GEODE_AUTH_HMAC_KEY` | auth‑chain HMAC | **identical on all 3 members**, stable across reschedule (e.g. `openssl rand -hex 32`) |
| `S3_ACCESS_KEY` / `S3_SECRET_KEY` | backups | — |

> Cluster mode is **only** active when `GEODE_CLUSTER_TOKEN` is set; without it
> geode runs standalone and silently ignores the cluster wiring.

---

## 5. The cluster‑TLS PKI (the keystone)

This is **not in the argo repo** and is the most common reason a cluster won't
form. A cert‑manager **selfSigned non‑CA leaf used as its own anchor is rejected
with `HandshakeError`**. You need a real CA:TRUE trust anchor and the leaf must
carry the **pod DNS SANs** and **both `server auth` and `client auth`** usages
(raft peers authenticate mutually). Apply these 4 objects per namespace:

```yaml
# 1) self-signed bootstrap issuer
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: { name: geode-cluster-selfsigned }
spec: { selfSigned: {} }
---
# 2) the cluster CA (CA:TRUE), signed by the selfSigned issuer
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: geode-cluster-ca }
spec:
  isCA: true
  commonName: geode-cluster-ca
  secretName: geode-cluster-ca
  duration: 87600h            # 10y
  privateKey: { algorithm: ECDSA, size: 256, encoding: PKCS8, rotationPolicy: Always }
  issuerRef: { name: geode-cluster-selfsigned, kind: Issuer, group: cert-manager.io }
---
# 3) the CA issuer (signs leaf certs from the CA secret)
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: { name: geode-cluster-ca }
spec: { ca: { secretName: geode-cluster-ca } }
---
# 4) the leaf the pods actually present — POD-DNS SANs + server AND client auth
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: geode-cluster-tls }
spec:
  secretName: geode-cluster-tls       # -> mounted at /cluster-tls (ca.crt, tls.crt, tls.key)
  commonName: geode-cluster
  duration: 8760h                     # 1y
  renewBefore: 720h
  privateKey: { algorithm: ECDSA, size: 256, encoding: PKCS8, rotationPolicy: Always }
  usages: [ server auth, client auth, digital signature, key encipherment ]
  dnsNames:
    - geode-0.geode.geode-qa.svc.cluster.local   # <-- one per pod ordinal
    - geode-1.geode.geode-qa.svc.cluster.local
    - geode-2.geode.geode-qa.svc.cluster.local
    - geode.geode-qa.svc.cluster.local           # headless service name
  issuerRef: { name: geode-cluster-ca, kind: Issuer, group: cert-manager.io }
```

**Per‑namespace:** swap `geode-qa` → `geode-prod` in every SAN. The pod presents
`/cluster-tls/tls.crt`+`tls.key`; peers verify against `/cluster-tls/ca.crt`
(`GEODE_CLUSTER_CA_CERT`). The leaf SANs **must** exactly match the pod FQDNs in
`GEODE_PEERS` or the handshake fails.

> The public client cert `geode-tls` (ACME `*.geodedb.com`) is **separate** — the
> cluster works on `geode-cluster-tls` even if the public cert is unhealthy.

---

## 6. The clustered StatefulSet (validated live config)

Differences from single‑node baseline are what matter; the exact working values:

- `replicas: 3`, **`podManagementPolicy: Parallel`** (OrderedReady deadlocks
  quorum — pod‑0 waits Ready, Ready needs quorum, quorum needs the other pods).
- Headless Service `geode`: **`publishNotReadyAddresses: true`** + port `4242/UDP`
  (peers must resolve each other before any is Ready).
- Container **`command`** (the entrypoint — derives identity, then `exec`s geode
  with **space‑separated** flags; see §11.1):

```sh
sh -c '
  set -e
  ORD="${HOSTNAME##*-}"
  export GEODE_NODE_ID="$((ORD + 1))"
  NS="${POD_NAMESPACE}"
  export GEODE_PEERS="geode-0.geode.${NS}.svc.cluster.local:4242,geode-1.geode.${NS}.svc.cluster.local:4242,geode-2.geode.${NS}.svc.cluster.local:4242"
  exec geode serve --listen 0.0.0.0:3141 --data-dir /data \
       --cert /cluster-tls/tls.crt --key /cluster-tls/tls.key --cluster-port 4242
'
```

- **Env** (in addition to the single‑node set):
  - `GEODE_CLUSTER_TOKEN` → `secretKeyRef geode-secrets:GEODE_CLUSTER_TOKEN`
  - `GEODE_AUTH_HMAC_KEY`  → `secretKeyRef geode-secrets:GEODE_AUTH_HMAC_KEY`
  - `GEODE_CLUSTER_CA_CERT = /cluster-tls/ca.crt`
  - `GEODE_CLUSTER_NAME = geode-cluster`
  - `GEODE_CLUSTER_PORT = 4242`
  - `POD_NAMESPACE` → `fieldRef metadata.namespace`
- **Probes** (startup / liveness / readiness) — all three, **`--ca-cert`, never
  `--insecure`** (release builds refuse `--insecure`, see §11.4):

```sh
geode query --server 127.0.0.1:3141 --ca-cert /cluster-tls/ca.crt \
     -U geode -P "$GEODE_ADMIN_PASSWORD" "RETURN 1" >/dev/null
```

- **Volumes / mounts:** `data`→`/data` (PVC, rw), `tls`→`/tls` ro (secret
  `geode-tls`), **`cluster-tls`→`/cluster-tls` ro (secret `geode-cluster-tls`)**,
  `tmp`→`/tmp` (memory emptyDir).
- **Resources (validated):** requests `cpu: 2 / memory: 2Gi`, limits
  `cpu: 4 / memory: 4Gi`. (The repo's qa overlay `500m/2000m` is **too low** —
  §11.5.)
- **PodDisruptionBudget `minAvailable: 2`** (keep quorum during drains).
- **NetworkPolicy `geode-allow-cluster`**: ingress+egress between
  `app.kubernetes.io/name: geode` pods on `4242/UDP` and `3141/UDP`.
- securityContext (unchanged from base): runAsNonRoot 65532, RO rootfs, drop ALL
  caps, seccomp RuntimeDefault.

---

## 7. Enabling the cluster + deltas vs the `geode-argo-arda` repo

In `geode-argo-arda`, the clustered `kustomize` Component exists at
`manifests/components/clustered/` but is **not referenced** by any overlay. To
turn a single‑node overlay into a 3‑node cluster:

```yaml
# manifests/overlays/<env>/kustomization.yaml
components:
  - ../../components/clustered
images:
  - name: geodedb/geode
    newTag: "0.7.0"          # <-- NOT 0.6.14
```

**But the repo `main` is stale — these deltas must also land before a synced
cluster actually works** (they currently exist only live / in local commits):

1. **Image → `v0.7.0`+** in base + both overlays (repo pins `0.6.14`).
2. **Cluster PKI (§5)** — add the 4 cert‑manager objects to base (the repo has
   **no** internal CA; the clustered component comment still suggests
   `GEODE_CLUSTER_INSECURE=1`, which we do **not** use).
3. **`/cluster-tls` mount + `cluster-tls` volume** (secret `geode-cluster-tls`).
4. **Entrypoint flags space‑separated** and pointing `--cert/--key` at
   `/cluster-tls/tls.{crt,key}` (the repo's component still has `--cluster-port=4242`
   `=`‑form / `--tls-dir`; §11.1).
5. **Probes → `--ca-cert /cluster-tls/ca.crt`** in base + clustered component (repo
   uses `--insecure-tls-skip-verify`, which a release build refuses; §11.4). This
   is the local‑only argo commit `ed0852a`.
6. **Cluster CPU floor** ≥ `2`/`4` cores (§11.5).
7. `GEODE_CLUSTER_CA_CERT`, `GEODE_AUTH_HMAC_KEY` env wired in the clustered patch.

> **ArgoCD discipline:** if you hotfix the live cluster ahead of git, **pause
> auto‑sync first** (`kubectl -n argocd patch application geode-<env> --type merge
> -p '{"spec":{"syncPolicy":{"automated":null}}}'`), and **push the fix to the
> argo repo before re‑enabling** — otherwise `selfHeal` reverts your fix and
> re‑breaks the pods. `geode-qa` currently runs paused with the probe/cert fixes
> applied live.

---

## 8. Deploy procedure

1. Land the §7 deltas in `geode-argo-arda` (or apply live with auto‑sync paused).
2. Ensure Vault `codepros/geode/<env>` has `GEODE_CLUSTER_TOKEN` +
   `GEODE_AUTH_HMAC_KEY` (identical values that the 3 members share).
3. Apply / sync the cert‑manager PKI (§5); confirm the certs are issued:
   `kubectl -n geode-<env> get certificate geode-cluster-ca geode-cluster-tls`
   (both `READY=True`) and `secret geode-cluster-tls` has `ca.crt tls.crt tls.key`.
4. Sync the Application (or `kustomize build overlays/<env> | kubectl apply -f -`).
5. **Verify (acceptance):**
   - `kubectl -n geode-<env> get pods -l app.kubernetes.io/name=geode` → 3× `1/1 Running`.
   - One leader, two followers, same term:
     `for p in geode-0 geode-1 geode-2; do kubectl -n geode-<env> logs $p -c geode --tail=12 | grep -oE 'state=[a-z]+ term=[0-9]+' | tail -1; done`
   - A leader write replicates 1/1/1 (§10).
   - **Run the sustained‑churn gate (§9)** before declaring it production‑ready.

---

## 9. Validation gate (the acceptance test)

A cluster build is only trusted after it passes the **sustained‑churn gate** on
real k8s (netns / unit tests cannot reproduce the failures — they are `:3141`
acceptor + cross‑pod handshake phenomena at pod scale). The gate `v0.7.0` passes:

> **6 × 4‑rapid‑leader‑kill bursts (24 kills) on a clean‑PVC cluster, plus an
> 8‑minute self‑heal watch, must show:**
>
> 1. **No acceptor wedge** — zero `ACCEPTOR WEDGE` / `exit(70)` / restarts (check
>    `--previous` containers too — §11.7).
> 2. **No no‑leader livelock** — a leader + functional quorum throughout; the
>    cluster reconverges to **clean 3/3 without a manual pod roll**.
> 3. **Zero data loss** — seeded nodes/edges survive (1/1/1), `EdgeSlotMappingMissing`
>    count 0, writes commit+replicate to the majority.

Reference battery (adapt namespace/context; queries use `--ca-cert`):

```sh
# helpers
rstate(){ kubectl --context company -n geode-qa logs "$1" -c geode --tail=12 \
  | grep -oE 'state=[a-z]+ term=[0-9]+' | tail -1; }
leader(){ for p in geode-0 geode-1 geode-2; do case "$(rstate $p)" in *leader*) echo $p; return;; esac; done; echo NONE; }
wedge(){ for p in geode-0 geode-1 geode-2; do
  c=$(kubectl -n geode-qa logs $p -c geode --tail=1500 | grep -c 'ACCEPTOR WEDGE')
  pv=$(kubectl -n geode-qa logs $p -c geode --previous --tail=1500 2>/dev/null | grep -c 'ACCEPTOR WEDGE')
  rc=$(kubectl -n geode-qa get pod $p -o jsonpath='{.status.containerStatuses[0].restartCount}')
  echo -n "$p(cur=$c prev=$pv rst=$rc) "; done; echo; }

# clean slate first (FileStorage persists divergent raft state — §11.8)
kubectl -n geode-qa scale statefulset geode --replicas=0
kubectl -n geode-qa delete pvc data-geode-0 data-geode-1 data-geode-2
kubectl -n geode-qa scale statefulset geode --replicas=3

# 6 bursts of 4 rapid leader kills, then watch for clean 3/3
for burst in 1 2 3 4 5 6; do
  for k in 1 2 3 4; do L=$(leader); [ "$L" != NONE ] && \
    kubectl -n geode-qa delete pod "$L" --grace-period=0 --force >/dev/null; sleep 6; done
  wedge   # must stay all-zero
done
# then poll up to 8 min: all three at the SAME term with a leader, no manual roll.
```

Acceptance: every burst reconverges to clean 3/3, `wedge` stays all‑zero, and a
post‑churn write replicates 1/1/1. (See the bug doc's "RESOLVED" section for the
`v0.7.0` run.)

---

## 10. Operations

**Query the cluster** (always `--ca-cert`, route writes to the leader):

```sh
kubectl --context company -n geode-qa exec geode-1 -c geode -- sh -c \
  'geode query --server 127.0.0.1:3141 --ca-cert /cluster-tls/ca.crt \
   -U geode -P "$GEODE_ADMIN_PASSWORD" "RETURN 1"'
```

**Read raft state:** `kubectl logs <pod> -c geode | grep '\[raft\] node'` →
`state=leader|follower|candidate term=N`. Healthy = 1 leader + 2 followers, same term.

**Roll to a new image** (dev iterating, or a release bump):

```sh
# in-place rolling (keeps data): bump image tag and let the STS roll, OR
kubectl -n geode-qa delete pod -l app.kubernetes.io/name=geode   # imagePullPolicy must re-pull
# clean-slate (loses data, for tests): scale 0 -> delete PVCs -> scale 3
```

**Recover a wedged/stranded cluster** (rarely needed on `v0.7.0`, which self‑heals):

- Transient livelock / one stranded node → **full simultaneous pod roll**
  (`kubectl delete pod geode-0 geode-1 geode-2 …`) breaks it; data survives.
- Divergent **durable** raft state (cluster won't re‑elect after a roll) → **wipe
  PVCs** (§11.8). FileStorage at `/data/raft` can persist an inconsistent log that
  a rolling restart cannot reconcile.

---

## 11. Gotchas catalogue (the hard‑won learnings)

### 11.1 geode flags are SPACE‑separated only

`--flag value` works; **`--flag=value` is silently ignored** and geode falls back
to defaults (incl. a throwaway self‑signed cert — single‑node never noticed
because the defaults happen to match). The entrypoint must pass
`--cert`/`--key`/`--data-dir`/`--cluster-port` space‑separated, or peer TLS uses
the wrong cert and handshakes fail. (This comment is baked into the live entrypoint.)

### 11.2 Cluster TLS needs a CA:TRUE anchor with pod‑DNS SANs

A selfSigned non‑CA leaf as its own anchor → `HandshakeError`. Build the 3‑tier
PKI (§5). The leaf needs **both `server auth` and `client auth`** (raft peers are
mutual) and SANs matching every pod FQDN in `GEODE_PEERS`.

### 11.3 `GEODE_CLUSTER_CA_CERT` / `--cert` / `--key` must point at `/cluster-tls`

Not `/tls` (that's the public client cert). The cluster secret `geode-cluster-tls`
projects `ca.crt`, `tls.crt`, `tls.key` into `/cluster-tls`.

### 11.4 Release builds REFUSE `--insecure-tls-skip-verify`

A release binary (or `GEODE_ENV=production`) errors: *"SECURITY: refusing
--insecure-tls-skip-verify on a release build."* **All probes and client queries
must use `--ca-cert /cluster-tls/ca.crt`** (escape hatch `GEODE_ALLOW_INSECURE_TLS=1`,
not recommended). The single‑node base manifests still use `--insecure` — migrate
them **before** upgrading prod off a debug build, or every probe fails and pods
never go Ready (raft can be healthy underneath while k8s shows 0/3).

### 11.5 CPU starvation destabilizes raft

Too‑low CPU → mesh handshake timeouts + heartbeat‑delay candidate flapping. The
repo qa floor (`500m`/`2000m`) is insufficient for clustering; the working cluster
runs **`2` req / `4` limit** cores. Give raft headroom.

### 11.6 `podManagementPolicy: Parallel` + `publishNotReadyAddresses: true`

OrderedReady + readiness‑gated‑on‑quorum is a deadlock (no pod becomes Ready until
quorum, which needs the not‑yet‑Ready pods). Parallel start + advertising
not‑ready addresses lets peers find each other and elect.

### 11.7 `kubectl logs --tail` reads only the CURRENT container

A watchdog `exit(70)` wedge lives in the **`--previous`** container. An in‑run
`--tail` grep shows `0` wedges and is misleading. Always check `--previous` +
`lastState.terminated.exitCode == 70`.

### 11.8 FileStorage persists divergent raft state across rolls

Raft log + hard‑state at `/data/raft` (PVC) survive restarts (correct for
restart‑idempotent apply) but a **divergent/wedged** durable log can prevent
re‑election after a roll. **Always wipe PVCs for a clean test** (scale 0 → delete
PVCs → scale 3); stale state otherwise confounds results.

### 11.9 Writes route through the leader; followers fail‑closed

A write to a follower returns `ClusterNotLeader` (SQLSTATE `40001`) and is **not**
applied or forwarded — clients must discover/route to the leader. (This is the
fail‑closed write gate; it prevents silent divergence.)

### 11.10 `08006` "outcome‑unknown" on a committed write is not a failure

At a leader transition (or while the 3rd node is absent) a write that **does**
commit+replicate can return SQLSTATE `08006`. Treat it as **retryable with an
idempotency key** — geode's idempotency‑key dedup prevents a double‑insert. Do not
blindly retry without a key.

### 11.11 The QUIC acceptor watchdog self‑restarts a wedged node

If the QUIC listener's UDP socket keeps datagrams queued for ≥ 30 s with no
datagram drained from it in that time, geode `exit(70)`s so the orchestrator
restarts it. The watchdog watches the listener's bound address (an ephemeral
`--listen host:0` port and an IPv6 listener included; it announces it at
startup: `[startup] acceptor watchdog: watching udp ... port N`), and the
backlog threshold is any queued datagram (1 byte; it was 8 MiB before
SONNY-6480, which let an acceptor wedged with a few queued connection attempts
run unrestarted).
A node that is still draining its backlog, only slower than datagrams arrive (a
CPU-starved or throttled pod, an overload), is slowed and not restarted
(SONNY-2719); before that fix it was killed after the same 30 s. Thresholds:
`GEODE_ACCEPTOR_WATCHDOG_RX_BYTES`, `GEODE_ACCEPTOR_WATCHDOG_DEADLINE_MS`.
Opt out with `GEODE_ACCEPTOR_WATCHDOG_DISABLE=1`. Tuning
knobs: `GEODE_QUIC_INITIAL_BUDGET` (server Initial processing budget/cycle, default
64), `GEODE_QUIC_DRAIN_PACKETS` (socket drain cap). `v0.7.0` bounds the rx_queue so
this rarely fires — frequent `exit(70)`s on a release build signal a regression.

### 11.12 Pods get new IPs on reschedule

`GEODE_PEERS` uses FQDNs; geode re‑resolves them on reschedule (works ≥ `v0.6.26`).
Don't pin peer IPs.

---

## 12. Known residuals (non‑blocking on `v0.7.0`)

- **`08006` on a fully‑replicated write** (§11.10) — cosmetic; data is correct and
  the idempotency key prevents double‑insert.
- Transient `HandshakeError` log lines still appear during heavy churn, but the
  stale connection is now reaped and the peer rejoins (RC‑C) — they self‑correct.

---

## 13. Prod rollout guidance

Prod (`geode-prod`) is **deliberately** still single‑node `geodedb/geode:0.6.14`.
Before clustering prod:

1. Land the §7 deltas in `geode-argo-arda` `main` **and push them** (don't run prod
   on local‑only hotfixes).
2. **Migrate the single‑node / base probes off `--insecure` to `--ca-cert`**
   (§11.4) — prod's upgrade path hits the release‑build TLS refusal.
3. Provision the prod cluster PKI (§5 with `geode-prod` SANs) and the
   `GEODE_CLUSTER_TOKEN` / `GEODE_AUTH_HMAC_KEY` Vault keys at `codepros/geode/prod`.
4. Set the prod CPU floor for clustering (≥ §11.5).
5. Validate on a prod‑like clean cluster with the §9 gate first.
6. Roll prod with `minAvailable: 2` so quorum is never lost during the upgrade.

---

## 14. References

- Engineering bug log (root causes, fix history, gate runs):
  [`docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md`](../bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md)
- GitOps manifests: `geode-argo-arda` (`manifests/base`, `manifests/components/clustered`,
  `manifests/overlays/<env>`, `argocd/application-<env>.yaml`).
- Generic single‑node Docker deploy: [`docs/deployment/DEPLOYMENT.md`](../deployment/DEPLOYMENT.md).

---

*Validated on arda `geode-qa`, 2026‑06‑15, geode `v0.7.0` (`c5c0b833`). Prod
untouched (single‑node `0.6.14`).*
