package schema

import (
	"os"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// One layer that writes both devices.bindings and devices.cgroup_rules,
// their blocks interleaved, keeps two independent families: each holds
// its own entries, in its own written order, numbered from 1, and
// neither is merged into the other or into the legacy `devices` family
// (base#1443 review round 2 finding 3).
//
// Expected values: main's toml_bridge.py `--kv` on s7_devices_both.toml
// (scratchpad r2/bridge.out), rc 0 with exactly [bridge]:
//
//	devices device_1      /dev/a
//	devices device_2      /dev/b
//	devices cgroup_rule_1 c 1:1 rwm
//	devices cgroup_rule_2 c 2:2 r
//
// The block headers are on lines 1, 4, 7 and 10 of the fixture [lit].
func TestDevicesBindingsAndCgroupRulesAreIndependentInOneLayer(t *testing.T) {
	files := testcorpus.Glob(t, "corpus/s7/s7_devices_both.toml")
	if len(files) != 1 {
		t.Fatalf("Glob = %v, want s7_devices_both.toml", files)
	}
	src, err := os.ReadFile(files[0])
	if err != nil {
		t.Fatal(err)
	}
	cfg, refusals := Decode(src)
	if len(refusals) != 0 || cfg == nil {
		t.Fatalf("Decode = %v, %+v, want a Config and no refusals", cfg, refusals)
	}
	if fam, ok := cfg.Arrays["devices"]; ok {
		t.Errorf("Arrays[devices] = %+v, want no legacy family", fam)
	}

	type want struct {
		index, line int
		key, text   string
	}
	for path, entries := range map[string][]want{
		"devices.bindings":     {{1, 1, "path", "/dev/a"}, {2, 7, "path", "/dev/b"}},
		"devices.cgroup_rules": {{1, 4, "rule", "c 1:1 rwm"}, {2, 10, "rule", "c 2:2 r"}},
	} {
		fam, ok := cfg.Arrays[path]
		if !ok || fam.State != Set || len(fam.Entries) != len(entries) {
			t.Errorf("Arrays[%s] = %+v, want a Set family of %d entries", path, fam, len(entries))
			continue
		}
		for i, w := range entries {
			e := fam.Entries[i]
			if e.Index != w.index || e.Line != w.line {
				t.Errorf("%s entry %d = {Index %d, Line %d}, want {Index %d, Line %d}",
					path, i+1, e.Index, e.Line, w.index, w.line)
			}
			if got := entryFields(t, e); len(got) != 1 || got[0] != [2]string{w.key, w.text} {
				t.Errorf("%s entry %d fields = %q, want [%s %q]", path, i+1, got, w.key, w.text)
			}
		}
	}

	// The shell names those entries by these addresses; each resolves to
	// its own family's entry.
	for addr, text := range map[string]string{
		"devices.device_1":      "/dev/a",
		"devices.device_2":      "/dev/b",
		"devices.cgroup_rule_1": "c 1:1 rwm",
		"devices.cgroup_rule_2": "c 2:2 r",
	} {
		a, err := ParseAddress(addr)
		if err != nil {
			t.Fatalf("ParseAddress(%q) error = %v", addr, err)
		}
		e, err := cfg.Entry(a)
		if err != nil || e == nil {
			t.Errorf("Entry(%q) = %v, %v, want the entry", addr, e, err)
			continue
		}
		if got := entryFields(t, *e); len(got) != 1 || got[0][1] != text {
			t.Errorf("Entry(%q) fields = %q, want the text %q", addr, got, text)
		}
	}
}
