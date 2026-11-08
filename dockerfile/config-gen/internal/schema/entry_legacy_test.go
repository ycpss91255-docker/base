package schema

import "testing"

// (*Config).Entry resolves `devices.device_N` on a layer that writes only
// the legacy `[[devices]]` spelling to entry N of that legacy family: the
// devices.bindings home, numbered under the same prefix and listed first,
// is not in the layer, so it is passed over rather than answered with
// an out-of-range refusal (base#1443 review round 3, guard record:
// Entry passes over a home the layer does not carry).
//
// Expected values: the worktree's toml_bridge.py `--kv` on the body
// below gives rc 0 and exactly [bridge]:
//
//	devices device_1 /dev/x
//	devices device_2 /dev/y
//
// so `devices.device_2` names the second `[[devices]]` block, whose
// header is on line 4 of the body [lit].
func TestConfigEntryResolvesTheLegacyDevicesHome(t *testing.T) {
	src := "[[devices]]\npath = \"/dev/x\"\n\n[[devices]]\npath = \"/dev/y\"\n"
	cfg, refusals := Decode([]byte(src))
	if len(refusals) != 0 || cfg == nil {
		t.Fatalf("Decode = %v, %+v, want a Config and no refusals", cfg, refusals)
	}
	a, err := ParseAddress("devices.device_2")
	if err != nil {
		t.Fatalf("ParseAddress error = %v", err)
	}

	e, err := cfg.Entry(a)

	if err != nil || e == nil {
		t.Fatalf("Entry(devices.device_2) = %v, %v; want the second [[devices]] entry", e, err)
	}
	if e.Index != 2 || e.Line != 4 || len(e.Fields) != 1 || e.Fields[0].Key != "path" || e.Fields[0].Value.Scalar.Text != "/dev/y" {
		t.Errorf("Entry(devices.device_2) = %+v, want {Index 2, Line 4, [path=/dev/y]}", *e)
	}
}
