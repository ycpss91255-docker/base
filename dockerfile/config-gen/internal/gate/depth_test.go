package gate

import (
	"errors"
	"strings"
	"testing"
)

// wantDepthText is the depth refusal's text (base#1441 design-ahead r3 §2),
// written out here rather than read from the package.
const wantDepthText = "nesting deeper than tomllib accepts (Python recursion limit)"

// nest builds one of the design-ahead r3 §1e shapes, n levels deep, with
// term at the bottom: arr `a = [[…]]`, it `a = {b = {b = …}}`, mix
// `a = [{b = [{b = …}]}]` (n pairs), arr-in-hdr `[t.u]` then
// `x.y.z = [[…]]`, arr-in-aot `[[t]]` then `x = [[…]]`, arr-ws `[ # c`
// and a line ending per level, it-arr `a = {b = [[…]]}`, ait
// `a = [{b = [[…]]}]`, arr-it `a = [{b = {b = …}}]`, warm-arr `x = {}`
// then `a = [[…]]` on line 2.
func nest(shape string, n int, term string) string {
	r := strings.Repeat
	switch shape {
	case "arr":
		return "a = " + r("[", n) + term + r("]", n) + "\n"
	case "it":
		return "a = " + r("{b = ", n) + term + r("}", n) + "\n"
	case "mix":
		return "a = " + r("[{b = ", n) + term + r("}]", n) + "\n"
	case "arr-in-hdr":
		return "[t.u]\nx.y.z = " + r("[", n) + term + r("]", n) + "\n"
	case "arr-in-aot":
		return "[[t]]\nx = " + r("[", n) + term + r("]", n) + "\n"
	case "arr-ws":
		return "a = " + r("[ # c\n", n) + term + r("\n]", n) + "\n"
	case "it-arr":
		return "a = {b = " + r("[", n) + term + r("]", n) + "}\n"
	case "ait":
		return "a = [{b = " + r("[", n) + term + r("]", n) + "}]\n"
	case "arr-it":
		return "a = [" + r("{b = ", n) + term + r("}", n) + "]\n"
	case "warm-arr":
		return "x = {}\na = " + r("[", n) + term + r("]", n) + "\n"
	}
	panic("nest: unknown shape " + shape)
}

// The gate refuses a nesting exactly when tomllib's parse passes CPython's
// recursion limit (1000 frames) the way the bridge calls it, and never
// below that: max is tomllib's largest accepted depth, measured in the
// pinned toml-bridge image (base#1441 design-ahead r3 §1e, written here
// as literals, never recomputed). At max Check returns nil; at max+1 it
// returns ReasonDepth at the first byte of the outermost value of the
// chain, counted by hand: `a = ` puts it at column 5, `x.y.z = ` on line
// 2 at column 9, `x = ` on line 2 at column 5. The escaped terminal is
// the eight bytes 22 5C 75 30 30 34 31 22; plain "A" (22 41 22) is its
// control.
func TestCheckDepthBoundaries(t *testing.T) {
	type row struct {
		shape, term string
		max         int
		line, col   int
	}
	rows := []row{
		{"arr", "1", 496, 1, 5},
		{"it", "1", 330, 1, 5},
		{"mix", "1", 198, 1, 5},
		{"arr-in-hdr", "1", 496, 2, 9},
		{"arr-in-aot", "1", 496, 2, 5},
		{"arr-ws", "1", 496, 1, 5},
		{"it-arr", "1", 495, 1, 5},
		// A comment in the innermost array, at the frame parity where
		// only its skip_until passes the limit: forms/depth it-c-* and
		// ait-c-* (base#1441).
		{"it-arr", "#c\n1", 494, 1, 5},
		{"ait", "#c\n1", 493, 1, 5},
		// An empty inline table one frame past the limit, which only the
		// inline table's own depth check refuses: forms/depth
		// it-arr-it-empty-* (base#1441).
		{"it-arr", "{}", 494, 1, 5},
		// An empty inline table read after another inline table goes one
		// frame deeper than the first one the document reads: forms/depth
		// arr-e-* (329 accept, 330 and 331 refuse) and warm-arr-it-empty-*
		// (495 accept, 496 refuse), where arr-it-empty-496 without the
		// earlier `x = {}` is accepted. warm-arr int is the control: the
		// earlier inline table moves no other boundary (base#1441).
		{"arr-it", "{}", 329, 1, 5},
		{"warm-arr", "{}", 495, 2, 5},
		{"warm-arr", "1", 496, 2, 5},
	}
	for _, tm := range []struct {
		term    string
		arr, it int
	}{
		{`"s"`, 496, 330},
		{`"A"`, 496, 330},
		{"\"\x5cu0041\"", 494, 329},
		{`'s'`, 496, 330},
		{`"""s"""`, 496, 330},
		{`'''s'''`, 496, 330},
		{"1979-05-27T07:32:00Z", 496, 330},
		{"1979-05-27", 496, 330},
		{"07:32:00", 496, 330},
		{"true", 496, 330},
		{"1.5", 496, 330},
		{"inf", 496, 330},
		{"0x1F", 496, 330},
		{"[]", 495, 330},
		{"{}", 496, 330},
		{`{"q" = 1}`, 494, 329},
		{"{x.y = 1}", 494, 329},
		{"[1, 2]", 495, 330},
	} {
		rows = append(rows, row{"arr", tm.term, tm.arr, 1, 5}, row{"it", tm.term, tm.it, 1, 5})
	}
	for _, rw := range rows {
		ok := nest(rw.shape, rw.max, rw.term)
		if err := Check("t.toml", []byte(ok)); err != nil {
			t.Errorf("%s %s at %d (tomllib accepts): Check() = %v, want nil", rw.shape, rw.term, rw.max, err)
		}
		over := nest(rw.shape, rw.max+1, rw.term)
		var r *Refusal
		if err := Check("t.toml", []byte(over)); !errors.As(err, &r) {
			t.Errorf("%s %s at %d (tomllib refuses): Check() = %v, want *Refusal", rw.shape, rw.term, rw.max+1, err)
			continue
		}
		if r.Reason != ReasonDepth || r.Line != rw.line || r.Col != rw.col || r.Text != wantDepthText {
			t.Errorf("%s %s at %d: Refusal = {%d %d %v %q}, want {%d %d ReasonDepth %q}",
				rw.shape, rw.term, rw.max+1, r.Line, r.Col, r.Reason, r.Text, rw.line, rw.col, wantDepthText)
		}
	}
}

// A 1001-part dotted key is a loop in tomllib, not a recursion: the
// pinned 3.13.13 parse-only oracle accepts it (base#1441 design-ahead r3
// §1f), so the gate must not count key parts as depth.
func TestCheckKeyPartsAreNotDepth(t *testing.T) {
	src := strings.Repeat("k.", 1000) + "k = 1\n"
	if err := Check("t.toml", []byte(src)); err != nil {
		t.Fatalf("Check(1001-part key) = %v, want nil", err)
	}
}
