// Package gate refuses the TOML forms that BurntSushi accepts but the
// TOML 1.0 oracle (tomllib) refuses, so that gate plus BurntSushi gives
// the oracle's verdict (base#1850).
package gate

import (
	"bytes"
	"fmt"
)

// Reason names why Check refused its input.
type Reason int

// ReasonEscape is a `\e` escape in a basic string (TOML 1.1 only).
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

// Check returns nil, or a *Refusal that names label and the offending
// byte of src (base#1850): the backslash of the first `\e` escape.
func Check(label string, src []byte) error {
	before, _, found := bytes.Cut(src, []byte(`\e`))
	if !found {
		return nil
	}
	return refusal(label, src, len(before), ReasonEscape, `escape sequence \e is not TOML 1.0`)
}

// position returns the 1-based line and byte column of offset off in src.
func position(src []byte, off int) (line, col int) {
	line = len(bytes.Split(src[:off], []byte{'\n'}))
	col = off - bytes.LastIndexByte(src[:off], '\n')
	return line, col
}
