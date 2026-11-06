//go:build linux

package main

// soReusePort is SO_REUSEPORT on Linux (0xf on amd64, arm64, arm, 386);
// the stdlib syscall package does not export it there.
const soReusePort = 0xf
