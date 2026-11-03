package buildgate

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"reflect"
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

// TraceOverlay changes exactly one identifier: the name of the one
// top-level func Glob, to a name no top-level declaration of the source
// holds. Its doc, signature and body, a method named Glob and every other
// declaration stay byte for byte. The new name is not this test's
// business: that the traced Glob reaches the renamed one, and that a
// consumer's reads are attributed through it, is what
// TestSensitivityWithTheGoToolchain (cmd/cg-gates) runs through the gate's
// own command.
func TestTraceOverlay(t *testing.T) {
	src := "package testcorpus\n\n// Glob doc.\nfunc Glob(t T, p string) []string { return Glob2(t, p) }\n\n" +
		"func (x X) Glob() {}\n\nfunc Glob2(t T, p string) []string { return nil }\n"
	got, err := TraceOverlay([]byte(src))
	if err != nil {
		t.Fatalf("TraceOverlay: %v", err)
	}
	before, after := topFuncs(t, src), topFuncs(t, string(got))
	if len(after) != len(before) {
		t.Fatalf("TraceOverlay = %q: %d top-level funcs, want %d", got, len(after), len(before))
	}
	renamed := 0
	for i, b := range before {
		a := after[i]
		if b.name != "Glob" || b.method {
			continue
		}
		renamed++
		for _, o := range before {
			if !o.method && o.name == a.name {
				t.Errorf("TraceOverlay renamed Glob to %q, a name the source already holds", a.name)
			}
		}
		back := string(got[:a.at]) + "Glob" + string(got[a.at+len(a.name):])
		if back != src {
			t.Errorf("TraceOverlay = %q: more than Glob's name changed", got)
		}
	}
	if renamed != 1 {
		t.Fatalf("the source holds %d top-level func Glob, want 1", renamed)
	}
	for _, a := range after {
		if a.name == "Glob" && !a.method {
			t.Errorf("TraceOverlay = %q still holds a top-level func Glob", got)
		}
	}
}

// topFunc is one func declaration: its name, the byte offset of the name,
// and whether it has a receiver.
type topFunc struct {
	name   string
	at     int
	method bool
}

// topFuncs returns src's func declarations in source order.
func topFuncs(t *testing.T, src string) []topFunc {
	t.Helper()
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "x.go", src, 0)
	if err != nil {
		t.Fatalf("parse %q: %v", src, err)
	}
	out := []topFunc{}
	for _, d := range f.Decls {
		if fd, ok := d.(*ast.FuncDecl); ok {
			out = append(out, topFunc{fd.Name.Name, fset.Position(fd.Name.Pos()).Offset, fd.Recv != nil})
		}
	}
	return out
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
