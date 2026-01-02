-- Filetype plugin for GQL files
-- Sets buffer-local options for GQL/Cypher editing
-- Formatting is handled by the Geode LSP (geode_lsp)

local opt = vim.opt_local

-- Indentation (matches Geode LSP default indent_size)
opt.expandtab = true
opt.shiftwidth = 4
opt.softtabstop = 4
opt.tabstop = 4

-- Text handling
opt.textwidth = 100
opt.wrap = false

-- Comments
opt.commentstring = "-- %s"
opt.comments = "s1:/*,mb:*,ex:*/,:--,://"

-- Folding (by indent)
opt.foldmethod = "indent"
opt.foldlevel = 99

-- Format options
opt.formatoptions:remove("t") -- Don't auto-wrap text
opt.formatoptions:append("c") -- Auto-wrap comments
opt.formatoptions:append("r") -- Continue comments on Enter
opt.formatoptions:append("o") -- Continue comments on o/O
opt.formatoptions:append("q") -- Allow formatting with gq
opt.formatoptions:append("l") -- Don't break long lines in insert mode
opt.formatoptions:append("j") -- Remove comment leader when joining lines

-- Keyword characters (for word motions)
opt.iskeyword:append("$") -- Include $ for parameters
opt.iskeyword:append(":") -- Include : for labels

-- Completion
opt.complete:append("k") -- Include dictionary completion
opt.dictionary:append("/usr/share/dict/words")

-- Match pairs
opt.matchpairs:append("<:>")

-- Set up abbreviations for common patterns
vim.cmd([[
  iabbrev <buffer> ret RETURN
  iabbrev <buffer> mtch MATCH
  iabbrev <buffer> crt CREATE
  iabbrev <buffer> mrg MERGE
  iabbrev <buffer> del DELETE
  iabbrev <buffer> whr WHERE
  iabbrev <buffer> ord ORDER BY
]])
