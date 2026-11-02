package schema

import (
	"reflect"
	"testing"
)

// `[deploy] runtime` is the legacy alias of gpu_runtime (base#1442 AC
// "Legacy alias", review round 2 finding 4). The model resolves the two as
// deploy.sh's _resolve_deploy_config does: Deploy.GPURuntime is
// gpu_runtime when it is set to a non-empty value, and otherwise the
// legacy runtime's field. A non-empty legacy runtime is flagged in
// Config.Deprecated, where deploy.sh logs conf_runtime_key_deprecated,
// whether or not gpu_runtime overrides it. Lines are counted from the
// input bytes.
func TestDecodeRuntimeAlias(t *testing.T) {
	legacy := Deprecation{Path: []string{"deploy", "runtime"}, Canonical: []string{"deploy", "gpu_runtime"}, Line: 2}
	cases := []struct {
		name       string
		src        string
		gpuRuntime Field
		deprecated []Deprecation
	}{
		{"alias alone", "[deploy]\nruntime = \"nvidia\"\n",
			Field{State: Set, Value: Scalar{Kind: KindString, Text: "nvidia"}, Line: 2}, []Deprecation{legacy}},
		{"canonical wins", "[deploy]\nruntime = \"nvidia\"\ngpu_runtime = \"off\"\n",
			Field{State: Set, Value: Scalar{Kind: KindString, Text: "off"}, Line: 3}, []Deprecation{legacy}},
		{"empty canonical falls back to the alias", "[deploy]\nruntime = \"nvidia\"\ngpu_runtime = \"\"\n",
			Field{State: Set, Value: Scalar{Kind: KindString, Text: "nvidia"}, Line: 2}, []Deprecation{legacy}},
		{"canonical alone", "[deploy]\ngpu_runtime = \"auto\"\n",
			Field{State: Set, Value: Scalar{Kind: KindString, Text: "auto"}, Line: 2}, nil},
		{"empty alias is no deprecation", "[deploy]\nruntime = \"\"\n",
			Field{State: Set, Value: Scalar{Kind: KindString, Text: ""}, Line: 2}, nil},
		{"neither", "[deploy]\ngpu_count = 1\n", Field{}, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg, refusals := Decode([]byte(tc.src))

			if len(refusals) != 0 {
				t.Fatalf("Decode refusals = %+v, want none", refusals)
			}
			if cfg.Deploy.GPURuntime != tc.gpuRuntime {
				t.Errorf("Deploy.GPURuntime = %+v, want %+v", cfg.Deploy.GPURuntime, tc.gpuRuntime)
			}
			if !reflect.DeepEqual(cfg.Deprecated, tc.deprecated) {
				t.Errorf("Deprecated = %+v, want %+v", cfg.Deprecated, tc.deprecated)
			}
		})
	}
}

// Each decode owns its deprecations: mutating every one of the first
// decode's leaves a second and a third decode of the same bytes equal to
// what they were, so no deprecation is shared package state (base#1442
// design r4 cycle 12e).
func TestDecodeDeprecationsAreOwned(t *testing.T) {
	src := []byte("[deploy]\nruntime = \"nvidia\"\n")
	c1, _ := Decode(src)
	c2, _ := Decode(src)
	c3, _ := Decode(src)
	snap2 := append([]Deprecation{}, c2.Deprecated...)
	snap3 := append([]Deprecation{}, c3.Deprecated...)
	for i := range snap2 {
		snap2[i].Path = append([]string{}, snap2[i].Path...)
		snap2[i].Canonical = append([]string{}, snap2[i].Canonical...)
	}
	for i := range snap3 {
		snap3[i].Path = append([]string{}, snap3[i].Path...)
		snap3[i].Canonical = append([]string{}, snap3[i].Canonical...)
	}
	if len(c1.Deprecated) == 0 {
		t.Fatal("first decode has no deprecation to mutate")
	}
	for i := range c1.Deprecated {
		c1.Deprecated[i].Line = -1
		for j := range c1.Deprecated[i].Path {
			c1.Deprecated[i].Path[j] = "mutated"
		}
		for j := range c1.Deprecated[i].Canonical {
			c1.Deprecated[i].Canonical[j] = "mutated"
		}
	}
	if !reflect.DeepEqual(c2.Deprecated, snap2) || !reflect.DeepEqual(c3.Deprecated, snap3) {
		t.Errorf("after mutating decode 1: decode 2 = %+v, decode 3 = %+v; want %+v and %+v", c2.Deprecated, c3.Deprecated, snap2, snap3)
	}
}
