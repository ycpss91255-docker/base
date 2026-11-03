package schema

import (
	"errors"
	"fmt"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/locate"
)

// errShape is the panic bind raises when the locator's tree and the value
// the parser decoded differ in shape: the command's panic path, exit 4
// (ADR-00000039), rather than a refusal at a guessed position.
var errShape = errors.New("schema: the locator tree and the parsed document differ")

// bound is one node of the locator's tree joined to the value the parser
// decoded for it (base#1442 redesign r2): the node gives the key, its
// records and the written order, the value gives the decoded content.
type bound struct {
	node  *locate.Node
	value any
	// children are the node's children, each joined to its value, in the
	// node's order: a table's keys as first created, an array's entries by
	// index.
	children []*bound
}

// bind joins the tree under n to the decoded value v, walking both by key
// and by index. A key or entry that one side has and the other lacks, or a
// node whose kind does not hold v's kind, panics with errShape.
func bind(n *locate.Node, v any, path []string) *bound {
	b := &bound{node: n, value: v}
	switch x := v.(type) {
	case map[string]any:
		if !holdsTable(n) || len(n.Children) != len(x) {
			shapePanic(path, n)
		}
		for _, c := range n.Children {
			cv, ok := x[c.Key]
			if !ok {
				shapePanic(append(path, c.Key), c)
			}
			b.children = append(b.children, bind(c, cv, append(append([]string{}, path...), c.Key)))
		}
	case []map[string]any:
		items := make([]any, len(x))
		for i, e := range x {
			items[i] = e
		}
		b.children = bindItems(n, items, path)
	case []any:
		b.children = bindItems(n, x, path)
	default:
		if n.Kind != locate.NKey && n.Kind != locate.NItem || n.Open != 0 || len(n.Children) != 0 {
			shapePanic(path, n)
		}
	}
	return b
}

// bindItems joins the entries of an array to the elements of an
// array-of-tables node or the items of a node holding an inline array.
func bindItems(n *locate.Node, items []any, path []string) []*bound {
	if n.Kind != locate.NArrayTables && n.Open != '[' || len(n.Children) != len(items) {
		shapePanic(path, n)
	}
	out := make([]*bound, len(items))
	for i, c := range n.Children {
		out[i] = bind(c, items[i], path)
	}
	return out
}

// holdsTable reports whether n holds a table: the root, a table, an
// element, a dotted parent inside an inline value, or a key or item
// holding an inline table.
func holdsTable(n *locate.Node) bool {
	switch n.Kind {
	case locate.NTable, locate.NElement, locate.NInlineTable:
		return true
	case locate.NKey, locate.NItem:
		return n.Open == '{'
	case locate.NArrayTables:
	}
	return false
}

func shapePanic(path []string, n *locate.Node) {
	panic(fmt.Errorf("%w at %q (node kind %d)", errShape, path, n.Kind))
}

// isTable reports whether b's value is a table.
func (b *bound) isTable() bool {
	_, ok := b.value.(map[string]any)
	return ok
}

// isArray reports whether b's value is an array, of tables or inline.
func (b *bound) isArray() bool {
	switch b.value.(type) {
	case []map[string]any, []any:
		return true
	}
	return false
}

// keyless reports whether b is an element or an item, which an array
// holds by index.
func (b *bound) keyless() bool {
	return b.node.Kind == locate.NElement || b.node.Kind == locate.NItem
}

// firstPos is the position of b's earliest record (locate.Node.First),
// or 0, 0 for the root.
func (b *bound) firstPos() (line, col int) {
	if first := b.node.First(); first != nil {
		return first.KeyLine, first.KeyCol
	}
	return 0, 0
}

// declPos is the position of b's explicit record, the key or header that
// writes it, or firstPos when it has none.
func (b *bound) declPos() (line, col int) {
	if d := b.node.Decl(); d != nil {
		return d.KeyLine, d.KeyCol
	}
	return b.firstPos()
}

// payload is the value of b for the array stage: its
// members in written order, each at its own line (base#1442).
func (b *bound) payload() Value {
	line, _ := b.firstPos()
	switch {
	case b.isArray():
		out := Value{Kind: VArray, Line: line}
		for _, c := range b.children {
			item := c.payload()
			item.Header = c.node.Kind == locate.NElement
			out.Items = append(out.Items, item)
		}
		return out
	case b.isTable():
		out := Value{Kind: VTable, Line: line}
		for _, c := range b.children {
			out.Members = append(out.Members, Member{Key: c.node.Key, Value: c.payload()})
		}
		return out
	}
	var s Scalar
	// A kind Scalar does not decode keeps its zero Scalar.
	_ = s.UnmarshalTOML(b.value)
	return Value{Kind: VScalar, Scalar: s, Line: line}
}
