package schema

import (
	"reflect"
	"testing"
)

// Only a table scalar is a numbered spelling of a family: a sub-table
// `[security.cap_add_1]` or an array `cap_add_1 = ["x"]` beside
// `[[security.cap_add]]` is a home of its own and keeps its own
// refusal, never conf_family_two_spellings (base#1443 review round 1
// finding 4).
//
// Expected values: dockerfile/toml_bridge.py `--kv`, run with tomli
// (base#1443 review round 1 mutation survey); _scalar_spellings_of skips
// a key bound to a list or a dict. The sub-table input gives rc 0
// (`security cap_add_1 A`, `security.cap_add_1 foo x`); the generator
// refuses the unknown sub-table, conf_unknown_table at line 4, as the
// shell's section check does. The array input gives rc 1
// "security.cap_add_1 is an array, and no numbered family of the shell
// view carries an array by that name"; the generator refuses it as
// conf_value_type_refused at line 2, the wrong-type exception of
// ADR-00000039 for a key the schema knows.
func TestDecodeTwoSpellingsNeedsATableScalar(t *testing.T) {
	for _, tc := range []struct {
		name string
		src  string
		want []Refusal
	}{
		{
			"sub-table",
			"[[security.cap_add]]\ncap = \"A\"\n\n[security.cap_add_1]\nfoo = \"x\"\n",
			[]Refusal{{Event: "conf_unknown_table", Path: []string{"security", "cap_add_1"}, Line: 4, Col: 1}},
		},
		{
			"array",
			"[security]\ncap_add_1 = [\"x\"]\n\n[[security.cap_add]]\ncap = \"A\"\n",
			[]Refusal{{Event: "conf_value_type_refused", Path: []string{"security", "cap_add_1"}, Line: 2, Col: 1}},
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
