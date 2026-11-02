package schema

import (
	"go/ast"
	"go/parser"
	"go/token"
	"maps"
	"regexp"
	"regexp/syntax"
	"slices"
	"strconv"
	"testing"
)

// patterns is every regular expression validate.go compiles, by its
// variable name. TestPatternsListsEveryRegexp holds it to validate.go's
// source, so a pattern added there without a row here fails.
var patterns = map[string]*regexp.Regexp{
	"posInt":      posInt,
	"nonNegInt":   nonNegInt,
	"gid":         gid,
	"projectName": projectName,
	"networkName": networkName,
	"logDriver":   logDriver,
	"portMapping": portMapping,
	"cgroupRule":  cgroupRule,
	"capability":  capability,
	"envKV":       envKV,
	"securityOpt": securityOpt,
	"contextName": contextName,
	"tmpfsPath":   tmpfsPath,
	"tmpfsOpts":   tmpfsOpts,
}

// equivalentMutants are the mutants no text Validate can be asked about
// tells apart from the pattern, by pattern and mutation, each with the
// reason. An entry the shared table kills fails, so the list cannot
// go stale.
var equivalentMutants = map[[2]string]string{
	// The empty text is accepted by the default empty policy before the
	// validator is asked (watchdog_start_period, cap_add_*, cap_drop_*
	// are not SCHEMA_EMPTY=validate keys), so `+` and `*` agree on every
	// text the validator sees.
	{"nonNegInt", "+ made * on [0-9]+"}:   "the empty text never reaches the validator",
	{"capability", "+ made * on [A-Z_]+"}: "the empty text never reaches the validator",
}

// TestPatternsListsEveryRegexp finds every package-level variable of
// validate.go bound to regexp.MustCompile and requires patterns to list
// exactly those, so the mutant check below covers every pattern.
func TestPatternsListsEveryRegexp(t *testing.T) {
	file, err := parser.ParseFile(token.NewFileSet(), "validate.go", nil, 0)
	if err != nil {
		t.Fatalf("parse validate.go: %v", err)
	}
	var found []string
	ast.Inspect(file, func(n ast.Node) bool {
		spec, ok := n.(*ast.ValueSpec)
		if !ok {
			return true
		}
		for i, v := range spec.Values {
			call, ok := v.(*ast.CallExpr)
			if !ok {
				continue
			}
			sel, ok := call.Fun.(*ast.SelectorExpr)
			if !ok || sel.Sel.Name != "MustCompile" {
				continue
			}
			if pkg, ok := sel.X.(*ast.Ident); ok && pkg.Name == "regexp" {
				found = append(found, spec.Names[i].Name)
			}
		}
		return true
	})
	slices.Sort(found)
	if want := slices.Sorted(maps.Keys(patterns)); !slices.Equal(found, want) {
		t.Errorf("validate.go compiles %v, patterns lists %v", found, want)
	}
}

// mutant is one pattern with a single point changed.
type mutant struct {
	what string
	re   *syntax.Regexp
}

// TestEveryPatternMutantIsKilled holds the shared table to the patterns
// it is meant to pin (base#1442 review rounds 3 and 4: rows were picked
// by hand, so a dropped `tcp`, a dropped `b` from [cba], a required tmpfs
// option value, a `*` made `+` and a dropped character class all left
// every verdict as it was). Every pattern of validate.go is parsed, and
// every single-point mutant of it is made: an alternative dropped, an
// element of a sequence dropped (an anchor included), a range of a
// character class dropped, a point of a range of at most three dropped,
// `*` made `+` or empty, `+` made one or `*`, `?` made required or
// empty. The mutant is put in the pattern's place and every class=value
// row of s6_scalar_values.tsv (whose verdicts the bats half holds to
// _schema_validate) is asked again; at least one verdict must change.
// A mutant no row kills names the class of text the table lacks.
func TestEveryPatternMutantIsKilled(t *testing.T) {
	type textRow struct {
		row  valueRow
		text string
	}
	var rows []textRow
	for _, row := range readValueRows(t) {
		rows = append(rows, textRow{row, rowText(t, row)})
	}
	killed := func() (string, bool) {
		for _, r := range rows {
			accepted := Validate(r.row.section, r.row.key, r.text) == nil
			if accepted != (r.row.verdict == "accept") {
				return "tsv line " + strconv.Itoa(r.row.line), true
			}
		}
		return "", false
	}
	if by, ok := killed(); ok {
		t.Fatalf("unmutated patterns already disagree with the table at %s", by)
	}
	seenEquivalent := map[[2]string]bool{}
	total := 0
	for _, name := range slices.Sorted(maps.Keys(patterns)) {
		re := patterns[name]
		orig := *re
		tree, err := syntax.Parse(orig.String(), syntax.Perl)
		if err != nil {
			t.Fatalf("%s: parse %q: %v", name, orig.String(), err)
		}
		for _, m := range mutants(tree) {
			src := m.re.String()
			if src == tree.String() {
				continue
			}
			compiled, err := regexp.Compile(src)
			if err != nil {
				t.Fatalf("%s: mutant %q (%s) does not compile: %v", name, src, m.what, err)
			}
			total++
			*re = *compiled
			by, ok := killed()
			*re = orig
			key := [2]string{name, m.what}
			if reason, eq := equivalentMutants[key]; eq {
				seenEquivalent[key] = true
				if ok {
					t.Errorf("%s: mutant %q listed as equivalent (%s) but killed at %s", name, src, reason, by)
				}
				continue
			}
			if !ok {
				t.Errorf("%s %q: mutant %q (%s) changes no verdict of s6_scalar_values.tsv", name, orig.String(), src, m.what)
			}
		}
	}
	for key := range equivalentMutants {
		if !seenEquivalent[key] {
			t.Errorf("equivalent mutant %v is not a mutant of its pattern", key)
		}
	}
	if total == 0 {
		t.Fatal("no mutants made")
	}
}

// mutants returns every single-point mutant of n: the local mutants of n
// itself, then each mutant of each child put in that child's place.
func mutants(n *syntax.Regexp) []mutant {
	out := local(n)
	for i, sub := range n.Sub {
		for _, m := range mutants(sub) {
			c := *n
			c.Sub = slices.Clone(n.Sub)
			c.Sub[i] = m.re
			out = append(out, mutant{m.what, &c})
		}
	}
	return out
}

// node is a new node of op over subs.
func node(op syntax.Op, flags syntax.Flags, subs ...*syntax.Regexp) *syntax.Regexp {
	return &syntax.Regexp{Op: op, Flags: flags, Sub: subs}
}

// local returns the mutants that change n itself.
func local(n *syntax.Regexp) []mutant {
	var out []mutant
	empty := node(syntax.OpEmptyMatch, n.Flags)
	switch n.Op {
	case syntax.OpAlternate, syntax.OpConcat:
		verb := "alternative"
		if n.Op == syntax.OpConcat {
			verb = "sequence element"
		}
		for i := range n.Sub {
			rest := slices.Delete(slices.Clone(n.Sub), i, i+1)
			var m *syntax.Regexp
			switch len(rest) {
			case 0:
				m = empty
			case 1:
				m = rest[0]
			default:
				m = node(n.Op, n.Flags, rest...)
			}
			out = append(out, mutant{"drop " + verb + " " + n.Sub[i].String(), m})
		}
	case syntax.OpCharClass:
		for i := 0; i < len(n.Rune); i += 2 {
			lo, hi := n.Rune[i], n.Rune[i+1]
			rest := slices.Delete(slices.Clone(n.Rune), i, i+2)
			out = append(out, mutant{"drop class range " + runeRange(lo, hi) + " of " + n.String(), charClass(n.Flags, rest)})
			if hi > lo && hi-lo < 3 {
				for p := lo; p <= hi; p++ {
					split := slices.Clone(rest)
					if p > lo {
						split = append(split, lo, p-1)
					}
					if p < hi {
						split = append(split, p+1, hi)
					}
					out = append(out, mutant{"drop class point " + strconv.QuoteRune(p) + " of " + n.String(), charClass(n.Flags, split)})
				}
			}
		}
	case syntax.OpStar:
		out = append(out,
			mutant{"* made + on " + n.String(), node(syntax.OpPlus, n.Flags, n.Sub[0])},
			mutant{"* made empty on " + n.String(), empty})
	case syntax.OpPlus:
		out = append(out,
			mutant{"+ made one on " + n.String(), n.Sub[0]},
			mutant{"+ made * on " + n.String(), node(syntax.OpStar, n.Flags, n.Sub[0])})
	case syntax.OpQuest:
		out = append(out,
			mutant{"? made required on " + n.String(), n.Sub[0]},
			mutant{"? made empty on " + n.String(), empty})
	case syntax.OpNoMatch, syntax.OpEmptyMatch, syntax.OpLiteral, syntax.OpAnyCharNotNL, syntax.OpAnyChar,
		syntax.OpBeginLine, syntax.OpEndLine, syntax.OpBeginText, syntax.OpEndText,
		syntax.OpWordBoundary, syntax.OpNoWordBoundary, syntax.OpCapture:
		// No change of its own: the sequence or alternative holding it
		// drops it, and a capture's child is mutated in its place.
	case syntax.OpRepeat:
		// No pattern of validate.go has a {n,m}; one that does needs its
		// mutants written before this test can claim to cover it.
		panic("mutants: {n,m} repetition in " + n.String() + " has no mutants")
	}
	return out
}

// charClass is a class of the given range pairs; no pairs is a class
// that matches nothing.
func charClass(flags syntax.Flags, pairs []rune) *syntax.Regexp {
	if len(pairs) == 0 {
		return node(syntax.OpNoMatch, flags)
	}
	sorted := make([][2]rune, 0, len(pairs)/2)
	for i := 0; i < len(pairs); i += 2 {
		sorted = append(sorted, [2]rune{pairs[i], pairs[i+1]})
	}
	slices.SortFunc(sorted, func(a, b [2]rune) int { return int(a[0] - b[0]) })
	r := node(syntax.OpCharClass, flags)
	for _, p := range sorted {
		r.Rune = append(r.Rune, p[0], p[1])
	}
	return r
}

// runeRange spells a class range for a failure message.
func runeRange(lo, hi rune) string {
	if lo == hi {
		return strconv.QuoteRune(lo)
	}
	return strconv.QuoteRune(lo) + "-" + strconv.QuoteRune(hi)
}
