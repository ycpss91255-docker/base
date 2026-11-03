package schema

import (
	"os"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// A family's presence comes from its declaration, not from whether it
// holds an entry: a family written as `[]` is Empty with no entry, a
// family not written at all is Absent, and a family with one block is
// Set (base#1443, design r1 cycle 11). Every row exercises that one
// rule, the family's State read from what the layer declares; a model
// that reads presence from the entries (truthiness) types `[]` as Set
// or as Absent.
//
// Expected values: main's dockerfile/toml_bridge.py run on each fixture
// (scratchpad s7c9-bridge.out): `[build] args = []` gives rc 0, no
// `--kv` row, `--empty-arrays` `build build.args` and
// `--empty-families` `build arg_1 build.args` -- a declared empty
// family; root `volumes = []` gives `--empty-arrays` `volumes volumes`;
// `[build]` alone gives no row in any of the three modes -- an absent
// family; `[[build.args]] key = "A"` gives `--kv` `build arg_1 A` and
// no empty-array row -- a set family of one entry. The lines are
// counted from the fixture bytes.
func TestDecodeFamilyPresenceFromDeclaration(t *testing.T) {
	cases := []struct {
		file    string
		family  string
		state   State
		line    int
		entries int
	}{
		{"s7_presence_empty.toml", "build.args", Empty, 2, 0},
		{"s7_presence_root_empty.toml", "volumes", Empty, 1, 0},
		{"s7_presence_absent.toml", "build.args", Absent, 0, 0},
		{"s7_presence_set.toml", "build.args", Set, 1, 1},
	}
	for _, c := range cases {
		t.Run(c.file, func(t *testing.T) {
			files := testcorpus.Glob(t, "corpus/s7/"+c.file)
			if len(files) != 1 {
				t.Fatalf("Glob = %v, want %s", files, c.file)
			}
			src, err := os.ReadFile(files[0])
			if err != nil {
				t.Fatal(err)
			}

			cfg, refusals := Decode(src)

			if len(refusals) != 0 {
				t.Fatalf("Decode refusals = %+v, want none", refusals)
			}
			if cfg == nil {
				t.Fatal("Decode returned no Config")
			}
			fam := cfg.Arrays[c.family]
			if fam.State != c.state {
				t.Errorf("%s State = %v, want %v", c.family, fam.State, c.state)
			}
			if fam.Line != c.line {
				t.Errorf("%s Line = %d, want %d", c.family, fam.Line, c.line)
			}
			if len(fam.Entries) != c.entries {
				t.Errorf("%s Entries = %+v, want %d", c.family, fam.Entries, c.entries)
			}
		})
	}
}
