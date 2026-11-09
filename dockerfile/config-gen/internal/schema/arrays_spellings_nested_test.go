package schema

import (
	"reflect"
	"testing"
)

// The two-spellings check walks every table below the root, a table
// nested in another one included: `arg_1` under `["stage:dev".build]`
// beside `[["stage:dev".build.args]]` is refused once as
// conf_family_two_spellings at the scalar (base#1443 review round 1
// mutation survey).
//
// Expected values: dockerfile/toml_bridge.py `--kv`, run with tomli
// (base#1443 review round 1 mutation survey), gives rc 1
// "stage:dev.build.arg_1 is carried two ways in one configuration":
// _check_one_spelling's walk recurses into every sub-table. The line is
// counted from the input bytes, `arg_1` is on line 2.
func TestDecodeTwoSpellingsInANestedTableIsRefused(t *testing.T) {
	src := "[\"stage:dev\".build]\narg_1 = \"x\"\n\n[[\"stage:dev\".build.args]]\nkey = \"A\"\n"

	_, refusals := Decode([]byte(src))

	want := []Refusal{{Event: "conf_family_two_spellings", Path: []string{"stage:dev", "build", "arg_1"}, Line: 2, Col: 1}}
	if !reflect.DeepEqual(refusals, want) {
		t.Errorf("Decode(%q) refusals = %+v, want %+v", src, refusals, want)
	}
}
