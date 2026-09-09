package main

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// IDS answers one line per path in order, and pipelined GETs are answered in order on one stream
func TestServeIdsAndPipelinedGets(t *testing.T) {
	dir := t.TempDir()
	var err error
	store, err = OpenStore(filepath.Join(dir, "packs"), 1<<30)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	slots = NewSlots(1)
	header := filepath.Join(dir, "h.h")
	if err := os.WriteFile(header, []byte("abc"), 0o644); err != nil {
		t.Fatal(err)
	}
	sock := filepath.Join(dir, "s")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: sock, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		for {
			conn, err := listener.AcceptUnix()
			if err != nil {
				return
			}
			go serve(conn)
		}
	}()
	conn, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	in := bufio.NewReader(conn)
	fmt.Fprintf(conn, "PUT k1 3\nabcIDS 2\n%s\n%s/missing\nGET nope\nGET k1\n", header, dir)
	var got []string
	for i := 0; i < 5; i++ {
		line, err := in.ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		got = append(got, strings.TrimSuffix(line, "\n"))
		if line == "OK 3\n" {
			val := make([]byte, 3)
			if _, err := in.Read(val); err != nil || string(val) != "abc" {
				t.Fatalf("value %q %v", val, err)
			}
		}
	}
	want := []string{"OK", "C:6437b3ac38465133ffb63b75273a8db5", "", "MISS", "OK 3"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("got %q want %q", got, want)
	}

	// the one slot: taken, returned with DONE, taken again, then freed by hanging up
	fmt.Fprintf(conn, "SLOT b1\nDONE b1\nSLOT b1\n")
	for i := 0; i < 3; i++ {
		if line, _ := in.ReadString('\n'); line != "OK\n" {
			t.Fatalf("slot reply %q", line)
		}
	}
	if out, _ := slots.Stats(); out != 1 {
		t.Fatalf("slots out %d", out)
	}
	conn.Close()
	other, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	fmt.Fprintf(other, "SLOT b2\n")
	if line, _ := bufio.NewReader(other).ReadString('\n'); line != "OK\n" {
		t.Fatalf("slot after hang-up: %q", line)
	}
}
