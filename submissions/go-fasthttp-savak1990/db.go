package main

/*
// SQLite is compiled by build.sh into sqlite/libsqlite3.a (compile options live there too).
#cgo LDFLAGS: ${SRCDIR}/sqlite/libsqlite3.a -lm
#include <stdlib.h>
#include "shim.h"
*/
import "C"

import (
	"errors"
	"fmt"
	"strconv"
	"unsafe"
)

// The whole post object is rendered by SQLite, so a request costs one cgo call and the bytes go
// from SQLite's result straight into the response buffer.
const postJSON = `json_object('id',p.id,'body',p.body,'created_at',p.created_at,'author',u.username,` +
	`'like_count',(SELECT count(*) FROM likes l WHERE l.post_id = p.id))`

const (
	// The subquery yields plain columns and the object is built inside the aggregate: building it in
	// the subquery would lose the JSON subtype and need a json() re-parse (+22% CPU, measured).
	// ORDER BY inside the aggregate pins the array order whatever plan SQLite picks.
	sqlFeed = `SELECT '{"posts":' || json_group_array(` +
		`json_object('id',id,'body',body,'created_at',ca,'author',username,'like_count',lc) ORDER BY ca DESC, id DESC) || '}' FROM (` +
		`SELECT p.id AS id, p.body AS body, p.created_at AS ca, u.username AS username, ` +
		`(SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS lc ` +
		`FROM posts p JOIN users u ON u.id = p.user_id ` +
		`ORDER BY p.created_at DESC, p.id DESC LIMIT 20)`
	sqlPost = `SELECT json_object('post', ` + postJSON + `) FROM posts p JOIN users u ON u.id = p.user_id WHERE p.id = ?1`
	// ?2 is the token username: author is taken from the token, not looked up (SPEC).
	sqlCreate = `INSERT INTO posts (user_id, body) VALUES (?1, ?3) RETURNING ` +
		`json_object('post', json_object('id',id,'body',body,'created_at',created_at,'author',?2,'like_count',0))`
	// Inserts only if the post exists: 0 changes means "already liked" or "no such post".
	sqlLike = `INSERT INTO likes (user_id, post_id) SELECT ?1, ?2 WHERE EXISTS (SELECT 1 FROM posts WHERE id = ?2) ` +
		`ON CONFLICT (user_id, post_id) DO NOTHING`
	sqlExists = `SELECT 1 FROM posts WHERE id = ?1`
	sqlPing   = `SELECT 1`
)

var pragmas = []string{
	"PRAGMA journal_mode=WAL",
	"PRAGMA synchronous=NORMAL",
	"PRAGMA mmap_size=1073741824",
	"PRAGMA cache_size=-2048",
	"PRAGMA wal_autocheckpoint=0",
}

const (
	maxBatch   = 256  // requests drained per loop pass; writes among them share one transaction
	ckptFrames = 1000 // WAL frames (4 KiB pages) before an inline TRUNCATE checkpoint
	outCap     = 16 << 10
)

type reqKind uint8

const (
	reqFeed reqKind = iota
	reqPost
	reqCreate
	reqLike
	reqPing
)

// dbReq is one unit of work for the DB goroutine. Handlers fill it, send it, wait on done, then
// read status/out. Buffers are owned by the handler and reused through a pool.
type dbReq struct {
	kind   reqKind
	id     int64  // post id
	user   int64  // user id from the token
	body   []byte // create: trimmed post body
	name   []byte // create: token username
	out    []byte // response body is appended here
	status int    // 200/201/404/500; 0 means "not handled"
	done   chan struct{}
}

type stmt = *C.sqlite3_stmt

type db struct {
	conn                                   *C.sqlite3
	feed, post, create, like, exists, ping stmt
	begin, commit, rollback                stmt
	ch                                     chan *dbReq
	writes                                 []*dbReq
}

var errDB = errors.New("sqlite error")

func openDB(path string) (*db, error) {
	if rc := C.sqlite3_initialize(); rc != C.SQLITE_OK {
		return nil, fmt.Errorf("sqlite3_initialize: %d", rc)
	}
	cpath := C.CString(path)
	defer C.free(unsafe.Pointer(cpath))
	d := &db{ch: make(chan *dbReq, 4096), writes: make([]*dbReq, 0, maxBatch)}
	if rc := C.sqlite3_open_v2(cpath, &d.conn, C.SQLITE_OPEN_READWRITE, nil); rc != C.SQLITE_OK {
		return nil, fmt.Errorf("open %s: %s", path, C.GoString(C.sqlite3_errstr(rc)))
	}
	for _, p := range pragmas {
		if err := d.exec(p); err != nil {
			return nil, err
		}
	}
	for _, p := range []struct {
		dst *stmt
		sql string
	}{
		{&d.feed, sqlFeed}, {&d.post, sqlPost}, {&d.create, sqlCreate}, {&d.like, sqlLike},
		{&d.exists, sqlExists}, {&d.ping, sqlPing},
		{&d.begin, "BEGIN IMMEDIATE"}, {&d.commit, "COMMIT"}, {&d.rollback, "ROLLBACK"},
	} {
		s, err := d.prepare(p.sql)
		if err != nil {
			return nil, err
		}
		*p.dst = s
	}
	C.shim_install_wal_hook(d.conn)
	go d.loop()
	return d, nil
}

func (d *db) errmsg() string { return C.GoString(C.sqlite3_errmsg(d.conn)) }

func (d *db) exec(sql string) error {
	c := C.CString(sql)
	defer C.free(unsafe.Pointer(c))
	if rc := C.sqlite3_exec(d.conn, c, nil, nil, nil); rc != C.SQLITE_OK {
		return fmt.Errorf("%s: %s", sql, d.errmsg())
	}
	return nil
}

func (d *db) prepare(sql string) (stmt, error) {
	c := C.CString(sql)
	defer C.free(unsafe.Pointer(c))
	var s stmt
	if rc := C.sqlite3_prepare_v3(d.conn, c, -1, C.SQLITE_PREPARE_PERSISTENT, &s, nil); rc != C.SQLITE_OK {
		return nil, fmt.Errorf("prepare %q: %s", sql, d.errmsg())
	}
	return s, nil
}

func cptr(b []byte) *C.char {
	if len(b) == 0 {
		return nil
	}
	return (*C.char)(unsafe.Pointer(unsafe.SliceData(b)))
}

// query runs s and appends its single text column to out. rows is 0 when nothing matched.
func (d *db) query(s stmt, i1, i2 int64, t1, t2 []byte, out []byte) (_ []byte, rows int, err error) {
	n1, n2 := -1, -1
	if t1 != nil {
		n1 = len(t1)
	}
	if t2 != nil {
		n2 = len(t2)
	}
	for {
		room := cap(out) - len(out)
		n := int(C.shim_query(s, C.sqlite3_int64(i1), C.sqlite3_int64(i2), cptr(t1), C.int(n1), cptr(t2), C.int(n2),
			(*C.uchar)(unsafe.Pointer(unsafe.SliceData(out[len(out):cap(out)]))), C.int(room)))
		switch {
		case n < 0:
			return out, 0, fmt.Errorf("%w: %s", errDB, d.errmsg())
		case n == 0:
			return out, 0, nil
		case n <= room:
			return out[:len(out)+n], 1, nil
		}
		out = grow(out, n)[:len(out)]
	}
}

func (d *db) step(s stmt) error {
	rc := C.sqlite3_step(s)
	C.sqlite3_reset(s)
	if rc != C.SQLITE_DONE {
		return fmt.Errorf("%w: %s", errDB, d.errmsg())
	}
	return nil
}

// loop is the only goroutine that touches SQLite (SQLITE_THREADSAFE=0). Each pass drains the queue,
// answers reads at once and commits every queued write in one transaction (group commit) before
// releasing those requests, so a 201 always means the row is on disk per synchronous=NORMAL.
func (d *db) loop() {
	for {
		r := <-d.ch
		d.writes = d.writes[:0]
		for n := 0; ; {
			if r.kind == reqCreate || r.kind == reqLike {
				d.writes = append(d.writes, r)
			} else {
				d.read(r)
				r.done <- struct{}{}
			}
			n++
			if n >= maxBatch {
				break
			}
			select {
			case r = <-d.ch:
			default:
				n = maxBatch
			}
			if n >= maxBatch {
				break
			}
		}
		if len(d.writes) > 0 {
			d.commitBatch()
		}
		if len(d.ch) == 0 && int(C.shim_wal_frames()) > ckptFrames {
			C.shim_checkpoint(d.conn)
		}
	}
}

func (d *db) read(r *dbReq) {
	var (
		rows int
		err  error
	)
	switch r.kind {
	case reqFeed:
		r.out, rows, err = d.query(d.feed, 0, -1, nil, nil, r.out)
	case reqPost:
		r.out, rows, err = d.query(d.post, r.id, -1, nil, nil, r.out)
	case reqPing:
		r.out, rows, err = d.query(d.ping, 0, -1, nil, nil, r.out[:0])
		r.out = r.out[:0]
	}
	switch {
	case err != nil:
		r.status = 500
	case rows == 0:
		r.status = 404
	default:
		r.status = 200
	}
}

func (d *db) commitBatch() {
	if err := d.step(d.begin); err != nil {
		d.failWrites()
		return
	}
	for _, r := range d.writes {
		d.write(r)
	}
	if err := d.step(d.commit); err != nil {
		d.step(d.rollback)
		d.failWrites()
		return
	}
	for _, r := range d.writes {
		r.done <- struct{}{}
	}
}

func (d *db) failWrites() {
	for _, r := range d.writes {
		r.status, r.out = 500, r.out[:0]
		r.done <- struct{}{}
	}
}

func (d *db) write(r *dbReq) {
	switch r.kind {
	case reqCreate:
		out, rows, err := d.query(d.create, r.user, -1, r.name, r.body, r.out)
		r.out = out
		switch {
		case err != nil || rows == 0:
			r.status = 500
		default:
			r.status = 201
		}
	case reqLike:
		n := int(C.shim_exec(d.like, C.sqlite3_int64(r.user), C.sqlite3_int64(r.id)))
		switch {
		case n < 0:
			r.status = 500
			return
		case n == 1:
			r.status = 201
		default:
			_, rows, err := d.query(d.exists, r.id, -1, nil, nil, r.out[:0])
			switch {
			case err != nil:
				r.status = 500
				return
			case rows == 0:
				r.status = 404
				return
			}
			r.status = 200
		}
		r.out = append(r.out, `{"liked":true,"already_liked":`...)
		r.out = strconv.AppendBool(r.out, r.status == 200)
		r.out = append(r.out, `,"post_id":`...)
		r.out = strconv.AppendInt(r.out, r.id, 10)
		r.out = append(r.out, '}')
	}
}
