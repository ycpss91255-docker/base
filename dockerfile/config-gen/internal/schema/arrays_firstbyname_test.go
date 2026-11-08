package schema

import (
	"os"
	"reflect"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// An entry that carries several fields one entry rule refuses is
// refused once, at the first of them by name, not at the first or the
// last one written (base#1443 review round 1 finding 1). In each fixture
// the field first by name is written between the first written and the
// last written offending field.
//
// Expected values: the real bridge refuses each fixture, `--kv` rc 1,
// and names the offending fields sorted, as _check_entry sorts them:
// "entry 1 of volumes carries aa, mm, zz, which its family does not
// read" and "entry 1 of volumes gives mode, source, target an array or a
// table" (dockerfile/toml_bridge.py run on the fixtures with tomli,
// base#1443 review round 1). The refused field is the first one named;
// the line is counted from the fixture bytes, the line it is written on.
//
// conf_entry_field_needs has no row: the one family with field needs,
// volumes, needs target beside mode and source beside target, so an
// entry missing target cannot also carry target without source, and no
// entry offends that rule at two fields at once.
func TestDecodeEntryRefusesTheFirstOffendingFieldByName(t *testing.T) {
	cases := []struct {
		file  string
		event string
		path  []string
		line  int
	}{
		{"s7_unknown_sorted.toml", "conf_entry_unknown_field", []string{"volumes", "aa"}, 4},
		{"s7_type_sorted.toml", "conf_value_type_refused", []string{"volumes", "mode"}, 3},
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

			want := []Refusal{{Event: c.event, Path: c.path, Line: c.line, Col: 1, Entry: 1, Field: c.path[1], HasField: true}}
			if !reflect.DeepEqual(refusals, want) {
				t.Errorf("Decode refusals = %+v, want %+v", refusals, want)
			}
		})
	}
}
