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
	ids := NewIdentities(dir)
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

// the socket is open to every sandboxed build: IDS must not be a read oracle for the host
func TestIdentityOnlyUnderStore(t *testing.T) {
	store, home := t.TempDir(), t.TempDir()
	secret := filepath.Join(home, "id_ed25519")
	os.WriteFile(secret, []byte("key"), 0o600)
	os.WriteFile(filepath.Join(store, "h.h"), []byte("abc"), 0o644)
	// a build's output may hold symlinks pointing anywhere
	os.Symlink(secret, filepath.Join(store, "link"))
	os.Symlink(home, filepath.Join(store, "dir"))
	os.Symlink(filepath.Join(store, "h.h"), filepath.Join(store, "inside"))
	ids := NewIdentities(store)
	for _, p := range []string{secret, store + "/../" + filepath.Base(home) + "/id_ed25519", store + "x/h.h", store,
		filepath.Join(store, "link"), filepath.Join(store, "dir", "id_ed25519")} {
		if got := ids.Of(p); got != "" {
			t.Errorf("%s: leaked %q", p, got)
		}
	}
	if ids.Of(filepath.Join(store, "h.h")) == "" || ids.Of(filepath.Join(store, "inside")) == "" {
		t.Fatal("store path not identified")
	}
}
