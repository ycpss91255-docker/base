package schema

import (
	"reflect"
	"testing"
)

// A stage's legacy alias follows the rule the root Deploy follows,
// written with an empty gpu_runtime and no runtime included: the stage's
// `"deploy.gpu_runtime" = ""` resolves to the same Deploy as the root's
// `[deploy] gpu_runtime = ""` -- the empty gpu_runtime kept, Set on line
// 2 -- since there is no runtime to fall back to (base#1443 review round
// 1 mutation survey).
//
// Expected values: the root projection of the same key on the same line,
// projectDeploy (base#1442), the rule deploy.sh's _resolve_deploy_config
// applies and Stage.Deploy is documented to follow.
func TestDecodeStageAliasKeepsAnEmptyGPURuntimeWithoutRuntime(t *testing.T) {
	stageSrc := "[\"stage:dev\"]\n\"deploy.gpu_runtime\" = \"\"\n"
	rootSrc := "[deploy]\ngpu_runtime = \"\"\n"

	stageCfg, stageRefusals := Decode([]byte(stageSrc))
	rootCfg, rootRefusals := Decode([]byte(rootSrc))

	if len(stageRefusals) != 0 || len(rootRefusals) != 0 {
		t.Fatalf("refusals = %+v and %+v, want none", stageRefusals, rootRefusals)
	}
	if len(stageCfg.Stages) != 1 {
		t.Fatalf("Decode(%q) Stages = %+v, want one", stageSrc, stageCfg.Stages)
	}
	got := stageCfg.Stages[0].Deploy
	if !reflect.DeepEqual(got, rootCfg.Deploy) {
		t.Errorf("stage Deploy = %+v, want the root's %+v", got, rootCfg.Deploy)
	}
	if got.GPURuntime.State != Set || got.GPURuntime.Line != 2 {
		t.Errorf("stage GPURuntime = %+v, want Set on line 2", got.GPURuntime)
	}
}
