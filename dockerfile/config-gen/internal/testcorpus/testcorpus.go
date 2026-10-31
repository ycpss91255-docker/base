// Package testcorpus is the one reader of the module's shared test corpus
// (base#1468). Its root is set only at link time with
// -ldflags=-X=<module>/internal/testcorpus.root=<dir>; a build without it
// leaves root empty and every call refuses.
package testcorpus

import (
	"path/filepath"
	"strings"
	"testing"
)

// root is the corpus directory. It is unexported so that only the linker
// (-X) or this package can set it.
var root string

// Glob returns the corpus files that match pattern under root, as sorted
// paths joined to root. It calls t.Fatal when root was never set, when
// pattern is absolute or has a `..` element, when pattern is malformed,
// and when nothing matches, so a caller never loops over an empty result.
func Glob(t testing.TB, pattern string) []string {
	t.Helper()
	if root == "" {
		t.Fatalf("testcorpus: root is empty; cannot glob %q (build with -ldflags=-X=<module>/internal/testcorpus.root=<dir>)", pattern)
	}
	if filepath.IsAbs(pattern) {
		t.Fatalf("testcorpus: pattern %q is absolute; it must be relative to the corpus root", pattern)
	}
	for _, elem := range strings.Split(filepath.ToSlash(pattern), "/") {
		if elem == ".." {
			t.Fatalf("testcorpus: pattern %q has a `..` element; it must stay under the corpus root", pattern)
		}
	}
	got, err := filepath.Glob(filepath.Join(root, pattern))
	if err != nil {
		t.Fatalf("testcorpus: pattern %q is malformed: %v", pattern, err)
	}
	if len(got) == 0 {
		t.Fatalf("testcorpus: pattern %q matched no corpus file under %s", pattern, root)
	}
	return got
}
