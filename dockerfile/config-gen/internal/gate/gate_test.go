package gate

import (
	"errors"
	"os"
	"path/filepath"
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
// depth) or inside a multi-line string it is legal. tomllib (the
// pinned-image probe, base#1441 design §1g) refuses every refused row and
// accepts every nil row; each refused row's decoderAccepts records
// BurntSushi v1.6.0's verdict, and a toml.Decode control asserts it, so
// the rows the decoder already refuses are marked. The position is the
// first byte (LF, or the CR of a CRLF) of that line ending, counted by
// hand, e.g. r2:
// a(1) ' '(2) =(3) ' '(4) {(5) ' '(6) b(7) ' '(8) =(9) ' '(10) 1(11)
// ' '(12) #(13) ' '(14) c(15) LF(16).
func TestCheckRefusesNewlineInInlineTable(t *testing.T) {
	for _, tc := range []struct {
		name, src      string
		line, col      int
		decoderAccepts bool
	}{
		{"r1", "a = {\nb = 1}\n", 1, 6, true},
		{"r2", "a = { b = 1 # c\n}\n", 1, 16, true},
		{"r3", "a = { b = [1,\n2],\n c = 3 }\n", 2, 4, true},
		{"r4", "a = { b = [ { c = 1,\n d = 2 } ] }\n", 1, 21, true},
		{"r5", "a = { b = 1\n, c = 2 }\n", 1, 12, true},
		{"r6", "a = { b = [1] \n}\n", 1, 15, true},
		{"r1-form", "a = {b = 1,\n c = 2}\n", 1, 12, true},
		{"crlf", "a = {\r\nb = 1}\r\n", 1, 6, true},
		// A comment stops before the CRLF that ends its line, so the
		// refusal names that CR: r2 with CR(16) LF(17). tomllib refuses it
		// ("Unclosed inline table", rc=1) and BurntSushi v1.6.0 decodes it
		// to map[a:map[b:1]] (run 2026-11-19, base#1850).
		{"r2-crlf", "a = { b = 1 # c\r\n}\r\n", 1, 16, true},
		// A basic string left open at its line end stops before that
		// line's CRLF in the same way: a(1) ' '(2) =(3) ' '(4) {(5) ' '(6)
		// b(7) ' '(8) =(9) ' '(10) "(11) x(12) CR(13). Both parsers refuse
		// this row (tomllib "Illegal character", BurntSushi "strings
		// cannot contain newlines", run 2026-11-19); it pins the column
		// only (base#1850).
		{"basic-crlf", "a = { b = \"x\r\n}\r\n", 1, 13, false},
		// Between a key and its `=`, and between the `=` and the value,
		// the structural pass refuses the line ending where it stands;
		// tomllib (run 2026-11-02) refuses both at the same column,
		// "Expected '=' after a key in a key/value pair (at line 1,
		// column 7)" and "Invalid value (at line 1, column 9)", and
		// BurntSushi v1.6.0 refuses both too (base#1441).
		{"key-eq", "a = {b\n= 1}\n", 1, 7, false},
		{"eq-value", "a = {b =\n1}\n", 1, 9, false},
	} {
		var v map[string]any
		if _, err := toml.Decode(tc.src, &v); (err == nil) != tc.decoderAccepts {
			t.Errorf("%s: toml.Decode(%q) = %v, want accepted=%v", tc.name, tc.src, err, tc.decoderAccepts)
		}
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
// refusing every `,` inside `{` fails c2. TOML 1.0 whitespace between the
// comma and the `}` is any run of spaces and tabs (ws = *wschar, wschar =
// %x20 / %x09); the tab rows hold the gate to both bytes, and to more than
// one. tomllib refuses tab, sp-tab and tab-tab (rc=1) and BurntSushi
// v1.6.0 accepts them (run 2026-11-19, base#1850).
func TestCheckRefusesTrailingCommaInInlineTable(t *testing.T) {
	for _, tc := range []struct {
		name, src string
		line, col int
	}{
		{"r1", "a = {b = 1, }\n", 1, 11},
		{"r2", "a = {b = 1,}\n", 1, 11},
		{"tab", "a = {b = 1,\t}\n", 1, 11},
		{"sp-tab", "a = {b = 1, \t }\n", 1, 11},
		{"tab-tab", "a = {b = 1,\t\t}\n", 1, 11},
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
	// c5 puts a form feed, which is not TOML whitespace, between the comma
	// and the `}`: the gate leaves it to the decoder, and both parsers
	// refuse it as a control character (run 2026-11-19, base#1850).
	for _, tc := range []struct {
		name, src      string
		decoderAccepts bool
	}{
		{"c1", "a = [1,\n2,]\n", true},
		{"c2", "a = {b = 1, c = 2}\n", true},
		{"c3", "a = {b = [1,\t]}\n", true},
		{"c4", "a = {b = 1,\tc = 2}\n", true},
		{"c5", "a = {b = 1,\f}\n", false},
	} {
		var v map[string]any
		if _, err := toml.Decode(tc.src, &v); (err == nil) != tc.decoderAccepts {
			t.Fatalf("%s: toml.Decode(%q) = %v, want accepted=%v", tc.name, tc.src, err, tc.decoderAccepts)
		}
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

// A date-bearing value whose year is 0000 is refused at the value's first
// byte. tomllib (CPython 3.13.13 Lib/tomllib, measured 2026-11-02 on
// base#1441) refuses each row with "Invalid date or datetime" at that byte,
// and the live oracle refuses forms/date-year0-{local-date,local-datetime,
// offset} (base#1851 probe), while BurntSushi v1.6.0 accepts every row, so
// the gate is the only thing between these bytes and a parse. Columns are
// counted by hand: a(1) ' '(2) =(3) ' '(4) 0(5); in the array row [(5)
// 0(6); in the inline-table row h(1) ' '(2) =(3) ' '(4) {(5) x(6) ' '(7)
// =(8) ' '(9) 0(10). Year 0001 and 9999 are dates tomllib accepts, and the
// same text inside strings, keys, a header and a comment is not a date
// value, so those controls are nil.
func TestCheckRefusesYearZeroDate(t *testing.T) {
	for _, tc := range []struct {
		name, src string
		line, col int
	}{
		{"local-date", "a = 0000-01-01\n", 1, 5},
		{"local-datetime", "b = 0000-01-01T00:00:00\n", 1, 5},
		{"offset-datetime", "c = 0000-01-01T00:00:00Z\n", 1, 5},
		{"local-datetime-space", "e = 0000-01-01 00:00:00\n", 1, 5},
		{"array", "g = [0000-01-01]\n", 1, 6},
		{"inline-table", "h = {x = 0000-01-01T00:00:00Z}\n", 1, 10},
	} {
		var v map[string]any
		if _, err := toml.Decode(tc.src, &v); err != nil {
			t.Fatalf("%s: toml.Decode(%q) = %v, want nil (the decoder accepts year 0000)", tc.name, tc.src, err)
		}
		err := Check("t.toml", []byte(tc.src))
		var r *Refusal
		if !errors.As(err, &r) {
			t.Errorf("%s: Check(%q) = %v, want *Refusal", tc.name, tc.src, err)
			continue
		}
		if r.File != "t.toml" || r.Line != tc.line || r.Col != tc.col || r.Reason != ReasonDateRange {
			t.Errorf("%s: Refusal = {%q %d %d %v}, want {\"t.toml\" %d %d ReasonDateRange}",
				tc.name, r.File, r.Line, r.Col, r.Reason, tc.line, tc.col)
		}
	}
	for _, src := range []string{
		"a = 0001-01-01\n",
		"b = 0001-01-01T00:00:00\n",
		"c = 0001-01-01T00:00:00Z\n",
		"a = 9999-12-31T23:59:59Z\n",
		"s = \"0000-01-01\"\n",
		"s = '0000-01-01T00:00:00Z'\n",
		"s = \"\"\"0000-01-01\"\"\"\n",
		"\"0000-01-01\" = 1\n",
		"0000-01-01 = 1\n",
		"x.0000-01-01 = 1\n",
		"[0000-01-01]\n",
		"a = 1 # 0000-01-01T00:00:00Z\n",
	} {
		if err := Check("t.toml", []byte(src)); err != nil {
			t.Errorf("Check(%q) = %v, want nil", src, err)
		}
	}
}

// An offset hour above 23 is refused with ReasonOffsetRange at the
// offset's sign. tomllib (CPython 3.13.13 Lib/tomllib, measured 2026-11-02
// on base#1441) refuses each row at the sign, "(at line 1, column 24)",
// array row column 25, and the live oracle refuses forms/offset-hour24
// (base#1851 probe), while BurntSushi v1.6.0 accepts every row. The TOML
// 1.0 ABNF limits time-hour in time-numoffset to 00-23. Column 24 is
// counted by hand: the value starts at column 5 and the 19-byte datetime
// ends at column 23. tomllib accepts the controls: hour 23 with either
// sign and the same bytes inside a basic string.
func TestCheckRefusesOffsetHourOutOfRange(t *testing.T) {
	for _, tc := range []struct {
		src       string
		line, col int
	}{
		{"a = 2021-01-01T00:00:00+24:00\n", 1, 24},
		{"a = 2021-01-01T00:00:00-24:00\n", 1, 24},
		{"a = 2021-01-01 00:00:00+24:00\n", 1, 24},
		{"a = [2021-01-01T00:00:00+24:00]\n", 1, 25},
	} {
		var v map[string]any
		if _, err := toml.Decode(tc.src, &v); err != nil {
			t.Fatalf("toml.Decode(%q) = %v, want nil (the decoder accepts offset hour 24)", tc.src, err)
		}
		err := Check("t.toml", []byte(tc.src))
		var r *Refusal
		if !errors.As(err, &r) {
			t.Errorf("Check(%q) = %v, want *Refusal", tc.src, err)
			continue
		}
		if r.File != "t.toml" || r.Line != tc.line || r.Col != tc.col || r.Reason != ReasonOffsetRange {
			t.Errorf("Check(%q) Refusal = {%q %d %d %v}, want {\"t.toml\" %d %d ReasonOffsetRange}",
				tc.src, r.File, r.Line, r.Col, r.Reason, tc.line, tc.col)
		}
	}
	for _, src := range []string{
		"a = 2021-01-01T00:00:00+23:59\n",
		"a = 2021-01-01T00:00:00-23:59\n",
		"s = \"2021-01-01T00:00:00+24:00\"\n",
	} {
		if err := Check("t.toml", []byte(src)); err != nil {
			t.Errorf("Check(%q) = %v, want nil", src, err)
		}
	}
}

// An offset minute above 59 is refused with ReasonOffsetRange at the
// offset's sign. The first row is toml-test v2.2.0
// invalid/datetime/offset-overflow-minute.toml byte for byte, which the
// live oracle refuses and BurntSushi v1.6.0 accepts (base#1851 probe). The
// TOML 1.0 ABNF limits time-minute in time-numoffset to 00-59. Column 24
// is counted by hand: the value starts at column 5 and the 19-byte
// datetime ends at column 23; the array row adds one for the bracket. A
// valid hour (12, 00) rules out a check of the offset hour only. Minute 59
// and the same bytes inside a basic string are the controls.
func TestCheckRefusesOffsetMinuteOutOfRange(t *testing.T) {
	for _, tc := range []struct {
		src       string
		line, col int
	}{
		{"d = 1985-06-18 17:04:07+12:60\n", 1, 24},
		{"d = 1985-06-18T17:04:07-12:60\n", 1, 24},
		{"d = [1985-06-18T17:04:07+00:60]\n", 1, 25},
	} {
		var v map[string]any
		if _, err := toml.Decode(tc.src, &v); err != nil {
			t.Fatalf("toml.Decode(%q) = %v, want nil (the decoder accepts offset minute 60)", tc.src, err)
		}
		err := Check("t.toml", []byte(tc.src))
		var r *Refusal
		if !errors.As(err, &r) {
			t.Errorf("Check(%q) = %v, want *Refusal", tc.src, err)
			continue
		}
		if r.File != "t.toml" || r.Line != tc.line || r.Col != tc.col || r.Reason != ReasonOffsetRange {
			t.Errorf("Check(%q) Refusal = {%q %d %d %v}, want {\"t.toml\" %d %d ReasonOffsetRange}",
				tc.src, r.File, r.Line, r.Col, r.Reason, tc.line, tc.col)
		}
	}
	for _, src := range []string{
		"d = 1985-06-18 17:04:07+12:59\n",
		"d = 1985-06-18T17:04:07-12:59\n",
		"s = \"1985-06-18 17:04:07+12:60\"\n",
	} {
		if err := Check("t.toml", []byte(src)); err != nil {
			t.Errorf("Check(%q) = %v, want nil", src, err)
		}
	}
}

// A leading byte order mark is not TOML 1.0: tomllib reads the file with a
// strict UTF-8 decode and refuses EF BB BF ("Invalid statement" at 1:1) and
// FF FE / FE FF ("'utf-8' codec can't decode byte 0xff/0xfe in position 0"),
// while BurntSushi v1.6.0 strips all three before it lexes (parse.go:47-51)
// and decodes the rest (base#1850 probe: map[a:1], map[a:1], map[]). The
// refusal points at the first byte of the file, 1:1. The FF FE prefix alone
// rules out a check that needs bytes after the prefix. An FF or FE byte
// anywhere else is invalid UTF-8 and the decoder refuses it itself (probe:
// "invalid UTF-8 byte", each), so the gate returns nil there: the control
// requires the decoder error, so these rows cannot pass vacuously. A UTF-8
// BOM inside a basic string is valid content, nil.
func TestCheckRefusesLeadingByteOrderMark(t *testing.T) {
	for _, tc := range []struct{ name, src string }{
		{"utf8-bom", "\xEF\xBB\xBFa = 1\n"},
		{"utf16le-bom", "\xFF\xFEa = 1\n"},
		{"utf16be-bom", "\xFE\xFFa = 1\n"},
		{"utf16le-bom-alone", "\xFF\xFE"},
	} {
		// Control: the decoder strips the prefix and accepts the rest, so
		// the gate is the only thing between these bytes and a parse.
		var v map[string]any
		if _, err := toml.Decode(tc.src, &v); err != nil {
			t.Fatalf("%s: toml.Decode(%q) = %v, want nil (the decoder strips the prefix)", tc.name, tc.src, err)
		}
		err := Check("t.toml", []byte(tc.src))
		var r *Refusal
		if !errors.As(err, &r) {
			t.Errorf("%s: Check(%q) = %v, want *Refusal", tc.name, tc.src, err)
			continue
		}
		if r.File != "t.toml" || r.Line != 1 || r.Col != 1 || r.Reason != ReasonBOM {
			t.Errorf("%s: Refusal = {%q %d %d %v}, want {\"t.toml\" 1 1 ReasonBOM}",
				tc.name, r.File, r.Line, r.Col, r.Reason)
		}
		if want := "t.toml:1:1: "; !strings.HasPrefix(r.Error(), want) {
			t.Errorf("%s: Error() = %q, want prefix %q", tc.name, r.Error(), want)
		}
	}
	for _, tc := range []struct{ name, src string }{
		{"utf16-bom-line-2", "a = 1\n\xFF\xFEb = 2\n"},
		{"utf16-bom-in-literal", "a = '\xFF\xFE'\n"},
		{"utf16-bom-in-ml-literal", "a = '''\xFF\xFE'''\n"},
		{"utf16-bom-in-comment", "# \xFE\xFF\na = 1\n"},
	} {
		// Control: the decoder refuses an FF/FE byte that is not a leading
		// prefix, so the gate need not.
		var v map[string]any
		if _, err := toml.Decode(tc.src, &v); err == nil {
			t.Fatalf("%s: toml.Decode(%q) = nil, want an invalid UTF-8 error", tc.name, tc.src)
		}
		if err := Check("t.toml", []byte(tc.src)); err != nil {
			t.Errorf("%s: Check(%q) = %v, want nil", tc.name, tc.src, err)
		}
	}
	src := "a = \"\xEF\xBB\xBF\"\n"
	var v map[string]any
	if _, err := toml.Decode(src, &v); err != nil {
		t.Fatalf("toml.Decode(%q) = %v, want nil", src, err)
	}
	if err := Check("t.toml", []byte(src)); err != nil {
		t.Errorf("utf8-bom-in-basic-string: Check(%q) = %v, want nil", src, err)
	}
}

// acceptedOutsideTheirContext holds, for each refused form other than the
// escapes above, the same bytes inside a literal string, a comment and a
// multi-line literal string (base#1850 acceptance: not refused). tomllib
// accepts each row (base#1850 probe: rc=0 each). Each row is also, byte for
// byte, the file testdata/forms/accept-<name>.toml, so a later oracle run
// answers on the same bytes the gate is tested on.
var acceptedOutsideTheirContext = []struct{ name, src string }{
	{"newline-literal", "a = '{'\nb = 1\n"},
	{"newline-comment", "# a = {\nb = 1\n"},
	{"newline-ml-literal", "a = '''{\nb = 1}'''\n"},
	{"comma-literal", "a = '{b = 1,}'\n"},
	{"comma-comment", "# a = {b = 1,}\nb = 1\n"},
	{"comma-ml-literal", "a = '''{b = 1,}'''\n"},
	{"time-literal", "a = '07:32'\n"},
	{"time-comment", "# a = 07:32\nb = 1\n"},
	{"time-ml-literal", "a = '''07:32'''\n"},
	{"bom-literal", "a = '\xEF\xBB\xBF'\n"},
	{"bom-comment", "# \xEF\xBB\xBF\nb = 1\n"},
	{"bom-ml-literal", "a = '''\xEF\xBB\xBF'''\n"},
}

// Check returns nil on every row of acceptedOutsideTheirContext, and each
// row is byte for byte its testdata/forms/accept-<name>.toml file.
func TestCheckAcceptsRefusedFormBytesOutsideTheirContext(t *testing.T) {
	for _, tc := range acceptedOutsideTheirContext {
		if err := Check("t.toml", []byte(tc.src)); err != nil {
			t.Errorf("%s: Check(%q) = %v, want nil", tc.name, tc.src, err)
		}
		p := filepath.Join("testdata", "forms", "accept-"+tc.name+".toml")
		got, err := os.ReadFile(p)
		if err != nil {
			t.Errorf("%s: %v", tc.name, err)
			continue
		}
		if string(got) != tc.src {
			t.Errorf("%s: %s holds %q, want %q", tc.name, p, got, tc.src)
		}
	}
}
