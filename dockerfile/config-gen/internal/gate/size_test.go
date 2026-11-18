package gate

import (
	"errors"
	"strings"
	"testing"
)

// 2000 nested arrays are refused with the depth refusal at 1:5, the
// outermost `[` after `a = `, and do not panic (base#1441 acceptance:
// size). tomllib refuses from 497 levels on (design-ahead r3 §1e). The
// unclosed form, which never reaches a `]`, is refused the same way.
func TestCheckRefuses2000NestedArrays(t *testing.T) {
	for _, src := range []string{
		"a = " + strings.Repeat("[", 2000) + "1" + strings.Repeat("]", 2000) + "\n",
		"a = " + strings.Repeat("[", 2000) + "\n",
	} {
		var r *Refusal
		if err := Check("t.toml", []byte(src)); !errors.As(err, &r) {
			t.Errorf("Check(%d bytes of nesting) = %v, want *Refusal", len(src), err)
			continue
		}
		if r.Reason != ReasonDepth || r.Line != 1 || r.Col != 5 || r.Text != wantDepthText {
			t.Errorf("Refusal = {%d %d %v %q}, want {1 5 ReasonDepth %q}", r.Line, r.Col, r.Reason, r.Text, wantDepthText)
		}
	}
}
