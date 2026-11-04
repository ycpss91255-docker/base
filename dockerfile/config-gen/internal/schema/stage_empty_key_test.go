package schema

import (
	"reflect"
	"testing"
)

// The empty quoted key under a `["stage:<name>"]` table is refused once
// as conf_unknown_key, at its own line, and Decode does not panic: its
// stage-relative text has no dot and no first byte, so the split into
// section and key must not reach past its end (base#1443 review round 2
// finding 1).
//
// Expected values: `_setup_known_key "" ""` gives 1 under LC_ALL=C (run
// from this worktree's dist/script/docker/lib), and the bridge's --kv
// gives rc 0 with _layer_verdict accept on the same bytes (measured with
// test/bats/unit/config_gen_s7_verdicts_spec.bats on a corpus copy), so
// the class is `differs:unknown-key`, as for the other stage keys of
// TestDecodeStageUnknownKeyIsRefused. The input is written here, not in
// corpus/s7, because the locate parity test reads every corpus fixture
// and fails on this one with locate unchanged (base#1542).
func TestDecodeStageEmptyKeyIsRefused(t *testing.T) {
	src := []byte("[\"stage:dev\"]\n\"\" = \"x\"\n")

	_, refusals := Decode(src)

	want := []string{"stage:dev", ""}
	if len(refusals) != 1 {
		t.Fatalf("Decode refusals = %+v, want exactly one", refusals)
	}
	r := refusals[0]
	if r.Event != "conf_unknown_key" {
		t.Errorf("Event = %q, want conf_unknown_key", r.Event)
	}
	if !reflect.DeepEqual(r.Path, want) {
		t.Errorf("Path = %q, want %q", r.Path, want)
	}
	if r.Line != 2 {
		t.Errorf("Line = %d, want 2", r.Line)
	}
}
