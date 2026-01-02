# Geode Editor Integrations

This directory contains editor integrations for the Geode GQL Language Server.

## Available Integrations

### VS Code (`vscode/`)
Full VS Code extension with:
- Syntax highlighting
- LSP integration
- Configurable settings

See [vscode/README.md](vscode/README.md) for installation instructions.

### Neovim (`neovim/`)
Neovim configuration with:
- nvim-lspconfig setup
- Vim syntax highlighting
- Key mappings

See [neovim/README.md](neovim/README.md) for installation instructions.

## Quick Start

### Prerequisites

Ensure Geode is built and in your PATH:

```bash
cd /path/to/geode
make build
export PATH="$PWD/zig-out/bin:$PATH"
```

Verify installation:
```bash
geode lsp --help
```

### Editor Setup

| Editor | Setup Command |
|--------|---------------|
| VS Code | Install VSIX from `editors/vscode/` |
| Neovim | Add config from `editors/neovim/gql.lua` |
| Vim | Add syntax from `editors/neovim/gql.vim` |

## LSP Capabilities

The Geode LSP provides:

| Feature | Status |
|---------|--------|
| textDocument/publishDiagnostics | ✅ |
| textDocument/hover | ✅ |
| textDocument/completion | ✅ |
| textDocument/definition | ✅ |
| textDocument/formatting | ✅ |
| textDocument/references | 🔜 |
| textDocument/rename | 🔜 |

## Adding New Editor Support

To add support for a new editor:

1. Create a new directory: `editors/<editor-name>/`
2. Configure the editor to start `geode lsp` via stdio
3. Map file extensions: `.gql`, `.gcypher`, `.cypher`, `.pgql`
4. Add a README with setup instructions

The LSP uses standard JSON-RPC 2.0 over stdio with Content-Length headers.

## Troubleshooting

### LSP not responding

1. Test LSP directly:
   ```bash
   echo 'Content-Length: 90\r\n\r\n{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' | geode lsp
   ```

2. Check stderr for error messages

3. Verify geode binary works: `geode --version`

### No syntax highlighting

1. Check file extension is recognized
2. Verify syntax files are in correct location
3. Restart editor after configuration changes
