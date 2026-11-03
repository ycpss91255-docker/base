package schema

import (
	"reflect"
	"testing"
)

// A root array is a family only at a root array home: a known section
// name that no array family carries, `deploy = []`, `deploy = [{...}]`
// or `[[deploy]]`, is an array nothing reads and is refused, in each
// spelling, as the root arrays of an unknown name are -- an inline
// array as conf_top_level_key, an array of tables as conf_unknown_table
// -- at the path of the section name, line 1 (base#1443 review round 1
// finding 1). The four root homes accept `[]` as an Empty family. Every
// known section is tried, so a section that gains no family is covered
// by being a section.
//
// Expected values: main's dockerfile/toml_bridge.py `--kv` run on the
// three spellings of every SCHEMA_SECTIONS name (scratchpad
// r1/bridge2.out): rc 1 "<name> is an array, and no numbered family of
// the shell view carries an array by that name" for every name but
// tmpfs, devices, volumes and additional_contexts, which give rc 0 for
// `[]` and refuse `zz = 1` entries by the entry rule instead.
func TestDecodeRootArrayAtAKnownSectionWithNoFamilyIsRefused(t *testing.T) {
	rootHomes := map[string]bool{"tmpfs": true, "devices": true, "volumes": true, "additional_contexts": true}
	sections := KnownSections()
	if len(sections) == 0 {
		t.Fatal("KnownSections() is empty")
	}
	n := 0
	for _, s := range sections {
		if rootHomes[s] {
			cfg, refusals := Decode([]byte(s + " = []\n"))
			if len(refusals) != 0 || cfg.Arrays[s].State != Empty {
				t.Errorf("%s = []: refusals %+v, family %+v; want none and an Empty family", s, refusals, cfg.Arrays[s])
			}
			continue
		}
		n++
		for _, c := range []struct {
			body  string
			event string
		}{
			{s + " = []\n", "conf_top_level_key"},
			{s + " = [{zz = 1}]\n", "conf_top_level_key"},
			{"[[" + s + "]]\nzz = 1\n", "conf_unknown_table"},
		} {
			cfg, refusals := Decode([]byte(c.body))
			if len(refusals) != 1 {
				t.Errorf("Decode(%q) refusals = %+v, want exactly one", c.body, refusals)
				continue
			}
			r := refusals[0]
			if r.Event != c.event || !reflect.DeepEqual(r.Path, []string{s}) || r.Line != 1 || r.Col != 1 {
				t.Errorf("Decode(%q) refusal = %+v, want {%s [%s] 1 1}", c.body, r, c.event, s)
			}
			if cfg != nil {
				if _, ok := cfg.Arrays[s]; ok {
					t.Errorf("Decode(%q) typed %s as a family: %+v", c.body, s, cfg.Arrays[s])
				}
			}
		}
	}
	if n == 0 {
		t.Fatal("every known section is a root home: nothing was tried")
	}
}
