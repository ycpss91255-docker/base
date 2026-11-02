// Package schema decodes a setup.toml layer and refuses what schema.sh
// does not know (base#1442).
package schema

import (
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
	Environment Environment
	Logging     Logging
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

// Decode decodes src and returns its refusals, each at the line the
// locator gives the refused table or key (base#1442). Every path md.Keys()
// lists is classified by its TOML type before any name lookup:
//   - a table schema.sh does not know is one conf_unknown_table refusal at
//     its header line; the outermost such table is refused and nothing
//     under it gets a refusal of its own;
//   - anything under an array is the array stage's and gets no refusal;
//   - a scalar at the root, whatever its name, is one conf_top_level_key;
//   - a scalar or an array under a known table is judged as
//     _setup_known_key and _schema_validate judge its section text and
//     key, so a `[logging.<service>]` key is judged as a [logging] key: an
//     unregistered key is conf_unknown_key, an array at a registered key
//     is conf_value_type_refused, and a scalar Validate refuses is one
//     refusal with Validate's event.
func Decode(src []byte) (*Config, []Refusal) {
	var doc map[string]any
	md, err := toml.Decode(string(src), &doc)
	if err != nil {
		return nil, []Refusal{{Event: "conf_toml_parse_failed"}}
	}
	lines := locate.Index(src)
	var refusals []Refusal
	refuse := func(event string, k []string, line int) {
		refusals = append(refusals, Refusal{Event: event, Path: k, Line: line})
	}
	refused := map[string]bool{}
next:
	for _, k := range md.Keys() {
		// The outermost table on the path that is refused, or the first
		// array on it, decides for everything under it. A prefix is
		// classified by its decoded value, so an implicit table, which
		// md.Keys() need not list, is classified too.
		for i := 1; i < len(k); i++ {
			switch lookup(doc, k[:i]).(type) {
			case []map[string]any, []any:
				continue next
			case map[string]any:
				if !accepted(k[:i]) {
					if id := pathID(k[:i]); !refused[id] {
						refused[id] = true
						refuse("conf_unknown_table", k[:i], tableLine(lines, k[:i]))
					}
					continue next
				}
			}
		}
		section, key := strings.Join(k[:len(k)-1], "."), k[len(k)-1]
		switch typ := md.Type(k...); {
		case typ == "Hash":
			if id := pathID(k); !accepted(k) && !refused[id] {
				refused[id] = true
				refuse("conf_unknown_table", k, tableLine(lines, k))
			}
		case len(k) == 1 && (typ == "ArrayHash" || typ == "Array"):
			// An array at a known section name, `[[volumes]]` or the
			// inline `volumes = [{...}]`, is the legacy spelling the
			// array stage handles. Any other root array is refused as
			// what it is written as: an array-table header is a table,
			// an inline array a root key.
			switch {
			case known[k[0]]:
			case typ == "ArrayHash":
				refuse("conf_unknown_table", k, tableLine(lines, k))
			default:
				refuse("conf_top_level_key", k, keyLine(lines, k))
			}
		case len(k) == 1:
			refuse("conf_top_level_key", k, keyLine(lines, k))
		case typ == "ArrayHash":
			// An array of tables nested under a known table is the array
			// stage's.
		default:
			if _, isKey := canonical(section, key); !isKey {
				refuse("conf_unknown_key", k, keyLine(lines, k))
				continue
			}
			if typ == "Array" {
				// An array at a registered scalar key is a value of the
				// wrong type for that key, not an array the array stage
				// owns.
				refuse("conf_value_type_refused", k, keyLine(lines, k))
				continue
			}
			var s Scalar
			if s.UnmarshalTOML(lookup(doc, k)) != nil {
				refuse("conf_value_type_refused", k, keyLine(lines, k))
				continue
			}
			var ve *ValueError
			if err := Validate(section, key, s); errors.As(err, &ve) {
				refuse(ve.Event, k, keyLine(lines, k))
			}
		}
	}
	tree, deferred := buildTree(md, doc, lines)
	return &Config{Environment: projectEnvironment(&tree), Logging: Logging{Services: ProjectServices(&tree)}, Tree: tree, Deferred: deferred}, refusals
}

// accepted reports whether the table at p is one _setup_known_section
// accepts: a known section, or any table whose text is under logging.
func accepted(p []string) bool {
	if len(p) == 1 {
		return known[p[0]] || serviceText(p[0])
	}
	return p[0] == "logging" || serviceText(p[0])
}

// lookup is the decoded value at path k of doc, or nil.
func lookup(doc map[string]any, k []string) any {
	var v any = doc
	for _, name := range k {
		m, ok := v.(map[string]any)
		if !ok {
			return nil
		}
		v = m[name]
	}
	return v
}

// keyLine is the line the locator gives the key k. A key inside an inline
// value is not indexed, so it is given the line of the innermost inline
// key that holds it.
func keyLine(lines *locate.Map, k []string) int {
	for i := len(k); i > 0; i-- {
		for _, o := range lines.Keys(k[:i]) {
			if i == len(k) || o.Inline {
				return o.KeyLine
			}
		}
	}
	return 0
}

// tableLine is the line of the first occurrence of the table k: its
// header, its first creator's when implicit, or its key's when inline.
func tableLine(lines *locate.Map, k []string) int {
	if occ := lines.Tables(k); len(occ) > 0 {
		return occ[0].KeyLine
	}
	return keyLine(lines, k)
}

// projectEnvironment is the [environment] node of t: Absent when there is
// none, Empty when it has no scalar row, Set with its rows otherwise
// (base#1309, base#1442).
func projectEnvironment(t *Tree) Environment {
	var out Environment
	if len(t.Nodes) == 0 {
		return out
	}
	for _, c := range t.Nodes[0].Children {
		if c.Kind != ChildNode || c.Key != "environment" {
			continue
		}
		out.Table.State = Empty
		for _, r := range t.Nodes[c.Node].Children {
			if r.Kind != ChildRow {
				continue
			}
			if out.Env == nil {
				out.Env = map[string]Field{}
			}
			out.Env[r.Key] = r.Row
			out.Table.State = Set
		}
	}
	return out
}

// serviceName is the logging service a section text names: the text
// after `logging.`, when the text is `logging.` plus at least one byte.
func serviceName(text string) (string, bool) {
	svc, ok := strings.CutPrefix(text, "logging.")
	return svc, ok && svc != ""
}

// serviceText reports whether a section text names a logging service.
func serviceText(text string) bool {
	_, ok := serviceName(text)
	return ok
}

// pathID is a collision-free string form of a TOML path, used as a map
// key and for path equality. It takes []string so a toml.Key is quoted
// element by element rather than through its String method.
func pathID(path []string) string {
	return fmt.Sprintf("%q", path)
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
func buildTree(md toml.MetaData, doc map[string]any, lines *locate.Map) (Tree, []Deferred) {
	keys := md.Keys()
	children := map[string][]string{}
	seen := map[string]bool{}
	for _, k := range keys {
		for i := 1; i <= len(k); i++ {
			id := pathID(k[:i])
			if !seen[id] {
				seen[id] = true
				parent := pathID(k[:i-1])
				children[parent] = append(children[parent], k[i-1])
			}
		}
	}
	t := Tree{Nodes: []Node{{}}}
	var deferred []Deferred
	var walk func(at int, path []string, table map[string]any)
	walk = func(at int, path []string, table map[string]any) {
		for _, name := range children[pathID(path)] {
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
				// At the root only an array at a known section name,
				// `[[volumes]]` or `volumes = [...]`, is accepted; any
				// other root key is refused.
				if len(path) == 0 && ((!isTables && !isArray) || !known[name]) {
					continue
				}
				if isTables || isArray {
					d := Deferred{Path: p, Type: md.Type(p...), Value: arrayValue(lines, keys, p, v)}
					d.Line = d.Value.Line
					t.Nodes[at].Children = append(t.Nodes[at].Children, Child{Kind: ChildDeferred, Key: name, Defer: len(deferred)})
					deferred = append(deferred, d)
					continue
				}
				var s Scalar
				// Scalar decodes every TOML scalar kind; a value it cannot
				// decode is refused by Decode, so leaving it out loses
				// nothing silently.
				if s.UnmarshalTOML(v) != nil {
					continue
				}
				f := Field{State: Set, Value: s, Line: keyLine(lines, p)}
				t.Nodes[at].Children = append(t.Nodes[at].Children, Child{Kind: ChildRow, Key: name, Row: f})
			}
		}
	}
	walk(0, nil, doc)
	return t, deferred
}

// arrayValue is the payload of the array v at path p. An array of tables
// is tablesValue's. An inline array starts on its key's line and its items
// are given that line; the members of each table item are in the order
// md.Keys() lists them (base#1442).
func arrayValue(lines *locate.Map, keys []toml.Key, p []string, v any) Value {
	elems, isTables := v.([]map[string]any)
	if !isTables {
		out := valueOf(v, keyLine(lines, p))
		orderInlineMembers(&out, keys, p)
		return out
	}
	return tablesValue(lines.Entries(), p, elems)
}

// tablesValue is the payload of the array of tables at p whose decoded
// elements are elems: one VTable per `[[p]]` element of entries, at its
// header line, holding the element's whole decoded table (tableValue).
func tablesValue(entries []locate.Occurrence, p []string, elems []map[string]any) Value {
	out := Value{Kind: VArray}
	spans := elementSpans(entries, p)
	for i, e := range elems {
		var span []locate.Occurrence
		line := 0
		if i < len(spans) {
			span, line = spans[i][1:], spans[i][0].KeyLine
		}
		item := tableValue(span, p, e, line)
		item.Header = true
		if i == 0 {
			out.Line = line
		}
		out.Items = append(out.Items, item)
	}
	return out
}

// elementSpans splits entries into the `[[p]]` elements: each span starts
// at one `[[p]]` header and holds every occurrence after it up to the next
// `[[p]]` header or the first header that is not under p. Nested tables,
// nested arrays of tables and dotted keys of the element are under p, so
// they stay in its span.
func elementSpans(entries []locate.Occurrence, p []string) [][]locate.Occurrence {
	want := pathID(p)
	var spans [][]locate.Occurrence
	open := false
	for _, o := range entries {
		switch {
		case o.Kind == locate.ArrayHeader && pathID(o.Path) == want:
			spans = append(spans, []locate.Occurrence{o})
			open = true
		case !open:
		case o.Kind != locate.Key && !under(o.Path, p):
			open = false
		default:
			spans[len(spans)-1] = append(spans[len(spans)-1], o)
		}
	}
	return spans
}

// under reports whether path lies strictly under p, by whole components.
func under(path, p []string) bool {
	return len(path) > len(p) && pathID(path[:len(p)]) == pathID(p)
}

// tableValue is the decoded table m written at prefix, at line. Its
// members are its keys in the order span first names them, then any key
// span does not name, in key order, so the payload is whole either way.
// A member that is a table written with headers or dotted keys is a
// tableValue of its own, an array of tables a tablesValue, and anything
// else valueOf at the member's first line.
func tableValue(span []locate.Occurrence, prefix []string, m map[string]any, line int) Value {
	out := Value{Kind: VTable, Line: line}
	var order []string
	first := map[string]locate.Occurrence{}
	for _, o := range span {
		if !under(o.Path, prefix) {
			continue
		}
		name := o.Path[len(prefix)]
		if _, seen := first[name]; !seen {
			first[name] = o
			order = append(order, name)
		}
	}
	var rest []string
	for name := range m {
		if _, seen := first[name]; !seen {
			rest = append(rest, name)
		}
	}
	sort.Strings(rest)
	for _, name := range append(order, rest...) {
		v, ok := m[name]
		if !ok {
			continue
		}
		o, written := first[name]
		at := line
		if written {
			at = o.KeyLine
		}
		p := append(append([]string{}, prefix...), name)
		inline := written && o.Kind == locate.Key && len(o.Path) == len(p)
		var mv Value
		switch x := v.(type) {
		case map[string]any:
			if inline {
				mv = valueOf(x, at)
			} else {
				mv = tableValue(span, p, x, at)
			}
		case []map[string]any:
			mv = tablesValue(span, p, x)
		default:
			mv = valueOf(v, at)
		}
		out.Members = append(out.Members, Member{Key: name, Value: mv})
	}
	return out
}

// orderInlineMembers puts the members of each table item of the inline
// array a, written at path p, in source order. md.Keys() lists the
// members of the items under p itself with no item index, one item after
// another (toml_bridge.py line 755 walks elem.items() in that order), so each
// table item takes the next run of keys directly under p, until every one
// of its members has its key (base#1442).
func orderInlineMembers(a *Value, keys []toml.Key, p []string) {
	want := pathID(p)
	var run []string
	for _, k := range keys {
		if len(k) == len(p)+1 && pathID(k[:len(p)]) == want {
			run = append(run, k[len(p)])
		}
	}
	for i := range a.Items {
		item := &a.Items[i]
		if item.Kind != VTable {
			continue
		}
		byKey := map[string]Member{}
		for _, m := range item.Members {
			byKey[m.Key] = m
		}
		ordered := make([]Member, 0, len(item.Members))
		for len(run) > 0 && len(ordered) < len(item.Members) {
			if m, ok := byKey[run[0]]; ok {
				ordered = append(ordered, m)
				delete(byKey, run[0])
			}
			run = run[1:]
		}
		if len(ordered) == len(item.Members) {
			item.Members = ordered
		}
	}
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
				svc, ok := serviceName(t.Nodes[i].Text)
				if !ok {
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
