" Geode GQL filetype detection and syntax for Vim/Neovim
" Add this to your ~/.vim/ftdetect/gql.vim or ~/.config/nvim/ftdetect/gql.vim

" Filetype detection
autocmd BufNewFile,BufRead *.gql setfiletype gql
autocmd BufNewFile,BufRead *.gcypher setfiletype gql
autocmd BufNewFile,BufRead *.cypher setfiletype cypher
autocmd BufNewFile,BufRead *.pgql setfiletype gql

" Basic syntax highlighting (minimal version)
" For full syntax, use the Lua configuration with Tree-sitter

if exists("b:current_syntax")
  finish
endif

" Keywords
syntax keyword gqlKeyword MATCH CREATE DELETE DETACH MERGE SET REMOVE
syntax keyword gqlKeyword RETURN WHERE ORDER BY LIMIT OFFSET SKIP
syntax keyword gqlKeyword WITH UNWIND CALL YIELD UNION ALL OPTIONAL
syntax keyword gqlKeyword AS DISTINCT ASC DESC GROUP HAVING
syntax keyword gqlKeyword INTERSECT EXCEPT INSERT UPDATE DROP
syntax keyword gqlKeyword USE GRAPH CATALOG SCHEMA TABLE VIEW INDEX
syntax keyword gqlKeyword CONSTRAINT ON EXISTS IF SHOW DESCRIBE EXPLAIN
syntax keyword gqlKeyword FOREACH

" Logical operators
syntax keyword gqlOperator AND OR NOT XOR IN IS NULL TRUE FALSE

" Case expressions
syntax keyword gqlCase CASE WHEN THEN ELSE END

" Types
syntax keyword gqlType INTEGER FLOAT STRING BOOLEAN DATE TIME DATETIME
syntax keyword gqlType DURATION POINT VECTOR UUID BYTES JSON LIST MAP
syntax keyword gqlType NODE RELATIONSHIP PATH GRAPH ANY

" Functions - aggregates
syntax keyword gqlFunction count sum avg min max collect size

" Functions - scalar
syntax keyword gqlFunction length type id labels properties keys nodes relationships
syntax keyword gqlFunction head last tail reverse range

" Functions - math
syntax keyword gqlFunction abs ceil floor round sqrt rand sign exp log log10
syntax keyword gqlFunction sin cos tan asin acos atan atan2 pi e degrees radians

" Functions - string
syntax keyword gqlFunction toString toInteger toFloat toBoolean split substring
syntax keyword gqlFunction replace toLower toUpper trim lTrim rTrim left right
syntax keyword gqlFunction startsWith endsWith contains

" Functions - temporal
syntax keyword gqlFunction timestamp date time datetime duration

" Functions - vector
syntax keyword gqlFunction distance similarity cosine euclidean manhattan

" Strings
syntax region gqlString start=/"/ skip=/\\"/ end=/"/
syntax region gqlString start=/'/ skip=/\\'/ end=/'/

" Numbers
syntax match gqlNumber "\<\d\+\>"
syntax match gqlNumber "\<\d\+\.\d*\>"
syntax match gqlNumber "\<\d\+[eE][+-]\?\d\+\>"
syntax match gqlNumber "\<\d\+\.\d*[eE][+-]\?\d\+\>"

" Comments
syntax match gqlComment "//.*$"
syntax region gqlComment start="/\*" end="\*/"

" Parameters
syntax match gqlParameter "\$[a-zA-Z_][a-zA-Z0-9_]*"

" Labels
syntax match gqlLabel ":[a-zA-Z_][a-zA-Z0-9_]*"

" Highlighting
highlight default link gqlKeyword Keyword
highlight default link gqlOperator Operator
highlight default link gqlCase Conditional
highlight default link gqlType Type
highlight default link gqlFunction Function
highlight default link gqlString String
highlight default link gqlNumber Number
highlight default link gqlComment Comment
highlight default link gqlParameter Identifier
highlight default link gqlLabel Tag

let b:current_syntax = "gql"
