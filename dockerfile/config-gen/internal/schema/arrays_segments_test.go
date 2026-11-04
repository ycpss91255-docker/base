package schema

import (
	"reflect"
	"testing"
)

// Two accepted families whose paths join to the same text stay two
// families: the typed model keeps each by its segments, so neither
// overwrites the other, and each is read back by its own path (base#1443
// review round 4 finding 1).
//
// Expected values: the body below decodes with no refusal on the branch
// at 00c8350b (both arrays pass the stage-array checks); the first array
// is the segments [stage:dev build args] holding key A on line 2, the
// second [stage:dev.build args] holding key B on line 4, and the text
// both join to names neither.
func TestDecodeKeepsFamiliesWhoseJoinedPathsCollideApart(t *testing.T) {
	body := "[\"stage:dev\".build]\nargs = [{key = \"A\"}]\n[\"stage:dev.build\"]\nargs = [{key = \"B\"}]\n"
	cfg, refusals := Decode([]byte(body))
	if len(refusals) != 0 || cfg == nil {
		t.Fatalf("Decode(%q) = %v, %+v, want a Config and no refusals", body, cfg, refusals)
	}

	for _, c := range []struct {
		path []string
		line int
		key  string
	}{
		{[]string{"stage:dev", "build", "args"}, 2, "A"},
		{[]string{"stage:dev.build", "args"}, 4, "B"},
	} {
		fam, ok := cfg.Array(c.path...)
		if !ok || fam.State != Set || len(fam.Entries) != 1 {
			t.Errorf("Array(%q) = %+v, %v; want a Set family of one entry", c.path, fam, ok)
			continue
		}
		if !reflect.DeepEqual(fam.Path, c.path) {
			t.Errorf("Array(%q).Path = %q, want %q", c.path, fam.Path, c.path)
		}
		e := fam.Entries[0]
		if e.Line != c.line {
			t.Errorf("Array(%q) entry line = %d, want %d", c.path, e.Line, c.line)
		}
		if got, want := entryFields(t, e), [][2]string{{"key", c.key}}; !reflect.DeepEqual(got, want) {
			t.Errorf("Array(%q) fields = %q, want %q", c.path, got, want)
		}
	}
	if len(cfg.Arrays) != 2 {
		t.Errorf("Arrays holds %d families, want 2: %+v", len(cfg.Arrays), cfg.Arrays)
	}
	if fam, ok := cfg.Array("stage:dev.build.args"); ok {
		t.Errorf("Array(%q) = %+v, want no family: the joined text is no path", "stage:dev.build.args", fam)
	}
}
