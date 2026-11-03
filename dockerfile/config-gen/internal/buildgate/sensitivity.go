package buildgate

import (
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"sort"
	"strings"
)

// The corpus sensitivity gate's inputs (base#1467): which packages read
// the shared corpus, and the traced build of internal/testcorpus that
// tells which golden files each of them was handed.

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

// untracedGlob is the name TraceOverlay gives testcorpus's own Glob.
const untracedGlob = "cgUntracedGlob"

// TraceOverlay returns testcorpus.go's source with its one top-level func
// Glob renamed to cgUntracedGlob, so that TraceSource, added beside it in
// a `go test -overlay`, is the Glob every caller reaches. Source that does
// not parse, or holds no top-level func Glob, is refused as
// config_gen_corpus_sensitivity_invalid reason=glob_not_found. The
// package on disk is never changed.
func TraceOverlay(src []byte) ([]byte, error) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "testcorpus.go", src, 0)
	at := []int{}
	if err == nil {
		for _, d := range f.Decls {
			if fd, ok := d.(*ast.FuncDecl); ok && fd.Recv == nil && fd.Name.Name == "Glob" {
				at = append(at, fset.Position(fd.Name.Pos()).Offset)
			}
		}
	}
	if len(at) != 1 {
		return nil, errors.New(ev("corpus_sensitivity_invalid", "reason", "glob_not_found").String())
	}
	out := append([]byte{}, src[:at[0]]...)
	out = append(out, untracedGlob...)
	return append(out, src[at[0]+len("Glob"):]...), nil
}

// TraceEnv names the file the traced Glob appends each path it returns to.
const TraceEnv = "CG_TESTCORPUS_TRACE"

// TraceSource is the file TraceOverlay's source is built beside: a Glob
// that calls the renamed one and appends every path it returned, one per
// line, to the file $CG_TESTCORPUS_TRACE names.
const TraceSource = `package testcorpus

import (
	"fmt"
	"os"
	"testing"
)

// Glob is the corpus sensitivity gate's traced Glob (base#1467).
func Glob(t testing.TB, pattern string) []string {
	t.Helper()
	got := ` + untracedGlob + `(t, pattern)
	f, err := os.OpenFile(os.Getenv("` + TraceEnv + `"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatalf("testcorpus trace: %v", err)
	}
	defer f.Close()
	for _, p := range got {
		fmt.Fprintln(f, p)
	}
	return got
}
`

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
