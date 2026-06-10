#!/usr/bin/env bash
# =============================================================================
# Distinct-IP (NON-loopback) 3-node Raft cluster MEMBERSHIP-CHURN regression.
#
# docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md was
# RE-OPENED (2026-06-09, dev=f653bdb) after the multiplexed-stream transport
# fix (root cause #5) was verified on the netns *steady-state* harness
# (netns_cluster_replication_test.sh A1-A5) and on real k8s: the cluster forms
# and replicates when all 3 nodes boot simultaneously and membership never
# changes. But on real k8s (where pods start staggered and restart constantly)
# the cluster CANNOT survive a membership change:
#
#   1. A node that starts LATE parks at `candidate term=0` and never joins.
#   2. A follower restarted with a NEW pod IP never rejoins (stays isolated).
#   3. Restarting the LEADER (new IP) breaks the whole cluster for 80s+.
#
# The steady-state A5 harness CANNOT see this — it never changes membership.
# This harness adds exactly the missing dimension: a MUTABLE DNS zone (so a
# restarted node can be re-pointed to a new IP, like a k8s pod reschedule) and
# live veth IP reassignment, then asserts the membership-change contract:
#
#   M1 staggered start   -> a late node joins as follower + replicates.
#   M2 follower new-IP    -> a follower restarted on a NEW IP rejoins + replicates.
#   M3 leader  new-IP     -> a leader restarted on a NEW IP -> single new leader
#                            re-elects within the election budget + replicates.
#   M4 in-place restart   -> a node restarted in place (PVC preserved) re-applies
#                            the committed log and must NOT duplicate a plain
#                            node CREATE (root cause #6).
#   M5 edge  restart-dup  -> ditto for a replicated edge CREATE: node + edge
#                            counts stay 1 after the durable-log re-apply.
#   M6 delete restart-dup -> a DETACH-DELETEd row must NOT resurrect from the log
#                            re-apply (count stays 0 everywhere).
#   M7 merge/SET restart  -> a MERGE'd row stays EXACTLY 1 (no double-apply) and a
#                            replicated MATCH...SET property survives the re-apply.
#   M8 MATCH...CREATE edge -> an edge created between two MATCH-bound nodes on the
#                            leader replicates to all 3 (GNC2 slice, 2026-06-10),
#                            a follower-directed MATCH...CREATE fails closed with
#                            ClusterNotLeader, and the edge stays EXACTLY 1 on all
#                            3 across an in-place restart (no re-apply duplicate).
#
# Same faithful topology as netns_cluster_replication_test.sh: 3 nodes, each in
# its own netns with a distinct routable IP on a bridge, WILDCARD cluster bind
# (0.0.0.0, as k8s leaves it), MTU 1450 (flannel VXLAN parity), k8s-style FQDN
# peers, hostname-derived identity, CA-signed TLS.
#
# Requires root (network namespaces). Skips cleanly (exit 0) when not root or
# when ip/openssl/python3 are unavailable, so it is safe in unprivileged CI.
#
# Usage:  sudo tests/cluster/netns_cluster_membership_churn_test.sh [path-to-geode]
#   Env:  PHASES="M1 M2 M3"  (subset to run; default all)
#         KEEP_WORK=1        (leave cluster + logs up for inspection)
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BIN="${1:-$ROOT/zig-out/bin/geode}"
WORK="${NETNS_TEST_WORK:-/tmp/geode-netns-churn-test}"
SUBNET="${NETNS_TEST_SUBNET:-10.90.0}"
BR=gchurnbr0
NS_NODES="1 2 3"
NS_ALL="1 2 3 53"
PHASES="${PHASES:-M1 M2 M3 M4 M5 M6 M7 M8}"
# Node IPs start at $SUBNET.1<id> (.11/.12/.13); a reschedule moves a node to
# $SUBNET.2<id> (.21/.22/.23). DNS is $SUBNET.153, bridge gw is $SUBNET.1.
ns_ip() { echo "$SUBNET.1$1"; }      # original pod IP for node $1
ns_ip2() { echo "$SUBNET.2$1"; }     # rescheduled (new) pod IP for node $1
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
declare -A IPLAST   # current last-octet-prefix per node: "1" => .1X, "2" => .2X
declare -A INC      # log-incarnation counter per node (for log rotation on restart)

teardown() {
  [ -n "${KEEP_WORK:-}" ] && { echo "(KEEP_WORK set: leaving cluster + $WORK up; pids: ${PID[*]:-} dns=${DNSPID:-})"; return; }
  for id in $NS_NODES; do [ -n "${PID[$id]:-}" ] && $SUDO kill "${PID[$id]}" 2>/dev/null; done
  [ -n "${DNSPID:-}" ] && $SUDO kill "$DNSPID" 2>/dev/null
  # Kill any straggler still inside a netns (privilege-dropped child whose pid we
  # did not track) before deleting the netns, else `ip netns del` silently fails.
  for i in $NS_ALL; do
    for pid in $($SUDO ip netns pids gt$i 2>/dev/null); do $SUDO kill -9 "$pid" 2>/dev/null; done
    $SUDO ip netns del gt$i 2>/dev/null; $SUDO rm -rf /etc/netns/gt$i 2>/dev/null
  done
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
  $SUDO mkdir -p /etc/netns/gt$i
  printf "nameserver %s\nsearch geode.test\noptions ndots:5\n" "$DNS_IP" | $SUDO tee /etc/netns/gt$i/resolv.conf >/dev/null
done
# DNS node + the 3 pod nodes get their initial IPs (.1X). Pod IPs are assigned
# via assign_ip so a later reschedule can move them.
$SUDO ip netns exec gt53 ip addr add "$DNS_IP/24" dev vtp53
$SUDO ip netns exec gt53 ip link set vtp53 up
$SUDO ip netns exec gt53 ip route add default via "$SUBNET.1"

assign_ip() {  # assign_ip <id> <prefix:1|2>   -> node $id gets $SUBNET.{prefix}{id}
  local id=$1 pfx=$2 ip
  ip="$SUBNET.$pfx$id"
  # Flush any prior address so a reschedule cleanly moves the node.
  $SUDO ip netns exec gt$id ip addr flush dev vtp$id 2>/dev/null
  $SUDO ip netns exec gt$id ip addr add "$ip/24" dev vtp$id
  $SUDO ip netns exec gt$id ip link set vtp$id up
  $SUDO ip netns exec gt$id ip route replace default via "$SUBNET.1"
  IPLAST[$id]=$pfx
}
for id in $NS_NODES; do assign_ip $id 1; done

# ---- mutable DNS zone (k8s headless-service style FQDN -> CURRENT pod IP) ----
# Written as a file the test rewrites on reschedule; dns.py re-reads per query
# so a SIGHUP/restart is unnecessary (matches k8s endpoint re-resolution).
write_zone() {
  local zid pfx                 # MUST be local: a leaked `id` would clobber callers (reschedule_node)
  : > "$WORK/zone.txt"
  for zid in $NS_NODES; do
    pfx="${IPLAST[$zid]:-1}"
    echo "geode-$zid.geode.test. $SUBNET.$pfx$zid" >> "$WORK/zone.txt"
    echo "geode-$zid. $SUBNET.$pfx$zid" >> "$WORK/zone.txt"
  done
}
write_zone
cat > "$WORK/dns.py" <<PYEOF
import socket, struct, sys
ZONE_FILE = "$WORK/zone.txt"
def load():
    z = {}
    try:
        for ln in open(ZONE_FILE):
            ln = ln.strip()
            if not ln: continue
            k, v = ln.split()
            z[k] = v
    except FileNotFoundError:
        pass
    return z
def name(d,o):
    L=[]
    while d[o]:
        n=d[o];o+=1;L.append(d[o:o+n].decode());o+=n
    return ".".join(L)+".",o+1
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(("$DNS_IP",53))
sys.stderr.write("dns up\n");sys.stderr.flush()
while True:
    d,a=s.recvfrom(512);q,o=name(d,12);t,_=struct.unpack(">HH",d[o:o+4]);o+=4
    ip=load().get(q)   # re-read zone every query so reschedules take effect live
    if ip and t==1:
        an=b"\xc0\x0c"+struct.pack(">HHIH",1,1,5,4)+socket.inet_aton(ip);fl=0x8180;ac=1
    else:
        an=b"";fl=0x8183;ac=0
    s.sendto(d[:2]+struct.pack(">HHHHH",fl,1,ac,0,0)+d[12:o]+an,a)
PYEOF
$SUDO ip netns exec gt53 python3 "$WORK/dns.py" > "$WORK/dns.log" 2>&1 &
DNSPID=$!
sleep 1

# ---- CA + leaf (FQDN + BOTH original and rescheduled IP SANs) ----------------
openssl ecparam -name prime256v1 -genkey -noout -out "$WORK/ca.key" 2>/dev/null
openssl req -x509 -new -key "$WORK/ca.key" -days 2 -subj /CN=netns-ca -addext "basicConstraints=critical,CA:TRUE" -out "$WORK/ca.crt" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out "$WORK/leaf.key" 2>/dev/null
openssl req -new -key "$WORK/leaf.key" -subj /CN=geode-node -out "$WORK/leaf.csr" 2>/dev/null
cat > "$WORK/leaf.ext" <<EOF
subjectAltName=DNS:geode-1.geode.test,DNS:geode-2.geode.test,DNS:geode-3.geode.test,IP:$(ns_ip 1),IP:$(ns_ip 2),IP:$(ns_ip 3),IP:$(ns_ip2 1),IP:$(ns_ip2 2),IP:$(ns_ip2 3),DNS:localhost
extendedKeyUsage=serverAuth,clientAuth
EOF
openssl x509 -req -in "$WORK/leaf.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" -CAcreateserial -days 2 -extfile "$WORK/leaf.ext" -out "$WORK/leaf.crt" 2>/dev/null
RUNUSER="${SUDO_USER:-$(id -un)}"
chown -R "$RUNUSER" "$WORK" 2>/dev/null || true
chmod -R a+rX "$WORK"

start_node() {
  local id=$1
  # Rotate the previous incarnation's log aside so laststate/leaderof/cnt read
  # ONLY the current incarnation — a restarted node must not be judged on stale
  # pre-restart `state=leader` lines (which `tail -1` would otherwise surface).
  if [ -f "$WORK/node$id.log" ]; then
    INC[$id]=$(( ${INC[$id]:-0} + 1 )); mv "$WORK/node$id.log" "$WORK/node$id.log.old${INC[$id]}" 2>/dev/null
  fi
  mkdir -p "$WORK/data$id"; chown "$RUNUSER" "$WORK/data$id" 2>/dev/null || true
  $SUDO ip netns exec gt$id sudo -u "$RUNUSER" env HOSTNAME="geode-$id" \
    GEODE_CLUSTER_TOKEN="$TOKEN" GEODE_AUTH_HMAC_KEY="$HMAC" GEODE_PEERS="$PEERS" \
    GEODE_CLUSTER_PORT="4242" GEODE_CLUSTER_CA_CERT="$WORK/ca.crt" GEODE_ADMIN_PASSWORD="$ADMINPW" \
    "$BIN" serve --listen "0.0.0.0:3141" --cluster-port 4242 --peers "$PEERS" \
      --data-dir "$WORK/data$id" --cert "$WORK/leaf.crt" --key "$WORK/leaf.key" --log-level info \
      >> "$WORK/node$id.log" 2>&1 &
  PID[$id]=$!
}

# query node $id at its CURRENT ip (.1X or .2X)
cur_ip() { echo "$SUBNET.${IPLAST[$1]:-1}$1"; }
q() { local id=$1 sql=$2 to=${3:-15}; timeout "$to" "$BIN" query --server "$(cur_ip $id):3141" --insecure-tls-skip-verify -U geode -P "$ADMINPW" "$sql" 2>&1; }
laststate() { grep -aoE "\[raft\] node $1 state=[a-z]+ term=[0-9]+" "$WORK/node$1.log" 2>/dev/null | tail -1; }
termof() { laststate "$1" | grep -aoE 'term=[0-9]+' | grep -aoE '[0-9]+'; }
roleof() { laststate "$1" | grep -aoE 'state=[a-z]+' | sed 's/state=//'; }
cnt() { q "$1" "MATCH (n:$2) RETURN count(n) AS c" 12 | grep -aoE '"c":[0-9]+' | grep -aoE '[0-9]+' | tail -1; }
# Generic count: run an ARBITRARY query on node $1 that projects a single integer
# column aliased `AS c` (e.g. an edge count `MATCH ()-[r:T]->() RETURN count(r) AS c`
# or a predicated node count `MATCH (n:L) WHERE n.v = 42 RETURN count(n) AS c`) and
# echo the integer. Shares cnt()'s `"c":N` parse (verified shape: {"c":1}).
cntq() { q "$1" "$2" 12 | grep -aoE '"c":[0-9]+' | grep -aoE '[0-9]+' | tail -1; }
leaderof() { local id; for id in $NS_NODES; do [ -n "${PID[$id]:-}" ] && laststate $id | grep -q state=leader && { echo $id; return; }; done; }

# wait until node $1 reports state=$2 (any term) within $3 seconds
wait_state() { local id=$1 want=$2 to=${3:-30} t; for t in $(seq 1 "$to"); do [ "$(roleof $id)" = "$want" ] && return 0; sleep 1; done; return 1; }
# wait until SOME leader exists within $1 seconds; echo its id
wait_leader() { local to=${1:-30} t lid; for t in $(seq 1 "$to"); do lid=$(leaderof); [ -n "$lid" ] && { echo "$lid"; return 0; }; sleep 1; done; return 1; }
# poll node $1 for label $2 count==1 within $3 seconds
wait_cnt1() { local id=$1 lbl=$2 to=${3:-30} t c; for t in $(seq 1 "$to"); do c=$(cnt $id $lbl); [ "$c" = "1" ] && return 0; sleep 1; done; return 1; }
# poll node $1 until ARBITRARY count-query $2 == expected $3 within $4 seconds
# (the cntq analog of wait_cnt1: used for edge counts and predicated counts).
wait_cntq() { local id=$1 query=$2 want=$3 to=${4:-30} t c; for t in $(seq 1 "$to"); do c=$(cntq "$id" "$query"); [ "$c" = "$want" ] && return 0; sleep 1; done; return 1; }

# ---- root cause #6: restart re-apply must NOT duplicate the replicated row ----
# docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md root
# cause #6: a node that restarts re-applies the leader's committed log on top of
# its ALREADY-PERSISTED graph store. The GNC1 replicated-create payload carries
# no node id, so applyNodeCreatePayload mints a fresh generateTimeBasedId() on
# every apply -> the SAME committed create becomes a DUPLICATE node. Confirmed on
# real k8s as count=2 / v=[1,1] after a pod restart with its PVC intact.
#
# `wait_cnt1` short-circuits on the FIRST count==1 sample, so it cannot see a
# subsequent jump to 2. This helper asserts the count is EXACTLY 1 on EVERY node
# AND holds steady at 1 (never 2) across several consecutive samples — RED by
# construction against the unfixed binary, which duplicates on the re-apply.
# $1 = label of the seeded row.
assert_no_duplicate() {
  local lbl=$1 id c t bad=0
  for id in $NS_NODES; do
    # The row must already be present (assert_cluster_healthy waited for ==1).
    for t in $(seq 1 6); do
      c=$(cnt $id $lbl)
      if [ "$c" != "1" ]; then
        fail "root-cause-#6 node$id has count=$c for $lbl (expected EXACTLY 1) — restart re-applied the committed create and duplicated the row"
        bad=1; break
      fi
      sleep 1
    done
  done
  [ "$bad" = "0" ] && echo "  PASS no-dup: $lbl count is EXACTLY 1 on all 3 nodes after restart (no re-apply duplicate)"
}

# Generic restart-idempotency assertion for the NEW replicable mutation types
# (edge create / DETACH DELETE / MERGE / MATCH...SET). Like assert_no_duplicate
# but for an ARBITRARY count-query and an arbitrary expected value: asserts the
# count is EXACTLY $want on EVERY node AND holds steady at $want (never drifts)
# across several consecutive samples — so a durable-log re-apply that duplicates
# an edge (want 1 -> 2), resurrects a deleted row (want 0 -> 1), double-applies a
# MERGE (want 1 -> 2), or loses a replicated SET (predicate want 1 -> 0) is caught.
#   $1 = phase/probe tag (for the PASS/FAIL line)
#   $2 = count-query (projects a single integer `AS c`)
#   $3 = expected steady value
#   $4 = human description of what is being counted (for the PASS/FAIL line)
assert_count_steady() {
  local tag=$1 query=$2 want=$3 desc=$4 id c t bad=0
  for id in $NS_NODES; do
    for t in $(seq 1 6); do
      c=$(cntq "$id" "$query")
      if [ "$c" != "$want" ]; then
        fail "$tag node$id has $desc=$c (expected EXACTLY $want) after restart re-applied the committed log — durable-log re-apply corrupted the replicated mutation"
        bad=1; break
      fi
      sleep 1
    done
  done
  [ "$bad" = "0" ] && echo "  PASS $tag: $desc is EXACTLY $want on all 3 nodes after restart (no re-apply corruption)"
}

# Fully terminate node $1 and WAIT until its process has actually exited, so its
# FileStorage exclusive `.lock` flock (under {data_dir}/raft) is released before
# any replacement starts on the SAME data-dir. The OS releases an flock the
# instant the holder exits (even on SIGKILL), so reaping is what frees the lock.
#
# This models a real k8s pod restart: the kubelet SIGKILLs a pod that does not
# exit within terminationGracePeriodSeconds, and a StatefulSet's RWO PVC is only
# (re)mounted onto the replacement pod once the old pod has FULLY terminated — so
# a same-PVC restart never races a still-live writer. geode's SIGTERM shutdown
# can hang (separate, pre-existing liveness-kill / idle-spin bug: the log shows
# "thread-pool deinit timed out" while the process keeps spinning); without this
# reap that lingering process would still hold the flock and the replacement
# would (correctly) refuse to start with RaftStorageDirLocked. Reaping reproduces
# the k8s termination ordering so M4 actually exercises durable FileStorage
# reload rather than a same-host two-writers race the product rightly forbids.
kill_and_reap() {
  local id=$1 t pat="geode serve .*--data-dir $WORK/data$id "
  # SIGTERM first (graceful flush attempt), then give it a few seconds.
  [ -n "${PID[$id]:-}" ] && $SUDO kill "${PID[$id]}" 2>/dev/null
  for t in $(seq 1 5); do pgrep -f "$pat" >/dev/null 2>&1 || break; sleep 1; done
  # Force-kill any survivor (geode + its sudo wrappers); SIGKILL is uncatchable,
  # so the kernel reaps it and releases the flock. Then WAIT until truly gone.
  $SUDO pkill -9 -f "$pat" 2>/dev/null
  for t in $(seq 1 15); do pgrep -f "$pat" >/dev/null 2>&1 || break; sleep 1; done
  PID[$id]=""
}

# Restart node $1 IN PLACE (keep its data-dir / persisted store), modelling a
# k8s pod restart where the PVC follows the pod. The restarted node re-applies
# the leader's committed log on top of its persisted store — the exact trigger
# for the root-cause-#6 duplicate — and (with the FileStorage fix) reloads its
# durable raft hard-state + log. The prior process is fully reaped first so its
# FileStorage flock is released (see kill_and_reap). (reschedule_node wipes the
# data-dir to model a move to a NEW node; this one deliberately does NOT.)
restart_in_place() {
  local id=$1
  kill_and_reap "$id"
  start_node $id
  echo "  restarted node$id in place (data-dir preserved, prior process reaped -> re-applies committed log)"
}

run_phase() { case " $PHASES " in *" $1 "*) return 0;; *) return 1;; esac; }

# ---- raft hard-state + log DURABILITY on disk (FileStorage active) -----------
# Follow-up to root cause #6 / fix design /tmp/raft-filestorage-design.md: the
# live cluster RaftNode must back the embedded raft library with the crash-safe
# raft_lib.FileStorage (rooted at {data_dir}/raft) instead of InMemoryStorage,
# so currentTerm/votedFor + the raft log survive a process restart. FileStorage's
# on-disk layout is {data_dir}/raft/hard_state (20B term/votedFor/crc) and
# {data_dir}/raft/entries.wal (the raft log WAL).
#
# This asserts those files EXIST for at least one running node — directly
# refuting the bug report's "no raft_log.bin / no raft log file present".
# RED by construction against the UNFIXED binary: InMemoryStorage writes nothing
# under {data_dir}/raft, so neither file ever appears. GREEN once FileStorage is
# wired. (Checks every node, passes if ANY one has both files — a node must have
# advanced its hard-state at least once, which it does as soon as it joins.)
assert_raft_state_persisted() {
  local tag=$1 id found=0
  for id in $NS_NODES; do
    [ -n "${PID[$id]:-}" ] || continue
    if [ -f "$WORK/data$id/raft/hard_state" ] && [ -f "$WORK/data$id/raft/entries.wal" ]; then
      echo "  PASS $tag: node$id persisted raft FileStorage on disk ($WORK/data$id/raft/{hard_state,entries.wal})"
      found=1
      break
    fi
  done
  [ "$found" = "0" ] && fail "$tag no node has {data_dir}/raft/hard_state AND entries.wal on disk — raft is still InMemoryStorage (hard-state + log NOT durable across restart)"
}

# Reschedule node $1 to a NEW IP, modelling a k8s pod reschedule:
#  - kill it, flush its old IP, bring it up on the toggled prefix (.1X<->.2X),
#  - point DNS geode-$1 at the new IP,
#  - wipe its data-dir (local-path PVC does not follow to a new node => fresh),
#  - and DETERMINISTICALLY silent-blackhole its OLD IP in every surviving peer's
#    netns via a bogus permanent ARP entry: a stale cached QUIC connection now
#    sends to a nonexistent MAC, the bridge floods+drops it (no host, no ICMP,
#    NO send error) — exactly the silent blackhole a departed pod IP becomes in
#    k8s. The existing evict-on-send-error path therefore CANNOT fire; only a
#    liveness/heartbeat-driven re-resolve can recover the peer. That is the
#    contract under test.
reschedule_node() {
  local id=$1 oldpfx="${IPLAST[$id]:-1}" newpfx oldip o
  newpfx=2; [ "$oldpfx" = "2" ] && newpfx=1
  oldip="$SUBNET.$oldpfx$id"
  [ -n "${PID[$id]:-}" ] && $SUDO kill "${PID[$id]}" 2>/dev/null
  PID[$id]=""; sleep 3
  for o in $NS_NODES; do
    [ "$o" = "$id" ] && continue
    $SUDO ip netns exec gt$o ip neigh replace "$oldip" lladdr 02:00:00:00:00:ee nud permanent dev vtp$o 2>/dev/null
  done
  assign_ip $id "$newpfx"
  write_zone
  rm -rf "$WORK/data$id"
  start_node $id
  echo "  rescheduled node$id: $oldip -> $(cur_ip $id) (old IP blackholed in surviving peers)"
}

# Assert the whole cluster reaches SUSTAINED health: exactly one leader and ZERO
# candidates held steady for several consecutive seconds (a single instantaneous
# check races a flapping node), then a fresh write replicates to ALL three nodes.
# A degraded 2/3 cluster (one node permanently stuck `candidate` because survivors
# never re-resolved its new IP) never accumulates the consecutive-clean window ->
# RED. $1 = label prefix for the probe.
assert_cluster_healthy() {
  local tag=$1 lid id c ok=1 nlead ncand t stable=0 stable_needed=${STABLE_SECS:-8}
  for t in $(seq 1 "${HEALTH_WAIT:-70}"); do
    nlead=0; ncand=0
    for id in $NS_NODES; do
      case "$(roleof $id)" in leader) nlead=$((nlead+1));; candidate) ncand=$((ncand+1));; esac
    done
    if [ "$nlead" = "1" ] && [ "$ncand" = "0" ]; then stable=$((stable+1)); else stable=0; fi
    [ "$stable" -ge "$stable_needed" ] && break
    sleep 1
  done
  if [ "$stable" -lt "$stable_needed" ]; then
    fail "$tag cluster never reached SUSTAINED health (1 leader / 0 candidates for ${stable_needed}s) — quorum could not re-form across the IP change; last: $(for id in $NS_NODES; do echo -n "n$id=$(roleof $id):$(termof $id) "; done)"
    return
  fi
  lid=$(leaderof)
  q "$lid" "CREATE (:${tag}w {v:1})" 20 >/dev/null
  for id in $NS_NODES; do
    if wait_cnt1 $id ${tag}w 40; then :; else c=$(cnt $id ${tag}w); fail "$tag node$id did not get ${tag}w (count=$c) — replication did not reach it"; ok=0; fi
  done
  [ "$ok" = "1" ] && echo "  PASS $tag: sustained 1 leader / 0 candidates + write replicated to all 3"
}

# =============================================================================
# M1: staggered start — a late node must join as follower and replicate.
# =============================================================================
if run_phase M1; then
  echo "== M1: staggered start (node 3 joins late) =="
  start_node 1; start_node 2
  LID=$(wait_leader 30) || { fail "M1 no leader among nodes 1,2 in 30s"; for id in 1 2; do echo "  node$id: $(laststate $id)"; done; }
  if [ -n "${LID:-}" ]; then
    echo "  2-node leader=node$LID term=$(termof $LID)"
    q "$LID" 'CREATE (:M1pre {v:1})' 20 >/dev/null; sleep 3
    # start the late node
    echo "  starting late node 3..."
    start_node 3
    if wait_state 3 follower 40; then
      echo "  node3 reached follower term=$(termof 3)"
      # backfill of the pre-join write must reach node 3
      wait_cnt1 3 M1pre 30 && echo "  PASS M1a: late node backfilled M1pre" || fail "M1a late node3 did NOT backfill M1pre (count=$(cnt 3 M1pre))"
      # a post-join write must replicate to node 3
      LID=$(wait_leader 15 || echo "$LID")
      q "$LID" 'CREATE (:M1post {v:2})' 20 >/dev/null
      wait_cnt1 3 M1post 30 && echo "  PASS M1b: post-join write replicated to late node3" || fail "M1b post-join write did NOT replicate to node3 (count=$(cnt 3 M1post))"
    else
      fail "M1 late node3 never became follower (state=$(roleof 3) term=$(termof 3)) — parked, never joined"
    fi
  fi
  # FileStorage durability check: by now nodes have elected + replicated, so at
  # least one has advanced + persisted its raft hard-state to disk. RED against
  # the unfixed InMemoryStorage binary (no {data_dir}/raft files exist).
  assert_raft_state_persisted M1
  echo "  M1 states: $(for id in 1 2 3; do echo -n "n$id=[$(laststate $id | sed 's/\[raft\] node [0-9]* //')] "; done)"
fi

# =============================================================================
# M2: follower restarted on a NEW IP must rejoin and replicate.
#   Survivor peers hold a cached PeerConnection to the follower's OLD IP; the
#   bug is they never re-resolve the FQDN to the new IP -> follower isolated.
# =============================================================================
if run_phase M2; then
  echo "== M2: follower restart with NEW IP =="
  # Ensure a full 3-node cluster is up (M1 may not have run).
  for id in $NS_NODES; do [ -n "${PID[$id]:-}" ] || start_node $id; done
  LID=$(wait_leader 40) || fail "M2 no leader for 3-node cluster in 40s"
  if [ -n "${LID:-}" ]; then
    # pick a follower != leader
    FOLL=""; for id in $NS_NODES; do [ "$id" != "$LID" ] && { FOLL=$id; break; }; done
    echo "  leader=node$LID; rescheduling follower node$FOLL onto a new IP"
    reschedule_node "$FOLL"
    if wait_state $FOLL follower 45; then
      echo "  node$FOLL reached follower term=$(termof $FOLL) at new IP"
    else
      fail "M2 rescheduled follower node$FOLL never rejoined (state=$(roleof $FOLL) term=$(termof $FOLL)) — survivors never re-resolved its new IP"
    fi
    assert_cluster_healthy M2
  fi
  echo "  M2 states: $(for id in 1 2 3; do echo -n "n$id=[$(laststate $id | sed 's/\[raft\] node [0-9]* //')] "; done)"
fi

# =============================================================================
# M3: leader restarted on a NEW IP -> a single new leader must re-elect within
#   the election budget (NOT 80s+) and replication must resume on all 3.
# =============================================================================
if run_phase M3; then
  echo "== M3: leader restart with NEW IP =="
  for id in $NS_NODES; do [ -n "${PID[$id]:-}" ] || start_node $id; done
  LID=$(wait_leader 40) || fail "M3 no leader for 3-node cluster in 40s"
  if [ -n "${LID:-}" ]; then
    echo "  current leader=node$LID; rescheduling IT onto a new IP (the 80s+ all-candidates hang)"
    reschedule_node "$LID"
    # a single new leader must emerge across ALL three within the election budget
    assert_cluster_healthy M3
  fi
  echo "  M3 states: $(for id in 1 2 3; do echo -n "n$id=[$(laststate $id | sed 's/\[raft\] node [0-9]* //')] "; done)"
fi

# =============================================================================
# M4: in-place node restart (PVC preserved) must NOT duplicate the replicated
#   row. This reproduces root cause #6 of
#   docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md:
#   the restarted node re-applies the leader's committed log on top of its
#   already-persisted graph store; on the unfixed binary the GNC1 create is
#   re-minted with a fresh id => the seeded row becomes count=2 (v=[1,1] on k8s).
#   RED by construction against the unfixed binary.
# =============================================================================
if run_phase M4; then
  echo "== M4: in-place restart must not duplicate the replicated row (root cause #6) =="
  for id in $NS_NODES; do [ -n "${PID[$id]:-}" ] || start_node $id; done
  LID=$(wait_leader 40) || fail "M4 no leader for 3-node cluster in 40s"
  if [ -n "${LID:-}" ]; then
    # Seed exactly one row and confirm it replicated to all 3 BEFORE the restart.
    q "$LID" 'CREATE (:M4dup {v:1})' 20 >/dev/null
    DUP_OK=1
    for id in $NS_NODES; do
      wait_cnt1 $id M4dup 40 || { fail "M4 seed CREATE (:M4dup) did not replicate to node$id (count=$(cnt $id M4dup))"; DUP_OK=0; }
    done
    if [ "$DUP_OK" = "1" ]; then
      # Restart a follower IN PLACE (PVC preserved): it re-applies the committed
      # M4dup create on top of its persisted store. Pick a follower != leader.
      RID=""; for id in $NS_NODES; do [ "$id" != "$LID" ] && { RID=$id; break; }; done
      echo "  leader=node$LID; restarting follower node$RID in place (PVC preserved)"
      restart_in_place "$RID"
      wait_state "$RID" follower 45 || fail "M4 restarted node$RID never rejoined (state=$(roleof $RID))"
      # After the restart + log re-apply settles, the row must be EXACTLY 1 on
      # EVERY node — count=2 anywhere is the re-apply duplicate (root cause #6).
      sleep 5
      assert_no_duplicate M4dup
    fi
  fi
  echo "  M4 states: $(for id in 1 2 3; do echo -n "n$id=[$(laststate $id | sed 's/\[raft\] node [0-9]* //')] "; done)"
fi

# =============================================================================
# M5: in-place restart must NOT duplicate a replicated EDGE CREATE.
#   Slice A made `CREATE (a)-[:T]->(b)` replicable through raft (commit c612711c)
#   with stable-id / raft-index-keyed idempotent apply. M4 proves a plain node
#   CREATE survives an in-place restart's durable-log re-apply without dup; this
#   proves the SAME for the edge path: the two endpoint nodes AND the edge must
#   each stay EXACTLY 1 after a follower re-applies the committed log on top of
#   its persisted store. An unfixed edge-apply (fresh ids / re-inserted edge) would
#   surface here as node count 2 or edge count 2 on the restarted follower.
# =============================================================================
if run_phase M5; then
  echo "== M5: in-place restart must not duplicate a replicated edge CREATE =="
  for id in $NS_NODES; do [ -n "${PID[$id]:-}" ] || start_node $id; done
  LID=$(wait_leader 40) || fail "M5 no leader for 3-node cluster in 40s"
  if [ -n "${LID:-}" ]; then
    # Seed one edge (two labelled endpoint nodes + one :M5L edge) and confirm BOTH
    # node labels AND the edge converged on all 3 BEFORE the restart.
    q "$LID" 'CREATE (a:M5A {k:1})-[:M5L]->(b:M5B {k:2})' 20 >/dev/null
    M5_OK=1
    M5_EDGEQ='MATCH ()-[r:M5L]->() RETURN count(r) AS c'
    for id in $NS_NODES; do
      wait_cnt1 $id M5A 40 || { fail "M5 seed did not replicate M5A to node$id (count=$(cnt $id M5A))"; M5_OK=0; }
      wait_cnt1 $id M5B 40 || { fail "M5 seed did not replicate M5B to node$id (count=$(cnt $id M5B))"; M5_OK=0; }
      wait_cntq $id "$M5_EDGEQ" 1 40 || { fail "M5 seed edge :M5L did not replicate to node$id (count=$(cntq $id "$M5_EDGEQ"))"; M5_OK=0; }
    done
    if [ "$M5_OK" = "1" ]; then
      # Restart a follower IN PLACE (PVC preserved): it re-applies the committed
      # edge-create on top of its persisted store. Pick a follower != leader.
      RID=""; for id in $NS_NODES; do [ "$id" != "$LID" ] && { RID=$id; break; }; done
      echo "  leader=node$LID; restarting follower node$RID in place (PVC preserved)"
      restart_in_place "$RID"
      wait_state "$RID" follower 45 || fail "M5 restarted node$RID never rejoined (state=$(roleof $RID))"
      sleep 5
      # Endpoint node counts AND the edge count must each stay EXACTLY 1 on all 3.
      assert_no_duplicate M5A
      assert_no_duplicate M5B
      assert_count_steady M5edge "$M5_EDGEQ" 1 "M5L edge count"
    fi
  fi
  echo "  M5 states: $(for id in 1 2 3; do echo -n "n$id=[$(laststate $id | sed 's/\[raft\] node [0-9]* //')] "; done)"
fi

# =============================================================================
# M6: a DETACH-DELETEd row must NOT resurrect after an in-place restart.
#   Slice B made DELETE / DETACH DELETE replicable through raft (commit e6d91f56).
#   The danger after a delete: the restarted follower re-applies the committed log
#   from the beginning — the CREATE entry is still in the log. If the delete entry
#   were not also re-applied idempotently (or the create were re-minted), the
#   deleted node would reappear as count=1. The contract: count stays 0 everywhere.
# =============================================================================
if run_phase M6; then
  echo "== M6: in-place restart must not resurrect a DETACH-DELETEd row =="
  for id in $NS_NODES; do [ -n "${PID[$id]:-}" ] || start_node $id; done
  LID=$(wait_leader 40) || fail "M6 no leader for 3-node cluster in 40s"
  if [ -n "${LID:-}" ]; then
    # Seed one row, converge to 1 on all 3, then DETACH DELETE it and converge to 0.
    q "$LID" 'CREATE (:M6 {k:1})' 20 >/dev/null
    M6_OK=1
    for id in $NS_NODES; do
      wait_cnt1 $id M6 40 || { fail "M6 seed CREATE (:M6) did not replicate to node$id (count=$(cnt $id M6))"; M6_OK=0; }
    done
    q "$LID" 'MATCH (n:M6) DETACH DELETE n' 20 >/dev/null
    for id in $NS_NODES; do
      wait_cntq $id 'MATCH (n:M6) RETURN count(n) AS c' 0 40 || { fail "M6 DETACH DELETE did not converge to 0 on node$id (count=$(cnt $id M6))"; M6_OK=0; }
    done
    if [ "$M6_OK" = "1" ]; then
      # Restart a follower IN PLACE: it re-applies the full committed log (create
      # THEN delete) on top of its persisted store. The row must stay deleted.
      RID=""; for id in $NS_NODES; do [ "$id" != "$LID" ] && { RID=$id; break; }; done
      echo "  leader=node$LID; restarting follower node$RID in place (PVC preserved)"
      restart_in_place "$RID"
      wait_state "$RID" follower 45 || fail "M6 restarted node$RID never rejoined (state=$(roleof $RID))"
      sleep 5
      # count MUST stay 0 on all 3 — count=1 anywhere is the deleted row resurrecting.
      assert_count_steady M6del 'MATCH (n:M6) RETURN count(n) AS c' 0 "M6 node count"
    fi
  fi
  echo "  M6 states: $(for id in 1 2 3; do echo -n "n$id=[$(laststate $id | sed 's/\[raft\] node [0-9]* //')] "; done)"
fi

# =============================================================================
# M7: a MERGE'd row stays EXACTLY 1 (no double-apply) and a replicated MATCH...SET
#   property survives an in-place restart.
#   Slice C made MERGE replicable + idempotent (commit 4aec072c); Slice D made
#   MATCH...SET replicable (commit ed75e2ce). The danger after restart: re-applying
#   the committed MERGE entries could double-insert (count 2), or the re-applied
#   SET could be lost / re-applied with the wrong target (predicate count 0).
#   Contract: exactly 1 :M7 row, and exactly 1 row with v=42, on all 3 — before
#   AND after the durable-log re-apply.
# =============================================================================
if run_phase M7; then
  echo "== M7: in-place restart preserves MERGE idempotency + a replicated SET =="
  for id in $NS_NODES; do [ -n "${PID[$id]:-}" ] || start_node $id; done
  LID=$(wait_leader 40) || fail "M7 no leader for 3-node cluster in 40s"
  if [ -n "${LID:-}" ]; then
    # MERGE the SAME key twice on the leader: match-or-create must yield exactly 1.
    q "$LID" 'MERGE (n:M7 {k:1})' 20 >/dev/null
    q "$LID" 'MERGE (n:M7 {k:1})' 20 >/dev/null
    M7_OK=1
    for id in $NS_NODES; do
      wait_cnt1 $id M7 40 || { fail "M7 double MERGE did not converge to 1 on node$id (count=$(cnt $id M7))"; M7_OK=0; }
    done
    # Then SET v=42 on the leader and confirm the predicate converges on all 3.
    M7_SETQ='MATCH (n:M7) WHERE n.v = 42 RETURN count(n) AS c'
    q "$LID" 'MATCH (n:M7) SET n.v = 42' 20 >/dev/null
    for id in $NS_NODES; do
      wait_cntq $id "$M7_SETQ" 1 40 || { fail "M7 MATCH...SET v=42 did not replicate to node$id (count=$(cntq $id "$M7_SETQ"))"; M7_OK=0; }
    done
    if [ "$M7_OK" = "1" ]; then
      # Restart a follower IN PLACE: it re-applies the committed MERGE x2 + SET.
      RID=""; for id in $NS_NODES; do [ "$id" != "$LID" ] && { RID=$id; break; }; done
      echo "  leader=node$LID; restarting follower node$RID in place (PVC preserved)"
      restart_in_place "$RID"
      wait_state "$RID" follower 45 || fail "M7 restarted node$RID never rejoined (state=$(roleof $RID))"
      sleep 5
      # Still EXACTLY 1 :M7 row (MERGE not double-applied) AND exactly 1 with v=42
      # (the replicated SET survived the re-apply) on all 3.
      assert_no_duplicate M7
      assert_count_steady M7set "$M7_SETQ" 1 "M7 v=42 count"
    fi
  fi
  echo "  M7 states: $(for id in 1 2 3; do echo -n "n$id=[$(laststate $id | sed 's/\[raft\] node [0-9]* //')] "; done)"
fi

# =============================================================================
# M8: a MATCH...CREATE edge between two already-replicated nodes must replicate
#   to all 3, fail closed on a follower, and stay EXACTLY 1 across an in-place
#   restart. Closes the 2026-06-10 silent-divergence hole in
#   docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md:
#   `MATCH (a),(b) CREATE (a)-[:R]->(b)` previously bypassed the cluster
#   write-gate on EVERY node (leader-only or follower-only edge, status 00000).
#   The fix routes it through the GNC2 slice with MATCH-resolved absolute node
#   ids (followers never re-run the MATCH); a follower must reject with
#   ClusterNotLeader. In-process analog: tests/test_cluster_replicable_mutations.zig
#   Tests 5+6. The restart leg re-applies the committed GNC2 entry on top of the
#   persisted store — the edge (and both endpoints) must stay EXACTLY 1.
# =============================================================================
if run_phase M8; then
  echo "== M8: MATCH...CREATE edge replicates, fails closed on follower, survives restart =="
  for id in $NS_NODES; do [ -n "${PID[$id]:-}" ] || start_node $id; done
  LID=$(wait_leader 40) || fail "M8 no leader for 3-node cluster in 40s"
  if [ -n "${LID:-}" ]; then
    # Seed the two endpoint nodes and converge BOTH on all 3 BEFORE the edge
    # write (the bug-doc repro pre-seeded its :MT endpoints the same way).
    q "$LID" 'CREATE (:M8A {id:1})' 20 >/dev/null
    q "$LID" 'CREATE (:M8B {id:2})' 20 >/dev/null
    M8_OK=1
    for id in $NS_NODES; do
      wait_cnt1 $id M8A 40 || { fail "M8 seed CREATE (:M8A) did not replicate to node$id (count=$(cnt $id M8A))"; M8_OK=0; }
      wait_cnt1 $id M8B 40 || { fail "M8 seed CREATE (:M8B) did not replicate to node$id (count=$(cnt $id M8B))"; M8_OK=0; }
    done
    M8_EDGEQ='MATCH (:M8A)-[r:M8L]->(:M8B) RETURN count(r) AS c'
    if [ "$M8_OK" = "1" ]; then
      # The exact divergence shape from the bug doc, on the LEADER: must now
      # propose through raft (GNC2, absolute endpoint ids) and read back 1
      # everywhere — NOT leader-only.
      q "$LID" 'MATCH (a:M8A {id:1}), (b:M8B {id:2}) CREATE (a)-[:M8L]->(b)' 20 >/dev/null
      for id in $NS_NODES; do
        wait_cntq $id "$M8_EDGEQ" 1 40 || { fail "M8 MATCH...CREATE edge :M8L did not replicate to node$id (count=$(cntq $id "$M8_EDGEQ")) — leader-local silent divergence"; M8_OK=0; }
      done
    fi
    # Follower fail-closed: the SAME shape sent to a follower must be refused
    # with ClusterNotLeader (it previously applied follower-locally with 00000),
    # and the cluster-wide edge count must stay EXACTLY 1 (no follower-only edge).
    FOLL=""; for id in $NS_NODES; do [ "$id" != "$LID" ] && { FOLL=$id; break; }; done
    out=$(q "$FOLL" 'MATCH (a:M8A {id:1}), (b:M8B {id:2}) CREATE (a)-[:M8LF]->(b)' 20)
    if echo "$out" | grep -q "ClusterNotLeader"; then
      echo "  PASS M8 fail-closed: follower node$FOLL rejected MATCH...CREATE with ClusterNotLeader"
    else
      fail "M8 follower node$FOLL did NOT reject MATCH...CREATE with ClusterNotLeader: $(echo "$out" | tail -1 | cut -c1-160)"
    fi
    sleep 3
    for id in $NS_NODES; do
      c=$(cntq $id 'MATCH (:M8A)-[r:M8LF]->(:M8B) RETURN count(r) AS c')
      [ "$c" = "0" ] || fail "M8 node$id has M8LF=$c (want 0) — follower-directed MATCH...CREATE leaked an edge"
    done
    if [ "$M8_OK" = "1" ]; then
      # Restart a follower IN PLACE (PVC preserved): it re-applies the committed
      # GNC2 edge entry on top of its persisted store. Edge + endpoints must
      # each stay EXACTLY 1 on all 3 (no re-apply duplicate).
      RID=""; for id in $NS_NODES; do [ "$id" != "$LID" ] && { RID=$id; break; }; done
      echo "  leader=node$LID; restarting follower node$RID in place (PVC preserved)"
      restart_in_place "$RID"
      wait_state "$RID" follower 45 || fail "M8 restarted node$RID never rejoined (state=$(roleof $RID))"
      sleep 5
      assert_no_duplicate M8A
      assert_no_duplicate M8B
      assert_count_steady M8edge "$M8_EDGEQ" 1 "M8L edge count"
    fi
  fi
  echo "  M8 states: $(for id in 1 2 3; do echo -n "n$id=[$(laststate $id | sed 's/\[raft\] node [0-9]* //')] "; done)"
fi

echo
if [ "$FAILED" = "0" ]; then echo "RESULT: PASS"; exit 0; else echo "RESULT: FAIL"; exit 1; fi
