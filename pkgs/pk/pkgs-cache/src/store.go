// Bitcask-style blob store: values are appended to the active pack file, an in-memory map says
// where each key lives, sealed packs get a hint file so startup does not scan data. Eviction drops
// whole packs, oldest first. Nothing is fsynced: this is a cache, a torn tail is truncated on load.
//
//	packs/000042.pack  records: u32 keylen, u32 vallen, key, value   (little endian)
//	packs/000042.hint  same records without the value, plus u64 offset of the record in .pack
package main

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
)

const (
	packLimit = 256 << 20 // seal the active pack at this size
	recHeader = 8
)

type loc struct {
	pack uint32
	off  uint32 // of the value, not the record
	len  uint32
}

type pack struct {
	id   uint32
	file *os.File
	size int64
	live int64 // bytes of values the index still points at
}

type Store struct {
	dir    string
	budget int64

	mu     sync.RWMutex
	index  map[string]loc
	packs  map[uint32]*pack
	active *pack
	total  int64
}

func packName(dir string, id uint32, ext string) string {
	return filepath.Join(dir, fmt.Sprintf("%06d.%s", id, ext))
}

func OpenStore(dir string, budget int64) (*Store, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	s := &Store{dir: dir, budget: budget, index: make(map[string]loc), packs: make(map[uint32]*pack)}
	names, err := filepath.Glob(filepath.Join(dir, "*.pack"))
	if err != nil {
		return nil, err
	}
	sort.Strings(names)
	var last uint32
	for _, name := range names {
		var id uint32
		if _, err := fmt.Sscanf(filepath.Base(name), "%06d.pack", &id); err != nil {
			continue
		}
		if err := s.load(id); err != nil {
			log.Printf("pack %06d: %v (skipped)", id, err)
			continue
		}
		last = id
	}
	return s, s.rotate(last + 1)
}

// load one pack into the index: from its hint file if sealed, else by scanning records
func (s *Store) load(id uint32) error {
	file, err := os.OpenFile(packName(s.dir, id, "pack"), os.O_RDWR, 0)
	if err != nil {
		return err
	}
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return err
	}
	p := &pack{id: id, file: file, size: info.Size()}
	add := func(key string, l loc) {
		if old, ok := s.index[key]; ok {
			s.packs[old.pack].live -= int64(old.len)
		}
		s.index[key] = l
		p.live += int64(l.len)
	}
	s.packs[id] = p
	if hint, err := os.Open(packName(s.dir, id, "hint")); err == nil {
		defer hint.Close()
		r := bufio.NewReaderSize(hint, 1<<20)
		var hdr [recHeader + 8]byte
		for {
			if _, err := io.ReadFull(r, hdr[:]); err != nil {
				break
			}
			klen, vlen, off := binary.LittleEndian.Uint32(hdr[0:]), binary.LittleEndian.Uint32(hdr[4:]), binary.LittleEndian.Uint64(hdr[8:])
			key := make([]byte, klen)
			if _, err := io.ReadFull(r, key); err != nil {
				break
			}
			add(string(key), loc{id, uint32(off) + recHeader + klen, vlen})
		}
		s.total += p.size
		return nil
	}
	// unsealed (was active when the daemon stopped): scan, truncate a torn tail
	r := bufio.NewReaderSize(file, 1<<20)
	var off int64
	var hdr [recHeader]byte
	for {
		if _, err := io.ReadFull(r, hdr[:]); err != nil {
			break
		}
		klen, vlen := binary.LittleEndian.Uint32(hdr[0:]), binary.LittleEndian.Uint32(hdr[4:])
		key := make([]byte, klen)
		if _, err := io.ReadFull(r, key); err != nil {
			break
		}
		if _, err := r.Discard(int(vlen)); err != nil {
			break
		}
		add(string(key), loc{id, uint32(off) + recHeader + klen, vlen})
		off += recHeader + int64(klen) + int64(vlen)
	}
	if off != p.size {
		log.Printf("pack %06d: truncating torn tail at %d (was %d)", id, off, p.size)
		if err := file.Truncate(off); err != nil {
			return err
		}
		p.size = off
	}
	s.total += p.size
	return s.seal(p)
}

// seal writes the hint file for a pack that will not grow any more
func (s *Store) seal(p *pack) error {
	tmp := packName(s.dir, p.id, "hint.tmp")
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	w := bufio.NewWriterSize(f, 1<<20)
	var hdr [recHeader + 8]byte
	for key, l := range s.index {
		if l.pack != p.id {
			continue
		}
		binary.LittleEndian.PutUint32(hdr[0:], uint32(len(key)))
		binary.LittleEndian.PutUint32(hdr[4:], l.len)
		binary.LittleEndian.PutUint64(hdr[8:], uint64(l.off-recHeader-uint32(len(key))))
		w.Write(hdr[:])
		w.WriteString(key)
	}
	if err := w.Flush(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, packName(s.dir, p.id, "hint"))
}

func (s *Store) rotate(id uint32) error {
	if s.active != nil {
		if err := s.seal(s.active); err != nil {
			return err
		}
	}
	file, err := os.OpenFile(packName(s.dir, id, "pack"), os.O_RDWR|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	s.active = &pack{id: id, file: file}
	s.packs[id] = s.active
	return nil
}

// Get returns a reader positioned at the value (an *io.SectionReader over the pack fd, so
// io.Copy to a socket is sendfile) or nil
func (s *Store) Get(key string) *io.SectionReader {
	s.mu.RLock()
	defer s.mu.RUnlock()
	l, ok := s.index[key]
	if !ok {
		return nil
	}
	return io.NewSectionReader(s.packs[l.pack].file, int64(l.off), int64(l.len))
}

func (s *Store) Put(key string, value []byte) error {
	if len(key) == 0 || len(key) > 4096 || strings.ContainsAny(key, "\n ") {
		return errors.New("bad key")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.active.size+int64(recHeader+len(key)+len(value)) > packLimit && s.active.size > 0 {
		if err := s.rotate(s.active.id + 1); err != nil {
			return err
		}
		s.evict()
	}
	var hdr [recHeader]byte
	binary.LittleEndian.PutUint32(hdr[0:], uint32(len(key)))
	binary.LittleEndian.PutUint32(hdr[4:], uint32(len(value)))
	rec := make([]byte, 0, recHeader+len(key)+len(value))
	rec = append(append(append(rec, hdr[:]...), key...), value...)
	if _, err := s.active.file.WriteAt(rec, s.active.size); err != nil {
		return err
	}
	if old, ok := s.index[key]; ok {
		s.packs[old.pack].live -= int64(old.len)
	}
	s.index[key] = loc{s.active.id, uint32(s.active.size) + recHeader + uint32(len(key)), uint32(len(value))}
	s.active.size += int64(len(rec))
	s.active.live += int64(len(value))
	s.total += int64(len(rec))
	return nil
}

// evict drops whole packs, oldest first, until under budget. Called with mu held.
func (s *Store) evict() {
	if s.budget <= 0 {
		return
	}
	ids := make([]uint32, 0, len(s.packs))
	for id := range s.packs {
		if id != s.active.id {
			ids = append(ids, id)
		}
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	for _, id := range ids {
		if s.total <= s.budget {
			return
		}
		p := s.packs[id]
		for key, l := range s.index {
			if l.pack == id {
				delete(s.index, key)
			}
		}
		// open SectionReaders keep the inode alive until their io.Copy finishes
		p.file.Close()
		os.Remove(packName(s.dir, id, "pack"))
		os.Remove(packName(s.dir, id, "hint"))
		delete(s.packs, id)
		s.total -= p.size
		log.Printf("evicted pack %06d (%d MiB, %d MiB live)", id, p.size>>20, p.live>>20)
	}
}

func (s *Store) Stats() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var live int64
	for _, p := range s.packs {
		live += p.live
	}
	return fmt.Sprintf("keys=%d packs=%d bytes=%d live=%d", len(s.index), len(s.packs), s.total, live)
}

// Close seals the active pack so the next start reads hints only
func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.seal(s.active)
}
