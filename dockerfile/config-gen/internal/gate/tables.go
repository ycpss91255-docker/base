package gate

import (
	"bytes"
	"errors"
	"regexp"
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
// (base#1851).
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

// The token patterns the table pass reads with, each anchored at the
// byte it reads from. A string is a multi-line basic or literal string
// up to its first run of three to five closing quotes (TOML 1.0
// ml-basic-body, ml-literal-body: one or two quotes of content may come
// before the closing three), a basic string whose escapes are each read
// as one unit, or a literal string. A bare value is a number, boolean,
// date or time; a full date followed by a space and a digit takes the
// space and the run after it too (a local or offset datetime with a
// space delimiter).
var (
	keyPartPattern = regexp.MustCompile(`^(?:[A-Za-z0-9_-]+|"(?:[^"\\]|\\.)*"|'[^']*')`)
	scalarPattern  = regexp.MustCompile(`^(?:"""(?s:[^\\]|\\.)*?"{3,5}|'''(?s:.)*?'{3,5}|"(?:[^"\\]|\\.)*"|'[^']*'|\d{4}-\d{2}-\d{2} \d[0-9A-Za-z_+.:-]*|[0-9A-Za-z_+.:-]+)`)
	blankPattern   = regexp.MustCompile(`^(?:[ \t]|#[^\n]*)*`)
	linesPattern   = regexp.MustCompile(`^(?:[ \t\r\n]|#[^\n]*)*`)
)

// tables reads one document in document order and holds tomllib's table
// rules (base#1851). A dotted key may not pass through a table a header
// defined, or a dotted-key table an earlier section made; nothing may
// extend an inline table or an array value; a key may not name a path
// that already exists. A break of one of these rules is refused at the
// first byte of the key or header that breaks it. It reads a valid TOML
// document exactly and checks no grammar of its own: where it finds no
// key it stops with errStop, and a document it misreads is one the
// decoder refuses anyway.
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
}

// errStop ends the pass where no key starts; Check then has no table
// rule to refuse.
var errStop = errors.New("gate: table pass stopped")

// newTables returns a pass over src that starts at its first byte and
// names label in its refusals.
func newTables(label string, src []byte) *tables {
	return &tables{src: src, label: label, root: newNode(nodeTable)}
}

// document reads every statement of src: a [header], a [[header]] or a
// key = value pair. Each statement reads at least one byte or returns
// an error, so the loop ends.
func (t *tables) document() error {
	table := t.root // the current table
	for {
		t.blank(linesPattern)
		var err error
		switch t.peek() {
		case 0:
			return nil
		case '[':
			table, err = t.header()
		default:
			err = t.pair(table, t.assignStep)
		}
		if err != nil {
			return err
		}
	}
}

// header reads a [parts] or [[parts]] header at t.i and returns the
// table it opens. The dotted-key prefixes the section before it made
// become explicit first, so no header reopens them.
func (t *tables) header() (*node, error) {
	start := t.i
	t.i++ // the `[` document saw
	aot := t.eat("[")
	for _, p := range t.pending {
		p.explicit = true
	}
	t.pending = nil
	n := t.root
	err := t.key(func(part string, dotted bool) (err error) {
		if dotted {
			n, err = t.headerStep(n, part, aot, start)
		} else {
			n, err = t.headerLeaf(n, part, aot, start)
		}
		return err
	})
	if err != nil {
		return nil, err
	}
	t.eat("]")
	if aot {
		t.eat("]")
	}
	return n, nil
}

// pair reads a key = value pair at t.i below n. step passes the key
// through each part before its last; the last part is defined below the
// node step returned.
func (t *tables) pair(n *node, step func(n *node, part string, at int) (*node, error)) error {
	t.blank(blankPattern)
	start := t.i
	err := t.key(func(part string, dotted bool) (err error) {
		if dotted {
			n, err = step(n, part, start)
		} else {
			n, err = t.define(n, part, start)
		}
		return err
	})
	if err != nil {
		return err
	}
	t.eat("=")
	n.kind, err = t.value()
	return err
}

// headerStep passes a [parts] or [[parts]] header that starts at offset
// at through part, an ancestor of its last part, below n, and returns
// part's node. A [[parts]] header refuses an ancestor that is a value: a
// scalar, an inline table or an array; a [parts] header refuses the same
// ancestors.
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

// value reads the value at t.i and returns its node kind.
func (t *tables) value() (byte, error) {
	t.blank(blankPattern)
	switch t.peek() {
	case '{':
		return nodeInline, t.inline()
	case '[':
		return nodeArray, t.array()
	}
	t.i += len(scalarPattern.Find(t.src[t.i:]))
	return nodeScalar, nil
}

// inline reads an inline table whose `{` is at t.i. Its keys are paths
// of its own, so no key passes through or repeats an inline table, array
// or scalar written earlier in it.
func (t *tables) inline() error {
	t.i++ // the `{` value saw
	local := newNode(nodeTable)
	t.blank(blankPattern)
	if t.eat("}") {
		return nil
	}
	for {
		if err := t.pair(local, t.inlineStep); err != nil {
			return err
		}
		t.blank(blankPattern)
		if !t.eat(",") {
			t.eat("}")
			return nil
		}
	}
}

// array reads an array whose `[` is at t.i.
func (t *tables) array() error {
	t.i++ // the `[` value saw
	for {
		t.blank(linesPattern)
		if t.eat("]") {
			return nil
		}
		if _, err := t.value(); err != nil {
			return err
		}
		t.blank(linesPattern)
		if !t.eat(",") {
			t.eat("]")
			return nil
		}
	}
}

// key reads a dotted key at t.i. After each part, and the blanks and
// `.` after it, it calls visit with the part, a basic string's escapes
// decoded and a literal string's quotes removed, and whether a `.`
// followed it; a refusal visit returns ends the key there. It stops with
// errStop where no key part starts.
func (t *tables) key(visit func(part string, dotted bool) error) error {
	for {
		t.blank(blankPattern)
		m := keyPartPattern.Find(t.src[t.i:])
		if m == nil {
			return errStop
		}
		t.i += len(m)
		part := string(m)
		switch m[0] {
		case '"':
			if s, err := strconv.Unquote(part); err == nil {
				part = s
			}
		case '\'':
			part = strings.Trim(part, "'")
		}
		t.blank(blankPattern)
		dotted := t.eat(".")
		if err := visit(part, dotted); err != nil || !dotted {
			return err
		}
	}
}

// blank skips what p matches at t.i: spaces, tabs and comments, and line
// endings too for linesPattern.
func (t *tables) blank(p *regexp.Regexp) {
	t.i += len(p.Find(t.src[t.i:]))
}

// peek returns the byte at t.i, or 0 at the end of src.
func (t *tables) peek() byte {
	if r := t.src[t.i:]; len(r) != 0 {
		return r[0]
	}
	return 0
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
// class, at offset at.
func (t *tables) refuse(at int, reason Reason) error {
	return refusal(t.label, t.src, at, reason, "key path defined twice is not TOML 1.0")
}
