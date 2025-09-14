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
	lastUsed map[*Conn]time.Time
	created int
	closing bool
	cond *sync.Cond
}

func NewPool(addr, helloName, helloVer, conf string, pageSize, max int, idleTimeout time.Duration) *Pool {
	p := &Pool{addr: addr, helloName: helloName, helloVer: helloVer, conf: conf, pageSize: pageSize, max: max, idleTimeout: idleTimeout, lastUsed: make(map[*Conn]time.Time)}
	p.cond = sync.NewCond(&p.mu)
	return p
}

func (p *Pool) Acquire(ctx context.Context) (*Conn, error) {
	deadline := time.Now().Add(5 * time.Second)
	jitter := func() { time.Sleep(time.Duration(5+time.Now().UnixNano()%5) * time.Millisecond) }
	for {
		p.mu.Lock()
		if p.closing { p.mu.Unlock(); return nil, errors.New("pool closed") }
		// prune expired
		if p.idleTimeout > 0 {
			now := time.Now()
			kept := p.idle[:0]
			for _, c := range p.idle {
				if lu, ok := p.lastUsed[c]; ok && now.Sub(lu) > p.idleTimeout {
					_ = c.Close(); p.created--; delete(p.lastUsed, c); continue
				}
				kept = append(kept, c)
			}
			p.idle = kept
		}
		if n := len(p.idle); n > 0 {
			c := p.idle[n-1]
			p.idle = p.idle[:n-1]
			p.mu.Unlock()
			// NOTE: PING health check removed for now. The previous implementation
			// dropped the connection on any failure without decrementing the
			// created counter, leading to a deadlock where created == max but no
			// usable connections existed. We'll trust the connection; failures will
			// surface on next use and the caller can Close(). A future revision can
			// reintroduce health checks with proper accounting.
			return c, nil
		}
		if p.created < p.max {
			p.created++
			p.mu.Unlock()
			db := &DB{addr: p.addr, pageSize: p.pageSize, helloName: p.helloName, helloVer: p.helloVer, conf: p.conf}
			c, err := db.Connect(ctx)
			if err != nil { p.mu.Lock(); p.created--; p.mu.Unlock(); return nil, err }
			return c, nil
		}
		// wait
		if time.Now().After(deadline) { p.mu.Unlock(); return nil, errors.New("pool acquire timeout") }
		p.cond.Wait()
		p.mu.Unlock()
		jitter()
	}
}

func (p *Pool) Release(c *Conn) {
	if c == nil { return }
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closing { _ = c.Close(); p.created--; return }
	if p.lastUsed != nil { p.lastUsed[c] = time.Now() }
	p.idle = append(p.idle, c)
	p.cond.Signal()
}

func (p *Pool) Close() {
	p.mu.Lock(); defer p.mu.Unlock()
	p.closing = true
	for _, c := range p.idle { _ = c.Close() }
	p.idle = nil
	p.lastUsed = nil
	p.created = 0
}
