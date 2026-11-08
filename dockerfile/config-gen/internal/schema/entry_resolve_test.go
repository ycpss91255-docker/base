package schema

import (
	"os"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// (*Config).Entry resolves a well-formed shell address to the entry of
// the decoded layer that the shell writes under that name: entry N of
// the family whose home the section and prefix name, counted in written
// order with the cleared slot kept in its position (base#1443, design r1
// cycle 17, design-r3 row 21).
//
// Expected values: the real bridge, `--kv` on s7_cleared_mid.toml
// (s7d1 bridge.out, f15_cleared_mid.toml), rc 0 with the rows
// [bridge]:
//
//	volumes mount_1 /a
//	volumes mount_2 ""
//	volumes mount_3 /c
//
// so `volumes.mount_N` names the N-th `[[volumes]]` block. Each entry's
// line is counted from the fixture bytes, the headers are on lines 1, 4
// and 6 [lit].
func TestConfigEntryResolvesAddress(t *testing.T) {
	files := testcorpus.Glob(t, "corpus/s7/s7_cleared_mid.toml")
	if len(files) != 1 {
		t.Fatalf("Glob = %v, want s7_cleared_mid.toml", files)
	}
	src, err := os.ReadFile(files[0])
	if err != nil {
		t.Fatal(err)
	}
	cfg, refusals := Decode(src)
	if len(refusals) != 0 || cfg == nil {
		t.Fatalf("Decode = %v, %+v, want a Config and no refusals", cfg, refusals)
	}

	for _, tc := range []struct {
		addr   string
		index  int
		line   int
		source string // "" with cleared: the entry carries no field
		clear  bool
	}{
		{addr: "volumes.mount_1", index: 1, line: 1, source: "/a"},
		{addr: "volumes.mount_2", index: 2, line: 4, clear: true},
		{addr: "volumes.mount_3", index: 3, line: 6, source: "/c"},
	} {
		a, err := ParseAddress(tc.addr)
		if err != nil {
			t.Fatalf("ParseAddress(%q) error = %v", tc.addr, err)
		}
		e, err := cfg.Entry(a)
		if err != nil {
			t.Errorf("Entry(%q) error = %v, want the entry", tc.addr, err)
			continue
		}
		if e == nil {
			t.Errorf("Entry(%q) = nil, want the entry", tc.addr)
			continue
		}
		if e.Index != tc.index || e.Line != tc.line {
			t.Errorf("Entry(%q) = {Index %d, Line %d}, want {Index %d, Line %d}",
				tc.addr, e.Index, e.Line, tc.index, tc.line)
		}
		if tc.clear {
			if !e.Cleared() {
				t.Errorf("Entry(%q) Fields = %+v, want the cleared slot", tc.addr, e.Fields)
			}
			continue
		}
		if len(e.Fields) != 1 || e.Fields[0].Key != "source" || e.Fields[0].Value.Scalar.Text != tc.source {
			t.Errorf("Entry(%q) Fields = %+v, want [source=%q]", tc.addr, e.Fields, tc.source)
		}
	}
}
