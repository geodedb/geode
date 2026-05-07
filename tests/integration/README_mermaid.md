# Mermaid External Integration Tests

`test_mermaid_external.sh` runs `geode query --format mermaid` against a
private geode instance on a high port and pipes the output through
`@mermaid-js/mermaid-cli` (the official Mermaid renderer) to verify the
output is real, parseable Mermaid syntax that produces a valid SVG.

## Running

    ./tests/integration/test_mermaid_external.sh

The first run downloads `@mermaid-js/mermaid-cli` and chromium via npx
(~200 MB). Subsequent runs reuse the cache.

## Requirements

- `node` and `npx` on PATH (any recent Node.js >= 18).
- The geode binary at `./zig-out/bin/geode` (the script will run
  `zig build` if it's missing).
- ~200 MB of disk for the npx/puppeteer cache on first run.

## What it checks

For each of three queries (empty graph, single node, single relationship):

1. The mermaid output starts with `flowchart LR`.
2. `mmdc` renders the output to an SVG without parser errors.
3. The resulting SVG is non-empty and starts with `<svg`.

## Make target

    make test-mermaid-integration
