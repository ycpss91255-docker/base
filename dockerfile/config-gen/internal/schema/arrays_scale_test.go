package schema

import (
	"fmt"
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

// fastestDecode is the shortest of runs Decode calls on src: the run
// least disturbed by the scheduler and the collector.
func fastestDecode(src []byte, runs int) time.Duration {
	best := time.Duration(1<<63 - 1)
	for range runs {
		start := time.Now()
		Decode(src)
		if d := time.Since(start); d < best {
			best = d
		}
	}
	return best
}

// A family of 10,000 entries is typed whole, each entry at its own index
// and line, and decoding grows with the entries, not with their square:
// 20,000 entries take less than 8 times as long as 5,000, where linear
// work takes about 4 times and quadratic work 16 times (base#1443 review
// round 1 finding 5, design r1 cycle 18). A per-entry step that walks
// every earlier entry, the planted O(n^2), turns it red.
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
	fam := cfg.Arrays["volumes"]
	if fam.State != Set || len(fam.Entries) != n {
		t.Fatalf("volumes holds %d entries, state %v; want %d, Set", len(fam.Entries), fam.State, n)
	}
	for i, e := range fam.Entries {
		k := i + 1
		if e.Index != k || e.Line != 3*k-2 || len(e.Fields) != 1 || e.Fields[0].Value.Scalar.Text != fmt.Sprintf("/s%d", k) {
			t.Fatalf("entry %d = %+v, want index %d, line %d, source /s%d", k, e, k, 3*k-2, k)
		}
	}

	small, large := manyVolumes(5000), manyVolumes(20000)
	fastestDecode(small, 1)
	ts, tl := fastestDecode(small, 5), fastestDecode(large, 5)
	if ratio := float64(tl) / float64(ts); ratio >= 8 {
		t.Errorf("Decode of 20,000 entries took %v, %.1f times the %v of 5,000; want under 8 (linear is about 4)", tl, ratio, ts)
	}
}

// BenchmarkDecodeTenThousandEntries decodes one family of 10,000 entries.
func BenchmarkDecodeTenThousandEntries(b *testing.B) {
	src := manyVolumes(10000)
	for b.Loop() {
		Decode(src)
	}
}
