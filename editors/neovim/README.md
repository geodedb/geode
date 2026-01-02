# Geode GQL Plugin for Neovim

A comprehensive Neovim plugin for [Geode](https://github.com/geode-db/geode) graph database development, providing LSP support, syntax highlighting, query execution, and snippets for GQL (Graph Query Language) and Cypher.

## Features

- **LSP Integration**: Diagnostics, hover documentation, go-to-definition, formatting
- **Syntax Highlighting**: Full GQL/Cypher syntax support including comments (`--` and `//`)
- **Query Execution**: Run queries directly from Neovim with `<F5>`
- **Code Snippets**: 25+ LuaSnip snippets for common patterns
- **Server Connection**: Connect to and manage Geode server connections
- **Status Line**: Integration with lualine/statusline

## Requirements

- Neovim 0.8+
- [Geode](https://github.com/geode-db/geode) installed and in PATH
- [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) (recommended)
- [LuaSnip](https://github.com/L3MON4D3/LuaSnip) (optional, for snippets)
- [nvim-cmp](https://github.com/hrsh7th/nvim-cmp) (optional, for completion)

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
    "geode-db/geode",
    config = function()
        require("geode").setup({
            lsp = { enabled = true },
            server = { host = "localhost", port = 3141 },
        })
    end,
    ft = { "gql", "cypher", "gcypher", "pgql" },
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
    "geode-db/geode",
    config = function()
        require("geode").setup()
    end,
    ft = { "gql", "cypher", "gcypher", "pgql" },
}
```

### Using [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'geode-db/geode'

" In your init.vim/init.lua:
lua require('geode').setup()
```

### Manual Installation

```bash
# Clone to Neovim's pack directory
mkdir -p ~/.local/share/nvim/site/pack/geode/start
cd ~/.local/share/nvim/site/pack/geode/start
git clone https://github.com/geode-db/geode.git geode-nvim

# Or use the Makefile
cd editors/neovim
make install
```

Then add to your `init.lua`:

```lua
require("geode").setup()
```

## Configuration

```lua
require("geode").setup({
    -- LSP settings
    lsp = {
        enabled = true,                              -- Enable LSP
        cmd = { "geode", "lsp" },                   -- LSP command
        filetypes = { "gql", "cypher", "gcypher", "pgql" },
    },

    -- Server connection
    server = {
        host = "localhost",                          -- Geode server host
        port = 3141,                                 -- Geode server port
        auto_connect = false,                        -- Auto-connect on startup
    },

    -- Query execution
    query = {
        timeout = 30000,                             -- Query timeout (ms)
        max_results = 1000,                          -- Maximum results
        output_format = "json",                      -- Output: json, table
    },

    -- UI settings
    ui = {
        show_diagnostics = true,                     -- Show LSP diagnostics
        virtual_text = true,                         -- Inline diagnostics
        signs = true,                                -- Sign column markers
        float_border = "rounded",                    -- Float border style
    },

    -- Keymaps (set to false to disable)
    keymaps = {
        run_query = "<F5>",                          -- Run buffer
        run_selection = "<leader>gr",                -- Run selection
        explain_query = "<leader>ge",                -- Explain plan
        format_buffer = "<leader>gf",                -- Format buffer
        show_docs = "K",                             -- Hover docs
    },
})
```

## Commands

| Command | Description |
|---------|-------------|
| `:GeodeRunQuery` | Execute entire buffer as GQL query |
| `:GeodeRunSelection` | Execute visual selection as query |
| `:GeodeExplain` | Show query execution plan |
| `:GeodeConnect [host:port]` | Connect to Geode server |
| `:GeodeDisconnect` | Disconnect from server |
| `:GeodeStatus` | Show connection/LSP status |
| `:GeodeRestartLsp` | Restart the LSP server |

## Keymaps

### Normal Mode

| Key | Action |
|-----|--------|
| `<F5>` | Run entire buffer as query |
| `<leader>ge` | Explain query plan |
| `<leader>gf` | Format buffer (LSP) |
| `K` | Show hover documentation |
| `gd` | Go to definition |

### Visual Mode

| Key | Action |
|-----|--------|
| `<leader>gr` | Run selected text as query |

## Snippets

Enable snippets (requires LuaSnip):

```lua
require("geode.snippets").setup()
```

Available snippets:

| Trigger | Description |
|---------|-------------|
| `match` | Basic MATCH pattern |
| `matchw` | MATCH with WHERE clause |
| `matchr` | MATCH with relationship |
| `create` | CREATE node |
| `creater` | CREATE relationship |
| `merge` | MERGE with ON CREATE/MATCH |
| `vdist` | Vector distance function |
| `vknn` | Vector KNN search |
| `path` | Variable-length path |
| `shortest` | Shortest path query |
| `case` | CASE expression |
| `foreach` | FOREACH loop |
| `unwind` | UNWIND list |

## Statusline Integration

Add to lualine:

```lua
require("lualine").setup({
    sections = {
        lualine_x = {
            require("geode").statusline,
            -- other components...
        }
    }
})
```

## Development

```bash
cd editors/neovim

# Link for development (changes reflect immediately)
make link

# Run tests
make test
make test-lsp

# Lint Lua files
make lint

# Generate help tags
make docs
```

## Troubleshooting

### LSP not starting

1. Ensure `geode` is in your PATH:
   ```bash
   which geode
   ```

2. Test the LSP command:
   ```bash
   geode lsp --help
   ```

3. Check LSP logs in Neovim:
   ```vim
   :LspLog
   ```

### Query execution fails

1. Ensure Geode server is running:
   ```bash
   geode serve --listen 0.0.0.0:3141
   ```

2. Test connection:
   ```vim
   :GeodeConnect localhost:3141
   :GeodeStatus
   ```

### Syntax highlighting not working

1. Check filetype:
   ```vim
   :set ft?
   ```

2. Reload syntax:
   ```vim
   :set ft=gql
   ```

## License

MIT License - see [LICENSE](../../LICENSE) for details.
