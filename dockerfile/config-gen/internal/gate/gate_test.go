package gate

import (
	"errors"
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
