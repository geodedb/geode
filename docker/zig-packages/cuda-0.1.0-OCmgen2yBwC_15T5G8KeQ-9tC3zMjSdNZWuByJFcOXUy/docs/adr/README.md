# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for the CUDA Zig library.

## What is an ADR?

An ADR is a document that captures an important architectural decision made along with its context and consequences.

## ADR Index

| ADR | Title | Status |
|-----|-------|--------|
| [ADR-001](./001-dynamic-driver-loading.md) | Dynamic CUDA Driver Loading | Accepted |
| [ADR-002](./002-memory-pooling.md) | Memory Pooling Strategy | Accepted |
| [ADR-003](./003-error-handling.md) | Error Handling Approach | Accepted |
| [ADR-004](./004-thread-safety.md) | Thread Safety Model | Accepted |
| [ADR-005](./005-api-design.md) | API Design Principles | Accepted |
| [ADR-006](./006-context-management.md) | Context Management Strategy | Accepted |

## Template

```markdown
# ADR-XXX: Title

## Status
Proposed | Accepted | Deprecated | Superseded

## Context
What is the issue that we're seeing that is motivating this decision?

## Decision
What is the change that we're proposing and/or doing?

## Consequences
What becomes easier or more difficult because of this change?
```
