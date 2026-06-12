// Module implementation
// CANARY: REQ=REQ-LSP-METADATA-001; FEATURE="MetadataIntegration"; ASPECT=Completions; STATUS=EXEMPT; OWNER=lsp; UPDATED=2026-01-03
// Language-features facade for the GQL/Geode LSP.
//
// #806 (QUALITY_GAP_ANALYSIS, closed 2026-06-11): the feature providers
// were split into per-feature modules under features/ — this file is now
// a thin re-export facade that preserves the public API. It is also the
// module root for the `lsp_features` named module consumed by the
// out-of-tree GAP-0818 regression (tests/test_gap0818_lsp_context.zig;
// see the lsp_features_mod wiring in build.zig). Keep the re-exports
// below stable: server.zig, features_test.zig, and the gap tests all
// consume this surface, and rooting a second module at any of the
// features/ files would trip Zig 0.16's "file exists in modules X and
// X0" diamond (same rationale as the transport_mod re-export in
// server.zig).
//
// Provider modules:
//   features/common.zig          shared prefix-match helper + GQL metadata lists
//   features/diagnostics.zig     parse/semantic/schema diagnostics
//   features/hover.zig           hover cards (schema + static metadata)
//   features/completion.zig      completion items (schema + static metadata)
//   features/definition.zig      go-to-definition
//   features/symbols.zig         document symbols (outline)
//   features/signature_help.zig  signature help
//   features/references.zig      find references
//   features/semantic_tokens.zig semantic tokens (syntax highlighting)
//   features/formatting.zig      document formatting

const protocol = @import("protocol.zig");
const context_mod = @import("context.zig");

/// GAP-0818: caller identity threaded into every feature provider.
pub const LspContext = context_mod.LspContext;

// GAP-0818 re-exports so out-of-tree test modules (rooted at this file as
// the `lsp_features` named module) can construct the provider inputs
// without registering `protocol.zig` / `document.zig` /
// `schema_provider.zig` as separate modules — which would trip Zig
// 0.16's "file exists in modules X and X0" diamond.
pub const Protocol = protocol;
pub const DocumentType = @import("document.zig").Document;
pub const SchemaProviderType = @import("schema_provider.zig").SchemaProvider;

const common = @import("features/common.zig");
const diagnostics_mod = @import("features/diagnostics.zig");
const hover_mod = @import("features/hover.zig");
const completion_mod = @import("features/completion.zig");
const definition_mod = @import("features/definition.zig");
const symbols_mod = @import("features/symbols.zig");
const signature_help_mod = @import("features/signature_help.zig");
const references_mod = @import("features/references.zig");
const semantic_tokens_mod = @import("features/semantic_tokens.zig");
const formatting_mod = @import("features/formatting.zig");

pub const startsWithCI = common.startsWithCI;
pub const provideDiagnostics = diagnostics_mod.provideDiagnostics;
pub const provideHover = hover_mod.provideHover;
pub const provideCompletion = completion_mod.provideCompletion;
pub const provideDefinition = definition_mod.provideDefinition;
pub const provideDocumentSymbols = symbols_mod.provideDocumentSymbols;
pub const provideSignatureHelp = signature_help_mod.provideSignatureHelp;
pub const provideReferences = references_mod.provideReferences;
pub const provideSemanticTokensFull = semantic_tokens_mod.provideSemanticTokensFull;

/// Formatting options for the GQL formatter (see features/formatting.zig).
pub const FormattingOptions = formatting_mod.FormattingOptions;
pub const provideFormatting = formatting_mod.provideFormatting;
pub const provideFormattingWithOptions = formatting_mod.provideFormattingWithOptions;

test {
    // Pull the per-feature modules into test analysis so their inline
    // tests (moved with their code during the #806 split) keep running
    // under `zig build test-lsp`.
    _ = common;
    _ = diagnostics_mod;
    _ = hover_mod;
    _ = completion_mod;
    _ = definition_mod;
    _ = symbols_mod;
    _ = signature_help_mod;
    _ = references_mod;
    _ = semantic_tokens_mod;
    _ = formatting_mod;
}
