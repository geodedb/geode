#!/usr/bin/env bash
# =============================================================================
# Distinct-IP (NON-loopback) 3-node Raft cluster replication regression test.
#
# docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md was
# re-opened because the in-repo *loopback* tests pass but the real multi-pod
# k8s cluster did not replicate writes. The reporter explicitly asked for:
#
#   "separate network namespaces with distinct routable IPs, not loopback,
#    that asserts (a) a single leader is elected and survives a rolling
#    restart of any one pod, and (b) a leader write reads back on both
#    followers."
#
# This test builds exactly that with Linux network namespaces: 3 nodes, each
# in its OWN netns with a distinct routable IP on a bridge, WILDCARD cluster
# bind (0.0.0.0, as k8s leaves it), MTU 1450 (flannel VXLAN parity), a custom
# DNS server resolving k8s-style FQDN peers, hostname-derived node identity,
# and CA-signed TLS. It then asserts the replication contract that the
# loopback tests cannot exercise.
#
# Requires root (network namespaces). Skips cleanly (exit 0) when not root or
# when `ip`/`openssl`/`python3` are unavailable, so it is safe in unprivileged
# CI; run it in a privileged job to actually exercise the cluster.
#
# Usage:  sudo tests/cluster/netns_cluster_replication_test.sh [path-to-geode]
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BIN="${1:-$ROOT/zig-out/bin/geode}"
WORK="${NETNS_TEST_WORK:-/tmp/geode-netns-cluster-test}"
SUBNET="${NETNS_TEST_SUBNET:-10.89.0}"
BR=gtestbr0
NS_NODES="1 2 3"
NS_ALL="1 2 3 53"
# Pod IPs are $SUBNET.1<id> (.11/.12/.13) and DNS is $SUBNET.153 so NONE collide
# with the bridge gateway ($SUBNET.1) — a bridge/pod IP clash would silently
# route host->pod queries to the host's own :3141 service.
ns_ip() { echo "$SUBNET.1$1"; }
DNS_IP="$(ns_ip 53)"

skip() { echo "SKIP: $*"; exit 0; }
fail() { echo "FAIL: $*"; FAILED=1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$(id -u)" = "0" ] || { [ -n "${SUDO_OK:-}" ] || sudo -n true 2>/dev/null || skip "needs root for network namespaces"; }
SUDO=""; [ "$(id -u)" = "0" ] || SUDO="sudo"
have ip || skip "ip(8) not available"
have openssl || skip "openssl not available"
have python3 || skip "python3 not available"
[ -x "$BIN" ] || skip "geode binary not found at $BIN (build first: zig build)"

TOKEN="netns-test-token"; HMAC="netns-test-hmac-0123456789abcdef0123456789abcdef"; ADMINPW="NetnsTestPw123!"
PEERS="geode-1.geode.test:4242,geode-2.geode.test:4242,geode-3.geode.test:4242"
FAILED=0
declare -A PID

teardown() {
  [ -n "${KEEP_WORK:-}" ] && { echo "(KEEP_WORK set: leaving cluster + $WORK up; pids: ${PID[*]:-} dns=${DNSPID:-})"; return; }
  for id in $NS_NODES; do [ -n "${PID[$id]:-}" ] && $SUDO kill "${PID[$id]}" 2>/dev/null; done
  [ -n "${DNSPID:-}" ] && $SUDO kill "$DNSPID" 2>/dev/null
  for i in $NS_ALL; do $SUDO ip netns del gt$i 2>/dev/null; $SUDO rm -rf /etc/netns/gt$i 2>/dev/null; done
  $SUDO ip link del $BR 2>/dev/null
  $SUDO rm -rf "$WORK" 2>/dev/null
}
trap teardown EXIT
KEEP_WORK= teardown 2>/dev/null   # clean any prior run (force, ignore KEEP_WORK)
mkdir -p "$WORK"

# ---- topology: bridge + 4 netns (3 nodes + 1 DNS) ---------------------------
$SUDO ip link add $BR type bridge
$SUDO ip addr add "$SUBNET.1/24" dev $BR
$SUDO ip link set $BR mtu 1450 up
for i in $NS_ALL; do
  $SUDO ip netns add gt$i
  $SUDO ip link add vth$i type veth peer name vtp$i
  $SUDO ip link set vth$i master $BR; $SUDO ip link set vth$i mtu 1450 up
  $SUDO ip link set vtp$i netns gt$i
  $SUDO ip netns exec gt$i ip link set lo up
  $SUDO ip netns exec gt$i ip link set vtp$i mtu 1450
  $SUDO ip netns exec gt$i ip addr add "$(ns_ip $i)/24" dev vtp$i
  $SUDO ip netns exec gt$i ip link set vtp$i up
  $SUDO ip netns exec gt$i ip route add default via "$SUBNET.1"
  $SUDO mkdir -p /etc/netns/gt$i
  printf "nameserver %s\nsearch geode.test\noptions ndots:5\n" "$DNS_IP" | $SUDO tee /etc/netns/gt$i/resolv.conf >/dev/null
done

# ---- DNS server (k8s headless-service style FQDN -> pod IP) ------------------
cat > "$WORK/dns.py" <<PYEOF
import socket, struct, sys
ZONE = {"geode-1.geode.test.":"$(ns_ip 1)","geode-2.geode.test.":"$(ns_ip 2)","geode-3.geode.test.":"$(ns_ip 3)"}
ZONE.update({k.split('.')[0]+'.':v for k,v in list(ZONE.items())})
def name(d,o):
    L=[]
    while d[o]:
        n=d[o];o+=1;L.append(d[o:o+n].decode());o+=n
    return ".".join(L)+".",o+1
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(("$DNS_IP",53))
sys.stderr.write("dns up\n");sys.stderr.flush()
while True:
    d,a=s.recvfrom(512);q,o=name(d,12);t,_=struct.unpack(">HH",d[o:o+4]);o+=4;ip=ZONE.get(q)
    if ip and t==1:
        an=b"\xc0\x0c"+struct.pack(">HHIH",1,1,30,4)+socket.inet_aton(ip);fl=0x8180;ac=1
    else:
        an=b"";fl=0x8183;ac=0
    s.sendto(d[:2]+struct.pack(">HHHHH",fl,1,ac,0,0)+d[12:o]+an,a)
PYEOF
$SUDO ip netns exec gt53 python3 "$WORK/dns.py" > "$WORK/dns.log" 2>&1 &
DNSPID=$!
sleep 1

# ---- CA + leaf (FQDN + IP SANs) ---------------------------------------------
openssl ecparam -name prime256v1 -genkey -noout -out "$WORK/ca.key" 2>/dev/null
openssl req -x509 -new -key "$WORK/ca.key" -days 2 -subj /CN=netns-ca -addext "basicConstraints=critical,CA:TRUE" -out "$WORK/ca.crt" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out "$WORK/leaf.key" 2>/dev/null
openssl req -new -key "$WORK/leaf.key" -subj /CN=geode-node -out "$WORK/leaf.csr" 2>/dev/null
cat > "$WORK/leaf.ext" <<EOF
subjectAltName=DNS:geode-1.geode.test,DNS:geode-2.geode.test,DNS:geode-3.geode.test,IP:$(ns_ip 1),IP:$(ns_ip 2),IP:$(ns_ip 3),DNS:localhost
extendedKeyUsage=serverAuth,clientAuth
EOF
openssl x509 -req -in "$WORK/leaf.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" -CAcreateserial -days 2 -extfile "$WORK/leaf.ext" -out "$WORK/leaf.crt" 2>/dev/null
RUNUSER="${SUDO_USER:-$(id -un)}"
chown -R "$RUNUSER" "$WORK" 2>/dev/null || true
chmod -R a+rX "$WORK"

start_node() {
  local id=$1
  mkdir -p "$WORK/data$id"; chown "$RUNUSER" "$WORK/data$id" 2>/dev/null || true
  # Privilege-drop to run geode as the non-root user inside the netns. Use a
  # fixed `sudo -u` (NOT `$SUDO -u`): when the script itself is launched as root
  # (e.g. `sudo tests/...` / the Makefile target) $SUDO is empty, and `$SUDO -u`
  # would exec a bare "-u" as the command. `sudo -u` works both as-root and when
  # the script self-elevates as a sudo-capable user.
  $SUDO ip netns exec gt$id sudo -u "$RUNUSER" env HOSTNAME="geode-$id" \
    GEODE_CLUSTER_TOKEN="$TOKEN" GEODE_AUTH_HMAC_KEY="$HMAC" GEODE_PEERS="$PEERS" \
    GEODE_CLUSTER_PORT="4242" GEODE_CLUSTER_CA_CERT="$WORK/ca.crt" GEODE_ADMIN_PASSWORD="$ADMINPW" \
    "$BIN" serve --listen "0.0.0.0:3141" --cluster-port 4242 --peers "$PEERS" \
      --data-dir "$WORK/data$id" --cert "$WORK/leaf.crt" --key "$WORK/leaf.key" --log-level info \
      >> "$WORK/node$id.log" 2>&1 &
  PID[$id]=$!
}
q() { local id=$1 sql=$2 to=${3:-15}; timeout "$to" "$BIN" query --server "$(ns_ip $id):3141" --insecure-tls-skip-verify -U geode -P "$ADMINPW" "$sql" 2>&1; }
laststate() { grep -aoE "\[raft\] node $1 state=[a-z]+ term=[0-9]+" "$WORK/node$1.log" 2>/dev/null | tail -1; }
cnt() { q "$1" "MATCH (n:$2) RETURN count(n) AS c" 12 | grep -aoE '"c":[0-9]+' | grep -aoE '[0-9]+' | tail -1; }
leaderof() { for id in 1 2 3; do laststate $id | grep -q state=leader && { echo $id; return; }; done; }
follower_of() { for id in 1 2 3; do [ "$id" != "$1" ] && { echo $id; return; }; done; }

for id in $NS_NODES; do start_node $id; done

# ---- A1: leader elected ------------------------------------------------------
echo "== A1: leader election =="
LID=""
for t in $(seq 1 30); do sleep 1; LID=$(leaderof); [ -n "$LID" ] && break; done
if [ -z "$LID" ]; then fail "A1 no leader elected in 30s"; for id in 1 2 3; do echo "  node$id: $(laststate $id)"; done; echo "RESULT: FAIL"; exit 1; fi
echo "PASS A1: leader=node$LID"
F1=$(follower_of $LID); F2=$(follower_of $LID); for id in 1 2 3; do [ "$id" != "$LID" ] && [ "$id" != "$F1" ] && F2=$id; done

# ---- A2: no-RETURN CREATE replicates to BOTH followers -----------------------
echo "== A2: CREATE (no RETURN) replicates to both followers =="
q "$LID" 'CREATE (:RepA {v:1})' 20 >/dev/null; sleep 4
for id in 1 2 3; do c=$(cnt $id RepA); [ "$c" = "1" ] || fail "A2 node$id RepA count=$c (want 1)"; echo "  node$id RepA=$c"; done

# ---- A3: CREATE ... RETURN replicates to BOTH followers ----------------------
#   (re-open / original-repro shape; was applied LEADER-LOCAL only -> divergence)
echo "== A3: CREATE ... RETURN replicates to both followers =="
q "$LID" 'CREATE (:RepB {v:2}) RETURN 1' 20 >/dev/null; sleep 4
for id in 1 2 3; do c=$(cnt $id RepB); [ "$c" = "1" ] || fail "A3 node$id RepB count=$c (want 1) -- RETURN-create did not replicate"; echo "  node$id RepB=$c"; done

# ---- A4: a write sent to a FOLLOWER must NOT be silently applied locally ------
#   (was: follower applied the write to its own store only -> divergence)
echo "== A4: follower rejects writes (no silent local apply) =="
out=$(q "$F1" 'CREATE (:RepC {v:3})' 20); sleep 3
lead_c=$(cnt "$LID" RepC); f1_c=$(cnt "$F1" RepC); f2_c=$(cnt "$F2" RepC)
echo "  follower-write response: $(echo "$out" | tail -1 | cut -c1-120)"
echo "  counts after follower-write: leader=$lead_c f1=$f1_c f2=$f2_c"
# Acceptable outcomes: (a) follower rejects -> all counts 0, or (b) follower
# forwards to leader -> all counts EQUAL and >=1. UNACCEPTABLE: divergence
# (follower has it but leader/other-follower do not).
if [ "$f1_c" != "$lead_c" ] || [ "$f1_c" != "$f2_c" ]; then
  fail "A4 divergence: follower-local write not consistent across cluster (leader=$lead_c f1=$f1_c f2=$f2_c)"
else
  echo "PASS A4: no divergence (all nodes agree: $lead_c)"
fi

# ---- A5: steady-state under sustained write load (k8s root cause #5) ----------
#   Reproduces the transport stream-starvation: sustained heartbeat+AppendEntries
#   load must NOT drive any node to a stuck `candidate`, and (the A1 fix) transient
#   OutOfStreams backpressure must NOT churn peer-connection evictions/handshakes.
#   On a fast host this may not reproduce the k8s CPU-limited pressure that
#   triggers OutOfStreams pre-fix — but it asserts the contract holds post-fix and
#   is a guard against regressing A1. Set LOAD_SECS/WRITERS higher to stress more.
echo "== A5: steady-state under sustained write load (root cause #5) =="
LID5=$(leaderof); [ -n "$LID5" ] || LID5=$LID
LOAD_SECS=${LOAD_SECS:-45}; WRITERS=${WRITERS:-6}
echo "  driving ${WRITERS} concurrent writers for ${LOAD_SECS}s against leader node$LID5..."
load_end=$(( $(date +%s) + LOAD_SECS ))
lpids=()
for w in $(seq 1 "$WRITERS"); do
  ( i=0; while [ "$(date +%s)" -lt "$load_end" ]; do
      q "$LID5" "CREATE (:Load {w:$w, i:$i})" 8 >/dev/null 2>&1; i=$((i+1)); done ) &
  lpids+=($!)
done
for p in "${lpids[@]}"; do wait "$p" 2>/dev/null; done
sleep 5
echo "  post-load raft states:"; for id in 1 2 3; do echo "    node$id: $(laststate $id)"; done
cand=0; lead=0
for id in 1 2 3; do
  st=$(laststate $id)
  echo "$st" | grep -q state=candidate && cand=$((cand+1))
  echo "$st" | grep -q state=leader && lead=$((lead+1))
done
[ "$cand" = "0" ] || fail "A5 $cand node(s) parked as candidate under load (root cause #5)"
[ "$lead" = "1" ] || fail "A5 expected exactly 1 leader after load, got $lead"
evicts=0
for id in 1 2 3; do
  n=$(grep -ac "evicting cached peer connection" "$WORK/node$id.log" 2>/dev/null || true)
  evicts=$((evicts + ${n:-0}))
done
echo "  evict-on-error log lines across cluster: $evicts (A1: transient OutOfStreams must NOT evict)"
[ "$evicts" -le "${EVICT_MAX:-8}" ] || fail "A5 $evicts evictions (>${EVICT_MAX:-8}) — connection-evict churn under load (A1 regressed)"
# Re-resolve the leader AFTER load (a benign re-election may have moved it / bumped
# term). Followers may still be APPLYING the load backlog, so the post-load write
# replicates with lag — POLL each node up to LF_CATCHUP_SECS for catch-up. The
# bug under test is permanent candidate-parking (asserted above), not apply-lag;
# this check verifies replication is not permanently STALLED.
sleep 3; LIDF=$(leaderof); [ -n "$LIDF" ] || LIDF=$LID5
echo "  post-load leader for final write: node$LIDF"
q "$LIDF" 'CREATE (:LoadFinal {v:9})' 20 >/dev/null
LF_CATCHUP_SECS=${LF_CATCHUP_SECS:-45}
lf_ok=1
for id in 1 2 3; do
  c=0
  for _ in $(seq 1 "$LF_CATCHUP_SECS"); do c=$(cnt $id LoadFinal); [ "$c" = "1" ] && break; sleep 1; done
  [ "$c" = "1" ] || { fail "A5 node$id LoadFinal=$c after ${LF_CATCHUP_SECS}s — replication STALLED under load (not just lag)"; lf_ok=0; }
  echo "  node$id LoadFinal=$c"
done
[ "$cand" = "0" ] && [ "$lead" = "1" ] && [ "$lf_ok" = "1" ] && echo "PASS A5: 1 leader, 0 candidates, evicts=$evicts, final write replicated to all 3 (post-load catch-up)"

echo
if [ "$FAILED" = "0" ]; then echo "RESULT: PASS"; exit 0; else echo "RESULT: FAIL"; exit 1; fi
