package gql

import "context"

// Client-side savepoint/rollback emulation (no-op on server if unsupported)

type Savepoint struct{ name string }

func (c *Conn) Savepoint(_ context.Context, name string) (*Savepoint, error) {
	return &Savepoint{name: name}, nil
}

func (c *Conn) RollbackTo(_ context.Context, sp *Savepoint) error {
	_ = sp
	// Client-side emulation; nothing to send to server currently
	return nil
}
