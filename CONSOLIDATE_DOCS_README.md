# Documentation Consolidation Tool

A safe, deterministic CLI agent that consolidates documentation into docs/, archives outdated docs to docs/archive/, and determines accuracy using code-aware checks plus canary definitions.

## Installation

```bash
# Install dependencies
pip install pyyaml==6.0.2 semver==3.0.2 rich==13.8.1 pytest==8.3.3 ruff==0.6.9
```

## Usage

```bash
# Dry run (default) - shows what would be moved
python consolidate_docs.py

# Apply changes
python consolidate_docs.py --apply

# Specify different repository root
python consolidate_docs.py --repo /path/to/repo

# Use custom configuration
python consolidate_docs.py --config custom.yaml

# Enable verbose logging
python consolidate_docs.py --verbose
```

## Features

- **Deterministic classification** based on version comparisons and symbol validation
- **Safe path handling** with directory traversal protection
- **Multi-language code scanning** for Zig, Go, Python, Shell
- **JSON Lines logging** with secret redaction
- **Dry-run default** with explicit --apply for safety
- **Comprehensive error handling** with appropriate exit codes

## Classification Rules

1. If doc has no declared version → OUTDATED
2. If doc's version < latest canary for its subsystem → OUTDATED
3. If doc references symbols/endpoints not found in code and canary doesn't allow legacy → OUTDATED
4. If doc references deprecated items without marking deprecated → OUTDATED
5. Otherwise → ACCURATE

## Testing

```bash
# Run all tests
pytest -q

# Lint code
ruff check .
```

## Exit Codes

- 0: Success
- 1: Runtime error
- 2: Classification setup error (e.g., no canaries)
- 3: Invalid config