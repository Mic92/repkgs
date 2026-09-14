package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func read(t *testing.T, s *Store, key string) []byte {
	t.Helper()
	r := s.Get(key)
	if r == nil {
		return nil
	}
	b, err := io.ReadAll(r)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestPutGetReopen(t *testing.T) {
	dir := t.TempDir()
	s, err := OpenStore([]Tier{{Dir: dir, Budget: 0}})
	if err != nil {
		t.Fatal(err)
	}
	s.Put("o/aa", []byte("one"))
	s.Put("o/bb", []byte("two"))
	s.Put("o/aa", []byte("three")) // overwrite: newest wins
	if got := read(t, s, "o/aa"); string(got) != "three" {
		t.Fatalf("got %q", got)
	}
	if read(t, s, "o/zz") != nil {
		t.Fatal("expected miss")
	}
	// crash without Close: next open scans the unsealed pack
	s2, err := OpenStore([]Tier{{Dir: dir, Budget: 0}})
	if err != nil {
		t.Fatal(err)
	}
	if got := read(t, s2, "o/aa"); string(got) != "three" {
		t.Fatalf("after scan: %q", got)
	}
	s2.Close()
	// and after a clean close it loads from hints
	s3, err := OpenStore([]Tier{{Dir: dir, Budget: 0}})
	if err != nil {
		t.Fatal(err)
	}
	if got := read(t, s3, "o/bb"); string(got) != "two" {
		t.Fatalf("after hints: %q", got)
	}
}

func TestTornTail(t *testing.T) {
	dir := t.TempDir()
	s, _ := OpenStore([]Tier{{Dir: dir, Budget: 0}})
	s.Put("k", []byte("value"))
	name := s.active.file.Name()
	// half a record appended
	f, _ := os.OpenFile(name, os.O_WRONLY|os.O_APPEND, 0)
	f.Write([]byte{9, 0, 0, 0, 200, 0, 0, 0, 'x'})
	f.Close()
	s2, err := OpenStore([]Tier{{Dir: dir, Budget: 0}})
	if err != nil {
		t.Fatal(err)
	}
	if got := read(t, s2, "k"); string(got) != "value" {
		t.Fatalf("got %q", got)
	}
	info, _ := os.Stat(name)
	if info.Size() != int64(recHeader+1+5) {
		t.Fatalf("not truncated: %d", info.Size())
	}
}

func TestEvictKeepsReadPack(t *testing.T) {
	dir := t.TempDir()
	s, _ := OpenStore([]Tier{{Dir: dir, Budget: 2*packLimit + packLimit/2}})
	big := bytes.Repeat([]byte{1}, 1<<20)
	per := packLimit / len(big)
	// two full packs, pack 1 read from, then a third: pack 2 goes, not pack 1
	for i := 0; i < 2*per; i++ {
		s.Put(fmt.Sprintf("o/%d", i), big)
	}
	read(t, s, "o/0")
	for i := 2 * per; i < 7*per/2; i++ {
		s.Put(fmt.Sprintf("o/%d", i), big)
	}
	s.Wait()
	if read(t, s, "o/0") == nil {
		t.Fatal("pack 1 was read last and got evicted")
	}
	if read(t, s, fmt.Sprintf("o/%d", per+1)) != nil {
		t.Fatal("pack 2 was never read and survived")
	}
}

// recency is the pack's mtime: a pack read before a restart outlives one that was not
func TestEvictRecencySurvivesRestart(t *testing.T) {
	dir := t.TempDir()
	s, _ := OpenStore([]Tier{{Dir: dir, Budget: 0}})
	big := bytes.Repeat([]byte{1}, 1<<20)
	per := packLimit / len(big)
	for i := 0; i < 2*per; i++ {
		s.Put(fmt.Sprintf("o/%d", i), big)
	}
	s.now = func() time.Time { return time.Now().Add(time.Hour) }
	read(t, s, "o/0") // pack 1 read later than pack 2 was written, pack 2 never read
	s.Close()

	s2, _ := OpenStore([]Tier{{Dir: dir, Budget: 2*packLimit + packLimit/2}})
	if p1, p2 := s2.packs[1].used.Load(), s2.packs[2].used.Load(); p1 <= p2 {
		t.Fatalf("after restart pack 1 used=%v not newer than pack 2 used=%v", time.Unix(0, p1), time.Unix(0, p2))
	}
	for i := 2 * per; i < 7*per/2; i++ {
		s2.Put(fmt.Sprintf("o/%d", i), big)
	}
	s2.Wait()
	if read(t, s2, "o/0") == nil {
		t.Fatal("pack 1 was read before the restart and got evicted")
	}
	if read(t, s2, fmt.Sprintf("o/%d", per+1)) != nil {
		t.Fatal("pack 2 was never read and survived")
	}
}

// a pack whose entries were mostly overwritten goes before a fully live one, however recent
func TestEvictSupersededFirst(t *testing.T) {
	dir := t.TempDir()
	s, _ := OpenStore([]Tier{{Dir: dir, Budget: 2*packLimit + packLimit/2}})
	big := bytes.Repeat([]byte{1}, 1<<20)
	per := packLimit / len(big)
	for i := 0; i < per; i++ { // pack 1: o/0..per
		s.Put(fmt.Sprintf("o/%d", i), big)
	}
	for i := 0; i < per; i++ { // pack 2: the same keys again, pack 1 is now dead weight
		s.Put(fmt.Sprintf("o/%d", i), big)
	}
	read(t, s, "o/0") // served from pack 2; pack 1 gets no reads but make it "recent" anyway
	s.packs[1].used.Store(time.Now().Add(time.Hour).UnixNano())
	for i := per; i < 5*per/2; i++ { // pack 3 and a half: over budget
		s.Put(fmt.Sprintf("o/%d", i), big)
	}
	s.Wait()
	if _, err := os.Stat(filepath.Join(dir, "000001.pack")); !os.IsNotExist(err) {
		t.Fatal("superseded pack 1 still on disk")
	}
	if read(t, s, "o/0") == nil {
		t.Fatal("live pack 2 evicted instead of dead pack 1")
	}
}

// over the fast budget a pack moves to the cold dir and is still served, over the cold budget it
// is gone. A restart finds cold packs
func TestTiers(t *testing.T) {
	hot, cold := t.TempDir(), t.TempDir()
	// room for the active pack plus one sealed pack in each tier
	tiers := []Tier{{Dir: hot, Budget: 2 * packLimit}, {Dir: cold, Budget: packLimit + packLimit/2}}
	s, _ := OpenStore(tiers)
	big := bytes.Repeat([]byte{1}, 1<<20)
	per := packLimit / len(big)
	puts := func(from, to int) {
		for i := from; i < to; i++ {
			s.Put(fmt.Sprintf("o/%d", i), big)
		}
		s.Wait()
	}
	puts(0, 5*per/2) // packs 1, 2 sealed, 3 half: 1 goes cold
	if _, err := os.Stat(filepath.Join(cold, "000001.pack")); err != nil {
		t.Fatal("pack 1 not demoted: ", err)
	}
	if _, err := os.Stat(filepath.Join(hot, "000001.pack")); !os.IsNotExist(err) {
		t.Fatal("pack 1 still hot")
	}
	if read(t, s, "o/0") == nil {
		t.Fatal("o/0 not served from the cold tier")
	}
	puts(5*per/2, 7*per/2) // 3 sealed, 4 half: 2 goes cold, cold over budget, 2 was read less recently than 1
	if read(t, s, fmt.Sprintf("o/%d", per+1)) != nil {
		t.Fatal("pack 2 survived the cold budget")
	}
	if read(t, s, "o/0") == nil {
		t.Fatal("pack 1 (read) dropped instead of pack 2")
	}
	s.Close()
	s2, err := OpenStore([]Tier{{Dir: hot}, {Dir: cold}})
	if err != nil {
		t.Fatal(err)
	}
	if read(t, s2, "o/0") == nil || s2.packs[1].tier != 1 {
		t.Fatal("cold pack 1 not found after restart")
	}
}

// a reader handed out by Get keeps working while its pack is evicted underneath it
func TestGetSurvivesEviction(t *testing.T) {
	dir := t.TempDir()
	s, _ := OpenStore([]Tier{{Dir: dir, Budget: packLimit + packLimit/2}})
	big := bytes.Repeat([]byte{1}, 1<<20)
	per := packLimit / len(big)
	for i := 0; i < per; i++ {
		s.Put(fmt.Sprintf("o/%d", i), big)
	}
	r := s.Get("o/0") // pack 1, about to be evicted
	for i := per; i < 5*per/2; i++ {
		s.Put(fmt.Sprintf("o/%d", i), big)
	}
	s.Wait()
	if _, err := os.Stat(filepath.Join(dir, "000001.pack")); !os.IsNotExist(err) {
		t.Fatal("pack 1 still on disk")
	}
	got, err := io.ReadAll(r)
	if err != nil || !bytes.Equal(got, big) {
		t.Fatalf("in-flight read broke: %v, %d bytes", err, len(got))
	}
}

// a Put racing with Close (connections outlive the listener) must not panic
func TestPutAfterClose(t *testing.T) {
	dir := t.TempDir()
	s, _ := OpenStore([]Tier{{Dir: dir, Budget: 1}})
	s.Put("k", []byte("v"))
	s.Close()
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("panic: %v", r)
		}
	}()
	s.Put("k2", []byte("v"))
}

func TestEvictOldestPack(t *testing.T) {
	dir := t.TempDir()
	s, _ := OpenStore([]Tier{{Dir: dir, Budget: packLimit + packLimit/2}})
	big := bytes.Repeat([]byte{1}, 1<<20)
	// ~2.5 packs worth: the first pack must go
	for i := 0; i < packLimit*5/2/len(big); i++ {
		if err := s.Put(fmt.Sprintf("o/%d", i), big); err != nil {
			t.Fatal(err)
		}
	}
	s.Wait()
	if read(t, s, "o/0") != nil {
		t.Fatal("o/0 should have been evicted with pack 1")
	}
	last := fmt.Sprintf("o/%d", packLimit*5/2/len(big)-1)
	if read(t, s, last) == nil {
		t.Fatal("newest entry missing")
	}
	if _, err := os.Stat(filepath.Join(dir, "000001.pack")); !os.IsNotExist(err) {
		t.Fatal("pack 1 still on disk")
	}
}
