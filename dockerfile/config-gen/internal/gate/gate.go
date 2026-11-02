// Package gate refuses the TOML forms that BurntSushi accepts but the
// TOML 1.0 oracle (tomllib) refuses, so that gate plus BurntSushi gives
// the oracle's verdict (base#1441).
package gate

import (
	"bytes"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
)

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
	// ReasonDuplicate is a key path defined a second time where nothing
	// may extend it: a key assigned twice, a path through a value, or a
	// [[path]] over a value that is not an array of tables.
	ReasonDuplicate
	// ReasonRedefine is a table header, or a dotted key, whose path names
	// a table that a header or dotted keys already defined. It stays a
	// separate value so callers can tell the two apart; Error() renders
	// both reasons as "Cannot overwrite a value (at line L, column C)",
	// the duplicate class's one text (base#1441 acceptance criterion,
	// ADR-00000039).
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
	// ReasonSyntax is the byte where the structural reading stops because
	// the TOML 1.0 grammar allows nothing there: a header with no closing
	// bracket, a key with no `=`, a value missing, two values or pairs with
	// no comma between them, a string left unclosed. It is the first such
	// byte in document order, and nothing after it is read.
	ReasonSyntax
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

// The messages oracleRefusal follows with tomllib's position suffix: the
// duplicate class's contract text (base#1441 acceptance criterion) and
// tomllib's date-range message, word for word.
const (
	msgOverwrite = "Cannot overwrite a value"
	msgDateRange = "Invalid date or datetime"
)

// syntaxText is the text of a refusal where the structural reading
// stops.
const syntaxText = "invalid TOML 1.0 syntax"

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
// byte of src. One structural pass reads src in document order and raises
// each refusal where it reads the token that breaks a rule: a lexical one
// (an escape, a line ending or a trailing comma in an inline table), a
// table rule, or the grammar itself where the pass cannot go on. So the
// first refusal in the document is the one reported, as tomllib reports
// its first error, and no second reader of the bytes after a stop decides
// anything (base#1441 redesign r2 R4b, review round 1 finding 3).
func Check(label string, src []byte) error {
	if bytes.HasPrefix(src, []byte("\xEF\xBB\xBF")) {
		return refusal(label, src, 0, ReasonBOM, "leading byte order mark is not TOML 1.0")
	}
	t := newTables(label, src)
	err := t.document()
	if errors.Is(err, errStop) {
		// A stop at the end of the document names its last byte, so the
		// position is always a byte of src.
		return refusal(label, src, min(t.i, len(src)-1), ReasonSyntax, syntaxText)
	}
	return err
}

// escapeRefusal is the refusal for the `\e` or `\x` escape whose
// backslash is at offset off of src.
func escapeRefusal(label string, src []byte, off int) *Refusal {
	return refusal(label, src, off, ReasonEscape, `escape sequence \`+string(src[off+1])+` is not TOML 1.0`)
}

// newlineRefusal is the refusal for the line ending at offset off of src
// inside an inline table.
func newlineRefusal(label string, src []byte, off int) *Refusal {
	return refusal(label, src, off, ReasonInlineNewline, "line ending inside an inline table is not TOML 1.0")
}

// commaRefusal is the refusal for the inline table's trailing comma at
// offset off of src.
func commaRefusal(label string, src []byte, off int) *Refusal {
	return refusal(label, src, off, ReasonInlineTrailingComma, "trailing comma in an inline table is not TOML 1.0")
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
		if !isDecimalFloat(src[start:end]) {
			return
		}
		tok := strings.ReplaceAll(string(src[start:end]), "_", "")
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

// isDecimalFloat reports whether tok, as written, is a TOML 1.0 decimal
// float (base#1441 review round 1, finding 1):
//
//	float = dec-int ( exp / frac [ exp ] )
//	dec-int = [ "-" / "+" ] ( DIGIT / digit1-9 1*( DIGIT / "_" DIGIT ) )
//	frac = "." zero-prefixable-int
//	exp = ( "e" / "E" ) [ "-" / "+" ] zero-prefixable-int
//	zero-prefixable-int = DIGIT *( DIGIT / "_" DIGIT )
func isDecimalFloat(tok []byte) bool {
	i := 0
	if i < len(tok) && (tok[i] == '+' || tok[i] == '-') {
		i++
	}
	if i < len(tok) && tok[i] == '0' {
		i++
	} else if i = digitRun(tok, i); i < 0 {
		return false
	}
	more := false
	if i < len(tok) && tok[i] == '.' {
		if i = digitRun(tok, i+1); i < 0 {
			return false
		}
		more = true
	}
	if i < len(tok) && (tok[i] == 'e' || tok[i] == 'E') {
		i++
		if i < len(tok) && (tok[i] == '+' || tok[i] == '-') {
			i++
		}
		if i = digitRun(tok, i); i < 0 {
			return false
		}
		more = true
	}
	return more && i == len(tok)
}

// digitRun returns the offset just past the zero-prefixable-int (a digit,
// then digits each optionally after one underscore) that starts at offset
// i of tok, or -1 when no digit is there.
func digitRun(tok []byte, i int) int {
	if i >= len(tok) || !isDigit(tok[i]) {
		return -1
	}
	for i++; i < len(tok); i++ {
		if tok[i] == '_' && i+1 < len(tok) && isDigit(tok[i+1]) {
			i++
		} else if !isDigit(tok[i]) {
			break
		}
	}
	return i
}

// isDigit reports whether b is an ASCII digit.
func isDigit(b byte) bool { return b >= '0' && b <= '9' }

// lineEnd reports whether a line ending (LF, or the CR of CRLF) starts at
// offset i of src.
func lineEnd(src []byte, i int) bool {
	return src[i] == '\n' || (src[i] == '\r' && i+1 < len(src) && src[i+1] == '\n')
}

// closeQuotes returns the offset just past the closing delimiter, n
// quotes q, that starts at offset j of src. A multi-line string (n == 3)
// may end in one or two q of its own before that delimiter, so the
// delimiter's run takes up to two more q (TOML 1.0 ml-basic-body,
// ml-literal-body). The structural pass closes every string here
// (base#1441 review round 2).
func closeQuotes(src []byte, j int, q byte, n int) int {
	k := j + n
	for extra := 0; n == 3 && extra < 2 && k < len(src) && src[k] == q; extra++ {
		k++
	}
	return k
}

// position returns the 1-based line and byte column of offset off in src.
func position(src []byte, off int) (line, col int) {
	line = 1 + bytes.Count(src[:off], []byte{'\n'})
	col = off - bytes.LastIndexByte(src[:off], '\n')
	return line, col
}
