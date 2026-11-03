package schema

import "testing"

// TestDecodeEnvironmentTablePresence checks that the decoded [environment]
// table has three observable states (base#1309, base#1442 design r4 cycle
// 13): a layer with no [environment] header gives Table.State Absent; a
// bare `[environment]` header gives Empty, a table that is written but
// holds no key; a header with `env_1 = "A=b"` gives Set and the key in
// Env. A field-less `[[volumes]]` beside the bare header stays legal: it
// is deferred with no refusal and the table stays Empty.
//
// Expected values: the real bridge prints no `--kv` row for a bare
// `[environment]` while its `--tables` lists `environment` (design r4
// section 1d, env_empty: `--kv rc=0 (no row)`, `--tables rc=0
// environment`), so the shell sees the table but no key; the library
// reports md.IsDefined("environment") true for the bare header and false
// when it is absent (design r4 section 1d). Lines are counted from the
// input bytes.
func TestDecodeEnvironmentTablePresence(t *testing.T) {
	cases := []struct {
		name     string
		src      string
		state    State
		env      map[string]Field
		deferred int
	}{
		{name: "absent", src: "[deploy]\ngpu_count = \"all\"\n", state: Absent},
		{name: "empty", src: "[environment]\n", state: Empty},
		{
			name:  "set",
			src:   "[environment]\nenv_1 = \"A=b\"\n",
			state: Set,
			env:   map[string]Field{"env_1": {State: Set, Value: Scalar{Kind: KindString, Text: "A=b"}, Line: 2}},
		},
		{name: "empty_beside_fieldless_aot", src: "[environment]\n\n[[volumes]]\n", state: Empty, deferred: 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg, refusals := Decode([]byte(tc.src))

			if len(refusals) != 0 {
				t.Fatalf("Decode refusals = %d (%+v), want none", len(refusals), refusals)
			}
			if got := cfg.Environment.Table.State; got != tc.state {
				t.Errorf("Environment.Table.State = %v, want %v", got, tc.state)
			}
			if len(cfg.Environment.Env) != len(tc.env) {
				t.Errorf("Environment.Env = %+v, want %+v", cfg.Environment.Env, tc.env)
			}
			for k, want := range tc.env {
				if got := cfg.Environment.Env[k]; got != want {
					t.Errorf("Environment.Env[%q] = %+v, want %+v", k, got, want)
				}
			}
			if len(cfg.Deferred) != tc.deferred {
				t.Errorf("Deferred = %d (%+v), want %d", len(cfg.Deferred), cfg.Deferred, tc.deferred)
			}
		})
	}
}
