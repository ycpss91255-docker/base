// Package diag encodes the NUL-framed diagnostics config-gen writes to
// stderr (ADR-00000039 §3, base#1469).
package diag

// Frame is one diagnostic: its severity, event id, the file label, line,
// column, key and message. Every field is carried byte for byte.
type Frame struct {
	Sev   string
	Event string
	File  string
	Line  string
	Col   string
	Key   string
	Text  string
}

// Encode returns f as eight NUL-terminated fields: the tag `D`, then Sev,
// Event, File, Line, Col, Key and Text, none escaped or quoted.
func Encode(f Frame) []byte {
	var out []byte
	for _, field := range []string{"D", f.Sev, f.Event, f.File, f.Line, f.Col, f.Key, f.Text} {
		out = append(out, field...)
		out = append(out, 0)
	}
	return out
}
