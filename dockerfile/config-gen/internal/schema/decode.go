// Package schema decodes a setup.toml layer and refuses what schema.sh
// does not know (base#1442).
package schema

import (
	"bytes"
	"errors"
	"fmt"
	"sort"
	"strings"

	"github.com/BurntSushi/toml"

	"github.com/ycpss91255-docker/base/dockerfile/config-gen/internal/locate"
)

// Refusal is one key the decode refused: the event id, the TOML path of
// the key and the 1-based line it is written on.
type Refusal struct {
	Event string
	Path  []string
	Line  int
}

// Config is the decoded layer.
type Config struct {
	Logging Logging
	// Tree is every accepted table node, in the bridge's traversal order.
	Tree Tree
	// Deferred is every accepted array with its payload, in the order its
	// ChildDeferred appears in the traversal; Child.Defer indexes it.
	Deferred []Deferred
}

// known is the set of sections _setup_known_section accepts
// (dist/script/docker/lib/setup_cmd.sh). Only [deploy], [devices],
// [environment], [logging], [security] and [volumes] so far; the other sections
// follow in later cycles of base#1442. A key of a known section is known
// when it resolves to a SCHEMA_VALIDATOR row, as _setup_known_key does.
var known = map[string]bool{
	"deploy":      true,
	"devices":     true,
	"environment": true,
	"logging":     true,
	"security":    true,
	"volumes":     true,
}

// Decode decodes src and returns one conf_unknown_table refusal for each
// top-level table schema.sh does not know, at its header line, and one
// conf_unknown_key refusal for each key of a known table that the table
// does not register. Keys under an unknown table get no refusal. A key
// written at the root is one conf_top_level_key refusal at its line. A
// known key whose value Validate refuses is one refusal with Validate's
// event at the key's line; an array at a known key is one
// conf_value_type_refused refusal at its line.
func Decode(src []byte) (*Config, []Refusal) {
	var root map[string]toml.Primitive
	md, err := toml.Decode(string(src), &root)
	if err != nil {
		return nil, []Refusal{{Event: "conf_toml_parse_failed"}}
	}
	var refusals []Refusal
	var lines *locate.Map
	for _, k := range md.Keys() {
		ok := known[k[0]]
		// A root table whose name is `logging.` plus at least one byte
		// (`["logging.a"]`) is a per-service section by its text, which
		// _setup_known_section accepts (base#1442).
		if len(k) == 1 && !ok && !(serviceText(k[0]) && md.Type(k...) == "Hash") {
			if lines == nil {
				lines = locate.Index(src)
			}
			if occ, found := lines.Key(k); found == locate.Found {
				refusals = append(refusals, Refusal{Event: "conf_top_level_key", Path: k, Line: occ.KeyLine})
				continue
			}
			occ, _ := lines.Table(k)
			refusals = append(refusals, Refusal{Event: "conf_unknown_table", Path: k, Line: occ.KeyLine})
		}
		// An array of tables at a known section name is the legacy
		// spelling the array stage handles; its keys are not scalars of
		// the section, so they are not looked up here. An array of tables
		// nested under a known section is owned by the array stage too,
		// so it is classified by its TOML type before any name lookup
		// (base#1442).
		if len(k) != 2 || !ok || md.Type(k[0]) == "ArrayHash" || md.Type(k...) == "ArrayHash" {
			continue
		}
		// A plain table nested under [logging] is a per-service section
		// _setup_known_section accepts, classified by its TOML type
		// before any key name lookup (base#1442).
		if md.Type(k...) == "Hash" && k[0] == "logging" {
			continue
		}
		// A plain table nested under any other known section is a section
		// of its own that _setup_known_section does not know, so it is
		// refused at its header line and the keys under it get no refusal
		// (base#1442).
		if md.Type(k...) == "Hash" {
			if lines == nil {
				lines = locate.Index(src)
			}
			occ, _ := lines.Table(k)
			refusals = append(refusals, Refusal{Event: "conf_unknown_table", Path: k, Line: occ.KeyLine})
			continue
		}
		if _, isKey := canonical(k[0], k[1]); !isKey {
			refusals = append(refusals, Refusal{Event: "conf_unknown_key", Path: k, Line: keyLine(src, k)})
		} else if md.Type(k...) == "Array" {
			// An array at a registered scalar key is a value of the wrong
			// type for that key, not an array the array stage owns
			// (base#1442).
			refusals = append(refusals, Refusal{Event: "conf_value_type_refused", Path: k, Line: keyLine(src, k)})
		} else {
			var table map[string]toml.Primitive
			var s Scalar
			// A value of a kind Scalar does not decode yet is left
			// unvalidated; the other kinds follow in later cycles of
			// base#1442.
			if md.PrimitiveDecode(root[k[0]], &table) != nil || md.PrimitiveDecode(table[k[1]], &s) != nil {
				continue
			}
			var ve *ValueError
			if err := Validate(k[0], k[1], s); errors.As(err, &ve) {
				refusals = append(refusals, Refusal{Event: ve.Event, Path: k, Line: keyLine(src, k)})
			}
		}
	}
	tree, deferred := buildTree(src, md)
	return &Config{Logging: Logging{Services: ProjectServices(&tree)}, Tree: tree, Deferred: deferred}, refusals
}

// serviceText reports whether a section text names a logging service:
// `logging.` plus at least one byte.
func serviceText(text string) bool {
	svc, ok := strings.CutPrefix(text, "logging.")
	return ok && svc != ""
}

// buildTree records the accepted table nodes of the layer in the bridge's
// traversal order (toml_bridge.py _emit_table, the loop at line 407): the
// parsed tree walked depth first, each node entered before its children,
// each table's children in the order they were first created, which is
// the order a key or a prefix of it first appears in md.Keys(). The root,
// the known sections and every table whose text is under logging are
// accepted; a refused table and everything under it is left out, and so
// is a root scalar. Each accepted array is returned in the second result
// with its payload (base#1442).
func buildTree(src []byte, md toml.MetaData) (Tree, []Deferred) {
	keys := md.Keys()
	var doc map[string]any
	if _, err := toml.Decode(string(src), &doc); err != nil {
		return Tree{}, nil
	}
	children := map[string][]string{}
	seen := map[string]bool{}
	for _, k := range keys {
		for i := 1; i <= len(k); i++ {
			id := fmt.Sprintf("%q", []string(k[:i]))
			if !seen[id] {
				seen[id] = true
				parent := fmt.Sprintf("%q", []string(k[:i-1]))
				children[parent] = append(children[parent], k[i-1])
			}
		}
	}
	lines := locate.Index(src)
	accepted := func(p []string) bool {
		if len(p) == 1 {
			return known[p[0]] || serviceText(p[0])
		}
		return p[0] == "logging" || serviceText(p[0])
	}
	t := Tree{Nodes: []Node{{}}}
	var deferred []Deferred
	var walk func(at int, path []string, table map[string]any)
	walk = func(at int, path []string, table map[string]any) {
		for _, name := range children[fmt.Sprintf("%q", path)] {
			p := append(append([]string{}, path...), name)
			switch v := table[name].(type) {
			case map[string]any:
				if !accepted(p) {
					continue
				}
				n := Node{Path: p, Text: strings.Join(p, ".")}
				if occ := lines.Tables(p); len(occ) > 0 {
					n.Line, n.Implicit = occ[0].KeyLine, occ[0].Implicit
				} else if occ := lines.Keys(p); len(occ) > 0 {
					n.Line, n.Inline = occ[0].KeyLine, true
				}
				i := len(t.Nodes)
				t.Nodes = append(t.Nodes, n)
				t.Nodes[at].Children = append(t.Nodes[at].Children, Child{Kind: ChildNode, Key: name, Node: i})
				walk(i, p, v)
			default:
				_, isTables := v.([]map[string]any)
				_, isArray := v.([]any)
				// At the root only an array of tables at a known section
				// name is accepted; any other root key is refused.
				if len(path) == 0 && (!isTables || !known[name]) {
					continue
				}
				if isTables || isArray {
					d := Deferred{Path: p, Type: md.Type(p...), Value: arrayValue(lines, p, v)}
					d.Line = d.Value.Line
					t.Nodes[at].Children = append(t.Nodes[at].Children, Child{Kind: ChildDeferred, Key: name, Defer: len(deferred)})
					deferred = append(deferred, d)
					continue
				}
				var s Scalar
				// A value of a kind Scalar does not decode yet is left
				// out; the other kinds follow in later cycles of
				// base#1442.
				if s.UnmarshalTOML(v) != nil {
					continue
				}
				occ, _ := lines.Key(p)
				f := Field{State: Set, Value: s, Line: occ.KeyLine}
				t.Nodes[at].Children = append(t.Nodes[at].Children, Child{Kind: ChildRow, Key: name, Row: f})
			}
		}
	}
	walk(0, nil, doc)
	return t, deferred
}

// arrayValue is the payload of the array v at path p. An array of tables
// has one VTable per `[[p]]` element, at its header line, whose members
// are the keys written directly under that header, in source order, each
// at its key line. An inline array starts on its key's line and its items
// are given that line (base#1442).
func arrayValue(lines *locate.Map, p []string, v any) Value {
	elems, isTables := v.([]map[string]any)
	if !isTables {
		occ, _ := lines.Key(p)
		return valueOf(v, occ.KeyLine)
	}
	out := Value{Kind: VArray}
	entries := lines.Entries()
	want := fmt.Sprintf("%q", p)
	i := 0
	for at, o := range entries {
		if o.Kind != locate.ArrayHeader || fmt.Sprintf("%q", o.Path) != want || i >= len(elems) {
			continue
		}
		item := Value{Kind: VTable, Header: true, Line: o.KeyLine}
		for _, m := range entries[at+1:] {
			if m.Kind == locate.ArrayHeader || (m.Kind == locate.Header && !m.Implicit) {
				break
			}
			if m.Kind != locate.Key || len(m.Path) != len(p)+1 || fmt.Sprintf("%q", m.Path[:len(p)]) != want {
				continue
			}
			key := m.Path[len(p)]
			item.Members = append(item.Members, Member{Key: key, Value: valueOf(elems[i][key], m.KeyLine)})
		}
		if i == 0 {
			out.Line = o.KeyLine
		}
		out.Items = append(out.Items, item)
		i++
	}
	return out
}

// valueOf is the value v written at line: a scalar, an array of values or
// a table whose members are in key order, each given line.
func valueOf(v any, line int) Value {
	switch x := v.(type) {
	case []any:
		out := Value{Kind: VArray, Line: line}
		for _, item := range x {
			out.Items = append(out.Items, valueOf(item, line))
		}
		return out
	case map[string]any:
		out := Value{Kind: VTable, Line: line}
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			out.Members = append(out.Members, Member{Key: k, Value: valueOf(x[k], line)})
		}
		return out
	}
	var s Scalar
	// A kind Scalar does not decode yet keeps its zero Scalar; the other
	// kinds follow in later cycles of base#1442.
	_ = s.UnmarshalTOML(v)
	return Value{Kind: VScalar, Scalar: s, Line: line}
}

// ProjectServices walks t depth first in Children order and appends each
// row of a node whose text is `logging.` plus at least one byte to the
// Rows of the service named by the rest of the text; each typed field is
// the last row with its key (the `_conf_get` rule). Decode builds
// Logging.Services with it, and a merged tree projects the same way
// (base#1442).
func ProjectServices(t *Tree) map[string]*Service {
	out := map[string]*Service{}
	if len(t.Nodes) == 0 {
		return out
	}
	var walk func(i int)
	walk = func(i int) {
		for _, c := range t.Nodes[i].Children {
			switch c.Kind {
			case ChildNode:
				walk(c.Node)
			case ChildRow:
				svc, ok := strings.CutPrefix(t.Nodes[i].Text, "logging.")
				if !ok || svc == "" {
					continue
				}
				if out[svc] == nil {
					out[svc] = &Service{}
				}
				out[svc].Rows = append(out[svc].Rows, Row{Key: c.Key, Field: c.Row})
				switch c.Key {
				case "driver":
					out[svc].Driver = c.Row
				case "max_file":
					out[svc].MaxFile = c.Row
				}
			case ChildDeferred:
				// An array is no service row.
			}
		}
	}
	walk(0)
	return out
}

// keyLine is the line of `<key> =` under the header `[<table>]`.
func keyLine(src []byte, k toml.Key) int {
	table := ""
	for i, line := range bytes.Split(src, []byte("\n")) {
		s := strings.TrimSpace(string(line))
		if strings.HasPrefix(s, "[") {
			table = strings.Trim(s, "[]")
		} else if name, _, ok := strings.Cut(s, "="); ok && table == k[0] && strings.TrimSpace(name) == k[1] {
			return i + 1
		}
	}
	return 0
}
