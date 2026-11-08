package schema

import "testing"

// Config.Stages models the `["stage:<name>"]` tables alone: a known
// section beside a stage, `[security]`, is no stage, so the layer below
// has one stage, `dev` (base#1443 review round 1 mutation survey).
//
// Expected values: the stage tables written in the input -- one, named
// `dev` after the `stage:` prefix, as _setup_conf_check_known names a
// stage section by that prefix.
func TestDecodeStagesHoldOnlyStageTables(t *testing.T) {
	src := "[security]\nprivileged = true\n\n[\"stage:dev\"]\n\"deploy.gpu_runtime\" = \"nvidia\"\n"

	cfg, refusals := Decode([]byte(src))

	if len(refusals) != 0 {
		t.Fatalf("Decode(%q) refusals = %+v, want none", src, refusals)
	}
	var names []string
	for _, s := range cfg.Stages {
		names = append(names, s.Name)
	}
	if len(names) != 1 || names[0] != "dev" {
		t.Errorf("Decode(%q) Stages = %q, want [dev]", src, names)
	}
}
