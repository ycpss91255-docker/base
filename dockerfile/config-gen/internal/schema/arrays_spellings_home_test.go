package schema

import (
	"reflect"
	"testing"
)

// Only an array of a family is a home a numbered scalar can collide
// with: a sub-table named after the family (`[security.cap_add]`) and an
// array no family carries (`foo = ["a"]` beside `_1`, the scalar an empty
// prefix would number) leave the scalar beside them to its own refusal,
// never conf_family_two_spellings (base#1443 review round 1 mutation
// survey).
//
// Expected values: dockerfile/toml_bridge.py `--kv`, run with tomli
// (base#1443 review round 1 mutation survey). The sub-table input gives
// rc 0 (`security cap_add_1 x`, `security.cap_add cap A`): the bridge's
// walk looks up only a list in _ARRAY_SPEC. The generator refuses
// cap_add_1 by its value (conf_value_invalid, line 2) and the unknown
// sub-table (conf_unknown_table, line 4) as the shell's checks do. The
// gui input gives rc 1 "gui.foo is an array, and no numbered family of
// the shell view carries an array by that name", no two-spellings
// message; the generator refuses `_1` and `foo` each as
// conf_unknown_key. Lines are counted from the input bytes.
func TestDecodeTwoSpellingsNeedsAFamilyArray(t *testing.T) {
	for _, tc := range []struct {
		name string
		src  string
		want []Refusal
	}{
		{
			"sub-table named after the family",
			"[security]\ncap_add_1 = \"x\"\n\n[security.cap_add]\ncap = \"A\"\n",
			[]Refusal{
				{Event: "conf_value_invalid", Path: []string{"security", "cap_add_1"}, Line: 2, Col: 1},
				{Event: "conf_unknown_table", Path: []string{"security", "cap_add"}, Line: 4, Col: 1},
			},
		},
		{
			"array no family carries",
			"[gui]\n_1 = \"x\"\nfoo = [\"a\"]\n",
			[]Refusal{
				{Event: "conf_unknown_key", Path: []string{"gui", "_1"}, Line: 2, Col: 1},
				{Event: "conf_unknown_key", Path: []string{"gui", "foo"}, Line: 3, Col: 1},
			},
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
