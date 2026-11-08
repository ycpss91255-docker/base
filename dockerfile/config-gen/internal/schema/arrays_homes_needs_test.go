package schema

import (
	"reflect"
	"strings"
	"testing"
)

// Each home of Homes() reports the fields its entries read only beside
// another one, the bridge's _FIELD_NEEDS: `target` beside `source` and
// `mode` beside `target` for volumes, nothing for any other family. What
// it reports is what the decode enforces: an entry carrying the field
// alone is refused as conf_entry_field_needs at that field (base#1443
// review round 1 mutation survey).
//
// Expected values: dockerfile/toml_bridge.py _FIELD_NEEDS, which holds
// the volumes row alone; `[[volumes]] target = "a"` and `[[volumes]]
// mode = "ro"` are each refused by the bridge's _check_entry as
// "carries <field> without <need>" (TestDecodeEntryFieldWithoutItsNeedIsRefused).
func TestHomesReportTheFieldsEachEntryNeeds(t *testing.T) {
	want := map[string]map[string]string{
		"volumes": {"target": "source", "mode": "target"},
	}
	for _, h := range Homes() {
		got := h.Spec.Needs
		if len(got) == 0 && len(want[h.Spec.Leaf]) == 0 {
			continue
		}
		if !reflect.DeepEqual(got, want[h.Spec.Leaf]) {
			t.Errorf("Homes() %q Needs = %v, want %v", h.Path, got, want[h.Spec.Leaf])
			continue
		}
		for field := range got {
			src := "[[" + strings.Join(h.Path, ".") + "]]\n" + field + " = \"a\"\n"
			_, refusals := Decode([]byte(src))
			r := Refusal{Event: "conf_entry_field_needs", Path: append(append([]string{}, h.Path...), field), Line: 2, Col: 1, Entry: 1, Field: field, HasField: true}
			if !reflect.DeepEqual(refusals, []Refusal{r}) {
				t.Errorf("Decode(%q) refusals = %+v, want %+v", src, refusals, []Refusal{r})
			}
		}
	}
}
