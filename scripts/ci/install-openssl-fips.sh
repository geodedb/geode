#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Build OpenSSL with the FIPS provider into a user-owned prefix for the GitHub
# Actions FIPS gate (.github/workflows/ci.yml, zig-fips-test). This is what
# the GitLab job gets from the private ci-catalog zig-fips image
# (/usr/local/ssl), built the way gitlab.com/devnw/zig/fips's
# scripts/install-openssl-fips.sh and that image's Dockerfile build it:
# Configure enable-fips -> make install_fips -> fipsinstall -> an openssl.cnf
# that activates fips + base -> require the fips provider to report active.
#
# Fail closed: the tarball must match the pinned SHA-256 AND carry a good
# signature from a pinned OpenSSL release key. An existing prefix with the
# same version and an active fips provider is reused (the workflow caches it).
#
#   OPENSSL_PREFIX=/home/runner/openssl-fips scripts/ci/install-openssl-fips.sh
set -euo pipefail

VER="${OPENSSL_VERSION:-3.6.5}"
PREFIX="${OPENSSL_PREFIX:?set OPENSSL_PREFIX}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

# SHA-256 of openssl-${VER}.tar.gz, pinned per version (from the release's
# .sha256 file, cross-checked against a local download on 2026-11-23).
case "$VER" in
  3.6.5) SHA256=a2157c2830efdec3788939b00c9b0638306d3f0bbb76dc4832ee503bb397df98 ;;
  *) echo "no pinned SHA-256 for OpenSSL ${VER}; add it to $0" >&2; exit 1 ;;
esac
# OpenSSL release signing keys (https://openssl-library.org/source/).
KEYS="B146647E45A7B33947AB226B2A2C87D161692D40 BA5473A2B0587B07FB27CF2D216094DFD0CB81EF"

log() { printf '==> %s\n' "$*"; }

fips_active() {
  [ -x "${PREFIX}/bin/openssl" ] &&
    OPENSSL_CONF="${PREFIX}/ssl/openssl.cnf" "${PREFIX}/bin/openssl" list -providers 2>/dev/null |
    grep -A3 -i '^[[:space:]]*fips$' | grep -qi 'status: active'
}

if [ -x "${PREFIX}/bin/openssl" ] &&
  [ "$("${PREFIX}/bin/openssl" version | awk '{print $2}')" = "${VER}" ] && fips_active; then
  log "OpenSSL ${VER} with an active fips provider already at ${PREFIX}"
  "${PREFIX}/bin/openssl" version
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
base="https://github.com/openssl/openssl/releases/download/openssl-${VER}"
tarball="openssl-${VER}.tar.gz"
log "Fetching ${tarball}"
curl -fsSL --retry 4 --retry-all-errors -o "$tarball" "${base}/${tarball}"
curl -fsSL --retry 4 --retry-all-errors -o "${tarball}.asc" "${base}/${tarball}.asc"

printf '%s  %s\n' "$SHA256" "$tarball" | sha256sum --check --strict

export GNUPGHOME="$work/gnupg"
mkdir -m 700 "$GNUPGHOME"
imported=0
for attempt in 1 2 3; do
  for server in hkps://keys.openpgp.org hkps://keyserver.ubuntu.com; do
    # shellcheck disable=SC2086 # KEYS is a list of fingerprints
    if gpg --batch --keyserver "$server" --recv-keys $KEYS >/dev/null 2>&1; then
      imported=1
      break 2
    fi
  done
  sleep $((attempt * 10))
done
[ "$imported" = 1 ] || { echo "could not fetch the OpenSSL release keys" >&2; exit 1; }
gpg --batch --status-fd 1 --verify "${tarball}.asc" "$tarball" >verify.out 2>verify.err || {
  cat verify.err >&2
  echo "GPG signature verification FAILED for ${tarball}" >&2
  exit 1
}
signer=$(awk '$2 == "VALIDSIG" {print $NF}' verify.out)
case " $KEYS " in
  *" $signer "*) log "Signature by pinned OpenSSL release key ${signer}" ;;
  *) echo "signature is not from a pinned OpenSSL release key (primary ${signer:-none})" >&2; exit 1 ;;
esac

tar xzf "$tarball"
cd "openssl-${VER}"
log "Configuring enable-fips (prefix ${PREFIX})"
./Configure enable-fips --prefix="${PREFIX}" --openssldir="${PREFIX}/ssl" \
  -Wl,-rpath,"${PREFIX}/lib64" -Wl,-rpath,"${PREFIX}/lib" >"$work/build.log" 2>&1 || { tail -50 "$work/build.log"; exit 1; }
make -j"${JOBS}" >>"$work/build.log" 2>&1 || { tail -50 "$work/build.log"; exit 1; }
make install_sw install_ssldirs install_fips >>"$work/build.log" 2>&1 || { tail -50 "$work/build.log"; exit 1; }

libdir="${PREFIX}/lib64"
[ -d "${libdir}/ossl-modules" ] || libdir="${PREFIX}/lib"
"${PREFIX}/bin/openssl" fipsinstall -out "${PREFIX}/ssl/fipsmodule.cnf" -module "${libdir}/ossl-modules/fips.so" \
  >"$work/fipsinstall.log" 2>&1 || { cat "$work/fipsinstall.log"; exit 1; }
tail -1 "$work/fipsinstall.log"
cat >"${PREFIX}/ssl/openssl.cnf" <<EOF
config_diagnostics = 1
openssl_conf = openssl_init

.include ${PREFIX}/ssl/fipsmodule.cnf

[openssl_init]
providers = provider_sect
alg_section = algorithm_sect

[provider_sect]
fips = fips_sect
base = base_sect

[base_sect]
activate = 1

[algorithm_sect]
default_properties = fips=yes
EOF

fips_active || { echo "the fips provider is not active after installation" >&2; exit 1; }
"${PREFIX}/bin/openssl" version
log "OpenSSL ${VER} FIPS provider active at ${PREFIX}"
