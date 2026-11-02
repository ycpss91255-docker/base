package gate

import (
	"bytes"
	"errors"
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

// node is one key path of the document: its kind, whether tomllib marks
// it EXPLICIT_NEST (a header path, or a dotted-key prefix of a section
// once the next header opens), and its children by decoded key part. A
// path is the chain of parts from the root, so two paths are the same
// exactly when their decoded parts are, whatever bytes a part holds
// (base#1441 review round 1, finding 2).
type node struct {
	kind     byte
	explicit bool
	kids     map[string]*node
}

// newNode returns a node of kind with no children.
func newNode(kind byte) *node { return &node{kind: kind, kids: map[string]*node{}} }

// child returns n's child named part, creating it as an implicit table
// when it does not exist yet.
func (n *node) child(part string) *node {
	c, ok := n.kids[part]
	if !ok {
		c = newNode(nodeTable)
		n.kids[part] = c
	}
	return c
}

// container reports whether a key may be defined below n: n is a table
// or an array of tables, not a scalar, an inline table or an array value.
func (n *node) container() bool { return n.kind == nodeTable || n.kind == nodeAOT }

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
	// root is the document's root table; every path that exists is a
	// node below it.
	root *node
	// pending holds the dotted-key prefixes the current section made;
	// the next header marks them explicit.
	pending []*node
	// scalar, when set, receives the span of each bare value token (a
	// number, boolean or date) the pass reads, trailing blanks excluded.
	scalar func(start, end int)
	// outer is the offset of the first byte of the statement value being
	// read, where a depth refusal points.
	outer int
	// tz holds the offsets (sign, hour, minute) an offset datetime has
	// already used in this document: tomllib builds each through an
	// lru_cache, whose Python frame runs only on the first use.
	tz map[string]bool
}

// tomllib's Python frame depth, as the pinned toml-bridge image calls it
// (base#1441 design-ahead r3 G6): the oracle program's <module> (1), main
// (2), tomllib.loads (3), key_value_rule (4), parse_key_value_pair (5),
// so a statement's value is read in parse_value at frame 6. tomllib
// refuses with a RecursionError once a frame deeper than recursionLimit
// (sys.getrecursionlimit() in the image) would start. Each method below
// that stands for a tomllib function takes that function's frame depth
// and reaches the depth of every function it calls; the frame costs are
// read off CPython 3.13.13 Lib/tomllib/_parser.py and _re.py.
const (
	statementValueFrame = 6
	recursionLimit      = 1000
)

// errStop ends the pass without a verdict: the input is not something
// the pass can follow, so the decoder decides.
var errStop = errors.New("gate: table pass stopped")

// newTables returns a pass over src that starts at its first byte and
// names label in its refusals.
func newTables(label string, src []byte) *tables {
	return &tables{src: src, label: label, root: newNode(nodeTable), tz: map[string]bool{}}
}

// checkTables returns nil or the *Refusal for the first table-rule
// conflict in src.
func checkTables(label string, src []byte) error {
	t := newTables(label, src)
	err := t.document()
	if errors.Is(err, errStop) {
		return nil
	}
	return err
}

func (t *tables) document() error {
	table := t.root // the current table
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
			parts, _, err := t.key()
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
			n, err := t.header(parts, aot, start)
			if err != nil {
				return err
			}
			table = n
		} else {
			parts, _, err := t.key()
			if err != nil {
				return err
			}
			t.skipBlank(false)
			if !t.eat("=") {
				return errStop
			}
			t.skipBlank(false)
			t.outer = t.i
			kind, err := t.value(statementValueFrame)
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

// header applies a [parts] or [[parts]] header that starts at offset at
// and returns the table it opens. A [[parts]] header refuses a path that
// exists as a table or a scalar, and an ancestor that is a scalar; a
// [parts] header refuses a path a header or dotted keys defined, and
// any ancestor that is a value.
func (t *tables) header(parts []string, aot bool, at int) (*node, error) {
	for _, p := range t.pending {
		p.explicit = true
	}
	t.pending = nil
	n := t.root
	for _, p := range parts[:len(parts)-1] {
		n = n.child(p)
		switch {
		case n.kind == nodeScalar:
			return nil, t.refuse(at, ReasonDuplicate)
		case !n.container() && !aot:
			return nil, t.refuse(at, ReasonRedefine)
		}
	}
	last := parts[len(parts)-1]
	c, ok := n.kids[last]
	if aot {
		if ok && c.kind != nodeAOT && c.kind != nodeArray {
			return nil, t.refuse(at, ReasonDuplicate)
		}
		// Each [[parts]] opens a new element: what the last one held is
		// out of scope.
		c = newNode(nodeAOT)
		n.kids[last] = c
	} else {
		switch {
		case ok && (c.explicit || c.kind == nodeInline || c.kind == nodeArray):
			return nil, t.refuse(at, ReasonRedefine)
		case ok && c.kind != nodeTable:
			return nil, t.refuse(at, ReasonDuplicate)
		}
		c = n.child(last)
	}
	c.explicit = true
	return c, nil
}

// assign applies `parts = <kind>` in table.
func (t *tables) assign(table *node, parts []string, kind byte, at int) error {
	n := table
	for _, p := range parts[:len(parts)-1] {
		c, ok := n.kids[p]
		switch {
		case ok && c.explicit:
			return t.refuse(at, ReasonRedefine)
		case ok && !c.container():
			return t.refuse(at, ReasonDuplicate)
		}
		n = n.child(p)
		t.pending = append(t.pending, n)
	}
	last := parts[len(parts)-1]
	if _, ok := n.kids[last]; ok {
		return t.refuse(at, ReasonDuplicate)
	}
	n.kids[last] = newNode(kind)
	return nil
}

// inline reads an inline table whose `{` is at t.i, holding tomllib's
// inline-table rules within it: no key passes through or repeats an
// inline table, array or scalar written earlier in it. f is the frame of
// tomllib's parse_inline_table; its skip_chars, flag and nest calls run
// at f+1, and each pair's parse_key_value_pair at f+1, whose parse_key
// runs at f+2 and whose value is read at f+2.
func (t *tables) inline(f int) error {
	if err := t.reach(f + 1); err != nil {
		return err
	}
	t.i++
	local := newNode(nodeTable) // the paths this inline table defined
	t.skipBlank(false)
	if t.eat("}") {
		return nil
	}
	for {
		t.skipBlank(false)
		start := t.i
		parts, cost, err := t.key()
		if err != nil {
			return err
		}
		if err := t.reach(f + 3 + cost); err != nil {
			return err
		}
		t.skipBlank(false)
		if !t.eat("=") {
			return errStop
		}
		kind, err := t.value(f + 2)
		if err != nil {
			return err
		}
		n := local
		for _, p := range parts[:len(parts)-1] {
			if c, ok := n.kids[p]; ok && c.kind != nodeTable {
				return t.refuse(start, ReasonDuplicate)
			}
			n = n.child(p)
		}
		if _, ok := n.kids[parts[len(parts)-1]]; ok {
			return t.refuse(start, ReasonDuplicate)
		}
		n.kids[parts[len(parts)-1]] = newNode(kind)
		t.skipBlank(false)
		if t.eat("}") {
			return nil
		}
		if !t.eat(",") {
			return errStop
		}
	}
}

// value reads the value at t.i and returns its node kind. f is the frame
// of tomllib's parse_value for it.
func (t *tables) value(f int) (byte, error) {
	if err := t.reach(f); err != nil {
		return 0, err
	}
	t.skipBlank(false)
	if t.i >= len(t.src) {
		return 0, errStop
	}
	switch t.src[t.i] {
	case '{':
		return nodeInline, t.inline(f + 1)
	case '[':
		return nodeArray, t.array(f + 1)
	case '"', '\'':
		_, cost, err := t.str()
		if err != nil {
			return 0, err
		}
		return nodeScalar, t.reach(f + cost)
	}
	start := t.i
	for t.i < len(t.src) && !strings.ContainsRune(",]}#\n\r", rune(t.src[t.i])) {
		t.i++
	}
	if t.i == start {
		return 0, errStop
	}
	end := t.i
	for end > start && (t.src[end-1] == ' ' || t.src[end-1] == '\t') {
		end--
	}
	if at, reason, text, bad := dateRule(t.src[start:end]); bad {
		if reason == ReasonDateRange {
			return 0, oracleRefusal(t.label, t.src, start+at, reason, msgDateRange)
		}
		return 0, refusal(t.label, t.src, start+at, reason, text)
	}
	if t.scalar != nil {
		t.scalar(start, end)
	}
	return nodeScalar, t.reach(f + t.scalarCost(t.src[start:end]))
}

// array reads an array whose `[` is at t.i. f is the frame of tomllib's
// parse_array: its skip_comments_and_array_ws runs at f+1 and calls
// skip_chars and skip_comment at f+2, and skip_comment calls skip_until
// at f+3 when a comment is there; each element is read at f+1.
func (t *tables) array(f int) error {
	if err := t.reach(f + 2); err != nil {
		return err
	}
	t.i++
	for {
		if err := t.arrayBlank(f); err != nil {
			return err
		}
		if t.eat("]") {
			return nil
		}
		if _, err := t.value(f + 1); err != nil {
			return err
		}
		if err := t.arrayBlank(f); err != nil {
			return err
		}
		if t.eat("]") {
			return nil
		}
		if !t.eat(",") {
			return errStop
		}
	}
}

// arrayBlank skips an array's whitespace, line endings and comments for
// the parse_array at frame f.
func (t *tables) arrayBlank(f int) error {
	if t.skipBlank(true) {
		return t.reach(f + 3)
	}
	return nil
}

// scalarCost returns how many frames below parse_value tomllib goes for
// the bare value token tok: none for true, false, inf and nan (the
// default parse_float is the C float); one for a number (match_to_number)
// or a date or time (match_to_datetime, match_to_localtime); two for an
// offset datetime whose offset this document has not used yet, whose
// match_to_datetime calls the lru_cache'd cached_tz.
func (t *tables) scalarCost(tok []byte) int {
	switch strings.TrimLeft(string(tok), "+-") {
	case "true", "false", "inf", "nan":
		return 0
	}
	if len(tok) >= 25 && digits(tok[:4]) && tok[4] == '-' && tok[len(tok)-3] == ':' {
		if sign := len(tok) - 6; tok[sign] == '+' || tok[sign] == '-' {
			if off := string(tok[sign:]); !t.tz[off] {
				t.tz[off] = true
				return 2
			}
		}
	}
	return 1
}

// reach refuses with ReasonDepth when frame f is deeper than tomllib's
// recursion limit.
func (t *tables) reach(f int) error {
	if f > recursionLimit {
		return refusal(t.label, t.src, t.outer, ReasonDepth, depthText)
	}
	return nil
}

// key reads a dotted key at t.i and returns its parts and how many
// frames below tomllib's parse_key_part its deepest part goes: one for a
// bare part (skip_chars), the str cost for a quoted one.
func (t *tables) key() ([]string, int, error) {
	var parts []string
	cost := 0
	for {
		t.skipBlank(false)
		if t.i >= len(t.src) {
			return nil, 0, errStop
		}
		switch c := t.src[t.i]; {
		case c == '"' || c == '\'':
			s, n, err := t.str()
			if err != nil {
				return nil, 0, err
			}
			parts = append(parts, s)
			cost = max(cost, n)
		case isBareKeyByte(c):
			start := t.i
			for t.i < len(t.src) && isBareKeyByte(t.src[t.i]) {
				t.i++
			}
			parts = append(parts, string(t.src[start:t.i]))
			cost = max(cost, 1)
		default:
			return nil, 0, errStop
		}
		t.skipBlank(false)
		if !t.eat(".") {
			return parts, cost, nil
		}
	}
}

// isBareKeyByte reports whether b may appear in a bare key.
func isBareKeyByte(b byte) bool {
	return isDigit(b) || b == '-' || b == '_' || (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z')
}

// str reads the string at t.i (basic, literal, or either multi-line
// form) and returns its text, a basic string's escapes decoded, and how
// many frames below its caller (parse_value or parse_key_part) tomllib
// goes for it. A literal string is parse_literal_str or
// parse_multiline_str, then skip_until: 2. A basic string is
// parse_one_line_basic_str or parse_multiline_str, then parse_basic_str:
// 2. An escape adds parse_basic_str_escape (3 one-line, 4 multi-line
// through parse_basic_str_escape_multiline); a multi-line whitespace
// escape adds its skip_chars (5); a \u or \U escape adds parse_hex_char
// and is_unicode_scalar_value (5 one-line, 6 multi-line).
func (t *tables) str() (string, int, error) {
	q := t.src[t.i]
	delim := []byte{q}
	if triple := []byte{q, q, q}; bytes.HasPrefix(t.src[t.i:], triple) {
		delim = triple
	}
	ml := 0
	if len(delim) == 3 {
		ml = 1
	}
	cost := 2
	t.i += len(delim)
	start := t.i
	for t.i < len(t.src) {
		if q == '"' && t.src[t.i] == '\\' {
			esc := 3
			if t.i+1 < len(t.src) {
				switch c := t.src[t.i+1]; {
				case c == 'u' || c == 'U':
					esc = 5
				case ml == 1 && (c == ' ' || c == '\t' || c == '\n' || c == '\r'):
					esc = 4
				}
			}
			cost = max(cost, esc+ml)
			t.i += 2
			continue
		}
		if bytes.HasPrefix(t.src[t.i:], delim) {
			stop := closeQuotes(t.src, t.i, q, len(delim))
			end := stop - len(delim)
			t.i = stop
			raw := string(t.src[start:end])
			if q == '"' && len(delim) == 1 {
				if s, err := strconv.Unquote(`"` + raw + `"`); err == nil {
					return s, cost, nil
				}
			}
			return raw, cost, nil
		}
		t.i++
	}
	return "", 0, errStop
}

// skipBlank skips spaces, tabs and comments, and line endings too when
// lines is set, and reports whether it skipped a comment.
func (t *tables) skipBlank(lines bool) (comment bool) {
	for t.i < len(t.src) {
		switch c := t.src[t.i]; {
		case c == ' ' || c == '\t':
			t.i++
		case lines && (c == '\n' || c == '\r'):
			t.i++
		case c == '#':
			comment = true
			for t.i < len(t.src) && t.src[t.i] != '\n' {
				t.i++
			}
		default:
			return comment
		}
	}
	return comment
}

// eat consumes s at t.i and reports whether it was there.
func (t *tables) eat(s string) bool {
	if bytes.HasPrefix(t.src[t.i:], []byte(s)) {
		t.i += len(s)
		return true
	}
	return false
}

// refuse returns the *Refusal for reason, a member of the duplicate
// class, at offset at; every member speaks the one overwrite text.
func (t *tables) refuse(at int, reason Reason) error {
	return oracleRefusal(t.label, t.src, at, reason, msgOverwrite)
}
