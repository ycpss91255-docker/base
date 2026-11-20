package locate

import (
	"os"
	"sync"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// TestFilterWorkIsLinearOnLargeCorpus counts the records filter examines
// for one lookup of every key and table path of the large_tables.toml
// fixture, and requires the total to stay within a small constant times
// keys plus entries. A scan of every entry per lookup costs keys x entries
// (base#1654). The test counts work, not time, through the examined hook
// inside filter's loop (base#1658).
func TestFilterWorkIsLinearOnLargeCorpus(t *testing.T) {
	src, err := os.ReadFile(testcorpus.Glob(t, "corpus/s1/large_tables.toml")[0])
	if err != nil {
		t.Fatal(err)
	}
	m := Index(src)
	entries := m.Entries()
	if len(entries) < 1000 {
		t.Fatalf("large corpus yields %d entries, want at least 1000", len(entries))
	}
	work := 0
	examined = func() { work++ }
	t.Cleanup(func() { examined = nil })
	for _, o := range entries {
		if o.Kind == Key {
			m.Keys(o.Path)
		} else {
			m.Tables(o.Path)
		}
	}
	// Each entry sits in its own path's bucket, so every lookup examines
	// at least one record; a count below that is not measuring filter's
	// loop (base#1658).
	if work < len(entries) {
		t.Fatalf("filter examined %d records for %d lookups, want at least %d", work, len(entries), len(entries))
	}
	const factor = 4
	if limit := factor * (len(entries) + len(entries)); work > limit {
		t.Fatalf("filter examined %d records for %d lookups over %d entries, limit %d", work, len(entries), len(entries), limit)
	}
}

// TestConcurrentReadersOfOneIndex has several goroutines look up the same
// Index at once, so go test -race fails if a lookup writes shared state
// (base#1654).
func TestConcurrentReadersOfOneIndex(t *testing.T) {
	src, err := os.ReadFile(testcorpus.Glob(t, "corpus/s1/large_tables.toml")[0])
	if err != nil {
		t.Fatal(err)
	}
	m := Index(src)
	entries := m.Entries()
	var wg sync.WaitGroup
	for g := 0; g < 4; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for _, o := range entries {
				m.Keys(o.Path)
				m.Tables(o.Path)
			}
		}()
	}
	wg.Wait()
}
