# Geode advancement notes

## SONNY-4778 — isolate hook Git environments

Tool-managed Git operations must not inherit the invoking hook's repository
or index overrides. Wrap local tool hooks with the shared environment guard
and verify it through local hooks and a required CI regression job.
