package schema

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// The members of an inline table inside a deferred array keep the order
// they are written in, so the array stage reads each element's keys the
// way the bridge's _emit_entries walks elem.items() (toml_bridge.py line 755)
// (base#1442, design r4 cycle 12e (c)).
//
// Expected values: the bridge's `--entries` rows for the same bytes
// (p1442d bridge_d1.out, bridge_d2.out, rc 0). s6_def_inline.toml gives
// `volumes 1 [[volumes]] target /t`, `volumes 1 [[volumes]] source /s`,
// `volumes 2 [[volumes]] source /u`; s6_def_inline2.toml gives
// `volumes 1 [[volumes]] source /s`, `volumes 2 [[volumes]] target /t`,
// `volumes 2 [[volumes]] source /u`.
func TestDecodeInlineArrayKeepsMemberOrder(t *testing.T) {
	want := map[string][][]string{
		"s6_def_inline.toml":  {{"target", "/t", "source", "/s"}, {"source", "/u"}},
		"s6_def_inline2.toml": {{"source", "/s"}, {"target", "/t", "source", "/u"}},
	}
	files := testcorpus.Glob(t, "corpus/s6/s6_def_inline*.toml")
	if len(files) != len(want) {
		t.Fatalf("Glob = %v, want the %d files of %v", files, len(want), want)
	}
	for _, file := range files {
		name := filepath.Base(file)
		src, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}

		cfg, refusals := Decode(src)

		if len(refusals) != 0 || cfg == nil || len(cfg.Deferred) != 1 {
			t.Fatalf("%s: Decode = %+v, %+v; want one Deferred and no refusal", name, cfg, refusals)
		}
		var got [][]string
		for _, item := range cfg.Deferred[0].Value.Items {
			var fields []string
			for _, m := range item.Members {
				fields = append(fields, m.Key, m.Value.Scalar.Text)
			}
			got = append(got, fields)
		}
		if !reflect.DeepEqual(got, want[name]) {
			t.Errorf("%s: element members = %q, want %q", name, got, want[name])
		}
	}
}
