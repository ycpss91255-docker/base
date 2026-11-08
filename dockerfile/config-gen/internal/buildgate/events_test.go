package buildgate

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// Every event id an ev() call of this package names is listed in
// testdata/build-events.txt, the table config_gen_gates.sh re-emits build
// log events by (base#1467): an id left out of it would be printed by the
// build and dropped by the runner. The ids are read from the package's
// syntax tree, not from its text, and each ev() call must name its id as
// a string literal, so no call can be skipped.
func TestBuildEventsListEveryEvId(t *testing.T) {
	listed := map[string]bool{}
	body, err := os.ReadFile("testdata/build-events.txt")
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(string(body), "\n") {
		if line != "" && !strings.HasPrefix(line, "#") {
			listed[line] = true
		}
	}
	fset := token.NewFileSet()
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, name, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		ast.Inspect(f, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			if fn, ok := call.Fun.(*ast.Ident); !ok || fn.Name != "ev" {
				return true
			}
			lit, ok := call.Args[0].(*ast.BasicLit)
			if !ok || lit.Kind != token.STRING {
				t.Errorf("%s: ev() names its id with no string literal", fset.Position(call.Pos()))
				return true
			}
			id, _ := strconv.Unquote(lit.Value)
			ids = append(ids, "config_gen_"+id)
			return true
		})
	}
	if len(ids) == 0 {
		t.Fatal("found no ev() call in the package")
	}
	sort.Strings(ids)
	for _, id := range ids {
		if !listed[id] {
			t.Errorf("%s is printed by an ev() call and not listed in testdata/build-events.txt", id)
		}
	}
}
