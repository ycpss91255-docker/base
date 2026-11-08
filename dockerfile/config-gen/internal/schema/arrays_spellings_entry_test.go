package schema

import (
	"reflect"
	"testing"
)

// The two-spellings check walks tables, never an array's entries: an
// entry of `[[volumes]]` that carries a family array, `cap_add`, beside
// a numbered `cap_add_1` keeps the one refusal the entry check gives it,
// conf_entry_unknown_field at the first unknown field by name, and no
// conf_family_two_spellings is added under the entry (base#1443 review
// round 1 mutation survey).
//
// Expected values: dockerfile/toml_bridge.py `--kv`, run with tomli on
// this input (base#1443 review round 1 mutation survey), gives rc 1
// "entry 1 of volumes carries cap_add, cap_add_1, which its family does
// not read": _check_one_spelling's walk recurses into dicts only, never
// into a list, so it finds no spelling, and _check_entry names the
// unknown fields sorted. `cap_add` is written on line 4, column 1.
func TestDecodeTwoSpellingsIsNotJudgedInsideAnEntry(t *testing.T) {
	src := "[[volumes]]\nsource = \"a\"\ncap_add_1 = \"x\"\ncap_add = [{cap = \"A\"}]\n"

	_, refusals := Decode([]byte(src))

	want := []Refusal{{Event: "conf_entry_unknown_field", Path: []string{"volumes", "cap_add"}, Line: 4, Col: 1, Entry: 1, Field: "cap_add", HasField: true}}
	if !reflect.DeepEqual(refusals, want) {
		t.Errorf("Decode(%q) refusals = %+v, want %+v", src, refusals, want)
	}
}
