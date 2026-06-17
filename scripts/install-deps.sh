#!/usr/bin/env bash
set -euo pipefail

# Geode Dependency Installation Script
# Installs all required system dependencies for building Geode
# Note: Geode uses a vendored QUIC library (build.zig.zon) - libmsquic is NOT required

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Geode Dependency Installation ==="
echo "Project root: $PROJECT_ROOT"
echo ""

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: This script should not be run as root"
    echo "Please run as a regular user with sudo access"
    exit 1
fi

# Update package lists
echo "→ Updating package lists..."
sudo apt-get update

# Install prerequisite packages
# Note: software-properties-common (for add-apt-repository) is intentionally
# omitted — no script in this repo adds PPAs anymore (libmsquic was the only
# user, and it's gone per Issue #381). The package is also not present in
# default Debian trixie repos, which broke `make deps` on Debian 13.
echo "→ Installing prerequisite packages..."
sudo apt-get install -y \
    wget \
    apt-transport-https \
    build-essential \
    git \
    curl

# Get OS version for informational purposes
source /etc/os-release
echo "→ Detected OS: $PRETTY_NAME"

# CANARY: REQ=REQ-BUILD-DEPS-001; FEATURE="DepsFallback"; ASPECT=UbuntuVersionFallback; STATUS=IMPL; OWNER=build; UPDATED=2026-02-10
# Issue #381: libmsquic removed as a dependency - Geode uses vendored QUIC (build.zig.zon)
# The Microsoft QUIC library (libmsquic) is no longer needed because:
#   1. build.zig does not link against it
#   2. build.zig.zon declares a vendored QUIC dependency from gitlab.com/devnw/zig/quic
#   3. The libmsquic package is unavailable on newer Ubuntu versions (e.g., 25.10)
echo "→ QUIC: using vendored implementation (libmsquic not required)"

# Install Zig if not present
if ! command -v zig &> /dev/null; then
    echo "→ Installing Zig via zvm (https://zig.sh)..."
    GEODE_ZIG_VERSION="${GEODE_ZIG_VERSION:-0.15.2}"
    sudo apt-get install -y jq xz-utils tar
    curl -fsSL https://zig.sh/install.sh | bash
    export PATH="$HOME/bin:$PATH"
    eval "$(zvm env)"
    zvm install "$GEODE_ZIG_VERSION"
    zvm use "$GEODE_ZIG_VERSION"
    echo "✓ Zig version: $(zig version)"
else
    ZIG_VERSION=$(zig version)
    echo "✓ Zig version: $ZIG_VERSION"
fi

# Install Rust if not present (for Rust client)
if ! command -v rustc &> /dev/null; then
    echo "→ Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
    echo "✓ Rust installed"
else
    RUST_VERSION=$(rustc --version)
    echo "✓ Rust version: $RUST_VERSION"
fi

# Install Python dependencies
if ! command -v python3 &> /dev/null; then
    echo "→ Installing Python 3..."
    sudo apt-get install -y python3 python3-pip python3-venv
else
    PYTHON_VERSION=$(python3 --version)
    echo "✓ Python version: $PYTHON_VERSION"
fi

# Install Go if not present (for Go client)
if ! command -v go &> /dev/null; then
    echo "→ Installing Go..."
    echo "⚠ Go not found. Please install Go 1.21+ from https://go.dev/dl/"
else
    GO_VERSION=$(go version)
    echo "✓ Go version: $GO_VERSION"
fi

# Install OpenSSL development files (required for building)
echo "→ Installing OpenSSL development files..."
sudo apt-get install -y libssl-dev

# Install performance and diagnostic tooling.
#
# These are not required to BUILD Geode, but they are required to
# diagnose and tune it under heavy load (the kind of work the
# edges_contains cascade investigation needed). Keeping them in
# `make deps` means a fresh dev environment is one command away
# from being able to capture stack traces, sample-profile under
# load, and inspect system-call / lock behaviour.
echo ""
echo "=== Installing performance + diagnostic tooling ==="
echo ""

# Core debugging + tracing.
#   gdb        — stack capture during repros (`gdb -p <pid> -batch -ex 'thread apply all bt'`)
#   strace     — system call tracing (`strace -c -e fsync` for fsync amortisation)
#   ltrace     — library call tracing
#   valgrind   — memory error / leak detection (`valgrind --tool=memcheck`)
#   lsof       — open file descriptor inspection (cross-check FD counts under load)
#   sysstat    — sar / iostat / pidstat for time-series system metrics
#   tcpdump    — network capture for QUIC packet-level analysis
#   numactl    — bind to CPU/memory nodes for reproducible perf benchmarks
echo "→ Installing core debug tools..."
sudo apt-get install -y \
    gdb \
    strace \
    ltrace \
    valgrind \
    lsof \
    sysstat \
    tcpdump \
    numactl

# Linux perf — sampling profiler (the primary tool for the GAP-0900 write-path
# serialization probe). Package naming differs by distro family:
#   • Ubuntu:      linux-tools-$(uname -r) + linux-tools-generic + linux-tools-common
#   • Debian/Kali: linux-perf (metapackage) — ships the `perf` wrapper + versioned perf
# Try each in turn; success = the `perf` command becomes available. Don't let a
# missing package abort the run (set -e) — guard every attempt with `|| true`.
echo "→ Installing linux perf tools..."
KREL=$(uname -r 2>/dev/null || true)
[ -n "$KREL" ] && sudo apt-get install -y "linux-tools-$KREL" linux-tools-generic linux-tools-common 2>/dev/null || true
command -v perf >/dev/null 2>&1 || sudo apt-get install -y linux-perf 2>/dev/null || true
# Debian/Kali sometimes ships the versioned package as linux-perf-<base> (e.g. 6.12).
command -v perf >/dev/null 2>&1 || sudo apt-get install -y "linux-perf-${KREL%%-*}" 2>/dev/null || true
if command -v perf >/dev/null 2>&1; then
    echo "✓ perf available: $(perf --version 2>/dev/null | head -1)"
else
    echo "⚠ perf not installed automatically. Debian/Kali: 'sudo apt-get install linux-perf'; Ubuntu: 'sudo apt-get install linux-tools-\$(uname -r)'"
fi

# bpftrace + bcc — eBPF tracing, including OFF-CPU profiling. For a single-thread
# serialization bottleneck (GAP-0900) the on-CPU perf profile shows the hot serial
# function, while bcc's offcputime/offwaketime show where the OTHER threads BLOCK
# (lock wait, fsync wait) — together they pinpoint the serialization. bcc needs
# matching kernel headers.
echo "→ Installing bpftrace + bcc (eBPF / off-CPU tracing)..."
sudo apt-get install -y bpftrace 2>/dev/null \
    || echo "⚠ bpftrace not available on this distro release — perf + gdb + strace cover most needs"
sudo apt-get install -y bpfcc-tools "linux-headers-$KREL" 2>/dev/null \
    || sudo apt-get install -y bpfcc-tools 2>/dev/null \
    || echo "⚠ bpfcc-tools/headers not available — bpftrace covers most eBPF needs"

# Configure QUIC performance optimizations
echo ""
echo "=== Configuring QUIC Performance Optimizations ==="
echo ""

# Increase UDP buffer sizes for high-throughput QUIC transfers
RMEM_MAX=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "0")
WMEM_MAX=$(sysctl -n net.core.wmem_max 2>/dev/null || echo "0")

if [ "$RMEM_MAX" -lt 7340032 ] 2>/dev/null; then
    echo "→ Increasing net.core.rmem_max to 7340032 (7MB)..."
    sudo sysctl -w net.core.rmem_max=7340032
    echo "✓ UDP receive buffer max increased"
else
    echo "✓ net.core.rmem_max already >= 7MB ($RMEM_MAX)"
fi

if [ "$WMEM_MAX" -lt 7340032 ] 2>/dev/null; then
    echo "→ Increasing net.core.wmem_max to 7340032 (7MB)..."
    sudo sysctl -w net.core.wmem_max=7340032
    echo "✓ UDP send buffer max increased"
else
    echo "✓ net.core.wmem_max already >= 7MB ($WMEM_MAX)"
fi

# Persist sysctl settings
SYSCTL_CONF="/etc/sysctl.d/99-geode-quic.conf"
if [ ! -f "$SYSCTL_CONF" ]; then
    echo "→ Creating persistent sysctl configuration..."
    sudo tee "$SYSCTL_CONF" > /dev/null << 'EOF'
# Geode QUIC Performance Optimizations
# Increase UDP buffer sizes for high-throughput QUIC transfers
# These settings allow quic-go to use larger buffers, improving performance
# on high-bandwidth connections.

# Maximum receive socket buffer size (7MB)
net.core.rmem_max=7340032

# Maximum send socket buffer size (7MB)
net.core.wmem_max=7340032
EOF
    echo "✓ Persistent sysctl configuration created at $SYSCTL_CONF"
else
    echo "✓ Persistent sysctl configuration already exists"
fi

# Enable userspace profiling.
# Most distros default to kernel.perf_event_paranoid=2 (Debian/Kali often 3) and
# kernel.kptr_restrict=1, which block `perf record -p <pid>` from sampling even
# your OWN processes and from resolving kernel symbols. Lower them so local perf
# / off-CPU profiling works (needed for the GAP-0900 write-path serialization
# probe). These are dev-box tunables; they intentionally relax kernel hardening,
# so they live in their own clearly-named file you can delete to revert.
echo ""
echo "=== Enabling userspace profiling (perf) ==="
echo ""
PARANOID=$(sysctl -n kernel.perf_event_paranoid 2>/dev/null || echo 3)
if [ "${PARANOID:-3}" -gt 1 ] 2>/dev/null; then
    echo "→ Lowering kernel.perf_event_paranoid ${PARANOID}→1 (allow perf to sample processes)..."
    sudo sysctl -w kernel.perf_event_paranoid=1 || true
else
    echo "✓ kernel.perf_event_paranoid already <= 1 ($PARANOID)"
fi
echo "→ Setting kernel.kptr_restrict=0 (resolve kernel symbols in perf)..."
sudo sysctl -w kernel.kptr_restrict=0 2>/dev/null || true

PERF_CONF="/etc/sysctl.d/99-geode-perf.conf"
if [ ! -f "$PERF_CONF" ]; then
    echo "→ Persisting profiling sysctls to $PERF_CONF (delete this file to revert)..."
    sudo tee "$PERF_CONF" > /dev/null << 'EOF'
# Geode dev-box profiling tunables (created by scripts/install-deps.sh).
# Relaxes kernel restrictions so `perf record -p <pid>` and off-CPU tracing work
# for local performance debugging. DELETE this file to restore hardened defaults.
kernel.perf_event_paranoid=1
kernel.kptr_restrict=0
EOF
    echo "✓ Persistent profiling sysctls created at $PERF_CONF"
else
    echo "✓ Persistent profiling sysctls already exist"
fi

echo ""
echo "=== Dependency Installation Complete ==="
echo ""
echo "Installed components:"
echo "  • Build tools and prerequisites"
echo "  • OpenSSL development files"
echo "  • QUIC: vendored implementation (no system libmsquic needed)"
echo "  • Performance + diagnostic tools: gdb, strace, ltrace, valgrind,"
echo "    lsof, sysstat, tcpdump, numactl, perf (linux-tools/linux-perf),"
echo "    bpftrace, bpfcc-tools (off-CPU/eBPF) + kernel headers"
echo "  • Userspace profiling enabled: kernel.perf_event_paranoid=1,"
echo "    kernel.kptr_restrict=0 (persisted in /etc/sysctl.d/99-geode-perf.conf)"
echo ""
echo "Profiling the write-path serialization (GAP-0900):"
echo "  perf record -g -p \$(pgrep -n geode) -- sleep 20 && perf report"
echo "  /usr/sbin/offcputime-bpfcc -p \$(pgrep -n geode) 20   # where threads block"
echo ""
echo "QUIC Performance Optimizations:"
echo "  • UDP buffer sizes increased to 7MB (net.core.rmem_max, net.core.wmem_max)"
echo "  • Generic Segmentation Offload (GSO) enabled automatically on Linux 4.18+"
echo "  • Path MTU Discovery (DPLPMTUD) enabled by default"
echo ""
echo "Next steps:"
echo "  1. Run 'make build' to build Geode"
echo ""
