// Package tables lists the tables a TOML file declares, one dotted path per
// line, in the order the bridge's `toml_bridge.py --tables` prints them
// (base#1469).
package tables

import (
	"bytes"

	"github.com/BurntSushi/toml"
)

// node is one key of the parsed document, with its children in the order
// they were first seen.
type node struct {
	name string
	kids []*node
}

// child returns n's child called name, appending it when n has none yet.
func (n *node) child(name string) *node {
	for _, k := range n.kids {
		if k.name == name {
			return k
		}
	}
	k := &node{name: name}
	n.kids = append(n.kids, k)
	return k
}

// Emit parses src and returns the dotted path of every table, LF-terminated.
// The parser lists keys flat, in declaration order, with no key for an
// implicit parent; the tree built here puts a parent where its first child
// appears and gathers its later children under it, as the bridge's dict
// walk does. A key enters the tree by its key parts as given, so a dot
// inside a quoted key never starts a new level; a key the parser does not
// type as a table enters only as far as its parent, so a value is never
// listed while the tables a dotted key declares on its way still are.
func Emit(src []byte) ([]byte, error) {
	var doc map[string]any
	md, err := toml.Decode(string(src), &doc)
	if err != nil {
		return nil, err
	}
	root := &node{}
	for _, key := range md.Keys() {
		parts := []string(key)
		if md.Type(key...) != "Hash" {
			parts = parts[:len(parts)-1]
		}
		n := root
		for _, part := range parts {
			n = n.child(part)
		}
	}
	var out bytes.Buffer
	walk(&out, "", root)
	return out.Bytes(), nil
}

// walk writes each node's path, then its children's, prefixing a path with
// its parent's only when the parent's path is non-empty.
func walk(out *bytes.Buffer, prefix string, n *node) {
	for _, k := range n.kids {
		path := k.name
		if prefix != "" {
			path = prefix + "." + k.name
		}
		out.WriteString(path + "\n")
		walk(out, path, k)
	}
}
