# Geode GQL Plugin for Neovim - Makefile
# Provides commands for installation, testing, and development

.PHONY: all install install-lazy install-packer install-vim-plug \
        uninstall link unlink test lint check help clean

# Default XDG paths
XDG_DATA_HOME ?= $(HOME)/.local/share
XDG_CONFIG_HOME ?= $(HOME)/.config
NVIM_DATA_DIR := $(XDG_DATA_HOME)/nvim
NVIM_SITE_DIR := $(NVIM_DATA_DIR)/site/pack/geode/start/geode-nvim
NVIM_CONFIG_DIR := $(XDG_CONFIG_HOME)/nvim

# Current directory
PLUGIN_DIR := $(shell pwd)

# Colors for output
GREEN := \033[0;32m
YELLOW := \033[0;33m
RED := \033[0;31m
NC := \033[0m

all: help

## Installation Methods

# Manual installation to nvim site directory
install:
	@echo "$(GREEN)Installing Geode plugin to $(NVIM_SITE_DIR)...$(NC)"
	@mkdir -p $(NVIM_SITE_DIR)
	@cp -r lua $(NVIM_SITE_DIR)/
	@cp -r plugin $(NVIM_SITE_DIR)/ 2>/dev/null || true
	@cp -r syntax $(NVIM_SITE_DIR)/ 2>/dev/null || true
	@cp -r ftplugin $(NVIM_SITE_DIR)/ 2>/dev/null || true
	@cp -r doc $(NVIM_SITE_DIR)/ 2>/dev/null || true
	@echo "$(GREEN)Installation complete!$(NC)"
	@echo "Add to your init.lua: require('geode').setup()"

# Symlink for development (changes reflect immediately)
link:
	@echo "$(GREEN)Creating symlink for development...$(NC)"
	@mkdir -p $(dir $(NVIM_SITE_DIR))
	@ln -sfn $(PLUGIN_DIR) $(NVIM_SITE_DIR)
	@echo "$(GREEN)Symlink created at $(NVIM_SITE_DIR)$(NC)"
	@echo "Changes to plugin files will be reflected immediately."

unlink:
	@echo "$(YELLOW)Removing development symlink...$(NC)"
	@rm -f $(NVIM_SITE_DIR)
	@echo "$(GREEN)Symlink removed.$(NC)"

uninstall:
	@echo "$(YELLOW)Uninstalling Geode plugin...$(NC)"
	@rm -rf $(NVIM_SITE_DIR)
	@echo "$(GREEN)Uninstallation complete.$(NC)"

## Plugin Manager Configurations

# Generate lazy.nvim config
install-lazy:
	@echo "$(GREEN)Lazy.nvim configuration:$(NC)"
	@echo ""
	@echo '{'
	@echo '  "geode-db/geode",'
	@echo '  config = function()'
	@echo '    require("geode").setup({'
	@echo '      lsp = { enabled = true },'
	@echo '      server = { host = "localhost", port = 3141 },'
	@echo '    })'
	@echo '  end,'
	@echo '  ft = { "gql", "cypher", "gcypher", "pgql" },'
	@echo '}'
	@echo ""

# Generate packer.nvim config
install-packer:
	@echo "$(GREEN)Packer.nvim configuration:$(NC)"
	@echo ""
	@echo 'use {'
	@echo '  "geode-db/geode",'
	@echo '  config = function()'
	@echo '    require("geode").setup()'
	@echo '  end,'
	@echo '  ft = { "gql", "cypher", "gcypher", "pgql" },'
	@echo '}'
	@echo ""

# Generate vim-plug config
install-vim-plug:
	@echo "$(GREEN)vim-plug configuration:$(NC)"
	@echo ""
	@echo "Plug 'geode-db/geode'"
	@echo ""
	@echo "\" Then in your init.vim/init.lua:"
	@echo "lua require('geode').setup()"
	@echo ""

## Testing

test:
	@echo "$(GREEN)Running plugin tests...$(NC)"
	@nvim --headless -c "lua require('geode')" -c "qa!" 2>&1 && \
		echo "$(GREEN)✓ Plugin loads successfully$(NC)" || \
		echo "$(RED)✗ Plugin failed to load$(NC)"

test-lsp:
	@echo "$(GREEN)Testing LSP connectivity...$(NC)"
	@which geode >/dev/null 2>&1 && \
		echo "$(GREEN)✓ geode binary found$(NC)" || \
		echo "$(RED)✗ geode binary not found in PATH$(NC)"
	@geode lsp --help >/dev/null 2>&1 && \
		echo "$(GREEN)✓ geode lsp command available$(NC)" || \
		echo "$(RED)✗ geode lsp command not available$(NC)"

test-all: test test-lsp
	@echo "$(GREEN)All tests completed.$(NC)"

## Linting

lint:
	@echo "$(GREEN)Linting Lua files...$(NC)"
	@if command -v luacheck >/dev/null 2>&1; then \
		luacheck lua/ --globals vim --no-max-line-length; \
	else \
		echo "$(YELLOW)luacheck not installed. Install with: luarocks install luacheck$(NC)"; \
	fi

lint-fix:
	@echo "$(GREEN)Formatting Lua files...$(NC)"
	@if command -v stylua >/dev/null 2>&1; then \
		stylua lua/; \
	else \
		echo "$(YELLOW)stylua not installed. Install from: https://github.com/JohnnyMorganz/StyLua$(NC)"; \
	fi

## Development

check: lint test
	@echo "$(GREEN)All checks passed!$(NC)"

watch:
	@echo "$(GREEN)Watching for changes...$(NC)"
	@echo "Use :luafile % in Neovim to reload individual files"
	@echo "Or restart Neovim to reload the entire plugin"

clean:
	@echo "$(YELLOW)Cleaning build artifacts...$(NC)"
	@find . -name "*.luac" -delete
	@find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
	@echo "$(GREEN)Clean complete.$(NC)"

## Documentation

docs:
	@echo "$(GREEN)Generating help tags...$(NC)"
	@nvim --headless -c "helptags doc/" -c "qa!" 2>/dev/null || true
	@echo "$(GREEN)Help tags generated.$(NC)"

## Help

help:
	@echo "Geode GQL Plugin for Neovim"
	@echo ""
	@echo "$(GREEN)Installation:$(NC)"
	@echo "  make install       - Install plugin to nvim site directory"
	@echo "  make link          - Create symlink for development"
	@echo "  make unlink        - Remove development symlink"
	@echo "  make uninstall     - Remove installed plugin"
	@echo ""
	@echo "$(GREEN)Plugin Managers:$(NC)"
	@echo "  make install-lazy      - Show lazy.nvim configuration"
	@echo "  make install-packer    - Show packer.nvim configuration"
	@echo "  make install-vim-plug  - Show vim-plug configuration"
	@echo ""
	@echo "$(GREEN)Testing:$(NC)"
	@echo "  make test          - Test plugin loading"
	@echo "  make test-lsp      - Test LSP availability"
	@echo "  make test-all      - Run all tests"
	@echo ""
	@echo "$(GREEN)Development:$(NC)"
	@echo "  make lint          - Lint Lua files with luacheck"
	@echo "  make lint-fix      - Format Lua files with stylua"
	@echo "  make check         - Run lint and tests"
	@echo "  make docs          - Generate help tags"
	@echo "  make clean         - Remove build artifacts"
	@echo ""
	@echo "$(GREEN)Quick Start:$(NC)"
	@echo "  1. make link       - Link plugin for development"
	@echo "  2. Add to init.lua: require('geode').setup()"
	@echo "  3. Open a .gql file and enjoy!"
