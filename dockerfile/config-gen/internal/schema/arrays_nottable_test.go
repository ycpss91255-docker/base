package schema

import (
	"os"
	"reflect"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// An element of a family array that is a scalar, not a table, is refused
// with conf_entry_not_table, once, on the line the element is written
// (base#1443, design r1 cycle 4). A string is not read as a cleared slot.
// Every row exercises that one rule: each fixture's refused element is a
// bare scalar, and a table element beside it is not refused.
//
// Expected values: the real bridge refuses each fixture, `--kv` rc 1,
// "entry <n> of <path> is <repr>, not a table" (scratchpad
// s7c3-bridge.out; s7d1 f07 for volumes); the path is the bridge's <path>
// split on "."; the line is counted from the fixture bytes, the line the
// refused element is written on (entry 2 of s7_nottable_second.toml is
// on line 3).
func TestDecodeEntryNotTableIsRefused(t *testing.T) {
	cases := []struct {
		file string
		path []string
		line int
	}{
		{"s7_nottable_string.toml", []string{"volumes"}, 1},
		{"s7_nottable_int.toml", []string{"tmpfs"}, 1},
		{"s7_nottable_args.toml", []string{"build", "args"}, 2},
		// entry 2 of 2: entry 1 is a table carrying source, not refused.
		{"s7_nottable_second.toml", []string{"volumes"}, 3},
	}
	for _, c := range cases {
		t.Run(c.file, func(t *testing.T) {
			files := testcorpus.Glob(t, "corpus/s7/"+c.file)
			if len(files) != 1 {
				t.Fatalf("Glob = %v, want %s", files, c.file)
			}
			src, err := os.ReadFile(files[0])
			if err != nil {
				t.Fatal(err)
			}

			_, refusals := Decode(src)

			if len(refusals) != 1 {
				t.Fatalf("Decode refusals = %+v, want exactly one", refusals)
			}
			r := refusals[0]
			if r.Event != "conf_entry_not_table" {
				t.Errorf("Event = %q, want conf_entry_not_table", r.Event)
			}
			if !reflect.DeepEqual(r.Path, c.path) {
				t.Errorf("Path = %q, want %q", r.Path, c.path)
			}
			if r.Line != c.line {
				t.Errorf("Line = %d, want %d", r.Line, c.line)
			}
		})
	}
}

// An element of a family array that is not a table is no entry of the
// typed family: `args = [1, { key = "A" }]` types build.args with the
// one table element as its one entry (base#1443 review round 1, verify
// finding 4). The scalar is refused as conf_entry_not_table, entry 1,
// as the bridge's `--kv` refuses it, "entry 1 of build.args is 1, not a
// table" (dockerfile/toml_bridge.py run with tomli). The bridge refuses
// the file, so the family the decode types is not compared with any
// bridge output: an entry is numbered within the typed family, and the
// line is counted from the fixture bytes.
func TestDecodeFamilyTypesOnlyItsTableElements(t *testing.T) {
	files := testcorpus.Glob(t, "corpus/s7/s7_nottable_first.toml")
	if len(files) != 1 {
		t.Fatalf("Glob = %v, want s7_nottable_first.toml", files)
	}
	src, err := os.ReadFile(files[0])
	if err != nil {
		t.Fatal(err)
	}

	cfg, refusals := Decode(src)

	wantRefusals := []Refusal{{Event: "conf_entry_not_table", Path: []string{"build", "args"}, Line: 2, Col: 9, Entry: 1}}
	if !reflect.DeepEqual(refusals, wantRefusals) {
		t.Errorf("Decode refusals = %+v, want %+v", refusals, wantRefusals)
	}
	if cfg == nil {
		t.Fatal("Decode returned no Config")
	}
	fam, ok := cfg.Array("build", "args")
	if !ok {
		t.Fatalf("Arrays = %+v, want a build.args family", cfg.Arrays)
	}
	want := Family{
		Path:  []string{"build", "args"},
		State: Set,
		Line:  2,
		Entries: []Entry{{
			Index:  1,
			Line:   2,
			Fields: []EntryField{{Key: "key", Value: Value{Kind: VScalar, Scalar: Scalar{Kind: KindString, Text: "A"}, Line: 2}}},
		}},
	}
	if !reflect.DeepEqual(fam, want) {
		t.Errorf("build.args = %+v, want %+v", fam, want)
	}
}
