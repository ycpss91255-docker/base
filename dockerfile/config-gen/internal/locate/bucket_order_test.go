package locate

import (
	"reflect"
	"testing"
)

// TestBucketKeepsDocumentOrder reads the byID bucket of a header written
// three times, between records of other paths, straight from the index:
// its records are in document order, the lines and ordinals counted by
// hand from src (base#1658).
func TestBucketKeepsDocumentOrder(t *testing.T) {
	src := []byte("[[a]]\nx = 1\n[b]\n[[a]]\ny = 2\n[[a]]\n")
	m := Index(src)
	lines, ords := occLines(values(m.byID[pathID([]string{"a"})]))
	if !reflect.DeepEqual(lines, []int{1, 4, 6}) || !reflect.DeepEqual(ords, []int{0, 1, 2}) {
		t.Errorf("byID[a] lines=%v ordinals=%v, want [1 4 6] [0 1 2]", lines, ords)
	}
}
