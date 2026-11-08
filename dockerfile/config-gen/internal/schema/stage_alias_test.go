package schema

import "testing"

// A stage's legacy alias is read from its flat members only (base#1443,
// design r1 cycle 15, r3 cycle 17). The flat `"deploy.runtime"` under
// `["stage:dev"]` fills Stage.Deploy the way S6 fills the root Deploy:
// GPURuntime is the flat `"deploy.gpu_runtime"` when it is non-empty and
// otherwise the legacy runtime's field, and Runtime is the legacy key as
// written. A nested `["stage:dev".deploy] runtime` is a member of the
// sub-table and fills nothing.
//
// Expected values: the bridge's `--merge --kv` (p1443 merge.out). Only
// the flat pair is read as an alias: `t_flat + l_flat` un-inherits the
// template's canonical and leaves `stage:dev\tdeploy.runtime\tnvidia`,
// while `t_nest + l_nest` keeps both `stage:dev.deploy` rows. The
// effective value is stage.sh's _resolve_deploy_config worked by hand
// (`if [[ -z "${_tmp}" ]]; then _tmp="${_legacy_runtime:-...}"`): a
// non-empty gpu_runtime wins, an empty one falls back to the alias.
// Lines are counted from the input bytes.
func TestDecodeStageAliasFlatOnly(t *testing.T) {
	str := func(text string, line int) Field {
		return Field{State: Set, Value: Scalar{Kind: KindString, Text: text}, Line: line}
	}
	cases := []struct {
		name string
		src  string
		want Deploy
	}{
		{"flat alias alone",
			"[\"stage:dev\"]\n\"deploy.runtime\" = \"nvidia\"\n",
			Deploy{GPURuntime: str("nvidia", 2), Runtime: str("nvidia", 2)}},
		{"flat canonical wins",
			"[\"stage:dev\"]\n\"deploy.gpu_runtime\" = \"auto\"\n\"deploy.runtime\" = \"nvidia\"\n",
			Deploy{GPURuntime: str("auto", 2), Runtime: str("nvidia", 3)}},
		{"flat empty canonical falls back to the alias",
			"[\"stage:dev\"]\n\"deploy.gpu_runtime\" = \"\"\n\"deploy.runtime\" = \"nvidia\"\n",
			Deploy{GPURuntime: str("nvidia", 3), Runtime: str("nvidia", 3)}},
		{"nested runtime is not an alias",
			"[\"stage:dev\".deploy]\nruntime = \"nvidia\"\n",
			Deploy{}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg, refusals := Decode([]byte(tc.src))

			if len(refusals) != 0 {
				t.Fatalf("Decode refusals = %+v, want none", refusals)
			}
			if cfg == nil || len(cfg.Stages) != 1 {
				t.Fatalf("Stages = %+v, want exactly one", cfg)
			}
			if got := cfg.Stages[0].Deploy; got != tc.want {
				t.Errorf("Stages[0].Deploy = %+v, want %+v", got, tc.want)
			}
			if cfg.Deploy != (Deploy{}) {
				t.Errorf("root Deploy = %+v, want zero (a stage alias stays in the stage)", cfg.Deploy)
			}
		})
	}
}
