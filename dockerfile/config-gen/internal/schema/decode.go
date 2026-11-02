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
// the key with its raw bytes, and the 1-based line and byte column it is
// written on (0 when no position is known).
type Refusal struct {
	Event string
	Path  []string
	Line  int
	Col   int
}

// Config is the decoded layer.
type Config struct {
	Deploy      Deploy
	Environment Environment
	Logging     Logging
	// Deprecated is every key of the layer written in a deprecated
	// spelling, owned by this decode.
	Deprecated []Deprecation
	// Tree is every accepted table node, in the bridge's traversal order.
	Tree Tree
	// Deferred is every accepted array with its payload, in the order its
	// ChildDeferred appears in the traversal; Child.Defer indexes it.
	Deferred []Deferred
}

// known is the set of sections _setup_known_section accepts
// (dist/script/docker/lib/setup_cmd.sh) by name: schema.sh's
// SCHEMA_SECTIONS, every one of which carries at least one
// SCHEMA_VALIDATOR row, so it is derived from the sections of the
// validators and not listed a second time (base#1442).
// TestKnownSectionsAreSchemaSections and its bats half hold it equal to
// SCHEMA_SECTIONS.
var known = func() map[string]bool {
	m := map[string]bool{}
	for k := range validators {
		section, _, _ := strings.Cut(k, ".")
		m[section] = true
	}
	return m
}()

// KnownSections returns the section names Decode knows, sorted.
func KnownSections() []string {
	out := make([]string, 0, len(known))
	for s := range known {
		out = append(out, s)
	}
	sort.Strings(out)
	return out
}

// freeForm is the keys _setup_known_key knows with no validator: the
// pre-arg_N [build] named keys _setup_apply lifts into build args.
var freeForm = map[string]bool{
	"build.apt_mirror_ubuntu": true,
	"build.apt_mirror_debian": true,
	"build.tz":                true,
}

// knownKey is _setup_known_key: a key that resolves to a SCHEMA_VALIDATOR
// row, or a free-form key.
func knownKey(section, key string) bool {
	_, ok := canonical(section, key)
	return ok || freeForm[section+"."+key]
}

// stage reports whether the path lies in a `["stage:<name>"]` table,
// whose section text _setup_conf_check_known skips.
func stage(p []string) bool {
	return len(p) > 0 && strings.HasPrefix(p[0], "stage:")
}

// keyCharEvent is the refusal one key or table name draws: U+0000 is
// conf_value_nul_refused (ADR-00000039), and a tab, LF or CR, which the
// bridge's tab-separated view cannot carry (toml_bridge.py
// _check_transportable), is conf_key_char_refused; "" otherwise.
func keyCharEvent(name string) string {
	switch {
	case strings.ContainsRune(name, 0):
		return "conf_value_nul_refused"
	case strings.ContainsAny(name, "\t\n\r"):
		return "conf_key_char_refused"
	}
	return ""
}

// valueCharEvent is the refusal one string value draws: U+0000 is
// conf_value_nul_refused (ADR-00000039), and an LF or CR, which the
// bridge refuses in a value (_check_transportable), is
// conf_value_newline_refused; "" otherwise. A tab in a value is carried.
func valueCharEvent(text string) string {
	switch {
	case strings.ContainsRune(text, 0):
		return "conf_value_nul_refused"
	case strings.ContainsAny(text, "\n\r"):
		return "conf_value_newline_refused"
	}
	return ""
}

// Decode decodes src and returns its refusals, each at the position the
// locator gives the refused table or key (base#1442), sorted by line.
//
// A document the parser refuses is one conf_toml_parse_failed at the
// parser's line and column, naming the last table or key the locator
// found at or before that line, and no Config.
//
// Otherwise every path md.Keys() lists is judged in turn:
//   - a table or key name holding U+0000, a tab, LF or CR is refused
//     (keyCharEvent) at the outermost path it appears in, once;
//   - a table schema.sh does not know is one conf_unknown_table refusal at
//     its header line; the outermost such table is refused and nothing
//     under it gets a refusal of its own;
//   - anything under an array is the array stage's: only its string
//     values are judged here, by valueCharEvent;
//   - a scalar at the root, whatever its name, is one conf_top_level_key;
//   - a string value under a known table holding U+0000, LF or CR is
//     refused (valueCharEvent);
//   - anything else under a `["stage:<name>"]` table is not judged, as
//     _setup_conf_check_known does not judge it;
//   - a scalar or an array under a known table is judged as
//     _setup_known_key and _schema_validate judge its section text and
//     key, so a `[logging.<service>]` key is judged as a [logging] key: an
//     unknown key is conf_unknown_key, an array at a registered key is
//     conf_value_type_refused, a scalar outside its key's type
//     (kindRefused) is conf_value_type_refused, and a scalar whose text
//     Validate refuses is one refusal with Validate's event.
func Decode(src []byte) (*Config, []Refusal) {
	var doc map[string]any
	md, err := toml.Decode(string(src), &doc)
	lines := locate.Index(src)
	if err != nil {
		return nil, []Refusal{parseRefusal(lines, err)}
	}
	d := decoder{lines: lines, refused: map[string]bool{}, tables: map[string]bool{}}
next:
	for _, k := range md.Keys() {
		if i := badName(k); i >= 0 {
			p := k[:i+1]
			if !d.refused[pathID(p)] {
				line, col := keyPos(lines, p)
				if i < len(k)-1 || md.Type(k...) == "Hash" {
					line, col = tablePos(lines, p)
				}
				d.refuse(keyCharEvent(k[i]), p, line, col)
			}
			continue
		}
		// Every table on the path is judged by its section text, as the
		// shell's --tables walk judges it: each one _setup_known_section
		// does not know is refused once, and nothing under it is judged
		// further. The first array on the path decides for everything
		// under it. A prefix is classified by its decoded value, so an
		// implicit table, which md.Keys() need not list, is classified
		// too.
		unknown := false
		for i := 1; i < len(k); i++ {
			switch lookup(doc, k[:i]).(type) {
			case []map[string]any, []any:
				continue next
			case map[string]any:
				if !accepted(k[:i]) {
					d.refuseTable(k[:i])
					unknown = true
				}
			}
		}
		if unknown {
			if md.Type(k...) == "Hash" {
				d.refuseTable(k)
			}
			continue
		}
		d.judge(md, doc, k)
	}
	tree, deferred := buildTree(md, doc, lines)
	for _, def := range deferred {
		if !d.refusedUnder(def.Path) {
			d.judgeValues(def.Path, def.Value)
		}
	}
	sort.SliceStable(d.refusals, func(i, j int) bool { return d.refusals[i].Line < d.refusals[j].Line })
	deploy, deprecated := projectDeploy(&tree)
	return &Config{
		Deploy:      deploy,
		Environment: projectEnvironment(&tree),
		Logging:     Logging{Services: ProjectServices(&tree)},
		Deprecated:  deprecated,
		Tree:        tree,
		Deferred:    deferred,
	}, d.refusals
}

// decoder collects the refusals of one Decode.
type decoder struct {
	lines    *locate.Map
	refusals []Refusal
	// refused holds the pathID of every refused path.
	refused map[string]bool
	// tables holds the section text of every refused table.
	tables map[string]bool
}

// refuseTable refuses the table k as conf_unknown_table at its first
// occurrence, once per section text: the shell reports a text once
// however many paths spell it (_setup_conf_check_known's _sck_reported).
func (d *decoder) refuseTable(k []string) {
	text := strings.Join(k, ".")
	if d.tables[text] {
		d.refused[pathID(k)] = true
		return
	}
	d.tables[text] = true
	line, col := tablePos(d.lines, k)
	d.refuse("conf_unknown_table", k, line, col)
}

func (d *decoder) refuse(event string, k []string, line, col int) {
	d.refused[pathID(k)] = true
	d.refusals = append(d.refusals, Refusal{Event: event, Path: k, Line: line, Col: col})
}

// refusedUnder reports whether p or a prefix of it is refused.
func (d *decoder) refusedUnder(p []string) bool {
	for i := 1; i <= len(p); i++ {
		if d.refused[pathID(p[:i])] {
			return true
		}
	}
	return false
}

// judge judges the path k, which lies under no array and no refused table.
func (d *decoder) judge(md toml.MetaData, doc map[string]any, k []string) {
	section, key := strings.Join(k[:len(k)-1], "."), k[len(k)-1]
	typ := md.Type(k...)
	line, col := keyPos(d.lines, k)
	switch {
	case typ == "Hash":
		if !accepted(k) {
			d.refuseTable(k)
		}
		return
	case len(k) == 1 && (typ == "ArrayHash" || typ == "Array"):
		// An array at a known section name, `[[volumes]]` or the inline
		// `volumes = [{...}]`, is the legacy spelling the array stage
		// handles. Any other root array is refused as what it is written
		// as: an array-table header is a table, an inline array a root key.
		switch {
		case known[k[0]]:
		case typ == "ArrayHash":
			d.refuseTable(k)
		default:
			d.refuse("conf_top_level_key", k, line, col)
		}
		return
	case len(k) == 1:
		d.refuse("conf_top_level_key", k, line, col)
		return
	case stage(k):
		// A `["stage:<name>"]` table is not judged here; only a string
		// value's characters are (below).
	case typ == "ArrayHash" || typ == "Array":
		// An array of a numbered family is judged by the row its first
		// entry takes: `[[security.cap_drop]]` and `cap_drop = []` are
		// security.cap_drop_1, as the shell's --kv and --empty-families
		// views name them. Its payload is the array stage's.
		if prefix, ok := arrayFamily[key]; ok {
			if !knownKey(section, prefix+"_1") {
				d.refuse("conf_unknown_key", k, line, col)
			}
			return
		}
		if typ == "ArrayHash" {
			// Any other array of tables under a known table is the array
			// stage's.
			return
		}
	}
	v := lookup(doc, k)
	if text, ok := v.(string); ok {
		if event := valueCharEvent(text); event != "" {
			d.refuse(event, k, line, col)
			return
		}
	}
	switch {
	case stage(k):
	case !knownKey(section, key):
		d.refuse("conf_unknown_key", k, line, col)
	case typ == "Array":
		// An array at a registered scalar key is a value of the wrong
		// type for that key, not an array the array stage owns.
		if _, registered := canonical(section, key); registered {
			d.refuse("conf_value_type_refused", k, line, col)
		}
	default:
		var s Scalar
		if s.UnmarshalTOML(v) != nil || kindRefused(section, key, s) {
			d.refuse("conf_value_type_refused", k, line, col)
			return
		}
		var ve *ValueError
		if err := Validate(section, key, s.Text); errors.As(err, &ve) {
			d.refuse(ve.Event, k, line, col)
		}
	}
}

// judgeValues refuses each string in the deferred value v, written at
// path p, that valueCharEvent refuses, at the value's line.
func (d *decoder) judgeValues(p []string, v Value) {
	switch v.Kind {
	case VScalar:
		if v.Scalar.Kind != KindString {
			return
		}
		if event := valueCharEvent(v.Scalar.Text); event != "" {
			d.refuse(event, p, v.Line, 0)
		}
	case VArray:
		for _, it := range v.Items {
			d.judgeValues(p, it)
		}
	case VTable:
		for _, m := range v.Members {
			d.judgeValues(append(append([]string{}, p...), m.Key), m.Value)
		}
	}
}

// badName is the index of the first component of k that keyCharEvent
// refuses, or -1.
func badName(k []string) int {
	for i, name := range k {
		if keyCharEvent(name) != "" {
			return i
		}
	}
	return -1
}

// parseRefusal is the conf_toml_parse_failed refusal for the parser's
// err: at the parser's line and column, naming the path of the last
// occurrence the locator found at or before that line.
func parseRefusal(lines *locate.Map, err error) Refusal {
	r := Refusal{Event: "conf_toml_parse_failed"}
	var pe toml.ParseError
	if errors.As(err, &pe) {
		r.Line, r.Col = pe.Position.Line, pe.Position.Col
	}
	for _, o := range lines.Entries() {
		if o.KeyLine > r.Line {
			break
		}
		r.Path = o.Path
	}
	return r
}

// accepted reports whether the table at p is one the shell accepts, judged
// on its section text, the dotted path the bridge names it by: a text
// _setup_known_section knows, or one starting with `stage:`, which
// _setup_conf_check_known skips. So `[logging.""]` is the text
// `logging.` and refused, while `["logging.web"]` and `[logging.web.x]`
// name a service.
func accepted(p []string) bool {
	text := strings.Join(p, ".")
	return strings.HasPrefix(text, "stage:") || knownSection(text)
}

// knownSection is _setup_known_section (dist/script/docker/lib/
// setup_cmd.sh): a SCHEMA_SECTIONS name, or `logging.` followed by at
// least one byte.
func knownSection(text string) bool {
	return known[text] || serviceText(text)
}

// arrayFamily maps an array's key to the numbered-family prefix its
// entries take in the shell view: the first element of toml_bridge.py's
// _ARRAY_SPEC, ported verbatim.
var arrayFamily = map[string]string{
	"rules":               "rule",
	"args":                "arg",
	"ports":               "port",
	"cap_add":             "cap_add",
	"cap_drop":            "cap_drop",
	"security_opt":        "security_opt",
	"volumes":             "mount",
	"tmpfs":               "tmpfs",
	"devices":             "device",
	"bindings":            "device",
	"cgroup_rules":        "cgroup_rule",
	"additional_contexts": "context",
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

// keyPos is the line and column the locator gives the key k. A key inside
// an inline value is not indexed, so it is given the position of the
// innermost inline key that holds it.
func keyPos(lines *locate.Map, k []string) (line, col int) {
	for i := len(k); i > 0; i-- {
		for _, o := range lines.Keys(k[:i]) {
			if i == len(k) || o.Inline {
				return o.KeyLine, o.KeyCol
			}
		}
	}
	return 0, 0
}

// keyLine is keyPos's line.
func keyLine(lines *locate.Map, k []string) int {
	line, _ := keyPos(lines, k)
	return line
}

// tablePos is the position of the first occurrence of the table k: its
// header, its first creator's when implicit, or its key's when inline.
func tablePos(lines *locate.Map, k []string) (line, col int) {
	if occ := lines.Tables(k); len(occ) > 0 {
		return occ[0].KeyLine, occ[0].KeyCol
	}
	return keyPos(lines, k)
}

// projectDeploy resolves the legacy alias in the [deploy] node of t as
// deploy.sh's _resolve_deploy_config does: GPURuntime is gpu_runtime when
// it is set to a non-empty value, and the legacy runtime's field
// otherwise. A non-empty legacy runtime, which deploy.sh reports as
// conf_runtime_key_deprecated, is returned as a Deprecation allocated for
// this call (base#1442).
func projectDeploy(t *Tree) (Deploy, []Deprecation) {
	var out Deploy
	if len(t.Nodes) == 0 {
		return out, nil
	}
	for _, c := range t.Nodes[0].Children {
		if c.Kind != ChildNode || c.Key != "deploy" {
			continue
		}
		for _, r := range t.Nodes[c.Node].Children {
			switch {
			case r.Kind != ChildRow:
			case r.Key == "gpu_runtime":
				out.GPURuntime = r.Row
			case r.Key == "runtime":
				out.Runtime = r.Row
			}
		}
	}
	if (out.GPURuntime.State != Set || out.GPURuntime.Value.Text == "") && out.Runtime.State == Set {
		out.GPURuntime = out.Runtime
	}
	if out.Runtime.State != Set || out.Runtime.Value.Text == "" {
		return out, nil
	}
	return out, []Deprecation{{
		Path:      []string{"deploy", "runtime"},
		Canonical: []string{"deploy", "gpu_runtime"},
		Line:      out.Runtime.Line,
	}}
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
// the known sections, every table whose text is under logging and every
// `["stage:<name>"]` table are accepted; a refused table and everything
// under it is left out, and so is a root scalar. Each accepted array is
// returned in the second result with its payload (base#1442).
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
// are given that line; the members of every inline table in it are in
// source order (keyStream).
func arrayValue(lines *locate.Map, keys []toml.Key, p []string, v any) Value {
	elems, isTables := v.([]map[string]any)
	if !isTables {
		out := valueOf(v, keyLine(lines, p))
		streamAfter(keys, p, 0).order(&out, p)
		return out
	}
	return tablesValue(lines.Entries(), keys, p, elems)
}

// tablesValue is the payload of the array of tables at p whose decoded
// elements are elems: one VTable per `[[p]]` element of entries, at its
// header line, holding the element's whole decoded table (tableValue).
func tablesValue(entries []locate.Occurrence, keys []toml.Key, p []string, elems []map[string]any) Value {
	out := Value{Kind: VArray}
	spans := elementSpans(entries, p)
	for i, e := range elems {
		var span []locate.Occurrence
		line := 0
		if i < len(spans) {
			span, line = spans[i][1:], spans[i][0].KeyLine
		}
		item := tableValue(span, keys, p, e, line)
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
// else valueOf at the member's first line; a member whose value is
// written inline has every inline table in it put in source order by the
// key stream from that occurrence of its key (keyStream).
func tableValue(span []locate.Occurrence, keys []toml.Key, prefix []string, m map[string]any, line int) Value {
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
				mv = tableValue(span, keys, p, x, at)
			}
		case []map[string]any:
			mv = tablesValue(span, keys, p, x)
		default:
			mv = valueOf(v, at)
		}
		if inline {
			streamAfter(keys, p, o.Ordinal).order(&mv, p)
		}
		out.Members = append(out.Members, Member{Key: name, Value: mv})
	}
	return out
}

// keyStream replays md.Keys() from one position. The library lists every
// key in the order it parses it, the members of an inline table and of
// each table item of an inline array included, under the path they are
// written at with no item index, each member followed at once by the keys
// inside its own value (toml_bridge.py line 755 walks elem.items() in that
// order). A nil stream orders nothing.
type keyStream struct {
	keys []toml.Key
	at   int
}

// streamAfter is the stream just after the nth (0-based) listing of the
// path p, or nil when p is listed fewer times.
func streamAfter(keys []toml.Key, p []string, nth int) *keyStream {
	want := pathID(p)
	for i, k := range keys {
		if pathID(k) != want {
			continue
		}
		if nth == 0 {
			return &keyStream{keys: keys, at: i + 1}
		}
		nth--
	}
	return nil
}

// order puts the members of every table in v, written at path p, in the
// order the stream lists them, consuming the stream as it goes: each table
// takes the next listed keys directly under p, until each of its members
// has its key, and each member's own value is ordered from the keys that
// follow it. A table whose members the stream does not account for keeps
// its order (base#1442).
func (s *keyStream) order(v *Value, p []string) {
	if s == nil {
		return
	}
	switch v.Kind {
	case VArray:
		for i := range v.Items {
			s.order(&v.Items[i], p)
		}
	case VTable:
		byKey := make(map[string]int, len(v.Members))
		for i, m := range v.Members {
			byKey[m.Key] = i
		}
		want := pathID(p)
		ordered := make([]Member, 0, len(v.Members))
		for len(ordered) < len(v.Members) && s.at < len(s.keys) {
			k := s.keys[s.at]
			s.at++
			if len(k) != len(p)+1 || pathID(k[:len(p)]) != want {
				continue
			}
			i, ok := byKey[k[len(p)]]
			if !ok {
				continue
			}
			delete(byKey, k[len(p)])
			m := v.Members[i]
			s.order(&m.Value, append(append([]string{}, p...), m.Key))
			ordered = append(ordered, m)
		}
		if len(ordered) == len(v.Members) {
			v.Members = ordered
		}
	case VScalar:
	}
}

// valueOf is the value v written at line: a scalar, an array of values or
// a table, each given line. A table's members are in key order here; the
// callers put them in source order with a keyStream.
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
	// A kind Scalar does not decode keeps its zero Scalar.
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
