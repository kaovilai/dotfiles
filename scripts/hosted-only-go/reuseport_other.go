//go:build !linux

package main

import "syscall"

// soReusePort is the stdlib constant on macOS and the BSDs.
const soReusePort = syscall.SO_REUSEPORT
