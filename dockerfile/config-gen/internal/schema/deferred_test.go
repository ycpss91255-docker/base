package schema

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// A deferred array is returned with its whole payload, not only its path,
// so two layers that differ only inside a `[[volumes]]` element decode to
// different models (base#1442, design r4 cycle 12e (a)). Before this, both
// s6_def_a.toml and s6_def_b.toml gave the same `{[volumes], ArrayHash}`
// and the array stage could not tell them apart.
//
// Expected values: the element's member and its text are the bridge's
// `--entries` rows for the same bytes, `volumes 1 [[volumes]] source /a`
// and `... source /b` (p1442d bridge_d1.out, both rc 0); the type is the
// library's md.Type for `[[volumes]]` (ArrayHash, design r4 section 1);
// lines are counted from the fixture bytes: the `[[volumes]]` header on
// line 1, `source` on line 2.
func TestDecodeDeferredArrayKeepsItsPayload(t *testing.T) {
	want := map[string]string{"s6_def_a.toml": "/a", "s6_def_b.toml": "/b"}
	files := testcorpus.Glob(t, "corpus/s6/s6_def_[ab].toml")
	if len(files) != len(want) {
		t.Fatalf("Glob = %v, want the %d files of %v", files, len(want), want)
	}
	var configs []*Config
	for _, file := range files {
		name := filepath.Base(file)
		src, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}

		cfg, refusals := Decode(src)

		if len(refusals) != 0 {
			t.Fatalf("%s: Decode refusals = %+v, want none", name, refusals)
		}
		wantDeferred := []Deferred{{
			Path: []string{"volumes"},
			Type: "ArrayHash",
			Line: 1,
			Value: Value{
				Kind: VArray,
				Line: 1,
				Items: []Value{{
					Kind:   VTable,
					Header: true,
					Line:   1,
					Members: []Member{{
						Key:   "source",
						Value: Value{Kind: VScalar, Scalar: Scalar{Kind: KindString, Text: want[name]}, Line: 2},
					}},
				}},
			},
		}}
		if !reflect.DeepEqual(cfg.Deferred, wantDeferred) {
			t.Errorf("%s: Deferred =\n%+v\nwant\n%+v", name, cfg.Deferred, wantDeferred)
		}
		var deferred []Child
		for _, c := range cfg.Tree.Nodes[0].Children {
			if c.Kind == ChildDeferred {
				deferred = append(deferred, c)
			}
		}
		if wantChild := []Child{{Kind: ChildDeferred, Key: "volumes", Defer: 0}}; !reflect.DeepEqual(deferred, wantChild) {
			t.Errorf("%s: root deferred children = %+v, want %+v", name, deferred, wantChild)
		}
		configs = append(configs, cfg)
	}
	if reflect.DeepEqual(configs[0], configs[1]) {
		t.Errorf("Decode of s6_def_a.toml and s6_def_b.toml are equal; the /a and /b payloads must differ")
	}
}
