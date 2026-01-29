# VDB Graph Migrations Makefile
# Provides utilities for managing GQL migrations converted from VDB SQL

GEODE_CLI = ../../zig-out/bin/geode
MIGRATION_DIR = .
MIGRATIONS = 001_base_entities.gql 004_dns.gql 006_core.gql 011_auth.gql 015_orgs.gql

.PHONY: help list validate run-all run-migration clean test-queries

help:
	@echo "VDB Graph Migrations"
	@echo "===================="
	@echo ""
	@echo "Available targets:"
	@echo "  list          - List available migrations"
	@echo "  validate      - Validate migration syntax"
	@echo "  run-all       - Run all migrations in order"
	@echo "  run-migration - Run specific migration (MIGRATION=file.gql)"
	@echo "  test-queries  - Run example queries"
	@echo "  clean         - Clean up test data"
	@echo "  docs          - Show migration documentation"
	@echo ""
	@echo "Examples:"
	@echo "  make run-migration MIGRATION=001_base_entities.gql"
	@echo "  make validate"
	@echo "  make test-queries"

list:
	@echo "Available VDB Graph Migrations:"
	@echo "==============================="
	@for migration in $(MIGRATIONS); do \
		echo "  $$migration"; \
		head -3 $$migration | grep "// " | sed 's|^// ||' | sed 's/^/    /'; \
		echo ""; \
	done

validate:
	@echo "Validating migration syntax..."
	@for migration in $(MIGRATIONS); do \
		echo "Checking $$migration..."; \
		if [ -f "$(GEODE_CLI)" ]; then \
			$(GEODE_CLI) query --dry-run < $$migration > /dev/null 2>&1 && \
			echo "  ✓ $$migration syntax valid" || \
			echo "  ✗ $$migration syntax error"; \
		else \
			echo "  ⚠ Geode CLI not found, skipping validation"; \
		fi; \
	done

run-all:
	@echo "Running all VDB graph migrations..."
	@if [ ! -f "$(GEODE_CLI)" ]; then \
		echo "Error: Geode CLI not found at $(GEODE_CLI)"; \
		echo "Run 'make build' in the root directory first"; \
		exit 1; \
	fi
	@for migration in $(MIGRATIONS); do \
		echo "Running $$migration..."; \
		$(GEODE_CLI) query < $$migration && \
		echo "  ✓ $$migration completed" || \
		echo "  ✗ $$migration failed"; \
	done

run-migration:
	@if [ -z "$(MIGRATION)" ]; then \
		echo "Error: MIGRATION parameter required"; \
		echo "Usage: make run-migration MIGRATION=001_base_entities.gql"; \
		exit 1; \
	fi
	@if [ ! -f "$(MIGRATION)" ]; then \
		echo "Error: Migration file $(MIGRATION) not found"; \
		exit 1; \
	fi
	@if [ ! -f "$(GEODE_CLI)" ]; then \
		echo "Error: Geode CLI not found at $(GEODE_CLI)"; \
		echo "Run 'make build' in the root directory first"; \
		exit 1; \
	fi
	@echo "Running migration: $(MIGRATION)"
	@$(GEODE_CLI) query < $(MIGRATION)

test-queries:
	@echo "Running example queries from migrations..."
	@if [ ! -f "$(GEODE_CLI)" ]; then \
		echo "Error: Geode CLI not found at $(GEODE_CLI)"; \
		exit 1; \
	fi

	@echo ""
	@echo "Testing DNS hierarchy queries..."
	@echo "CALL create_domain('mail.google.com.');" | $(GEODE_CLI) query
	@echo "MATCH (d:Domain WHERE d.name = 'mail.google.com.') RETURN d;" | $(GEODE_CLI) query

	@echo ""
	@echo "Testing organization queries..."
	@echo "MATCH (org:Organization WHERE org.acronym = 'IETF') RETURN org.name, org.founded;" | $(GEODE_CLI) query

	@echo ""
	@echo "Testing entity queries..."
	@echo "MATCH (e:Entity) RETURN count(e) AS entity_count;" | $(GEODE_CLI) query

clean:
	@echo "Cleaning up test data..."
	@if [ -f "$(GEODE_CLI)" ]; then \
		echo "MATCH (n) WHERE n:Domain OR n:Organization OR n:Account DETACH DELETE n;" | $(GEODE_CLI) query; \
		echo "Test data cleaned"; \
	else \
		echo "Geode CLI not found, cannot clean data"; \
	fi

docs:
	@echo "VDB Graph Migration Documentation"
	@echo "================================="
	@echo ""
	@cat README.md | head -50
	@echo ""
	@echo "For full documentation, see: README.md"

# Example usage targets
example-entities:
	@echo "Running base entities example..."
	@if [ -f "$(GEODE_CLI)" ]; then \
		echo "CREATE (test:Entity {id: gen_random_uuid(), metadata: {name: 'test_entity'}});" | $(GEODE_CLI) query; \
		echo "MATCH (e:Entity) WHERE e.metadata.name = 'test_entity' RETURN e;" | $(GEODE_CLI) query; \
	fi

example-dns:
	@echo "Running DNS hierarchy example..."
	@if [ -f "$(GEODE_CLI)" ]; then \
		echo "CALL create_domain('www.example.com.');" | $(GEODE_CLI) query; \
		echo "MATCH path = (d:Domain WHERE d.name = 'www.example.com.')-[:SUBDOMAIN_OF*]->(root) RETURN path;" | $(GEODE_CLI) query; \
	fi

example-auth:
	@echo "Running authentication example..."
	@if [ -f "$(GEODE_CLI)" ]; then \
		echo "CALL create_account('testuser', 'test@example.com', 'hashed_password', ['user']);" | $(GEODE_CLI) query; \
		echo "MATCH (a:Account WHERE a.username = 'testuser')-[:HAS_ROLE]->(r:Role) RETURN a.username, r.name;" | $(GEODE_CLI) query; \
	fi

# Development targets
dev-server:
	@echo "Starting Geode development server..."
	@if [ -f "$(GEODE_CLI)" ]; then \
		$(GEODE_CLI) serve --data-dir ./data --log-level debug; \
	else \
		echo "Geode CLI not found. Run 'make build' first."; \
	fi

dev-shell:
	@echo "Starting Geode interactive shell..."
	@if [ -f "$(GEODE_CLI)" ]; then \
		$(GEODE_CLI) shell; \
	else \
		echo "Geode CLI not found. Run 'make build' first."; \
	fi

# Schema export
export-schema:
	@echo "Exporting graph schema..."
	@if [ -f "$(GEODE_CLI)" ]; then \
		echo "SHOW LABELS;" | $(GEODE_CLI) query > schema_labels.txt; \
		echo "SHOW EDGE_TYPES;" | $(GEODE_CLI) query > schema_edges.txt; \
		echo "SHOW CONSTRAINTS;" | $(GEODE_CLI) query > schema_constraints.txt; \
		echo "Schema exported to schema_*.txt files"; \
	fi

# Performance testing
perf-test:
	@echo "Running basic performance tests..."
	@if [ -f "$(GEODE_CLI)" ]; then \
		echo "Creating test data..."; \
		for i in {1..100}; do \
			echo "CALL create_domain('test$$i.example.com.');" | $(GEODE_CLI) query > /dev/null; \
		done; \
		echo "Testing query performance..."; \
		time echo "MATCH (d:Domain) RETURN count(d);" | $(GEODE_CLI) query; \
	fi
