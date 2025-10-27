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
- `debug_property_access.zig` - Debug property access
- `debug_property_keyword.zig` - Debug property keywords

## Benchmark Files

### Federation Benchmarks
- `benchmark_federation_mismatch_frequency.zig` - Federation mismatch frequency analysis
- `benchmark_federation_mismatch_latency.zig` - Federation mismatch latency analysis
- `benchmark_bias_clamp_variance.zig` - Bias clamp variance analysis

## Utility Files

- `io_decl_inspect.zig` - Inspect I/O declarations
- `quick_validation.zig` - Quick validation checks

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
