package schema

import "testing"

// Refusal.Key names an entry refusal by the bridge's 1-based entry
// number, `<home>[<n>]` for the entry and `<home>[<n>].<field>` for one
// of its fields, and any other refusal by its path joined with "."
// (base#1443, design r1 cycle 20).
//
// Expected values: the bridge's own refusals of the same bytes
// (toml_bridge.py --kv, rc 1): "entry 2 of volumes carries none of the
// fields it is read from", "entry 2 of volumes carries zz", "entry 3 of
// volumes carries target without source", "security.cap_drop_1 is
// carried two ways".
func TestRefusalKeyNamesTheEntry(t *testing.T) {
	cases := []struct {
		name, src, want string
	}{
		{"entry", "[[volumes]]\nsource = \"/a\"\n\n[[volumes]]\nzz = \"x\"\n", "volumes[2]"},
		{"entry field", "[[volumes]]\nsource = \"/a\"\n\n[[volumes]]\nsource = \"/b\"\nzz = \"x\"\n", "volumes[2].zz"},
		{"third entry field", "[[volumes]]\nsource = \"/a\"\n\n[[volumes]]\n\n[[volumes]]\ntarget = \"/d\"\n", "volumes[3].target"},
		{"not an entry", "[security]\ncap_drop_1 = \"ALL\"\n[[security.cap_drop]]\ncap = \"NET_RAW\"\n", "security.cap_drop_1"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, refusals := Decode([]byte(c.src))

			if len(refusals) != 1 {
				t.Fatalf("Decode refusals = %+v, want exactly one", refusals)
			}
			if got := refusals[0].Key(); got != c.want {
				t.Errorf("Key() = %q, want %q", got, c.want)
			}
		})
	}
}
