package buildgate

import (
	"sort"
	"strings"
)

// The corpus sensitivity gate's inputs (base#1467): which packages read
// the shared corpus, which golden files a traced run of each was handed,
// and the events the gate prints. The traced build of internal/testcorpus
// itself is cmd/cg-gates' own.

// CorpusImporters returns, sorted, the module-relative directory (`.` for
// the root) of every package whose test binary depends on
// internal/testcorpus, read from
// `go list -json -test -deps ./...` of the module.
func CorpusImporters(module string, pkgs []Package) []string {
	corpus := module + "/" + testcorpus
	out := []string{}
	for _, p := range pkgs {
		under, ok := strings.CutSuffix(p.ImportPath, ".test")
		if !ok {
			continue
		}
		rel, ok := moduleDir(module, under)
		if !ok {
			continue
		}
		for _, d := range p.Deps {
			if d == corpus || strings.HasPrefix(d, corpus+" [") {
				out = append(out, rel)
				break
			}
		}
	}
	sort.Strings(out)
	return out
}

// TracedGoldens returns, sorted and once each, the root-relative path of
// every line of trace that names a file under root/golden/.
func TracedGoldens(trace, root string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, line := range strings.Split(trace, "\n") {
		rel, ok := strings.CutPrefix(line, root+"/")
		if ok && strings.HasPrefix(rel, "golden/") && !seen[rel] {
			seen[rel] = true
			out = append(out, rel)
		}
	}
	sort.Strings(out)
	return out
}

// SensitivityWeak is the event the gate prints for a consumer pkg whose
// tests still passed with the first byte of the golden file flipped.
func SensitivityWeak(pkg, file string) Event {
	return ev("corpus_sensitivity_weak", "pkg", pkg, "file", file)
}

// SensitivityInvalid is the event the gate prints when testcorpus.go does
// not parse or holds no top-level func Glob to trace.
func SensitivityInvalid() Event {
	return ev("corpus_sensitivity_invalid", "reason", "glob_not_found")
}
