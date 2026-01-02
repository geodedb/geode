# Geode GQL for Visual Studio Code

This extension provides GQL (Graph Query Language) and Cypher language support for Visual Studio Code, powered by the Geode LSP.

## Features

- **Syntax Highlighting**: Full syntax highlighting for GQL and Cypher
- **Real-time Diagnostics**: See errors and warnings as you type
- **Hover Documentation**: Hover over keywords, functions, and types for documentation
- **Code Completion**: Intelligent completions for keywords, functions, and types
- **Go-to-Definition**: Navigate to symbol definitions (Ctrl+Click)
- **Document Formatting**: Format your GQL documents

## Prerequisites

1. **Geode** must be installed and available in your PATH:
   ```bash
   # Build from source
   git clone https://github.com/geode-db/geode.git
   cd geode && make build
   export PATH="$PWD/zig-out/bin:$PATH"
   ```

## Installation

### From VSIX (Local Install)

1. Build the extension:
   ```bash
   cd editors/vscode
   npm install
   npm run compile
   npx vsce package
   ```

2. Install in VS Code:
   - Open VS Code
   - Press `Ctrl+Shift+P` → "Extensions: Install from VSIX..."
   - Select the generated `.vsix` file

### From Marketplace (When Published)

```bash
code --install-extension geode-db.geode-gql
```

## Configuration

Settings available in VS Code settings:

| Setting | Default | Description |
|---------|---------|-------------|
| `geode.lsp.path` | `"geode"` | Path to geode executable |
| `geode.lsp.args` | `["lsp"]` | Arguments for LSP server |
| `geode.lsp.trace.server` | `"off"` | LSP communication tracing |

## Supported File Types

- `.gql` - GQL files
- `.gcypher` - Geode Cypher variant
- `.cypher` - Cypher compatibility
- `.pgql` - Property Graph Query Language

## Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| Hover documentation | Hover mouse |
| Go to definition | `F12` or `Ctrl+Click` |
| Find references | `Shift+F12` |
| Format document | `Shift+Alt+F` |
| Quick fix | `Ctrl+.` |

## Troubleshooting

### Extension not loading

1. Check Output panel: View → Output → "Geode GQL Language Server"
2. Verify geode is in PATH: `which geode` or `where geode`
3. Try restarting VS Code

### No syntax highlighting

1. Check file extension is `.gql`, `.cypher`, etc.
2. Check bottom-right of VS Code shows "GQL" as language

### No completions

1. Ensure LSP is started (check Output panel)
2. Try typing trigger characters: `.`, `:`, `$`
3. Use `Ctrl+Space` to force completion popup

## Development

```bash
# Install dependencies
npm install

# Compile TypeScript
npm run compile

# Watch for changes
npm run watch

# Package as VSIX
npx vsce package
```

## License

MIT License - See the main Geode repository for full license.
