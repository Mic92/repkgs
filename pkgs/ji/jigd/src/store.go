// Bitcask-style blob store: values are appended to the active pack file, an in-memory map says
// where each key lives, sealed packs get a hint file so startup does not scan data. Packs live in
// tiers (a fast local dir, then optionally a big slow one), each with a byte budget: a tier over
// budget demotes whole packs to the next, mostly superseded ones first, then least recently read,
// and the last tier deletes. A pack's mtime is its last read so recency survives restarts.
// Nothing is fsynced: this is a cache, a torn tail is truncated on load.
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
	"sync/atomic"
	"time"
)

// a Get moves its pack's mtime at most this often
const touchEvery = time.Minute

const (
	packLimit = 256 << 20 // seal the active pack at this size
	recHeader = 8
)

type loc struct {
	pack uint32
	off  uint32 // of the value, not the record
	len  uint32
}

// Tier is a directory of packs with a byte budget (0 = unbounded)
type Tier struct {
	Dir    string
	Budget int64
	total  int64
}

// Pack files are never Closed explicitly: readers from Get may outlive eviction, the
// finalizer closes the fd. Packs are few and large.
type pack struct {
	id      uint32
	tier    int // index into Store.tiers
	file    *os.File
	size    int64
	live    int64        // bytes of values the index still points at
	used    atomic.Int64 // unix nanos of the last Get served from this pack
	touched atomic.Int64 // what the file's mtime says, moved at most every touchEvery
}

type Store struct {
	tiers []Tier // tiers[0] takes the writes
	now   func() time.Time

	mu     sync.RWMutex
	index  map[string]loc
	packs  map[uint32]*pack
	active *pack
	demote chan struct{} // a tier went over budget
	done   chan struct{}
}

func packName(dir string, id uint32, ext string) string {
	return filepath.Join(dir, fmt.Sprintf("%06d.%s", id, ext))
}

func (s *Store) name(p *pack, ext string) string { return packName(s.tiers[p.tier].Dir, p.id, ext) }

func OpenStore(tiers []Tier) (*Store, error) {
	s := &Store{tiers: tiers, now: time.Now, index: make(map[string]loc), packs: make(map[uint32]*pack),
		demote: make(chan struct{}, 1), done: make(chan struct{})}
	var last uint32
	// fast tier first: a pack in both (stopped mid-demotion) keeps the fast copy
	for t := range tiers {
		if err := os.MkdirAll(tiers[t].Dir, 0o755); err != nil {
			return nil, err
		}
		names, err := filepath.Glob(filepath.Join(tiers[t].Dir, "*.pack"))
		if err != nil {
			return nil, err
		}
		sort.Strings(names)
		for _, name := range names {
			var id uint32
			if _, err := fmt.Sscanf(filepath.Base(name), "%06d.pack", &id); err != nil {
				continue
			}
			if _, dup := s.packs[id]; dup {
				os.Remove(name)
				os.Remove(packName(tiers[t].Dir, id, "hint"))
				continue
			}
			if err := s.load(t, id); err != nil {
				log.Printf("pack %06d: %v (skipped)", id, err)
				continue
			}
			last = max(last, id)
		}
	}
	if err := s.rotate(last + 1); err != nil {
		return nil, err
	}
	go s.demoter()
	return s, nil
}

// load one pack into the index: from its hint file if sealed, else by scanning records
func (s *Store) load(tier int, id uint32) error {
	file, err := os.OpenFile(packName(s.tiers[tier].Dir, id, "pack"), os.O_RDWR, 0)
	if err != nil {
		return err
	}
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return err
	}
	p := &pack{id: id, tier: tier, file: file, size: info.Size()}
	p.used.Store(info.ModTime().UnixNano())
	p.touched.Store(info.ModTime().UnixNano())
	add := func(key string, l loc) {
		if old, ok := s.index[key]; ok {
			s.packs[old.pack].live -= int64(old.len)
		}
		s.index[key] = l
		p.live += int64(l.len)
	}
	s.packs[id] = p
	if hint, err := os.Open(s.name(p, "hint")); err == nil {
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
		s.tiers[tier].total += p.size
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
	s.tiers[tier].total += p.size
	return s.seal(p)
}

// seal writes the hint file for a pack that will not grow any more
func (s *Store) seal(p *pack) error {
	tmp := s.name(p, "hint.tmp")
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
	return os.Rename(tmp, s.name(p, "hint"))
}

func (s *Store) rotate(id uint32) error {
	if s.active != nil {
		if err := s.seal(s.active); err != nil {
			return err
		}
	}
	file, err := os.OpenFile(packName(s.tiers[0].Dir, id, "pack"), os.O_RDWR|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	s.active = &pack{id: id, file: file}
	s.active.used.Store(s.now().UnixNano()) // being written counts as recent
	s.active.touched.Store(s.now().UnixNano())
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
	p := s.packs[l.pack]
	now := s.now()
	p.used.Store(now.UnixNano())
	if last := p.touched.Load(); now.UnixNano()-last > int64(touchEvery) && p.touched.CompareAndSwap(last, now.UnixNano()) {
		os.Chtimes(s.name(p, "pack"), time.Time{}, now)
	}
	return io.NewSectionReader(p.file, int64(l.off), int64(l.len))
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
	s.tiers[0].total += int64(len(rec))
	if t := s.tiers[0]; t.Budget > 0 && t.total > t.Budget {
		s.kick()
	}
	return nil
}

func (s *Store) kick() {
	select {
	case s.demote <- struct{}{}:
	default:
	}
}

// demoter moves packs down a tier while one is over budget. The copy to a slow tier runs
// without the lock, reads keep being served from the old file until the switch
func (s *Store) demoter() {
	defer close(s.done)
	for range s.demote {
		for {
			s.mu.Lock()
			p, ok := s.victim()
			s.mu.Unlock()
			if !ok {
				break
			}
			if err := s.moveDown(p); err != nil {
				log.Printf("pack %06d: %v", p.id, err)
				break
			}
		}
	}
}

// victim picks the pack to leave the first tier that is over budget: mostly superseded ones
// first (their space is free without losing much), then the one longest without a read, so a
// full tier forgets what no build asks for, not the toolchain objects every build replays.
// Called with mu held
func (s *Store) victim() (*pack, bool) {
	for t := range s.tiers {
		if s.tiers[t].Budget <= 0 || s.tiers[t].total <= s.tiers[t].Budget {
			continue
		}
		var out []*pack
		for _, p := range s.packs {
			if p.tier == t && p != s.active {
				out = append(out, p)
			}
		}
		if len(out) == 0 {
			continue
		}
		stale := func(p *pack) bool { return p.live*2 < p.size }
		sort.Slice(out, func(i, j int) bool {
			if stale(out[i]) != stale(out[j]) {
				return stale(out[i])
			}
			ui, uj := out[i].used.Load(), out[j].used.Load()
			return ui < uj || (ui == uj && out[i].id < out[j].id)
		})
		return out[0], true
	}
	return nil, false
}

// moveDown demotes p to the next tier, or deletes it from the last
func (s *Store) moveDown(p *pack) error {
	from := p.tier
	if from+1 == len(s.tiers) {
		s.mu.Lock()
		defer s.mu.Unlock()
		for key, l := range s.index {
			if l.pack == p.id {
				delete(s.index, key)
			}
		}
		os.Remove(s.name(p, "pack"))
		os.Remove(s.name(p, "hint"))
		delete(s.packs, p.id)
		s.tiers[from].total -= p.size
		log.Printf("evicted pack %06d (%d MiB, %d MiB live)", p.id, p.size>>20, p.live>>20)
		return nil
	}
	to := s.tiers[from+1].Dir
	for _, ext := range []string{"pack", "hint"} {
		if err := moveFile(packName(s.tiers[from].Dir, p.id, ext), packName(to, p.id, ext)); err != nil {
			return err
		}
	}
	file, err := os.OpenFile(packName(to, p.id, "pack"), os.O_RDWR, 0)
	if err != nil {
		return err
	}
	os.Chtimes(file.Name(), time.Time{}, time.Unix(0, p.used.Load()))
	s.mu.Lock()
	defer s.mu.Unlock()
	p.file = file
	p.tier = from + 1
	s.tiers[from].total -= p.size
	s.tiers[from+1].total += p.size
	os.Remove(packName(s.tiers[from].Dir, p.id, "pack"))
	os.Remove(packName(s.tiers[from].Dir, p.id, "hint"))
	log.Printf("demoted pack %06d to %s (%d MiB, %d MiB live)", p.id, to, p.size>>20, p.live>>20)
	return nil
}

// rename, or copy across filesystems (the source stays until the caller removes it)
func moveFile(from, to string) error {
	if err := os.Link(from, to); err == nil || os.IsExist(err) {
		return nil
	}
	src, err := os.Open(from)
	if err != nil {
		return err
	}
	defer src.Close()
	tmp := to + ".tmp"
	dst, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if _, err := io.Copy(dst, src); err != nil {
		dst.Close()
		os.Remove(tmp)
		return err
	}
	if err := dst.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, to)
}

func (s *Store) Stats() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var live, total int64
	for _, p := range s.packs {
		live += p.live
	}
	for _, t := range s.tiers {
		total += t.total
	}
	return fmt.Sprintf("keys=%d packs=%d bytes=%d live=%d", len(s.index), len(s.packs), total, live)
}

// Wait blocks until no tier is over budget (tests)
func (s *Store) Wait() {
	for {
		s.mu.Lock()
		_, busy := s.victim()
		s.mu.Unlock()
		if !busy {
			return
		}
		time.Sleep(time.Millisecond)
	}
}

// Close seals the active pack so the next start reads hints only
func (s *Store) Close() error {
	close(s.demote)
	<-s.done
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.seal(s.active)
}
