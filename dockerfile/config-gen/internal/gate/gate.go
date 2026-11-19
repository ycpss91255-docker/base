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

// ReasonEscape is a `\e` or `\x` escape in a basic string (TOML 1.1
// only).
const ReasonEscape Reason = 1

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

// Check returns nil, or a *Refusal that names label and the offending
// byte of src (base#1850): the backslash of the first `\e` or `\x`
// escape in a basic or multi-line basic string. The same bytes in a
// comment, a literal string or a multi-line literal are TOML 1.0 and are
// accepted.
func Check(label string, src []byte) error {
	// Every token is at least one byte, so src holds at most len(src).
	for _, m := range tokenPattern.FindAllSubmatchIndex(src, len(src)) {
		for _, g := range []int{m[2], m[4]} {
			if g != -1 {
				return escapeRefusal(label, src, g)
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

// position returns the 1-based line and byte column of offset off in src.
func position(src []byte, off int) (line, col int) {
	line = len(bytes.Split(src[:off], []byte{'\n'}))
	col = off - bytes.LastIndexByte(src[:off], '\n')
	return line, col
}
