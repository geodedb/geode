package gql

import (
	"fmt"
	"strings"
)

// QueryBuilder provides a fluent interface for building GQL queries
type QueryBuilder struct {
	clauses []clause
	params  map[string]interface{}
}

type clause struct {
	typ     clauseType
	content string
}

type clauseType int

const (
	matchClause clauseType = iota
	optionalMatchClause
	whereClause
	withClause
	returnClause
	orderByClause
	limitClause
	offsetClause
	createClause
	mergeClause
	setClause
	deleteClause
	unionClause
	groupByClause
)

// NewQueryBuilder creates a new query builder
func NewQueryBuilder() *QueryBuilder {
	return &QueryBuilder{
		clauses: make([]clause, 0),
		params:  make(map[string]interface{}),
	}
}

// Match adds a MATCH clause
func (qb *QueryBuilder) Match(pattern string) *QueryBuilder {
	qb.clauses = append(qb.clauses, clause{
		typ:     matchClause,
		content: pattern,
	})
	return qb
}

// OptionalMatch adds an OPTIONAL MATCH clause
func (qb *QueryBuilder) OptionalMatch(pattern string) *QueryBuilder {
	qb.clauses = append(qb.clauses, clause{
		typ:     optionalMatchClause,
		content: pattern,
	})
	return qb
}

// Where adds a WHERE clause
func (qb *QueryBuilder) Where(condition string) *QueryBuilder {
	qb.clauses = append(qb.clauses, clause{
		typ:     whereClause,
		content: condition,
	})
	return qb
}

// With adds a WITH clause
func (qb *QueryBuilder) With(expressions ...string) *QueryBuilder {
	qb.clauses = append(qb.clauses, clause{
		typ:     withClause,
		content: strings.Join(expressions, ", "),
	})
	return qb
}

// Return adds a RETURN clause
func (qb *QueryBuilder) Return(expressions ...string) *QueryBuilder {
	qb.clauses = append(qb.clauses, clause{
		typ:     returnClause,
		content: strings.Join(expressions, ", "),
	})
	return qb
}

// OrderBy adds an ORDER BY clause
func (qb *QueryBuilder) OrderBy(expressions ...string) *QueryBuilder {
	qb.clauses = append(qb.clauses, clause{
		typ:     orderByClause,
		content: strings.Join(expressions, ", "),
	})
	return qb
}

// Limit adds a LIMIT clause
func (qb *QueryBuilder) Limit(n int) *QueryBuilder {
	qb.clauses = append(qb.clauses, clause{
		typ:     limitClause,
		content: fmt.Sprintf("%d", n),
	})
	return qb
}

// Offset adds an OFFSET clause
func (qb *QueryBuilder) Offset(n int) *QueryBuilder {
	qb.clauses = append(qb.clauses, clause{
		typ:     offsetClause,
		content: fmt.Sprintf("%d", n),
	})
	return qb
}

// Create adds a CREATE clause
func (qb *QueryBuilder) Create(pattern string) *QueryBuilder {
	qb.clauses = append(qb.clauses, clause{
		typ:     createClause,
		content: pattern,
	})
	return qb
}

// Merge adds a MERGE clause
func (qb *QueryBuilder) Merge(pattern string) *QueryBuilder {
	qb.clauses = append(qb.clauses, clause{
		typ:     mergeClause,
		content: pattern,
	})
	return qb
}

// Set adds a SET clause
func (qb *QueryBuilder) Set(assignments ...string) *QueryBuilder {
	qb.clauses = append(qb.clauses, clause{
		typ:     setClause,
		content: strings.Join(assignments, ", "),
	})
	return qb
}

// Delete adds a DELETE clause
func (qb *QueryBuilder) Delete(variables ...string) *QueryBuilder {
	qb.clauses = append(qb.clauses, clause{
		typ:     deleteClause,
		content: strings.Join(variables, ", "),
	})
	return qb
}

// Union adds a UNION clause
func (qb *QueryBuilder) Union() *QueryBuilder {
	qb.clauses = append(qb.clauses, clause{
		typ:     unionClause,
		content: "",
	})
	return qb
}

// GroupBy adds a GROUP BY clause
func (qb *QueryBuilder) GroupBy(expressions ...string) *QueryBuilder {
	qb.clauses = append(qb.clauses, clause{
		typ:     groupByClause,
		content: strings.Join(expressions, ", "),
	})
	return qb
}

// WithParam adds a parameter to the query
func (qb *QueryBuilder) WithParam(name string, value interface{}) *QueryBuilder {
	qb.params[name] = value
	return qb
}

// WithParams adds multiple parameters to the query
func (qb *QueryBuilder) WithParams(params map[string]interface{}) *QueryBuilder {
	for k, v := range params {
		qb.params[k] = v
	}
	return qb
}

// Build generates the final GQL query string
func (qb *QueryBuilder) Build() string {
	var parts []string
	
	for _, clause := range qb.clauses {
		switch clause.typ {
		case matchClause:
			parts = append(parts, fmt.Sprintf("MATCH %s", clause.content))
		case optionalMatchClause:
			parts = append(parts, fmt.Sprintf("OPTIONAL MATCH %s", clause.content))
		case whereClause:
			parts = append(parts, fmt.Sprintf("WHERE %s", clause.content))
		case withClause:
			parts = append(parts, fmt.Sprintf("WITH %s", clause.content))
		case returnClause:
			parts = append(parts, fmt.Sprintf("RETURN %s", clause.content))
		case orderByClause:
			parts = append(parts, fmt.Sprintf("ORDER BY %s", clause.content))
		case limitClause:
			parts = append(parts, fmt.Sprintf("LIMIT %s", clause.content))
		case offsetClause:
			parts = append(parts, fmt.Sprintf("OFFSET %s", clause.content))
		case createClause:
			parts = append(parts, fmt.Sprintf("CREATE %s", clause.content))
		case mergeClause:
			parts = append(parts, fmt.Sprintf("MERGE %s", clause.content))
		case setClause:
			parts = append(parts, fmt.Sprintf("SET %s", clause.content))
		case deleteClause:
			parts = append(parts, fmt.Sprintf("DELETE %s", clause.content))
		case unionClause:
			parts = append(parts, "UNION")
		case groupByClause:
			parts = append(parts, fmt.Sprintf("GROUP BY %s", clause.content))
		}
	}
	
	return strings.Join(parts, "\n")
}

// GetParams returns the parameters for the query
func (qb *QueryBuilder) GetParams() map[string]interface{} {
	return qb.params
}

// PatternBuilder helps build graph patterns
type PatternBuilder struct {
	elements []patternElement
}

type patternElement struct {
	typ     patternType
	content string
}

type patternType int

const (
	nodePattern patternType = iota
	edgePattern
)

// NewPatternBuilder creates a new pattern builder
func NewPatternBuilder() *PatternBuilder {
	return &PatternBuilder{
		elements: make([]patternElement, 0),
	}
}

// Node adds a node pattern
func (pb *PatternBuilder) Node(variable, label string, properties ...map[string]interface{}) *PatternBuilder {
	var pattern string
	if variable != "" {
		pattern = fmt.Sprintf("(%s", variable)
	} else {
		pattern = "("
	}
	
	if label != "" {
		pattern += fmt.Sprintf(":%s", label)
	}
	
	if len(properties) > 0 && properties[0] != nil {
		props := make([]string, 0)
		for k, v := range properties[0] {
			props = append(props, fmt.Sprintf("%s: %v", k, formatValue(v)))
		}
		pattern += fmt.Sprintf(" {%s}", strings.Join(props, ", "))
	}
	
	pattern += ")"
	
	pb.elements = append(pb.elements, patternElement{
		typ:     nodePattern,
		content: pattern,
	})
	
	return pb
}

// Edge adds an edge pattern
func (pb *PatternBuilder) Edge(variable, typ string, direction EdgeDirection, properties ...map[string]interface{}) *PatternBuilder {
	var pattern string
	
	switch direction {
	case Outgoing:
		pattern = "-"
	case Incoming:
		pattern = "<-"
	case Undirected:
		pattern = "-"
	}
	
	if variable != "" || typ != "" || len(properties) > 0 {
		pattern += "["
		
		if variable != "" {
			pattern += variable
		}
		
		if typ != "" {
			pattern += fmt.Sprintf(":%s", typ)
		}
		
		if len(properties) > 0 && properties[0] != nil {
			props := make([]string, 0)
			for k, v := range properties[0] {
				props = append(props, fmt.Sprintf("%s: %v", k, formatValue(v)))
			}
			pattern += fmt.Sprintf(" {%s}", strings.Join(props, ", "))
		}
		
		pattern += "]"
	}
	
	switch direction {
	case Outgoing:
		pattern += "->"
	case Incoming:
		// Already has <- at the beginning
	case Undirected:
		pattern += "-"
	}
	
	pb.elements = append(pb.elements, patternElement{
		typ:     edgePattern,
		content: pattern,
	})
	
	return pb
}

// VariableLength adds variable length to the last edge
func (pb *PatternBuilder) VariableLength(min, max int) *PatternBuilder {
	if len(pb.elements) > 0 && pb.elements[len(pb.elements)-1].typ == edgePattern {
		edge := &pb.elements[len(pb.elements)-1]
		// Insert variable length before the closing bracket
		idx := strings.LastIndex(edge.content, "]")
		if idx != -1 {
			var lengthSpec string
			if min == 0 && max == 0 {
				lengthSpec = "*"
			} else if max == 0 {
				lengthSpec = fmt.Sprintf("*%d..", min)
			} else {
				lengthSpec = fmt.Sprintf("*%d..%d", min, max)
			}
			edge.content = edge.content[:idx] + lengthSpec + edge.content[idx:]
		}
	}
	return pb
}

// Build generates the pattern string
func (pb *PatternBuilder) Build() string {
	parts := make([]string, len(pb.elements))
	for i, elem := range pb.elements {
		parts[i] = elem.content
	}
	return strings.Join(parts, "")
}

// EdgeDirection represents the direction of an edge
type EdgeDirection int

const (
	Outgoing EdgeDirection = iota
	Incoming
	Undirected
)

// Helper function to format values for GQL
func formatValue(v interface{}) string {
	switch val := v.(type) {
	case string:
		return fmt.Sprintf("'%s'", strings.ReplaceAll(val, "'", "\\'"))
	case int, int32, int64, float32, float64, bool:
		return fmt.Sprintf("%v", val)
	case nil:
		return "null"
	default:
		return fmt.Sprintf("%v", val)
	}
}

// PredicateBuilder helps build WHERE conditions
type PredicateBuilder struct {
	conditions []string
}

// NewPredicateBuilder creates a new predicate builder
func NewPredicateBuilder() *PredicateBuilder {
	return &PredicateBuilder{
		conditions: make([]string, 0),
	}
}

// Equals adds an equality condition
func (pb *PredicateBuilder) Equals(left, right string) *PredicateBuilder {
	pb.conditions = append(pb.conditions, fmt.Sprintf("%s = %s", left, right))
	return pb
}

// NotEquals adds an inequality condition
func (pb *PredicateBuilder) NotEquals(left, right string) *PredicateBuilder {
	pb.conditions = append(pb.conditions, fmt.Sprintf("%s <> %s", left, right))
	return pb
}

// GreaterThan adds a greater than condition
func (pb *PredicateBuilder) GreaterThan(left, right string) *PredicateBuilder {
	pb.conditions = append(pb.conditions, fmt.Sprintf("%s > %s", left, right))
	return pb
}

// LessThan adds a less than condition
func (pb *PredicateBuilder) LessThan(left, right string) *PredicateBuilder {
	pb.conditions = append(pb.conditions, fmt.Sprintf("%s < %s", left, right))
	return pb
}

// In adds an IN condition
func (pb *PredicateBuilder) In(expr string, values []interface{}) *PredicateBuilder {
	formatted := make([]string, len(values))
	for i, v := range values {
		formatted[i] = formatValue(v)
	}
	pb.conditions = append(pb.conditions, fmt.Sprintf("%s IN [%s]", expr, strings.Join(formatted, ", ")))
	return pb
}

// IsNull adds an IS NULL condition
func (pb *PredicateBuilder) IsNull(expr string) *PredicateBuilder {
	pb.conditions = append(pb.conditions, fmt.Sprintf("%s IS NULL", expr))
	return pb
}

// IsNotNull adds an IS NOT NULL condition
func (pb *PredicateBuilder) IsNotNull(expr string) *PredicateBuilder {
	pb.conditions = append(pb.conditions, fmt.Sprintf("%s IS NOT NULL", expr))
	return pb
}

// Exists adds an EXISTS condition
func (pb *PredicateBuilder) Exists(pattern string) *PredicateBuilder {
	pb.conditions = append(pb.conditions, fmt.Sprintf("EXISTS { %s }", pattern))
	return pb
}

// And combines conditions with AND
func (pb *PredicateBuilder) And() string {
	return strings.Join(pb.conditions, " AND ")
}

// Or combines conditions with OR
func (pb *PredicateBuilder) Or() string {
	return strings.Join(pb.conditions, " OR ")
}

// Example usage functions

// FindFriends builds a query to find friends of a person
func FindFriends(personName string, limit int) (string, map[string]interface{}) {
	qb := NewQueryBuilder().
		Match("(p:Person {name: $name})-[:KNOWS]->(friend:Person)").
		Return("friend.name AS name", "friend.age AS age").
		OrderBy("friend.age DESC").
		Limit(limit).
		WithParam("name", personName)
	
	return qb.Build(), qb.GetParams()
}

// CreatePerson builds a query to create a person with relationships
func CreatePerson(name string, age int, company string) (string, map[string]interface{}) {
	qb := NewQueryBuilder().
		Create("(p:Person {name: $name, age: $age})").
		Merge("(c:Company {name: $company})").
		Create("(p)-[:WORKS_AT]->(c)").
		Return("p, c").
		WithParams(map[string]interface{}{
			"name":    name,
			"age":     age,
			"company": company,
		})
	
	return qb.Build(), qb.GetParams()
}

// FindShortestPath builds a query to find the shortest path between two people
func FindShortestPath(person1, person2 string) (string, map[string]interface{}) {
	pattern := NewPatternBuilder().
		Node("a", "Person", map[string]interface{}{"name": "$person1"}).
		Edge("", "KNOWS", Undirected).VariableLength(1, 6).
		Node("b", "Person", map[string]interface{}{"name": "$person2"}).
		Build()
	
	qb := NewQueryBuilder().
		Match(fmt.Sprintf("path = %s", pattern)).
		Return("path").
		OrderBy("LENGTH(path)").
		Limit(1).
		WithParams(map[string]interface{}{
			"person1": person1,
			"person2": person2,
		})
	
	return qb.Build(), qb.GetParams()
}

// ComplexQuery demonstrates a complex query with multiple clauses
func ComplexQuery() string {
	predicate := NewPredicateBuilder().
		GreaterThan("p.age", "25").
		NotEquals("p.city", "'NYC'").
		IsNotNull("p.email").
		And()
	
	qb := NewQueryBuilder().
		Match("(p:Person)").
		Where(predicate).
		OptionalMatch("(p)-[:WORKS_AT]->(c:Company)").
		With("p", "c").
		Match("(p)-[:PURCHASED]->(product:Product)").
		Return(
			"p.name AS person",
			"c.name AS company",
			"COUNT(product) AS purchase_count",
			"SUM(product.price) AS total_spent",
		).
		GroupBy("p.name", "c.name").
		OrderBy("total_spent DESC").
		Limit(10)
	
	return qb.Build()
}