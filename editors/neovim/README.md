# Geode GQL for Neovim

This directory contains Neovim/Vim configuration for GQL language support with the Geode LSP.

## Quick Setup

### 1. Prerequisites

- Neovim 0.8+ (for LSP support)
- [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig)
- [nvim-cmp](https://github.com/hrsh7th/nvim-cmp) (optional, for completion)
- Geode binary in PATH

### 2. Install Geode LSP Configuration

Add to your `init.lua` or create `~/.config/nvim/after/plugin/geode-gql.lua`:

```lua
-- Minimal setup
local lspconfig = require('lspconfig')
local configs = require('lspconfig.configs')

if not configs.geode_gql then
  configs.geode_gql = {
    default_config = {
      cmd = { 'geode', 'lsp' },
      filetypes = { 'gql', 'cypher', 'gcypher', 'pgql' },
      root_dir = function(fname)
        return lspconfig.util.find_git_ancestor(fname) or vim.fn.getcwd()
      end,
      single_file_support = true,
    },
  }
end

lspconfig.geode_gql.setup({})
```

### 3. Filetype Detection

Add to `~/.config/nvim/ftdetect/gql.lua`:

```lua
vim.filetype.add({
  extension = {
    gql = 'gql',
    gcypher = 'gql',
    cypher = 'cypher',
    pgql = 'gql',
  },
})
```

### 4. Basic Syntax Highlighting (Vim-style)

Copy `gql.vim` to `~/.config/nvim/syntax/gql.vim` for basic syntax highlighting.

## Features

Once configured, you'll have access to:

| Feature | Keybinding |
|---------|------------|
| Hover documentation | `K` |
| Go to definition | `gd` |
| Find references | `gr` |
| Rename symbol | `<leader>rn` |
| Code actions | `<leader>ca` |
| Format document | `<leader>f` |
| Completion | `<C-x><C-o>` or via nvim-cmp |

## Troubleshooting

### LSP not starting

1. Verify geode is installed:
   ```bash
   geode lsp --help
   ```

2. Check LSP logs:
   ```vim
   :LspLog
   ```

3. Verify filetype is detected:
   ```vim
   :set ft?
   ```

### No completions

1. Ensure nvim-cmp is configured with LSP source
2. Check that the LSP is attached: `:LspInfo`
3. Try omnifunc completion: `<C-x><C-o>`

## Advanced Configuration

For a complete setup with all features, see `gql.lua` in this directory.

### With Mason.nvim

If you use mason.nvim for managing language servers:

```lua
-- Currently geode-lsp is not in mason registry
-- Install manually and configure path
lspconfig.geode_gql.setup({
  cmd = { '/path/to/geode', 'lsp' },
})
```
