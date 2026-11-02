package gate

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A `\e` escape in a basic string is TOML 1.1 only; tomllib (the oracle)
// refuses it while BurntSushi accepts it, so the gate must refuse it at
// the backslash (base#1441). Column 7 is counted by hand:
// a(1) ' '(2) =(3) ' '(4) "(5) x(6) \(7).
func TestCheckRefusesEscapeEInBasicString(t *testing.T) {
	err := Check("t.toml", []byte("a = \"x\\e\"\n"))
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

// A `\xHH` escape in a basic string is TOML 1.1 only: the TOML 1.0 spec
// lists only \b \t \n \f \r \" \\ \uXXXX \UXXXXXXXX, so tomllib refuses it
// while BurntSushi accepts it, and the gate must refuse it at the
// backslash (base#1441). Column 7 is counted by hand:
// a(1) ' '(2) =(3) ' '(4) "(5) x(6) \(7).
func TestCheckRefusesEscapeXInBasicString(t *testing.T) {
	err := Check("t.toml", []byte("a = \"x\\x41\"\n"))
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

// The escape rule covers only an escape inside a basic string. The same
// `\e` / `\x` bytes in a literal string, a multi-line literal string or a
// comment are not escapes, and `\\e` is an escaped backslash followed by
// a plain `e`. tomllib (the oracle) accepts every row (base#1441 design
// cycle 3), so Check must return nil for each.
func TestCheckAcceptsEscapeBytesOutsideBasicStringEscape(t *testing.T) {
	for _, src := range []string{
		"a = 'x\\e'\n",
		"a = '''x\\x41'''\n",
		"# \"\\e\"\na = 1\n",
		"a = \"x\\\\e\"\n",
	} {
		if err := Check("t.toml", []byte(src)); err != nil {
			t.Errorf("Check(%q) = %v, want nil", src, err)
		}
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
		// BurntSushi v1.6.0 refuses both too (base#1441 review round 2).
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
// inline table is TOML 1.1 only. toml-test v2.2.0's 1.0 list has
// invalid/inline-table/trailing-comma, which tomllib refuses while
// BurntSushi v1.6.0 accepts (base#1441 design-ahead §1c), and the TOML 1.0
// ABNF (inline-table-keyvals = keyval [ inline-table-sep
// inline-table-keyvals ]) has no trailing separator. The position is the
// comma, counted by hand, e.g. r1:
// a(1) ' '(2) =(3) ' '(4) {(5) b(6) ' '(7) =(8) ' '(9) 1(10) ,(11).
// An array's trailing comma is TOML 1.0 (array-values allows it), and a
// comma between two inline-table pairs is the separator, so both are nil.
func TestCheckRefusesTrailingCommaInInlineTable(t *testing.T) {
	for _, tc := range []struct {
		name, src string
		line, col int
	}{
		{"r1", "a = {b = 1, }\n", 1, 11},
		{"r2", "a = {b = 1,}\n", 1, 11},
	} {
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
// so tomllib refuses `07:32` while BurntSushi v1.6.0 accepts it (toml-test
// v2.2.0 1.0 list, base#1441 design-ahead §1c). The refusal points at the
// first byte of the value token, counted by hand: a(1) ' '(2) =(3) ' '(4)
// 0 or 1(5). The forms are the local time, the offset datetime (`T`
// delimiter) and the local datetime (space delimiter). A time with
// seconds, and the same bytes inside a basic string, are nil.
func TestCheckRefusesTimeWithoutSeconds(t *testing.T) {
	for _, tc := range []struct {
		name, src string
		line, col int
	}{
		{"local-time", "a = 07:32\n", 1, 5},
		{"offset-datetime", "a = 1979-05-27T07:32Z\n", 1, 5},
		{"local-datetime-space", "a = 1979-05-27 07:32\n", 1, 5},
	} {
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
	} {
		if err := Check("t.toml", []byte(tc.src)); err != nil {
			t.Errorf("%s: Check(%q) = %v, want nil", tc.name, tc.src, err)
		}
	}
}

// A leading UTF-8 BOM (bytes EF BB BF) is refused at 1:1: tomllib (CPython
// 3.13.13 Lib/tomllib) refuses "\xEF\xBB\xBFa = 1\n" with "Invalid statement
// (at line 1, column 1)" while BurntSushi v1.6.0 accepts it as {a: 1}
// (base#1441, measured). The same three bytes inside a basic string are a
// U+FEFF character that both accept, so Check returns nil for them.
func TestCheckRefusesLeadingBOM(t *testing.T) {
	err := Check("t.toml", []byte("\xEF\xBB\xBFa = 1\n"))
	var r *Refusal
	if !errors.As(err, &r) {
		t.Fatalf("Check() = %v, want *Refusal", err)
	}
	if r.File != "t.toml" || r.Line != 1 || r.Col != 1 || r.Reason != ReasonBOM {
		t.Fatalf("Refusal = {%q %d %d %v}, want {\"t.toml\" 1 1 ReasonBOM}", r.File, r.Line, r.Col, r.Reason)
	}
	if !strings.HasPrefix(r.Error(), "t.toml:1:1: ") {
		t.Fatalf("Error() = %q, want prefix %q", r.Error(), "t.toml:1:1: ")
	}
	if err := Check("t.toml", []byte("a = \"\xEF\xBB\xBF\"\n")); err != nil {
		t.Fatalf("Check(BOM inside a basic string) = %v, want nil", err)
	}
}

// A key assigned twice in the same table is refused at the first byte of
// the second assignment's key, in tomllib's wording "Cannot overwrite a
// value" (issue base#1441 acceptance criterion: a duplicate key gives
// "Cannot overwrite a value (at line L, column C)"). The position is
// counted by hand: line 2 is `a = 2`, and its key `a` is column 1.
func TestCheckRefusesDuplicateKey(t *testing.T) {
	err := Check("t.toml", []byte("a = 1\na = 2\n"))
	var r *Refusal
	if !errors.As(err, &r) {
		t.Fatalf("Check() = %v, want *Refusal", err)
	}
	if r.File != "t.toml" || r.Line != 2 || r.Col != 1 || r.Reason != ReasonDuplicate {
		t.Fatalf("Refusal = {%q %d %d %v}, want {\"t.toml\" 2 1 ReasonDuplicate}", r.File, r.Line, r.Col, r.Reason)
	}
	const want = "t.toml:2:1: Cannot overwrite a value (at line 2, column 1)"
	if r.Error() != want {
		t.Fatalf("Error() = %q, want %q", r.Error(), want)
	}
}

// A table header whose path names a table that dotted keys already
// created is refused with ReasonRedefine at the header's `[`. Inputs are
// the toml-test v2.2.0 (ce08da1) invalid/ files vendored under
// testdata/toml-test, which tomllib (CPython 3.13.13 Lib/tomllib) refuses
// with "Cannot declare ... twice" on the same line while BurntSushi v1.6.0
// accepts them (base#1441 design run1 r2 cycle 9a, measured). Each L:C is
// counted by hand in the file: the header line, column 1. The controls
// are accepted by tomllib: a sub-table header under a dotted table that
// no dotted key created (valid/spec-1.0.0/table-9), and the same shape
// written as a literal.
func TestCheckRefusesHeaderOverDottedTable(t *testing.T) {
	for _, tc := range []struct {
		file      string
		line, col int
	}{
		{"invalid/table/duplicate-key-04.toml", 4, 1},
		{"invalid/table/duplicate-key-05.toml", 4, 1},
		{"invalid/table/redefine-02.toml", 3, 1},
		{"invalid/table/redefine-03.toml", 3, 1},
		{"invalid/spec-1.0.0/table-9-1.toml", 6, 1},
	} {
		src, err := os.ReadFile(filepath.Join("testdata", "toml-test", tc.file))
		if err != nil {
			t.Fatal(err)
		}
		err = Check(tc.file, src)
		var r *Refusal
		if !errors.As(err, &r) {
			t.Errorf("%s: Check() = %v, want *Refusal", tc.file, err)
			continue
		}
		if r.File != tc.file || r.Line != tc.line || r.Col != tc.col || r.Reason != ReasonRedefine {
			t.Errorf("%s: Refusal = {%q %d %d %v}, want {%q %d %d ReasonRedefine}",
				tc.file, r.File, r.Line, r.Col, r.Reason, tc.file, tc.line, tc.col)
			continue
		}
		want := fmt.Sprintf("%s:%d:%d: Cannot overwrite a value (at line %d, column %d)",
			tc.file, tc.line, tc.col, tc.line, tc.col)
		if r.Error() != want {
			t.Errorf("%s: Error() = %q, want %q", tc.file, r.Error(), want)
		}
	}
	src, err := os.ReadFile(filepath.Join("testdata", "toml-test", "valid", "spec-1.0.0", "table-9.toml"))
	if err != nil {
		t.Fatal(err)
	}
	if err := Check("table-9.toml", src); err != nil {
		t.Errorf("Check(valid/spec-1.0.0/table-9.toml) = %v, want nil", err)
	}
	if err := Check("t.toml", []byte("[a]\nb.c = 1\n[a.d]\n")); err != nil {
		t.Errorf("Check(%q) = %v, want nil", "[a]\nb.c = 1\n[a.d]\n", err)
	}
}

// An offset minute above 59 is refused with ReasonOffsetRange at the
// offset's sign. tomllib (CPython 3.13.13 Lib/tomllib, measured
// 2026-11-02) refuses each row at the sign, "(at line 1, column 24)",
// array row column 25, while BurntSushi v1.6.0 accepts it (toml-test
// invalid/datetime/offset-overflow-minute; base#1441 design cycle 10).
// Column 24 is counted by hand: the value starts at column 5 and the
// 19-byte datetime ends at column 23. tomllib accepts the controls: the
// in-range minute 59 and the same bytes inside a basic string.
func TestCheckRefusesOffsetMinuteOutOfRange(t *testing.T) {
	for _, tc := range []struct {
		src       string
		line, col int
	}{
		{"d = 1985-06-18 17:04:07+12:60\n", 1, 24},
		{"d = 1985-06-18T17:04:07-12:60\n", 1, 24},
		{"d = 1985-06-18T17:04:07+00:60\n", 1, 24},
		{"d = [1985-06-18T17:04:07+12:60]\n", 1, 25},
	} {
		err := Check("t.toml", []byte(tc.src))
		var r *Refusal
		if !errors.As(err, &r) {
			t.Errorf("Check(%q) = %v, want *Refusal", tc.src, err)
			continue
		}
		if r.File != "t.toml" || r.Line != tc.line || r.Col != tc.col || r.Reason != ReasonOffsetRange {
			t.Errorf("Check(%q) Refusal = {%q %d %d %v}, want {\"t.toml\" %d %d ReasonOffsetRange}",
				tc.src, r.File, r.Line, r.Col, r.Reason, tc.line, tc.col)
			continue
		}
		prefix := fmt.Sprintf("t.toml:%d:%d: ", tc.line, tc.col)
		if !strings.HasPrefix(r.Error(), prefix) {
			t.Errorf("Check(%q) Error() = %q, want prefix %q", tc.src, r.Error(), prefix)
		}
	}
	for _, src := range []string{
		"d = 1985-06-18 17:04:07+12:59\n",
		"s = \"1985-06-18 17:04:07+12:60\"\n",
	} {
		if err := Check("t.toml", []byte(src)); err != nil {
			t.Errorf("Check(%q) = %v, want nil", src, err)
		}
	}
}

// An offset hour above 23 is refused with ReasonOffsetRange at the
// offset's sign. tomllib (CPython 3.13.13 Lib/tomllib, measured
// 2026-11-02, base#1441 design run2 r1 cycle 10b) refuses each row at
// the sign, "(at line 1, column 24)", array row column 25, while
// BurntSushi v1.6.0 accepts it (prints +2400). The TOML 1.0 ABNF limits
// time-hour in time-numoffset to 00-23. Column 24 is counted by hand:
// the value starts at column 5 and the 19-byte datetime ends at column
// 23. tomllib accepts the controls: hour 23 with either sign and the
// same bytes inside a basic string.
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
		err := Check("t.toml", []byte(tc.src))
		var r *Refusal
		if !errors.As(err, &r) {
			t.Errorf("Check(%q) = %v, want *Refusal", tc.src, err)
			continue
		}
		if r.File != "t.toml" || r.Line != tc.line || r.Col != tc.col || r.Reason != ReasonOffsetRange {
			t.Errorf("Check(%q) Refusal = {%q %d %d %v}, want {\"t.toml\" %d %d ReasonOffsetRange}",
				tc.src, r.File, r.Line, r.Col, r.Reason, tc.line, tc.col)
			continue
		}
		prefix := fmt.Sprintf("t.toml:%d:%d: ", tc.line, tc.col)
		if !strings.HasPrefix(r.Error(), prefix) {
			t.Errorf("Check(%q) Error() = %q, want prefix %q", tc.src, r.Error(), prefix)
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

// A date-bearing value whose year is 0000 is refused at the value's
// first byte with tomllib's own wording. tomllib (CPython 3.13.13
// Lib/tomllib, measured 2026-11-02, base#1441 design run2 r1 cycle 10c)
// refuses each row with "Invalid date or datetime (at line 1, column
// 5)", array row column 6, inline-table row column 10, while BurntSushi
// v1.6.0 accepts every row (prints 0000-01-01 00:00:00 +0000 UTC). The
// year refusal wins over the offset-hour one in the combined row
// (tomllib column 5, not the sign at 24). tomllib accepts the controls:
// year 0001 in all three forms, year 9999, and the same text inside
// strings, keys, a header and a comment.
func TestCheckRefusesYearZeroDate(t *testing.T) {
	for _, tc := range []struct {
		src       string
		line, col int
	}{
		{"a = 0000-01-01\n", 1, 5},
		{"b = 0000-01-01T00:00:00\n", 1, 5},
		{"c = 0000-01-01T00:00:00Z\n", 1, 5},
		{"e = 0000-01-01 00:00:00\n", 1, 5},
		{"g = [0000-01-01]\n", 1, 6},
		{"h = {x = 0000-01-01T00:00:00Z}\n", 1, 10},
		{"a = 0000-01-01T00:00:00+24:00\n", 1, 5},
	} {
		err := Check("t.toml", []byte(tc.src))
		var r *Refusal
		if !errors.As(err, &r) {
			t.Errorf("Check(%q) = %v, want *Refusal", tc.src, err)
			continue
		}
		want := fmt.Sprintf("t.toml:%d:%d: Invalid date or datetime (at line %d, column %d)",
			tc.line, tc.col, tc.line, tc.col)
		if r.File != "t.toml" || r.Line != tc.line || r.Col != tc.col || r.Error() != want {
			t.Errorf("Check(%q) = {%q %d %d %q}, want {\"t.toml\" %d %d %q}",
				tc.src, r.File, r.Line, r.Col, r.Error(), tc.line, tc.col, want)
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

// A multi-line basic string may hold one or two `"` of its own; the gate's
// lexer must keep the string open across them (base#1441 review round 1,
// finding 1). tomllib (CPython 3.13.13 Lib/tomllib, run 2026-11-02)
// refuses the first two rows, `Unescaped '\' in a string`, and BurntSushi
// v1.6.0 accepts them as TOML 1.1 escapes, so the gate refuses each at its
// backslash, counted by hand: a(1) ' '(2) =(3) ' '(4) "(5) "(6) "(7) a(8)
// "(9) ' '(10) \(11); in the second row x(8) "(9) "(10) ' '(11) \(12).
// tomllib accepts the controls: a line ending after an embedded quote
// inside an inline table's multi-line string is string content, not a
// line ending of the inline table, and so is a brace.
func TestCheckLexesQuotesInsideMultiLineBasicString(t *testing.T) {
	for _, tc := range []struct {
		src       string
		line, col int
	}{
		{"a = \"\"\"a\" \\e\"\"\"\n", 1, 11},
		{"a = \"\"\"x\"\" \\x41\"\"\"\n", 1, 12},
	} {
		err := Check("t.toml", []byte(tc.src))
		var r *Refusal
		if !errors.As(err, &r) {
			t.Errorf("Check(%q) = %v, want *Refusal", tc.src, err)
			continue
		}
		if r.Line != tc.line || r.Col != tc.col || r.Reason != ReasonEscape {
			t.Errorf("Check(%q) Refusal = {%d %d %v}, want {%d %d ReasonEscape}", tc.src, r.Line, r.Col, r.Reason, tc.line, tc.col)
		}
	}
	for _, src := range []string{
		"a = {b = \"\"\"a\"\n\"\"\"}\n",
		"a = \"\"\"a\" {\"\"\"\n",
		"a = {b = \"\"\"a\" , \"\"\"}\n",
	} {
		if err := Check("t.toml", []byte(src)); err != nil {
			t.Errorf("Check(%q) = %v, want nil", src, err)
		}
	}
}

// The date, offset and seconds rules read the value tokens a TOML parser
// reads, wherever comments and line endings put them (base#1441 review
// round 1, finding 2). tomllib (CPython 3.13.13 Lib/tomllib, run
// 2026-11-02) refuses the year-zero row "Invalid date or datetime (at line
// 2, column 3)", and BurntSushi v1.6.0 accepts it, so the gate must
// refuse it at 2:3, the value's first byte after the two-space indent.
// The offset-hour and seconds rows behind the same comment keep their
// reasons: the sign at 2:22 (the 19-byte datetime runs from column 3 to
// 21) and the value at 2:3.
func TestCheckReadsValueTokensBehindComments(t *testing.T) {
	for _, tc := range []struct {
		src       string
		line, col int
		reason    Reason
	}{
		{"a = [ # comment\n  0000-01-01\n]\n", 2, 3, ReasonDateRange},
		{"a = [ # c\n  2021-01-01T00:00:00+24:00\n]\n", 2, 22, ReasonOffsetRange},
		{"a = [ # c\n  07:32\n]\n", 2, 3, ReasonTimeNoSeconds},
	} {
		err := Check("t.toml", []byte(tc.src))
		var r *Refusal
		if !errors.As(err, &r) {
			t.Errorf("Check(%q) = %v, want *Refusal", tc.src, err)
			continue
		}
		if r.Line != tc.line || r.Col != tc.col || r.Reason != tc.reason {
			t.Errorf("Check(%q) Refusal = {%d %d %v}, want {%d %d %v}", tc.src, r.Line, r.Col, r.Reason, tc.line, tc.col, tc.reason)
		}
	}
}

// A multi-line literal string may end in one or two single quotes of
// its own before its closing delimiter of three, so a value written as x
// followed by four single quotes is the string x plus one quote, and
// with five, x plus two; the gate must lex past every closing quote and
// still see a later basic string's escape (base#1441 review round 2,
// finding 1). tomllib (CPython 3.13.13 Lib/tomllib, run 2026-11-02)
// refuses each refused row with "Unescaped '\' in a string" on line 2
// and BurntSushi v1.6.0 accepts it; tomllib accepts each control. The
// position is the backslash, counted by hand: b(1) ' '(2) =(3) ' '(4)
// "(5) \(6); in the array row a(1) ' '(2) =(3) ' '(4) [(5) '(6) '(7)
// '(8) x(9) '(10) '(11) '(12) '(13) ,(14) ' '(15) "(16) \(17).
func TestCheckLexesMultiLineLiteralClosingQuotes(t *testing.T) {
	for _, tc := range []struct {
		src       string
		line, col int
	}{
		{"a = '''x''''\nb = \"\\e\"\n", 2, 6},
		{"a = '''x''''\nb = \"\\x41\"\n", 2, 6},
		{"a = '''x'''''\nb = \"\\e\"\n", 2, 6},
		{"a = '''x'''''\nb = \"\\x41\"\n", 2, 6},
		{"a = ['''x'''', \"\\e\"]\n", 1, 17},
	} {
		err := Check("t.toml", []byte(tc.src))
		var r *Refusal
		if !errors.As(err, &r) {
			t.Errorf("Check(%q) = %v, want *Refusal", tc.src, err)
			continue
		}
		if r.Line != tc.line || r.Col != tc.col || r.Reason != ReasonEscape {
			t.Errorf("Check(%q) Refusal = {%d %d %v}, want {%d %d ReasonEscape}", tc.src, r.Line, r.Col, r.Reason, tc.line, tc.col)
		}
	}
	for _, src := range []string{
		"a = '''x''''\nb = \"ok\"\n",
		"a = '''x'''''\nb = \"ok\"\n",
	} {
		if err := Check("t.toml", []byte(src)); err != nil {
			t.Errorf("Check(%q) = %v, want nil", src, err)
		}
	}
}

// A dotted key under an array-of-tables header belongs to the current
// element of that array, not to the root table, so a later [b] header
// names a different table (base#1441 review round 2, finding 2). tomllib
// (CPython 3.13.13 Lib/tomllib, run 2026-11-02) accepts both nil rows.
// It refuses both refused rows ("Cannot declare ('a', 'b') twice" and
// "Cannot declare ('b',) twice") and BurntSushi v1.6.0 accepts them: the
// header names the table a dotted key created, in the current element
// and at the root. The gate refuses them with ReasonRedefine at the
// header's `[`, line 3 column 1, as TestCheckRefusesHeaderOverDottedTable
// fixes for that reason.
func TestCheckScopesDottedKeysToArrayOfTablesElement(t *testing.T) {
	for _, src := range []string{
		"[[a]]\nb.c = 1\n[b]\nx = 1\n",
		"[[a]]\nb.c = 1\n[[a]]\nb.c = 2\n[b]\nx = 1\n",
	} {
		if err := Check("t.toml", []byte(src)); err != nil {
			t.Errorf("Check(%q) = %v, want nil", src, err)
		}
	}
	for _, src := range []string{
		"[[a]]\nb.c = 1\n[a.b]\nx = 1\n",
		"b.c = 1\n[[a]]\n[b]\n",
	} {
		err := Check("t.toml", []byte(src))
		var r *Refusal
		if !errors.As(err, &r) {
			t.Errorf("Check(%q) = %v, want *Refusal", src, err)
			continue
		}
		if r.Line != 3 || r.Col != 1 || r.Reason != ReasonRedefine {
			t.Errorf("Check(%q) Refusal = {%d %d %v}, want {3 1 ReasonRedefine}", src, r.Line, r.Col, r.Reason)
		}
	}
}

// Every member of the duplicate class reads "Cannot overwrite a value
// (at line L, column C)": the issue base#1441 acceptance criterion and
// ADR-00000039 line 129 fix that text for the class, so a header that
// defines a table a second time speaks it too, whatever internal reason
// the gate records (base#1441 redesign r3 R7). tomllib (CPython 3.13.13
// Lib/tomllib, run 2026-11-02) refuses every row, as "Cannot declare
// ... twice". BurntSushi v1.6.0 (run 2026-11-02, review round 2 finding
// 3) refuses four rows itself, "Key 'x' has already been defined." for
// `[x]\n[x]\n`, `[x]\ny = 1\n[x]\n` and `[[x]]\n[x]\n` and "Key 'a' has
// already been defined." for `a = {b = 1}\n[a]\n`; it accepts the two
// header-over-dotted-key rows, `a.b = 1\n[a]\n` and
// `[a]\nb.c = 1\n[a.b]\n`, which only the gate refuses. The reason and the
// position are the gate's own: ReasonRedefine at the second header's `[`,
// column 1, the line counted by hand.
func TestCheckRedefinedTableSpeaksOverwrite(t *testing.T) {
	for _, tc := range []struct {
		src  string
		line int
	}{
		{"[x]\n[x]\n", 2},
		{"[x]\ny = 1\n[x]\n", 3},
		{"[[x]]\n[x]\n", 2},
		{"a.b = 1\n[a]\n", 2},
		{"a = {b = 1}\n[a]\n", 2},
		{"[a]\nb.c = 1\n[a.b]\n", 3},
	} {
		err := Check("t.toml", []byte(tc.src))
		var r *Refusal
		if !errors.As(err, &r) {
			t.Errorf("Check(%q) = %v, want *Refusal", tc.src, err)
			continue
		}
		if r.File != "t.toml" || r.Line != tc.line || r.Col != 1 || r.Reason != ReasonRedefine {
			t.Errorf("Check(%q) Refusal = {%q %d %d %v}, want {\"t.toml\" %d 1 ReasonRedefine}",
				tc.src, r.File, r.Line, r.Col, r.Reason, tc.line)
			continue
		}
		want := fmt.Sprintf("t.toml:%d:1: Cannot overwrite a value (at line %d, column 1)", tc.line, tc.line)
		if r.Error() != want {
			t.Errorf("Check(%q) Error() = %q, want %q", tc.src, r.Error(), want)
		}
	}
}

// A key path is its decoded parts, so a quoted key part that holds a NUL
// (written \u0000) names a key of its own, never the dotted path its
// bytes around the NUL would spell (base#1441 review round 1, finding 2;
// ADR-00000039 requires acceptance). tomllib (a Lib/tomllib copy run
// under python3 -I, 2026-11-02) accepts each nil row and refuses the
// last row, two spellings of the same key, "Cannot overwrite a value";
// the gate refuses it with ReasonDuplicate at the second key's first
// byte, 2:1, counted by hand.
func TestCheckKeyPathsAreDecodedParts(t *testing.T) {
	for _, src := range []string{
		"\"a\\u0000b\" = 1\na.b = 2\n",
		"a.b = 1\n\"a\\u0000b\" = 2\n",
		"[\"a\\u0000b\"]\n[a.b]\n",
		"[a.b]\n[\"a\\u0000b\"]\n",
		"[[\"a\\u0000b\"]]\n[a.b]\n",
		"t = {\"a\\u0000b\" = 1, a.b = 2}\n",
		"t = {a.b = 1, \"a\\u0000b\" = 2}\n",
	} {
		if err := Check("t.toml", []byte(src)); err != nil {
			t.Errorf("Check(%q) = %v, want nil", src, err)
		}
	}
	const dup = "\"a\\u0000b\" = 1\n\"a\\U00000000b\" = 2\n"
	err := Check("t.toml", []byte(dup))
	var r *Refusal
	if !errors.As(err, &r) {
		t.Fatalf("Check(%q) = %v, want *Refusal", dup, err)
	}
	const want = "t.toml:2:1: Cannot overwrite a value (at line 2, column 1)"
	if r.Reason != ReasonDuplicate || r.Error() != want {
		t.Fatalf("Check(%q) = %v %q, want ReasonDuplicate %q", dup, r.Reason, r.Error(), want)
	}
}

// Normalize rewrites only a TOML 1.0 float literal: a float token that
// breaks the float ABNF (a leading zero, a doubled, leading or trailing
// underscore, a fraction with no digits) is left byte for byte, so the
// decoder refuses it as tomllib does, however far past float64 max its
// value would be (base#1441 review round 1, finding 1). tomllib (a
// Lib/tomllib copy under python3 -I, 2026-11-02) refuses every left row
// and loads every rewritten row as an infinity.
func TestNormalizeRewritesOnlyTOMLFloats(t *testing.T) {
	for _, src := range []string{
		"a = 01e999\n",
		"a = 00.5e999\n",
		"a = +01.5e999\n",
		"a = 0_1e999\n",
		"a = 1__0e999\n",
		"a = 1_e999\n",
		"a = 1e_999\n",
		"a = 1e+_999\n",
		"a = 1e999_\n",
		"a = 1.e999\n",
	} {
		if got := string(Normalize([]byte(src))); got != src {
			t.Errorf("Normalize(%q) = %q, want it unchanged", src, got)
		}
	}
	for _, tc := range []struct{ src, want string }{
		{"a = 1e999\n", "a = inf  \n"},
		{"a = 1_0e999\n", "a = inf    \n"},
		{"a = 1.0_0e99_9\n", "a = inf       \n"},
		{"a = 1E+999\n", "a = inf   \n"},
		{"a = -1e999\n", "a = -inf  \n"},
	} {
		if got := string(Normalize([]byte(tc.src))); got != tc.want {
			t.Errorf("Normalize(%q) = %q, want %q", tc.src, got, tc.want)
		}
	}
}

// An array-of-tables header over an array value, or below an inline
// table or an array value, defines a key path a second time, as the
// other two definition sites already refuse (base#1441 redesign r3 R8,
// review round 1 finding 4). Inputs are toml-test v2.2.0 (ce08da1)
// invalid/ files vendored under testdata/toml-test, which tomllib refuses
// (p1441/py-1.0.0.txt lines 22, 186, 440) and BurntSushi v1.6.0 refuses
// in its own words. Each L:C is counted by hand in the file: the `[[`
// line, column 1. The controls are accepted by tomllib: an array of
// tables twice, a sub-table header before its parent, and the spec's
// array-of-tables files.
func TestCheckRefusesArrayOfTablesOverValue(t *testing.T) {
	for _, tc := range []struct {
		file      string
		line, col int
	}{
		{"invalid/array/tables-01.toml", 4, 1},
		{"invalid/inline-table/overwrite-04.toml", 3, 1},
		{"invalid/table/duplicate-key-10.toml", 2, 1},
	} {
		src, err := os.ReadFile(filepath.Join("testdata", "toml-test", tc.file))
		if err != nil {
			t.Fatal(err)
		}
		err = Check(tc.file, src)
		var r *Refusal
		if !errors.As(err, &r) {
			t.Errorf("%s: Check() = %v, want *Refusal", tc.file, err)
			continue
		}
		want := fmt.Sprintf("%s:%d:%d: Cannot overwrite a value (at line %d, column %d)",
			tc.file, tc.line, tc.col, tc.line, tc.col)
		if r.Reason != ReasonDuplicate || r.Error() != want {
			t.Errorf("%s: Refusal = %v %q, want ReasonDuplicate %q", tc.file, r.Reason, r.Error(), want)
		}
	}
	for _, src := range []string{"[[x]]\n[[x]]\n", "[x.y]\n[x]\n"} {
		if err := Check("t.toml", []byte(src)); err != nil {
			t.Errorf("Check(%q) = %v, want nil", src, err)
		}
	}
	files, err := filepath.Glob(filepath.Join("testdata", "toml-test", "valid", "spec-1.0.0", "array-of-tables-*.toml"))
	if err != nil || len(files) == 0 {
		t.Fatalf("glob array-of-tables-*.toml: %v, %d files", err, len(files))
	}
	for _, f := range files {
		src, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		if err := Check(f, src); err != nil {
			t.Errorf("Check(%s) = %v, want nil", f, err)
		}
	}
}

// Check reports the first refusal in document order: a lexical refusal
// (here a `\e` escape) is reported when the structural reading reaches
// it, so a duplicate on an earlier line is reported first (base#1441
// redesign r2 R4b, review round 2 finding 1). tomllib (a CPython 3.13.13
// Lib/tomllib copy under python3 -I, run 2026-11-02) refuses both R4b
// rows on line 2, "Cannot overwrite a value (at line 2, column 6)" and
// "Cannot declare ('x',) twice (at line 2, column 3)", not at the line 3
// escape. The gate's position is the second definition's first byte,
// 2:1, counted by hand. In the last two rows the reading stops on line 1,
// where tomllib refuses them too ("Unclosed inline table", "Unclosed
// array"): a bare value ends at the blank after it, so the next byte the
// inline table or array reads is not a `,` or its closing bracket, and
// the gate refuses there, before the line 2 escape (base#1441 review
// round 1 finding 4): `c` at 1:12, a(1) ' '(2) =(3) ' '(4) {(5) b(6)
// ' '(7) =(8) ' '(9) 1(10) ' '(11) c(12); `2` at 1:8, x(1) ' '(2) =(3)
// ' '(4) [(5) 1(6) ' '(7) 2(8).
func TestCheckRefusesInDocumentOrder(t *testing.T) {
	for _, tc := range []struct {
		src       string
		line, col int
		reason    Reason
		text      string
	}{
		{"a = 1\na = 2\nb = \"\\e\"\n", 2, 1, ReasonDuplicate, "Cannot overwrite a value (at line 2, column 1)"},
		{"[x]\n[x]\nb = \"\\e\"\n", 2, 1, ReasonRedefine, "Cannot overwrite a value (at line 2, column 1)"},
		{"a = {b = 1 c = 2}\nd = \"\\e\"\n", 1, 12, ReasonSyntax, wantSyntaxText},
		{"x = [1 2]\nd = \"\\e\"\n", 1, 8, ReasonSyntax, wantSyntaxText},
	} {
		err := Check("t.toml", []byte(tc.src))
		var r *Refusal
		if !errors.As(err, &r) {
			t.Errorf("Check(%q) = %v, want *Refusal", tc.src, err)
			continue
		}
		want := fmt.Sprintf("t.toml:%d:%d: %s", tc.line, tc.col, tc.text)
		if r.Line != tc.line || r.Col != tc.col || r.Reason != tc.reason || r.Error() != want {
			t.Errorf("Check(%q) = %v %q, want %v %q", tc.src, r.Reason, r.Error(), tc.reason, want)
		}
	}
}

// Where the structural reading cannot go on, Check refuses at the byte it
// stopped on, the first byte in document order that breaks the TOML 1.0
// grammar, and reads no further: no later rule (the escape on line 2 of
// the first row) and no second, lossy reader of the rest decides the
// verdict (base#1441 review round 1 finding 3). Each row's position is
// counted by hand: the `\n` where the header's `]` should be (1:3); the
// `,` where an inline table's first key should be (1:6, t(1) ' '(2) =(3)
// ' '(4) {(5) ,(6)); the `}` where `=` should be (1:7); the `c` and the
// second `"` where a `,` should be (1:14, 1:10); and the last byte, the
// lone `[`, when the document ends inside a header (2:1). The rest are
// one row for each other place the reading stops: the byte where a key or
// its `=` should start, the byte after a complete statement, the byte
// where a value should start, the line ending that leaves a one-line
// string unclosed, and the last byte when the document ends inside a key,
// a value or a multi-line string.
func TestCheckRefusesAtTheStopPoint(t *testing.T) {
	read := func(p string) string {
		b, err := os.ReadFile(filepath.Join("testdata", p))
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	for _, tc := range []struct {
		name, src string
		line, col int
	}{
		{"header-newline", "[a\nb = \"\\e\"\n", 1, 3},
		{"empty-01", read("toml-test/invalid/inline-table/empty-01.toml"), 1, 6},
		{"empty-02", read("toml-test/invalid/inline-table/empty-02.toml"), 1, 6},
		{"inline-no-equals", read("forms/stop-inline-no-equals.toml"), 1, 7},
		{"inline-no-comma", read("forms/stop-inline-no-comma.toml"), 1, 14},
		{"array-no-comma", read("forms/stop-array-no-comma.toml"), 1, 10},
		{"header-eof", read("forms/stop-header-eof.toml"), 2, 1},
		{"key-missing", "= 1\n", 1, 1},
		{"key-eof", "a.", 1, 2},
		{"equals-missing", "a 1\n", 1, 3},
		{"statement-trailing", "a = 1 b\n", 1, 7},
		{"value-eof", "a =", 1, 3},
		{"value-missing", "a = ,\n", 1, 5},
		{"string-line-end", "a = \"x\nb = 1\n", 1, 7},
		{"string-eof", "a = \"\"\"x", 1, 8},
	} {
		err := Check("t.toml", []byte(tc.src))
		var r *Refusal
		if !errors.As(err, &r) {
			t.Errorf("%s: Check(%q) = %v, want *Refusal", tc.name, tc.src, err)
			continue
		}
		want := fmt.Sprintf("t.toml:%d:%d: %s", tc.line, tc.col, wantSyntaxText)
		if r.Reason != ReasonSyntax || r.Error() != want {
			t.Errorf("%s: Check(%q) = %v %q, want ReasonSyntax %q", tc.name, tc.src, r.Reason, r.Error(), want)
		}
	}
}

// wantSyntaxText is the stop-point refusal's text, written as a literal.
const wantSyntaxText = "invalid TOML 1.0 syntax"
