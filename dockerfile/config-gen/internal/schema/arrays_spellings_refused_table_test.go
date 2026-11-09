package schema

import (
	"reflect"
	"testing"
)

// A numbered scalar beside its family's array under a table the walk
// refused -- `cap_add_1` and `[[bogus.cap_add]]` under the unknown
// [bogus] -- is not judged for two spellings: the table's refusal is the
// file's only one, as nothing under a refused table is judged, the rule
// Decode already applies when it types no array under a refused path
// (base#1443 review round 1 finding 1).
//
// Expected values: the generator's own rule for a refused table
// (checkSpellings, base#1443 review round 1 finding 3). Both halves
// refuse this input: dockerfile/toml_bridge.py `--kv`, run with tomli
// (base#1443 review round 1 mutation survey), gives rc 1 "bogus.cap_add_1
// is carried two ways", since the bridge knows no section list, while
// the generator refuses [bogus] itself, conf_unknown_table at line 1,
// column 1, as _setup_conf_check_known refuses the section.
func TestDecodeTwoSpellingsUnderARefusedTableIsNotJudged(t *testing.T) {
	src := "[bogus]\ncap_add_1 = \"x\"\n\n[[bogus.cap_add]]\ncap = \"A\"\n"

	_, refusals := Decode([]byte(src))

	want := []Refusal{{Event: "conf_unknown_table", Path: []string{"bogus"}, Line: 1, Col: 1}}
	if !reflect.DeepEqual(refusals, want) {
		t.Errorf("Decode(%q) refusals = %+v, want %+v", src, refusals, want)
	}
}
