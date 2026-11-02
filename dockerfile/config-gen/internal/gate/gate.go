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

// timeNoSeconds matches a value token whose time part is HH:MM with no
// `:SS` after it: a local time, or a date plus `T`/`t`/space and a time.
var timeNoSeconds = regexp.MustCompile(`^(?:[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt ])?[0-9]{2}:[0-9]{2}(?:[^:0-9]|$)`)

// yearZero matches a value token that starts with a date whose year is
// 0000.
var yearZero = regexp.MustCompile(`^0000-[0-9]{2}-[0-9]{2}`)

// offsetField matches an offset datetime value token; group 1 is the
// offset's sign, group 2 its hour and group 3 its minute.
var offsetField = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt ][0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?([+-])([0-9]{2}):([0-9]{2})$`)

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
	var open []byte // innermost last: '{' inline table, '[' array, 'h' header
	// seen holds the keys assigned in the current table.
	seen := map[string]bool{}
	// table is the current table's dotted path; dotted holds the paths
	// of the tables that dotted keys created.
	table := ""
	dotted := map[string]bool{}
	for i := 0; i < len(src); i++ {
		switch {
		case !inBasic && len(open) == 0 && src[i] == '[' && atLineStart(src, i):
			seen = map[string]bool{}
			if path, ok := headerPath(src, i); ok {
				if dotted[path] {
					line, col := position(src, i)
					return &Refusal{File: label, Line: line, Col: col, Reason: ReasonRedefine,
						Text: fmt.Sprintf("Cannot redefine a table (at line %d, column %d)", line, col)}
				}
				table = path
			}
			open = append(open, 'h')
		case !inBasic && len(open) == 0 && isBareKeyByte(src[i]) && atLineStart(src, i):
			if key, ok := lineKey(src, i); ok {
				if seen[key] {
					line, col := position(src, i)
					return &Refusal{File: label, Line: line, Col: col, Reason: ReasonDuplicate,
						Text: fmt.Sprintf("Cannot overwrite a value (at line %d, column %d)", line, col)}
				}
				seen[key] = true
				if !bytes.ContainsAny([]byte(key), "\"'") {
					parts := splitKey(key)
					for n := 1; n < len(parts); n++ {
						dotted[joinPath(table, parts[:n])] = true
					}
				}
			}
			for i+1 < len(src) && isBareKeyByte(src[i+1]) {
				i++
			}
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
			if yearZero.Match(src[i:end]) && inValue(src, i, open) {
				line, col := position(src, i)
				return &Refusal{File: label, Line: line, Col: col, Reason: ReasonDateRange,
					Text: fmt.Sprintf("Invalid date or datetime (at line %d, column %d)", line, col)}
			}
			if timeNoSeconds.Match(src[i:end]) {
				line, col := position(src, i)
				return &Refusal{File: label, Line: line, Col: col, Reason: ReasonTimeNoSeconds,
					Text: "time without seconds is not TOML 1.0"}
			}
			if m := offsetField.FindSubmatchIndex(src[i:end]); m != nil {
				if string(src[i+m[4]:i+m[5]]) > "23" {
					line, col := position(src, i+m[2])
					return &Refusal{File: label, Line: line, Col: col, Reason: ReasonOffsetRange,
						Text: "offset hour above 23 is not TOML 1.0"}
				}
				if string(src[i+m[6]:i+m[7]]) > "59" {
					line, col := position(src, i+m[2])
					return &Refusal{File: label, Line: line, Col: col, Reason: ReasonOffsetRange,
						Text: "offset minute above 59 is not TOML 1.0"}
				}
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
	t := &tables{src: src, node: map[string]byte{}, explicit: map[string]bool{}}
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

// inValue reports whether offset i of src is in a value position: after
// `=`, or after `[` or `,` inside an array. Bytes inside a header
// (marked 'h' on open) are a key, not a value.
func inValue(src []byte, i int, open []byte) bool {
	j := i - 1
	for j >= 0 && (src[j] == ' ' || src[j] == '\t' || src[j] == '\n' || src[j] == '\r') {
		j--
	}
	if j < 0 || bytes.IndexByte(open, 'h') >= 0 {
		return false
	}
	switch src[j] {
	case '=':
		return true
	case '[', ',':
		return len(open) > 0 && open[len(open)-1] == '['
	}
	return false
}

// atLineStart reports whether only spaces or tabs lie between the start
// of the line and offset i of src.
func atLineStart(src []byte, i int) bool {
	for j := i - 1; j >= 0; j-- {
		switch src[j] {
		case ' ', '\t':
		case '\n':
			return true
		default:
			return false
		}
	}
	return true
}

// lineKey returns the key text from offset i of src up to the `=` on the
// same line, with trailing spaces and tabs removed, and false when the
// line has no `=`.
func lineKey(src []byte, i int) (string, bool) {
	j := i
	for j < len(src) && src[j] != '=' && src[j] != '\n' {
		j++
	}
	if j == len(src) || src[j] != '=' {
		return "", false
	}
	return string(bytes.TrimRight(src[i:j], " \t")), true
}

// headerPath returns the dotted path of the single-bracket table header
// whose `[` is at offset i of src, with spaces around each part removed,
// and false for an array-of-tables header, a quoted part, or no `]` on
// the line.
func headerPath(src []byte, i int) (string, bool) {
	if i+1 < len(src) && src[i+1] == '[' {
		return "", false
	}
	j := i + 1
	for j < len(src) && src[j] != ']' && src[j] != '\n' {
		j++
	}
	if j == len(src) || src[j] != ']' || bytes.ContainsAny(src[i+1:j], "\"'") {
		return "", false
	}
	return joinPath("", splitKey(string(src[i+1:j]))), true
}

// splitKey splits an unquoted dotted key at each `.` and trims spaces
// and tabs from each part.
func splitKey(key string) []string {
	parts := strings.Split(key, ".")
	for n := range parts {
		parts[n] = strings.Trim(parts[n], " \t")
	}
	return parts
}

// joinPath returns the dotted path of parts under the table at path
// base ("" for the root table).
func joinPath(base string, parts []string) string {
	p := strings.Join(parts, ".")
	if base == "" {
		return p
	}
	return base + "." + p
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
