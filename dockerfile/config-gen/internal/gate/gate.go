// Package gate refuses the TOML forms that BurntSushi accepts but the
// TOML 1.0 oracle (tomllib) refuses, so that gate plus BurntSushi gives
// the oracle's verdict (base#1441).
package gate

import (
	"bytes"
	"errors"
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"
)

// decimalFloat matches a TOML 1.0 decimal float with its underscores
// removed: an integer part with a fraction, an exponent or both.
var decimalFloat = regexp.MustCompile(`^[+-]?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$`)

// Reason names why Check refused its input.
type Reason int

const (
	// ReasonEscape is a `\e` or `\xHH` escape in a basic string (TOML 1.1
	// only).
	ReasonEscape Reason = iota + 1
	// ReasonInlineNewline is a line ending whose innermost open container
	// is an inline table (TOML 1.1 only).
	ReasonInlineNewline
	// ReasonInlineTrailingComma is a comma followed, after optional
	// spaces or tabs, by the `}` that closes an inline table (TOML 1.1
	// only).
	ReasonInlineTrailingComma
	// ReasonTimeNoSeconds is a time value written as HH:MM, without the
	// seconds the TOML 1.0 partial-time requires (TOML 1.1 only).
	ReasonTimeNoSeconds
	// ReasonBOM is a UTF-8 byte order mark (EF BB BF) at the start of the
	// document, which the TOML 1.0 oracle refuses.
	ReasonBOM
	// ReasonDuplicate is a key assigned a second time in the same table,
	// which the TOML 1.0 oracle reports as "Cannot overwrite a value".
	ReasonDuplicate
	// ReasonRedefine is a table header whose path names a table that
	// dotted keys already created, which the TOML 1.0 oracle reports as
	// "Cannot redefine a table".
	ReasonRedefine
	// ReasonOffsetRange is an offset datetime whose offset hour is above
	// 23 or whose offset minute is above 59, which the TOML 1.0 oracle
	// refuses at the offset's sign.
	ReasonOffsetRange
	// ReasonDateRange is a date-bearing value whose year is 0000, which
	// the TOML 1.0 oracle refuses at the value's first byte as "Invalid
	// date or datetime".
	ReasonDateRange
	// ReasonDepth is a value nested so deep that tomllib's parse passes
	// CPython's recursion limit, which the TOML 1.0 oracle reports as a
	// RecursionError; it is refused at the first byte of the outermost
	// value of the nesting chain.
	ReasonDepth
)

// Refusal is the error Check returns. Line and Col are 1-based; Col is
// the byte column after the last LF.
type Refusal struct {
	File      string
	Line, Col int
	Reason    Reason
	Text      string
}

// Error returns `File:Line:Col: Text`.
func (r *Refusal) Error() string {
	return fmt.Sprintf("%s:%d:%d: %s", r.File, r.Line, r.Col, r.Text)
}

// The tomllib messages Check repeats word for word; oracleRefusal appends
// tomllib's position suffix to them.
const (
	msgOverwrite = "Cannot overwrite a value"
	msgRedefine  = "Cannot redefine a table"
	msgDateRange = "Invalid date or datetime"
)

// depthText is the depth refusal's text; tomllib's RecursionError has no
// position to repeat.
const depthText = "nesting deeper than tomllib accepts (Python recursion limit)"

// refusal returns the *Refusal for reason at offset off of src.
func refusal(label string, src []byte, off int, reason Reason, text string) *Refusal {
	line, col := position(src, off)
	return &Refusal{File: label, Line: line, Col: col, Reason: reason, Text: text}
}

// oracleRefusal returns the *Refusal for reason at offset off of src
// whose text is tomllib's msg followed by " (at line L, column C)".
func oracleRefusal(label string, src []byte, off int, reason Reason, msg string) *Refusal {
	r := refusal(label, src, off, reason, "")
	r.Text = fmt.Sprintf("%s (at line %d, column %d)", msg, r.Line, r.Col)
	return r
}

// Check returns nil, or a *Refusal that names label and the offending
// byte of src.
func Check(label string, src []byte) error {
	if bytes.HasPrefix(src, []byte("\xEF\xBB\xBF")) {
		return refusal(label, src, 0, ReasonBOM, "leading byte order mark is not TOML 1.0")
	}
	var open []byte // innermost last: '{' inline table, '[' array or header
	// Table rules (duplicate keys, redefined tables) are the structural
	// pass's alone: checkTables follows headers, array-of-tables elements
	// and dotted keys the way tomllib does (base#1441 review round 2).
	for i := 0; i < len(src); i++ {
		switch {
		case src[i] == '#':
			for i < len(src) && !lineEnd(src, i) {
				i++
			}
			i-- // the loop step lands on the line ending
		case src[i] == '\'':
			i = skipLiteral(src, i)
		case src[i] == '"':
			last, bad := scanBasic(src, i)
			if bad >= 0 {
				return refusal(label, src, bad, ReasonEscape, `escape sequence \`+string(src[bad+1])+` is not TOML 1.0`)
			}
			i = last
		case src[i] == '{' || src[i] == '[':
			open = append(open, src[i])
		case (src[i] == '}' || src[i] == ']') && len(open) > 0:
			open = open[:len(open)-1]
		case lineEnd(src, i) && len(open) > 0 && open[len(open)-1] == '{':
			return refusal(label, src, i, ReasonInlineNewline, "line ending inside an inline table is not TOML 1.0")
		case src[i] == ',' && len(open) > 0 && open[len(open)-1] == '{':
			j := i + 1
			for j < len(src) && (src[j] == ' ' || src[j] == '\t') {
				j++
			}
			if j < len(src) && src[j] == '}' {
				return refusal(label, src, i, ReasonInlineTrailingComma, "trailing comma in an inline table is not TOML 1.0")
			}
		}
	}
	return checkTables(label, src)
}

// Normalize returns a copy of src, which Check accepted, in which every
// value-position float literal past float64 max is replaced by `inf`,
// `+inf` or `-inf` (its sign kept) padded with spaces to the literal's
// length; tomllib loads such a literal as an infinity, BurntSushi refuses
// it (base#1441). Every other byte keeps its value and offset, so a
// decoder's line and column still index src. Decode Normalize(src),
// never src itself.
func Normalize(src []byte) []byte {
	out := bytes.Clone(src)
	t := newTables("", src)
	t.scalar = func(start, end int) {
		tok := strings.ReplaceAll(string(src[start:end]), "_", "")
		if !decimalFloat.MatchString(tok) || !strings.ContainsAny(tok, ".eE") {
			return
		}
		if f, err := strconv.ParseFloat(tok, 64); !errors.Is(err, strconv.ErrRange) || !math.IsInf(f, 0) {
			return
		}
		inf := "inf"
		if tok[0] == '+' || tok[0] == '-' {
			inf = tok[:1] + inf
		}
		copy(out[start:end], inf+strings.Repeat(" ", end-start-len(inf)))
	}
	_ = t.document()
	return out
}

// isDigit reports whether b is an ASCII digit.
func isDigit(b byte) bool { return b >= '0' && b <= '9' }

// isBareKeyByte reports whether b may appear in a bare key.
func isBareKeyByte(b byte) bool {
	return isDigit(b) || b == '-' || b == '_' || (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z')
}

// lineEnd reports whether a line ending (LF, or the CR of CRLF) starts at
// offset i of src.
func lineEnd(src []byte, i int) bool {
	return src[i] == '\n' || (src[i] == '\r' && i+1 < len(src) && src[i+1] == '\n')
}

// skipLiteral returns the offset of the last quote of the literal string
// (single- or multi-line) that opens at offset i of src, or len(src)-1
// when it is unclosed.
func skipLiteral(src []byte, i int) int {
	delim := []byte{'\''}
	if bytes.HasPrefix(src[i:], []byte("'''")) {
		delim = []byte("'''")
	}
	end := bytes.Index(src[i+len(delim):], delim)
	if end < 0 {
		return len(src) - 1
	}
	return closeQuotes(src, i+len(delim)+end, '\'', len(delim)) - 1
}

// closeQuotes returns the offset just past the closing delimiter, n
// quotes q, that starts at offset j of src. A multi-line string (n == 3)
// may end in one or two q of its own before that delimiter, so the
// delimiter's run takes up to two more q (TOML 1.0 ml-basic-body,
// ml-literal-body). Every lexer in this package closes strings here
// (base#1441 review round 2).
func closeQuotes(src []byte, j int, q byte, n int) int {
	k := j + n
	for extra := 0; n == 3 && extra < 2 && k < len(src) && src[k] == q; extra++ {
		k++
	}
	return k
}

// scanBasic lexes the basic string (single- or multi-line) that opens
// at offset i of src. It returns the offset of the string's last byte
// (its closing quote, the last of up to two extra quotes a multi-line
// string may end with, the byte before the line ending that leaves a
// single-line string unclosed, or len(src)-1) and the offset of the
// first `\e` or `\x` escape's backslash, or -1. A `"` inside a
// multi-line string that does not start `"""` is content.
func scanBasic(src []byte, i int) (last, bad int) {
	n := 1
	if bytes.HasPrefix(src[i:], []byte(`"""`)) {
		n = 3
	}
	for j := i + n; j < len(src); {
		switch {
		case src[j] == '\\' && j+1 < len(src):
			if src[j+1] == 'e' || src[j+1] == 'x' {
				return j, j
			}
			j += 2
		case src[j] == '"' && n == 1:
			return j, -1
		case src[j] == '"' && bytes.HasPrefix(src[j:], []byte(`"""`)):
			return closeQuotes(src, j, '"', 3) - 1, -1
		case n == 1 && lineEnd(src, j):
			return j - 1, -1
		default:
			j++
		}
	}
	return len(src) - 1, -1
}

// position returns the 1-based line and byte column of offset off in src.
func position(src []byte, off int) (line, col int) {
	line = 1 + bytes.Count(src[:off], []byte{'\n'})
	col = off - bytes.LastIndexByte(src[:off], '\n')
	return line, col
}
