package schema

import (
	"reflect"
	"testing"
)

// An entry carrying a field whose quoted name is empty is refused at
// that field: the empty name is a field the entry carries, not the
// absence of one, so the refusal's path keeps its empty last segment and
// its key names the field, `<home>[<n>].` (base#1443 review round 1
// finding 1).
//
// Expected values: the bridge's own refusals of the same bytes
// (toml_bridge.py --kv, rc 1, scratchpad r1443e): "entry 1 of volumes
// carries , which its family does not read" and "entry 2 of volumes
// carries , which its family does not read". Lines and columns are
// counted from the bytes below [lit]: the empty key's opening quote.
func TestEntryRefusalKeepsAnEmptyFieldName(t *testing.T) {
	cases := []struct {
		name, src string
		want      Refusal
		key       string
	}{
		{"first entry", "[[volumes]]\nsource = \"/a\"\n\"\" = \"x\"\n",
			Refusal{Event: "conf_entry_unknown_field", Path: []string{"volumes", ""}, Line: 3, Col: 1, Entry: 1}, "volumes[1]."},
		{"second entry", "[[volumes]]\nsource = \"/a\"\n\n[[volumes]]\nsource = \"/b\"\n\"\" = \"x\"\n",
			Refusal{Event: "conf_entry_unknown_field", Path: []string{"volumes", ""}, Line: 6, Col: 1, Entry: 2}, "volumes[2]."},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, refusals := Decode([]byte(c.src))

			if len(refusals) != 1 {
				t.Fatalf("Decode refusals = %+v, want exactly one", refusals)
			}
			got := refusals[0]
			if got.Event != c.want.Event || !reflect.DeepEqual(got.Path, c.want.Path) || got.Line != c.want.Line || got.Col != c.want.Col || got.Entry != c.want.Entry || got.Field != "" {
				t.Errorf("refusal = %+v, want %+v naming the empty field", got, c.want)
			}
			if k := got.Key(); k != c.key {
				t.Errorf("Key() = %q, want %q", k, c.key)
			}
		})
	}
}
