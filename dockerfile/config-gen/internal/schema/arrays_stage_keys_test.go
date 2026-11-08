package schema

import (
	"os"
	"reflect"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// A key under a `["stage:<name>"]` table that the schema does not know is
// refused once as conf_unknown_key, whether it is written flat as one
// quoted dotted key or nested under a `["stage:<name>".<section>]` table;
// a key the schema knows is accepted even when the stage override
// allowlist leaves it out (base#1443, design r1 cycle 14, r3 R2-2 / 17b).
//
// Expected values: the shell's `_setup_known_key` on the split key, run
// from this worktree's dist/script/docker/lib under LC_ALL=C (scratchpad
// c12/known.out): `deploy bogus -> 1`, `build target -> 1`,
// `build target_arch -> 0`, `deploy gpu_mode -> 0`. The class is
// `differs:unknown-key`: the bridge passes these keys through with rc 0
// (r3 1o), and ADR-00000039 refuses an unknown key in every command. The
// refused path is the TOML path as written (as in cycle 11): the stage
// table, then the quoted key as one segment, or the sub-table's segments
// then the key. Lines are counted from the fixture bytes, the key is on
// line 2 in each.
func TestDecodeStageUnknownKeyIsRefused(t *testing.T) {
	read := func(t *testing.T, name string) []byte {
		t.Helper()
		files := testcorpus.Glob(t, "corpus/s7/"+name)
		if len(files) != 1 {
			t.Fatalf("Glob = %v, want %s", files, name)
		}
		src, err := os.ReadFile(files[0])
		if err != nil {
			t.Fatal(err)
		}
		return src
	}

	for _, tc := range []struct {
		file string
		path []string
	}{
		{"s7_stage_unknown_flat.toml", []string{"stage:dev", "deploy.bogus"}},
		{"s7_stage_unknown_build.toml", []string{"stage:dev", "build.target"}},
		{"s7_stage_unknown_nested.toml", []string{"stage:dev", "deploy", "bogus"}},
	} {
		t.Run(tc.file, func(t *testing.T) {
			_, refusals := Decode(read(t, tc.file))

			if len(refusals) != 1 {
				t.Fatalf("Decode refusals = %+v, want exactly one", refusals)
			}
			r := refusals[0]
			if r.Event != "conf_unknown_key" {
				t.Errorf("Event = %q, want conf_unknown_key", r.Event)
			}
			if !reflect.DeepEqual(r.Path, tc.path) {
				t.Errorf("Path = %q, want %q", r.Path, tc.path)
			}
			if r.Line != 2 {
				t.Errorf("Line = %d, want 2", r.Line)
			}
		})
	}
	t.Run("known keys are accepted", func(t *testing.T) {
		_, refusals := Decode(read(t, "s7_stage_known_keys.toml"))

		if len(refusals) != 0 {
			t.Fatalf("Decode refusals = %+v, want none", refusals)
		}
	})
}
