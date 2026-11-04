package schema

import (
	"reflect"
	"testing"
)

// An entry the entry check refuses keeps that refusal as its only one:
// its values are not judged beside it, and no later entry rule is tried
// on it. Each input carries a second defect the decode would otherwise
// report on the same entry -- a non-table element that is itself an
// array, an LF inside the list a field holds, an LF in the value of a
// field written without the field it needs -- and the whole refusal list
// is compared (base#1443 review round 1 finding 5).
//
// Expected values: dockerfile/toml_bridge.py `--kv`, run with tomli on
// each input (base#1443 review round 1 mutation survey), refuses each
// with rc 1 and one message, the first entry rule that fails: "entry 1
// of build.args is ['a'], not a table", "entry 1 of tmpfs gives size an
// array or a table", "entry 1 of volumes carries target without
// source". _check_entry runs before _check_transportable judges any
// value. Lines and columns are counted from the input bytes.
func TestDecodeEntryRefusalIsTheEntrysOnlyRefusal(t *testing.T) {
	for _, tc := range []struct {
		name string
		src  string
		want []Refusal
	}{
		{
			"not a table, itself an array",
			"[build]\nargs = [[\"a\"], {key = \"A\"}]\n",
			[]Refusal{{Event: "conf_entry_not_table", Path: []string{"build", "args"}, Line: 2, Col: 9, Entry: 1}},
		},
		{
			"list field holding an LF",
			"[[tmpfs]]\npath = \"/t\"\nsize = [\"a\\nb\"]\n",
			[]Refusal{{Event: "conf_value_type_refused", Path: []string{"tmpfs", "size"}, Line: 3, Col: 1, Entry: 1, Field: "size", HasField: true}},
		},
		{
			"needs refusal on a value holding an LF",
			"[[volumes]]\ntarget = \"a\\nb\"\n",
			[]Refusal{{Event: "conf_entry_field_needs", Path: []string{"volumes", "target"}, Line: 2, Col: 1, Entry: 1, Field: "target", HasField: true}},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, refusals := Decode([]byte(tc.src))

			if !reflect.DeepEqual(refusals, tc.want) {
				t.Errorf("Decode(%q) refusals = %+v, want %+v", tc.src, refusals, tc.want)
			}
		})
	}
}
