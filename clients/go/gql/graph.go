package gql

import (
	"context"
	"encoding/json"
	"fmt"
)

// GraphClient provides graph-specific operations
type GraphClient struct {
	conn *Conn
}

// Node represents a graph node
type Node struct {
	ID         int64             `json:"id"`
	Labels     []string          `json:"labels"`
	Properties map[string]Value  `json:"properties"`
}

// Edge represents a graph edge
type Edge struct {
	ID         int64             `json:"id"`
	Source     int64             `json:"source"`
	Target     int64             `json:"target"`
	Label      string            `json:"label"`
	Properties map[string]Value  `json:"properties"`
}

// Path represents a path in the graph
type Path struct {
	Nodes []Node `json:"nodes"`
	Edges []Edge `json:"edges"`
}

// GraphPattern represents a pattern for matching
type GraphPattern struct {
	Nodes       []NodePattern `json:"nodes"`
	Edges       []EdgePattern `json:"edges"`
	Where       string        `json:"where,omitempty"`
	OrderBy     []string      `json:"order_by,omitempty"`
	Limit       *int          `json:"limit,omitempty"`
	Offset      *int          `json:"offset,omitempty"`
}

// NodePattern for pattern matching
type NodePattern struct {
	Variable   string            `json:"variable,omitempty"`
	Labels     []string          `json:"labels,omitempty"`
	Properties map[string]Value  `json:"properties,omitempty"`
}

// EdgePattern for pattern matching
type EdgePattern struct {
	Variable   string            `json:"variable,omitempty"`
	Source     string            `json:"source"`
	Target     string            `json:"target"`
	Label      string            `json:"label,omitempty"`
	Properties map[string]Value  `json:"properties,omitempty"`
	MinHops    *int              `json:"min_hops,omitempty"`
	MaxHops    *int              `json:"max_hops,omitempty"`
}

// NewGraphClient creates a new graph client
func (c *Conn) Graph() *GraphClient {
	return &GraphClient{conn: c}
}

// CreateNode creates a new node
func (g *GraphClient) CreateNode(ctx context.Context, labels []string, properties map[string]Value) (*Node, error) {
	gql := "CREATE (n"
	if len(labels) > 0 {
		for i, label := range labels {
			if i == 0 {
				gql += ":"
			} else {
				gql += "&"
			}
			gql += label
		}
	}
	
	// Add properties
	if len(properties) > 0 {
		propsJSON, err := json.Marshal(properties)
		if err != nil {
			return nil, fmt.Errorf("failed to marshal properties: %w", err)
		}
		gql += fmt.Sprintf(" %s", string(propsJSON))
	}
	gql += ") RETURN n"
	
	page, pager, err := g.conn.Query(ctx, gql, nil, 100)
	if err != nil {
		return nil, fmt.Errorf("failed to create node: %w", err)
	}
	
	iter := &Iterator{
		page: page,
		pager: pager,
		ctx: ctx,
		rowIndex: 0,
	}
	
	if !iter.Next() {
		return nil, fmt.Errorf("no node returned")
	}
	
	row := iter.Row()
	if nodeVal, ok := row["n"]; ok {
		// Convert Value to Node
		node := &Node{
			Properties: make(map[string]Value),
		}
		if nodeVal.Kind == Object {
			if id, ok := nodeVal.Obj["id"]; ok {
				node.ID = id.Int
			}
			if labels, ok := nodeVal.Obj["labels"]; ok && labels.Kind == Array {
				for _, l := range labels.Arr {
					if l.Kind == Str {
						node.Labels = append(node.Labels, l.Str)
					}
				}
			}
			if props, ok := nodeVal.Obj["properties"]; ok && props.Kind == Object {
				node.Properties = props.Obj
			}
		}
		return node, nil
	}
	
	return nil, fmt.Errorf("failed to parse created node")
}

// CreateEdge creates a new edge between two nodes
func (g *GraphClient) CreateEdge(ctx context.Context, sourceID, targetID int64, label string, properties map[string]Value) (*Edge, error) {
	gql := fmt.Sprintf("MATCH (a), (b) WHERE id(a) = %d AND id(b) = %d ", sourceID, targetID)
	gql += fmt.Sprintf("CREATE (a)-[e:%s", label)
	
	// Add properties
	if len(properties) > 0 {
		propsJSON, err := json.Marshal(properties)
		if err != nil {
			return nil, fmt.Errorf("failed to marshal properties: %w", err)
		}
		gql += fmt.Sprintf(" %s", string(propsJSON))
	}
	gql += "]->(b) RETURN e"
	
	page, pager, err := g.conn.Query(ctx, gql, nil, 100)
	if err != nil {
		return nil, fmt.Errorf("failed to create edge: %w", err)
	}
	
	iter := &Iterator{
		page: page,
		pager: pager,
		ctx: ctx,
		rowIndex: 0,
	}
	
	if !iter.Next() {
		return nil, fmt.Errorf("no edge returned")
	}
	
	row := iter.Row()
	if edgeVal, ok := row["e"]; ok {
		edge := &Edge{
			Source:     sourceID,
			Target:     targetID,
			Label:      label,
			Properties: make(map[string]Value),
		}
		if edgeVal.Kind == Object {
			if id, ok := edgeVal.Obj["id"]; ok {
				edge.ID = id.Int
			}
			if props, ok := edgeVal.Obj["properties"]; ok && props.Kind == Object {
				edge.Properties = props.Obj
			}
		}
		return edge, nil
	}
	
	return nil, fmt.Errorf("failed to parse created edge")
}

// Iterator wraps the page-based iteration
type Iterator struct {
	page Page
	pager func(context.Context) (Page, error)
	err error
	ctx context.Context
	rowIndex int
}

func (it *Iterator) Next() bool {
	if it.err != nil {
		return false
	}
	if it.rowIndex < len(it.page.Rows) {
		return true
	}
	if it.pager == nil {
		return false
	}
	// Fetch next page
	it.page, it.err = it.pager(it.ctx)
	if it.err != nil {
		return false
	}
	it.rowIndex = 0
	it.pager = nil // Only one page for now
	return len(it.page.Rows) > 0
}

func (it *Iterator) Row() map[string]Value {
	if it.rowIndex < len(it.page.Rows) {
		row := it.page.Rows[it.rowIndex]
		it.rowIndex++
		return row
	}
	return nil
}

func (it *Iterator) Err() error {
	return it.err
}

func (it *Iterator) Close() {
	// Nothing to close for now
}

// Match performs a pattern match on the graph
func (g *GraphClient) Match(ctx context.Context, pattern *GraphPattern) (*Iterator, error) {
	// Build MATCH clause
	gql := "MATCH "
	
	// Add node patterns
	for i, np := range pattern.Nodes {
		if i > 0 {
			gql += ", "
		}
		gql += "("
		if np.Variable != "" {
			gql += np.Variable
		}
		if len(np.Labels) > 0 {
			for j, label := range np.Labels {
				if j == 0 {
					gql += ":"
				} else {
					gql += "&"
				}
				gql += label
			}
		}
		if len(np.Properties) > 0 {
			propsJSON, _ := json.Marshal(np.Properties)
			gql += fmt.Sprintf(" %s", string(propsJSON))
		}
		gql += ")"
	}
	
	// Add edge patterns
	for _, ep := range pattern.Edges {
		gql += fmt.Sprintf(", (%s)-[", ep.Source)
		if ep.Variable != "" {
			gql += ep.Variable
		}
		if ep.Label != "" {
			gql += ":" + ep.Label
		}
		if ep.MinHops != nil || ep.MaxHops != nil {
			gql += "*"
			if ep.MinHops != nil {
				gql += fmt.Sprintf("%d", *ep.MinHops)
			}
			gql += ".."
			if ep.MaxHops != nil {
				gql += fmt.Sprintf("%d", *ep.MaxHops)
			}
		}
		if len(ep.Properties) > 0 {
			propsJSON, _ := json.Marshal(ep.Properties)
			gql += fmt.Sprintf(" %s", string(propsJSON))
		}
		gql += fmt.Sprintf("]->(%s)", ep.Target)
	}
	
	// Add WHERE clause
	if pattern.Where != "" {
		gql += " WHERE " + pattern.Where
	}
	
	// Add RETURN clause (return all variables)
	gql += " RETURN *"
	
	// Add ORDER BY
	if len(pattern.OrderBy) > 0 {
		gql += " ORDER BY "
		for i, ord := range pattern.OrderBy {
			if i > 0 {
				gql += ", "
			}
			gql += ord
		}
	}
	
	// Add LIMIT/OFFSET
	if pattern.Limit != nil {
		gql += fmt.Sprintf(" LIMIT %d", *pattern.Limit)
	}
	if pattern.Offset != nil {
		gql += fmt.Sprintf(" OFFSET %d", *pattern.Offset)
	}
	
	page, pager, err := g.conn.Query(ctx, gql, nil, 100)
	if err != nil {
		return nil, err
	}
	return &Iterator{
		page: page,
		pager: pager,
		ctx: ctx,
		rowIndex: 0,
	}, nil
}

// ShortestPath finds the shortest path between two nodes
func (g *GraphClient) ShortestPath(ctx context.Context, sourceID, targetID int64, maxHops int) (*Path, error) {
	gql := fmt.Sprintf(
		"MATCH (a), (b), p = shortestPath((a)-[*..%d]-(b)) WHERE id(a) = %d AND id(b) = %d RETURN p",
		maxHops, sourceID, targetID,
	)
	
	page, pager, err := g.conn.Query(ctx, gql, nil, 100)
	if err != nil {
		return nil, fmt.Errorf("failed to find shortest path: %w", err)
	}
	
	iter := &Iterator{
		page: page,
		pager: pager,
		ctx: ctx,
		rowIndex: 0,
	}
	
	if !iter.Next() {
		return nil, fmt.Errorf("no path found")
	}
	
	row := iter.Row()
	if pathVal, ok := row["p"]; ok {
		return g.parsePathValue(pathVal), nil
	}
	
	return nil, fmt.Errorf("failed to parse path")
}

// AllShortestPaths finds all shortest paths between two nodes
func (g *GraphClient) AllShortestPaths(ctx context.Context, sourceID, targetID int64, maxHops int) ([]*Path, error) {
	gql := fmt.Sprintf(
		"MATCH (a), (b), p = allShortestPaths((a)-[*..%d]-(b)) WHERE id(a) = %d AND id(b) = %d RETURN p",
		maxHops, sourceID, targetID,
	)
	
	page, pager, err := g.conn.Query(ctx, gql, nil, 100)
	if err != nil {
		return nil, fmt.Errorf("failed to find shortest paths: %w", err)
	}
	
	iter := &Iterator{
		page: page,
		pager: pager,
		ctx: ctx,
		rowIndex: 0,
	}
	
	var paths []*Path
	for iter.Next() {
		row := iter.Row()
		if pathVal, ok := row["p"]; ok {
			paths = append(paths, g.parsePathValue(pathVal))
		}
	}
	
	if err := iter.Err(); err != nil {
		return nil, err
	}
	
	return paths, nil
}

// UpdateNode updates a node's properties
func (g *GraphClient) UpdateNode(ctx context.Context, nodeID int64, properties map[string]Value) error {
	propsJSON, err := json.Marshal(properties)
	if err != nil {
		return fmt.Errorf("failed to marshal properties: %w", err)
	}
	
	gql := fmt.Sprintf("MATCH (n) WHERE id(n) = %d SET n += %s", nodeID, string(propsJSON))
	
	_, _, err = g.conn.Query(ctx, gql, nil, 100)
	if err != nil {
		return fmt.Errorf("failed to update node: %w", err)
	}
	
	return nil
}

// DeleteNode deletes a node and its relationships
func (g *GraphClient) DeleteNode(ctx context.Context, nodeID int64) error {
	gql := fmt.Sprintf("MATCH (n) WHERE id(n) = %d DETACH DELETE n", nodeID)
	
	_, _, err := g.conn.Query(ctx, gql, nil, 100)
	if err != nil {
		return fmt.Errorf("failed to delete node: %w", err)
	}
	
	return nil
}

// DeleteEdge deletes an edge
func (g *GraphClient) DeleteEdge(ctx context.Context, edgeID int64) error {
	gql := fmt.Sprintf("MATCH ()-[e]-() WHERE id(e) = %d DELETE e", edgeID)
	
	_, _, err := g.conn.Query(ctx, gql, nil, 100)
	if err != nil {
		return fmt.Errorf("failed to delete edge: %w", err)
	}
	
	return nil
}

// Helper function to parse path values
func (g *GraphClient) parsePathValue(pathVal Value) *Path {
	path := &Path{
		Nodes: []Node{},
		Edges: []Edge{},
	}
	
	if pathVal.Kind == Object {
		if nodes, ok := pathVal.Obj["nodes"]; ok && nodes.Kind == Array {
			for _, n := range nodes.Arr {
				node := Node{Properties: make(map[string]Value)}
				if n.Kind == Object {
					if id, ok := n.Obj["id"]; ok {
						node.ID = id.Int
					}
					if labels, ok := n.Obj["labels"]; ok && labels.Kind == Array {
						for _, l := range labels.Arr {
							if l.Kind == Str {
								node.Labels = append(node.Labels, l.Str)
							}
						}
					}
					if props, ok := n.Obj["properties"]; ok && props.Kind == Object {
						node.Properties = props.Obj
					}
				}
				path.Nodes = append(path.Nodes, node)
			}
		}
		
		if edges, ok := pathVal.Obj["edges"]; ok && edges.Kind == Array {
			for _, e := range edges.Arr {
				edge := Edge{Properties: make(map[string]Value)}
				if e.Kind == Object {
					if id, ok := e.Obj["id"]; ok {
						edge.ID = id.Int
					}
					if src, ok := e.Obj["source"]; ok {
						edge.Source = src.Int
					}
					if tgt, ok := e.Obj["target"]; ok {
						edge.Target = tgt.Int
					}
					if label, ok := e.Obj["label"]; ok && label.Kind == Str {
						edge.Label = label.Str
					}
					if props, ok := e.Obj["properties"]; ok && props.Kind == Object {
						edge.Properties = props.Obj
					}
				}
				path.Edges = append(path.Edges, edge)
			}
		}
	}
	
	return path
}