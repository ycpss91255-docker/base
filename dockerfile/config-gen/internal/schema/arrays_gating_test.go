package schema

import (
	"os"
	"reflect"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// An entry that carries fields but none of the fields its family is read
// from is refused with conf_entry_no_gating_field, once, on the line its
// block starts (base#1443, design r1 cycle 3). Every row exercises that
// one rule: each fixture's only field is a scalar its family does not
// gate on, so no other entry rule applies.
//
// Expected values: the real bridge refuses each fixture, `--kv` rc 1,
// "entry <n> of <path> carries none of the fields it is read from"
// (scratchpad s7c2/bridge.out; s7d1 f03 for volumes); the path is the
// bridge's <path> split on "."; the line is counted from the fixture
// bytes, the line of the refused entry's [[...]] header.
func TestDecodeEntryWithoutGatingFieldIsRefused(t *testing.T) {
	cases := []struct {
		file string
		path []string
		line int
	}{
		{"s7_nogating_volumes.toml", []string{"volumes"}, 1},
		{"s7_nogating_tmpfs.toml", []string{"tmpfs"}, 1},
		{"s7_nogating_args.toml", []string{"build", "args"}, 1},
		{"s7_nogating_ports.toml", []string{"network", "ports"}, 1},
		{"s7_nogating_contexts.toml", []string{"additional_contexts"}, 1},
		// entry 2 of 2: the first entry is the field-less cleared slot,
		// which carries no field and so is not refused.
		{"s7_nogating_second.toml", []string{"volumes"}, 3},
		// a family under a `["stage:<name>"]` table is held to its
		// entry rules as at the top: "entry 1 of stage:dev.build.args
		// carries none of the fields it is read from" (base#1443 review
		// round 1 finding 2).
		{"s7_stage_nogating.toml", []string{"stage:dev", "build", "args"}, 1},
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

			_, refusals := Decode(src)

			if len(refusals) != 1 {
				t.Fatalf("Decode refusals = %+v, want exactly one", refusals)
			}
			r := refusals[0]
			if r.Event != "conf_entry_no_gating_field" {
				t.Errorf("Event = %q, want conf_entry_no_gating_field", r.Event)
			}
			if !reflect.DeepEqual(r.Path, c.path) {
				t.Errorf("Path = %q, want %q", r.Path, c.path)
			}
			if r.Line != c.line {
				t.Errorf("Line = %d, want %d", r.Line, c.line)
			}
		})
	}
}
