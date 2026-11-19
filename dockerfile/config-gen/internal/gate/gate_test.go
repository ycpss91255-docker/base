package gate

import (
	"errors"
	"strings"
	"testing"

	"github.com/BurntSushi/toml"
)

// A `\e` escape in a basic string is TOML 1.1 only; tomllib (the oracle)
// refuses it while BurntSushi accepts it, so the gate must refuse it at
// the backslash (base#1850). Column 7 is counted by hand:
// a(1) ' '(2) =(3) ' '(4) "(5) x(6) \(7).
func TestCheckRefusesEscapeEInBasicString(t *testing.T) {
	src := []byte("a = \"x\\e\"\n")
	// Control: the decoder accepts the form, so the gate is the only
	// thing between these bytes and a TOML 1.1 parse.
	var v map[string]any
	if _, err := toml.Decode(string(src), &v); err != nil {
		t.Fatalf("toml.Decode(%q) = %v, want nil (the decoder accepts \\e)", src, err)
	}
	err := Check("t.toml", src)
	var r *Refusal
	if !errors.As(err, &r) {
		t.Fatalf("Check() = %v, want *Refusal", err)
	}
	if r.File != "t.toml" || r.Line != 1 || r.Col != 7 || r.Reason != ReasonEscape {
		t.Fatalf("Refusal = {%q %d %d %v}, want {\"t.toml\" 1 7 ReasonEscape}", r.File, r.Line, r.Col, r.Reason)
	}
	if !strings.HasPrefix(r.Error(), "t.toml:1:7: ") {
		t.Fatalf("Error() = %q, want prefix %q", r.Error(), "t.toml:1:7: ")
	}
}

// A `\xHH` escape in a basic string is TOML 1.1 only as well; tomllib
// refuses `a = "x\x41"` (rc=1) while BurntSushi accepts it, so the gate
// must refuse it at the backslash, not match `\e` only (base#1850).
// Column 7 is counted by hand: a(1) ' '(2) =(3) ' '(4) "(5) x(6) \(7).
func TestCheckRefusesEscapeXInBasicString(t *testing.T) {
	src := []byte("a = \"x\\x41\"\n")
	var v map[string]any
	if _, err := toml.Decode(string(src), &v); err != nil {
		t.Fatalf("toml.Decode(%q) = %v, want nil (the decoder accepts \\x)", src, err)
	}
	err := Check("t.toml", src)
	var r *Refusal
	if !errors.As(err, &r) {
		t.Fatalf("Check() = %v, want *Refusal", err)
	}
	if r.File != "t.toml" || r.Line != 1 || r.Col != 7 || r.Reason != ReasonEscape {
		t.Fatalf("Refusal = {%q %d %d %v}, want {\"t.toml\" 1 7 ReasonEscape}", r.File, r.Line, r.Col, r.Reason)
	}
	if !strings.HasPrefix(r.Error(), "t.toml:1:7: ") {
		t.Fatalf("Error() = %q, want prefix %q", r.Error(), "t.toml:1:7: ")
	}
}

// The escape rule fires only inside a basic string: the same `\e` / `\x`
// bytes in a literal string, a multi-line literal or a comment are TOML
// 1.0, and so is `\\e` (an escaped backslash, then `e`). tomllib accepts
// each row (rc=0, base#1850 probe), so the gate must return nil. This
// rules out a whole-file byte search and a missing escape skip.
func TestCheckAcceptsEscapeBytesOutsideBasicString(t *testing.T) {
	for name, src := range map[string]string{
		"literal":           "a = 'x\\e'\n",
		"ml-literal":        "a = '''x\\x41'''\n",
		"comment":           "# \"\\e\"\na = 1\n",
		"escaped-backslash": "a = \"x\\\\e\"\n",
	} {
		t.Run(name, func(t *testing.T) {
			var v map[string]any
			if _, err := toml.Decode(src, &v); err != nil {
				t.Fatalf("toml.Decode(%q) = %v, want nil", src, err)
			}
			if err := Check("t.toml", []byte(src)); err != nil {
				t.Fatalf("Check(%q) = %v, want nil", src, err)
			}
		})
	}
}

// The escape rule also fires inside a multi-line basic string, which may
// hold one or two lone quotes before its closing `"""`; a gate that
// toggles "in a string" at every quote reads the escape as outside one
// (base#1850). Columns are counted by hand:
//
//	`a = """a" \e"""`    a(1) ' '(2) =(3) ' '(4) "(5) "(6) "(7) a(8) "(9) ' '(10) \(11)
//	`a = """x"" \x41"""` a(1) ' '(2) =(3) ' '(4) "(5) "(6) "(7) x(8) "(9) "(10) ' '(11) \(12)
//
// The nil rows hold a `{` or a newline inside the multi-line basic string,
// which is TOML 1.0 and must not open a container or end a line for the
// gate. BurntSushi decodes every row.
func TestCheckEscapeInMultiLineBasicString(t *testing.T) {
	for _, tc := range []struct {
		name, src string
		col       int // 0: Check must return nil
	}{
		{"one-quote-e", "a = \"\"\"a\" \\e\"\"\"\n", 11},
		{"two-quotes-x", "a = \"\"\"x\"\" \\x41\"\"\"\n", 12},
		{"newline-in-inline", "a = {b = \"\"\"a\"\n\"\"\"}\n", 0},
		{"brace-in-string", "a = \"\"\"a\" {\"\"\"\n", 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var v map[string]any
			if _, err := toml.Decode(tc.src, &v); err != nil {
				t.Fatalf("toml.Decode(%q) = %v, want nil", tc.src, err)
			}
			err := Check("t.toml", []byte(tc.src))
			if tc.col == 0 {
				if err != nil {
					t.Fatalf("Check(%q) = %v, want nil", tc.src, err)
				}
				return
			}
			var r *Refusal
			if !errors.As(err, &r) {
				t.Fatalf("Check(%q) = %v, want *Refusal", tc.src, err)
			}
			if r.File != "t.toml" || r.Line != 1 || r.Col != tc.col || r.Reason != ReasonEscape {
				t.Fatalf("Refusal = {%q %d %d %v}, want {\"t.toml\" 1 %d ReasonEscape}", r.File, r.Line, r.Col, r.Reason, tc.col)
			}
		})
	}
}
