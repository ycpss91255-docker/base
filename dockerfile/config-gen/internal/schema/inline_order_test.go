package schema

import (
	"reflect"
	"testing"
)

// memberKeys lists the keys of v's members, recursing into each member
// that is a table and each table item of a member that is an array, as
// "key" or "key{...}" in order.
func memberKeys(v Value) []string {
	var out []string
	for _, m := range v.Members {
		out = append(out, m.Key)
		switch m.Value.Kind {
		case VTable:
			out = append(out, "{")
			out = append(out, memberKeys(m.Value)...)
			out = append(out, "}")
		case VArray:
			for _, it := range m.Value.Items {
				if it.Kind == VTable {
					out = append(out, "{")
					out = append(out, memberKeys(it)...)
					out = append(out, "}")
				}
			}
		case VScalar:
		}
	}
	return out
}

// onlyUnknownField reports whether every refusal is the entry rule's
// conf_entry_unknown_field. The bridge refuses a `[[volumes]]` entry
// carrying a member it does not read (`extra`, `a`, `opts`): `--kv` rc 1,
// "entry 1 of volumes carries extra, which its family does not read"
// (base#1443, scratchpad s7c4-s6probe.sh). The payload is still recorded
// in Deferred, which is what these tests pin.
func onlyUnknownField(refusals []Refusal) bool {
	for _, r := range refusals {
		if r.Event != "conf_entry_unknown_field" {
			return false
		}
	}
	return true
}

// Every inline table inside a deferred array keeps its members in the
// order they are written, at any depth, whether the array is an inline
// array or a `[[...]]` array of tables, and two items that write the same
// keys in different orders each keep their own (base#1442 review round 2
// finding 7; ADR-00000039: key order inside each array-of-tables entry
// follows the document). The orders are read from the input bytes.
func TestDecodeNestedInlineTablesKeepSourceOrder(t *testing.T) {
	cases := []struct {
		name string
		src  string
		want [][]string
	}{
		{"inline array, nested inline table",
			"volumes = [{source = \"/a\", extra = {z = 1, a = 2}}]\n",
			[][]string{{"source", "extra", "{", "z", "a", "}"}}},
		{"inline array, two items in different orders",
			"volumes = [{source = \"/a\", extra = {z = 1, a = 2}}, {extra = {q = 1, b = 2}, source = \"/b\"}]\n",
			[][]string{{"source", "extra", "{", "z", "a", "}"}, {"extra", "{", "q", "b", "}", "source"}}},
		{"array of tables, inline table two deep",
			"[[volumes]]\nsource = \"/a\"\nextra = {z = 1, a = {y = 1, b = 2}}\n",
			[][]string{{"source", "extra", "{", "z", "a", "{", "y", "b", "}", "}"}}},
		{"array of tables, the same inline key in two elements",
			"[[volumes]]\nsource = \"/a\"\nextra = {z = 1, a = 2}\n[[volumes]]\nsource = \"/b\"\nextra = {b = 1, a = 2}\n",
			[][]string{{"source", "extra", "{", "z", "a", "}"}, {"source", "extra", "{", "b", "a", "}"}}},
		{"inline array of inline tables inside an inline table",
			"volumes = [{source = \"/a\", opts = [{z = 1, a = 2}, {b = 1, a = 2}]}]\n",
			[][]string{{"source", "opts", "{", "z", "a", "}", "{", "b", "a", "}"}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg, refusals := Decode([]byte(tc.src))

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
