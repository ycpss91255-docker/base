// Package gate refuses six TOML 1.1-only forms that BurntSushi v1.6.0
// accepts and the TOML 1.0 oracle (tomllib) refuses (base#1850): a `\e`
// escape, a `\x` escape, a line ending inside an inline table, a trailing
// comma in an inline table, a time without seconds, and a leading byte
// order mark. It also refuses a date-bearing value with year 0000 and a
// datetime whose offset hour is above 23 or offset minute above 59, which
// BurntSushi v1.6.0 accepts and tomllib refuses (base#1851), and a key
// path a document defines twice, which tomllib refuses and BurntSushi
// v1.6.0 accepts in some forms (base#1851), and the byte where the
// structural reading stops because the TOML 1.0 grammar allows nothing
// there (base#1851).
package gate

import (
	"bytes"
	"errors"
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Reason names why Check refused its input.
type Reason int

const (
	// ReasonEscape is a `\e` or `\x` escape in a basic string (TOML 1.1
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
	// ReasonBOM is a byte order mark at the start of the file: UTF-8
	// (EF BB BF) or UTF-16 (FF FE, FE FF). TOML 1.0 has none.
	ReasonBOM
	// ReasonDateRange is a date-bearing value whose year is 0000, which
	// the TOML 1.0 oracle refuses at the value's first byte as "Invalid
	// date or datetime" (base#1851).
	ReasonDateRange
	// ReasonOffsetRange is a datetime whose offset hour is above 23 or
	// whose offset minute is above 59, which the TOML 1.0 oracle refuses
	// at the offset's sign (base#1851).
	ReasonOffsetRange
	// ReasonDefinedTwice is a key path defined a second time: a key
	// assigned twice, a path through a value, a [[path]] over a value that
	// is not an array of tables, or a table header or dotted key whose
	// path names a table a header or dotted keys already defined
	// (base#1851).
	ReasonDefinedTwice
	// ReasonSyntax is the byte where the structural reading stops because
	// the TOML 1.0 grammar allows nothing there: a header with no closing
	// bracket, a key with no `=`, a value missing, two values or pairs with
	// no comma between them, a string left unclosed. It is the first byte
	// the reading cannot go on from, and no rule after it decides the
	// verdict (base#1851).
	ReasonSyntax
)

// syntaxText is the text of a refusal where the structural reading
// stops.
const syntaxText = "invalid TOML 1.0 syntax"

// bomPrefixes is the whole list of leading byte order marks the decoder
// strips before it lexes (BurntSushi v1.6.0 parse.go, lines 47-51), each of
// which the TOML 1.0 oracle refuses (base#1850).
var bomPrefixes = [][]byte{[]byte("\xEF\xBB\xBF"), []byte("\xFF\xFE"), []byte("\xFE\xFF")}

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

// refusal returns the *Refusal for reason at offset off of src.
func refusal(label string, src []byte, off int, reason Reason, text string) *Refusal {
	line, col := position(src, off)
	return &Refusal{File: label, Line: line, Col: col, Reason: reason, Text: text}
}

// tokenPattern reads src left to right as comments, multi-line literal
// strings, literal strings, multi-line basic strings and basic strings;
// any other byte is skipped. A multi-line literal string stops at its
// first run of three single quotes, plus up to two quotes of content
// before it. A multi-line basic string may hold lone quotes and line ends
// and stops at its first `"""` (plus up to two quotes of content before
// it) or at a `\e` or `\x` escape, which is then group 1. A basic string
// stops at its closing quote, at a line end, or at a `\e` or `\x` escape,
// which is then group 2. Any other escape, `\\` among them, is read as
// one unit, so its second byte never starts an escape.
var tokenPattern = regexp.MustCompile(`#[^\n]*|'''(?s:.*?)(?:'''''|''''|''')|'[^'\n]*'|"""(?:[^\\]|\\[^ex])*?(?:(\\[ex])|"""""|""""|""")|"(?:[^"\\\n]|\\[^ex\n])*(?:(\\[ex])|"?)`)

// Check returns nil, or a *Refusal that names label and one offending
// byte of src (base#1850). The lexical rules come first: the earliest in
// document order of the backslash of a `\e` or `\x` escape in a basic or
// multi-line basic string, or the first byte (LF,
// or the CR of a CRLF) of a line ending outside a string or comment
// whose innermost open `[` / `{` container is an inline table, the comma
// of an inline table's trailing comma, or the first byte of a bare
// token that is a time without seconds, or the first byte of a bare
// value (a value position of the table pass's reading) that is a
// date-bearing value with year 0000, or the sign of a datetime's offset
// whose hour is above 23 or whose minute is above 59; or the first byte
// of a leading byte order mark. The same bytes in a comment, a literal string or a
// multi-line literal are TOML 1.0 and are accepted. Where the structural
// reading (tables) stops, the byte it stopped on is refused with
// ReasonSyntax unless one of those bytes comes at or before it; nothing
// after the stop decides the verdict. Only when neither a lexical rule
// nor a stop refuses does it refuse the first byte of the key or header
// that defines a key path a second time (tables, base#1851), so Check
// may name a later byte than the first offending one: for `a = 1`,
// `a = 2` and `b = "\e"` on three lines it names the escape on line 3,
// not the second `a` (review round 2, base#1851).
func Check(label string, src []byte) error {
	for _, p := range bomPrefixes {
		if bytes.HasPrefix(src, p) {
			return refusal(label, src, 0, ReasonBOM, "leading byte order mark is not TOML 1.0")
		}
	}
	t := newTables(label, src)
	err := t.document()
	var stop *Refusal
	if errors.Is(err, errStop) {
		err = nil
		if !undecodable(src, t.i) {
			// A stop at the end of the document names its last byte, so
			// the position is always a byte of src.
			stop = refusal(label, src, min(t.i, len(src)-1), ReasonSyntax, syntaxText)
		}
	}
	st := scan{bare: t.bare, arrays: t.arrays}
	// A nil *Refusal must come back as a nil error, not a typed nil.
	if r := read(label, src, &st); r != nil && (stop == nil || !before(stop, r)) {
		return r
	}
	if stop != nil {
		return stop
	}
	return err
}

// undecodable reports whether offset i of src is a byte the decoder
// refuses wherever it stands outside a string or comment: a control
// character other than tab, LF or CR, or a byte that starts no valid
// UTF-8 sequence. A stop on such a byte is left to the decoder
// (base#1851).
func undecodable(src []byte, i int) bool {
	if i >= len(src) {
		return false
	}
	if c := src[i]; c == 0x7F || (c < 0x20 && c != '\t' && c != '\n' && c != '\r') {
		return true
	}
	r, n := utf8.DecodeRune(src[i:])
	return r == utf8.RuneError && n == 1
}

// before reports whether a names an earlier byte than b.
func before(a, b *Refusal) bool {
	return a.Line < b.Line || (a.Line == b.Line && a.Col < b.Col)
}

// read walks src as tokens and the bytes between them, keeping st, and
// returns the first refusal Check reports after the byte order mark.
func read(label string, src []byte, st *scan) *Refusal {
	prev := 0
	// Every token is at least one byte, so src holds at most len(src)
	// tokens. An empty match at len(src) with neither escape group set
	// ends the list, so that the bytes after the last token are read too.
	end := len(src)
	tokens := append(tokenPattern.FindAllSubmatchIndex(src, len(src)), []int{end, end, -1, end, -1, end})
	for _, m := range tokens {
		if r := structural(label, src, prev, m[0], st); r != nil {
			return r
		}
		// A string or comment token is not `=` or `[`, so the bare token
		// after it is not read as a value.
		st.last = '"'
		for _, g := range []int{m[2], m[4]} {
			if g != -1 {
				return escapeRefusal(label, src, g)
			}
		}
		prev = lineEndStart(src, m[1])
	}
	return nil
}

// lineEndStart returns end, or end-1 when the last byte of the token that
// ends at end is the CR of a CRLF (a comment or an unclosed basic string
// takes the CR but not the LF), so that structural reads that CR as the
// first byte of the line ending (base#1850). The guard end < len(src)
// skips the empty end-of-list match; every other token is at least one
// byte, so end-1 is a byte of it.
func lineEndStart(src []byte, end int) int {
	if end < len(src) && src[end] == '\n' && src[end-1] == '\r' {
		return end - 1
	}
	return end
}

// scan is the state structural keeps across the gaps between tokens:
// the stack of open containers (`[` an array, `h` a table header's
// bracket, `{` an inline table) and last, the last byte outside a
// string or comment that is not a space, tab or line ending (`"` after
// a string or comment, `v` after a bare token, 0 at the start). bare and
// arrays are the table pass's value positions (tables.bare,
// tables.arrays): a bare token is a value only when it starts at a key of
// bare, and a `[` opens an array only when its offset is in arrays.
type scan struct {
	open   []byte
	last   byte
	bare   map[int]int
	arrays map[int]bool
}

// structural reads src[from:to], bytes outside any token, keeping st,
// and returns the refusal for the first line ending there whose
// innermost open container is `{`, or for the first comma there that
// follows a pair and is followed, after optional spaces or tabs, by the
// `}` that closes an inline table, or for the first bare token there
// that is a time without seconds, or for the first bare value token
// there that is a date-bearing value with year 0000, or for the offset
// sign of the first bare token there whose offset hour is above 23 or
// offset minute is above 59.
func structural(label string, src []byte, from, to int, st *scan) *Refusal {
	for i := from; i < to; i++ {
		switch c := src[i]; c {
		case '[':
			// A `[` that starts a value opens an array; any other opens
			// a table header.
			if st.arrays[i] {
				st.open = append(st.open, '[')
			} else {
				st.open = append(st.open, 'h')
			}
			st.last = c
		case '{':
			st.open = append(st.open, c)
			st.last = c
		case ']', '}':
			// A close with nothing open leaves the stack empty.
			st.open = st.open[:max(len(st.open)-1, 0)]
			st.last = c
		case ' ', '\t':
		case '\n', '\r':
			if n := len(st.open); n > 0 && st.open[n-1] == '{' {
				return newlineRefusal(label, src, i)
			}
		case ',':
			j := i + 1
			for j < len(src) && (src[j] == ' ' || src[j] == '\t') {
				j++
			}
			// A comma right after the `{` or another comma follows no
			// pair, so it is not a trailing comma; the structural reading
			// stops there instead (base#1851).
			trailing := st.last != '{' && st.last != ','
			if n := len(st.open); trailing && n > 0 && st.open[n-1] == '{' && j < len(src) && src[j] == '}' {
				return commaRefusal(label, src, i)
			}
			st.last = c
		default:
			tok := barePattern.Find(src[i:to])
			if tok == nil {
				st.last = c
				continue
			}
			if _, value := st.bare[i]; value && yearZero(tok) {
				return dateRangeRefusal(label, src, i)
			}
			if dateRule(tok) {
				return timeRefusal(label, src, i)
			}
			if at, ok := offsetOutOfRange(tok); ok {
				return offsetRangeRefusal(label, src, i+at)
			}
			st.last = 'v'
			i += len(tok) - 1
		}
	}
	return nil
}

// Normalize returns a copy of src, which Check accepted, in which every
// value-position float literal (a bare value the table pass read, in any
// array or inline-table position) past float64 max is replaced by `inf`,
// `+inf` or `-inf` (its sign kept) padded with spaces to the literal's
// length; tomllib loads such a literal as an infinity, BurntSushi refuses
// it (base#1851). Every other byte keeps its value and offset, so a
// decoder's line and column still index src.
func Normalize(src []byte) []byte {
	out := bytes.Clone(src)
	t := newTables("", src)
	_ = t.document()
	for start, end := range t.bare {
		if !isDecimalFloat(src[start:end]) {
			continue
		}
		tok := strings.ReplaceAll(string(src[start:end]), "_", "")
		if f, err := strconv.ParseFloat(tok, 64); errors.Is(err, strconv.ErrRange) && math.IsInf(f, 0) {
			inf := "inf"
			if tok[0] == '+' || tok[0] == '-' {
				inf = tok[:1] + inf
			}
			// The literal's bytes become spaces, then inf over its start.
			pad := out[start:end]
			for k := range pad {
				pad[k] = ' '
			}
			copy(pad, inf)
		}
	}
	return out
}

// isDecimalFloat reports whether tok, as written, is a TOML 1.0 decimal
// float (base#1851):
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
	start := i
	i = digitRun(tok, i)
	// dec-int is one digit, or a run whose first digit is not 0.
	ok := i > start && (tok[start] != '0' || i == start+1)
	more := false
	if i < len(tok) && tok[i] == '.' {
		j := digitRun(tok, i+1)
		ok = ok && j > i+1
		i, more = j, true
	}
	if i < len(tok) && (tok[i] == 'e' || tok[i] == 'E') {
		i++
		if i < len(tok) && (tok[i] == '+' || tok[i] == '-') {
			i++
		}
		j := digitRun(tok, i)
		ok = ok && j > i
		i, more = j, true
	}
	return ok && more && i == len(tok)
}

// digitRun returns the offset just past the zero-prefixable-int (a digit,
// then digits each optionally after one underscore) that starts at offset
// i of tok, or i itself when no digit is there.
func digitRun(tok []byte, i int) int {
	for ; i < len(tok) && isDigit(tok[i]); i++ {
		// An underscore goes on only with a digit after it.
		if i+2 < len(tok) && tok[i+1] == '_' && isDigit(tok[i+2]) {
			i++
		}
	}
	return i
}

// isDigit reports whether b is an ASCII digit.
func isDigit(b byte) bool { return b >= '0' && b <= '9' }

// escapeRefusal is the refusal for the `\e` or `\x` escape whose
// backslash is at offset off of src.
func escapeRefusal(label string, src []byte, off int) *Refusal {
	return refusal(label, src, off, ReasonEscape, "escape sequence "+string(src[off:off+2])+" is not TOML 1.0")
}

// newlineRefusal is the refusal for the line ending at offset off of src
// inside an inline table.
func newlineRefusal(label string, src []byte, off int) *Refusal {
	return refusal(label, src, off, ReasonInlineNewline, "line ending inside an inline table is not TOML 1.0")
}

// commaRefusal is the refusal for the trailing comma at offset off of
// src inside an inline table.
func commaRefusal(label string, src []byte, off int) *Refusal {
	return refusal(label, src, off, ReasonInlineTrailingComma, "trailing comma in an inline table is not TOML 1.0")
}

// timeRefusal is the refusal for the time without seconds whose bare
// token starts at offset off of src.
func timeRefusal(label string, src []byte, off int) *Refusal {
	return refusal(label, src, off, ReasonTimeNoSeconds, "time without seconds is not TOML 1.0")
}

// dateRangeRefusal is the refusal for the year-0000 date-bearing value
// whose bare token starts at offset off of src.
func dateRangeRefusal(label string, src []byte, off int) *Refusal {
	return refusal(label, src, off, ReasonDateRange, "Invalid date or datetime")
}

// offsetRangeRefusal is the refusal for the offset hour above 23 or the
// offset minute above 59 whose sign is at offset off of src.
func offsetRangeRefusal(label string, src []byte, off int) *Refusal {
	return refusal(label, src, off, ReasonOffsetRange, "offset hour above 23 or minute above 59 is not TOML 1.0")
}

// position returns the 1-based line and byte column of offset off in src.
func position(src []byte, off int) (line, col int) {
	line = len(bytes.Split(src[:off], []byte{'\n'}))
	col = off - bytes.LastIndexByte(src[:off], '\n')
	return line, col
}
