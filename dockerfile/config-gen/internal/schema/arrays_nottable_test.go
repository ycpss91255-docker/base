package schema

import (
	"os"
	"reflect"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// An element of a family array that is a scalar, not a table, is refused
// with conf_entry_not_table, once, on the line the element is written
// (base#1443, design r1 cycle 4). A string is not read as a cleared slot.
// Every row exercises that one rule: each fixture's refused element is a
// bare scalar, and a table element beside it is not refused.
//
// Expected values: the real bridge refuses each fixture, `--kv` rc 1,
// "entry <n> of <path> is <repr>, not a table" (scratchpad
// s7c3-bridge.out; s7d1 f07 for volumes); the path is the bridge's <path>
// split on "."; the line is counted from the fixture bytes, the line the
// refused element is written on (entry 2 of s7_nottable_second.toml is
// on line 3).
func TestDecodeEntryNotTableIsRefused(t *testing.T) {
	cases := []struct {
		file string
		path []string
		line int
	}{
		{"s7_nottable_string.toml", []string{"volumes"}, 1},
		{"s7_nottable_int.toml", []string{"tmpfs"}, 1},
		{"s7_nottable_args.toml", []string{"build", "args"}, 2},
		// entry 2 of 2: entry 1 is a table carrying source, not refused.
		{"s7_nottable_second.toml", []string{"volumes"}, 3},
	}
	for _, c := range cases {
		t.Run(c.file, func(t *testing.T) {
			files := testcorpus.Glob(t, "corpus/s7/"+c.file)
			if len(files) != 1 {
				t.Fatalf("Glob = %v, want %s", files, c.file)
			}
			src, err := os.ReadFile(files[0])
			if err != nil {
				t.Fatal(err)
			}

			_, refusals := Decode(src)

			if len(refusals) != 1 {
				t.Fatalf("Decode refusals = %+v, want exactly one", refusals)
			}
			r := refusals[0]
			if r.Event != "conf_entry_not_table" {
				t.Errorf("Event = %q, want conf_entry_not_table", r.Event)
			}
			if !reflect.DeepEqual(r.Path, c.path) {
				t.Errorf("Path = %q, want %q", r.Path, c.path)
			}
			if r.Line != c.line {
				t.Errorf("Line = %d, want %d", r.Line, c.line)
			}
		})
	}
}
