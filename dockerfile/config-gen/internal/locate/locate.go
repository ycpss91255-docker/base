// Package locate is a line index of a TOML document: it records where
// each table header and key is written, so a caller can attribute a key
// the parser reports to its line (base#1442). It is not a parser and
// never decides whether the document is valid.
package locate

import (
	"bytes"
	"strconv"
	"strings"
)

// Kind is how an occurrence is written.
type Kind int

const (
	// Header is a `[path]` table header (or an implicit table).
	Header Kind = iota
	// ArrayHeader is a `[[path]]` array-table header.
	ArrayHeader
	// Key is a `key = value` line.
	Key
)

// Occurrence is one place a path is written. (Path, Ordinal) identifies
// it: Ordinal counts the earlier explicit occurrences of the same path.
type Occurrence struct {
	Path    []string
	Ordinal int
	Kind    Kind
	// Implicit marks a table with no header of its own, created by a
	// header or a dotted key under it; its lines are its first creator's.
	Implicit bool
	// Inline marks a key whose value is an inline table or array. A key
	// written inside the value is not one of Entries; Members lists it.
	Inline bool
	// KeyLine is the 1-based line the header or key is written on.
	KeyLine int
	// KeyCol is the 1-based byte column of the header's `[` or the key's
	// first byte on KeyLine; an implicit table's is its first creator's.
	KeyCol int
	// ValueEndLine is the 1-based line the key's value ends on (KeyLine
	// for a header). An array value is given its start line, the line the
	// library reports for it.
	ValueEndLine int
}

// Lookup is the result of a unique lookup.
type Lookup int

const (
	// Missing: the path is not written.
	Missing Lookup = iota
	// Found: the path is written exactly once.
	Found
	// Repeated: the path is written more than once; no position is given.
	Repeated
)

// NodeKind is what a node of the document tree is.
type NodeKind int

const (
	// NTable is a table: the root, a `[path]` header's, or one a header
	// or a dotted key creates implicitly.
	NTable NodeKind = iota
	// NArrayTables is the array a `[[path]]` header appends to.
	NArrayTables
	// NElement is one element of an NArrayTables node, by index.
	NElement
	// NKey is a `key = value` key.
	NKey
)

// Node is one node of the document tree (base#1442). Its records are the
// occurrences of the log that write it, in source order, so a table that
// is created implicitly and declared later keeps both positions.
type Node struct {
	// Key is the node's key as the scanner decodes it; "" for the root and
	// an element.
	Key  string
	Kind NodeKind
	// Occ are the node's records, in source order.
	Occ []*Occurrence
	// Children are in first-creation order; elements by index.
	Children []*Node
}

// child is n's child with key k, or nil.
func (n *Node) child(k string) *Node {
	for _, c := range n.Children {
		if c.Key == k {
			return c
		}
	}
	return nil
}

// add appends a child with key k and kind to n, holding rec unless it is
// nil, and returns it.
func (n *Node) add(k string, kind NodeKind, rec *Occurrence) *Node {
	c := &Node{Key: k, Kind: kind}
	if rec != nil {
		c.Occ = append(c.Occ, rec)
	}
	n.Children = append(n.Children, c)
	return c
}

// Map is the occurrence index of one document.
type Map struct {
	entries []*Occurrence
	members []*Occurrence
	// inlineTables is every table a dotted key inside an inline value
	// creates for its parent components.
	inlineTables []*Occurrence
	root         *Node
}

// Root returns the root of the document tree: headers resolve from it,
// and a `key = value` line from the table or element the last header
// opened (base#1442 redesign r3).
func (m *Map) Root() *Node { return m.root }

// Entries returns every occurrence in document order.
func (m *Map) Entries() []Occurrence { return values(m.entries) }

// values copies the records of rs.
func values(rs []*Occurrence) []Occurrence {
	out := make([]Occurrence, len(rs))
	for i, r := range rs {
		out[i] = *r
	}
	return out
}

// Members returns every occurrence of the key path written inside an
// inline value, in document order: a member of an inline table, or of a
// table item of an inline array, under the path the parser names it by,
// the holding key's path and the member's key with no item index
// (base#1442). An inline value may span lines, so each member keeps its
// own line and column.
func (m *Map) Members(path []string) []Occurrence {
	var out []Occurrence
	want := pathID(path)
	for _, o := range m.members {
		if pathID(o.Path) == want {
			out = append(out, *o)
		}
	}
	return out
}

// InlineTables returns every implicit table created for a parent
// component of a dotted key written inside an inline value, in document
// order, at the line and column of the dotted key that creates it, as an
// implicit table of a dotted `key = value` line is given its creator's
// (base#1442 review round 2). A path is listed once per dotted key that
// creates it, so each table item of an inline array keeps its own.
func (m *Map) InlineTables(path []string) []Occurrence {
	var out []Occurrence
	want := pathID(path)
	for _, o := range m.inlineTables {
		if pathID(o.Path) == want {
			out = append(out, *o)
		}
	}
	return out
}

// Table is the unique lookup of a table path.
func (m *Map) Table(path []string) (Occurrence, Lookup) { return unique(m.Tables(path)) }

// Key is the unique lookup of a key path.
func (m *Map) Key(path []string) (Occurrence, Lookup) { return unique(m.Keys(path)) }

// Tables returns every occurrence of the table path, in document order.
func (m *Map) Tables(path []string) []Occurrence {
	return m.filter(path, func(o Occurrence) bool { return o.Kind != Key })
}

// Keys returns every occurrence of the key path, in document order.
func (m *Map) Keys(path []string) []Occurrence {
	return m.filter(path, func(o Occurrence) bool { return o.Kind == Key })
}

func (m *Map) filter(path []string, keep func(Occurrence) bool) []Occurrence {
	var out []Occurrence
	want := pathID(path)
	for _, o := range m.entries {
		if keep(*o) && pathID(o.Path) == want {
			out = append(out, *o)
		}
	}
	return out
}

func unique(all []Occurrence) (Occurrence, Lookup) {
	switch len(all) {
	case 0:
		return Occurrence{}, Missing
	case 1:
		return all[0], Found
	default:
		return Occurrence{}, Repeated
	}
}

// pathID is a collision-free string form of a path.
func pathID(path []string) string {
	parts := make([]string, len(path))
	for i, p := range path {
		parts[i] = strconv.Quote(p)
	}
	return strings.Join(parts, ".")
}

// Index scans src and returns its occurrence index.
func Index(src []byte) *Map {
	root := &Node{Kind: NTable}
	s := &scanner{src: src, line: 1, ordinal: map[string]int{}, memberOrdinal: map[string]int{}, root: root, cur: root}
	s.run()
	return &Map{entries: s.entries, members: s.members, inlineTables: s.inlineTables, root: root}
}

type scanner struct {
	src     []byte
	pos     int
	line    int
	table   []string
	entries []*Occurrence
	members []*Occurrence
	// inlineTables is every implicit table a dotted key inside an inline
	// value creates.
	inlineTables []*Occurrence
	// root is the document tree; cur is the node the last header opened,
	// the one a `key = value` line resolves from.
	root, cur *Node
	ordinal   map[string]int
	// memberOrdinal counts the members of each path recorded so far.
	memberOrdinal map[string]int
}

func (s *scanner) run() {
	for s.pos < len(s.src) {
		switch c := s.src[s.pos]; {
		case c == '\n':
			s.pos++
			s.line++
		case c == ' ' || c == '\t' || c == '\r':
			// Indentation before a header, a key or a comment.
			s.pos++
		case c == '#':
			s.skipLine()
		case c == '[':
			s.header()
		default:
			s.keyValue()
		}
	}
}

func (s *scanner) header() {
	line, col := s.line, s.col()
	kind := Header
	s.pos++
	if s.peek() == '[' {
		kind = ArrayHeader
		s.pos++
	}
	path := s.key()
	s.skipLine()
	// A header resolves from the root.
	n := s.root
	for i := 1; i < len(path); i++ {
		rec := s.implicit(path[:i], line, col)
		c := n.child(path[i-1])
		if c == nil {
			c = n.add(path[i-1], NTable, rec)
		}
		n = c
	}
	rec := s.add(Occurrence{Path: path, Kind: kind, KeyLine: line, KeyCol: col, ValueEndLine: line})
	last := path[len(path)-1]
	c := n.child(last)
	switch {
	case kind == Header:
		if c == nil {
			c = n.add(last, NTable, nil)
		}
		c.Occ = append(c.Occ, rec)
		s.cur = c
	default:
		if c == nil {
			c = n.add(last, NArrayTables, nil)
		}
		c.Occ = append(c.Occ, rec)
		s.cur = c.add("", NElement, rec)
	}
	s.table = path
}

func (s *scanner) keyValue() {
	line, col := s.line, s.col()
	parts := s.key()
	s.skipSpace()
	if s.peek() != '=' {
		s.skipLine()
		return
	}
	s.pos++
	s.skipSpace()
	path := append(append([]string{}, s.table...), parts...)
	// A `key = value` line resolves from the table or element the last
	// header opened.
	n := s.cur
	for i := len(s.table) + 1; i < len(path); i++ {
		rec := s.implicit(path[:i], line, col)
		c := n.child(path[i-1])
		if c == nil {
			c = n.add(path[i-1], NTable, rec)
		}
		n = c
	}
	array := s.peek() == '['
	inline := s.peek() == '{' || array
	s.value(path)
	end := s.line
	if array {
		end = line
	}
	rec := s.add(Occurrence{Path: path, Kind: Key, Inline: inline, KeyLine: line, KeyCol: col, ValueEndLine: end})
	n.add(parts[len(parts)-1], NKey, rec)
	s.skipLine()
}

// col is the 1-based byte column of the scanner's position.
func (s *scanner) col() int {
	return s.pos - bytes.LastIndexByte(s.src[:s.pos], '\n')
}

// implicit records path as an implicit table created at line and col,
// unless a table occurrence of path is already recorded, and returns the
// record it appends, or nil.
func (s *scanner) implicit(path []string, line, col int) *Occurrence {
	want := pathID(path)
	for _, o := range s.entries {
		if o.Kind != Key && pathID(o.Path) == want {
			return nil
		}
	}
	p := append([]string{}, path...)
	rec := &Occurrence{Path: p, Kind: Header, Implicit: true, KeyLine: line, KeyCol: col, ValueEndLine: line}
	s.entries = append(s.entries, rec)
	return rec
}

// add appends o to the log with its ordinal and returns its record.
func (s *scanner) add(o Occurrence) *Occurrence {
	id := pathID(o.Path)
	o.Ordinal = s.ordinal[id]
	s.ordinal[id]++
	rec := &o
	s.entries = append(s.entries, rec)
	return rec
}

// key reads a dotted key up to `=`, `]` or the end of the line.
func (s *scanner) key() []string {
	var parts []string
	for {
		s.skipSpace()
		switch s.peek() {
		case '"':
			parts = append(parts, s.basic())
		case '\'':
			parts = append(parts, s.literal())
		default:
			start := s.pos
			for s.pos < len(s.src) && bare(s.src[s.pos]) {
				s.pos++
			}
			parts = append(parts, string(s.src[start:s.pos]))
		}
		s.skipSpace()
		if s.peek() != '.' {
			return parts
		}
		s.pos++
	}
}

func bare(c byte) bool {
	return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_' || c == '-'
}

// value skips one value written at path, strings included; a multi-line
// string, array or inline table may span lines, and a header-like line
// inside it is its content. Each key inside an inline value is recorded
// as a member (inline).
func (s *scanner) value(path []string) {
	for s.pos < len(s.src) && s.src[s.pos] != '\n' && s.src[s.pos] != '#' {
		if !s.skipString() {
			if c := s.src[s.pos]; c == '[' || c == '{' {
				s.inline(path)
			} else {
				s.pos++
			}
		}
	}
}

// skipString skips the string that starts at the current byte, of any of
// the four TOML string forms, and reports whether one started there.
func (s *scanner) skipString() bool {
	switch {
	case bytes.HasPrefix(s.src[s.pos:], []byte(`"""`)):
		s.multiline('"')
	case bytes.HasPrefix(s.src[s.pos:], []byte(`'''`)):
		s.multiline('\'')
	case s.src[s.pos] == '"':
		s.basic()
	case s.src[s.pos] == '\'':
		s.literal()
	default:
		return false
	}
	return true
}

// inline skips the `[...]` array or `{...}` inline table at the current
// byte, written at path, through its matching close, counting the lines
// it spans; strings and comments inside it are skipped whole. Each
// `key = value` of an inline table is recorded as a member at the line
// and column of its key's first byte, under path plus its dotted key, each
// parent component of a dotted key as an implicit inline table at the same
// line and column, and its value is read at that path; an array's items are read at path, as
// the parser lists the members of each table item of an inline array
// with no item index. A byte that fits neither is skipped, so malformed
// input still ends the scan.
func (s *scanner) inline(path []string) {
	table := s.src[s.pos] == '{'
	s.pos++
	for s.pos < len(s.src) {
		s.skipBlank()
		if s.pos >= len(s.src) {
			return
		}
		switch s.src[s.pos] {
		case ']', '}':
			s.pos++
			return
		case ',':
			s.pos++
			continue
		}
		if !table {
			s.item(path)
			continue
		}
		line, col, start := s.line, s.col(), s.pos
		parts := s.key()
		s.skipSpace()
		if s.peek() != '=' {
			if s.pos == start {
				s.pos++
			}
			continue
		}
		s.pos++
		s.skipSpace()
		p := append(append([]string{}, path...), parts...)
		for i := len(path) + 1; i < len(p); i++ {
			t := append([]string{}, p[:i]...)
			s.inlineTables = append(s.inlineTables, &Occurrence{Path: t, Kind: Header, Implicit: true, KeyLine: line, KeyCol: col, ValueEndLine: line})
		}
		id := pathID(p)
		inline := s.peek() == '{' || s.peek() == '['
		s.item(p)
		s.members = append(s.members, &Occurrence{Path: p, Ordinal: s.memberOrdinal[id], Kind: Key, Inline: inline, KeyLine: line, KeyCol: col, ValueEndLine: s.line})
		s.memberOrdinal[id]++
	}
}

// item skips one value inside an inline value, written at path, up to the
// `,`, closing bracket, end of line or comment that ends it; a nested
// inline value is read by inline.
func (s *scanner) item(path []string) {
	for s.pos < len(s.src) {
		if s.skipString() {
			continue
		}
		switch s.src[s.pos] {
		case '[', '{':
			s.inline(path)
		case ',', ']', '}', '\n', '#':
			return
		default:
			s.pos++
		}
	}
}

// skipBlank skips spaces, tabs, CRs, newlines and comments inside an
// inline value, counting the lines it spans.
func (s *scanner) skipBlank() {
	for s.pos < len(s.src) {
		switch s.src[s.pos] {
		case ' ', '\t', '\r':
			s.pos++
		case '\n':
			s.pos++
			s.line++
		case '#':
			s.skipComment()
		default:
			return
		}
	}
}

// multiline skips a multi-line string delimited by three q bytes through
// its closing delimiter, counting the lines it spans. In a basic string
// (q is `"`) a backslash escapes the byte after it, so `\"""` does not
// close the string. The closing delimiter may follow one or two quote
// bytes of the content (`"""a""""` is `a"`), so a run of up to five q
// bytes is consumed whole.
func (s *scanner) multiline(q byte) {
	s.pos += 3
	for s.pos < len(s.src) {
		c := s.src[s.pos]
		switch {
		case c == '\n':
			s.line++
			s.pos++
		case c == '\\' && q == '"':
			s.pos++
			if s.pos < len(s.src) && s.src[s.pos] != '\n' {
				s.pos++
			}
		case c == q && s.pos+2 < len(s.src) && s.src[s.pos+1] == q && s.src[s.pos+2] == q:
			n := 0
			for n < 5 && s.pos < len(s.src) && s.src[s.pos] == q {
				s.pos++
				n++
			}
			return
		default:
			s.pos++
		}
	}
}

// basic reads a single-line basic string and returns its decoded text:
// an escape never ends the string. The scan stops at the end of the line
// or of the input, so an unterminated string cannot run past either.
func (s *scanner) basic() string {
	s.pos++
	var b strings.Builder
	for s.pos < len(s.src) && s.src[s.pos] != '\n' {
		switch c := s.src[s.pos]; c {
		case '"':
			s.pos++
			return b.String()
		case '\\':
			s.escape(&b)
		default:
			b.WriteByte(c)
			s.pos++
		}
	}
	return b.String()
}

// escape decodes the TOML 1.0 escape sequence at the current backslash
// into b; any other escaped byte is kept as written.
func (s *scanner) escape(b *strings.Builder) {
	s.pos++
	if s.pos >= len(s.src) || s.src[s.pos] == '\n' {
		return
	}
	c := s.src[s.pos]
	s.pos++
	switch c {
	case 'b':
		b.WriteByte('\b')
	case 't':
		b.WriteByte('\t')
	case 'n':
		b.WriteByte('\n')
	case 'f':
		b.WriteByte('\f')
	case 'r':
		b.WriteByte('\r')
	case 'u':
		s.hexRune(b, 4)
	case 'U':
		s.hexRune(b, 8)
	default:
		b.WriteByte(c)
	}
}

// hexRune decodes the n hex digits at the current position as one code
// point into b.
func (s *scanner) hexRune(b *strings.Builder, n int) {
	if s.pos+n > len(s.src) {
		s.pos = len(s.src)
		return
	}
	v, err := strconv.ParseUint(string(s.src[s.pos:s.pos+n]), 16, 32)
	s.pos += n
	if err == nil {
		b.WriteRune(rune(v))
	}
}

// literal reads a single-line literal string, which has no escapes. The
// scan stops at the end of the line or of the input.
func (s *scanner) literal() string {
	s.pos++
	start := s.pos
	for s.pos < len(s.src) && s.src[s.pos] != '\'' && s.src[s.pos] != '\n' {
		s.pos++
	}
	text := string(s.src[start:s.pos])
	if s.pos < len(s.src) && s.src[s.pos] == '\'' {
		s.pos++
	}
	return text
}

func (s *scanner) peek() byte {
	if s.pos < len(s.src) {
		return s.src[s.pos]
	}
	return 0
}

func (s *scanner) skipSpace() {
	for s.pos < len(s.src) && (s.src[s.pos] == ' ' || s.src[s.pos] == '\t' || s.src[s.pos] == '\r') {
		s.pos++
	}
}

func (s *scanner) skipComment() {
	for s.pos < len(s.src) && s.src[s.pos] != '\n' {
		s.pos++
	}
}

// skipLine moves past the rest of the current line, newline included.
func (s *scanner) skipLine() {
	s.skipComment()
	if s.pos < len(s.src) {
		s.pos++
		s.line++
	}
}
