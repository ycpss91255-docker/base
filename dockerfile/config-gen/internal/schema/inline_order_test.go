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
			"[[volumes]]\nextra = {z = 1, a = 2}\n[[volumes]]\nextra = {b = 1, a = 2}\n",
			[][]string{{"extra", "{", "z", "a", "}"}, {"extra", "{", "b", "a", "}"}}},
		{"inline array of inline tables inside an inline table",
			"volumes = [{opts = [{z = 1, a = 2}, {b = 1, a = 2}]}]\n",
			[][]string{{"opts", "{", "z", "a", "}", "{", "b", "a", "}"}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg, refusals := Decode([]byte(tc.src))

			if len(refusals) != 0 || cfg == nil || len(cfg.Deferred) != 1 {
				t.Fatalf("Decode = %+v, %+v; want one Deferred and no refusal", cfg, refusals)
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
