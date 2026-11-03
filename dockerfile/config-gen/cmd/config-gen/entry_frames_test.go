package main

import (
	"strings"
	"testing"
)

// `config-gen check` reports each refusal the array-family rules add
// (base#1443) as a whole frame: its event, line, column and key, and a
// display text that names the key. A refusal of an entry or of one of
// its fields names the entry by the bridge's 1-based entry number,
// `<home>[<n>]` and `<home>[<n>].<field>` (design r1 cycle 20, design-r3
// P4 default); a numbered table scalar keeps its own name.
//
// Expected values: the entry numbers, fields and homes are the bridge's
// own refusals of the same bytes (toml_bridge.py --kv, rc 1, scratchpad
// s7c2..s7c10 bridge.out): "entry 2 of volumes is 'x', not a table",
// "entry 2 of volumes carries none of the fields it is read from",
// "entry 2 of volumes carries zz", "entry 2 of network.ports gives
// container an array or a table", "entry 3 of volumes carries target
// without source", "security.cap_drop_1 is carried two ways". Lines and
// columns are counted from the bytes below [lit]: a block's header, an
// inline element's first byte, a field's key.
func TestCheckEntryRefusalFrames(t *testing.T) {
	cases := []struct {
		name string
		src  string
		want []string // event, line, col, key
	}{
		{"entry not a table", "volumes = [\n  { source = \"/a\" },\n  \"x\",\n]\n",
			[]string{"conf_entry_not_table", "3", "3", "volumes[2]"}},
		{"entry without a gating field", "[[volumes]]\nsource = \"/a\"\n\n[[volumes]]\nzz = \"x\"\n",
			[]string{"conf_entry_no_gating_field", "4", "1", "volumes[2]"}},
		{"entry with an unknown field", "[[volumes]]\nsource = \"/a\"\n\n[[volumes]]\nsource = \"/b\"\nzz = \"x\"\n",
			[]string{"conf_entry_unknown_field", "6", "1", "volumes[2].zz"}},
		{"entry field holding a table", "[[network.ports]]\nhost = \"80\"\n\n[[network.ports]]\nhost = \"81\"\ncontainer = {}\n",
			[]string{"conf_value_type_refused", "6", "1", "network.ports[2].container"}},
		{"entry field without the field it needs", "[[volumes]]\nsource = \"/a\"\ntarget = \"/b\"\n\n[[volumes]]\n\n[[volumes]]\nmode = \"ro\"\ntarget = \"/d\"\n\n[[volumes]]\nsource = \"/c\"\ntarget = \"\"\nmode = \"rw\"\n",
			[]string{"conf_entry_field_needs", "9", "1", "volumes[3].target"}},
		{"family written two ways", "[security]\ncap_drop_1 = \"ALL\"\n[[security.cap_drop]]\ncap = \"NET_RAW\"\n",
			[]string{"conf_family_two_spellings", "2", "1", "security.cap_drop_1"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, fr := runCheck(t, writeLayer(t, tc.src))

			if got != 1 || len(fr) != 1 {
				t.Fatalf("check = %d, frames %q; want 1 and one frame", got, fr)
			}
			f := fr[0]
			if f[2] != tc.want[0] || f[4] != tc.want[1] || f[5] != tc.want[2] || f[6] != tc.want[3] {
				t.Errorf("frame = %q, want event %s line %s col %s key %q", f, tc.want[0], tc.want[1], tc.want[2], tc.want[3])
			}
			if !strings.Contains(f[7], tc.want[3]) || strings.Contains(f[7], "%!") {
				t.Errorf("display = %q, want a text naming %q", f[7], tc.want[3])
			}
		})
	}
}
