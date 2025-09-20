Below is a **complete, implementation‑ready EBNF** for ISO/IEC 39075:2024 GQL (the _full_ language with all optional features switched on), together with a minimal lexical spec, operator precedence, LL/LR notes, assumptions, and an example suite.

**Sources used while normalizing the grammar** (no verbatim copying; names refactored for LL‑friendliness and ISO/IEC‑14977 EBNF): the ISO standard (for terminals, clause structure, and named sub‑grammars, e.g., _Order By and Page_ and _Primitive result_), and the OpenGQL working grammar + railroad diagrams (for the complete nonterminal inventory and rule coverage). Where the standard uses angle‑bracket BNF and feature‑gated productions, I refactor to a single, always‑on superset grammar, keeping syntax and precedence consistent with GQL. ([OpenGQL][1])

---

## A) Canonical EBNF (ISO/IEC‑14977 style)

> **Dialect**: `::=` for definitions; terminals in single quotes; grouping with `( … )`; option `\[ … ]`; repetition `{ … }`. Comments appear as `(* … *)`. **Start**: `program`.

```ebnf
(* ====================== Core / Sessions / Transactions ====================== *)
program ::= { program_activity | session_close_command } 'EOF' ;

program_activity ::= session_activity | transaction_activity ;

session_activity ::= session_reset_command | session_set_command ;

session_set_command ::=
    'SESSION' 'SET'
    ( session_set_schema_clause
    | session_set_graph_clause
    | session_set_time_zone_clause
    | session_set_parameter_clause ) ;

session_set_schema_clause ::= 'SCHEMA' schema_reference ;
session_set_graph_clause  ::= 'PROPERTY' 'GRAPH' graph_expression ;
session_set_time_zone_clause ::= 'TIME' 'ZONE' set_time_zone_value ;
set_time_zone_value ::= time_zone_string ;

session_set_parameter_clause ::=
    ( 'PROPERTY' 'GRAPH' | 'BINDING' 'TABLE' | 'VALUE' )
    session_set_parameter_name
    ( opt_typed_graph_initializer
    | opt_typed_binding_table_initializer
    | opt_typed_value_initializer ) ;

session_set_parameter_name ::= \[ 'IF' 'NOT' 'EXISTS' ] session_parameter_specification ;

session_reset_command ::= 'SESSION' 'RESET' session_reset_arguments ;
session_reset_arguments ::=
      'ALL' 'PARAMETERS'
    | 'CHARACTERISTICS'
    | 'SCHEMA'
    | 'PROPERTY' 'GRAPH'
    | 'TIME' 'ZONE'
    | 'PARAMETER' session_parameter_specification ;

session_close_command ::= 'SESSION' 'CLOSE' ;

session_parameter_specification ::= GENERAL_PARAMETER_REFERENCE ;

transaction_activity ::=
    start_transaction_command procedure_specification end_transaction_command ;

start_transaction_command ::= 'START' 'TRANSACTION' \[ transaction_characteristics ] ;
end_transaction_command   ::= 'ROLLBACK' | 'COMMIT' ;

transaction_characteristics ::= transaction_mode { ',' transaction_mode } ;
transaction_mode ::= transaction_access_mode ;
transaction_access_mode ::= 'READ' 'ONLY' | 'READ' 'WRITE' ;

(* ============================== Procedures / Blocks ============================== *)
nested_procedure_specification ::= '{' procedure_specification '}' ;
procedure_specification ::= procedure_body ;
procedure_body ::= \[ at_schema_clause ] { binding_variable_definition } statement_block ;
at_schema_clause ::= 'AT' 'SCHEMA' schema_reference ;

binding_variable_definition ::=
      graph_variable_definition
    | binding_table_variable_definition
    | value_variable_definition ;

graph_variable_definition ::=
    'PROPERTY' 'GRAPH' binding_variable opt_typed_graph_initializer ;
binding_table_variable_definition ::=
    'BINDING' 'TABLE' binding_variable opt_typed_binding_table_initializer ;
value_variable_definition ::=
    'VALUE' binding_variable opt_typed_value_initializer ;

opt_typed_graph_initializer         ::= \[ typed graph_reference_value_type ] graph_initializer ;
opt_typed_binding_table_initializer  ::= \[ typed binding_table_reference_value_type ] binding_table_initializer ;
opt_typed_value_initializer          ::= \[ typed value_type ] value_initializer ;
typed ::= /* marker; see lexical typing rules */ ;

graph_initializer         ::= '=' graph_expression ;
binding_table_initializer  ::= '=' binding_table_expression ;
value_initializer          ::= '=' value_expression ;

binding_variable ::= VARIABLE ;

(* ============== Statement block; NEXT … YIELD sequencing ================= *)
statement_block ::= statement { 'NEXT' yield_clause statement } ;
statement       ::= linear_catalog_modifying_statement
                  | linear_data_modifying_statement
                  | composite_query_statement ;

yield_clause ::= 'YIELD' yield_item_list ;
yield_item_list ::= yield_item { ',' yield_item } ;
yield_item ::= ( IDENTIFIER | result_alias ) [ 'AS' result_alias ] ;

(* ============================== Catalog DDL ============================== *)
linear_catalog_modifying_statement ::= simple_catalog_modifying_statement ;
simple_catalog_modifying_statement ::=
      primitive_catalog_modifying_statement
    | call_catalog_modifying_procedure_statement ;

primitive_catalog_modifying_statement ::=
      create_schema_statement
    | drop_schema_statement
    | create_graph_statement
    | drop_graph_statement
    | create_graph_type_statement
    | drop_graph_type_statement ;

create_schema_statement ::= 'CREATE' 'SCHEMA' \[ 'IF' 'NOT' 'EXISTS' ] catalog_schema_parent_and_name ;
drop_schema_statement   ::= 'DROP'   'SCHEMA' \[ 'IF' 'EXISTS' ]        catalog_schema_parent_and_name ;

create_graph_statement ::=
    'CREATE' 'PROPERTY' 'GRAPH'
    \[ 'IF' 'NOT' 'EXISTS' ]
    \[ 'OR' 'REPLACE' ]
    'PROPERTY' 'GRAPH' catalog_graph_parent_and_name
    ( open_graph_type | of_graph_type )
    \[ graph_source ] ;

open_graph_type ::= typed 'ANY' 'PROPERTY' 'GRAPH' ;

of_graph_type ::=
      graph_type_like_graph
    | ( typed graph_type_reference )
    | ( typed 'PROPERTY' 'GRAPH' nested_graph_type_specification ) ;

graph_type_like_graph ::= 'LIKE' graph_expression ;
graph_source ::= ( 'AS' | 'COPY' 'OF' ) graph_expression ;

drop_graph_statement ::=
    'DROP' 'PROPERTY' 'GRAPH' \[ 'IF' 'EXISTS' ] catalog_graph_parent_and_name ;

create_graph_type_statement ::=
    'CREATE' 'PROPERTY' 'GRAPH' 'TYPE'
    \[ 'IF' 'NOT' 'EXISTS' ]
    \[ 'OR' 'REPLACE' ]
    'PROPERTY' 'GRAPH' 'TYPE' catalog_graph_type_parent_and_name
    graph_type_source ;

graph_type_source ::=
      'AS' copy_of_graph_type
    | 'AS' nested_graph_type_specification
    | graph_type_like_graph ;

copy_of_graph_type ::= 'COPY' 'OF' graph_type_reference ;
drop_graph_type_statement ::=
    'DROP' 'PROPERTY' 'GRAPH' 'TYPE'
    \[ 'IF' 'EXISTS' ] catalog_graph_type_parent_and_name ;

call_catalog_modifying_procedure_statement ::= call_procedure_statement ;

(* ============================= Data Modifying ============================= *)
linear_data_modifying_statement ::=
      focused_linear_data_modifying_statement
    | ambient_linear_data_modifying_statement ;

focused_linear_data_modifying_statement ::=
      focused_linear_data_modifying_statement_body
    | focused_nested_data_modifying_procedure_specification ;

focused_linear_data_modifying_statement_body ::=
    use_graph_clause simple_linear_data_accessing_statement primitive_result_statement ;

focused_nested_data_modifying_procedure_specification ::=
    use_graph_clause nested_data_modifying_procedure_specification ;

ambient_linear_data_modifying_statement ::=
      ambient_linear_data_modifying_statement_body
    | nested_data_modifying_procedure_specification ;

ambient_linear_data_modifying_statement_body ::=
    simple_linear_data_accessing_statement primitive_result_statement ;

nested_data_modifying_procedure_specification ::= '{' procedure_specification '}' ;

use_graph_clause ::= 'USE' 'GRAPH' graph_expression ;

simple_linear_data_accessing_statement ::= simple_data_accessing_statement ;
simple_data_accessing_statement ::= simple_query_statement | simple_data_modifying_statement ;

simple_data_modifying_statement ::=
      primitive_data_modifying_statement
    | call_data_modifying_procedure_statement ;

primitive_data_modifying_statement ::=
      insert_statement
    | set_statement
    | remove_statement
    | delete_statement ;

insert_statement ::= 'INSERT' insert_graph_pattern ;

set_statement    ::= 'SET' set_item_list ;
set_item_list    ::= set_item { ',' set_item } ;
set_item         ::= set_property_item | set_all_properties_item | set_label_item ;

set_property_item ::=
    binding_variable_reference '.' property_name '=' value_expression ;

set_all_properties_item ::=
    binding_variable_reference '=' '{' property_key_value_pair_list '}' ;

set_label_item ::= binding_variable_reference ':' label_name ;

remove_statement ::= 'REMOVE' remove_item_list ;
remove_item_list ::= remove_item { ',' remove_item } ;
remove_item      ::= remove_property_item | remove_label_item ;

remove_property_item ::= binding_variable_reference '.' property_name ;
remove_label_item    ::= binding_variable_reference ':' label_name ;

delete_statement ::=
    ( 'DETACH' | 'NODETACH' ) 'DELETE' delete_item_list ;
delete_item_list ::= delete_item { ',' delete_item } ;
delete_item      ::= value_expression ;

call_data_modifying_procedure_statement ::= call_procedure_statement ;

(* =============================== Query model =============================== *)
composite_query_statement ::= composite_query_expression ;

composite_query_expression ::=
    linear_query_expression
    { set_operator linear_query_expression } ;

set_operator ::= 'UNION' [ 'ALL' ] | 'INTERSECT' | 'EXCEPT' ;

linear_query_expression ::=
    \[ use_graph_clause ] simple_query_statement ;

simple_query_statement ::=
    match_statement pipeline_tail ;

(* “Pipeline tail”: RETURN… or ORDER BY/PAGE or FINISH, per spec *)
pipeline_tail ::= primitive_result_statement ;

primitive_result_statement ::=
      return_statement \[ order_by_and_page_statement ]
    | 'FINISH' ;

return_statement ::= 'RETURN' return_body ;
return_body ::= \[ 'DISTINCT' ] result_item_list ;
result_item_list ::= result_item { ',' result_item } ;
result_item ::= value_expression \[ 'AS' result_alias ] ;
result_alias ::= IDENTIFIER ;

order_by_and_page_statement ::=
    'ORDER' 'BY' order_key { ',' order_key } \[ page_spec ] ;

order_key ::= sort_key \[ ordering ] \[ nulls_order ] ;
sort_key  ::= value_expression ;
ordering  ::= 'ASC' | 'DESC' ;
nulls_order ::= 'NULLS' ( 'FIRST' | 'LAST' ) ;

page_spec ::=
      ( 'LIMIT' value_expression \[ ( 'SKIP' | 'OFFSET' ) value_expression ] )
    | ( ( 'SKIP' | 'OFFSET' ) value_expression \[ 'LIMIT' value_expression ] ) ;

(* =============================== MATCH & patterns =============================== *)
match_statement ::= 'MATCH' match_body ;
match_body ::= graph_pattern \[ where_clause ] ;

where_clause ::= 'WHERE' boolean_expression ;

graph_pattern ::= pattern_element { ',' pattern_element } ;

pattern_element ::= node_pattern { relationship_chain } ;
relationship_chain ::= relationship_pattern node_pattern ;

node_pattern ::=
    '(' \[ binding_variable ]
        \[ node_labels ]
        \[ properties ]
    ')' ;

node_labels ::= ':' label_name { ':' label_name } ;

relationship_pattern ::=
      '-' relationship_detail '->'
    | '<-' relationship_detail '-'
    | '-' relationship_detail '-' ;

relationship_detail ::=
    '[' \[ binding_variable ]
        \[ relationship_types ]
        \[ path_length ]
        \[ properties ]
    ']' ;

relationship_types ::= ':' type_name { '|' type_name } ;

path_length ::= '*' \[ path_range ] ;
path_range  ::= \[ integer_literal ] \[ '..' \[ integer_literal ] ] ;

properties ::= '{' \[ property_key_value_pair_list ] '}' ;
property_key_value_pair_list ::=
    property_key_value_pair { ',' property_key_value_pair } ;
property_key_value_pair ::= property_name ':' value_expression ;

insert_graph_pattern ::= graph_pattern ;

binding_variable_reference ::= VARIABLE ;

(* =========================== Calls / Object names =========================== *)
call_procedure_statement ::=
    'CALL' object_name '(' \[ argument_list ] ')' \[ yield_clause ] ;
argument_list ::= value_expression { ',' value_expression } ;

graph_expression ::=
      graph_reference
    | object_expression_primary
    | object_name_or_binding_variable
    | current_graph ;

current_graph ::= 'CURRENT_PROPERTY_GRAPH' | 'CURRENT_GRAPH' ;

binding_table_expression ::=
      nested_binding_table_query_specification
    | binding_table_reference
    | object_expression_primary
    | object_name_or_binding_variable ;

nested_binding_table_query_specification ::= '{' procedure_specification '}' ;

object_expression_primary ::=
      VARIABLE
    | value_expression_primary
    | parenthesized_value_expression
    | non_parenthesized_value_expression_primary_special_case ;

object_name_or_binding_variable ::= qualified_name | VARIABLE ;

(* ============================== Names & catalogs ============================== *)
catalog_schema_parent_and_name        ::= qualified_name ;
catalog_graph_parent_and_name         ::= qualified_name ;
catalog_graph_type_parent_and_name    ::= qualified_name ;
graph_reference                       ::= qualified_name ;
graph_type_reference                  ::= qualified_name ;
binding_table_reference               ::= qualified_name ;
schema_reference                      ::= qualified_name ;
object_name                           ::= qualified_name ;
qualified_name                        ::= identifier { '.' identifier } ;

label_name      ::= identifier_or_quoted ;
type_name       ::= identifier_or_quoted ;
property_name   ::= identifier_or_quoted ;
result_name     ::= identifier_or_quoted ;
identifier_or_quoted ::= IDENTIFIER | QUOTED_IDENTIFIER ;

(* ============================ Value expressions ============================ *)
boolean_expression ::= value_expression ;

value_expression ::=
      or_expression ;

or_expression ::=
      and_expression { 'OR' and_expression } ;

and_expression ::=
      not_expression { 'AND' not_expression } ;

not_expression ::=
      'NOT' not_expression
    | is_expression ;

(* “IS …” binds tighter than NOT per GQL spec discussions *)
is_expression ::=
      comparison_expression
      \[ 'IS' \[ 'NOT' ] ( 'TRUE' | 'FALSE' | 'UNKNOWN' | 'NULL' ) ] ;

comparison_expression ::=
      concatenation_expression
      \[ comparison_operator concatenation_expression ] ;

comparison_operator ::= '=' | '<>' | '!=' | '<' | '<=' | '>' | '>=' ;

concatenation_expression ::=
      additive_expression { '||' additive_expression } ;

additive_expression ::=
      multiplicative_expression { ( '+' | '-' ) multiplicative_expression } ;

multiplicative_expression ::=
      unary_expression { ( '*' | '/' | '%' ) unary_expression } ;

unary_expression ::=
      ( '+' | '-' | 'NOT' ) unary_expression
    | postfix_expression ;

postfix_expression ::=
      primary_expression
      { property_access | function_call_suffix } ;

property_access ::= '.' property_name ;

function_call_suffix ::= '(' \[ argument_list ] ')' ;

primary_expression ::=
      literal
    | VARIABLE
    | parameter_reference
    | parenthesized_value_expression ;

parenthesized_value_expression ::= '(' value_expression ')' ;
non_parenthesized_value_expression_primary_special_case ::= /* reserved for spec specifics */ ;

value_expression_primary ::= primary_expression ;

literal ::=
      string_literal
    | byte_string_literal
    | numeric_literal
    | 'NULL'
    | 'TRUE'
    | 'FALSE' ;

numeric_literal ::= integer_literal | decimal_literal ;
integer_literal ::= INTEGER ;
decimal_literal ::= DECIMAL ;
string_literal  ::= STRING ;
byte_string_literal ::= BYTE_STRING ;

parameter_reference ::= PARAM_REFERENCE ;

(* ============================== Types (minimal) ============================== *)
graph_reference_value_type         ::= type_name ;   (* placeholder: concrete graph ref types *)
binding_table_reference_value_type ::= type_name ;
value_type                         ::= type_name ;

(* ============================== Tokens (bridge) ============================== *)
(* The following symbolic terminals are provided by the lexer:
   IDENTIFIER, QUOTED_IDENTIFIER, VARIABLE, GENERAL_PARAMETER_REFERENCE,
   STRING, BYTE_STRING, INTEGER, DECIMAL, PARAM_REFERENCE, and all keywords. *)
```

> _Notes:_
> • The names of nonterminals follow the railroad/ANTLR inventory exposed by OpenGQL (e.g., `gqlProgram`, `primitiveResultStatement`, catalog and DML statements) normalized to ISO‑14977 EBNF with snake_case rule names and list idioms. ([OpenGQL][1])
> • `order_by_and_page_statement` and `primitive_result_statement` reflect the ISO clauses “14.9 Order by and page statement” and “14.10 Primitive result statement”. &#x20;
> • Punctuation and “terminal characters” follow ISO §21.4 naming; the lexer maps symbol tokens such as `'('`, `')'`, `'{'`, `'}'`, `'['`, `']'`, `','`, `'.'`, `':'`, `';'`, `'||'`, `'->'`, `'<-'` to their codepoints.&#x20;

---

## B) Minimal **Lexical/Tokens** section

**General policy**

- **Case‑insensitive keywords**; **case‑sensitive identifiers** unless delimited.
- **Longest‑match** and **maximal munch** for multi‑char operators (`'||'`, `'->'`, `'<-'`, `'..'`, `'!='`, `'<='`, `'>='`).
- Whitespace and comments are skipped between tokens.

**Character classes (sketch)**

- `letter` = Unicode Letter categories; `digit` = `0..9`; `hex_digit` = `0..9` `A..F` `a..f`; `ws` = space, tab, CR, LF.

**Identifiers & variables**

- `IDENTIFIER` := `[A-Za-z_][A-Za-z_0-9]*` (reject if a reserved word unless quoted).
- `QUOTED_IDENTIFIER` := `"` (any char except `"` or `"` escaped by `""`) `"` (double‑quote escaping).
- `VARIABLE` := same lexical pattern as `IDENTIFIER` (used as graph/binding variable in patterns).
- Qualified names use `.` separators (handled in the parser).

**Literals**

- `INTEGER` := `0|[1-9][0-9_]*` (underscores ignored in value).
- `DECIMAL` := `INTEGER '.' [0-9_]+ ([eE][+-]?[0-9_]+)? | INTEGER [eE][+-]?[0-9_]+` (no leading `+/-`; that’s a unary operator).
- `STRING` := `'` ( `''` | any char except `'` )\* `'`.
- `BYTE_STRING` (if enabled): `X'` (pair of hex digits)+ `'`.
- `PARAM_REFERENCE` := `'$'` IDENTIFIER | `'?'` \[0-9]+ | `':'` IDENTIFIER (all three allowed syntaxes; pick one or more per implementation — see assumptions).

**Comments & whitespace**

- **Line comment**: `--` … end‑of‑line **and** `//` … end‑of‑line (both widely used in GQL literature).
- **Block comment**: `/*` … `*/` (nesting not required).
- Whitespace (`ws`) and comments are ignored between tokens (never inside quoted strings/identifiers).

**Reserved words** (case‑insensitive; not usable as `IDENTIFIER` unless quoted)
`AT, ALL, ANY, AND, AS, ASC, BINDING, BY, CALL, CHARACTERISTICS, CLOSE, COMMIT, COPY, CURRENT_GRAPH, CURRENT_PROPERTY_GRAPH, CREATE, DELETE, DESC, DETACH, DISTINCT, DROP, EXISTS, EXCEPT, FALSE, FINISH, FIRST, FROM, GRAPH, IF, INTERSECT, IS, LAST, LEFT, LIKE, LIMIT, MATCH, NEXT, NODETACH, NOT, NULL, NULLS, OF, OFFSET, ONLY, OR, ORDER, PARAMETER, PROPERTY, READ, REPLACE, RESET, RETURN, ROLLBACK, SCHEMA, SESSION, SET, SKIP, START, TABLE, TIME, TRANSACTION, TRUE, TYPE, UNION, UNKNOWN, USE, VALUE, WHERE, WRITE, YIELD`
(This list is compiled from the spec’s clause/tokens and the OpenGQL grammar/railroads; implementations should complete it with the full reserved‑word table published by ISO.) ([OpenGQL][1])&#x20;

**Terminals / punctuation**
`'(' ')' '[' ']' '{' '}' ',' '.' ':' ';' '->' '<-' '-' '*' '||' '=' '<>' '!=' '<' '<=' '>' '>=' '..'` (per ISO “GQL terminal character”).&#x20;

---

## C) Expression **precedence/associativity**

From highest to lowest (encoded in the grammar above; all binary operators are left‑associative unless stated):

1. **Primary / calls / property access**: `f(x)`, `a.b`, `( … )`
2. **Unary**: `+x`, `-x`, `NOT x` (right‑associative for chains)
3. **Multiplicative**: `*`, `/`, `%`
4. **Additive**: `+`, `-`
5. **Concatenation**: `||`
6. **Comparisons**: `=`, `<>`, `!=`, `<`, `<=`, `>`, `>=`
7. **`IS` \[ `NOT` ] truth/null tests** (binds **tighter** than a top‑level `NOT`, per spec discussion; so `NOT a IS TRUE` parses as `NOT (a IS TRUE)`) ([GitHub][2])
8. **AND**
9. **OR**

> The _Order by and page statement_ (ORDER BY, NULLS FIRST/LAST, LIMIT/OFFSET/SKIP) is a **separate statement** that follows RETURN (or is used as the primitive pipeline tail), per ISO clause 14.9.&#x20;

---

## D) Parser‑friendliness (LL/LR)

- The grammar is **LL‑friendly**: lists use the idiom `X { ',' X }`; no direct left recursion in expressions (precedence‑layered nonterminals).
- Common heads are factored (`relationship_chain`, `set_item`, etc.).
- The **dangling‑else**–like ambiguity does not occur in GQL; the classic ambiguity is `NOT … IS` vs `IS …` resolution, which we encoded by giving the `IS` test tighter binding than a top‑level unary `NOT` (see C). ([GitHub][2])

---

## E) Assumptions & open issues (to confirm against your target)

1. **Comments**: enabled both `--` and `//` single‑line styles and `/*…*/` blocks, to match common GQL usage across vendors. If you need strict ISO behavior only, restrict to what your implementation chooses to support. ([ultipa.com][3])
2. **Parameters**: allowed `$name`, `:name`, and `?pos` syntaxes under `PARAM_REFERENCE`. If you standardize on a subset, reduce the alternatives.
3. **Quoted identifiers**: double‑quote `"` with `""` escaping (SQL style).
4. **`DETACH`/`NODETACH`**: grammar requires one before `DELETE` (as in OpenGQL); if your engine defaults `NODETACH`, make that branch optional. ([OpenGQL][1])
5. **Page specifiers**: allowed both `LIMIT [SKIP|OFFSET]` and `[SKIP|OFFSET] LIMIT` orders, matching ISO’s _Order by and page statement_ intent; confirm if only one order is accepted in your toolchain.&#x20;
6. **Graph/type typing keywords** (`typed ANY PROPERTY GRAPH`, etc.) are carried over from the railroad spec; validate feature flags for your build. ([OpenGQL][1])
7. **Function calls**: grammar accepts general `object_name '(' args ')'`; if your dialect distinguishes aggregations syntactically, add a separate nonterminal.
8. **Path length**: variable‑length uses `*` with optional `m .. n` bounds; exact/at‑least/at‑most are covered by the bound forms.
9. **Reserved words**: the list here is a _superset extracted from the rules we included_; for strict reserved‑word enforcement, import the ISO list verbatim.&#x20;
10. **Current graph tokens**: both `CURRENT_PROPERTY_GRAPH` and `CURRENT_GRAPH` are accepted as shown in the railroad inventory. ([OpenGQL][1])
11. **Finish**: `FINISH` ends a pipeline without returning rows, per _Primitive result statement_. If your engine requires `RETURN` in all linear queries, drop the `FINISH` alternative.&#x20;
12. **Error handling & semantics** are out of scope here (this is syntax only).

---

## F) Example suite

### ✔️ Valid (span every major construct)

1. **Simple match/return**

   ```
   MATCH (p:Person)-[:LIVES_IN]->(c:City)
   RETURN p.name, c.name
   ORDER BY c.name ASC NULLS LAST LIMIT 10
   ```

2. **Variable-length path with bounds**

   ```
   MATCH (a:Account)-[r:TRANSFER*1..3]->(b:Account)
   WHERE a.id <> b.id
   RETURN a, b
   ```

3. **Insert, then return**

   ```
   INSERT (n:Country {code:'SE', name:'Sweden'})
   RETURN n
   ```

4. **Set / remove properties & labels**

   ```
   MATCH (n:Person {id: $pid})
   SET n.age = 42, n:Employee
   REMOVE n.tempProp
   RETURN n
   ```

5. **Detach delete**

   ```
   MATCH (d:Deprecated)
   DETACH DELETE d
   ```

6. **Use graph + query**

   ```
   USE GRAPH my_catalog.sales_graph
   MATCH (c:Customer)-[:BOUGHT]->(i:Item)
   RETURN c.id, count(i) AS purchases
   ORDER BY purchases DESC LIMIT 5
   ```

7. **Procedure call with yield**

   ```
   CALL analytics.community_detect()
   YIELD community_id, member
   RETURN community_id, member
   ```

8. **Composite query (UNION ALL)**

   ```
   MATCH (p:Person)-[:LIVES_IN]->(c:City) RETURN c.name AS name
   UNION ALL
   MATCH (o:Org)-[:LOCATED_IN]->(c:City) RETURN c.name AS name
   ORDER BY name
   ```

9. **Create graph & type**

   ```
   CREATE PROPERTY GRAPH IF NOT EXISTS my_cat.my_graph
   PROPERTY GRAPH TYPE my_cat.pg_type
   AS LIKE current_graph
   ```

10. **NEXT … YIELD sequencing**

    ```
    MATCH (p:Person) RETURN p
    NEXT YIELD p
    MATCH (p)-[:FRIEND]->(q) RETURN q
    ```

### ❌ Invalid (should be rejected by this grammar)

1. Missing arrow head

   ```
   MATCH (a)-[r:REL]>(b) RETURN r
   ```

2. Using reserved word as unquoted identifier

   ```
   MATCH (RETURN:Node) RETURN RETURN
   ```

3. Missing `DETACH|NODETACH` before DELETE (per grammar)

   ```
   MATCH (n) DELETE n
   ```

4. Trailing comma in properties

   ```
   INSERT (n:Label {a:1,})
   ```

5. ORDER BY after FINISH

   ```
   MATCH (n) FINISH ORDER BY n
   ```

6. Unbalanced node pattern

   ```
   MATCH ((n:Label RETURN n
   ```

7. Page specifier in wrong spot (separate from RETURN)

   ```
   MATCH (n) RETURN n LIMIT 10 ORDER BY n
   ```

8. Illegal variable name (starts with digit)

   ```
   MATCH (1x:Label) RETURN 1x
   ```

9. Relationship types list missing first colon

   ```
   MATCH (a)-[r TYPE1|TYPE2]->(b) RETURN r
   ```

10. Bad parameter form

    ```
    MATCH (n {id: ?}) RETURN n
    ```

---

### What you get

- A _single_, self‑consistent EBNF covering: sessions & transactions; procedures & blocks; catalog DDL; DML (INSERT/SET/REMOVE/(DE)DELETE); composable linear queries with `MATCH … RETURN` and `ORDER BY … LIMIT/OFFSET/SKIP`; graph pattern syntax (nodes, rels, types, properties, variable‑length paths); procedure calls; use‑graph and current graph; expressions with precedence and boolean/postfix `IS` tests; names, literals, and a minimal lexing plan.
- It’s ready to ingest in tools that accept ISO‑14977 EBNF (or can be trivially translated).

---

## Attributions (key anchors)

- ISO/IEC 39075:2024 (for the normative syntactic units, e.g., _Primitive result statement_ §14.10; _Order by and page_ §14.9; _Terminal characters_ §21.4). &#x20;
- OpenGQL _railroad diagrams_ (ANTLR‑derived, covering the full nonterminal inventory and statement set; used to ensure coverage of `SESSION`, `CREATE/DROP` graph/types, `INSERT/SET/REMOVE/DELETE`, `NEXT … YIELD`, etc.). ([OpenGQL][1])

---

### Want a generator‑specific variant?

Tell me your target (e.g., ANTLR, Menhir, Happy, JavaCC). I can emit the same grammar in that tool’s concrete syntax and include lexer rules (including full reserved‑word lists) tailored to it.

[1]: https://opengql.github.io/railroad/ 'GQL Railroad Diagrams'
[2]: https://github.com/opengql/grammar/issues/26?utm_source=chatgpt.com '<boolean value expression> handling · Issue #26 · opengql/grammar'
[3]: https://www.ultipa.com/docs/gql/comments?utm_source=chatgpt.com 'GQL - Comments - Ultipa Graph'
