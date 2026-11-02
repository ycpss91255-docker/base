package buildgate

import (
	"os"
	"reflect"
	"strings"
	"testing"
)

// The corpus sensitivity gate's inputs (base#1467).

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

func TestTraceOverlay(t *testing.T) {
	src := "package testcorpus\n\n// Glob doc.\nfunc Glob(t T, p string) []string { return Glob2(t, p) }\n\n" +
		"func (x X) Glob() {}\n\nfunc Glob2(t T, p string) []string { return nil }\n"
	want := "package testcorpus\n\n// Glob doc.\nfunc cgUntracedGlob(t T, p string) []string { return Glob2(t, p) }\n\n" +
		"func (x X) Glob() {}\n\nfunc Glob2(t T, p string) []string { return nil }\n"
	got, err := TraceOverlay([]byte(src))
	if err != nil {
		t.Fatalf("TraceOverlay: %v", err)
	}
	if string(got) != want {
		t.Errorf("TraceOverlay = %q, want %q", got, want)
	}
}

func TestTraceOverlayRefusesNoGlob(t *testing.T) {
	const refusal = "cg_event config_gen_corpus_sensitivity_invalid reason=glob_not_found"
	for _, c := range []struct{ name, src string }{
		{"no Glob", "package testcorpus\n\nfunc Other() {}\n"},
		{"a method only", "package testcorpus\n\nfunc (x X) Glob() {}\n"},
		{"two Globs", "package testcorpus\n\nfunc Glob() {}\n\nfunc Glob() {}\n"},
		{"does not parse", "package testcorpus\n\nfunc Glob( {\n"},
		{"not Go at all", ""},
		{"a var named it", "package testcorpus\n\nvar Glob = 1\n"},
	} {
		t.Run(c.name, func(t *testing.T) {
			got, err := TraceOverlay([]byte(c.src))
			if err == nil || err.Error() != refusal {
				t.Fatalf("TraceOverlay = %q, %v; want the refusal %q", got, err, refusal)
			}
		})
	}
}

func TestTraceSourceCallsTheRenamedGlob(t *testing.T) {
	if !reflect.DeepEqual(TracedGoldens(TraceSource, "x"), []string{}) {
		t.Fatal("TraceSource names a golden")
	}
	for _, want := range []string{"func Glob(t testing.TB, pattern string) []string",
		"got := cgUntracedGlob(t, pattern)", `os.Getenv("CG_TESTCORPUS_TRACE")`} {
		if !strings.Contains(TraceSource, want) {
			t.Errorf("TraceSource lacks %q", want)
		}
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
