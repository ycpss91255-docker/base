package schema

import (
	"os"
	"reflect"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// An entry that the entry check refuses (not a table, no gating field,
// an unknown field) draws that one refusal and nothing else: no type or
// value refusal for what it holds, since the check picks the first
// failure before any field is converted or value-checked (base#1443,
// the r3 note, design r1 cycle 6). Every row exercises that one rule:
// each fixture's only entry fails the entry check and also holds a value
// that would draw a type or value refusal on its own (a list where one
// value belongs, or a string with a newline).
// s7_order_nogating_list.toml is r3 control 1 ([[tmpfs]] size = [1]).
//
// Expected values: the real bridge refuses each fixture, `--kv` rc 1,
// with the entry-check message only (scratchpad s7c6-bridge.out; s7d1
// f04 and f18): "carries none of the fields it is read from" ->
// conf_entry_no_gating_field, "is '...', not a table" ->
// conf_entry_not_table, "carries zz, which its family does not read" ->
// conf_entry_unknown_field; the path and line follow cycles 2 to 4 (the
// entry's first line, the unknown field's line), counted from the
// fixture bytes.
func TestDecodeEntryCheckRefusalIsTheOnlyOne(t *testing.T) {
	cases := []struct {
		file  string
		event string
		path  []string
		line  int
	}{
		{"s7_order_nogating_list.toml", "conf_entry_no_gating_field", []string{"tmpfs"}, 1},
		{"s7_order_nogating_newline.toml", "conf_entry_no_gating_field", []string{"volumes"}, 1},
		{"s7_order_nottable_newline.toml", "conf_entry_not_table", []string{"volumes"}, 1},
		{"s7_order_unknown_newline.toml", "conf_entry_unknown_field", []string{"volumes", "zz"}, 3},
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
			if r.Event != c.event {
				t.Errorf("Event = %q, want %q", r.Event, c.event)
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
