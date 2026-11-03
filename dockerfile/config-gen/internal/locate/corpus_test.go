package locate

import (
	"io/fs"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/testcorpus"
)

// CorpusTOML is every .toml file under the corpus directory, at any depth,
// sorted (base#1442 AC "every corpus file"). The directory comes from
// testcorpus.Glob; the tree under it is listed here rather than matched by
// a pattern, so a fixture in a nested directory is never left out. It is
// exported from a test file so the locate_test package shares it.
func CorpusTOML(t testing.TB) []string {
	t.Helper()
	var got []string
	err := filepath.WalkDir(testcorpus.Glob(t, "corpus")[0], func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.Type().IsRegular() && strings.HasSuffix(p, ".toml") {
			got = append(got, p)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("list the corpus: %v", err)
	}
	if len(got) == 0 {
		t.Fatal("no corpus TOML file")
	}
	sort.Strings(got)
	return got
}
