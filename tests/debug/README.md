# Debug Test Files

This directory contains debug and benchmark Zig files used for development and troubleshooting.

## Debug Files

### Parser Debugging

- `debug_count_alias.zig` - Debug COUNT with alias issues
- `debug_count_issue.zig` - Debug COUNT operation issues
- `debug_double_quotes.zig` - Debug double quote parsing
- `debug_graph_type_parse.zig` - Debug graph type parsing
- `debug_parser_step.zig` - Step through parser execution
- `debug_set_parsing.zig` - Debug SET operation parsing
- `debug_set_remove.zig` - Debug SET REMOVE operations
- `debug_set_variations.zig` - Debug SET variations
- `debug_simple_path.zig` - Debug simple path expressions
- `debug_token_sequence.zig` - Debug token sequences

### Execution Debugging

- `debug_execution.zig` - Debug query execution
- `debug_failing_case.zig` - Debug specific failing test cases
- `debug_path_variable.zig` - Debug path variable handling
- `debug_variable_length.zig` - Debug variable-length patterns

### Property Debugging

- `debug_property_keyword.zig` - Debug property keywords

## Benchmark Files

### Federation Benchmarks

- `benchmark_federation_mismatch_frequency.zig` - Federation mismatch frequency analysis
- `benchmark_federation_mismatch_latency.zig` - Federation mismatch latency analysis
- `benchmark_bias_clamp_variance.zig` - Bias clamp variance analysis

## Utility Files

- `io_decl_inspect.zig` - Inspect I/O declarations
- `quick_validation.zig` - Quick validation checks

## Test Files

### Parser and Lexer Tests

- `test_create_lexer.zig` - Lexer creation tests
- `test_create_parser.zig` - Parser creation tests
- `test_lexer_direct.zig` - Direct lexer tests
- `test_parser_direct.zig` - Direct parser tests
- `test_parser_fix.zig` - Parser fix validation
- `test_property_parser.zig` - Property parser tests

### Execution and Evaluation Tests

- `test_eval_direct.zig` - Direct evaluation tests
- `test_io.zig` - I/O operation tests
- `test_advanced_union.zig` - Advanced union tests
- `test_nested_functions.zig` - Nested function tests

### Query Operation Tests

- `test_create_index.zig` - Index creation tests
- `test_match_delete.zig` - MATCH DELETE operation tests

### Cost Model and Planner Tests

- `test_cost_model_adaptive_bias.zig` - Adaptive bias cost model
- `test_cost_model_adaptive_bias_parity.zig` - Bias parity tests
- `test_cost_model_bias_clamp_warning.zig` - Bias clamp warning tests
- `test_cost_model_bias_persistence.zig` - Bias persistence tests
- `test_cost_model_bias_persistence_v2.zig` - Bias persistence v2
- `test_cost_model_dynamic_alpha.zig` - Dynamic alpha tests
- `test_cost_model_explain_bias.zig` - Explain bias tests
- `test_cost_model_explain_v4.zig` - Explain v4 tests
- `test_cost_model_planner_bias_application.zig` - Planner bias application

### Data Structure Tests

- `test_arraylist2.zig` - ArrayList test 2
- `test_arraylist3.zig` - ArrayList test 3
- `test_arraylist4.zig` - ArrayList test 4

### Feature-Specific Tests

- `test_gql_compliance.zig` - GQL compliance tests
- `test_gql_features.zig` - GQL feature tests
- `test_rbac_abac.zig` - RBAC/ABAC security tests
- `test_rbac_simple.zig` - Simple RBAC tests
- `test_telemetry_smoke.zig` - Telemetry smoke tests
- `test_nvrtc_validation.zig` - NVRTC validation tests
- `test_pagerank_threshold.zig` - PageRank threshold tests

## Usage

These files are not part of the regular test suite. They are standalone programs used for debugging specific issues during development.

### Compiling and Running

```bash
# From repository root
cd tests/debug

# Compile a debug file
zig build-exe debug_parser_step.zig

# Run it
./debug_parser_step

# Or compile and run in one step
zig run debug_parser_step.zig
```

### Creating New Debug Files

1. Create a new `.zig` file in this directory
2. Include necessary imports from `src/`
3. Write focused test case for the issue
4. Add entry to this README

## When to Use Debug Files

Use debug files when:

- Investigating specific parser or execution issues
- Need to step through code with controlled input
- Testing edge cases not covered by main test suite
- Benchmarking specific operations
- Prototyping new features

These files are intentionally simple and focused on specific issues, unlike the comprehensive test suite in `tests/`.
