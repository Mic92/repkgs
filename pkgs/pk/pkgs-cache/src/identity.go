// Identities of store files for jig's manifest validation ("C:" + first 128 bits of BLAKE3, hex,
// the form jig computes itself). A cache hit re-validates ~100 headers. Hashing them in every
// compiler process cost 4 ms per hit. Store files are immutable once their build is done, so the
// daemon memoises by path, guarded by (inode, size, mtime) for paths that get garbage-collected
// and rebuilt. jig only asks for paths under the store and outside its own $out.
package main

import (
	"encoding/hex"
	"os"
	"sync"
	"syscall"

	"lukechampine.com/blake3"
)

type fileStamp struct {
	ino   uint64
	size  int64
	mtime int64
}

type identEntry struct {
	stamp fileStamp
	id    string
}

type Identities struct {
	mu    sync.RWMutex
	known map[string]identEntry
}

func NewIdentities() *Identities { return &Identities{known: make(map[string]identEntry)} }

func stampOf(info os.FileInfo) fileStamp {
	st := info.Sys().(*syscall.Stat_t)
	return fileStamp{ino: st.Ino, size: info.Size(), mtime: info.ModTime().UnixNano()}
}

// Of returns the identity of a regular file, "" if it cannot be read.
func (ids *Identities) Of(path string) string {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return ""
	}
	stamp := stampOf(info)
	ids.mu.RLock()
	entry, ok := ids.known[path]
	ids.mu.RUnlock()
	if ok && entry.stamp == stamp {
		return entry.id
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	sum := blake3.Sum256(data)
	id := "C:" + hex.EncodeToString(sum[:16])
	ids.mu.Lock()
	ids.known[path] = identEntry{stamp: stamp, id: id}
	ids.mu.Unlock()
	return id
}

func (ids *Identities) Len() int {
	ids.mu.RLock()
	defer ids.mu.RUnlock()
	return len(ids.known)
}
