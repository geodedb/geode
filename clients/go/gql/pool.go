package gql

import (
	"context"
	"errors"
	"sync"
	"time"
)

type Pool struct {
	addr string
	helloName string
	helloVer string
	conf string
	pageSize int
	max int
	idleTimeout time.Duration
	mu sync.Mutex
	idle []*Conn
	created int
	closing bool
}

func NewPool(addr, helloName, helloVer, conf string, pageSize, max int, idleTimeout time.Duration) *Pool {
	return &Pool{addr: addr, helloName: helloName, helloVer: helloVer, conf: conf, pageSize: pageSize, max: max, idleTimeout: idleTimeout}
}

func (p *Pool) Acquire(ctx context.Context) (*Conn, error) {
	deadline := time.Now().Add(5 * time.Second)
	for {
		p.mu.Lock()
		if p.closing { p.mu.Unlock(); return nil, errors.New("pool closed") }
		// pop idle
		for len(p.idle) > 0 {
			c := p.idle[len(p.idle)-1]
			p.idle = p.idle[:len(p.idle)-1]
			p.mu.Unlock()
			return c, nil
		}
		if p.created < p.max {
			p.created++
			p.mu.Unlock()
			// create
			db := &DB{addr: p.addr, pageSize: p.pageSize, helloName: p.helloName, helloVer: p.helloVer, conf: p.conf}
			c, err := db.Connect(ctx)
			if err != nil {
				p.mu.Lock(); p.created--; p.mu.Unlock()
				return nil, err
			}
			return c, nil
		}
		p.mu.Unlock()
		if time.Now().After(deadline) { return nil, errors.New("pool acquire timeout") }
		time.Sleep(5 * time.Millisecond)
	}
}

func (p *Pool) Release(c *Conn) {
	if c == nil { return }
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closing { _ = c.Close(); p.created--; return }
	p.idle = append(p.idle, c)
}

func (p *Pool) Close() {
	p.mu.Lock(); defer p.mu.Unlock()
	p.closing = true
	for _, c := range p.idle { _ = c.Close() }
	p.idle = nil
	p.created = 0
}
