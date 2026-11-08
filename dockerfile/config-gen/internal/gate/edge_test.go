package gate

import (
	"bytes"
	"errors"
	"testing"
)

// A document may end at any byte, with no line ending after its last
// token, and Check reads it to that byte without reading past it
// (base#1441). Verdicts are tomllib's (CPython 3.13 Lib/tomllib, measured
// 2026-11-08): it accepts the nil rows and refuses every refused row,
// "(at end of document)" or at the stray byte; the forms/eof-* files put
// each row in front of the live oracle. A refused row is ReasonSyntax at
// the byte where the reading stops, or the document's last byte when it
// stops at the end; columns are counted by hand, e.g. "a = {b = 1,":
// a(1) ' '(2) =(3) ' '(4) {(5) b(6) ' '(7) =(8) ' '(9) 1(10) ,(11), and
// `a = """x""""""` stops at its sixth closing quote, column 14: a closing
// delimiter takes at most two quotes of the body before it. The \x5c in
// the sources is the backslash.
func TestCheckReadsToTheLastByte(t *testing.T) {
	for _, src := range []string{
		"a = 1",
		"a = 1979-05-27T07:32:00Z",
		"a = \"\"\"x\"\"\"",
		"a = '''x'''",
		"a = \"\"\"x\"\"\"\"\"",
		"Z = 1\n",
		"[Z]\nz = 1",
	} {
		if err := Check("t.toml", []byte(src)); err != nil {
			t.Errorf("Check(%q) = %v, want nil", src, err)
		}
	}
	for _, tc := range []struct {
		src string
		col int
	}{
		{"a", 1},
		{"[a", 2},
		{"a = {", 5},
		{"a = {b = 1", 10},
		{"a = {b = 1,", 11},
		{"a = \"\x5c", 6},
		{"a = \"x\x5c", 7},
		{"a = \"x\r", 7},
		{"a = 2021-01-01 1", 16},
		{"a = 2021-01-01 12", 16},
		{"a = \"\"\"x\"\"\"\"\"\"\n", 14},
		{"a = '''x''''''\n", 14},
	} {
		err := Check("t.toml", []byte(tc.src))
		var r *Refusal
		if !errors.As(err, &r) {
			t.Errorf("Check(%q) = %v, want *Refusal", tc.src, err)
			continue
		}
		if r.File != "t.toml" || r.Line != 1 || r.Col != tc.col || r.Reason != ReasonSyntax {
			t.Errorf("Check(%q) Refusal = {%q %d %d %v}, want {\"t.toml\" 1 %d ReasonSyntax}",
				tc.src, r.File, r.Line, r.Col, r.Reason, tc.col)
		}
	}
}

// The offset of an offset datetime with fractional seconds is held to the
// same ranges as one without (base#1441): tomllib refuses offset hour 24
// and offset minute 60 after a fraction of any length (CPython 3.13
// Lib/tomllib, measured 2026-11-08) while BurntSushi v1.6.0 accepts them.
// The refusal is ReasonOffsetRange at the offset's sign, counted by hand:
// the value starts at column 5, the 19-byte datetime ends at column 23,
// `.1` is columns 24-25, so the sign is column 26; after `.123456` it is
// column 31. tomllib accepts the controls.
func TestCheckRefusesOffsetRangeAfterFraction(t *testing.T) {
	for _, tc := range []struct {
		src string
		col int
	}{
		{"a = 2021-01-01T00:00:00.1+24:00\n", 26},
		{"a = 2021-01-01T00:00:00.1-23:60\n", 26},
		{"a = 2021-01-01T00:00:00.123456+24:00\n", 31},
		{"a = 2021-01-01 00:00:00.123456-00:60\n", 31},
	} {
		err := Check("t.toml", []byte(tc.src))
		var r *Refusal
		if !errors.As(err, &r) {
			t.Errorf("Check(%q) = %v, want *Refusal", tc.src, err)
			continue
		}
		if r.File != "t.toml" || r.Line != 1 || r.Col != tc.col || r.Reason != ReasonOffsetRange {
			t.Errorf("Check(%q) Refusal = {%q %d %d %v}, want {\"t.toml\" 1 %d ReasonOffsetRange}",
				tc.src, r.File, r.Line, r.Col, r.Reason, tc.col)
		}
	}
	for _, src := range []string{
		"a = 2021-01-01T00:00:00.1+23:59\n",
		"a = 2021-01-01T00:00:00.123456-23:59\n",
	} {
		if err := Check("t.toml", []byte(src)); err != nil {
			t.Errorf("Check(%q) = %v, want nil", src, err)
		}
	}
}

// A lowercase `t` is a datetime delimiter like `T` and the space (TOML
// 1.0: "you may replace the T delimiter"), so a time without seconds after
// it is refused the same way (base#1441): tomllib refuses
// "a = 2021-01-01t10:00" (CPython 3.13 Lib/tomllib, measured 2026-11-08)
// while BurntSushi v1.6.0 accepts it. ReasonTimeNoSeconds at the value's
// first byte, column 5; an offset after `t` is held to its range at the
// sign, column 24. tomllib accepts the control with seconds.
func TestCheckReadsLowercaseDelimiter(t *testing.T) {
	for _, tc := range []struct {
		src    string
		col    int
		reason Reason
	}{
		{"a = 2021-01-01t10:00\n", 5, ReasonTimeNoSeconds},
		{"a = 2021-01-01t00:00:00+24:00\n", 24, ReasonOffsetRange},
	} {
		err := Check("t.toml", []byte(tc.src))
		var r *Refusal
		if !errors.As(err, &r) {
			t.Errorf("Check(%q) = %v, want *Refusal", tc.src, err)
			continue
		}
		if r.Line != 1 || r.Col != tc.col || r.Reason != tc.reason {
			t.Errorf("Check(%q) Refusal = {%d %d %v}, want {1 %d %v}", tc.src, r.Line, r.Col, r.Reason, tc.col, tc.reason)
		}
	}
	if err := Check("t.toml", []byte("a = 2021-01-01t10:00:00\n")); err != nil {
		t.Errorf("Check(lowercase t with seconds) = %v, want nil", err)
	}
}

// Normalize rewrites only a TOML 1.0 decimal float past float64 max
// (base#1441). A bare value that is not a TOML 1.0 float keeps its bytes,
// even when strconv would read it as one past float64 max: tomllib refuses
// `.5e999`, `+.5e999` and a lone `+` as "Invalid value" (CPython 3.13
// Lib/tomllib, measured 2026-11-08), so turning them into `inf` would make
// BurntSushi accept what the oracle refuses. Check leaves each to
// BurntSushi, so Normalize is handed it.
func TestNormalizeKeepsNonFloatTokens(t *testing.T) {
	for _, src := range []string{
		"a = .5e999\n",
		"a = +.5e999\n",
		"a = +\n",
		"a = -\n",
		"a = x.5e999\n",
	} {
		if err := Check("t.toml", []byte(src)); err != nil {
			t.Fatalf("Check(%q) = %v; the row needs Check to hand it on", src, err)
		}
		if got := Normalize([]byte(src)); !bytes.Equal(got, []byte(src)) {
			t.Errorf("Normalize(%q) = %q, want it unchanged", src, got)
		}
	}
}
