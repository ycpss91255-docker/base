package schema

import (
	"os"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// A `["stage:<name>"]` table is modelled: the decode gives one Stage
// named by the text after `stage:`, at its header's line, whose flat
// scalar keys are its Members in written order, each key one string with
// its dot kept (base#1443, design r1 cycle 14, r3 cycle 16 a47). A
// decode that only judges the stage's keys and drops them leaves the
// stage out of the model.
//
// Expected values: the bridge on a47 (r3 1j, design-r3.md: `--kv`
// `stage:dev\tdeploy.gpu_mode\toff` and `stage:dev\tvolumes.mount_1\t/a:/b`,
// JSON `{"stage:dev": {"deploy.gpu_mode": "off", "volumes.mount_1":
// "/a:/b"}}`): one stage `dev`, two flat keys, each one dotted string,
// in that order. Both keys are known, so the decode refuses neither
// (`_setup_known_key` from this worktree's dist/script/docker/lib under
// LC_ALL=C: `deploy gpu_mode -> 0`, `volumes mount_1 -> 0`). Lines are
// counted from the fixture bytes: header on 1, keys on 2 and 3.
func TestDecodeStageFlatMembersAreModelled(t *testing.T) {
	files := testcorpus.Glob(t, "corpus/s7/s7_stage_flat.toml")
	if len(files) != 1 {
		t.Fatalf("Glob = %v, want s7_stage_flat.toml", files)
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
	if len(cfg.Stages) != 1 {
		t.Fatalf("Stages = %+v, want exactly one", cfg.Stages)
	}
	s := cfg.Stages[0]
	if s.Name != "dev" || s.Line != 1 {
		t.Errorf("stage = {Name %q, Line %d}, want {Name \"dev\", Line 1}", s.Name, s.Line)
	}
	want := []struct {
		key  string
		line int
		text string
	}{
		{"deploy.gpu_mode", 2, "off"},
		{"volumes.mount_1", 3, "/a:/b"},
	}
	if len(s.Members) != len(want) {
		t.Fatalf("Members = %+v, want %d", s.Members, len(want))
	}
	for i, w := range want {
		m := s.Members[i]
		if m.Key != w.key || m.Kind != MemberScalar || m.Line != w.line || m.Value.Text != w.text {
			t.Errorf("Members[%d] = {Key %q, Kind %v, Line %d, Text %q}, want {Key %q, MemberScalar, Line %d, Text %q}",
				i, m.Key, m.Kind, m.Line, m.Value.Text, w.key, w.line, w.text)
		}
	}
}
