package testcorpus

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

// fatalSentinel is what fakeTB panics with on Fatal, so a test can stop
// Glob at the refusal and read the message it recorded (base#1468).
type fatalSentinel struct{}

// fakeTB records the first Fatal message instead of failing the real
// test, so a refusal is an observable value.
type fakeTB struct {
	testing.TB
	msg string
}

func (f *fakeTB) Helper() {}

func (f *fakeTB) Fatal(args ...any) {
	f.msg = fmt.Sprint(args...)
	panic(fatalSentinel{})
}

func (f *fakeTB) Fatalf(format string, args ...any) {
	f.msg = fmt.Sprintf(format, args...)
	panic(fatalSentinel{})
}

// callGlob runs Glob against the fake and reports whether it refused.
func callGlob(f *fakeTB, pattern string) (got []string, refused bool) {
	defer func() {
		if r := recover(); r != nil {
			if _, ok := r.(fatalSentinel); !ok {
				panic(r)
			}
			refused = true
		}
	}()
	return Glob(f, pattern), false
}

// An unset root is the build that skipped -ldflags -X: Glob must refuse
// it rather than read whatever sits beside the package (base#1468).
func TestGlobEmptyRoot(t *testing.T) {
	saved := root
	root = ""
	t.Cleanup(func() { root = saved })

	f := &fakeTB{TB: t}
	got, refused := callGlob(f, "*.toml")
	if !refused {
		t.Fatalf("Glob(%q) with an empty root returned %q, want a Fatal", "*.toml", got)
	}
	if !strings.Contains(f.msg, "root is empty") {
		t.Fatalf("Fatal message = %q, want it to contain %q", f.msg, "root is empty")
	}
}

// TestLinkerRoot runs against the root the build passed with -ldflags -X,
// not one set here, so a root fixed in source cannot satisfy it. The race
// gate moves testdata/ (holding corpus/s1/seed.toml) to that root
// (base#1468). A plain `go test` without -X fails here by design.
func TestLinkerRoot(t *testing.T) {
	got := Glob(t, "corpus/s1/*.toml")
	want := []string{filepath.Join(root, "corpus", "s1", "seed.toml")}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Glob(%q) = %q, want %q", "corpus/s1/*.toml", got, want)
	}
}

// A pattern Glob cannot serve is a refusal, never an empty result: an
// empty slice lets a table-driven test loop zero times and pass, and an
// absolute or `..` pattern escapes the corpus root (base#1468). Each
// message has to name the pattern so the failing caller is findable.
func TestGlobRefusesBadPattern(t *testing.T) {
	saved := root
	root = t.TempDir()
	t.Cleanup(func() { root = saved })
	if err := os.MkdirAll(filepath.Join(root, "corpus", "s1"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "corpus", "s1", "seed.toml"), []byte("x = 1\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	for _, pattern := range []string{"corpus/s1/*.none", "/abs", "../x", "["} {
		t.Run(pattern, func(t *testing.T) {
			f := &fakeTB{TB: t}
			got, refused := callGlob(f, pattern)
			if !refused {
				t.Fatalf("Glob(%q) returned %q, want a Fatal", pattern, got)
			}
			if !strings.Contains(f.msg, strconv.Quote(pattern)) {
				t.Fatalf("Fatal message = %q, want it to name the pattern %q", f.msg, pattern)
			}
		})
	}
}

// One basename names one corpus file across every slice: a.toml in both
// corpus/s1 and corpus/s2 is refused even when the pattern matches only
// s1, so the check cannot be scoped to the matched directory. The message
// names both paths so the duplicate is findable (base#1468).
func TestGlobRefusesRepeatedBasename(t *testing.T) {
	saved := root
	root = t.TempDir()
	t.Cleanup(func() { root = saved })
	s1 := filepath.Join(root, "corpus", "s1", "a.toml")
	s2 := filepath.Join(root, "corpus", "s2", "a.toml")
	for _, p := range []string{s1, s2} {
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("x = 1\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	f := &fakeTB{TB: t}
	got, refused := callGlob(f, "corpus/s1/*.toml")
	if !refused {
		t.Fatalf("Glob(%q) with a.toml in s1 and s2 returned %q, want a Fatal", "corpus/s1/*.toml", got)
	}
	for _, p := range []string{s1, s2} {
		if !strings.Contains(f.msg, p) {
			t.Fatalf("Fatal message = %q, want it to name %q", f.msg, p)
		}
	}
}
