package testcorpus

import (
	"fmt"
	"path/filepath"
	"reflect"
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
