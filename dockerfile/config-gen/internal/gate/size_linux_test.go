package gate

import (
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
)

// rusageThread is Linux's RUSAGE_THREAD (include/uapi/linux/resource.h):
// getrusage reports the calling thread's CPU time only.
const rusageThread = 1

// threadCPU returns the user plus system CPU time the calling OS thread
// has used.
func threadCPU(t *testing.T) time.Duration {
	t.Helper()
	var ru syscall.Rusage
	if err := syscall.Getrusage(rusageThread, &ru); err != nil {
		t.Fatalf("getrusage(RUSAGE_THREAD): %v", err)
	}
	return time.Duration(ru.Utime.Nano() + ru.Stime.Nano())
}

// A 1 MiB basic string value is accepted in under one second, with no
// panic (base#1441 acceptance: size). tomllib accepts it.
//
// The bound is on the CPU time of the one OS thread that runs Check (the
// goroutine is locked to it), not on the wall clock: the base#1441 review
// round 1 run logged wall times of 1.10 to 2.30 s for this call while the
// redpath cases ran in parallel, and the CPU time of one thread does not
// count the time it waits for a CPU. The
// smallest of three calls is kept, so one call slowed by a collection is
// not the verdict. Measured 2026-11-19 in the race RUN (-race,
// -covermode=atomic) at a host load average near 20: 0.41 to 0.59 s per
// call; the same test built without -race and coverage: 5 to 7 ms.
func TestCheckOneMiBValueUnderOneSecond(t *testing.T) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	src := []byte("a = \"" + strings.Repeat("x", 1<<20) + "\"\n")
	best := time.Duration(-1)
	for range 3 {
		start := threadCPU(t)
		err := Check("t.toml", src)
		used := threadCPU(t) - start
		if err != nil {
			t.Fatalf("Check(1 MiB string) = %v, want nil", err)
		}
		if best < 0 || used < best {
			best = used
		}
	}
	if best >= time.Second {
		t.Fatalf("Check(1 MiB string) used %v of its thread's CPU at best of 3, want under 1s", best)
	}
}
