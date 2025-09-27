package gql

import "context"

// Client-side savepoint/rollback emulation (no-op on server if unsupported)

type Savepoint struct{ name string }

func (c *Conn) Savepoint(ctx context.Context, name string) (*Savepoint, error) {
	if err := c.writeJSON(map[string]any{"type": "SAVEPOINT", "name": name}); err != nil {
		return nil, err
	}
	if _, err := c.readLine(ctx); err != nil {
		return nil, err
	}
	return &Savepoint{name: name}, nil
}

func (c *Conn) RollbackTo(ctx context.Context, sp *Savepoint) error {
	if err := c.writeJSON(map[string]any{"type": "ROLLBACK_TO", "name": sp.name}); err != nil {
		return err
	}
	_, err := c.readLine(ctx)
	return err
}
