// Host side of jig's build cache: blobs under $XDG_CACHE_HOME/pkgs-cache, served on a unix
// socket that nix.conf's extra-sandbox-paths maps into every build.
//
//	GET key\n             -> OK <len>\n<bytes> | MISS\n
//	PUT key <len>\n<bytes> -> OK\n
//	STATS\n               -> gets=… hits=… puts=…\n
package main

import (
	"bufio"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
)

var (
	root             string
	gets, hits, puts atomic.Int64
)

// keys are "<kind>/<hex or name>": no "..", no leading slash
func keyPath(key string) (string, bool) {
	if key == "" || strings.HasPrefix(key, "/") || strings.Contains(key, "..") {
		return "", false
	}
	return filepath.Join(root, filepath.FromSlash(key)), true
}

func get(conn *net.UnixConn, out *bufio.Writer, key string) error {
	gets.Add(1)
	path, ok := keyPath(key)
	if !ok {
		_, err := out.WriteString("MISS\n")
		return err
	}
	file, err := os.Open(path)
	if err != nil {
		_, err := out.WriteString("MISS\n")
		return err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		_, err := out.WriteString("MISS\n")
		return err
	}
	hits.Add(1)
	if _, err := fmt.Fprintf(out, "OK %d\n", info.Size()); err != nil {
		return err
	}
	if err := out.Flush(); err != nil {
		return err
	}
	// *os.File -> *net.UnixConn: io.Copy uses sendfile(2)
	_, err = io.Copy(conn, file)
	return err
}

func put(in *bufio.Reader, out *bufio.Writer, key string, size int64) error {
	puts.Add(1)
	path, ok := keyPath(key)
	if !ok {
		if _, err := io.CopyN(io.Discard, in, size); err != nil {
			return err
		}
		_, err := out.WriteString("OK\n")
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	// several builds may PUT one key at once: write beside, rename over
	tmp, err := os.CreateTemp(filepath.Dir(path), ".put-*")
	if err != nil {
		return err
	}
	_, err = io.CopyN(tmp, in, size)
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp.Name(), path)
	}
	if err != nil {
		os.Remove(tmp.Name())
		return err
	}
	_, err = out.WriteString("OK\n")
	return err
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
			if perr != nil || size < 0 {
				return
			}
			err = put(in, out, fields[1], size)
		case len(fields) == 1 && fields[0] == "STATS":
			_, err = fmt.Fprintf(out, "gets=%d hits=%d puts=%d\n", gets.Load(), hits.Load(), puts.Load())
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
	root = filepath.Join(cache, "pkgs-cache")
	if err := os.MkdirAll(root, 0o755); err != nil {
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
	log.Printf("listening on %s, store %s", sock, root)
	for {
		conn, err := listener.AcceptUnix()
		if err != nil {
			log.Fatal(err)
		}
		go serve(conn)
	}
}
