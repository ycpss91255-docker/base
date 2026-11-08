package schema

import (
	"os"
	"reflect"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// An entry that carries a field without the field its family needs
// beside it -- a [[volumes]] target without source, or mode without
// target -- is refused with conf_entry_field_needs, once, at the path of
// the field that lacks its partner and on the line that field is written
// (base#1443, design r1 cycle 7). Every row exercises that one rule:
// each fixture's refused entry carries a gating field, only fields its
// family reads, no list or table, and one field whose partner is absent.
// Presence, not truthiness, decides: an empty source does not supply
// target for mode, and an empty target in entry 4 of
// s7_needs_second.toml still counts as present, so only entry 3 is
// refused there.
//
// Expected values: the real bridge refuses each fixture, `--kv` rc 1,
// "entry <n> of volumes carries <field> without <needed>, a combination
// its family is never written in" (scratchpad s7c7-bridge.out; s7d1
// f08); the path is volumes followed by <field>; the line is counted
// from the fixture bytes, the line <field> is written on.
func TestDecodeEntryFieldWithoutItsNeedIsRefused(t *testing.T) {
	cases := []struct {
		file string
		path []string
		line int
	}{
		{"s7_needs_target.toml", []string{"volumes", "target"}, 2},
		{"s7_needs_mode.toml", []string{"volumes", "mode"}, 3},
		{"s7_needs_empty_source.toml", []string{"volumes", "mode"}, 3},
		// entry 3 of 4: entry 2 is cleared, entry 4 has an empty target.
		{"s7_needs_second.toml", []string{"volumes", "target"}, 9},
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
			if r.Event != "conf_entry_field_needs" {
				t.Errorf("Event = %q, want conf_entry_field_needs", r.Event)
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
