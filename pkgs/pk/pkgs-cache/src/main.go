// Host side of jig's build cache: a pack-file blob store under $XDG_CACHE_HOME/pkgs-cache,
// served on a unix socket that nix.conf's extra-sandbox-paths maps into every build.
//
//	GET key\n             -> OK <len>\n<bytes> | MISS\n
//	PUT key <len>\n<bytes> -> OK\n
//	IDS <n>\n<n paths\n>    -> <n identities\n> ("" for unreadable), see identity.go
//	STATS\n               -> gets=… hits=… puts=… ids=… keys=… packs=… bytes=… live=…\n
//
// PKGS_CACHE_SIZE (GiB, default 50) bounds the store; the oldest packs are dropped beyond it.
package main

import (
	"bufio"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
)

var (
	store            *Store
	idents           = NewIdentities()
	gets, hits, puts atomic.Int64
)

func get(conn *net.UnixConn, out *bufio.Writer, key string) error {
	gets.Add(1)
	val := store.Get(key)
	if val == nil {
		_, err := out.WriteString("MISS\n")
		return err
	}
	hits.Add(1)
	if _, err := fmt.Fprintf(out, "OK %d\n", val.Size()); err != nil {
		return err
	}
	if err := out.Flush(); err != nil {
		return err
	}
	// SectionReader over *os.File -> *net.UnixConn: io.Copy uses sendfile(2)
	_, err := io.Copy(conn, val)
	return err
}

func put(in *bufio.Reader, out *bufio.Writer, key string, size int64) error {
	puts.Add(1)
	buf := make([]byte, size)
	if _, err := io.ReadFull(in, buf); err != nil {
		return err
	}
	if err := store.Put(key, buf); err != nil {
		log.Printf("put %s: %v", key, err)
	}
	_, err := out.WriteString("OK\n")
	return err
}

func ids(in *bufio.Reader, out *bufio.Writer, count int) error {
	for ; count > 0; count-- {
		path, err := in.ReadString('\n')
		if err != nil {
			return err
		}
		if _, err := out.WriteString(idents.Of(strings.TrimSuffix(path, "\n")) + "\n"); err != nil {
			return err
		}
	}
	return nil
}

func serve(conn *net.UnixConn) {
	defer conn.Close()
	in := bufio.NewReaderSize(conn, 1<<16)
	out := bufio.NewWriter(conn)
	for {
		line, err := in.ReadString('\n')
		if err != nil {
			return
		}
		fields := strings.Fields(line)
		switch {
		case len(fields) == 2 && fields[0] == "GET":
			err = get(conn, out, fields[1])
		case len(fields) == 3 && fields[0] == "PUT":
			size, perr := strconv.ParseInt(fields[2], 10, 64)
			if perr != nil || size < 0 || size > 2<<30 {
				return
			}
			err = put(in, out, fields[1], size)
		case len(fields) == 2 && fields[0] == "IDS":
			count, perr := strconv.Atoi(fields[1])
			if perr != nil || count < 0 || count > 1<<20 {
				return
			}
			err = ids(in, out, count)
		case len(fields) == 1 && fields[0] == "STATS":
			_, err = fmt.Fprintf(out, "gets=%d hits=%d puts=%d ids=%d %s\n", gets.Load(), hits.Load(), puts.Load(), idents.Len(), store.Stats())
		default:
			return
		}
		if err == nil {
			err = out.Flush()
		}
		if err != nil {
			return
		}
	}
}

func main() {
	if len(os.Args) != 2 {
		log.Fatal("usage: pkgs-cache <socket>")
	}
	sock := os.Args[1]
	cache := os.Getenv("XDG_CACHE_HOME")
	if cache == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			log.Fatal(err)
		}
		cache = filepath.Join(home, ".cache")
	}
	budget := int64(50)
	if v := os.Getenv("PKGS_CACHE_SIZE"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			budget = n
		}
	}
	var err error
	store, err = OpenStore(filepath.Join(cache, "pkgs-cache", "packs"), budget<<30)
	if err != nil {
		log.Fatal(err)
	}
	os.Remove(sock)
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: sock, Net: "unix"})
	if err != nil {
		log.Fatal(err)
	}
	if err := os.Chmod(sock, 0o666); err != nil {
		log.Fatal(err)
	}
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
		<-sig
		listener.Close()
	}()
	log.Printf("listening on %s, %s", sock, store.Stats())
	for {
		conn, err := listener.AcceptUnix()
		if err != nil {
			break
		}
		go serve(conn)
	}
	if err := store.Close(); err != nil {
		log.Fatal(err)
	}
}
