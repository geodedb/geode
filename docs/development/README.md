# Development Documentation

Documentation for development tools, workflows, and environment setup.

## Quick Start

**New developers should start here:**

```bash
# Clone and setup everything
git clone https://gitlab.com/devnw/codepros/geode/geode.git
cd geode
make setup-dev
```

This command will:

1. Initialize git submodules
2. Install pre-commit hooks
3. Build the project
4. Run the test suite

See [CONTRIBUTING.md](../../CONTRIBUTING.md) for detailed setup instructions.

## Pre-commit Hooks

This project uses [pre-commit](https://pre-commit.com/) for code quality enforcement.

**Installation:**

```bash
make pre-commit-install
```

**What runs on commit:**

- Zig formatting (`zig fmt`)
- Zig compilation check
- Trailing whitespace removal
- YAML/JSON validation
- Shell script linting
- Python linting
- Markdown linting
- GoReleaser config validation

**What runs on push:**

- Cross-compilation for all platforms
- Full test suite
- Feature flags check
- CANARY marker verification

**Manual commands:**

```bash
make pre-commit        # Run all commit hooks
make pre-commit-all    # Run commit + push hooks
make pre-commit-update # Update to latest versions
```

## IDE Integration

- **[IDE_INTEGRATION.md](IDE_INTEGRATION.md)** - Editor and IDE setup

## Development Tools

- **[AI_CLI_TOOLS.md](AI_CLI_TOOLS.md)** - AI-assisted development tools
- **[REPL_ADVANCED_FEATURES.md](REPL_ADVANCED_FEATURES.md)** - Interactive shell features
- **[REPL_FORMATTING_FIXES.md](REPL_FORMATTING_FIXES.md)** - REPL formatting improvements

## Project Management

- **[WORK_TRACKER.md](WORK_TRACKER.md)** - Development tracking
- **[CRUSH.md](CRUSH.md)** - Code review and analysis

## Architecture Changes

- **[EMBEDDED_REMOVAL.md](EMBEDDED_REMOVAL.md)** - Embedded mode removal documentation
