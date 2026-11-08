package buildgate

import (
	"os"
	"reflect"
	"testing"
)

// The corpus sensitivity gate's inputs (base#1467). The traced
// testcorpus build is judged by what the gate's own command does with it
// (cmd/cg-gates TestSensitivity and TestSensitivityWithTheGoToolchain),
// not here.

// The fixture's test binaries that depend on testcorpus are b.test,
// d.test and testcorpus.test (see fixtureModule).
func TestCorpusImporters(t *testing.T) {
	body, err := os.ReadFile("testdata/golist-testcorpus.json")
	if err != nil {
		t.Fatal(err)
	}
	pkgs, err := DecodeList(body)
	if err != nil {
		t.Fatalf("DecodeList: %v", err)
	}
	want := []string{"internal/b", "internal/d", "internal/testcorpus"}
	if got := CorpusImporters(fixtureModule, pkgs); !reflect.DeepEqual(got, want) {
		t.Errorf("CorpusImporters = %q, want %q", got, want)
	}
	if got := CorpusImporters(fixtureModule, nil); !reflect.DeepEqual(got, []string{}) {
		t.Errorf("CorpusImporters of no package = %q, want none", got)
	}
}

func TestTracedGoldens(t *testing.T) {
	trace := "/r/golden/s1/b.golden\n/r/corpus/s1/seed.toml\n/r/golden/s1/a.golden\n" +
		"/tmp/x/golden/s1/a.golden\n/r/golden/s1/b.golden\n/rr/golden/s1/c.golden\n\n"
	want := []string{"golden/s1/a.golden", "golden/s1/b.golden"}
	if got := TracedGoldens(trace, "/r"); !reflect.DeepEqual(got, want) {
		t.Errorf("TracedGoldens = %q, want %q", got, want)
	}
}

func TestSensitivityWeak(t *testing.T) {
	want := "cg_event config_gen_corpus_sensitivity_weak pkg=m/internal/a file=golden/s1/a%20b.golden"
	if got := SensitivityWeak("m/internal/a", "golden/s1/a b.golden").String(); got != want {
		t.Errorf("SensitivityWeak = %q, want %q", got, want)
	}
}

func TestSensitivityInvalid(t *testing.T) {
	want := "cg_event config_gen_corpus_sensitivity_invalid reason=glob_not_found"
	if got := SensitivityInvalid().String(); got != want {
		t.Errorf("SensitivityInvalid = %q, want %q", got, want)
	}
}
