// Package gate refuses the TOML forms that BurntSushi accepts but the
// TOML 1.0 oracle (tomllib) refuses, so that gate plus BurntSushi gives
// the oracle's verdict (base#1850).
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
)

// bomPrefixes is the whole list of leading byte order marks the decoder
// strips before it lexes (BurntSushi v1.6.0 parse.go:47-51), each of
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
// before it. A multi-line
// basic string may hold lone quotes and line ends and stops at its first
// `"""` (plus up to two quotes of content before it) or at a `\e` or
// `\x` escape, which is then group 1. A basic string stops at its
// closing quote, at a line end, or at a `\e` or `\x` escape, which is
// then group 2. Any other escape, `\\` among them, is read as one unit,
// so its second byte never starts an escape.
var tokenPattern = regexp.MustCompile(`#[^\n]*|'''(?s:.*?)(?:'''''|''''|''')|'[^'\n]*'|"""(?:[^\\]|\\[^ex])*?(?:(\\[ex])|"""""|""""|""")|"(?:[^"\\\n]|\\[^ex\n])*(?:(\\[ex])|"?)`)

// Check returns nil, or a *Refusal that names label and the first
// offending byte of src (base#1850): the backslash of a `\e` or `\x`
// escape in a basic or multi-line basic string, or the first byte (LF,
// or the CR of a CRLF) of a line ending outside a string or comment
// whose innermost open `[` / `{` container is an inline table, the comma
// of an inline table's trailing comma, or the first byte of a bare
// token that is a time without seconds; or the first byte of a leading
// byte order mark. The same
// bytes in a comment, a literal string or a multi-line literal are TOML
// 1.0 and are accepted.
func Check(label string, src []byte) error {
	for _, p := range bomPrefixes {
		if bytes.HasPrefix(src, p) {
			return refusal(label, src, 0, ReasonBOM, "leading byte order mark is not TOML 1.0")
		}
	}
	var open []byte
	prev := 0
	// Every token is at least one byte, so src holds at most len(src).
	// An empty match at len(src) with neither escape group set ends the
	// list, so that the bytes after the last token are read too.
	end := len(src)
	tokens := append(tokenPattern.FindAllSubmatchIndex(src, len(src)), []int{end, end, -1, end, -1, end})
	for _, m := range tokens {
		if r := structural(label, src, prev, m[0], &open); r != nil {
			return r
		}
		for _, g := range []int{m[2], m[4]} {
			if g != -1 {
				return escapeRefusal(label, src, g)
			}
		}
		prev = m[1]
	}
	return nil
}

// structural reads src[from:to], bytes outside any token, keeping the
// stack of open `[` and `{` containers, and returns the refusal for the
// first line ending there whose innermost open container is `{`, or for
// the first comma there followed, after optional spaces or tabs, by the
// `}` that closes an inline table, or for the first bare token there
// that is a time without seconds.
func structural(label string, src []byte, from, to int, open *[]byte) *Refusal {
	for i := from; i < to; i++ {
		switch c := src[i]; c {
		case '[', '{':
			*open = append(*open, c)
		case ']', '}':
			// A close with nothing open leaves the stack empty.
			*open = (*open)[:max(len(*open)-1, 0)]
		case '\n', '\r':
			if n := len(*open); n > 0 && (*open)[n-1] == '{' {
				return newlineRefusal(label, src, i)
			}
		case ',':
			j := i + 1
			for j < len(src) && (src[j] == ' ' || src[j] == '\t') {
				j++
			}
			if n := len(*open); n > 0 && (*open)[n-1] == '{' && j < len(src) && src[j] == '}' {
				return commaRefusal(label, src, i)
			}
		default:
			if tok := barePattern.Find(src[i:to]); tok != nil {
				if dateRule(tok) {
					return timeRefusal(label, src, i)
				}
				i += len(tok) - 1
			}
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

// position returns the 1-based line and byte column of offset off in src.
func position(src []byte, off int) (line, col int) {
	line = len(bytes.Split(src[:off], []byte{'\n'}))
	col = off - bytes.LastIndexByte(src[:off], '\n')
	return line, col
}
