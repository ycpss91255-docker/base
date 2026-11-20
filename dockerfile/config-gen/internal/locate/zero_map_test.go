package locate

import (
	"reflect"
	"testing"
)

// TestZeroMapFindsNothing looks up a path in a Map not built by Index,
// whose byID index is nil: every lookup returns no results and the unique
// lookups report Missing, with no panic (base#1658).
func TestZeroMapFindsNothing(t *testing.T) {
	var m Map
	path := []string{"a", "b"}
	lists := map[string]func([]string) []Occurrence{
		"Keys":         m.Keys,
		"Tables":       m.Tables,
		"Members":      m.Members,
		"InlineTables": m.InlineTables,
	}
	for name, list := range lists {
		if got := list(path); len(got) != 0 {
			t.Errorf("zero Map %s(%q) = %v, want no results", name, path, got)
		}
	}
	if got := m.Entries(); len(got) != 0 {
		t.Errorf("zero Map Entries() = %v, want no results", got)
	}
	uniques := map[string]func([]string) (Occurrence, Lookup){
		"Key":   m.Key,
		"Table": m.Table,
	}
	for name, lookup := range uniques {
		if o, l := lookup(path); l != Missing || !reflect.DeepEqual(o, Occurrence{}) {
			t.Errorf("zero Map %s(%q) = %v, %v, want the zero Occurrence, Missing", name, path, o, l)
		}
	}
}
