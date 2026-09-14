//go:build !linux

package main

import (
	"net"
	"os"
)

// no SO_PEERCRED: the socket directory's permissions are the only gate
func allowed(*net.UnixConn) bool { return true }

func fdUnder(*os.File, string) bool { return true }
