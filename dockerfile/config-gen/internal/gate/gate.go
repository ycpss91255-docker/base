// Package gate refuses the TOML forms that BurntSushi accepts but the
// TOML 1.0 oracle (tomllib) refuses, so that gate plus BurntSushi gives
// the oracle's verdict (base#1441).
package gate

import (
	"bytes"
	"fmt"
	"regexp"
)

// timeNoSeconds matches a value token whose time part is HH:MM with no
// `:SS` after it: a local time, or a date plus `T`/`t`/space and a time.
var timeNoSeconds = regexp.MustCompile(`^(?:[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt ])?[0-9]{2}:[0-9]{2}(?:[^:0-9]|$)`)

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

// Check returns nil, or a *Refusal that names label and the offending
// byte of src.
func Check(label string, src []byte) error {
	if bytes.HasPrefix(src, []byte("\xEF\xBB\xBF")) {
		return &Refusal{File: label, Line: 1, Col: 1, Reason: ReasonBOM,
			Text: "leading byte order mark is not TOML 1.0"}
	}
	inBasic := false
	var open []byte // innermost last: '{' inline table, '[' array or header
	for i := 0; i < len(src); i++ {
		switch {
		case !inBasic && src[i] == '#':
			for i < len(src) && !lineEnd(src, i) {
				i++
			}
			i-- // the loop step lands on the line ending
		case !inBasic && src[i] == '\'':
			i = skipLiteral(src, i)
		case !inBasic && (src[i] == '{' || src[i] == '['):
			open = append(open, src[i])
		case !inBasic && (src[i] == '}' || src[i] == ']') && len(open) > 0:
			open = open[:len(open)-1]
		case !inBasic && lineEnd(src, i) && len(open) > 0 && open[len(open)-1] == '{':
			line, col := position(src, i)
			return &Refusal{File: label, Line: line, Col: col, Reason: ReasonInlineNewline,
				Text: "line ending inside an inline table is not TOML 1.0"}
		case !inBasic && src[i] == ',' && len(open) > 0 && open[len(open)-1] == '{':
			j := i + 1
			for j < len(src) && (src[j] == ' ' || src[j] == '\t') {
				j++
			}
			if j < len(src) && src[j] == '}' {
				line, col := position(src, i)
				return &Refusal{File: label, Line: line, Col: col, Reason: ReasonInlineTrailingComma,
					Text: "trailing comma in an inline table is not TOML 1.0"}
			}
		case !inBasic && isDigit(src[i]) && (i == 0 || !isBareKeyByte(src[i-1])):
			end := valueTokenEnd(src, i)
			if timeNoSeconds.Match(src[i:end]) {
				line, col := position(src, i)
				return &Refusal{File: label, Line: line, Col: col, Reason: ReasonTimeNoSeconds,
					Text: "time without seconds is not TOML 1.0"}
			}
			i = end - 1
		case src[i] == '"':
			inBasic = !inBasic
		case inBasic && src[i] == '\\' && i+1 < len(src):
			if src[i+1] == 'e' || src[i+1] == 'x' {
				line, col := position(src, i)
				return &Refusal{File: label, Line: line, Col: col, Reason: ReasonEscape,
					Text: `escape sequence \` + string(src[i+1]) + ` is not TOML 1.0`}
			}
			i++
		}
	}
	return nil
}

// isDigit reports whether b is an ASCII digit.
func isDigit(b byte) bool { return b >= '0' && b <= '9' }

// isBareKeyByte reports whether b may appear in a bare key, so a digit
// after it continues that key rather than starting a value.
func isBareKeyByte(b byte) bool {
	return isDigit(b) || b == '-' || b == '_' || (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z')
}

// valueTokenEnd returns the offset just past the value token that starts
// with a digit at offset i of src. A date followed by one space and a
// digit continues as a datetime with a space delimiter.
func valueTokenEnd(src []byte, i int) int {
	j := i
	for j < len(src) && (isBareKeyByte(src[j]) || src[j] == ':' || src[j] == '.' || src[j] == '+') {
		j++
	}
	if j-i == 10 && src[i+4] == '-' && j+1 < len(src) && src[j] == ' ' && isDigit(src[j+1]) {
		return valueTokenEnd(src, j+1)
	}
	return j
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
	return i + len(delim) + end + len(delim) - 1
}

// position returns the 1-based line and byte column of offset off in src.
func position(src []byte, off int) (line, col int) {
	line = 1 + bytes.Count(src[:off], []byte{'\n'})
	col = off - bytes.LastIndexByte(src[:off], '\n')
	return line, col
}
