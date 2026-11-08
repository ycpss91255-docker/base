package schema

import (
	"reflect"
	"testing"
)

// A root array is a family only at a root array home: the last name of
// a home that lives under a section (`args`, `cap_add`, `bindings`, ...)
// written at the root, `[[args]]`, is not a known section and is
// refused as conf_unknown_table at line 1, column 1, and typed as no
// family. Every home Homes lists below the root is tried, so a family
// that gains a home is covered by having one (base#1443 review round 1
// mutation survey).
//
// Expected values: dockerfile/toml_bridge.py `--kv`, run with tomli on
// `[[args]]` `key = "A"` (base#1443 review round 1 mutation survey),
// gives rc 0 and the row `args arg_1 A`: the bridge looks the array up
// by its key alone. Its section `args` is no SCHEMA_SECTIONS name, so
// the shell's _setup_conf_check_known refuses it, the refusal the
// generator gives as conf_unknown_table.
func TestDecodeRootArrayOfASectionHomeIsRefused(t *testing.T) {
	n := 0
	for _, h := range Homes() {
		if len(h.Path) == 1 {
			continue
		}
		n++
		leaf := h.Spec.Leaf
		src := "[[" + leaf + "]]\n" + h.Spec.Gating[0] + " = \"A\"\n"

		cfg, refusals := Decode([]byte(src))

		want := []Refusal{{Event: "conf_unknown_table", Path: []string{leaf}, Line: 1, Col: 1}}
		if !reflect.DeepEqual(refusals, want) {
			t.Errorf("Decode(%q) refusals = %+v, want %+v", src, refusals, want)
		}
		if cfg != nil {
			if fam, ok := cfg.Array(leaf); ok {
				t.Errorf("Decode(%q) typed %s as a family: %+v", src, leaf, fam)
			}
		}
	}
	if n == 0 {
		t.Fatal("Homes() lists no home below the root")
	}
}
