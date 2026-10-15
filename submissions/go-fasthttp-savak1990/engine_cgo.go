package main

/*
// SQLite is compiled by build.sh into sqlite/libsqlite3.a (compile options live there too).
#cgo LDFLAGS: ${SRCDIR}/sqlite/libsqlite3.a -lm
#include <stdlib.h>
#include "shim.h"
*/
import "C"

import (
	"fmt"
	"unsafe"
)

// cgoEngine: the pinned amalgamation (SQLITE_THREADSAFE=0) behind shim.c; one cgo call per query.
type cgoEngine struct {
	conn  *C.sqlite3
	stmts [numQueries]*C.sqlite3_stmt
}

func openCgoEngine(path string) (*cgoEngine, error) {
	if rc := C.sqlite3_initialize(); rc != C.SQLITE_OK {
		return nil, fmt.Errorf("sqlite3_initialize: %d", rc)
	}
	cpath := C.CString(path)
	defer C.free(unsafe.Pointer(cpath))
	e := &cgoEngine{}
	if rc := C.sqlite3_open_v2(cpath, &e.conn, C.SQLITE_OPEN_READWRITE, nil); rc != C.SQLITE_OK {
		return nil, fmt.Errorf("open %s: %s", path, C.GoString(C.sqlite3_errstr(rc)))
	}
	for _, p := range pragmas {
		if err := e.execSQL(p); err != nil {
			return nil, err
		}
	}
	for q, sql := range querySQL {
		c := C.CString(sql)
		rc := C.sqlite3_prepare_v3(e.conn, c, -1, C.SQLITE_PREPARE_PERSISTENT, &e.stmts[q], nil)
		C.free(unsafe.Pointer(c))
		if rc != C.SQLITE_OK {
			return nil, fmt.Errorf("prepare %q: %s", sql, e.errmsg())
		}
	}
	C.shim_install_wal_hook(e.conn)
	return e, nil
}

func (e *cgoEngine) errmsg() string { return C.GoString(C.sqlite3_errmsg(e.conn)) }

func (e *cgoEngine) execSQL(sql string) error {
	c := C.CString(sql)
	defer C.free(unsafe.Pointer(c))
	if rc := C.sqlite3_exec(e.conn, c, nil, nil, nil); rc != C.SQLITE_OK {
		return fmt.Errorf("%s: %s", sql, e.errmsg())
	}
	return nil
}

func cptr(b []byte) *C.char {
	if len(b) == 0 {
		return nil
	}
	return (*C.char)(unsafe.Pointer(unsafe.SliceData(b)))
}

func (e *cgoEngine) run(q query, i1, i2 int64, t1, t2 []byte, out []byte) (_ []byte, rows int, err error) {
	n1, n2 := -1, -1
	if t1 != nil {
		n1 = len(t1)
	}
	if t2 != nil {
		n2 = len(t2)
	}
	for {
		room := cap(out) - len(out)
		n := int(C.shim_query(e.stmts[q], C.sqlite3_int64(i1), C.sqlite3_int64(i2), cptr(t1), C.int(n1), cptr(t2), C.int(n2),
			(*C.uchar)(unsafe.Pointer(unsafe.SliceData(out[len(out):cap(out)]))), C.int(room)))
		switch {
		case n < 0:
			return out, 0, fmt.Errorf("%w: %s", errDB, e.errmsg())
		case n == 0:
			return out, 0, nil
		case n <= room:
			return out[:len(out)+n], 1, nil
		}
		out = grow(out, n)[:len(out)]
	}
}

func (e *cgoEngine) exec(q query, i1, i2 int64) (int, error) {
	if q >= qBegin { // transaction control: no parameters, no row count
		rc := C.sqlite3_step(e.stmts[q])
		C.sqlite3_reset(e.stmts[q])
		if rc != C.SQLITE_DONE {
			return 0, fmt.Errorf("%w: %s", errDB, e.errmsg())
		}
		return 0, nil
	}
	n := int(C.shim_exec(e.stmts[q], C.sqlite3_int64(i1), C.sqlite3_int64(i2)))
	if n < 0 {
		return 0, fmt.Errorf("%w: %s", errDB, e.errmsg())
	}
	return n, nil
}

func (e *cgoEngine) walFrames() int { return int(C.shim_wal_frames()) }
func (e *cgoEngine) checkpoint()    { C.shim_checkpoint(e.conn) }
