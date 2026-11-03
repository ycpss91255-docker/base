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
// (base#1441).
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

// tables reads one document in document order and holds tomllib's table
// rules (base#1441). A dotted key may not pass through a table a header
// defined, or a dotted-key table an earlier section made; nothing may
// extend an inline table or an array value; a key may not name a path
// that already exists. A break of one of these rules is refused at its
// byte. Where the TOML 1.0 grammar allows nothing at the byte it reads,
// it stops there with errStop at that byte.
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

// errStop ends the pass at t.i, a byte where the TOML 1.0 grammar allows
// nothing; Check refuses that byte with ReasonSyntax.
var errStop = errors.New("gate: table pass stopped")

// newTables returns a pass over src that starts at its first byte and
// names label in its refusals.
func newTables(label string, src []byte) *tables {
	return &tables{src: src, label: label, root: newNode(nodeTable), tz: map[string]bool{}}
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
			closing := "]"
			aot := t.eat("[[")
			if aot {
				closing = "]]"
			} else {
				t.i++ // the `[` checked above
			}
			t.closeSection()
			n := t.root
			err := t.key(func(part string, _ int, dotted bool) (err error) {
				if dotted {
					n, err = t.headerStep(n, part, aot, start)
				} else {
					n, err = t.headerLeaf(n, part, aot, start)
				}
				return err
			})
			if err != nil {
				return err
			}
			if !t.eat(closing) {
				return errStop
			}
			table = n
		} else {
			n := table
			err := t.key(func(part string, _ int, dotted bool) (err error) {
				if dotted {
					n, err = t.assignStep(n, part, start)
				} else {
					n, err = t.define(n, part, start)
				}
				return err
			})
			if err != nil {
				return err
			}
			t.skipBlank(false)
			if !t.eat("=") {
				return errStop
			}
			t.skipBlank(false)
			t.outer = t.i
			if n.kind, err = t.value(statementValueFrame); err != nil {
				return err
			}
		}
		t.skipBlank(false)
		if t.i < len(t.src) && t.src[t.i] != '\n' && t.src[t.i] != '\r' {
			return errStop
		}
	}
}

// closeSection ends the current section at a header: the dotted-key
// prefixes it made become explicit, so no later header reopens them.
func (t *tables) closeSection() {
	for _, p := range t.pending {
		p.explicit = true
	}
	t.pending = nil
}

// headerStep passes a [parts] or [[parts]] header that starts at offset
// at through part, an ancestor of its last part, below n, and returns
// part's node. A [[parts]] header refuses an ancestor that is a value: a
// scalar, an inline table or an array (base#1441); a [parts] header
// refuses the same ancestors.
func (t *tables) headerStep(n *node, part string, aot bool, at int) (*node, error) {
	n = n.child(part)
	switch {
	case n.kind == nodeScalar, !n.container() && aot:
		return nil, t.refuse(at, ReasonDuplicate)
	case !n.container():
		return nil, t.refuse(at, ReasonRedefine)
	}
	return n, nil
}

// headerLeaf opens part, the last part of a [parts] or [[parts]] header
// that starts at offset at, below n and returns the table it opens. A
// [[parts]] header refuses a path that exists as anything but an array of
// tables; a [parts] header refuses a path a header or dotted keys defined.
func (t *tables) headerLeaf(n *node, part string, aot bool, at int) (*node, error) {
	c, ok := n.kids[part]
	if aot {
		if ok && c.kind != nodeAOT {
			return nil, t.refuse(at, ReasonDuplicate)
		}
		// Each [[parts]] opens a new element: what the last one held is
		// out of scope.
		c = newNode(nodeAOT)
		n.kids[part] = c
	} else {
		switch {
		case ok && (c.explicit || c.kind == nodeInline || c.kind == nodeArray):
			return nil, t.refuse(at, ReasonRedefine)
		case ok && c.kind != nodeTable:
			return nil, t.refuse(at, ReasonDuplicate)
		}
		c = n.child(part)
	}
	c.explicit = true
	return c, nil
}

// assignStep passes a dotted key that starts at offset at through part,
// an ancestor of its last part, below n, and returns part's node. It
// refuses a part a header defined and a part that is a value.
func (t *tables) assignStep(n *node, part string, at int) (*node, error) {
	c, ok := n.kids[part]
	switch {
	case ok && c.explicit:
		return nil, t.refuse(at, ReasonRedefine)
	case ok && !c.container():
		return nil, t.refuse(at, ReasonDuplicate)
	}
	n = n.child(part)
	t.pending = append(t.pending, n)
	return n, nil
}

// define records key part as a new node below n and returns it, and
// refuses ReasonDuplicate at offset at when n already holds part.
func (t *tables) define(n *node, part string, at int) (*node, error) {
	if _, ok := n.kids[part]; ok {
		return nil, t.refuse(at, ReasonDuplicate)
	}
	c := newNode(nodeScalar)
	n.kids[part] = c
	return c, nil
}

// inline reads an inline table whose `{` is at t.i, holding tomllib's
// inline-table rules within it: no key passes through or repeats an
// inline table, array or scalar written earlier in it; no line ending
// stands between its tokens, and no comma before its `}` (TOML 1.0
// inline-table; base#1441). f is the frame of
// tomllib's parse_inline_table; its skip_chars, flag and nest calls run
// at f+1, and each pair's parse_key_value_pair at f+1, whose parse_key
// runs at f+2 and whose value is read at f+2.
func (t *tables) inline(f int) error {
	if err := t.reach(f + 1); err != nil {
		return err
	}
	t.i++
	local := newNode(nodeTable) // the paths this inline table defined
	if err := t.inlineBlank(); err != nil {
		return err
	}
	if t.eat("}") {
		return nil
	}
	for {
		start := t.i
		n := local
		err := t.key(func(part string, cost int, dotted bool) (err error) {
			if err = t.reach(f + 3 + cost); err != nil {
				return err
			}
			if dotted {
				n, err = t.inlineStep(n, part, start)
			} else {
				n, err = t.define(n, part, start)
			}
			return err
		})
		if err != nil {
			return err
		}
		if err := t.inlineBlank(); err != nil {
			return err
		}
		if !t.eat("=") {
			return errStop
		}
		if err := t.inlineBlank(); err != nil {
			return err
		}
		if n.kind, err = t.value(f + 2); err != nil {
			return err
		}
		if err := t.inlineBlank(); err != nil {
			return err
		}
		if t.eat("}") {
			return nil
		}
		comma := t.i
		if !t.eat(",") {
			return errStop
		}
		if err := t.inlineBlank(); err != nil {
			return err
		}
		if t.i < len(t.src) && t.src[t.i] == '}' {
			return commaRefusal(t.label, t.src, comma)
		}
	}
}

// inlineStep passes an inline-table member's dotted key that starts at
// offset at through part, an ancestor of its last part, below n, and
// returns part's node. It refuses a part the inline table already holds
// as anything but a table.
func (t *tables) inlineStep(n *node, part string, at int) (*node, error) {
	if c, ok := n.kids[part]; ok && c.kind != nodeTable {
		return nil, t.refuse(at, ReasonDuplicate)
	}
	return n.child(part), nil
}

// inlineBlank skips the spaces, tabs and comment at t.i inside an inline
// table and refuses the line ending it then stands on.
func (t *tables) inlineBlank() error {
	t.skipBlank(false)
	if t.i < len(t.src) && lineEnd(t.src, t.i) {
		return newlineRefusal(t.label, t.src, t.i)
	}
	return nil
}

// value reads the value at t.i and returns its node kind. f is the frame
// of tomllib's parse_value for it. value checks no frame of its own:
// every caller has already reached a deeper one (array f+1, inline its
// key's f+1+cost, a statement the fixed statementValueFrame), so a check
// of f here could never refuse.
func (t *tables) value(f int) (byte, error) {
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
	t.i = bareEnd(t.src, t.i)
	if t.i == start {
		return 0, errStop
	}
	end := t.i
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

// bareEnd returns the offset just past the bare value token (a number,
// boolean, date or time) that starts at offset i of src: the token ends at
// a blank, a comma, a closing bracket or brace, a comment or a line
// ending. A full date followed by one space and `HH:` goes on as a
// date-time whose delimiter is that space (TOML 1.0 offset-date-time,
// local-date-time); no other bare value holds a blank, so what follows a
// blank is the next token, never part of this one (base#1441).
func bareEnd(src []byte, i int) int {
	end := func(j int) int {
		for j < len(src) && !strings.ContainsRune(",]}#\n\r \t", rune(src[j])) {
			j++
		}
		return j
	}
	j := end(i)
	if j-i == 10 && fullDate(src[i:j]) && j+3 < len(src) && src[j] == ' ' && digits(src[j+1:j+3]) && src[j+3] == ':' {
		j = end(j + 1)
	}
	return j
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

// key reads a dotted key at t.i. After each part, and the blanks and
// `.` after it, it calls visit with the part, how many frames below
// tomllib's parse_key_part the deepest part so far goes (one for a bare
// part, skip_chars; the str cost for a quoted one), and whether a `.`
// followed it; a refusal visit returns ends the key there. So a rule the
// parts already read break is refused before any later byte of the key
// is read (TestCheckRefusesInDocumentOrder).
func (t *tables) key(visit func(part string, cost int, dotted bool) error) error {
	cost := 0
	for {
		t.skipBlank(false)
		if t.i >= len(t.src) {
			return errStop
		}
		var part string
		switch c := t.src[t.i]; {
		case c == '"' || c == '\'':
			s, n, err := t.str()
			if err != nil {
				return err
			}
			part = s
			cost = max(cost, n)
		case isBareKeyByte(c):
			start := t.i
			for t.i < len(t.src) && isBareKeyByte(t.src[t.i]) {
				t.i++
			}
			part = string(t.src[start:t.i])
			cost = max(cost, 1)
		default:
			return errStop
		}
		t.skipBlank(false)
		dotted := t.eat(".")
		if err := visit(part, cost, dotted); err != nil || !dotted {
			return err
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
// and is_unicode_scalar_value (5 one-line, 6 multi-line). A `\e` or `\x`
// escape in a basic string is refused at its backslash (base#1441); a
// single-line string a line ending leaves unclosed stops the reading.
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
		if len(delim) == 1 && lineEnd(t.src, t.i) {
			return "", 0, errStop // a single-line string left unclosed
		}
		if q == '"' && t.src[t.i] == '\\' {
			if t.i+1 < len(t.src) && (t.src[t.i+1] == 'e' || t.src[t.i+1] == 'x') {
				return "", 0, escapeRefusal(t.label, t.src, t.i)
			}
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
