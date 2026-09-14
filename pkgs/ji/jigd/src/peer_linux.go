package main

import (
	"fmt"
	"net"
	"os"
	"os/user"
	"strconv"
	"strings"
	"syscall"
)

// allowed: the daemon's own user, root, and nix build users (nixbld or auto-allocated uids).
// The socket itself is 0666 so build users reach it.
func allowed(conn *net.UnixConn) bool {
	raw, err := conn.SyscallConn()
	if err != nil {
		return false
	}
	var cred *syscall.Ucred
	raw.Control(func(fd uintptr) {
		cred, err = syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
	})
	if err != nil || cred == nil {
		return false
	}
	const autoUIDs, autoCount = 872415232, 128 << 16 // nix.conf start-id / id-count defaults
	return int(cred.Uid) == os.Getuid() || cred.Uid == 0 || (nixbld >= 0 && int(cred.Gid) == nixbld) ||
		(cred.Uid >= autoUIDs && cred.Uid < autoUIDs+autoCount)
}

// gid of the nixbld group, -1 if there is none
var nixbld = func() int {
	g, err := user.LookupGroup("nixbld")
	if err != nil {
		return -1
	}
	gid, _ := strconv.Atoi(g.Gid)
	return gid
}()

// fdUnder: the file f has open lives under dir (trailing slash), by the kernel's account
func fdUnder(f *os.File, dir string) bool {
	at, err := os.Readlink(fmt.Sprintf("/proc/self/fd/%d", f.Fd()))
	return err == nil && strings.HasPrefix(at, dir)
}
