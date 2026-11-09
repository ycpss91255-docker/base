package schema

import (
	"reflect"
	"testing"
)

// A table scalar is a numbered spelling of a family only when its key is
// the family's prefix, "_" and one or more ASCII digits, the suffix the
// bridge's _scalar_spellings_of accepts: `cap_add_0` and `cap_add_9`
// beside `[[security.cap_add]]` are refused as conf_family_two_spellings,
// while an empty suffix (`cap_add_`), a letter (`cap_add_x`), a byte just
// below or above the digits (`cap_add_/`, `cap_add_:`), a sign
// (`cap_add_+`) and a digits-only key without the prefix (`1`) are
// unrelated keys that keep their own refusal (base#1443 review round 1
// findings 2 and 3).
//
// Expected values: dockerfile/toml_bridge.py `--kv`, run with tomli on
// each input (base#1443 review round 1 mutation survey): rc 1
// "security.cap_add_0 is carried two ways" and the same for cap_add_9;
// rc 0 for every other key, each emitted as its own row beside
// `security cap_add_1 A`. The generator refuses those by the schema:
// `cap_add_` by its value (conf_value_invalid, the key resolves to the
// cap_add family's validator), the rest as conf_unknown_key. The key is
// on line 2, column 1, in each input.
func TestDecodeTwoSpellingsNeedsADigitSuffix(t *testing.T) {
	for _, tc := range []struct {
		key   string
		path  string
		event string
	}{
		{"cap_add_0", "cap_add_0", "conf_family_two_spellings"},
		{"cap_add_9", "cap_add_9", "conf_family_two_spellings"},
		{"cap_add_", "cap_add_", "conf_value_invalid"},
		{"cap_add_x", "cap_add_x", "conf_unknown_key"},
		{`"cap_add_/"`, "cap_add_/", "conf_unknown_key"},
		{`"cap_add_:"`, "cap_add_:", "conf_unknown_key"},
		{`"cap_add_+"`, "cap_add_+", "conf_unknown_key"},
		{"1", "1", "conf_unknown_key"},
	} {
		t.Run(tc.path, func(t *testing.T) {
			src := "[security]\n" + tc.key + " = \"x\"\n\n[[security.cap_add]]\ncap = \"A\"\n"

			_, refusals := Decode([]byte(src))

			want := []Refusal{{Event: tc.event, Path: []string{"security", tc.path}, Line: 2, Col: 1}}
			if !reflect.DeepEqual(refusals, want) {
				t.Errorf("Decode(%q) refusals = %+v, want %+v", src, refusals, want)
			}
		})
	}
}
