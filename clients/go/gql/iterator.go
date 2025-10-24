package gql

import (
	"context"
	"encoding/json"
	"io"
)

type RowIterator struct {
	c        *Conn
	ctx      context.Context
	cols     []Column
	rows     []map[string]Value
	i        int
	final    bool
	types    map[string]string
	pageSize int
}

func (c *Conn) NewIterator(ctx context.Context, text string, params map[string]any, pageSize int) (*RowIterator, error) {
	if pageSize <= 0 {
		pageSize = 1000
	}
	run := map[string]any{"type": "RUN_GQL", "text": text}
	if len(params) > 0 {
		run["params"] = params
	}
	if err := c.writeJSON(run); err != nil {
		return nil, err
	}
	l1, err := c.readLine(ctx)
	if err != nil {
		return nil, err
	}
	var fr frame
	if err := json.Unmarshal(l1, &fr); err != nil {
		return nil, err
	}
	if fr.Result.Type == "ERROR" {
		return nil, &Error{StatusClass: fr.StatusClass, Code: fr.Result.Code, Message: fr.Result.Message, Anchor: fr.Result.Anchor, FlaggerFindings: fr.Result.FlaggerFindings}
	}
	if fr.Result.Type != "SCHEMA" {
		return nil, io.ErrUnexpectedEOF
	}
	cols := make([]Column, len(fr.Result.Columns))
	types := make(map[string]string, len(fr.Result.Columns))
	for i, cdef := range fr.Result.Columns {
		cols[i] = Column{Name: cdef.Name, Type: cdef.Type}
		types[cdef.Name] = cdef.Type
	}
	it := &RowIterator{c: c, ctx: ctx, cols: cols, types: types, pageSize: pageSize}
	return it, nil
}

func (it *RowIterator) Next() (map[string]Value, error) {
	for {
		if it.i < len(it.rows) {
			r := it.rows[it.i]
			it.i++
			return r, nil
		}
		if it.final {
			return nil, io.EOF
		}
		if err := it.c.writeJSON(map[string]any{"type": "PULL", "request_id": 1, "page_size": it.pageSize}); err != nil {
			return nil, err
		}
		line, err := it.c.readLine(it.ctx)
		if err != nil {
			return nil, err
		}
		var f frame
		if err := json.Unmarshal(line, &f); err != nil {
			return nil, err
		}
		if f.Result.Type == "ERROR" {
			return nil, io.EOF
		}
		if f.Result.Type != "BINDINGS" {
			return nil, io.ErrUnexpectedEOF
		}
		it.rows = toRowsTyped(f.Result.Rows, it.types)
		it.i = 0
		it.final = f.Result.Final
		// dynamic tuning: increase page size modestly for very small rows
		if len(it.rows) > 0 {
			// heuristic: if average row has few keys (<4), increase page size up to cap
			if len(it.rows[0]) < 4 && it.pageSize < 10000 {
				it.pageSize *= 2
			}
		}
	}
}

func (it *RowIterator) Columns() []Column { return it.cols }

// CurrentPageSize returns the page size the iterator will request next.
func (it *RowIterator) CurrentPageSize() int { return it.pageSize }
