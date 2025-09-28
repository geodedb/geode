# Geode Fuzz Suite

This directory contains fuzz targets and seed corpora for Geode (Zig 0.15.1).

- Run all fuzz targets (short budget):
  zig build test --fuzz=10s

- Run with LLVM libFuzzer fallback (if needed):
  zig build test --fuzz=60m -- -Denable-llvm-fuzzer=true

- Generate a scaffold for a new fuzz target mapped to a CANARY:
  zig build gen-fuzz -- --canary REQ-GQL-068

- Update Source Anchors:
  bash scripts/annotate_refs.sh
