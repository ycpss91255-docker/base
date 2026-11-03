package schema

import (
	"reflect"
	"strconv"
	"testing"
)

// valueLines lists v's line and, depth first, each item's and member's,
// as "line" for an item and "key:line" for a member.
func valueLines(v Value) []string {
	var out []string
	for _, it := range v.Items {
		out = append(out, strconv.Itoa(it.Line))
		out = append(out, valueLines(it)...)
	}
	for _, m := range v.Members {
		out = append(out, m.Key+"@"+strconv.Itoa(m.Value.Line))
		out = append(out, valueLines(m.Value)...)
	}
	return out
}

// Each item and member of a deferred payload carries the line it is
// written on, not the line of the key that opens the array (base#1442
// redesign R6, findings F2 and F5 of review round 3). Lines are counted
// from the input bytes.
func TestDecodeDeferredPayloadLines(t *testing.T) {
	cases := []struct {
		name string
		src  string
		want []string
	}{
		{"F2 item on its own line",
			"volumes = [\n  { source = \"/a\", target = \"/b\", \"bad\\tkey\" = \"x\" }\n]\n",
			[]string{"2", "source@2", "target@2", "bad\tkey@2"}},
		{"F5 nested inline array over lines",
			"volumes = [\n  {\n    opts = [\n      { \"bad\\tk\" = 1 },\n    ],\n  },\n]\n",
			[]string{"2", "opts@3", "4", "bad\tk@4"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg, _ := decodeNoPanic(t, []byte(tc.src))

			if cfg == nil || len(cfg.Deferred) != 1 {
				t.Fatalf("Decode = %+v; want one Deferred", cfg)
			}
			v := cfg.Deferred[0].Value
			if v.Line != 1 {
				t.Errorf("array line = %d, want 1", v.Line)
			}
			if got := valueLines(v); !reflect.DeepEqual(got, tc.want) {
				t.Errorf("lines = %q, want %q", got, tc.want)
			}
		})
	}
}
