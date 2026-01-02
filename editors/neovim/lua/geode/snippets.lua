-- Geode GQL Snippets for Neovim
-- Compatible with LuaSnip

local M = {}

-- Check if LuaSnip is available
local luasnip_ok, ls = pcall(require, "luasnip")
if not luasnip_ok then
    return M
end

local s = ls.snippet
local t = ls.text_node
local i = ls.insert_node
local c = ls.choice_node
local f = ls.function_node

-- GQL Snippets
M.snippets = {
    -- Basic patterns
    s("match", {
        t("MATCH ("),
        i(1, "n"),
        t(":"),
        i(2, "Label"),
        t(")"),
        i(0),
    }),

    s("matchw", {
        t("MATCH ("),
        i(1, "n"),
        t(":"),
        i(2, "Label"),
        t(")"),
        t({ "", "WHERE " }),
        i(3, "n.property = value"),
        t({ "", "RETURN " }),
        i(4, "n"),
        i(0),
    }),

    s("matchr", {
        t("MATCH ("),
        i(1, "a"),
        t(":"),
        i(2, "Label"),
        t(")-["),
        i(3, "r"),
        t(":"),
        i(4, "REL_TYPE"),
        t("]->("),
        i(5, "b"),
        t(":"),
        i(6, "Label"),
        t(")"),
        t({ "", "RETURN " }),
        i(7, "a, r, b"),
        i(0),
    }),

    s("create", {
        t("CREATE ("),
        i(1, "n"),
        t(":"),
        i(2, "Label"),
        t(" {"),
        t({ "", "    " }),
        i(3, "property"),
        t(": "),
        i(4, "value"),
        t({ "", "})" }),
        i(0),
    }),

    s("creater", {
        t("CREATE ("),
        i(1, "a"),
        t(")-[:"),
        i(2, "REL_TYPE"),
        t(" {"),
        i(3, ""),
        t("}]->("),
        i(4, "b"),
        t(")"),
        i(0),
    }),

    s("merge", {
        t("MERGE ("),
        i(1, "n"),
        t(":"),
        i(2, "Label"),
        t(" {"),
        i(3, "key"),
        t(": "),
        i(4, "value"),
        t("})"),
        t({ "", "ON CREATE SET " }),
        i(5, "n.created = timestamp()"),
        t({ "", "ON MATCH SET " }),
        i(6, "n.updated = timestamp()"),
        i(0),
    }),

    s("delete", {
        t("MATCH ("),
        i(1, "n"),
        t(":"),
        i(2, "Label"),
        t(")"),
        t({ "", "WHERE " }),
        i(3, "n.property = value"),
        t({ "", "DELETE " }),
        i(4, "n"),
        i(0),
    }),

    s("detach", {
        t("MATCH ("),
        i(1, "n"),
        t(":"),
        i(2, "Label"),
        t(")"),
        t({ "", "WHERE " }),
        i(3, "n.property = value"),
        t({ "", "DETACH DELETE " }),
        i(4, "n"),
        i(0),
    }),

    -- Set and update
    s("set", {
        t("SET "),
        i(1, "n"),
        t("."),
        i(2, "property"),
        t(" = "),
        i(3, "value"),
        i(0),
    }),

    s("remove", {
        t("REMOVE "),
        i(1, "n"),
        t("."),
        i(2, "property"),
        i(0),
    }),

    -- Aggregation
    s("count", {
        t("MATCH ("),
        i(1, "n"),
        t(":"),
        i(2, "Label"),
        t(")"),
        t({ "", "RETURN count(" }),
        i(3, "n"),
        t(") AS "),
        i(4, "count"),
        i(0),
    }),

    s("group", {
        t("MATCH ("),
        i(1, "n"),
        t(":"),
        i(2, "Label"),
        t(")"),
        t({ "", "RETURN " }),
        i(3, "n.property"),
        t(", count(*) AS count"),
        t({ "", "ORDER BY count DESC" }),
        i(0),
    }),

    -- Vector operations (Geode-specific)
    s("vdist", {
        t("distance("),
        i(1, "v1"),
        t(", "),
        i(2, "v2"),
        t(", '"),
        c(3, {
            t("L2"),
            t("cosine"),
            t("manhattan"),
            t("dot_product"),
        }),
        t("')"),
        i(0),
    }),

    s("vsim", {
        t("similarity("),
        i(1, "v1"),
        t(", "),
        i(2, "v2"),
        t(")"),
        i(0),
    }),

    s("vknn", {
        t("MATCH ("),
        i(1, "n"),
        t(":"),
        i(2, "Label"),
        t(")"),
        t({ "", "WHERE distance(" }),
        i(3, "n.embedding"),
        t(", "),
        i(4, "$query_vector"),
        t(", 'L2') < "),
        i(5, "0.5"),
        t({ "", "RETURN " }),
        i(6, "n"),
        t({ "", "ORDER BY distance(" }),
        i(7, "n.embedding"),
        t(", "),
        i(8, "$query_vector"),
        t(", 'L2')"),
        t({ "", "LIMIT " }),
        i(9, "10"),
        i(0),
    }),

    s("vectorf32", {
        t("VectorF32(["),
        i(1, "0.1, 0.2, 0.3"),
        t("])"),
        i(0),
    }),

    -- Graph operations
    s("path", {
        t("MATCH path = ("),
        i(1, "start"),
        t(":"),
        i(2, "Label"),
        t(")-[*"),
        i(3, "1..5"),
        t("]->("),
        i(4, "end"),
        t(":"),
        i(5, "Label"),
        t(")"),
        t({ "", "RETURN path" }),
        i(0),
    }),

    s("shortest", {
        t("MATCH path = shortestPath(("),
        i(1, "start"),
        t(":"),
        i(2, "Label"),
        t(")-[*]->("),
        i(3, "end"),
        t(":"),
        i(4, "Label"),
        t("))"),
        t({ "", "RETURN path, length(path)" }),
        i(0),
    }),

    -- Control flow
    s("case", {
        t("CASE "),
        i(1, "expression"),
        t({ "", "    WHEN " }),
        i(2, "value1"),
        t(" THEN "),
        i(3, "result1"),
        t({ "", "    WHEN " }),
        i(4, "value2"),
        t(" THEN "),
        i(5, "result2"),
        t({ "", "    ELSE " }),
        i(6, "default"),
        t({ "", "END" }),
        i(0),
    }),

    s("foreach", {
        t("FOREACH ("),
        i(1, "x"),
        t(" IN "),
        i(2, "list"),
        t(" |"),
        t({ "", "    " }),
        i(3, "SET x.property = value"),
        t({ "", ")" }),
        i(0),
    }),

    s("unwind", {
        t("UNWIND "),
        i(1, "$list"),
        t(" AS "),
        i(2, "item"),
        t({ "", "" }),
        i(0),
    }),

    -- Transactions
    s("call", {
        t("CALL {"),
        t({ "", "    " }),
        i(1, "// subquery"),
        t({ "", "}" }),
        i(0),
    }),

    -- Schema operations
    s("creategraph", {
        t("CREATE GRAPH "),
        i(1, "graph_name"),
        t(" IF NOT EXISTS"),
        i(0),
    }),

    s("dropgraph", {
        t("DROP GRAPH "),
        i(1, "graph_name"),
        t(" IF EXISTS"),
        i(0),
    }),

    s("usegraph", {
        t("USE GRAPH "),
        i(1, "graph_name"),
        i(0),
    }),

    -- Index operations
    s("createindex", {
        t("CREATE INDEX "),
        i(1, "index_name"),
        t(" FOR ("),
        i(2, "n"),
        t(":"),
        i(3, "Label"),
        t(") ON ("),
        i(4, "n.property"),
        t(")"),
        i(0),
    }),

    s("dropindex", {
        t("DROP INDEX "),
        i(1, "index_name"),
        t(" IF EXISTS"),
        i(0),
    }),

    -- Comment templates
    s("header", {
        t("-- "),
        i(1, "Description"),
        t({ "", "-- Author: " }),
        i(2, "Author"),
        t({ "", "-- Date: " }),
        f(function()
            return os.date("%Y-%m-%d")
        end),
        t({ "", "", "" }),
        i(0),
    }),
}

-- Setup function
function M.setup()
    if not luasnip_ok then
        vim.notify("LuaSnip not found. Snippets disabled.", vim.log.levels.WARN)
        return
    end

    ls.add_snippets("gql", M.snippets)
    ls.add_snippets("cypher", M.snippets)
    ls.add_snippets("graphql", M.snippets)  -- vim-graphql compatibility
end

return M
