// Package testcorpus is the one reader of the module's shared test corpus
// (base#1468). Its root is set only at link time with
// -ldflags=-X=<module>/internal/testcorpus.root=<dir>; a build without it
// leaves root empty and every call refuses.
package testcorpus

import (
	"io/fs"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// root is the corpus directory. It is unexported so that only the linker
// (-X) or this package can set it.
var root string

// Glob returns the corpus files that match pattern under root, as sorted
// paths joined to root. It calls t.Fatal when root was never set, when
// pattern is absolute or has a `..` element, when pattern is malformed,
// when nothing matches, so a caller never loops over an empty result, and
// when one basename appears in more than one corpus/s*/ slice.
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
	refuseRepeatedBasename(t)
	return got
}

// Files returns every file under root/corpus, at any depth, whose name
// ends in ext, as sorted paths joined to root (base#1442). It lists the
// tree rather than matching a pattern, so a fixture in a nested directory
// is never left out. It calls t.Fatal when root was never set, when the
// tree cannot be walked, when no file ends in ext, and when one basename
// appears twice anywhere under root/corpus.
func Files(t testing.TB, ext string) []string {
	t.Helper()
	if root == "" {
		t.Fatalf("testcorpus: root is empty; cannot list %q files (build with -ldflags=-X=<module>/internal/testcorpus.root=<dir>)", ext)
	}
	var got []string
	for _, p := range corpusFiles(t) {
		if strings.HasSuffix(p, ext) {
			got = append(got, p)
		}
	}
	if len(got) == 0 {
		t.Fatalf("testcorpus: no corpus file ends in %q under %s", ext, root)
	}
	refuseRepeatedBasename(t)
	return got
}

// corpusFiles is every regular file under root/corpus, at any depth,
// sorted.
func corpusFiles(t testing.TB) []string {
	t.Helper()
	var all []string
	err := filepath.WalkDir(filepath.Join(root, "corpus"), func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.Type().IsRegular() {
			all = append(all, p)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("testcorpus: cannot list %s/corpus: %v", root, err)
	}
	sort.Strings(all)
	return all
}

// refuseRepeatedBasename calls t.Fatal, naming both paths, when two files
// anywhere under root/corpus share a basename (base#1468, base#1442).
func refuseRepeatedBasename(t testing.TB) {
	t.Helper()
	all := corpusFiles(t)
	seen := make(map[string]string, len(all))
	for _, p := range all {
		base := filepath.Base(p)
		if first, ok := seen[base]; ok {
			t.Fatalf("testcorpus: basename %q is repeated: %s and %s", base, first, p)
		}
		seen[base] = p
	}
}
