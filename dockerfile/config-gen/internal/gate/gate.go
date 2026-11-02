// Package gate refuses the TOML forms that BurntSushi accepts but the
// TOML 1.0 oracle (tomllib) refuses, so that gate plus BurntSushi gives
// the oracle's verdict (base#1441).
package gate

import (
	"bytes"
	"fmt"
)

// Reason names why Check refused its input.
type Reason int

const (
	// ReasonEscape is a `\e` escape in a basic string (TOML 1.1 only).
	ReasonEscape Reason = iota + 1
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
	inBasic := false
	for i := 0; i < len(src); i++ {
		switch {
		case src[i] == '"':
			inBasic = !inBasic
		case inBasic && src[i] == '\\' && i+1 < len(src) && src[i+1] == 'e':
			line, col := position(src, i)
			return &Refusal{File: label, Line: line, Col: col, Reason: ReasonEscape,
				Text: `escape sequence \e is not TOML 1.0`}
		}
	}
	return nil
}

// position returns the 1-based line and byte column of offset off in src.
func position(src []byte, off int) (line, col int) {
	line = 1 + bytes.Count(src[:off], []byte{'\n'})
	col = off - bytes.LastIndexByte(src[:off], '\n')
	return line, col
}
