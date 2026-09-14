// Identities of store files for jig's manifest validation ("C:" + first 128 bits of BLAKE3, hex,
// the form jig computes itself). A cache hit re-validates ~100 headers. Hashing them in every
// compiler process cost 4 ms per hit. Store files are immutable once their build is done, so the
// daemon memoises by path, guarded by (inode, size, mtime) for paths that get garbage-collected
// and rebuilt. jig only asks for paths under the store and outside its own $out. The daemon
// answers for nothing else, since any sandboxed build can talk to the socket.
package main

import (
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
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
	store, realStore string // with trailing slash, as given and with symlinks resolved
	mu               sync.RWMutex
	known            map[string]identEntry
}

func NewIdentities(storeDir string) *Identities {
	real, err := filepath.EvalSymlinks(storeDir)
	if err != nil {
		real = storeDir
	}
	return &Identities{store: filepath.Clean(storeDir) + "/", realStore: filepath.Clean(real) + "/", known: make(map[string]identEntry)}
}

func stampOf(info os.FileInfo) fileStamp {
	st := info.Sys().(*syscall.Stat_t)
	return fileStamp{ino: st.Ino, size: info.Size(), mtime: info.ModTime().UnixNano()}
}

// Of returns the identity of a regular file under the store, "" otherwise.
func (ids *Identities) Of(path string) string {
	if !strings.HasPrefix(path, ids.store) || filepath.Clean(path) != path {
		return ""
	}
	// store trees hold symlinks, also ones a hostile build pointed out of the store
	real, err := filepath.EvalSymlinks(path)
	if err != nil || !strings.HasPrefix(real, ids.realStore) {
		return ""
	}
	info, err := os.Stat(real)
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
	data, err := os.ReadFile(real)
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
