package schema

import (
	"fmt"
	"os"
	"testing"
	"time"
)

// terminationBound is how long Decode may take on terminationInput, a
// two-line layer, so a decode that is still running after it is one that
// never ends.
const terminationBound = time.Second

// terminationInput is a valid layer of UTF-8 text: Decode reads every one
// of its bytes for one the bridge cannot read as text before it judges it.
const terminationInput = "[deploy]\ngpu_mode = \"auto\"\n"

// TestMain checks, before any test of the package runs, that Decode
// returns on terminationInput within terminationBound, and fails the run
// when it does not (base#1467: the S1f mutation gate counted a mutant
// that makes the scan for an undecodable byte never end as timed out,
// because no test bounded how long Decode may run). It runs first so that
// no other test reaches a decode that never ends before it.
func TestMain(m *testing.M) {
	done := make(chan struct{})
	go func() {
		defer close(done)
		Decode([]byte(terminationInput))
	}()
	select {
	case <-done:
	case <-time.After(terminationBound):
		_, _ = fmt.Fprintf(os.Stderr, "Decode(%q) did not return within %v\n", terminationInput, terminationBound)
		os.Exit(1)
	}
	os.Exit(m.Run())
}
