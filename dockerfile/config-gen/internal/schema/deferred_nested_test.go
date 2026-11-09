package schema

import (
	"reflect"
	"testing"
)

// A deferred array keeps the whole payload of each element, so two layers
// that differ anywhere inside a `[[volumes]]` element decode to different
// models (base#1442, review round 1). A table nested under the element
// (`[volumes.extra]`) and a dotted key of the element (`a.b = 1`) are
// members of the element: the library decodes both into the element's
// table (`{"source": "/a", "extra": {"k": 1}}`), and the bridge's
// `--entries` reads the same nested value. Members are in written order;
// each line is counted from the input bytes.
func TestDecodeDeferredArrayKeepsNestedMembers(t *testing.T) {
	scalar := func(kind Kind, text string, line int) Value {
		return Value{Kind: VScalar, Scalar: Scalar{Kind: kind, Text: text}, Line: line}
	}
	cases := []struct {
		name    string
		a, b    string
		wantA   []Member
		elemOfA int
	}{
		{
			name: "nested table",
			a:    "[[volumes]]\nsource = \"/a\"\n[volumes.extra]\nk = 1\n",
			b:    "[[volumes]]\nsource = \"/a\"\n[volumes.extra]\nk = 2\n",
			wantA: []Member{
				{Key: "source", Value: scalar(KindString, "/a", 2)},
				{Key: "extra", Value: Value{Kind: VTable, Line: 3, Members: []Member{{Key: "k", Value: scalar(KindInt, "1", 4)}}}},
			},
		},
		{
			name: "dotted key",
			a:    "[[volumes]]\nsource = \"/a\"\na.b = 1\n",
			b:    "[[volumes]]\nsource = \"/a\"\na.b = 2\n",
			wantA: []Member{
				{Key: "source", Value: scalar(KindString, "/a", 2)},
				{Key: "a", Value: Value{Kind: VTable, Line: 3, Members: []Member{{Key: "b", Value: scalar(KindInt, "1", 3)}}}},
			},
		},
		{
			name: "nested table in the second element",
			a:    "[[volumes]]\nsource = \"/a\"\n[[volumes]]\nsource = \"/b\"\n[volumes.extra]\nk = 1\n",
			b:    "[[volumes]]\nsource = \"/a\"\n[[volumes]]\nsource = \"/b\"\n[volumes.extra]\nk = 2\n",
			wantA: []Member{
				{Key: "source", Value: scalar(KindString, "/b", 4)},
				{Key: "extra", Value: Value{Kind: VTable, Line: 5, Members: []Member{{Key: "k", Value: scalar(KindInt, "1", 6)}}}},
			},
			elemOfA: 1,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfgA, refA := decodeNoPanic(t, []byte(tc.a))
			cfgB, refB := decodeNoPanic(t, []byte(tc.b))

			if !onlyUnknownField(refA) || !onlyUnknownField(refB) {
				t.Fatalf("refusals = %+v / %+v, want only conf_entry_unknown_field", refA, refB)
			}
			if reflect.DeepEqual(cfgA.Deferred, cfgB.Deferred) {
				t.Errorf("Deferred of %q and %q are equal; the payloads differ", tc.a, tc.b)
			}
			if len(cfgA.Deferred) != 1 || len(cfgA.Deferred[0].Value.Items) <= tc.elemOfA {
				t.Fatalf("Deferred = %+v, want one array with element %d", cfgA.Deferred, tc.elemOfA)
			}
			if got := cfgA.Deferred[0].Value.Items[tc.elemOfA].Members; !reflect.DeepEqual(got, tc.wantA) {
				t.Errorf("element %d members =\n  %+v\nwant\n  %+v", tc.elemOfA, got, tc.wantA)
			}
		})
	}
}
