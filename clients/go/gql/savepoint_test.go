package gql

import (
	"context"
	"testing"
	"time"
)

func TestSavepointRollbackSequence(t *testing.T) { // savepoint/rollback tests
	c := withConn(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := c.Begin(ctx); err != nil { t.Fatalf("begin: %v", err) }
	sp1, err := c.Savepoint(ctx, "sp1"); if err != nil { t.Fatalf("savepoint: %v", err) }
	// Run a simple query
	_, _, _ = c.Query(ctx, "RETURN 1 AS x", nil, 10)
	if err := c.RollbackTo(ctx, sp1); err != nil { t.Fatalf("rollback to: %v", err) }
	sp2, _ := c.Savepoint(ctx, "sp2")
	if err := c.RollbackTo(ctx, sp2); err != nil { t.Fatalf("rollback to sp2: %v", err) }
	if err := c.Commit(ctx); err != nil { t.Fatalf("commit: %v", err) }
}
