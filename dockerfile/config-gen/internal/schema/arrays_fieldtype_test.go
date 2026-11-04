package schema

import (
	"os"
	"reflect"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// An entry that carries its family's gating field and gives one of the
// fields its family reads a list or a table, where a single value
// belongs, is refused with conf_value_type_refused, once, at that
// field's path and on the line the field is written (base#1443, design
// r1 cycle 6). Every row exercises that one rule: each fixture's refused
// entry carries a gating field, no field outside its family's read
// fields, and exactly one read field holding a list or a table.
//
// Expected values: the real bridge refuses each fixture, `--kv` rc 1,
// "entry <n> of <path> gives <field> an array or a table, and the shell
// view carries only a single value per field" (scratchpad
// s7c5-bridge.out; s7d1 f09); the path is the bridge's <path> split on
// "." followed by <field>; the line is counted from the fixture bytes,
// the line <field> is written on.
func TestDecodeEntryFieldListOrTableIsRefused(t *testing.T) {
	cases := []struct {
		file string
		path []string
		line int
	}{
		{"s7_type_tmpfs_list.toml", []string{"tmpfs", "size"}, 3},
		{"s7_type_volumes_table.toml", []string{"volumes", "mode"}, 3},
		{"s7_type_args_inline.toml", []string{"build", "args", "value"}, 2},
		// entry 2 of 2: entry 1 carries only host, not refused.
		{"s7_type_second.toml", []string{"network", "ports", "container"}, 6},
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
			if r.Event != "conf_value_type_refused" {
				t.Errorf("Event = %q, want conf_value_type_refused", r.Event)
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
