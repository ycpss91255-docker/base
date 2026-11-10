package schema

import (
	"fmt"
	"runtime"
	"strings"
	"testing"
	"time"
)

// manyVolumes is n `[[volumes]]` blocks of three lines each, a header, a
// source and a blank line, so entry i (1-based) starts on line 3i-2.
func manyVolumes(n int) []byte {
	var b strings.Builder
	for i := 1; i <= n; i++ {
		fmt.Fprintf(&b, "[[volumes]]\nsource = \"/s%d\"\n\n", i)
	}
	return []byte(b.String())
}

// leastDecodeCPU is the least thread CPU time Decode takes on small and
// on large over rounds of one decode of each, every decode after a collection
// so it does not pay for the garbage of the one before. The least of each
// is the run least disturbed by the cache and the collector; alternating
// spreads any slow stretch over both sizes. The goroutine is locked to its
// thread so the clock read is the one that ran Decode.
func leastDecodeCPU(t *testing.T, small, large []byte, rounds int) (ts, tl time.Duration) {
	t.Helper()
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	one := func(src []byte) time.Duration {
		runtime.GC()
		start := threadCPU(t)
		Decode(src)
		return threadCPU(t) - start
	}
	one(small)
	ts, tl = time.Duration(1<<63-1), time.Duration(1<<63-1)
	for range rounds {
		ts, tl = min(ts, one(small)), min(tl, one(large))
	}
	return ts, tl
}

// A family of 10,000 entries is typed whole, each entry at its own index
// and line, and decoding grows with the entries, not with their square:
// 40,000 entries take less than 14 times the CPU time of 5,000, where
// linear work takes about 8 times and quadratic work 64 times (base#1443
// review round 1 finding 5, design r1 cycle 18). A per-entry step that
// walks every earlier entry, the planted O(n^2), turns it red. The check
// counts thread CPU time, not wall time, so a neighbour process that
// deschedules the test does not move the ratio (base#1614).
//
// Expected values: the line of entry i is 3i-2, counted from the
// fixture's three-line blocks; the source of entry i is "/s<i>", the text
// written into it.
func TestDecodeTenThousandEntriesInBoundedTime(t *testing.T) {
	const n = 10000
	cfg, refusals := Decode(manyVolumes(n))
	if len(refusals) != 0 {
		t.Fatalf("Decode refusals = %+v, want none", refusals[:min(len(refusals), 3)])
	}
	fam, _ := arrayAt(cfg, "volumes")
	if fam.State != Set || len(fam.Entries) != n {
		t.Fatalf("volumes holds %d entries, state %v; want %d, Set", len(fam.Entries), fam.State, n)
	}
	for i, e := range fam.Entries {
		k := i + 1
		if e.Index != k || e.Line != 3*k-2 || len(e.Fields) != 1 || e.Fields[0].Value.Scalar.Text != fmt.Sprintf("/s%d", k) {
			t.Fatalf("entry %d = %+v, want index %d, line %d, source /s%d", k, e, k, 3*k-2, k)
		}
	}

	ts, tl := leastDecodeCPU(t, manyVolumes(5000), manyVolumes(40000), 5)
	if ratio := float64(tl) / float64(ts); ratio >= 14 {
		t.Errorf("Decode of 40,000 entries took %v of CPU, %.1f times the %v of 5,000; want under 14 (linear is about 8)", tl, ratio, ts)
	}
}

// BenchmarkDecodeTenThousandEntries decodes one family of 10,000 entries.
func BenchmarkDecodeTenThousandEntries(b *testing.B) {
	src := manyVolumes(10000)
	for b.Loop() {
		Decode(src)
	}
}
