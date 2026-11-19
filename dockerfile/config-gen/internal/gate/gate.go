// Package gate refuses six TOML 1.1-only forms that BurntSushi v1.6.0
// accepts and the TOML 1.0 oracle (tomllib) refuses (base#1850): a `\e`
// escape, a `\x` escape, a line ending inside an inline table, a trailing
// comma in an inline table, a time without seconds, and a leading byte
// order mark. It also refuses a date-bearing value with year 0000, which
// BurntSushi v1.6.0 accepts and tomllib refuses (base#1851).
package gate

import (
	"bytes"
	"fmt"
	"regexp"
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
)

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

// Check returns nil, or a *Refusal that names label and the first
// offending byte of src (base#1850): the backslash of a `\e` or `\x`
// escape in a basic or multi-line basic string, or the first byte (LF,
// or the CR of a CRLF) of a line ending outside a string or comment
// whose innermost open `[` / `{` container is an inline table, the comma
// of an inline table's trailing comma, or the first byte of a bare
// token that is a time without seconds, or the first byte of a bare
// token after `=` or an array's opening `[` that is a date-bearing value
// with year 0000; or the first byte of a leading byte order mark. The same bytes in a comment, a literal string or a
// multi-line literal are TOML 1.0 and are accepted.
func Check(label string, src []byte) error {
	for _, p := range bomPrefixes {
		if bytes.HasPrefix(src, p) {
			return refusal(label, src, 0, ReasonBOM, "leading byte order mark is not TOML 1.0")
		}
	}
	var st scan
	prev := 0
	// Every token is at least one byte, so src holds at most len(src)
	// tokens. An empty match at len(src) with neither escape group set
	// ends the list, so that the bytes after the last token are read too.
	end := len(src)
	tokens := append(tokenPattern.FindAllSubmatchIndex(src, len(src)), []int{end, end, -1, end, -1, end})
	for _, m := range tokens {
		if r := structural(label, src, prev, m[0], &st); r != nil {
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
// a string or comment, `v` after a bare token, 0 at the start).
type scan struct {
	open []byte
	last byte
}

// valueNext reports whether the next bare token is a value: it follows
// `=`, or it follows the `[` that opens an array.
func (st *scan) valueNext() bool {
	switch st.last {
	case '=':
		return true
	case '[':
		return bytes.HasSuffix(st.open, []byte("["))
	}
	return false
}

// structural reads src[from:to], bytes outside any token, keeping st,
// and returns the refusal for the first line ending there whose
// innermost open container is `{`, or for the first comma there
// followed, after optional spaces or tabs, by the `}` that closes an
// inline table, or for the first bare token there that is a time
// without seconds, or for the first bare value token there that is a
// date-bearing value with year 0000.
func structural(label string, src []byte, from, to int, st *scan) *Refusal {
	for i := from; i < to; i++ {
		switch c := src[i]; c {
		case '[':
			// A `[` that starts a value opens an array; any other opens
			// a table header.
			if st.valueNext() {
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
			if n := len(st.open); n > 0 && st.open[n-1] == '{' && j < len(src) && src[j] == '}' {
				return commaRefusal(label, src, i)
			}
			st.last = c
		default:
			tok := barePattern.Find(src[i:to])
			if tok == nil {
				st.last = c
				continue
			}
			if st.valueNext() && yearZero(tok) {
				return dateRangeRefusal(label, src, i)
			}
			if dateRule(tok) {
				return timeRefusal(label, src, i)
			}
			st.last = 'v'
			i += len(tok) - 1
		}
	}
	return nil
}

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

// position returns the 1-based line and byte column of offset off in src.
func position(src []byte, off int) (line, col int) {
	line = len(bytes.Split(src[:off], []byte{'\n'}))
	col = off - bytes.LastIndexByte(src[:off], '\n')
	return line, col
}
