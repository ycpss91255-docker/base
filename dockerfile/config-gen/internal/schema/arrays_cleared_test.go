package schema

import (
	"os"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// A field-less `[[volumes]]` is the cleared slot: the decode accepts it
// and types it as the volumes family, Set, with exactly one entry that
// carries no field, kept at its own position (base#1443, design r1
// cycle 1). An untyped Deferred payload alone is not enough.
//
// Expected values: the real bridge accepts the file, `--kv` rc 0 with the
// one row `volumes mount_1 ""` (s7d1 bridge.out, f01_cleared.toml), so
// the family holds one entry and that entry has no field; the entry is
// the bridge's first, index 1; the line is counted from the fixture
// bytes, the header is on line 1.
func TestDecodeClearedSlotIsOneEmptyEntry(t *testing.T) {
	files := testcorpus.Glob(t, "corpus/s7/s7_cleared.toml")
	if len(files) != 1 {
		t.Fatalf("Glob = %v, want s7_cleared.toml", files)
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
	fam, ok := arrayAt(cfg, "volumes")
	if !ok {
		t.Fatalf("Arrays = %+v, want a volumes family", cfg.Arrays)
	}
	if fam.State != Set {
		t.Errorf("volumes State = %v, want Set", fam.State)
	}
	if fam.Line != 1 {
		t.Errorf("volumes Line = %d, want 1", fam.Line)
	}
	if len(fam.Entries) != 1 {
		t.Fatalf("volumes Entries = %+v, want exactly one", fam.Entries)
	}
	e := fam.Entries[0]
	if e.Index != 1 || e.Line != 1 {
		t.Errorf("entry = {Index %d, Line %d}, want {Index 1, Line 1}", e.Index, e.Line)
	}
	if len(e.Fields) != 0 {
		t.Errorf("entry Fields = %+v, want none", e.Fields)
	}
	if !e.Cleared() {
		t.Error("entry Cleared() = false, want true")
	}
}
