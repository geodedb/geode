-- Geode GQL Plugin for Neovim
-- Provides LSP, syntax highlighting, snippets, and query execution

local M = {}

-- Default configuration
M.config = {
    -- LSP settings
    lsp = {
        enabled = true,
        cmd = { "geode", "lsp" },
        filetypes = { "gql", "cypher", "gcypher", "pgql", "graphql" },
        root_dir = nil, -- Will use current directory
    },
    -- Server connection settings
    server = {
        host = "localhost",
        port = 3141,
        auto_connect = false,
    },
    -- Query execution settings
    query = {
        timeout = 30000,
        max_results = 1000,
        output_format = "json",
    },
    -- Formatting settings
    format = {
        indent_size = 4,
        fold_property_maps = true,  -- Fold property maps onto multiple lines
        max_line_length = 80,       -- Max line length before folding
        min_properties_to_fold = 2, -- Min properties to trigger folding
        format_on_save = true,      -- Auto-format GQL files on save
    },
    -- UI settings
    ui = {
        show_diagnostics = true,
        virtual_text = true,
        signs = true,
        float_border = "rounded",
    },
    -- Keymaps (set to false to disable)
    keymaps = {
        run_query = "<F5>",
        run_selection = "<leader>gr",
        explain_query = "<leader>ge",
        format_buffer = "<leader>gf",
        show_docs = "K",
    },
}

-- Track connection state
M.connected = false
M.output_buf = nil
M.output_win = nil

-- Setup function
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})

    -- Setup filetype detection
    M.setup_filetype()

    -- Setup LSP if enabled
    if M.config.lsp.enabled then
        M.setup_lsp()
    end

    -- Setup commands
    M.setup_commands()

    -- Setup keymaps
    M.setup_keymaps()

    -- Setup diagnostics UI
    if M.config.ui.show_diagnostics then
        M.setup_diagnostics()
    end
end

-- Filetype detection
function M.setup_filetype()
    vim.filetype.add({
        extension = {
            gql = "gql",
            gcypher = "gql",
            cypher = "gql",
            pgql = "gql",
        },
    })
end

-- LSP setup
function M.setup_lsp()
    local lspconfig_ok, lspconfig = pcall(require, "lspconfig")
    local configs_ok, configs = pcall(require, "lspconfig.configs")

    if not lspconfig_ok or not configs_ok then
        vim.notify("nvim-lspconfig not found. LSP features disabled.", vim.log.levels.WARN)
        return
    end

    -- Register geode LSP if not already registered
    if not configs.geode_lsp then
        configs.geode_lsp = {
            default_config = {
                cmd = M.config.lsp.cmd,
                filetypes = M.config.lsp.filetypes,
                root_dir = function(fname)
                    return M.config.lsp.root_dir or vim.fn.getcwd()
                end,
                settings = {},
                init_options = {},
            },
            docs = {
                description = [[
Geode GQL Language Server

Provides diagnostics, hover, completion, and formatting for GQL/Cypher queries.

Install geode and ensure it's in your PATH:
  https://github.com/geode-db/geode
]],
            },
        }
    end

    -- Setup the LSP
    lspconfig.geode_lsp.setup({
        on_attach = function(client, bufnr)
            M.on_lsp_attach(client, bufnr)
        end,
        capabilities = M.get_capabilities(),
    })
end

-- Get LSP capabilities (with nvim-cmp support if available)
function M.get_capabilities()
    local capabilities = vim.lsp.protocol.make_client_capabilities()

    -- Add nvim-cmp capabilities if available
    local cmp_ok, cmp_lsp = pcall(require, "cmp_nvim_lsp")
    if cmp_ok then
        capabilities = cmp_lsp.default_capabilities(capabilities)
    end

    return capabilities
end

-- LSP attach callback
function M.on_lsp_attach(client, bufnr)
    local opts = { buffer = bufnr, silent = true }

    -- Hover
    if M.config.keymaps.show_docs then
        vim.keymap.set("n", M.config.keymaps.show_docs, vim.lsp.buf.hover, opts)
    end

    -- Go to definition
    vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)

    -- Format keymap
    if M.config.keymaps.format_buffer then
        vim.keymap.set("n", M.config.keymaps.format_buffer, function()
            vim.lsp.buf.format({ async = true })
        end, opts)
    end

    -- Set Geode LSP as the default formatter for this buffer
    if client.server_capabilities.documentFormattingProvider then
        vim.bo[bufnr].formatexpr = "v:lua.vim.lsp.formatexpr()"

        -- Format on save if enabled
        if M.config.format.format_on_save then
            vim.api.nvim_create_autocmd("BufWritePre", {
                buffer = bufnr,
                callback = function()
                    vim.lsp.buf.format({
                        async = false,
                        bufnr = bufnr,
                        filter = function(c)
                            return c.name == "geode_lsp"
                        end,
                    })
                end,
                desc = "Format GQL file on save using Geode LSP",
            })
        end
    end

    vim.notify("Geode LSP attached", vim.log.levels.INFO)
end

-- Setup diagnostics display
function M.setup_diagnostics()
    vim.diagnostic.config({
        virtual_text = M.config.ui.virtual_text,
        signs = M.config.ui.signs,
        underline = true,
        update_in_insert = false,
        severity_sort = true,
        float = {
            border = M.config.ui.float_border,
            source = "always",
        },
    })

    -- Define diagnostic signs
    local signs = {
        Error = " ",
        Warn = " ",
        Hint = " ",
        Info = " ",
    }
    for type, icon in pairs(signs) do
        local hl = "DiagnosticSign" .. type
        vim.fn.sign_define(hl, { text = icon, texthl = hl, numhl = "" })
    end
end

-- Setup commands
function M.setup_commands()
    vim.api.nvim_create_user_command("GeodeRunQuery", function()
        M.run_query()
    end, { desc = "Run the current buffer as a GQL query" })

    vim.api.nvim_create_user_command("GeodeRunSelection", function()
        M.run_selection()
    end, { range = true, desc = "Run selected text as a GQL query" })

    vim.api.nvim_create_user_command("GeodeExplain", function()
        M.explain_query()
    end, { desc = "Explain the query execution plan" })

    vim.api.nvim_create_user_command("GeodeConnect", function(opts)
        M.connect_server(opts.args)
    end, { nargs = "?", desc = "Connect to Geode server [host:port]" })

    vim.api.nvim_create_user_command("GeodeDisconnect", function()
        M.disconnect_server()
    end, { desc = "Disconnect from Geode server" })

    vim.api.nvim_create_user_command("GeodeStatus", function()
        M.show_status()
    end, { desc = "Show Geode connection status" })

    vim.api.nvim_create_user_command("GeodeRestartLsp", function()
        vim.cmd("LspRestart geode_lsp")
        vim.notify("Geode LSP restarted", vim.log.levels.INFO)
    end, { desc = "Restart Geode LSP" })
end

-- Setup keymaps
function M.setup_keymaps()
    -- Only set keymaps for GQL filetypes (including graphql for vim-graphql compat)
    vim.api.nvim_create_autocmd("FileType", {
        pattern = { "gql", "cypher", "gcypher", "pgql", "graphql" },
        callback = function(ev)
            local opts = { buffer = ev.buf, silent = true }

            if M.config.keymaps.run_query then
                vim.keymap.set("n", M.config.keymaps.run_query, M.run_query, opts)
            end

            if M.config.keymaps.run_selection then
                vim.keymap.set("v", M.config.keymaps.run_selection, M.run_selection, opts)
            end

            if M.config.keymaps.explain_query then
                vim.keymap.set("n", M.config.keymaps.explain_query, M.explain_query, opts)
            end
        end,
    })
end

-- Run query from current buffer
function M.run_query()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local query = table.concat(lines, "\n")
    M.execute_query(query)
end

-- Run selected text as query
function M.run_selection()
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    local lines = vim.api.nvim_buf_get_lines(0, start_pos[2] - 1, end_pos[2], false)

    if #lines == 0 then
        vim.notify("No selection", vim.log.levels.WARN)
        return
    end

    -- Trim selection on first and last lines
    if #lines == 1 then
        lines[1] = string.sub(lines[1], start_pos[3], end_pos[3])
    else
        lines[1] = string.sub(lines[1], start_pos[3])
        lines[#lines] = string.sub(lines[#lines], 1, end_pos[3])
    end

    local query = table.concat(lines, "\n")
    M.execute_query(query)
end

-- Explain query plan
function M.explain_query()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local query = "EXPLAIN " .. table.concat(lines, "\n")
    M.execute_query(query)
end

-- Execute query via geode CLI
function M.execute_query(query)
    local host = M.config.server.host
    local port = M.config.server.port

    local cmd = {
        "geode", "query",
        "--server", string.format("%s:%d", host, port),
        "--format", M.config.query.output_format,
        query,
    }

    vim.notify("Executing query...", vim.log.levels.INFO)

    vim.fn.jobstart(cmd, {
        stdout_buffered = true,
        stderr_buffered = true,
        on_stdout = function(_, data)
            if data and #data > 0 then
                M.show_output(data, "Query Results")
            end
        end,
        on_stderr = function(_, data)
            if data and #data > 0 and data[1] ~= "" then
                M.show_output(data, "Query Error")
            end
        end,
        on_exit = function(_, code)
            if code ~= 0 then
                vim.notify("Query failed with exit code: " .. code, vim.log.levels.ERROR)
            end
        end,
    })
end

-- Show output in a floating window
function M.show_output(lines, title)
    -- Filter empty lines
    local filtered = {}
    for _, line in ipairs(lines) do
        if line ~= "" then
            table.insert(filtered, line)
        end
    end

    if #filtered == 0 then
        return
    end

    -- Create buffer
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, filtered)
    vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(buf, "filetype", "json")

    -- Calculate window size
    local width = math.min(100, vim.o.columns - 10)
    local height = math.min(#filtered + 2, vim.o.lines - 10)

    -- Create floating window
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = M.config.ui.float_border,
        title = " " .. title .. " ",
        title_pos = "center",
    })

    -- Close on q or <Esc>
    vim.keymap.set("n", "q", function()
        vim.api.nvim_win_close(win, true)
    end, { buffer = buf })
    vim.keymap.set("n", "<Esc>", function()
        vim.api.nvim_win_close(win, true)
    end, { buffer = buf })

    M.output_buf = buf
    M.output_win = win
end

-- Connect to server
function M.connect_server(addr)
    if addr and addr ~= "" then
        local host, port = addr:match("([^:]+):?(%d*)")
        if host then
            M.config.server.host = host
        end
        if port and port ~= "" then
            M.config.server.port = tonumber(port)
        end
    end

    local host = M.config.server.host
    local port = M.config.server.port

    vim.notify(string.format("Connecting to %s:%d...", host, port), vim.log.levels.INFO)

    -- Test connection with a simple query
    local cmd = {
        "geode", "query",
        "--server", string.format("%s:%d", host, port),
        "RETURN 1",
    }

    vim.fn.jobstart(cmd, {
        on_exit = function(_, code)
            if code == 0 then
                M.connected = true
                vim.notify(string.format("Connected to Geode at %s:%d", host, port), vim.log.levels.INFO)
            else
                M.connected = false
                vim.notify("Failed to connect to Geode server", vim.log.levels.ERROR)
            end
        end,
    })
end

-- Disconnect from server
function M.disconnect_server()
    M.connected = false
    vim.notify("Disconnected from Geode server", vim.log.levels.INFO)
end

-- Show status
function M.show_status()
    local status = {
        "Geode Status:",
        "-------------",
        string.format("Connected: %s", M.connected and "Yes" or "No"),
        string.format("Server: %s:%d", M.config.server.host, M.config.server.port),
        string.format("LSP Enabled: %s", M.config.lsp.enabled and "Yes" or "No"),
    }

    -- Check LSP status
    local clients = vim.lsp.get_active_clients({ name = "geode_lsp" })
    if #clients > 0 then
        table.insert(status, "LSP Status: Active")
    else
        table.insert(status, "LSP Status: Not attached")
    end

    vim.notify(table.concat(status, "\n"), vim.log.levels.INFO)
end

-- Statusline component
function M.statusline()
    local clients = vim.lsp.get_active_clients({ name = "geode_lsp" })
    if #clients > 0 then
        if M.connected then
            return " Geode"
        else
            return " Geode LSP"
        end
    end
    return ""
end

return M
