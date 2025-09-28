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
    VALUES,
    SCAN,
    START,
    TRANSACTION,
    COMMIT,
    ROLLBACK,
    CREATE,
    DELETE,
    MERGE,
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
    KEY,
    KEYS,
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

    // pattern and string operators (extras)
    regex_match, // =~

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
    if (std.ascii.eqlIgnoreCase(word, "VALUES")) return .VALUES;
    if (std.ascii.eqlIgnoreCase(word, "SCAN")) return .SCAN;
    if (std.ascii.eqlIgnoreCase(word, "START")) return .START;
    if (std.ascii.eqlIgnoreCase(word, "TRANSACTION")) return .TRANSACTION;
    if (std.ascii.eqlIgnoreCase(word, "COMMIT")) return .COMMIT;
    if (std.ascii.eqlIgnoreCase(word, "ROLLBACK")) return .ROLLBACK;
    if (std.ascii.eqlIgnoreCase(word, "CREATE")) return .CREATE;
    if (std.ascii.eqlIgnoreCase(word, "DELETE")) return .DELETE;
    if (std.ascii.eqlIgnoreCase(word, "MERGE")) return .MERGE;
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
    if (std.ascii.eqlIgnoreCase(word, "KEY")) return .KEY;
    if (std.ascii.eqlIgnoreCase(word, "KEYS")) return .KEYS;
    if (std.ascii.eqlIgnoreCase(word, "LABELS")) return .LABELS;
    if (std.ascii.eqlIgnoreCase(word, "LOAD")) return .LOAD;
    if (std.ascii.eqlIgnoreCase(word, "CSV")) return .CSV;
    if (std.ascii.eqlIgnoreCase(word, "PERIODIC")) return .PERIODIC;
    if (std.ascii.eqlIgnoreCase(word, "PROPERTIES")) return .PROPERTIES;
    if (std.ascii.eqlIgnoreCase(word, "RELATIONSHIPS")) return .RELATIONSHIPS;
    if (std.ascii.eqlIgnoreCase(word, "START_NODE")) return .START_NODE;
    if (std.ascii.eqlIgnoreCase(word, "END_NODE")) return .END_NODE;
    if (std.ascii.eqlIgnoreCase(word, "TYPE")) return .TYPE;
    if (std.ascii.eqlIgnoreCase(word, "TYPES")) return .TYPES;
    // Temporal keywords
    if (std.ascii.eqlIgnoreCase(word, "DATE")) return .date_lit;
    if (std.ascii.eqlIgnoreCase(word, "DATETIME")) return .datetime_lit;
    if (std.ascii.eqlIgnoreCase(word, "TIME")) return .time_lit;
    if (std.ascii.eqlIgnoreCase(word, "LOCAL")) return .local_datetime_lit;
    return .identifier;
}
