package gate

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// Node kinds the table pass records for each key path.
const (
	nodeTable  = 't' // a table: a header, a header's parent, a dotted-key prefix
	nodeAOT    = 'a' // an array of tables ([[x]])
	nodeScalar = 'v' // a string, number, boolean or date value
	nodeInline = 'i' // an inline table value, immutable once written
	nodeArray  = 'l' // an array value, immutable once written
)

// sep joins the parts of a key path; no TOML key holds a NUL byte
// unescaped, so a quoted key holding a dot cannot alias a dotted one.
const sep = "\x00"

// tables is the second pass of Check: it follows tomllib's table rules
// (base#1441), which BurntSushi does not hold to. A dotted key may not
// pass through a table a header defined, or a dotted-key table an
// earlier section made; nothing may extend an inline table or an array
// value; a key may not name a path that already exists. Input it cannot
// follow is left to the decoder.
type tables struct {
	src   []byte
	label string
	i     int
	// node holds every absolute path that exists and its kind.
	node map[string]byte
	// explicit holds the paths tomllib marks EXPLICIT_NEST: header paths,
	// and the dotted-key prefixes of a section once the next header opens.
	explicit map[string]bool
	pending  []string
}

// errStop ends the pass without a verdict: the input is not something
// the pass can follow, so the decoder decides.
var errStop = errors.New("gate: table pass stopped")

// checkTables returns nil or the *Refusal for the first table-rule
// conflict in src.
func checkTables(label string, src []byte) error {
	t := &tables{src: src, label: label, node: map[string]byte{}, explicit: map[string]bool{}}
	err := t.document()
	if errors.Is(err, errStop) {
		return nil
	}
	return err
}

func (t *tables) document() error {
	var table []string // the current table's path; nil is the root table
	for {
		t.skipBlank(true)
		if t.i >= len(t.src) {
			return nil
		}
		start := t.i
		if t.src[t.i] == '[' {
			aot := t.i+1 < len(t.src) && t.src[t.i+1] == '['
			if aot {
				t.i += 2
			} else {
				t.i++
			}
			parts, err := t.key()
			if err != nil {
				return err
			}
			if aot {
				if !t.eat("]]") {
					return errStop
				}
			} else if !t.eat("]") {
				return errStop
			}
			path := strings.Join(parts, sep)
			if err := t.header(path, aot, start); err != nil {
				return err
			}
			table = parts
		} else {
			parts, err := t.key()
			if err != nil {
				return err
			}
			t.skipBlank(false)
			if !t.eat("=") {
				return errStop
			}
			kind, err := t.value()
			if err != nil {
				return err
			}
			if err := t.assign(table, parts, kind, start); err != nil {
				return err
			}
		}
		t.skipBlank(false)
		if t.i < len(t.src) && t.src[t.i] != '\n' && t.src[t.i] != '\r' {
			return errStop
		}
	}
}

// header applies a [path] or [[path]] header that starts at offset at.
func (t *tables) header(path string, aot bool, at int) error {
	for _, p := range t.pending {
		t.explicit[p] = true
	}
	t.pending = nil
	parts := strings.Split(path, sep)
	for n := 1; n < len(parts); n++ {
		if k := t.node[strings.Join(parts[:n], sep)]; k == nodeScalar {
			return t.refuse(at, ReasonDuplicate)
		}
	}
	if aot {
		if k, ok := t.node[path]; ok && k != nodeAOT && k != nodeArray {
			return t.refuse(at, ReasonDuplicate)
		}
		for p := range t.node {
			if strings.HasPrefix(p, path+sep) {
				delete(t.node, p)
			}
		}
		for p := range t.explicit {
			if strings.HasPrefix(p, path+sep) {
				delete(t.explicit, p)
			}
		}
		t.node[path] = nodeAOT
	} else {
		if t.explicit[path] || t.frozen(parts) {
			return t.refuse(at, ReasonRedefine)
		}
		if k, ok := t.node[path]; ok && k != nodeTable {
			return t.refuse(at, ReasonDuplicate)
		}
		t.node[path] = nodeTable
	}
	t.explicit[path] = true
	t.makeParents(parts)
	return nil
}

// assign applies `parts = <kind>` in the table whose path is base.
func (t *tables) assign(base, parts []string, kind byte, at int) error {
	abs := append(append([]string{}, base...), parts...)
	for n := len(base) + 1; n < len(abs); n++ {
		cont := strings.Join(abs[:n], sep)
		if t.explicit[cont] {
			return t.refuse(at, ReasonRedefine)
		}
		t.pending = append(t.pending, cont)
	}
	if t.frozen(abs[:len(abs)-1]) {
		return t.refuse(at, ReasonDuplicate)
	}
	for n := 1; n < len(abs); n++ {
		if k := t.node[strings.Join(abs[:n], sep)]; k == nodeScalar {
			return t.refuse(at, ReasonDuplicate)
		}
	}
	path := strings.Join(abs, sep)
	if _, ok := t.node[path]; ok {
		return t.refuse(at, ReasonDuplicate)
	}
	t.makeParents(abs)
	t.node[path] = kind
	return nil
}

// frozen reports whether parts or one of its ancestors is an inline
// table or an array value.
func (t *tables) frozen(parts []string) bool {
	for n := 1; n <= len(parts); n++ {
		if k := t.node[strings.Join(parts[:n], sep)]; k == nodeInline || k == nodeArray {
			return true
		}
	}
	return false
}

// makeParents records every proper prefix of parts that does not exist
// yet as a table.
func (t *tables) makeParents(parts []string) {
	for n := 1; n < len(parts); n++ {
		p := strings.Join(parts[:n], sep)
		if _, ok := t.node[p]; !ok {
			t.node[p] = nodeTable
		}
	}
}

// inline reads an inline table whose `{` is at t.i, holding tomllib's
// inline-table rules within it: no key passes through or repeats an
// inline table, array or scalar written earlier in it.
func (t *tables) inline() error {
	t.i++
	local := map[string]byte{}
	t.skipBlank(false)
	if t.eat("}") {
		return nil
	}
	for {
		t.skipBlank(false)
		start := t.i
		parts, err := t.key()
		if err != nil {
			return err
		}
		t.skipBlank(false)
		if !t.eat("=") {
			return errStop
		}
		kind, err := t.value()
		if err != nil {
			return err
		}
		for n := 1; n < len(parts); n++ {
			p := strings.Join(parts[:n], sep)
			if k, ok := local[p]; ok && k != nodeTable {
				return t.refuse(start, ReasonDuplicate)
			}
		}
		path := strings.Join(parts, sep)
		if _, ok := local[path]; ok {
			return t.refuse(start, ReasonDuplicate)
		}
		for n := 1; n < len(parts); n++ {
			p := strings.Join(parts[:n], sep)
			if _, ok := local[p]; !ok {
				local[p] = nodeTable
			}
		}
		local[path] = kind
		t.skipBlank(false)
		if t.eat("}") {
			return nil
		}
		if !t.eat(",") {
			return errStop
		}
	}
}

// value reads the value at t.i and returns its node kind.
func (t *tables) value() (byte, error) {
	t.skipBlank(false)
	if t.i >= len(t.src) {
		return 0, errStop
	}
	switch t.src[t.i] {
	case '{':
		return nodeInline, t.inline()
	case '[':
		t.i++
		for {
			t.skipBlank(true)
			if t.eat("]") {
				return nodeArray, nil
			}
			if _, err := t.value(); err != nil {
				return 0, err
			}
			t.skipBlank(true)
			if t.eat("]") {
				return nodeArray, nil
			}
			if !t.eat(",") {
				return 0, errStop
			}
		}
	case '"', '\'':
		_, err := t.str()
		return nodeScalar, err
	}
	start := t.i
	for t.i < len(t.src) && !strings.ContainsRune(",]}#\n\r", rune(t.src[t.i])) {
		t.i++
	}
	if t.i == start {
		return 0, errStop
	}
	return nodeScalar, nil
}

// key reads a dotted key at t.i and returns its parts.
func (t *tables) key() ([]string, error) {
	var parts []string
	for {
		t.skipBlank(false)
		if t.i >= len(t.src) {
			return nil, errStop
		}
		switch c := t.src[t.i]; {
		case c == '"' || c == '\'':
			s, err := t.str()
			if err != nil {
				return nil, err
			}
			parts = append(parts, s)
		case isBareKeyByte(c):
			start := t.i
			for t.i < len(t.src) && isBareKeyByte(t.src[t.i]) {
				t.i++
			}
			parts = append(parts, string(t.src[start:t.i]))
		default:
			return nil, errStop
		}
		t.skipBlank(false)
		if !t.eat(".") {
			return parts, nil
		}
	}
}

// str reads the string at t.i (basic, literal, or either multi-line
// form) and returns its text; a basic string's escapes are decoded.
func (t *tables) str() (string, error) {
	q := t.src[t.i]
	delim := string(q)
	if strings.HasPrefix(string(t.src[t.i:min(t.i+3, len(t.src))]), strings.Repeat(delim, 3)) {
		delim = strings.Repeat(delim, 3)
	}
	t.i += len(delim)
	start := t.i
	for t.i < len(t.src) {
		if q == '"' && t.src[t.i] == '\\' {
			t.i += 2
			continue
		}
		if strings.HasPrefix(string(t.src[t.i:min(t.i+len(delim), len(t.src))]), delim) {
			end := t.i
			t.i += len(delim)
			// A multi-line string may end in one or two quotes of its own.
			for n := 0; len(delim) == 3 && n < 2 && t.i < len(t.src) && t.src[t.i] == q; n++ {
				t.i++
				end++
			}
			raw := string(t.src[start:end])
			if q == '"' && len(delim) == 1 {
				if s, err := strconv.Unquote(`"` + raw + `"`); err == nil {
					return s, nil
				}
			}
			return raw, nil
		}
		t.i++
	}
	return "", errStop
}

// skipBlank skips spaces, tabs and comments, and line endings too when
// lines is set.
func (t *tables) skipBlank(lines bool) {
	for t.i < len(t.src) {
		switch c := t.src[t.i]; {
		case c == ' ' || c == '\t':
			t.i++
		case lines && (c == '\n' || c == '\r'):
			t.i++
		case c == '#':
			for t.i < len(t.src) && t.src[t.i] != '\n' {
				t.i++
			}
		default:
			return
		}
	}
}

// eat consumes s at t.i and reports whether it was there.
func (t *tables) eat(s string) bool {
	if strings.HasPrefix(string(t.src[t.i:]), s) {
		t.i += len(s)
		return true
	}
	return false
}

// refuse returns the *Refusal for reason at offset at.
func (t *tables) refuse(at int, reason Reason) error {
	line, col := position(t.src, at)
	text := fmt.Sprintf("Cannot overwrite a value (at line %d, column %d)", line, col)
	if reason == ReasonRedefine {
		text = fmt.Sprintf("Cannot redefine a table (at line %d, column %d)", line, col)
	}
	return &Refusal{File: t.label, Line: line, Col: col, Reason: reason, Text: text}
}
