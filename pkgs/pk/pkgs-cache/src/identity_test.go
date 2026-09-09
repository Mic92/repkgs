package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestIdentityMatchesJigAndTracksRewrites(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "h.h")
	if err := os.WriteFile(path, []byte("abc"), 0o644); err != nil {
		t.Fatal(err)
	}
	ids := NewIdentities()
	// jig: "C:" + Digest(HashOf("abc")).hex(), BLAKE3 truncated to 128 bits
	const want = "C:6437b3ac38465133ffb63b75273a8db5"
	if got := ids.Of(path); got != want {
		t.Fatalf("got %q want %q", got, want)
	}
	if got := ids.Of(path); got != want || ids.Len() != 1 {
		t.Fatalf("memoised lookup: %q, %d entries", got, ids.Len())
	}
	if err := os.WriteFile(path, []byte("abcd"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := ids.Of(path); got == want || got == "" {
		t.Fatalf("rewrite not noticed: %q", got)
	}
	if ids.Of(filepath.Join(dir, "missing")) != "" || ids.Of(dir) != "" {
		t.Fatal("unreadable paths must yield empty identities")
	}
}
