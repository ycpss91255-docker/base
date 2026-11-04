package schema

import (
	"os"
	"reflect"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// A family with an array home that is also spelled as a numbered table
// scalar beside that array -- `cap_drop_1` under [security] next to a
// [[security.cap_drop]] block 1 -- is refused once as
// conf_family_two_spellings, at the scalar's path and on its line
// (base#1443, design r1 cycle 12). Rules out the collision being
// ignored.
//
// Expected values: main's dockerfile/toml_bridge.py `--kv` on
// s7_two_spellings.toml gives rc 1, "security.cap_drop_1 is carried two
// ways in one configuration" (scratchpad s7c10-bridge.out; s7d1 f17); the
// line is counted from the fixture bytes, `cap_drop_1` is on line 2.
func TestDecodeFamilyTwoSpellingsIsRefused(t *testing.T) {
	files := testcorpus.Glob(t, "corpus/s7/s7_two_spellings.toml")
	if len(files) != 1 {
		t.Fatalf("Glob = %v, want s7_two_spellings.toml", files)
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
	if r.Event != "conf_family_two_spellings" {
		t.Errorf("Event = %q, want conf_family_two_spellings", r.Event)
	}
	if want := []string{"security", "cap_drop_1"}; !reflect.DeepEqual(r.Path, want) {
		t.Errorf("Path = %q, want %q", r.Path, want)
	}
	if r.Line != 2 {
		t.Errorf("Line = %d, want 2", r.Line)
	}
}

// A numbered table scalar whose value the decode would also refuse, an
// LF in `arg_1` under [build] beside a [[build.args]] block, is refused
// once, as conf_family_two_spellings at that scalar, not as
// conf_value_newline_refused and not as both (base#1443 review round 1
// finding 3).
//
// Expected values: dockerfile/toml_bridge.py `--kv` on
// s7_two_spellings_newline.toml (run with tomli, base#1443 review round
// 1) gives rc 1, "build.arg_1 is carried two ways in one configuration":
// _emit_kv calls _check_one_spelling before any row reaches
// _check_transportable. The line is counted from the fixture bytes,
// `arg_1` is on line 2.
func TestDecodeFamilyTwoSpellingsComesBeforeTheValueRefusal(t *testing.T) {
	files := testcorpus.Glob(t, "corpus/s7/s7_two_spellings_newline.toml")
	if len(files) != 1 {
		t.Fatalf("Glob = %v, want s7_two_spellings_newline.toml", files)
	}
	src, err := os.ReadFile(files[0])
	if err != nil {
		t.Fatal(err)
	}

	_, refusals := Decode(src)

	want := []Refusal{{Event: "conf_family_two_spellings", Path: []string{"build", "arg_1"}, Line: 2, Col: 1}}
	if !reflect.DeepEqual(refusals, want) {
		t.Errorf("Decode refusals = %+v, want %+v", refusals, want)
	}
}
