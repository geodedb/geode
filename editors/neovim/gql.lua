-- Geode GQL Language Server configuration for Neovim
-- Add this to your Neovim configuration (init.lua or separate file)

-- Method 1: Using nvim-lspconfig (recommended)
-- Add to your lspconfig setup after installing nvim-lspconfig

local lspconfig = require('lspconfig')
local configs = require('lspconfig.configs')

-- Register geode-gql as a new LSP server
if not configs.geode_gql then
  configs.geode_gql = {
    default_config = {
      cmd = { 'geode', 'lsp' },
      filetypes = { 'gql', 'cypher', 'gcypher', 'pgql' },
      root_dir = function(fname)
        return lspconfig.util.find_git_ancestor(fname)
          or lspconfig.util.root_pattern('*.gql', '.git')(fname)
          or vim.fn.getcwd()
      end,
      single_file_support = true,
      settings = {},
    },
    docs = {
      description = [[
Geode GQL Language Server

A language server for GQL (Graph Query Language) and Cypher queries,
providing diagnostics, hover documentation, and code completion.

Installation:
  Build geode from source or install via package manager.
  Ensure 'geode' is in your PATH.

Usage:
  The server is started automatically for .gql, .cypher, .gcypher, and .pgql files.
]],
    },
  }
end

-- Setup the server
lspconfig.geode_gql.setup({
  on_attach = function(client, bufnr)
    -- Enable completion triggered by <c-x><c-o>
    vim.api.nvim_buf_set_option(bufnr, 'omnifunc', 'v:lua.vim.lsp.omnifunc')

    -- Buffer local mappings
    local opts = { buffer = bufnr, noremap = true, silent = true }
    vim.keymap.set('n', 'gD', vim.lsp.buf.declaration, opts)
    vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts)
    vim.keymap.set('n', 'K', vim.lsp.buf.hover, opts)
    vim.keymap.set('n', 'gi', vim.lsp.buf.implementation, opts)
    vim.keymap.set('n', '<C-k>', vim.lsp.buf.signature_help, opts)
    vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, opts)
    vim.keymap.set('n', '<leader>ca', vim.lsp.buf.code_action, opts)
    vim.keymap.set('n', 'gr', vim.lsp.buf.references, opts)
    vim.keymap.set('n', '<leader>f', function()
      vim.lsp.buf.format({ async = true })
    end, opts)

    print('Geode GQL LSP attached to buffer ' .. bufnr)
  end,
  capabilities = require('cmp_nvim_lsp').default_capabilities(),
})
