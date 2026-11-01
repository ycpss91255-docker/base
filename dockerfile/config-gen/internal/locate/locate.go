// Package locate is a line index of a TOML document: it records where
// each table header and key is written, so a caller can attribute a key
// the parser reports to its line (base#1442). It is not a parser and
// never decides whether the document is valid.
package locate

import (
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
	// Inline marks a key whose value is an inline table or array; nothing
	// inside the value is indexed.
	Inline bool
	// KeyLine is the 1-based line the header or key is written on.
	KeyLine int
	// ValueEndLine is the 1-based line the key's value ends on (KeyLine
	// for a header).
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

// Map is the occurrence index of one document.
type Map struct {
	entries []Occurrence
}

// Entries returns every occurrence in document order.
func (m *Map) Entries() []Occurrence { return m.entries }

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
		if keep(o) && pathID(o.Path) == want {
			out = append(out, o)
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
	s := &scanner{src: src, line: 1, ordinal: map[string]int{}}
	s.run()
	return &Map{entries: s.entries}
}

type scanner struct {
	src     []byte
	pos     int
	line    int
	table   []string
	entries []Occurrence
	ordinal map[string]int
}

func (s *scanner) run() {
	for s.pos < len(s.src) {
		switch c := s.src[s.pos]; {
		case c == '\n':
			s.pos++
			s.line++
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
	line := s.line
	kind := Header
	s.pos++
	if s.peek() == '[' {
		kind = ArrayHeader
		s.pos++
	}
	path := s.key()
	s.skipLine()
	for i := 1; i < len(path); i++ {
		s.implicit(path[:i], line)
	}
	s.add(Occurrence{Path: path, Kind: kind, KeyLine: line, ValueEndLine: line})
	s.table = path
}

func (s *scanner) keyValue() {
	line := s.line
	parts := s.key()
	s.skipSpace()
	if s.peek() != '=' {
		s.skipLine()
		return
	}
	s.pos++
	s.skipSpace()
	path := append(append([]string{}, s.table...), parts...)
	for i := len(s.table) + 1; i < len(path); i++ {
		s.implicit(path[:i], line)
	}
	inline := s.peek() == '{' || s.peek() == '['
	s.value()
	s.add(Occurrence{Path: path, Kind: Key, Inline: inline, KeyLine: line, ValueEndLine: s.line})
	s.skipLine()
}

// implicit records path as an implicit table created on line, unless a
// table occurrence of path is already recorded.
func (s *scanner) implicit(path []string, line int) {
	want := pathID(path)
	for _, o := range s.entries {
		if o.Kind != Key && pathID(o.Path) == want {
			return
		}
	}
	p := append([]string{}, path...)
	s.entries = append(s.entries, Occurrence{Path: p, Kind: Header, Implicit: true, KeyLine: line, ValueEndLine: line})
}

func (s *scanner) add(o Occurrence) {
	id := pathID(o.Path)
	o.Ordinal = s.ordinal[id]
	s.ordinal[id]++
	s.entries = append(s.entries, o)
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

// value skips one single-line value, strings included.
func (s *scanner) value() {
	for s.pos < len(s.src) && s.src[s.pos] != '\n' && s.src[s.pos] != '#' {
		switch s.src[s.pos] {
		case '"':
			s.basic()
		case '\'':
			s.literal()
		default:
			s.pos++
		}
	}
}

// basic reads a single-line basic string without escapes.
func (s *scanner) basic() string {
	return s.quoted('"')
}

// literal reads a single-line literal string.
func (s *scanner) literal() string {
	return s.quoted('\'')
}

// quoted reads the bytes between an opening quote and the next q.
func (s *scanner) quoted(q byte) string {
	s.pos++
	start := s.pos
	for s.src[s.pos] != q {
		s.pos++
	}
	s.pos++
	return string(s.src[start : s.pos-1])
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
