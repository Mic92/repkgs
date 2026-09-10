package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"testing"
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
	s, err := OpenStore(dir, 0)
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
	s2, err := OpenStore(dir, 0)
	if err != nil {
		t.Fatal(err)
	}
	if got := read(t, s2, "o/aa"); string(got) != "three" {
		t.Fatalf("after scan: %q", got)
	}
	s2.Close()
	// and after a clean close it loads from hints
	s3, err := OpenStore(dir, 0)
	if err != nil {
		t.Fatal(err)
	}
	if got := read(t, s3, "o/bb"); string(got) != "two" {
		t.Fatalf("after hints: %q", got)
	}
}

func TestTornTail(t *testing.T) {
	dir := t.TempDir()
	s, _ := OpenStore(dir, 0)
	s.Put("k", []byte("value"))
	name := s.active.file.Name()
	// half a record appended
	f, _ := os.OpenFile(name, os.O_WRONLY|os.O_APPEND, 0)
	f.Write([]byte{9, 0, 0, 0, 200, 0, 0, 0, 'x'})
	f.Close()
	s2, err := OpenStore(dir, 0)
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
	s, _ := OpenStore(dir, 2*packLimit+packLimit/2)
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
	if read(t, s, "o/0") == nil {
		t.Fatal("pack 1 was read last and got evicted")
	}
	if read(t, s, fmt.Sprintf("o/%d", per+1)) != nil {
		t.Fatal("pack 2 was never read and survived")
	}
}

func TestEvictOldestPack(t *testing.T) {
	dir := t.TempDir()
	s, _ := OpenStore(dir, packLimit+packLimit/2)
	big := bytes.Repeat([]byte{1}, 1<<20)
	// ~2.5 packs worth: the first pack must go
	for i := 0; i < packLimit*5/2/len(big); i++ {
		if err := s.Put(fmt.Sprintf("o/%d", i), big); err != nil {
			t.Fatal(err)
		}
	}
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
