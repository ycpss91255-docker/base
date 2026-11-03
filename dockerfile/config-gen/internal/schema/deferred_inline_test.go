package schema

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// An inline array of tables at a known section name
// (`volumes = [{...}, {...}]`) is the legacy spelling the array stage
// owns, like `[[volumes]]`: it is deferred, and the keys inside its
// elements are not looked up in the [volumes] schema (base#1442, design
// r4 cycle 12e, whose s6_def_inline fixtures decode with zero refusals).
//
// Expected values: the bridge accepts both files, `--kv` rc 0 with
// `volumes mount_1 /s:/t` / `volumes mount_2 /u` and `volumes mount_1 /s`
// / `volumes mount_2 /u:/t` (p1442d bridge_d1.out, bridge_d2.out); the
// type is the library's md.Type for an inline array, Array (design r4
// cycle 12e (g)); the line is counted from the fixture bytes, the whole
// array is on line 1.
func TestDecodeInlineArrayAtKnownSectionIsDeferred(t *testing.T) {
	files := testcorpus.Glob(t, "corpus/s6/s6_def_inline*.toml")
	if len(files) != 2 {
		t.Fatalf("Glob = %v, want s6_def_inline.toml and s6_def_inline2.toml", files)
	}
	for _, file := range files {
		name := filepath.Base(file)
		src, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}

		cfg, refusals := Decode(src)

		if len(refusals) != 0 {
			t.Errorf("%s: Decode refusals = %+v, want none", name, refusals)
		}
		if cfg == nil {
			t.Fatalf("%s: Decode returned no Config", name)
		}
		type head struct {
			Path []string
			Type string
			Line int
		}
		var got []head
		for _, d := range cfg.Deferred {
			got = append(got, head{d.Path, d.Type, d.Line})
		}
		if want := []head{{[]string{"volumes"}, "Array", 1}}; !reflect.DeepEqual(got, want) {
			t.Errorf("%s: Deferred = %+v, want %+v", name, got, want)
		}
	}
}
