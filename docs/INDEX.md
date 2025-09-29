# Geode Documentation Index

**Version**: v0.18.0  
**Last Updated**: 2025-09-29

## 📚 Primary Documentation

### Getting Started
- **[Quick Reference](QUICK_REFERENCE.md)** - Essential commands and common operations
- **[Usage Guide](USAGE.md)** - How to use Geode
- **[Match Tutorial](examples/match_tutorial.md)** - Graph query examples

### Comprehensive Documentation
- **[Ground Truth Documentation](GROUND_TRUTH.md)** ⭐ - Complete consolidated documentation
- **[README](README.md)** - Documentation overview
- **[Executive Summary](v0.18.0/executive_summary.md)** - High-level overview

## 🏗️ Architecture & Design

### Core Architecture
- **[Architecture & Storage](v0.18.0/architecture_storage.md)** - System architecture
- **[Data Model & GQL](v0.18.0/data_model_gql.md)** - Graph data model
- **[Binary Protocol](BINARY_PROTOCOL.md)** - Wire protocol specification

### Type System
- **[Types and Functions](TYPES_AND_FUNCTIONS.md)** - Complete type reference
- **[Type Quick Reference](TYPE_QUICK_REFERENCE.md)** - Type summary
- **[Type System Extensions](TYPE_SYSTEM_EXTENSIONS.md)** - Advanced types

## 🔒 Security & Governance

### Security
- **[Security Progress](SECURITY_PROGRESS.md)** - Security implementation status
- **[Security & Governance](v0.18.0/security_governance.md)** - Security architecture
- **[Design TDE KMS](DESIGN_TDE_KMS.md)** - Encryption design
- **[Audit Logging](AUDIT_LOGGING.md)** - Audit system

### Governance
- **[Governance](GOVERNANCE.md)** - Evidence-based governance
- **[GAP Analysis](GAP_ANALYSIS.md)** - Implementation gaps
- **[Implementation Reality](IMPLEMENTATION_REALITY.md)** - Current state

## 🚀 Operations & Deployment

### Deployment
- **[Deployment & Operations](v0.18.0/deployment_operations.md)** - Production deployment
- **[Docker Usage](../kb/docker/DOCKER_USAGE.md)** - Container deployment

### Performance
- **[Performance & Scalability](v0.18.0/performance_scalability.md)** - Performance guide
- **[Telemetry](TELEMETRY.md)** - Monitoring and metrics

### Client Interfaces
- **[CLI Interface](v0.18.0/interfaces_cli.md)** - Command-line tools
- **[Client Libraries](v0.18.0/interfaces_clients.md)** - SDK documentation

## 🔧 Development

### Contributing
- **[Development & Contributing](v0.18.0/development_contributing.md)** - Contributor guide
- **[Requirements](REQUIREMENTS.md)** - Technical requirements

### Implementation Status
- **[Status CSV](status.csv)** - CANARY evidence tracking (auto-generated)
- **[Conformance Profile](gql/GQL_CONFORMANCE_PROFILE.md)** - GQL conformance

### Roadmap
- **[Roadmap](v0.18.0/roadmap.md)** - Future plans
- **[Next Steps](NEXT.md)** - Priority items

## 📖 Reference

### Standards & Specifications
- **[ISO/IEC 39075:2024](../kb/gql/ISO_IEC_39075_2024.md)** - GQL standard
- **[GQL Grammar](../specs/gql/ebnf-grammar.md)** - Complete EBNF

### Knowledge Base
- **[Consolidated KB](../kb/CONSOLIDATED.md)** - Knowledge base summary
- **[Algorithm Research](../kb/algorithm-research/)** - Graph algorithms
- **[Research Papers](../kb/research/)** - Academic research

### Version History
- **[v0.18.0 Release](RELEASE_v0.18.md)** - Current release
- **[v0.17.0 Release](v0.17.0-RELEASE-NOTES.md)** - Previous release
- **[v0.16.0 Release](V0.16.0_RELEASE_NOTES.md)** - Earlier release
- **[Changelog](../CHANGELOG.md)** - All changes

## 🔍 Quick Links

### By Topic

#### Graph Operations
- [Match patterns](v0.18.0/data_model_gql.md)
- [Graph algorithms](../kb/algorithm-research/)
- [Path queries](examples/match_tutorial.md)

#### Data Types
- [Network types (IP/CIDR)](TYPES_AND_FUNCTIONS.md#network-types)
- [Geographic types](TYPES_AND_FUNCTIONS.md#geographic-types)
- [Temporal types](TYPES_AND_FUNCTIONS.md#temporal-types)
- [Cryptographic types](TYPES_AND_FUNCTIONS.md#cryptographic-types)

#### Security Features
- [TDE encryption](DESIGN_TDE_KMS.md)
- [Row-level security](../kb/RLS_IMPLEMENTATION.md)
- [Audit logging](AUDIT_LOGGING.md)

#### Distributed Features
- [Raft consensus](../specs/raft/zaft/README.md)
- [Federation](v0.18.0/architecture_storage.md)
- [2PC transactions](../kb/archive/)

## 📋 Documentation Guidelines

### CANARY Evidence System
Every feature must have evidence:
```zig
// CANARY: REQ=REQ-GQL-XXX; FEATURE="Name"; 
//         ASPECT=Component; STATUS=TESTED;
//         TEST=TestName; OWNER=team; 
//         UPDATED=2025-09-29
```

### Documentation Updates
1. Update source documentation
2. Run `make status-generate` to update evidence
3. Update relevant `.md` files
4. Verify with `make governance-check`

## 🆘 Support

### Getting Help
- Check [Quick Reference](QUICK_REFERENCE.md)
- Review [FAQ & Glossary](v0.18.0/faq_glossary.md)
- Search [Ground Truth](GROUND_TRUTH.md)

### Reporting Issues
- GitHub Issues: [spyderorg/geode](https://github.com/spyderorg/geode)
- Include version, query, error message

---

*This index provides navigation to all Geode documentation. Start with [Quick Reference](QUICK_REFERENCE.md) for common tasks or [Ground Truth](GROUND_TRUTH.md) for comprehensive information.*