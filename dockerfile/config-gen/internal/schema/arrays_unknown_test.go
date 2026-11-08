package schema

import (
	"os"
	"reflect"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// An entry that carries its family's gating field and, beside it, a field
// its family does not read is refused with conf_entry_unknown_field,
// once, at that field's path and on the line the field is written
// (base#1443, design r1 cycle 5). Every row exercises that one rule:
// each fixture's refused entry carries a gating field and exactly one
// field outside its family's read fields. s7_unknown_table_value.toml is
// the r3 control: its unknown field holds a table, and the unknown-field
// refusal is the only one, no type refusal beside it.
//
// Expected values: the real bridge refuses each fixture, `--kv` rc 1,
// "entry <n> of <path> carries <field>, which its family does not read"
// (scratchpad s7c4-bridge.out; s7d1 f05 and f06); the path is the
// bridge's <path> split on "." followed by <field>; the line is counted
// from the fixture bytes, the line <field> is written on.
func TestDecodeEntryUnknownFieldIsRefused(t *testing.T) {
	cases := []struct {
		file string
		path []string
		line int
	}{
		{"s7_unknown_devices.toml", []string{"devices", "foo"}, 3},
		{"s7_unknown_tmpfs.toml", []string{"tmpfs", "sise"}, 3},
		{"s7_unknown_table_value.toml", []string{"volumes", "zz"}, 3},
		// entry 2 of 2: entry 1 carries only source, not refused.
		{"s7_unknown_second.toml", []string{"volumes", "zz"}, 6},
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
			if r.Event != "conf_entry_unknown_field" {
				t.Errorf("Event = %q, want conf_entry_unknown_field", r.Event)
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
