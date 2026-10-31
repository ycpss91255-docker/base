// Package testcorpus is the one reader of the module's shared test corpus
// (base#1468). Its root is set only at link time with
// -ldflags=-X=<module>/internal/testcorpus.root=<dir>; a build without it
// leaves root empty and every call refuses.
package testcorpus

import (
	"path/filepath"
	"testing"
)

// root is the corpus directory. It is unexported so that only the linker
// (-X) or this package can set it.
var root string

// Glob returns the corpus files that match pattern under root, as sorted
// paths joined to root. It calls t.Fatal when root was never set.
func Glob(t testing.TB, pattern string) []string {
	t.Helper()
	if root == "" {
		t.Fatalf("testcorpus: root is empty; cannot glob %q (build with -ldflags=-X=<module>/internal/testcorpus.root=<dir>)", pattern)
	}
	got, _ := filepath.Glob(filepath.Join(root, pattern))
	return got
}
