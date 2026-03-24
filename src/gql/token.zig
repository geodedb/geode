// Thin compatibility wrapper: delegates to the external gql library.
//
// CANARY: REQ=REQ-LEXER-METADATA-001; FEATURE="MetadataIntegration"; ASPECT=KeywordLookup; STATUS=EXEMPT; OWNER=lexer; UPDATED=2026-01-03
// CANARY: REQ=REQ-LEXER-METADATA-002; FEATURE="MetadataIntegration"; ASPECT=ComptimeKeywordMap; STATUS=EXEMPT; OWNER=lexer; UPDATED=2026-01-03
// CANARY: REQ=REQ-GQL-KEYWORDS-001; FEATURE="GQL Reserved Words"; ASPECT=ISO39075Compliance; STATUS=TESTED; TEST=geodetestlab/specs/geode_keyword_fixes.yml; OWNER=parser; UPDATED=2026-01-03
// CANARY: REQ=REQ-GQL-CAST-KEYWORDS-001; FEATURE="CastTypeKeywords"; ASPECT=UnitTests; STATUS=TESTED; TEST=self; OWNER=parser; UPDATED=2026-01-25

const gql_lib = @import("gql_lib");
const ext_token = gql_lib.token;

// Re-export all public types from the external library
pub const TokenKind = ext_token.TokenKind;
pub const Location = ext_token.Location;
pub const Token = ext_token.Token;

// Re-export public functions
pub const isIdentifierStart = ext_token.isIdentifierStart;
pub const isIdentifierContinue = ext_token.isIdentifierContinue;
pub const isDigit = ext_token.isDigit;
pub const isUnicodeDigit = ext_token.isUnicodeDigit;
pub const digitToAscii = ext_token.digitToAscii;
pub const keywordKind = ext_token.keywordKind;
pub const isKeywordInMetadata = ext_token.isKeywordInMetadata;
pub const getKeywordMetadata = ext_token.getKeywordMetadata;
