const std = @import("std");

// Minimal ISO/IEC 39075:2024 GQL token set (subset; expandable).
pub const TokenKind = enum {
    // delimiters/operators
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    l_brace,
    r_brace,
    comma,
    colon,
    semicolon,
    dot,
    dotdot,
    plus,
    minus,
    star,
    slash,
    percent,
    lt,
    gt,
    le,
    ge,
    eq,
    ne,
    regex_match, // =~
    regex_not_match, // !~
    concat, // ||
    bar, // |
    dollar, // $
    arrow_r, // ->
    arrow_l, // <-

    // literals & identifiers
    identifier,
    quoted_identifier,
    integer_lit,
    float_lit,
    string_lit,
    date_lit,
    datetime_lit,
    time_lit,
    local_datetime_lit,

    // keywords (ISO/IEC 39075:2024 reserved words; case-insensitive in lexer)
    MATCH,
    OPTIONAL,
    WHERE,
    RETURN,
    WITH,
    CASE,
    WHEN,
    THEN,
    ELSE,
    END,
    AND,
    OR,
    NOT,
    IN,
    IS,
    STARTS,
    ENDS,
    CONTAINS,
    CALL,
    YIELD,
    TRUE,
    FALSE,
    NULL,
    AS,
    DISTINCT,
    UNION,
    INTERSECT,
    EXCEPT,
    ALL,
    SESSION,
    SET,
    RESET,
    CLOSE,
    INSERT,
    VALUE,
    // VALUES - Removed to allow values() function calls (SCAN VALUES still works via identifier check)
    SCAN,
    START,
    TRANSACTION,
    BEGIN,
    COMMIT,
    ROLLBACK,
    CREATE,
    DELETE,
    MERGE,
    SHOW,
    EXPLAIN,
    PROFILE,
    GRAPH,
    PROPERTY,
    DROP,
    ORDER,
    BY,
    GROUP,
    ASC,
    DESC,
    LIMIT,
    OFFSET,
    SKIP,
    HAVING,
    NULLS,
    FIRST,
    LAST,
    ON,
    UNKNOWN,
    // Additional ISO reserved words
    FILTER,
    LET,
    SELECT,
    FROM,
    EXISTS,
    DETACH,
    REMOVE,
    FOR,
    FOREACH,
    UNWIND,
    USE,
    USING,
    INDEX,
    JOIN,
    IF,
    TO,
    KEY,
    // KEYS - Removed to allow keys() function calls
    LABELS,
    LOAD,
    CSV,
    PERIODIC,
    PROPERTIES,
    RELATIONSHIPS,
    START_NODE,
    END_NODE,
    TYPE,
    TYPES,

    // Critical missing ISO GQL keywords (avoiding duplicates)
    ACYCLIC,
    AGGREGATE,
    ANY,
    AVG,
    CATALOG,
    CAST,
    CONSTRAINT,
    COUNT,
    CURRENT,
    DIFFERENT,
    DURATION,
    EDGES,
    ELEMENT,
    FINISH,
    HOME,
    LABELED,
    LIKE,
    LIST,
    LOCAL,
    MAX,
    MIN,
    NEXT,
    NODE,
    OF,
    OTHERWISE,
    PATH,
    PATHS,
    RECORD,
    REPEATABLE,
    REPLACE,
    SCHEMA,
    SHORTEST,
    SIMPLE,
    SUM,
    TABLE,
    TRAIL,
    WALK,
    XOR,
    ZONED,
    ZONE,
    BINDING,

    eof,
    invalid,
};

pub const Location = struct { line: u32, column: u32 };

pub const Token = struct {
    kind: TokenKind,
    lexeme: []const u8, // slice into source buffer
    loc: Location,
};

const unicode = @import("../unicode/unicode_tables.zig");

// Unicode-aware identifier checking
pub fn isIdentifierStart(cp: u21) bool {
    return unicode.isIdentifierStart(cp);
}

pub fn isIdentifierContinue(cp: u21) bool {
    return unicode.isIdentifierContinue(cp);
}

// ASCII digit check (for compatibility)
pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

// Unicode digit check
pub fn isUnicodeDigit(cp: u21) bool {
    return unicode.isDecimalDigit(cp);
}

// Convert Unicode digit to ASCII value
pub fn digitToAscii(cp: u21) ?u8 {
    return unicode.digitToAscii(cp);
}

// Export keyword checking to lexer
pub fn keywordKind(word: []const u8) TokenKind {
    // Case-insensitive keyword matching
    if (std.ascii.eqlIgnoreCase(word, "MATCH")) return .MATCH;
    if (std.ascii.eqlIgnoreCase(word, "OPTIONAL")) return .OPTIONAL;
    if (std.ascii.eqlIgnoreCase(word, "WHERE")) return .WHERE;
    if (std.ascii.eqlIgnoreCase(word, "RETURN")) return .RETURN;
    if (std.ascii.eqlIgnoreCase(word, "WITH")) return .WITH;
    if (std.ascii.eqlIgnoreCase(word, "CASE")) return .CASE;
    if (std.ascii.eqlIgnoreCase(word, "WHEN")) return .WHEN;
    if (std.ascii.eqlIgnoreCase(word, "THEN")) return .THEN;
    if (std.ascii.eqlIgnoreCase(word, "ELSE")) return .ELSE;
    if (std.ascii.eqlIgnoreCase(word, "END")) return .END;
    if (std.ascii.eqlIgnoreCase(word, "AND")) return .AND;
    if (std.ascii.eqlIgnoreCase(word, "OR")) return .OR;
    if (std.ascii.eqlIgnoreCase(word, "NOT")) return .NOT;
    if (std.ascii.eqlIgnoreCase(word, "IN")) return .IN;
    if (std.ascii.eqlIgnoreCase(word, "IS")) return .IS;
    if (std.ascii.eqlIgnoreCase(word, "STARTS")) return .STARTS;
    if (std.ascii.eqlIgnoreCase(word, "ENDS")) return .ENDS;
    if (std.ascii.eqlIgnoreCase(word, "CONTAINS")) return .CONTAINS;
    if (std.ascii.eqlIgnoreCase(word, "CALL")) return .CALL;
    if (std.ascii.eqlIgnoreCase(word, "YIELD")) return .YIELD;
    if (std.ascii.eqlIgnoreCase(word, "TRUE")) return .TRUE;
    if (std.ascii.eqlIgnoreCase(word, "FALSE")) return .FALSE;
    if (std.ascii.eqlIgnoreCase(word, "NULL")) return .NULL;
    if (std.ascii.eqlIgnoreCase(word, "AS")) return .AS;
    if (std.ascii.eqlIgnoreCase(word, "DISTINCT")) return .DISTINCT;
    if (std.ascii.eqlIgnoreCase(word, "UNION")) return .UNION;
    if (std.ascii.eqlIgnoreCase(word, "INTERSECT")) return .INTERSECT;
    if (std.ascii.eqlIgnoreCase(word, "EXCEPT")) return .EXCEPT;
    if (std.ascii.eqlIgnoreCase(word, "ALL")) return .ALL;
    if (std.ascii.eqlIgnoreCase(word, "SESSION")) return .SESSION;
    if (std.ascii.eqlIgnoreCase(word, "SET")) return .SET;
    if (std.ascii.eqlIgnoreCase(word, "RESET")) return .RESET;
    if (std.ascii.eqlIgnoreCase(word, "CLOSE")) return .CLOSE;
    if (std.ascii.eqlIgnoreCase(word, "INSERT")) return .INSERT;
    if (std.ascii.eqlIgnoreCase(word, "VALUE")) return .VALUE;
    // if (std.ascii.eqlIgnoreCase(word, "VALUES")) return .VALUES; // Removed to allow values() function
    if (std.ascii.eqlIgnoreCase(word, "SCAN")) return .SCAN;
    if (std.ascii.eqlIgnoreCase(word, "START")) return .START;
    if (std.ascii.eqlIgnoreCase(word, "TRANSACTION")) return .TRANSACTION;
    if (std.ascii.eqlIgnoreCase(word, "BEGIN")) return .BEGIN;
    if (std.ascii.eqlIgnoreCase(word, "COMMIT")) return .COMMIT;
    if (std.ascii.eqlIgnoreCase(word, "ROLLBACK")) return .ROLLBACK;
    if (std.ascii.eqlIgnoreCase(word, "CREATE")) return .CREATE;
    if (std.ascii.eqlIgnoreCase(word, "DELETE")) return .DELETE;
    if (std.ascii.eqlIgnoreCase(word, "MERGE")) return .MERGE;
    if (std.ascii.eqlIgnoreCase(word, "SHOW")) return .SHOW;
    if (std.ascii.eqlIgnoreCase(word, "EXPLAIN")) return .EXPLAIN;
    if (std.ascii.eqlIgnoreCase(word, "PROFILE")) return .PROFILE;
    if (std.ascii.eqlIgnoreCase(word, "GRAPH")) return .GRAPH;
    if (std.ascii.eqlIgnoreCase(word, "PROPERTY")) return .PROPERTY;
    if (std.ascii.eqlIgnoreCase(word, "DROP")) return .DROP;
    if (std.ascii.eqlIgnoreCase(word, "ORDER")) return .ORDER;
    if (std.ascii.eqlIgnoreCase(word, "BY")) return .BY;
    if (std.ascii.eqlIgnoreCase(word, "GROUP")) return .GROUP;
    if (std.ascii.eqlIgnoreCase(word, "ASC")) return .ASC;
    if (std.ascii.eqlIgnoreCase(word, "DESC")) return .DESC;
    if (std.ascii.eqlIgnoreCase(word, "LIMIT")) return .LIMIT;
    if (std.ascii.eqlIgnoreCase(word, "OFFSET")) return .OFFSET;
    if (std.ascii.eqlIgnoreCase(word, "SKIP")) return .SKIP;
    if (std.ascii.eqlIgnoreCase(word, "HAVING")) return .HAVING;
    if (std.ascii.eqlIgnoreCase(word, "NULLS")) return .NULLS;
    if (std.ascii.eqlIgnoreCase(word, "FIRST")) return .FIRST;
    if (std.ascii.eqlIgnoreCase(word, "LAST")) return .LAST;
    if (std.ascii.eqlIgnoreCase(word, "ON")) return .ON;
    if (std.ascii.eqlIgnoreCase(word, "UNKNOWN")) return .UNKNOWN;
    // Additional ISO reserved words
    if (std.ascii.eqlIgnoreCase(word, "FILTER")) return .FILTER;
    if (std.ascii.eqlIgnoreCase(word, "LET")) return .LET;
    if (std.ascii.eqlIgnoreCase(word, "SELECT")) return .SELECT;
    if (std.ascii.eqlIgnoreCase(word, "FROM")) return .FROM;
    if (std.ascii.eqlIgnoreCase(word, "EXISTS")) return .EXISTS;
    if (std.ascii.eqlIgnoreCase(word, "DETACH")) return .DETACH;
    if (std.ascii.eqlIgnoreCase(word, "REMOVE")) return .REMOVE;
    if (std.ascii.eqlIgnoreCase(word, "FOR")) return .FOR;
    if (std.ascii.eqlIgnoreCase(word, "FOREACH")) return .FOREACH;
    if (std.ascii.eqlIgnoreCase(word, "UNWIND")) return .UNWIND;
    if (std.ascii.eqlIgnoreCase(word, "USE")) return .USE;
    if (std.ascii.eqlIgnoreCase(word, "USING")) return .USING;
    if (std.ascii.eqlIgnoreCase(word, "INDEX")) return .INDEX;
    if (std.ascii.eqlIgnoreCase(word, "JOIN")) return .JOIN;
    if (std.ascii.eqlIgnoreCase(word, "IF")) return .IF;
    if (std.ascii.eqlIgnoreCase(word, "TO")) return .TO;
    if (std.ascii.eqlIgnoreCase(word, "KEY")) return .KEY;
    // if (std.ascii.eqlIgnoreCase(word, "KEYS")) return .KEYS; // Removed to allow keys() function
    // if (std.ascii.eqlIgnoreCase(word, "LABELS")) return .LABELS; // Removed to allow labels() function
    if (std.ascii.eqlIgnoreCase(word, "LOAD")) return .LOAD;
    if (std.ascii.eqlIgnoreCase(word, "CSV")) return .CSV;
    if (std.ascii.eqlIgnoreCase(word, "PERIODIC")) return .PERIODIC;
    if (std.ascii.eqlIgnoreCase(word, "PROPERTIES")) return .PROPERTIES;
    if (std.ascii.eqlIgnoreCase(word, "RELATIONSHIPS")) return .RELATIONSHIPS;
    if (std.ascii.eqlIgnoreCase(word, "START_NODE")) return .START_NODE;
    if (std.ascii.eqlIgnoreCase(word, "END_NODE")) return .END_NODE;
    if (std.ascii.eqlIgnoreCase(word, "TYPE")) return .TYPE;
    if (std.ascii.eqlIgnoreCase(word, "TYPES")) return .TYPES;

    // Critical missing ISO GQL keywords (avoiding duplicates)
    if (std.ascii.eqlIgnoreCase(word, "ACYCLIC")) return .ACYCLIC;
    if (std.ascii.eqlIgnoreCase(word, "AGGREGATE")) return .AGGREGATE;
    if (std.ascii.eqlIgnoreCase(word, "ANY")) return .ANY;
    if (std.ascii.eqlIgnoreCase(word, "AVG")) return .AVG;
    if (std.ascii.eqlIgnoreCase(word, "CATALOG")) return .CATALOG;
    if (std.ascii.eqlIgnoreCase(word, "CAST")) return .CAST;
    if (std.ascii.eqlIgnoreCase(word, "CONSTRAINT")) return .CONSTRAINT;
    if (std.ascii.eqlIgnoreCase(word, "COUNT")) return .COUNT;
    if (std.ascii.eqlIgnoreCase(word, "CURRENT")) return .CURRENT;
    if (std.ascii.eqlIgnoreCase(word, "DIFFERENT")) return .DIFFERENT;
    if (std.ascii.eqlIgnoreCase(word, "DURATION")) return .DURATION;
    if (std.ascii.eqlIgnoreCase(word, "EDGES")) return .EDGES;
    if (std.ascii.eqlIgnoreCase(word, "ELEMENT")) return .ELEMENT;
    if (std.ascii.eqlIgnoreCase(word, "FINISH")) return .FINISH;
    if (std.ascii.eqlIgnoreCase(word, "HOME")) return .HOME;
    if (std.ascii.eqlIgnoreCase(word, "LABELED")) return .LABELED;
    if (std.ascii.eqlIgnoreCase(word, "LIKE")) return .LIKE;
    if (std.ascii.eqlIgnoreCase(word, "LIST")) return .LIST;
    if (std.ascii.eqlIgnoreCase(word, "MAX")) return .MAX;
    if (std.ascii.eqlIgnoreCase(word, "MIN")) return .MIN;
    if (std.ascii.eqlIgnoreCase(word, "NEXT")) return .NEXT;
    if (std.ascii.eqlIgnoreCase(word, "NODE")) return .NODE;
    if (std.ascii.eqlIgnoreCase(word, "OF")) return .OF;
    if (std.ascii.eqlIgnoreCase(word, "OTHERWISE")) return .OTHERWISE;
    if (std.ascii.eqlIgnoreCase(word, "PATH")) return .PATH;
    if (std.ascii.eqlIgnoreCase(word, "PATHS")) return .PATHS;
    if (std.ascii.eqlIgnoreCase(word, "RECORD")) return .RECORD;
    if (std.ascii.eqlIgnoreCase(word, "REPEATABLE")) return .REPEATABLE;
    if (std.ascii.eqlIgnoreCase(word, "REPLACE")) return .REPLACE;
    if (std.ascii.eqlIgnoreCase(word, "SCHEMA")) return .SCHEMA;
    if (std.ascii.eqlIgnoreCase(word, "SHORTEST")) return .SHORTEST;
    if (std.ascii.eqlIgnoreCase(word, "SIMPLE")) return .SIMPLE;
    if (std.ascii.eqlIgnoreCase(word, "SUM")) return .SUM;
    if (std.ascii.eqlIgnoreCase(word, "TABLE")) return .TABLE;
    if (std.ascii.eqlIgnoreCase(word, "TRAIL")) return .TRAIL;
    if (std.ascii.eqlIgnoreCase(word, "WALK")) return .WALK;
    if (std.ascii.eqlIgnoreCase(word, "XOR")) return .XOR;
    if (std.ascii.eqlIgnoreCase(word, "ZONED")) return .ZONED;
    if (std.ascii.eqlIgnoreCase(word, "BINDING")) return .BINDING;
    if (std.ascii.eqlIgnoreCase(word, "ZONE")) return .ZONE;

    // Temporal keywords - checked before regular TIME keyword
    if (std.ascii.eqlIgnoreCase(word, "DATE")) return .date_lit;
    if (std.ascii.eqlIgnoreCase(word, "DATETIME")) return .datetime_lit;
    if (std.ascii.eqlIgnoreCase(word, "TIME")) return .time_lit;
    if (std.ascii.eqlIgnoreCase(word, "LOCAL")) return .local_datetime_lit;

    // Regular TIME keyword for TIME ZONE statements (after temporal literal check)
    // Note: This won't be reached for TIME"..." because lexer handles temporal literals first
    return .identifier;
}
