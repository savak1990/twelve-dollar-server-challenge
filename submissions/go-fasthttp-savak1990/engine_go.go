package main

import (
	"fmt"

	"zombiezen.com/go/sqlite"
	"zombiezen.com/go/sqlite/sqlitex"
)

// goEngine: zombiezen.com/go/sqlite (SQLite transpiled to Go by modernc.org/sqlite, no cgo).
// No WAL hook is exposed, so WAL growth is estimated from the number of write statements.
type goEngine struct {
	conn   *sqlite.Conn
	stmts  [numQueries]*sqlite.Stmt
	frames int
}

func openGoEngine(path string) (*goEngine, error) {
	conn, err := sqlite.OpenConn(path, sqlite.OpenReadWrite|sqlite.OpenWAL)
	if err != nil {
		return nil, err
	}
	e := &goEngine{conn: conn}
	for _, p := range pragmas {
		if err := sqlitex.ExecuteTransient(conn, p, nil); err != nil {
			return nil, fmt.Errorf("%s: %w", p, err)
		}
	}
	for q, sql := range querySQL {
		if e.stmts[q], err = conn.Prepare(sql); err != nil {
			return nil, fmt.Errorf("prepare %q: %w", sql, err)
		}
	}
	return e, nil
}

// bind mirrors shim_query's parameter layout; unlike the C API, an out-of-range bind is an error
// here, so statements without parameters (SELECT 1, BEGIN) must not be bound at all.
func (e *goEngine) bind(s *sqlite.Stmt, i1, i2 int64, t1, t2 []byte) {
	np := s.BindParamCount()
	idx := 1
	if idx <= np {
		s.BindInt64(idx, i1)
		idx++
	}
	if i2 >= 0 && idx <= np {
		s.BindInt64(idx, i2)
		idx++
	}
	if t1 != nil && idx <= np {
		s.BindText(idx, string(t1))
		idx++
	}
	if t2 != nil && idx <= np {
		s.BindText(idx, string(t2))
	}
}

func (e *goEngine) run(q query, i1, i2 int64, t1, t2 []byte, out []byte) (_ []byte, rows int, err error) {
	s := e.stmts[q]
	e.bind(s, i1, i2, t1, t2)
	defer func() {
		if rerr := s.Reset(); rerr != nil && err == nil {
			err = fmt.Errorf("%w: %v", errDB, rerr)
		}
		_ = s.ClearBindings()
	}()
	has, err := s.Step()
	if err != nil {
		return out, 0, fmt.Errorf("%w: %v", errDB, err)
	}
	if !has {
		return out, 0, nil
	}
	n := s.ColumnLen(0)
	if cap(out)-len(out) < n {
		out = grow(out, n)[:len(out)]
	}
	s.ColumnBytes(0, out[len(out):len(out)+n])
	out = out[:len(out)+n]
	if q == qCreate || q == qLike {
		e.frames += 2
	}
	if _, err = s.Step(); err != nil { // drain to SQLITE_DONE like the shim does
		return out, 0, fmt.Errorf("%w: %v", errDB, err)
	}
	return out, 1, nil
}

func (e *goEngine) exec(q query, i1, i2 int64) (int, error) {
	s := e.stmts[q]
	if q < qBegin { // transaction control statements take no parameters
		s.BindInt64(1, i1)
		s.BindInt64(2, i2)
	}
	_, err := s.Step()
	_ = s.Reset()
	if err != nil {
		return 0, fmt.Errorf("%w: %v", errDB, err)
	}
	if q >= qBegin {
		return 0, nil
	}
	n := e.conn.Changes()
	e.frames += 2 * n
	return n, nil
}

func (e *goEngine) walFrames() int { return e.frames }

func (e *goEngine) checkpoint() {
	if err := sqlitex.ExecuteTransient(e.conn, "PRAGMA wal_checkpoint(TRUNCATE)", nil); err == nil {
		e.frames = 0
	}
}
