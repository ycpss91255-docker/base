package schema

import (
	"os"
	"reflect"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// Under a `["stage:<name>"]` table an array is looked up by its segments,
// not by its joined text: the quoted key `"build.args"` is one segment no
// family carries, so the array is refused once as conf_unknown_key, while
// the dotted `build.args`, two segments, is the build.args family and is
// accepted (base#1443, design r1 cycle 13).
//
// Expected values: the real bridge, `toml_bridge.py --kv` (scratchpad
// 1443-c11-bridge.out; s7d1 bridge.out f16), refuses
// s7_stage_quoted_array.toml rc 1 "stage:dev.build.args is an array, and
// no numbered family of the shell view carries an array by that name"
// and accepts s7_stage_dotted_array.toml rc 0 with the one row
// `stage:dev.build arg_1 A`. The refused path is the TOML path as
// written, the table then the one quoted key; the line is counted from
// the fixture bytes, the key is on line 2.
func TestDecodeStageArrayIsLookedUpBySegments(t *testing.T) {
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

	t.Run("quoted key is refused", func(t *testing.T) {
		_, refusals := Decode(read(t, "s7_stage_quoted_array.toml"))

		if len(refusals) != 1 {
			t.Fatalf("Decode refusals = %+v, want exactly one", refusals)
		}
		r := refusals[0]
		if r.Event != "conf_unknown_key" {
			t.Errorf("Event = %q, want conf_unknown_key", r.Event)
		}
		if want := []string{"stage:dev", "build.args"}; !reflect.DeepEqual(r.Path, want) {
			t.Errorf("Path = %q, want %q", r.Path, want)
		}
		if r.Line != 2 {
			t.Errorf("Line = %d, want 2", r.Line)
		}
	})
	t.Run("dotted key is accepted", func(t *testing.T) {
		_, refusals := Decode(read(t, "s7_stage_dotted_array.toml"))

		if len(refusals) != 0 {
			t.Fatalf("Decode refusals = %+v, want none", refusals)
		}
	})
}
