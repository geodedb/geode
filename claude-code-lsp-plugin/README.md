# Geode GQL Language Server Plugin for Claude Code

This plugin provides Language Server Protocol (LSP) support for Geode's GQL (Graph Query Language) in Claude Code.

## Features

- **Syntax Diagnostics**: Real-time error detection for GQL queries
- **Hover Documentation**: Documentation for GQL keywords, functions, and types
- **Code Completion**: Intelligent completions for keywords, functions, and types
- **Go-to-Definition**: Navigate to symbol definitions
- **Document Formatting**: Format GQL documents

## Supported File Extensions

- `.gql` - GQL files
- `.gcypher` - Geode Cypher variant
- `.cypher` - Cypher compatibility
- `.pgql` - Property Graph Query Language

## Installation

### Prerequisites

1. **Geode** must be installed and available in your PATH:
   ```bash
   # Build from source
   git clone https://github.com/geode-db/geode.git
   cd geode && make build
   export PATH="$PWD/zig-out/bin:$PATH"
   ```

### Install Plugin in Claude Code

```bash
# Install from local path
claude /plugin install /path/to/claude-code-lsp-plugin

# Or install from marketplace (when published)
claude /plugin install geode-lsp@claude-code-lsps
```

## Usage

Once installed, the LSP server automatically starts when you open a supported file. You'll get:

- Red squiggles for syntax errors
- Hover tooltips with documentation
- Completion suggestions as you type
- Keyboard shortcuts for go-to-definition

## LSP Capabilities

| Feature | Support |
|---------|---------|
| textDocument/hover | Yes |
| textDocument/completion | Yes (triggers: `.`, `:`, `$`) |
| textDocument/definition | Yes |
| textDocument/formatting | Yes |
| textDocument/publishDiagnostics | Yes |

## Troubleshooting

### LSP Not Starting

1. Verify geode is installed:
   ```bash
   geode lsp --help
   ```

2. Check the Claude Code output panel for errors

3. Restart Claude Code after installing the plugin

### No Completions

Completions are triggered by:
- Typing `.` after a variable
- Typing `:` for label syntax
- Typing `$` for parameter names

## Development

To modify this plugin:

1. Edit `.lsp.json` for LSP configuration
2. Edit `hooks/check-geode.sh` for installation checks
3. Reload the plugin in Claude Code

## License

MIT License - See the main Geode repository for full license.
