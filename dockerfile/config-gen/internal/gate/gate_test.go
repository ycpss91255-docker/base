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

// A multi-line literal string may end in one or two quotes of content
// before its closing delimiter, so the first two strings below hold x
// plus one and x plus two quotes. A gate that closes one at the first
// triple quote reads the extra quotes as a literal string that swallows
// or invents a basic string (base#1850). Columns are counted by hand:
//
//	`a = '''x''''`
//	`a = '''x'''''`
//	`b = "\e"`                b(1) ' '(2) =(3) ' '(4) "(5) \(6)
//	`a = ['''x'''', "\e", '']` a(1) ' '(2) =(3) ' '(4) [(5) '(6) '(7) '(8) x(9) '(10) '(11) '(12) '(13) ,(14) ' '(15) "(16) \(17)
//
// In the nil row the escape is inside a literal string; a first-triple
// close pairs the fourth quote with the one before the double quote and
// reads the escape as one in a basic string. BurntSushi decodes every
// row.
func TestCheckClosesMultiLineLiteralAtLastQuote(t *testing.T) {
	for _, tc := range []struct {
		name, src string
		line, col int // 0: Check must return nil
	}{
		{"four-quotes-next-line", "a = '''x''''\nb = \"\\e\"\n", 2, 6},
		{"five-quotes-next-line", "a = '''x'''''\nb = \"\\e\"\n", 2, 6},
		{"four-quotes-array", "a = ['''x'''', \"\\e\", '']\n", 1, 17},
		{"four-quotes-literal-after", "a = ['''x'''', '\"\\e\"']\n", 0, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var v map[string]any
			if _, err := toml.Decode(tc.src, &v); err != nil {
				t.Fatalf("toml.Decode(%q) = %v, want nil", tc.src, err)
			}
			err := Check("t.toml", []byte(tc.src))
			if tc.line == 0 {
				if err != nil {
					t.Fatalf("Check(%q) = %v, want nil", tc.src, err)
				}
				return
			}
			var r *Refusal
			if !errors.As(err, &r) {
				t.Fatalf("Check(%q) = %v, want *Refusal", tc.src, err)
			}
			if r.File != "t.toml" || r.Line != tc.line || r.Col != tc.col || r.Reason != ReasonEscape {
				t.Fatalf("Refusal = {%q %d %d %v}, want {\"t.toml\" %d %d ReasonEscape}", r.File, r.Line, r.Col, r.Reason, tc.line, tc.col)
			}
		})
	}
}

// A line ending outside a string token is refused exactly when the
// innermost open container is an inline table; inside an array (at any
// depth) or inside a multi-line string it is legal. Verdicts come from
// the pinned-image tomllib and BurntSushi v1.6.0 (base#1441 design §1g):
// tomllib refuses every refused row and accepts every nil row, while
// BurntSushi accepts all of them. The position is the first byte (LF, or
// the CR of a CRLF) of that line ending, counted by hand, e.g. r2:
// a(1) ' '(2) =(3) ' '(4) {(5) ' '(6) b(7) ' '(8) =(9) ' '(10) 1(11)
// ' '(12) #(13) ' '(14) c(15) LF(16).
func TestCheckRefusesNewlineInInlineTable(t *testing.T) {
	for _, tc := range []struct {
		name, src string
		line, col int
	}{
		{"r1", "a = {\nb = 1}\n", 1, 6},
		{"r2", "a = { b = 1 # c\n}\n", 1, 16},
		{"r3", "a = { b = [1,\n2],\n c = 3 }\n", 2, 4},
		{"r4", "a = { b = [ { c = 1,\n d = 2 } ] }\n", 1, 21},
		{"r5", "a = { b = 1\n, c = 2 }\n", 1, 12},
		{"r6", "a = { b = [1] \n}\n", 1, 15},
		{"r1-form", "a = {b = 1,\n c = 2}\n", 1, 12},
		{"crlf", "a = {\r\nb = 1}\r\n", 1, 6},
		// Between a key and its `=`, and between the `=` and the value,
		// the structural pass refuses the line ending where it stands;
		// tomllib (run 2026-11-02) refuses both at the same column,
		// "Expected '=' after a key in a key/value pair (at line 1,
		// column 7)" and "Invalid value (at line 1, column 9)", and
		// BurntSushi v1.6.0 refuses both too (base#1441).
		{"key-eq", "a = {b\n= 1}\n", 1, 7},
		{"eq-value", "a = {b =\n1}\n", 1, 9},
	} {
		err := Check("t.toml", []byte(tc.src))
		var r *Refusal
		if !errors.As(err, &r) {
			t.Errorf("%s: Check(%q) = %v, want *Refusal", tc.name, tc.src, err)
			continue
		}
		if r.File != "t.toml" || r.Line != tc.line || r.Col != tc.col || r.Reason != ReasonInlineNewline {
			t.Errorf("%s: Refusal = {%q %d %d %v}, want {\"t.toml\" %d %d ReasonInlineNewline}",
				tc.name, r.File, r.Line, r.Col, r.Reason, tc.line, tc.col)
		}
	}
	for _, tc := range []struct{ name, src string }{
		{"c1", "a = { b = [1,\n2] }\n"},
		{"c2", "a = { b = [ # c\n 1 ] }\n"},
		{"c3", "a = { b = \"\"\"x\ny\"\"\" }\n"},
		{"c4", "a = { b = '''x\ny''' }\n"},
		{"c5", "a = { b = { c = [1,\n2] } }\n"},
		{"c6", "a = [ { b = 1 },\n { b = 2 } ]\n"},
		{"c7", "a = { b = [1,\r\n2] }\r\n"},
		{"c8", "a = { b = [1\n] }\n"},
	} {
		if err := Check("t.toml", []byte(tc.src)); err != nil {
			t.Errorf("%s: Check(%q) = %v, want nil", tc.name, tc.src, err)
		}
	}
}

// A comma followed (after optional whitespace) by the `}` that closes an
// inline table is TOML 1.1 only: the TOML 1.0 ABNF (inline-table-keyvals
// = keyval [ inline-table-sep inline-table-keyvals ]) has no trailing
// separator, and tomllib refuses `a = {b = 1, }` at 1:13 (rc=1) while
// BurntSushi v1.6.0 accepts it (base#1850). The gate must refuse it at
// the comma, counted by hand, e.g. r1:
// a(1) ' '(2) =(3) ' '(4) {(5) b(6) ' '(7) =(8) ' '(9) 1(10) ,(11).
// An array's trailing comma is TOML 1.0 (array-values allows it), and a
// comma between two inline-table pairs is the separator, so both are nil:
// refusing every `,` inside `{` fails c2.
func TestCheckRefusesTrailingCommaInInlineTable(t *testing.T) {
	for _, tc := range []struct {
		name, src string
		line, col int
	}{
		{"r1", "a = {b = 1, }\n", 1, 11},
		{"r2", "a = {b = 1,}\n", 1, 11},
	} {
		// Control: the decoder accepts the form, so the gate is the only
		// thing between these bytes and a TOML 1.1 parse.
		var v map[string]any
		if _, err := toml.Decode(tc.src, &v); err != nil {
			t.Fatalf("%s: toml.Decode(%q) = %v, want nil (the decoder accepts a trailing comma)", tc.name, tc.src, err)
		}
		err := Check("t.toml", []byte(tc.src))
		var r *Refusal
		if !errors.As(err, &r) {
			t.Errorf("%s: Check(%q) = %v, want *Refusal", tc.name, tc.src, err)
			continue
		}
		if r.File != "t.toml" || r.Line != tc.line || r.Col != tc.col || r.Reason != ReasonInlineTrailingComma {
			t.Errorf("%s: Refusal = {%q %d %d %v}, want {\"t.toml\" %d %d ReasonInlineTrailingComma}",
				tc.name, r.File, r.Line, r.Col, r.Reason, tc.line, tc.col)
		}
	}
	for _, tc := range []struct{ name, src string }{
		{"c1", "a = [1,\n2,]\n"},
		{"c2", "a = {b = 1, c = 2}\n"},
	} {
		if err := Check("t.toml", []byte(tc.src)); err != nil {
			t.Errorf("%s: Check(%q) = %v, want nil", tc.name, tc.src, err)
		}
	}
}

// A time without seconds (HH:MM) is TOML 1.1 only: the TOML 1.0 ABNF has
// partial-time = time-hour ":" time-minute ":" time-second [ time-secfrac ],
// so tomllib refuses `a = 07:32` and `a = 1979-05-27 07:32` (rc=1, base#1850
// probe) while BurntSushi v1.6.0 accepts them. The rule fires on bare value
// tokens only. The refusal points at the first byte of the value token,
// counted by hand: a(1) ' '(2) =(3) ' '(4) 0, 1 or 2(5); behind a comment
// line, `  07:32` starts at 2:3 after the two-space indent. The rows cover
// the local time, the offset datetime (`T`), the local datetime (space, so
// a gate splitting the token at the space misses it) and a lowercase `t`
// delimiter. A time with seconds, and the same bytes in a basic string,
// are nil.
func TestCheckRefusesTimeWithoutSeconds(t *testing.T) {
	for _, tc := range []struct {
		name, src string
		line, col int
	}{
		{"local-time", "a = 07:32\n", 1, 5},
		{"offset-datetime", "a = 1979-05-27T07:32Z\n", 1, 5},
		{"local-datetime-space", "a = 1979-05-27 07:32\n", 1, 5},
		{"lowercase-t", "a = 2021-01-01t10:00\n", 1, 5},
		{"behind-comment", "a = [ # c\n  07:32\n]\n", 2, 3},
	} {
		// Control: the decoder accepts the form, so the gate is the only
		// thing between these bytes and a TOML 1.1 parse.
		var v map[string]any
		if _, err := toml.Decode(tc.src, &v); err != nil {
			t.Fatalf("%s: toml.Decode(%q) = %v, want nil (the decoder accepts a time without seconds)", tc.name, tc.src, err)
		}
		err := Check("t.toml", []byte(tc.src))
		var r *Refusal
		if !errors.As(err, &r) {
			t.Errorf("%s: Check(%q) = %v, want *Refusal", tc.name, tc.src, err)
			continue
		}
		if r.File != "t.toml" || r.Line != tc.line || r.Col != tc.col || r.Reason != ReasonTimeNoSeconds {
			t.Errorf("%s: Refusal = {%q %d %d %v}, want {\"t.toml\" %d %d ReasonTimeNoSeconds}",
				tc.name, r.File, r.Line, r.Col, r.Reason, tc.line, tc.col)
		}
	}
	for _, tc := range []struct{ name, src string }{
		{"c1", "a = 07:32:00\n"},
		{"c2", "a = \"07:32\"\n"},
		{"c3", "a = 2021-01-01t10:00:00\n"},
	} {
		if err := Check("t.toml", []byte(tc.src)); err != nil {
			t.Errorf("%s: Check(%q) = %v, want nil", tc.name, tc.src, err)
		}
	}
}
