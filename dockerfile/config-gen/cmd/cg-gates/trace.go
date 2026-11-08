package main

import (
	"errors"
	"go/ast"
	"go/parser"
	"go/token"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/buildgate"
)

// The traced build of internal/testcorpus the sensitivity gate runs each
// importer's tests with (base#1467). Its only contract is the gate's own:
// TestSensitivityWithTheGoToolchain runs it, by `go test -overlay`, against
// the real toolchain.

// untracedGlob is the name traceOverlay gives testcorpus's own Glob.
const untracedGlob = "cgUntracedGlob"

// traceOverlay returns testcorpus.go's source with its one top-level func
// Glob renamed to cgUntracedGlob, so that traceSource, added beside it in
// a `go test -overlay`, is the Glob every caller reaches. Source that does
// not parse, or holds no top-level func Glob, is refused with the event
// buildgate.SensitivityInvalid. The package on disk is never changed.
func traceOverlay(src []byte) ([]byte, error) {
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
		return nil, errors.New(buildgate.SensitivityInvalid().String())
	}
	out := append([]byte{}, src[:at[0]]...)
	out = append(out, untracedGlob...)
	return append(out, src[at[0]+len("Glob"):]...), nil
}

// traceEnv names the file the traced Glob appends each path it returns to.
const traceEnv = "CG_TESTCORPUS_TRACE"

// traceSource is the file traceOverlay's source is built beside: a Glob
// that calls the renamed one and appends every path it returned, one per
// line, to the file $CG_TESTCORPUS_TRACE names.
const traceSource = `package testcorpus

import (
	"fmt"
	"os"
	"testing"
)

// Glob is the corpus sensitivity gate's traced Glob (base#1467).
func Glob(t testing.TB, pattern string) []string {
	t.Helper()
	got := ` + untracedGlob + `(t, pattern)
	f, err := os.OpenFile(os.Getenv("` + traceEnv + `"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
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
