//go:build linux

package schema

import (
	"syscall"
	"testing"
	"time"
	"unsafe"
)

// clockThreadCPUTimeID is CLOCK_THREAD_CPUTIME_ID from <time.h>, which
// the syscall package does not name.
const clockThreadCPUTimeID = 3

// threadCPU is the CPU time the calling OS thread has used. Time the
// thread spends descheduled is not counted, so a neighbour process on
// the same CPUs does not inflate it (base#1614). The caller holds
// runtime.LockOSThread, so the goroutine stays on the thread measured.
func threadCPU(tb testing.TB) time.Duration {
	tb.Helper()
	var ts syscall.Timespec
	if _, _, errno := syscall.Syscall(syscall.SYS_CLOCK_GETTIME, clockThreadCPUTimeID, uintptr(unsafe.Pointer(&ts)), 0); errno != 0 {
		tb.Fatalf("clock_gettime(CLOCK_THREAD_CPUTIME_ID): %v", errno)
	}
	return time.Duration(ts.Nano())
}
