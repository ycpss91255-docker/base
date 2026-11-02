package testcorpus

import (
	"fmt"
	"os"
	"os/exec"
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

// An empty root makes Glob refuse rather than read whatever sits beside
// the package (base#1468). This checks the refusal branch in process; the
// configuration that leaves root empty, a build without -ldflags -X, is
// TestGlobWithoutLinkerRoot.
func TestGlobRefusesEmptyRoot(t *testing.T) {
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

// noLinkerChildEnv marks the child process TestGlobWithoutLinkerRoot
// starts; only that child runs TestGlobNoLinkerChild.
const noLinkerChildEnv = "TESTCORPUS_NO_LINKER_CHILD"

// A build without -ldflags -X must leave root empty, so Glob refuses it
// (base#1468). The running binary was linked with -X, so this builds and
// runs the package again in a child `go test` that is given no -ldflags
// and no GOFLAGS, and never assigns root: whatever value the source gives
// root is what the child sees. A nonempty initializer in source fails
// here even though TestLinkerRoot, whose -X overrides it, still passes.
func TestGlobWithoutLinkerRoot(t *testing.T) {
	if os.Getenv(noLinkerChildEnv) == "1" {
		t.Skip("running as the no-linker child")
	}
	cmd := exec.Command("go", "test", "-count=1", "-run", "^TestGlobNoLinkerChild$", "-v", ".")
	cmd.Env = append(withoutEnv(os.Environ(), "GOFLAGS"), noLinkerChildEnv+"=1", "GOFLAGS=")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("no-linker child failed: %v\n%s", err, out)
	}
	if !strings.Contains(string(out), "--- PASS: TestGlobNoLinkerChild") {
		t.Fatalf("no-linker child did not run TestGlobNoLinkerChild:\n%s", out)
	}
}

// TestGlobNoLinkerChild runs only inside the child that
// TestGlobWithoutLinkerRoot builds without -X. It leaves root as the
// source set it and requires the empty-root refusal.
func TestGlobNoLinkerChild(t *testing.T) {
	if os.Getenv(noLinkerChildEnv) != "1" {
		t.Skip("runs only as the child of TestGlobWithoutLinkerRoot")
	}
	f := &fakeTB{TB: t}
	got, refused := callGlob(f, "corpus/s1/*.toml")
	if !refused {
		t.Fatalf("Glob(%q) in a build without -X returned %q, want a Fatal", "corpus/s1/*.toml", got)
	}
	if !strings.Contains(f.msg, "root is empty") {
		t.Fatalf("Fatal message = %q, want it to contain %q", f.msg, "root is empty")
	}
}

// withoutEnv returns env minus every entry for key.
func withoutEnv(env []string, key string) []string {
	out := make([]string, 0, len(env))
	for _, kv := range env {
		if !strings.HasPrefix(kv, key+"=") {
			out = append(out, kv)
		}
	}
	return out
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
//
// The absolute and `..` patterns each resolve to the existing seed file
// once joined to root, so without its own guard each would match and be
// returned: neither the zero-match guard nor the malformed-pattern guard
// can stand in for the containment guards.
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

	for _, pattern := range []string{
		"corpus/s1/*.none",
		"/corpus/s1/seed.toml",
		"corpus/../corpus/s1/seed.toml",
		"../" + filepath.Base(root) + "/corpus/s1/seed.toml",
		"[",
	} {
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

// callFiles runs Files against the fake and reports whether it refused.
func callFiles(f *fakeTB, ext string) (got []string, refused bool) {
	defer func() {
		if r := recover(); r != nil {
			if _, ok := r.(fatalSentinel); !ok {
				panic(r)
			}
			refused = true
		}
	}()
	return Files(f, ext), false
}

// plant writes each path, relative to a fresh root, and points root at it
// for the rest of the test.
func plant(t *testing.T, paths ...string) {
	t.Helper()
	saved := root
	root = t.TempDir()
	t.Cleanup(func() { root = saved })
	for _, p := range paths {
		full := filepath.Join(root, p)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte("x = 1\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// Files lists the corpus tree, not a pattern: a file at any depth under
// corpus/ whose name ends in ext is returned, sorted, and nothing else is
// (base#1442). A one-level glob would miss corpus/s6/sections/b.toml.
func TestFilesListsEveryDepth(t *testing.T) {
	plant(t, "corpus/s6/sections/b.toml", "corpus/s1/seed.toml", "corpus/s6/a.toml", "corpus/s6/t.tsv", "corpus/s6/sections/deep/c.toml")
	f := &fakeTB{TB: t}
	got, refused := callFiles(f, ".toml")
	if refused {
		t.Fatalf("Files(.toml) refused: %s", f.msg)
	}
	var want []string
	for _, p := range []string{"corpus/s1/seed.toml", "corpus/s6/a.toml", "corpus/s6/sections/b.toml", "corpus/s6/sections/deep/c.toml"} {
		want = append(want, filepath.Join(root, p))
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Files(.toml) = %q, want %q", got, want)
	}
}

// Files refuses rather than return nothing: with no root, with no corpus
// directory, with no file ending in ext, and with one basename at two
// depths of the tree, naming both paths (base#1442, base#1468).
func TestFilesRefuses(t *testing.T) {
	t.Run("empty root", func(t *testing.T) {
		saved := root
		root = ""
		t.Cleanup(func() { root = saved })
		if got, refused := callFiles(&fakeTB{TB: t}, ".toml"); !refused {
			t.Fatalf("Files with an empty root returned %q, want a Fatal", got)
		}
	})
	t.Run("no corpus directory", func(t *testing.T) {
		plant(t)
		if got, refused := callFiles(&fakeTB{TB: t}, ".toml"); !refused {
			t.Fatalf("Files with no corpus directory returned %q, want a Fatal", got)
		}
	})
	t.Run("no match", func(t *testing.T) {
		plant(t, "corpus/s1/seed.toml")
		f := &fakeTB{TB: t}
		if got, refused := callFiles(f, ".none"); !refused || !strings.Contains(f.msg, `".none"`) {
			t.Fatalf("Files(.none) = %q, Fatal %q; want a Fatal naming the extension", got, f.msg)
		}
	})
	t.Run("repeated basename at depth", func(t *testing.T) {
		plant(t, "corpus/s1/a.toml", "corpus/s6/sections/a.toml")
		f := &fakeTB{TB: t}
		got, refused := callFiles(f, ".toml")
		if !refused {
			t.Fatalf("Files with a.toml in s1 and s6/sections returned %q, want a Fatal", got)
		}
		for _, p := range []string{"corpus/s1/a.toml", "corpus/s6/sections/a.toml"} {
			if !strings.Contains(f.msg, filepath.Join(root, p)) {
				t.Fatalf("Fatal message = %q, want it to name %s", f.msg, p)
			}
		}
	})
}
