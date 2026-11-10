//go:build !linux

package schema

import (
	"testing"
	"time"
)

// threadCPU falls back to wall time off Linux, so the package still
// builds there; every gate runs on Linux, where the thread CPU clock is
// read (base#1614).
func threadCPU(tb testing.TB) time.Duration {
	tb.Helper()
	return time.Duration(time.Now().UnixNano())
}
