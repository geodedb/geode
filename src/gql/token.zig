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
    integer_lit,
    float_lit,
    string_lit,
    date_lit,
    datetime_lit,
    time_lit,
    local_datetime_lit,

    // keywords (subset; case-insensitive in lexer)
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
    DROP,
    ORDER,
    BY,
    GROUP,
    ASC,
    DESC,
    LIMIT,
    OFFSET,
    HAVING,
    NULLS,
    FIRST,
    LAST,
    ON,

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

pub fn isIdentifierStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

pub fn isIdentifierContinue(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
