package schema

import (
	"fmt"
	"strings"
	"testing"
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

// A family of 10,000 entries is typed whole, each entry at its own index
// and line, and decoding grows with the entries, not with their square:
// 40,000 entries take at most 9 times the entry visits of 5,000, where
// linear work takes 8 times and quadratic work 64 times (base#1443
// review round 1 finding 5, design r1 cycle 18). A per-entry step that
// walks every earlier entry, the planted O(n^2), turns it red. The check
// counts entry visits, not time, so neither a neighbour process nor a
// shared cache moves it (base#1614, base#1617). Each of the 5,000
// entries is visited at least once, so a count that never steps fails.
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

	const small, large, maxRatio = 5000, 40000, 9
	_, _, vs := decode(manyVolumes(small))
	_, _, vl := decode(manyVolumes(large))
	if vs < small {
		t.Fatalf("Decode of %d entries made %d entry visits; want at least one per entry", small, vs)
	}
	if ratio := float64(vl) / float64(vs); ratio > maxRatio {
		t.Errorf("Decode of %d entries made %d entry visits, %.1f times the %d of %d; want at most %d (linear is %d)",
			large, vl, ratio, vs, small, maxRatio, large/small)
	}
}

// BenchmarkDecodeTenThousandEntries decodes one family of 10,000 entries.
func BenchmarkDecodeTenThousandEntries(b *testing.B) {
	src := manyVolumes(10000)
	for b.Loop() {
		Decode(src)
	}
}
