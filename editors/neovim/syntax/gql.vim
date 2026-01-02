" Vim syntax file
" Language: GQL (Graph Query Language) / Cypher
" Maintainer: Geode DB Team
" Latest Revision: 2025

if exists("b:current_syntax")
  finish
endif

" Case insensitive matching
syn case ignore

" Comments (must come first to take precedence)
syn match gqlComment "--.*$"
syn match gqlComment "//.*$"
syn region gqlComment start="/\*" end="\*/" contains=gqlTodo
syn keyword gqlTodo contained TODO FIXME XXX NOTE HACK BUG

" Keywords - Clauses
syn keyword gqlClause MATCH OPTIONAL WHERE RETURN WITH ORDER BY SKIP LIMIT
syn keyword gqlClause UNION ALL INTERSECT EXCEPT
syn keyword gqlClause UNWIND AS FOREACH IN
syn keyword gqlClause CALL YIELD

" Keywords - Data Modification
syn keyword gqlModify CREATE MERGE DELETE DETACH SET REMOVE
syn keyword gqlModify ON MATCH ON CREATE

" Keywords - Schema
syn keyword gqlSchema GRAPH INDEX CONSTRAINT UNIQUE EXISTS
syn keyword gqlSchema DROP USE IF NOT SCHEMA TYPE
syn keyword gqlSchema FOR REQUIRE ASSERT

" Keywords - Graph Operations
syn keyword gqlGraph NODE RELATIONSHIP EDGE PATH
syn keyword gqlGraph START END LENGTH NODES RELATIONSHIPS

" Keywords - Transaction
syn keyword gqlTransaction BEGIN COMMIT ROLLBACK TRANSACTION

" Keywords - Logical
syn keyword gqlLogical AND OR XOR NOT IS NULL TRUE FALSE
syn keyword gqlLogical IN CONTAINS STARTS ENDS WITH

" Keywords - Comparison
syn keyword gqlCompare DISTINCT ASC DESC ASCENDING DESCENDING
syn keyword gqlCompare CASE WHEN THEN ELSE END

" Keywords - Functions (common)
syn keyword gqlFunction count sum avg min max collect
syn keyword gqlFunction head tail last size length type id
syn keyword gqlFunction keys labels properties nodes relationships
syn keyword gqlFunction startNode endNode coalesce
syn keyword gqlFunction toString toInteger toFloat toBoolean
syn keyword gqlFunction abs ceil floor round sign rand
syn keyword gqlFunction log log10 exp sqrt pow
syn keyword gqlFunction sin cos tan asin acos atan atan2
syn keyword gqlFunction degrees radians pi e
syn keyword gqlFunction left right trim ltrim rtrim
syn keyword gqlFunction replace substring split reverse
syn keyword gqlFunction upper lower toLower toUpper
syn keyword gqlFunction date datetime time localtime localdatetime duration
syn keyword gqlFunction timestamp year month day hour minute second
syn keyword gqlFunction point distance
syn keyword gqlFunction range reduce extract filter all any none single
syn keyword gqlFunction shortestPath allShortestPaths

" Keywords - Geode-specific
syn keyword gqlGeode VectorF32 VectorI32 distance similarity
syn keyword gqlGeode EXPLAIN PROFILE

" Types
syn keyword gqlType INTEGER INT FLOAT DOUBLE STRING BOOLEAN BOOL
syn keyword gqlType LIST MAP ANY POINT DATE DATETIME DURATION
syn keyword gqlType VECTOR EMBEDDING

" Strings
syn region gqlString start=+"+ skip=+\\"+ end=+"+
syn region gqlString start=+'+ skip=+\\'+ end=+'+

" Numbers
syn match gqlNumber "\<\d\+\>"
syn match gqlNumber "\<\d\+\.\d*\>"
syn match gqlNumber "\<\.\d\+\>"
syn match gqlNumber "\<\d\+[eE][+-]\=\d\+\>"
syn match gqlNumber "\<\d\+\.\d*[eE][+-]\=\d\+\>"
syn match gqlNumber "\<0[xX][0-9a-fA-F]\+\>"

" Parameters
syn match gqlParameter "\$[a-zA-Z_][a-zA-Z0-9_]*"

" Labels and relationship types
syn match gqlLabel ":[a-zA-Z_][a-zA-Z0-9_]*" contained
syn match gqlRelType "\[:[a-zA-Z_][a-zA-Z0-9_|]*\]"

" Node patterns
syn region gqlNode start="(" end=")" contains=gqlLabel,gqlString,gqlNumber,gqlParameter,gqlProperty transparent

" Property keys in braces
syn region gqlProperty start="{" end="}" contains=gqlString,gqlNumber,gqlParameter,gqlLogical transparent

" Operators
syn match gqlOperator "[<>=!]"
syn match gqlOperator "<>"
syn match gqlOperator "<="
syn match gqlOperator ">="
syn match gqlOperator "=~"
syn match gqlOperator "\.\."
syn match gqlOperator "+"
syn match gqlOperator "-"
syn match gqlOperator "\*"
syn match gqlOperator "/"
syn match gqlOperator "%"
syn match gqlOperator "\^"

" Arrows
syn match gqlArrow "->"
syn match gqlArrow "<-"
syn match gqlArrow "--"
syn match gqlArrow "-\[" contained
syn match gqlArrow "\]-" contained

" Highlighting links
hi def link gqlComment Comment
hi def link gqlTodo Todo
hi def link gqlClause Statement
hi def link gqlModify Statement
hi def link gqlSchema Statement
hi def link gqlGraph Keyword
hi def link gqlTransaction Statement
hi def link gqlLogical Conditional
hi def link gqlCompare Keyword
hi def link gqlFunction Function
hi def link gqlGeode Special
hi def link gqlType Type
hi def link gqlString String
hi def link gqlNumber Number
hi def link gqlParameter Identifier
hi def link gqlLabel Type
hi def link gqlRelType Type
hi def link gqlOperator Operator
hi def link gqlArrow Operator

let b:current_syntax = "gql"
