//go:build !linux

package main

import "net"

// no SO_PEERCRED: the socket directory's permissions are the only gate
func allowed(*net.UnixConn) bool { return true }
