package main

import "errors"

// query identifies one of the prepared statements every engine holds.
type query uint8

const (
	qFeed query = iota
	qPost
	qCreate
	qLike
	qExists
	qPing
	qBegin
	qCommit
	qRollback
	numQueries
)

var querySQL = [numQueries]string{
	qFeed: sqlFeed, qPost: sqlPost, qCreate: sqlCreate, qLike: sqlLike, qExists: sqlExists, qPing: sqlPing,
	qBegin: "BEGIN IMMEDIATE", qCommit: "COMMIT", qRollback: "ROLLBACK",
}

var errDB = errors.New("sqlite error")

// engine is the SQLite binding behind the DB goroutine. Selected by SQLITE_BACKEND: "cgo" (the
// amalgamation through shim.c, one cgo call per query) or "go" (zombiezen.com/go/sqlite, pure Go).
// Only one goroutine ever calls it.
type engine interface {
	// run executes q with up to two integer and two text parameters (a nil text is not bound) and
	// appends the single text column of the first row to out. rows is 0 when no row came back.
	run(q query, i1, i2 int64, t1, t2 []byte, out []byte) (_ []byte, rows int, err error)
	// exec runs a statement without result columns; returns the number of rows changed.
	exec(q query, i1, i2 int64) (changes int, err error)
	// walFrames is the WAL size after the last commit, in frames; checkpoint truncates the WAL.
	walFrames() int
	checkpoint()
}
