package schema

import (
	"reflect"
	"testing"
)

// A dotted key inside an inline table of a deferred array keeps the order
// it is written in, at any depth, as an explicit inline-table parent does
// (base#1442 review round 3 finding 1). The bridge's parser (tomli, the
// bridge's fallback import) loads `volumes = [{ extra.z = 1, extra.a = 2 }]`
// as {'volumes': [{'extra': {'z': 1, 'a': 2}}]} and the second case as
// {'volumes': [{'source': '/a', 'extra': {'y': {'z': 1, 'a': 2}, 'b': 3}}]},
// each dict in insertion order. The first case also carries `source`,
// the field a volumes entry is read from, so the entry rule (base#1443)
// refuses only `extra`, as a field its family does not read.
func TestDecodeDottedKeysInDeferredInlineTablesKeepSourceOrder(t *testing.T) {
	cases := []struct {
		name string
		src  string
		want [][]string
	}{
		{"dotted keys in an inline array item",
			"volumes = [{ source = \"/a\", extra.z = 1, extra.a = 2 }]\n",
			[][]string{{"source", "extra", "{", "z", "a", "}"}}},
		{"dotted keys in an inline table of an element",
			"[[volumes]]\nsource = \"/a\"\nextra = { y.z = 1, y.a = 2, b = 3 }\n",
			[][]string{{"source", "extra", "{", "y", "{", "z", "a", "}", "b", "}"}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg, refusals := decodeNoPanic(t, []byte(tc.src))

			if !onlyUnknownField(refusals) || cfg == nil || len(cfg.Deferred) != 1 {
				t.Fatalf("Decode = %+v, %+v; want one Deferred and only conf_entry_unknown_field", cfg, refusals)
			}
			var got [][]string
			for _, item := range cfg.Deferred[0].Value.Items {
				got = append(got, memberKeys(item))
			}
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("members = %q, want %q", got, tc.want)
			}
		})
	}
}
