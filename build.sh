#!/usr/bin/env bash
# Geode Build Script for Docker Development Environment
set -e

export MSQUIC_INCLUDE_DIR=/opt/msquic/include
export MSQUIC_LIB_DIR=/opt/msquic/lib
export ZIG_GLOBAL_CACHE_DIR=${ZIG_GLOBAL_CACHE_DIR:-$HOME/.cache/zig}
export LD_LIBRARY_PATH=/opt/msquic/lib:/opt/openssl-fips/lib64:${LD_LIBRARY_PATH:-}

echo "Building Geode with MsQUIC integration..."
zig build "$@"
echo "Build completed! Binary: ./zig-out/bin/geode"
