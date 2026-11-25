#!/usr/bin/env bash
# Fetch a cross-compilation OpenSSL 3.x prefix (headers + shared libraries) for
# one Zig target, so release builds can link the gRPC transport's TLS support.
#
# Why this exists
# ---------------
#   Zig does not search host system library paths for a non-native target, so
#   `-Denable-openssl=true` alone resolves `ssl`/`crypto` to "searched paths:
#   none" and the link fails. Every cross-compiled release binary therefore
#   shipped with TLS compiled out of `src/transport/grpc_tls.zig`, and
#   `serve --listen-grpc` refused to start with `error.TlsRequired`.
#
#   Rather than build OpenSSL from source per target, take the distro's own
#   prebuilt dev + runtime packages for that architecture and lay them out as a
#   `--search-prefix` root. Debian trixie for the glibc targets, Alpine v3.22
#   for the musl targets — both ship OpenSSL 3.5.x.
#
# Usage
# -----
#   scripts/ci/fetch-openssl-prefix.sh <zig-target> <outdir>
#
#   <zig-target>  one of: x86_64-linux-gnu  aarch64-linux-gnu
#                         x86_64-linux-musl aarch64-linux-musl
#   <outdir>      prefix root to create. Populated as:
#                     <outdir>/include/openssl/*.h
#                     <outdir>/lib/libssl.so[.3], libcrypto.so[.3]
#
#   Pass that <outdir> to `zig build --search-prefix <outdir>`, or point
#   `-Dopenssl-sysroot=<root>` at a directory containing one <zig-target>
#   subdirectory per target (build.zig derives <root>/<triple> itself).
#
# Reproducibility
# --------------
#   Package versions and sha256 checksums are pinned below. A checksum mismatch
#   is a hard failure — never "refresh" a checksum without also bumping the
#   version and re-verifying the resulting prefix builds.
set -euo pipefail

# This script runs as a GoReleaser before-hook, and the CI build-release job
# scopes OPENSSL_CONF=/usr/local/ssl/ssl/openssl.cnf (the validated FIPS
# provider config) onto the goreleaser invocation — which GoReleaser forwards
# to its hooks. Alpine's curl/openssl cannot load that provider and every TLS
# handshake then fails DETERMINISTICALLY with "curl: (35) Insufficient
# randomness" (v0.8.6 job 16156266534, v0.8.7 job 16172633085; retries cannot
# help). The FIPS config is only meant for the zig build lane, so drop it here.
unset OPENSSL_CONF OPENSSL_MODULES

TARGET="${1:-}"
OUTDIR="${2:-}"

if [[ -z "$TARGET" || -z "$OUTDIR" ]]; then
    echo "usage: $0 <zig-target> <outdir>" >&2
    echo "  zig-target: x86_64-linux-gnu | aarch64-linux-gnu | x86_64-linux-musl | aarch64-linux-musl" >&2
    exit 2
fi

# --- Pinned upstream package sets --------------------------------------------
#
# Debian trixie (13), OpenSSL 3.5.7-1~deb13u2 (3.5.6 was removed from the pool 2026-09-16). `libssl-dev` carries the headers
# and the `libssl.so`/`libcrypto.so` link-time symlinks; `libssl3t64` carries
# the `.so.3` runtime objects those symlinks point at.
# Fetched from snapshot.debian.org, which keeps every version ever published:
# deb.debian.org drops a version as soon as a newer security update lands
# (3.5.7-1~deb13u2 went 404 there on 2026-11-25), which broke every
# glibc cross-build until the pin was bumped. The timestamp is the archive
# run that first carried this version in the main pool; the sha256 pins
# below are unchanged and still enforced. Bump DEB_VERSION and the timestamp
# together (https://snapshot.debian.org/mr/binary/libssl-dev/<version>/binfiles?fileinfo=1).
DEB_SNAPSHOT="https://snapshot.debian.org/archive/debian/20260826T203905Z/pool/main/o/openssl"
DEB_VERSION="3.5.7-1~deb13u2"

# Alpine v3.22, OpenSSL 3.5.9-r2 (3.5.8-r0 and 3.5.9-r0 were removed from the mirror; cross-build 404s,
# GitLab job 17097029064 and GitHub job 139418568534). Alpine keeps only the newest build per branch and has no
# snapshot archive, so this pin rots whenever a rebuild lands: bump APK_VERSION and the six sha256s below. `openssl-dev` carries headers + link symlinks;
# `libssl3`/`libcrypto3` carry the runtime objects.
APK_MIRROR="https://dl-cdn.alpinelinux.org/alpine/v3.22/main"
APK_VERSION="3.5.9-r2"

# sha256 of each fetched artifact, keyed "<target>:<filename>".
declare -A CHECKSUMS=(
    ["x86_64-linux-gnu:libssl-dev_${DEB_VERSION}_amd64.deb"]="f245b646a4fe5beb31d6a387da9db3399e3b14a904efef1a23227ff5465a1d11"
    ["x86_64-linux-gnu:libssl3t64_${DEB_VERSION}_amd64.deb"]="916f7f40b34a06e6ebfaefcdab331bff458328411da672598f126a760472467d"
    ["aarch64-linux-gnu:libssl-dev_${DEB_VERSION}_arm64.deb"]="b81910e8728fab596158c8384d6aa101c8249c1769eb2d33c73643b2be7a0bcf"
    ["aarch64-linux-gnu:libssl3t64_${DEB_VERSION}_arm64.deb"]="ec131326aa9fa9ec934eca386bc7991f328fe383eaefd3e43bd8901a9199c5ae"
    ["x86_64-linux-musl:openssl-dev-${APK_VERSION}.apk"]="06262df9730a14154bde19b50beaa4f5d32c8733d258ae7c67cafebb7948a8b0"
    ["x86_64-linux-musl:libssl3-${APK_VERSION}.apk"]="678f241a05f34858762790eac31599def62e3963702d13c62b0aa4720681fea1"
    ["x86_64-linux-musl:libcrypto3-${APK_VERSION}.apk"]="931ac2f8cd696a47221b6317f650eb5e0ed5bf8f04d34ae7b9573027801d3544"
    ["aarch64-linux-musl:openssl-dev-${APK_VERSION}.apk"]="5252ea38a84d4d18f128eb2d12d01ebb2fd0882b96f4e6b5493c17d0ca5ae9ba"
    ["aarch64-linux-musl:libssl3-${APK_VERSION}.apk"]="7c8f76f087ef0cd74c15c1f64d575fd4e28e05c5db3a6343859b9d098676cb2d"
    ["aarch64-linux-musl:libcrypto3-${APK_VERSION}.apk"]="36392036421de3d71fc815ed771e9c2291bc45c7a336e9651e9dd87d408dee99"
)

case "$TARGET" in
x86_64-linux-gnu)
    FLAVOR=deb
    DEB_ARCH=amd64
    # Debian splits a handful of arch-dependent headers out of /usr/include
    # into a multiarch subdirectory; they must be merged back in (see below).
    DEB_TRIPLET=x86_64-linux-gnu
    ;;
aarch64-linux-gnu)
    FLAVOR=deb
    DEB_ARCH=arm64
    DEB_TRIPLET=aarch64-linux-gnu
    ;;
x86_64-linux-musl)
    FLAVOR=apk
    APK_ARCH=x86_64
    ;;
aarch64-linux-musl)
    FLAVOR=apk
    APK_ARCH=aarch64
    ;;
*)
    echo "error: unsupported target '$TARGET'" >&2
    echo "  riscv64-linux-gnu is deliberately absent: Zig 0.16 cannot @cImport" >&2
    echo "  libc headers for that target ('unsupported FLEN'), so OpenSSL stays" >&2
    echo "  off there and the binary is QUIC-only. See release/target_manifest.json." >&2
    echo "  macOS targets are cross-built on Linux without OpenSSL provisioning." >&2
    exit 2
    ;;
esac

need() { command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' is required" >&2; exit 1; }; }
need curl
need sha256sum
need tar

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Download into $WORK and verify against the pin. An unpinned entry (still
# holding a __PIN_*__ placeholder) records the observed digest and fails, so the
# first run on a new pin tells you exactly what to paste in.
fetch() {
    local url="$1" name="$2"
    local expected="${CHECKSUMS[${TARGET}:${name}]:-}"

    echo "  fetching $name"
    # --retry-all-errors: plain --retry only covers transient HTTP errors;
    # runners intermittently die with TLS-layer failures like
    # "curl: (35) Insufficient randomness" that need a retry too.
    curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
        --retry-all-errors \
        --output "$WORK/$name" "$url"

    local actual
    actual="$(sha256sum "$WORK/$name" | cut -d' ' -f1)"

    if [[ -z "$expected" || "$expected" == __PIN_* ]]; then
        echo "error: no pinned checksum for '${TARGET}:${name}'" >&2
        echo "       observed sha256: $actual" >&2
        echo "       Add it to CHECKSUMS in $0 after verifying the source." >&2
        exit 1
    fi
    if [[ "$actual" != "$expected" ]]; then
        echo "error: checksum mismatch for '${TARGET}:${name}'" >&2
        echo "       expected: $expected" >&2
        echo "       actual:   $actual" >&2
        exit 1
    fi
}

# `ar` is not guaranteed present in minimal CI images; .deb is just an ar
# archive whose data member we can hand straight to tar.
extract_deb() {
    local deb="$1" dest="$2"
    mkdir -p "$dest"
    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -x "$deb" "$dest"
        return
    fi
    need ar
    local tmp="$WORK/ar-$RANDOM"
    mkdir -p "$tmp"
    (cd "$tmp" && ar x "$deb")
    local data
    data="$(find "$tmp" -maxdepth 1 -name 'data.tar.*' -print -quit)"
    [[ -n "$data" ]] || { echo "error: no data member in $deb" >&2; exit 1; }
    tar -xf "$data" -C "$dest"
}

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR/include" "$OUTDIR/lib"
STAGE="$WORK/stage"
mkdir -p "$STAGE"

echo "Building OpenSSL prefix for $TARGET -> $OUTDIR"

if [[ "$FLAVOR" == deb ]]; then
    for pkg in "libssl-dev_${DEB_VERSION}_${DEB_ARCH}.deb" "libssl3t64_${DEB_VERSION}_${DEB_ARCH}.deb"; do
        fetch "${DEB_SNAPSHOT}/${pkg}" "$pkg"
        extract_deb "$WORK/$pkg" "$STAGE"
    done

    cp -a "$STAGE/usr/include/openssl/." "$OUTDIR/include/openssl/"

    # MANDATORY: Debian moves the two arch-dependent headers into the multiarch
    # include dir. Without merging them, every @cImport of <openssl/ssl.h> dies
    # on a missing openssl/opensslconf.h.
    local_arch_inc="$STAGE/usr/include/${DEB_TRIPLET}/openssl"
    if [[ -d "$local_arch_inc" ]]; then
        cp -a "$local_arch_inc/." "$OUTDIR/include/openssl/"
    fi
    for required in opensslconf.h configuration.h; do
        if [[ ! -f "$OUTDIR/include/openssl/$required" ]]; then
            echo "error: missing $required after merge — layout changed upstream" >&2
            exit 1
        fi
    done

    cp -a "$STAGE/usr/lib/${DEB_TRIPLET}/"libssl.so* "$OUTDIR/lib/"
    cp -a "$STAGE/usr/lib/${DEB_TRIPLET}/"libcrypto.so* "$OUTDIR/lib/"
else
    for pkg in "openssl-dev-${APK_VERSION}.apk" "libssl3-${APK_VERSION}.apk" "libcrypto3-${APK_VERSION}.apk"; do
        fetch "${APK_MIRROR}/${APK_ARCH}/${pkg}" "$pkg"
        # .apk is a gzipped tar with signature members tar happily skips.
        tar -xzf "$WORK/$pkg" -C "$STAGE" 2>/dev/null || true
    done

    cp -a "$STAGE/usr/include/openssl/." "$OUTDIR/include/openssl/"
    cp -a "$STAGE/usr/lib/"libssl.so* "$OUTDIR/lib/"
    cp -a "$STAGE/usr/lib/"libcrypto.so* "$OUTDIR/lib/"
fi

# `libssl.so` / `libcrypto.so` are absolute symlinks inside the package
# (-> /usr/lib/<triplet>/libssl.so.3); rewrite them as relative links so the
# prefix is self-contained and usable from any path.
for stem in libssl libcrypto; do
    if [[ -L "$OUTDIR/lib/$stem.so" ]]; then
        rm -f "$OUTDIR/lib/$stem.so"
    fi
    if [[ ! -e "$OUTDIR/lib/$stem.so" ]]; then
        soname="$(cd "$OUTDIR/lib" && ls -1 "$stem.so."* 2>/dev/null | head -1)"
        [[ -n "$soname" ]] || { echo "error: no $stem.so.* in prefix" >&2; exit 1; }
        ln -s "$soname" "$OUTDIR/lib/$stem.so"
    fi
done

for required in "$OUTDIR/include/openssl/ssl.h" "$OUTDIR/lib/libssl.so" "$OUTDIR/lib/libcrypto.so"; do
    [[ -e "$required" ]] || { echo "error: prefix incomplete, missing $required" >&2; exit 1; }
done

echo "OK: $TARGET prefix ready at $OUTDIR"
